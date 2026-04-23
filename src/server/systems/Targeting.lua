--[[
    Targeting.lua — Target selection for tower firing.

    Owns findTarget — given a tower's world position, firing range, and
    current TargetMode, pick the best mob on the active map's path for
    this tick. Called from the Towers module's updateTowers loop and
    via ctx.findTarget anywhere else that needs tower-style targeting.

    Four modes (all single-target, they differ only in priority):
      "First"     : mob furthest along the path (about to reach heart)
      "Strongest" : mob with highest current HP
      "Center"    : mob with the most other mobs within 8 studs (for
                    maximizing AOE / Detonator hit counts)
      "Last"      : mob LEAST far along the path. Designed for the
                    explosive-blob problem on map 2 — kill the back
                    of the pack first so the explosion damages the
                    rest of the group, not empty space at the front.

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

local Targeting = {}

function Targeting.setup(ctx)
    -- Per-tower manual target overrides. Populated by the bullseye UI on
    -- the client → SetTowerManualTarget remote. Highest priority in
    -- findTarget when the mob is still alive and in range; cleared on mob
    -- death via the stale-entry sweep at the top of findTarget.
    ctx.towerManualTargets = {}

    local function findTarget(towerPos, range, mode, towerModel)
        mode = mode or "First"
        local waypoints = ctx.getWaypoints()
        local activeMobs = ctx.activeMobs
        local CLUSTER_RADIUS = 8

        -- Manual target override. Return it if still alive + in range;
        -- otherwise clear the stale entry and fall through to mode logic.
        if towerModel then
            local manual = ctx.towerManualTargets[towerModel]
            if manual then
                local data = activeMobs[manual]
                if manual.Parent and data and not data._phoenixQueued then
                    if (manual.Position - towerPos).Magnitude <= range then
                        return manual
                    end
                else
                    ctx.towerManualTargets[towerModel] = nil
                end
            end
        end

        -- Gather all mobs in range with their progress metric
        local candidates = {}
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
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
        if not ctx.activeMobs[mob] then return end
        ctx.towerManualTargets[tower] = mob
    end)
end

return Targeting
