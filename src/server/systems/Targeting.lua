--[[
    Targeting.lua — Target selection for tower firing.

    Owns findTarget — given a tower's world position, firing range, and
    current TargetMode, pick the best mob on the active map's path for
    this tick. Called from the Towers module's updateTowers loop and
    via ctx.findTarget anywhere else that needs tower-style targeting.

    Five modes (all single-target, they differ only in priority):
      "First"     : mob furthest along the path (about to reach heart)
      "Last"      : mob LEAST far along the path. Designed for the
                    explosive-blob problem on map 2 — kill the back
                    of the pack first so the explosion damages the
                    rest of the group, not empty space at the front.
      "Center"    : mob with the most other mobs within 8 studs (for
                    maximizing AOE / Detonator hit counts)
      "Strongest" : mob with highest current HP
      "Weakest"   : mob with lowest current HP. Useful for low-DPS
                    towers chasing kill-credit (e.g. Detonator triggers
                    on death, so finishing weak mobs cascades the chain).

    Ties broken in this order: progress-along-path → HP → distance-to-tower.

    setup(ctx) reads (late-resolved at call time, not setup time — the
    fields are written to ctx by the orchestrator after their source
    tables are declared but all modules' setups may run before either
    side is final):
      ctx.activeMobs     -- per-frame mob registry (owned by MobFactory
                            in a later commit; published by orchestrator
                            for now)
      ctx.getWaypoints   -- world-accessor returning the active map's
                            waypoint Parts in order

    And publishes:
      ctx.findTarget(towerPos, range, mode) → Mob instance or nil
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tags = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Tags"))

local Targeting = {}

function Targeting.setup(ctx)
    -- Per-tower manual target overrides. Populated by the bullseye UI on
    -- the client → SetTowerManualTarget remote. Highest priority in
    -- findTarget when the mob is still alive and in range; cleared on mob
    -- death via the stale-entry sweep at the top of findTarget.
    ctx.towerManualTargets = {}
    -- Throttle table for the manual-target rejection diagnostic
    -- (~1 print per tower per second). Module-private — no need to
    -- expose on ctx.
    local lastDiagTime = {}

    local function findTarget(towerPos, range, mode, towerModel)
        mode = mode or "First"
        local waypoints = ctx.getWaypoints()
        local activeMobs = ctx.activeMobs
        local CLUSTER_RADIUS = 8

        -- Distance helper — respects the same TargetXZOnly /
        -- TargetRadius attributes the Tags.Mob fallback below uses,
        -- so the manual-target path correctly handles tall bosses
        -- like Pickle Lord (body center buried 125 stud below the
        -- platform → 3D Magnitude permanently exceeds any tower's
        -- range). Without this the player could LOCK onto the
        -- boss but the tower would silently never fire because the
        -- in-range check kept failing.
        local function effectiveDistTo(mob)
            local diff = mob.Position - towerPos
            local d
            if mob:GetAttribute("TargetXZOnly") then
                d = math.sqrt(diff.X * diff.X + diff.Z * diff.Z)
            else
                d = diff.Magnitude
            end
            local tr = mob:GetAttribute("TargetRadius") or 0
            if tr > 0 then d = math.max(0, d - tr) end
            return d
        end

        -- Manual target override. Return it if still alive +
        -- damageable + range-ring overlaps the body silhouette
        -- (effectiveDistTo respects TargetRadius / TargetXZOnly).
        -- Range IS gated — range-decay reducing the ring below the
        -- boss's silhouette is the intended difficulty curve, per
        -- the original spec.
        --
        -- Diagnostic: when a manual target IS set but gets
        -- rejected, log the reason every ~1s per tower so playtest
        -- can see why "I targeted X but towers won't fire" cases
        -- are happening. Throttled via lastDiagTime[towerModel].
        if towerModel then
            local manual = ctx.towerManualTargets[towerModel]
            if manual then
                local data = activeMobs[manual]
                local rejected, reason
                if data then
                    if manual.Parent and not data._phoenixQueued
                       and effectiveDistTo(manual) <= range then
                        return manual
                    end
                    if not manual.Parent then
                        rejected, reason = true, "mob.Parent=nil (despawned)"
                    elseif data._phoenixQueued then
                        rejected, reason = true, "phoenix-queued (in limbo)"
                    else
                        rejected = true
                        reason = string.format("out of range: effDist=%.1f range=%.1f",
                            effectiveDistTo(manual), range)
                    end
                else
                    -- Not in activeMobs — could be the Map 3 bird boss body
                    -- or the Pickle Lord body (both Tags.Mob-tagged but
                    -- self-managed). Tower fires only when the mob is
                    -- currently damageable (Tags.Mob present, no
                    -- Untargetable flag).
                    if manual.Parent then
                        if CollectionService:HasTag(manual, Tags.Mob)
                           and not manual:GetAttribute("Untargetable")
                           and effectiveDistTo(manual) <= range then
                            return manual
                        end
                        if not CollectionService:HasTag(manual, Tags.Mob) then
                            rejected, reason = true, "no Tags.Mob"
                        elseif manual:GetAttribute("Untargetable") then
                            rejected, reason = true, "Untargetable=true"
                        else
                            local hasXZ = manual:GetAttribute("TargetXZOnly")
                            local tr = manual:GetAttribute("TargetRadius") or 0
                            local diff = manual.Position - towerPos
                            local rawD
                            if hasXZ then
                                rawD = math.sqrt(diff.X*diff.X + diff.Z*diff.Z)
                            else
                                rawD = diff.Magnitude
                            end
                            rejected = true
                            reason = string.format(
                                "out of range: effDist=%.1f range=%.1f (rawD=%.1f, TargetRadius=%.1f, XZOnly=%s)",
                                effectiveDistTo(manual), range, rawD, tr,
                                tostring(hasXZ == true))
                        end
                        -- Don't clear — bird may re-tag on next swoop;
                        -- Pickle Lord clears Untargetable on rise complete.
                    else
                        ctx.towerManualTargets[towerModel] = nil
                        rejected, reason = true, "mob despawned (cleared from manual targets)"
                    end
                end
                if data and (not manual.Parent or data._phoenixQueued) then
                    ctx.towerManualTargets[towerModel] = nil
                end
                -- Log the rejection ~1× per second per tower so the
                -- studio output isn't flooded but every problem case
                -- still shows up promptly.
                if rejected then
                    local now = os.clock()
                    local last = lastDiagTime[towerModel] or 0
                    if now - last >= 1.0 then
                        lastDiagTime[towerModel] = now
                        local mobName = (manual and manual.Parent and manual.Name) or "?"
                        local towerName = (towerModel and towerModel.Name) or "?"
                        print(("[Targeting] manual target REJECTED tower=%s mob=%s — %s"):format(
                            towerName, mobName, reason))
                    end
                end
            end
        end

        -- Gather all mobs in range with their progress metric
        local candidates = {}
        local seen = {}  -- de-dupe between activeMobs + Tags.Mob fallback
        for mob, data in pairs(activeMobs) do
            if mob.Parent and not data._phoenixQueued then
                local d = (mob.Position - towerPos).Magnitude
                if d <= range then
                    -- Progress score: waypointIndex + (fraction to next waypoint).
                    -- Higher = further along the path.
                    local prog = data.waypointIndex or 1
                    local nextWp = waypoints[prog]
                    if nextWp then
                        local prevWp = waypoints[prog - 1]
                        local legStart = prevWp and prevWp.Position or mob.Position
                        local legEnd = nextWp.Position
                        local legLen = (legEnd - legStart).Magnitude
                        if legLen > 0.01 then
                            local traveled = (mob.Position - legStart).Magnitude
                            prog = prog + math.clamp(traveled / legLen, 0, 1)
                        end
                    end
                    table.insert(candidates, {
                        mob = mob,
                        data = data,
                        dist = d,
                        progress = prog,
                    })
                    seen[mob] = true
                end
            end
        end

        -- Self-managed Tags.Mob parts that live outside ctx.activeMobs —
        -- the Map 3 bird boss body (only Mob-tagged during dive/grab/carry)
        -- and the Map3BirdBoss eggs (created via makePart, walked by their
        -- own task.spawn). Without this fallback, towers would never fire
        -- on eggs and the player would have to face-tank them with the
        -- bird; with it, the same tower update + damage path that handles
        -- regular mobs covers these too. Synthetic `data` is just enough
        -- for the mode sorts (HP / progress / dist) to work.
        for _, mob in ipairs(CollectionService:GetTagged(Tags.Mob)) do
            if not seen[mob] and mob:IsA("BasePart") and mob.Parent
               -- Untargetable flag (Pickle Lord during cinematic /
               -- entrance rise): towers shouldn't be firing bolts at
               -- a still-rising boss before the player even has
               -- camera control back. Cleared when the rise tween
               -- finishes; from then on the mob is normally targetable.
               and not mob:GetAttribute("Untargetable") then
                -- Distance for the in-range check. Two per-mob attribute
                -- knobs let huge bosses participate cleanly:
                --   • TargetXZOnly = true: ignore Y component. The
                --     Pickle Lord body is 440 stud tall with center
                --     buried ~125 stud below the platform; 3D distance
                --     would have a permanent ~125-stud Y baseline and
                --     no tower could ever reach. XZ-only collapses
                --     this to the horizontal-arena distance the
                --     player intuitively reads.
                --   • TargetRadius (studs): subtracted from distance
                --     after computation. Gives towers credit for
                --     hitting the OUTER EDGE of a wide body rather
                --     than its geometric center — Pickle Lord is
                --     62 stud wide, so TargetRadius=31 means towers
                --     hit when the body's silhouette overlaps their
                --     range ring, not just when the centroid does.
                local diff = mob.Position - towerPos
                local d
                if mob:GetAttribute("TargetXZOnly") then
                    d = math.sqrt(diff.X * diff.X + diff.Z * diff.Z)
                else
                    d = diff.Magnitude
                end
                local targetRadius = mob:GetAttribute("TargetRadius") or 0
                if targetRadius > 0 then
                    d = math.max(0, d - targetRadius)
                end
                if d <= range then
                    -- Skip path-flyers (the Map 3 bird) for "First" mode by
                    -- giving them progress = 0 — bird hovers mid-map and
                    -- would otherwise outrank actually-walking-the-path
                    -- eggs because its nearest waypoint sits halfway down
                    -- the path. Walking enemies (eggs) compute real
                    -- progress from waypoint proximity. "Strongest" still
                    -- prefers the bird (HP-sorted), and manual targets
                    -- bypass mode logic entirely.
                    -- Walking enemies (eggs) get FRACTIONAL progress from
                    -- their stamped WaypointIndex + how far along the
                    -- current leg they've traveled. Path flyers (the bird
                    -- — no stamped index, doesn't follow waypoints) fall
                    -- back to closest-waypoint by 3D distance, which lets
                    -- FRONT mode prefer the bird when it's near the heart
                    -- (e.g. dive/grab/dazed near the front of the path)
                    -- and prefer eggs when the bird is mid-map.
                    local prog = 0
                    local stamped = mob:GetAttribute("WaypointIndex")
                    if type(stamped) == "number" then
                        prog = stamped
                        local nextWp = waypoints[stamped]
                        if nextWp then
                            local prevWp = waypoints[stamped - 1]
                            local legStart = (prevWp and prevWp.Position) or mob.Position
                            local legEnd = nextWp.Position
                            local legLen = (legEnd - legStart).Magnitude
                            if legLen > 0.01 then
                                local traveled = (mob.Position - legStart).Magnitude
                                prog = stamped + math.clamp(traveled / legLen, 0, 1)
                            end
                        end
                    else
                        local closestLegDist = math.huge
                        for i = 1, #waypoints do
                            local wp = waypoints[i]
                            if wp and wp.Position then
                                local dl = (mob.Position - wp.Position).Magnitude
                                if dl < closestLegDist then
                                    closestLegDist = dl
                                    prog = i
                                end
                            end
                        end
                    end
                    local hp = mob:GetAttribute("Health") or 1
                    local maxHp = mob:GetAttribute("MaxHealth") or hp
                    table.insert(candidates, {
                        mob = mob,
                        data = { hp = hp, maxHp = maxHp },  -- synthetic
                        dist = d,
                        progress = prog,
                    })
                end
            end
        end

        if #candidates == 0 then return nil end

        if mode == "Strongest" then
            table.sort(candidates, function(a, b)
                if a.data.hp ~= b.data.hp then return a.data.hp > b.data.hp end
                if a.progress ~= b.progress then return a.progress > b.progress end
                return a.dist < b.dist
            end)
            return candidates[1].mob
        end

        -- "Weakest" — opposite of Strongest. Lowest current HP first.
        -- Pairs well with Detonator (death-triggered AOE chains hardest
        -- when each kill bursts into the next-weakest in range).
        if mode == "Weakest" then
            table.sort(candidates, function(a, b)
                if a.data.hp ~= b.data.hp then return a.data.hp < b.data.hp end
                if a.progress ~= b.progress then return a.progress > b.progress end
                return a.dist < b.dist
            end)
            return candidates[1].mob
        end

        if mode == "Center" then
            -- For each candidate, count how many other mobs are within CLUSTER_RADIUS
            for _, c in ipairs(candidates) do
                local n = 0
                for other in pairs(activeMobs) do
                    if other ~= c.mob and other.Parent then
                        if (other.Position - c.mob.Position).Magnitude <= CLUSTER_RADIUS then
                            n = n + 1
                        end
                    end
                end
                c.neighbors = n
            end
            table.sort(candidates, function(a, b)
                if a.neighbors ~= b.neighbors then return a.neighbors > b.neighbors end
                if a.progress ~= b.progress then return a.progress > b.progress end
                return a.dist < b.dist
            end)
            return candidates[1].mob
        end

        -- "Last" — opposite of First. Targets the mob LEAST far along the path.
        -- Designed for the explosive-blob problem on map 2: the player wants
        -- to kill back-of-pack first so the explosion damages the rest of the
        -- group, instead of detonating in empty space at the front.
        if mode == "Last" then
            table.sort(candidates, function(a, b)
                if a.progress ~= b.progress then return a.progress < b.progress end
                return a.dist < b.dist
            end)
            return candidates[1].mob
        end

        -- Default: "First" — furthest along the path
        table.sort(candidates, function(a, b)
            if a.progress ~= b.progress then return a.progress > b.progress end
            return a.dist < b.dist
        end)
        return candidates[1].mob
    end

    ctx.findTarget = findTarget

    -- SetTowerManualTarget remote handler. Validates ownership + that the
    -- passed mob is still a live active mob before writing. Passing
    -- payload.mob = nil clears the override (bullseye toggle-off).
    local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"))
    local setTargetRemote = Remotes.getOrCreate(Remotes.Names.SetTowerManualTarget, "RemoteEvent")
    setTargetRemote.OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= "table" then return end
        local tower = payload.tower
        if typeof(tower) ~= "Instance" or not tower:IsA("Model") then return end
        if tower:GetAttribute("Owner") ~= player.UserId then return end
        local mob = payload.mob
        if mob == nil then
            ctx.towerManualTargets[tower] = nil
            return
        end
        if typeof(mob) ~= "Instance" or not mob:IsA("BasePart") then return end
        -- Accept any active wave-system mob OR any standalone
        -- Tags.Mob-tagged part with a Health attribute. The
        -- standalone path covers the Map 3 Canopy Bird body
        -- (only Mob-tagged during dive/grab/carry — but the
        -- player can pre-lock during the gray hover phase, per
        -- Matthew's "allow setting the target when the boss hp
        -- is grayed out") AND the Pickle Lord body (custom
        -- self-managed system, never enters activeMobs). The
        -- earlier hardcoded bird-body check rejected Pickle
        -- Lord targeting silently — surfaced 2026-04-26 in the
        -- "I targeted but towers don't fire" diagnostic dump.
        local accepted = ctx.activeMobs[mob] ~= nil
        if not accepted then
            if CollectionService:HasTag(mob, Tags.Mob)
               and mob:GetAttribute("Health") ~= nil then
                accepted = true
            end
        end
        if not accepted then return end
        ctx.towerManualTargets[tower] = mob
    end)
end

return Targeting
