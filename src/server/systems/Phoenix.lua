--[[
    Phoenix.lua — The Phoenix attachment's death-save mechanic.

    When the heart would take fatal damage, if any tower has a ready
    Phoenix attachment, we instead:
      1. Restore heart to full HP (no damage taken).
      2. Teleport every mob within PHOENIX_AOE_RADIUS of the heart into
         a burn-in-place state, then a limbo queue that releases them
         back to the path one-at-a-time with fire VFX.
      3. Open a PHOENIX_GRACE_DURATION grace window — any mob reaching
         the heart during this window gets captured instead of dealing
         damage (prevents the next-mob-in-line from re-killing the heart).
      4. Consume the charge: PhoenixReady=false, CdRemaining=PhoenixCooldown.

    CRITICAL INVARIANTS (per CLAUDE.md "don't change without asking"):
      - All Phoenix mechanic numbers come from Config.Phoenix:
          AoeRadius, GraceSeconds, BurnSeconds, BurnInPlaceSeconds,
          Cooldowns (per-rarity, 6-10 minutes).
        This module reads them but must NEVER mutate them, and changing
        the CONFIG values requires design sign-off.
      - Cooldowns tick on wallclock, ungated by gameSpeed. The HUD
        indicator shows integer seconds (write-throttled via
        phoenixDisplayCd to avoid 60Hz attribute replication).
      - Grace window uses wallclock too; heart arrivals during grace
        trigger capturePhoenixMob on the arriving mob.

    setup(ctx) reads (late-resolved at call time):
      ctx.activeMobs         (from MobFactory)
      ctx.getHeart, ctx.getWaypoints  (world accessors)
      ctx.tdRoom             (VFX anchor parent)

    And publishes:
      ctx.PhoenixGrace            (state — shared with MobFactory.clearAllMobs)
      ctx.PhoenixQueue            (state — same)
      ctx.phoenixDisplayCd        (HUD write throttle cache)
      ctx.phoenixDisplayGrace     (same)
      ctx.tryConsumePhoenix()     -- called by damageMob on heart-kill
      ctx.capturePhoenixAOEMobs() -- called by updateMobs during grace
      ctx.capturePhoenixMob()     -- called by updateMobs for heart arrivals during grace
      ctx.processPhoenixQueue()   -- called by updateMobs to release queued mobs
      ctx.tickPhoenixCooldowns()  -- called by Heartbeat each frame
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags   = require(Shared:WaitForChild("Tags"))
local Config = require(Shared:WaitForChild("Config"))

local Phoenix = {}

function Phoenix.setup(ctx)
    -- State tables (kept module-local AND published on ctx so other
    -- modules can read without capturing a stale reference).
    local PhoenixGrace        = { activeUntil = 0 }
    local PhoenixQueue        = { items = {}, nextReleaseAt = 0 }
    local phoenixDisplayCd    = {}
    local phoenixDisplayGrace = {}
    ctx.PhoenixGrace        = PhoenixGrace
    ctx.PhoenixQueue        = PhoenixQueue
    ctx.phoenixDisplayCd    = phoenixDisplayCd
    ctx.phoenixDisplayGrace = phoenixDisplayGrace

    -- Pull shortcuts to ctx fields that are read often inside the
    -- closures. These get captured as upvalues; since ctx.activeMobs
    -- etc. may be re-assigned in theory, we read ctx.X in the hot
    -- path rather than caching.

    -- ============================================================
    -- PHOENIX CHARM (death-save mechanic)
    -- ============================================================
    -- When the heart would take fatal damage, if any tower has a ready Phoenix
    -- attachment, we instead:
    --   1. Restore heart to full HP (no damage taken).
    --   2. Teleport every active mob back to waypoint 1, keeping their current HP.
    --   3. Open a 5-second "grace window" — any mob that reaches the heart during
    --      this window also gets teleported back instead of dealing damage. This
    --      prevents the next-mob-in-line from instantly killing the heart again.
    --   4. Consume the charge: PhoenixReady=false, CdRemaining=PhoenixCooldown.
    -- The cooldown ticks down only during active waves (existing tickPhoenixCooldowns).
    -- A run reset destroys towers, which clears the cooldown state — so restarting
    -- a map gives you a fresh Phoenix even if the cooldown wasn't done.
    
    -- PhoenixGrace forward-declared above (near clearAllMobs).
    
    -- Spawn a fire VFX (ParticleEmitter on a hidden anchor part) at a position.
    -- Lasts `duration` seconds, then auto-cleans up. Server-spawned so the VFX
    -- replicates to all clients automatically — no remote needed.
    --
    -- The anchor is a 0.1-stud invisible Part. ParticleEmitter does the work.
    -- We stagger the emission so particles continue spawning for ~half the
    -- duration, then we let the existing particles finish their lifetime
    -- naturally before destroying the anchor.
    local function spawnFireVFX(position, duration, scale)
        duration = duration or 2.5
        scale = scale or 1.0
        local anchor = Instance.new("Part")
        anchor.Name = "PhoenixFireVFX"
        anchor.Size = Vector3.new(0.1, 0.1, 0.1)
        anchor.Anchored = true
        anchor.CanCollide = false
        anchor.CanQuery = false
        anchor.CanTouch = false
        anchor.Transparency = 1
        anchor.CFrame = CFrame.new(position)
        anchor.Parent = Workspace
    
        local pe = Instance.new("ParticleEmitter")
        pe.Texture = "rbxasset://textures/particles/fire_main.dds"
        pe.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0,    Color3.fromRGB(255, 230, 120)),
            ColorSequenceKeypoint.new(0.5,  Color3.fromRGB(255, 130,  40)),
            ColorSequenceKeypoint.new(1,    Color3.fromRGB(120,  20,  20)),
        })
        pe.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   1.4 * scale),
            NumberSequenceKeypoint.new(0.5, 2.2 * scale),
            NumberSequenceKeypoint.new(1,   0.4 * scale),
        })
        pe.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.1),
            NumberSequenceKeypoint.new(0.7, 0.4),
            NumberSequenceKeypoint.new(1,   1.0),
        })
        pe.Lifetime = NumberRange.new(0.5, 0.9)
        pe.Rate = 60 * scale
        pe.Speed = NumberRange.new(2, 5)
        pe.SpreadAngle = Vector2.new(180, 180)  -- omnidirectional puff
        pe.Acceleration = Vector3.new(0, 6, 0)  -- rises like fire
        pe.LightEmission = 0.8
        pe.LightInfluence = 0
        pe.Rotation = NumberRange.new(0, 360)
        pe.RotSpeed = NumberRange.new(-90, 90)
        pe.Parent = anchor
    
        -- Emit for the active portion of the duration, then let particles fade.
        task.delay(duration * 0.6, function()
            if pe.Parent then pe.Enabled = false end
        end)
        task.delay(duration + 1.0, function()  -- +1s to let last particles fade
            if anchor.Parent then anchor:Destroy() end
        end)
    end
    
    -- Spawn a ring of fire on the floor showing the Phoenix AOE boundary.
    -- Used when Phoenix fires — players see exactly how far the effect reaches.
    -- Creates 16 fire anchors arranged in a circle of the given radius around
    -- `centerPos`, each with a small upward-burning ParticleEmitter. All fade
    -- out after `duration` seconds.
    local function spawnPhoenixAOEFloorFire(centerPos, radius, duration)
        local NUM_ANCHORS = 16
        local anchors = {}
        for i = 0, NUM_ANCHORS - 1 do
            local angle = (i / NUM_ANCHORS) * math.pi * 2
            local pos = centerPos + Vector3.new(math.cos(angle) * radius, 0.5, math.sin(angle) * radius)
            local anchor = Instance.new("Part")
            anchor.Name = "PhoenixAOEFloorFire"
            anchor.Size = Vector3.new(0.1, 0.1, 0.1)
            anchor.Anchored = true
            anchor.CanCollide = false
            anchor.CanQuery = false
            anchor.CanTouch = false
            anchor.Transparency = 1
            anchor.CFrame = CFrame.new(pos)
            anchor.Parent = Workspace
    
            local pe = Instance.new("ParticleEmitter")
            pe.Texture = "rbxasset://textures/particles/fire_main.dds"
            pe.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 200, 100)),
                ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 120,  40)),
                ColorSequenceKeypoint.new(1,   Color3.fromRGB(140,  30,  20)),
            })
            pe.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0,   1.8),
                NumberSequenceKeypoint.new(0.5, 3.2),
                NumberSequenceKeypoint.new(1,   0.6),
            })
            pe.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0,   0.2),
                NumberSequenceKeypoint.new(0.8, 0.6),
                NumberSequenceKeypoint.new(1,   1.0),
            })
            pe.Lifetime = NumberRange.new(0.6, 1.2)
            pe.Rate = 24
            pe.Speed = NumberRange.new(2, 4)
            pe.SpreadAngle = Vector2.new(35, 35)  -- mostly upward
            pe.Acceleration = Vector3.new(0, 5, 0)
            pe.LightEmission = 0.8
            pe.Rotation = NumberRange.new(0, 360)
            pe.RotSpeed = NumberRange.new(-90, 90)
            pe.Parent = anchor
            anchors[i + 1] = {anchor = anchor, pe = pe}
        end
        -- Fade out the emitters `duration * 0.7` in so particles stop
        -- emitting while the tail continues to burn.
        task.delay(duration * 0.7, function()
            for _, a in ipairs(anchors) do
                if a.pe.Parent then a.pe.Enabled = false end
            end
        end)
        -- Destroy the anchors once all particles have faded.
        task.delay(duration + 1.2, function()
            for _, a in ipairs(anchors) do
                if a.anchor.Parent then a.anchor:Destroy() end
            end
        end)
    end
    
    local PHOENIX_AOE_RADIUS = Config.Phoenix.AoeRadius       -- studs, centered on heart
    local PHOENIX_GRACE_DURATION = Config.Phoenix.GraceSeconds    -- seconds — AOE keeps catching mobs during this window
    local PHOENIX_BURN_DURATION = Config.Phoenix.BurnSeconds    -- seconds of fire VFX on each released mob
    
    -- Phoenix respawn queue.
    --
    -- On Phoenix trigger (or during grace window sweep), every mob in AOE is
    -- CAPTURED: hidden offscreen, HP preserved, and queued with its original
    -- path-distance-from-heart. Queue is sorted closest-to-heart first. A
    -- scheduler releases them from the path start in that order, with delays
    -- based on ORIGINAL spacing:
    --   delay_N = (pathDist_N - pathDist_(N-1)) / speed_N
    -- So if A was 7 studs from heart, B was 13, C was 27:
    --   A releases at t=0
    --   B releases at t = (13-7)/B.speed = 6/B.speed seconds later
    --   C releases at t_B + (27-13)/C.speed
    -- This recreates the original wave pacing.
    --
    -- Each released mob gets a burning VFX (follows them) and their original HP.
    -- The queue can outlive the grace window — grace just controls when new
    -- entries get captured.
    -- PhoenixQueue forward-declared above (near clearAllMobs) with {items={}, nextReleaseAt=0}.
    
    -- Compute a mob's path-distance-from-heart (studs). 0 = at heart. Higher =
    -- further from heart, closer to spawn.
    local function computePathDistFromHeart(mob, data, waypoints)
        -- Total path length forward of this mob = distance to next waypoint +
        -- sum of segment lengths from that waypoint through the final one.
        local idx = data.waypointIndex or 1
        local total = 0
        local nextWp = waypoints[idx]
        if nextWp then
            total = (nextWp.Position - mob.Position).Magnitude
            for i = idx, #waypoints - 1 do
                total = total + (waypoints[i + 1].Position - waypoints[i].Position).Magnitude
            end
        end
        return total
    end
    
    -- Attach a fire ParticleEmitter to a mob for PHOENIX_BURN_DURATION seconds.
    -- Parented to the mob so it follows them. If the mob dies before burn
    -- expires, emitter is destroyed with the mob automatically.
    local function attachBurningEffect(mob, data)
        if data._burnEmitter and data._burnEmitter.Parent then
            data._burnEmitter:Destroy()
        end
        local pe = Instance.new("ParticleEmitter")
        pe.Texture = "rbxasset://textures/particles/fire_main.dds"
        pe.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 230, 120)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 130,  40)),
            ColorSequenceKeypoint.new(1,   Color3.fromRGB(120,  20,  20)),
        })
        local scale = math.max(0.5, (data.size or 1.5) * 0.35)
        pe.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.8 * scale),
            NumberSequenceKeypoint.new(0.5, 1.3 * scale),
            NumberSequenceKeypoint.new(1,   0.2 * scale),
        })
        pe.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.15),
            NumberSequenceKeypoint.new(0.7, 0.4),
            NumberSequenceKeypoint.new(1,   1.0),
        })
        pe.Lifetime = NumberRange.new(0.4, 0.8)
        pe.Rate = 30
        pe.Speed = NumberRange.new(1, 3)
        pe.SpreadAngle = Vector2.new(180, 180)
        pe.Acceleration = Vector3.new(0, 4, 0)
        pe.LightEmission = 0.8
        pe.Rotation = NumberRange.new(0, 360)
        pe.RotSpeed = NumberRange.new(-90, 90)
        pe.Parent = mob
    
        data._burnEmitter = pe
        task.delay(PHOENIX_BURN_DURATION, function()
            if pe.Parent then pe.Enabled = false end
            task.delay(1, function() if pe.Parent then pe:Destroy() end end)
        end)
    end
    
    -- LIMBO position: far below all maps so queued mobs are invisible/unreachable
    -- while they wait for release. Per-mob offset so many queued mobs don't stack.
    local PHOENIX_LIMBO_BASE = Vector3.new(-10000, -500, -10000)
    
    -- Capture a mob into the Phoenix queue: hide it, record HP + pathDist,
    -- insert into the queue sorted by pathDist ascending (closest-to-heart first).
    -- Caller guarantees mob.Parent and not already queued.
    local PHOENIX_BURN_IN_PLACE_DURATION = Config.Phoenix.BurnInPlaceSeconds  -- seconds mobs freeze + burn visibly before going to limbo
    
    -- Phase 1 of Phoenix capture: mob catches fire + freezes in place for
    -- PHOENIX_BURN_IN_PLACE_DURATION seconds. Still in world, still targetable
    -- by towers, still damageable — but doesn't move. Once the burn timer
    -- expires, moveToPhoenixLimbo transitions to phase 2 (queue + hidden).
    --
    -- The pathDist is captured NOW (at burn start) so queue ordering reflects
    -- the mob's original position, not anything that happens during burn.
    local function startPhoenixBurn(mob, data, waypoints)
        data._phoenixBurning = true
        data._phoenixBurnUntil = os.clock() + PHOENIX_BURN_IN_PLACE_DURATION
        data._phoenixPathDist = computePathDistFromHeart(mob, data, waypoints)
        data.knockback = nil
        attachBurningEffect(mob, data)
    end
    
    -- Phase 2 of Phoenix capture: mob moves to limbo (hidden far below map)
    -- and enters the respawn queue. Called from updateMobs when the burn-in-
    -- place timer expires. Mob's current HP is captured into the queue entry
    -- (may be LESS than original if towers damaged it during the burn window).
    local function moveToPhoenixLimbo(mob, data)
        data._phoenixBurning = nil
        data._phoenixBurnUntil = nil
        data._phoenixQueued = true
        local pathDist = data._phoenixPathDist or 0
        data._phoenixPathDist = nil
    
        -- Hide in limbo: offset by queue length so multiple captures don't stack
        local limboPos = PHOENIX_LIMBO_BASE + Vector3.new(#PhoenixQueue.items * 5, 0, 0)
        mob.CFrame = CFrame.new(limboPos)
        if data.bbAnchor then
            data.bbAnchor.CFrame = CFrame.new(limboPos)
        end
        table.insert(PhoenixQueue.items, {
            mob = mob,
            data = data,
            hp = data.hp,  -- current HP (may have been damaged during burn window)
            pathDist = pathDist,
            speed = data.speed or 1,
            released = false,
        })
        -- Keep queue sorted by pathDist ascending (closest-to-heart goes first)
        table.sort(PhoenixQueue.items, function(a, b)
            if a.released ~= b.released then return not a.released and b.released end
            return a.pathDist < b.pathDist
        end)
        -- Pop the lead mob immediately. The first unreleased entry (after
        -- the sort) is the "lead" — closest to the heart. Whether the queue
        -- was previously empty, drained, or mid-wait for a spacing-based
        -- release, this newly-arrived-and-possibly-promoted lead should
        -- come back RIGHT AWAY; we only preserve spacing between mobs AFTER
        -- the lead (handled in releaseNextPhoenixMob). Setting
        -- nextReleaseAt = os.clock() kicks the next processPhoenixQueue
        -- tick into releasing the lead; spacing for subsequent mobs is
        -- recomputed there from the lead's pathDist.
        local firstUnreleased
        for _, e in ipairs(PhoenixQueue.items) do
            if not e.released then firstUnreleased = e; break end
        end
        if firstUnreleased then
            PhoenixQueue.nextReleaseAt = os.clock()
        end
    end
    
    -- Legacy entry point for capture — kicks off phase 1. Kept as the public
    -- name used by heart-arrival + capturePhoenixAOEMobs.
    local function capturePhoenixMob(mob, data, waypoints)
        startPhoenixBurn(mob, data, waypoints)
    end
    
    -- Release the next queued mob: teleport to start, restore HP, attach burn,
    -- clear queue flag. Updates nextReleaseAt for the subsequent mob.
    local function releaseNextPhoenixMob(now, waypoints)
        -- Find first unreleased entry
        local entry = nil
        local entryIdx = nil
        for i, e in ipairs(PhoenixQueue.items) do
            if not e.released then
                entry = e
                entryIdx = i
                break
            end
        end
        if not entry then return false end
    
        local mob = entry.mob
        local data = entry.data
        if not mob.Parent then
            -- Mob was destroyed while in limbo (can't really happen but defensive)
            entry.released = true
            return true
        end
        local startPos = waypoints[1].Position
        local spawnPos = startPos + Vector3.new(0, data.size / 2, 0)
        mob.CFrame = CFrame.new(spawnPos)
        data.waypointIndex = 1
        data.knockback = nil
        data.hp = entry.hp  -- restore original HP
        data._phoenixQueued = nil
        -- Restore HP bar tracking (mob update loop will reposition the anchor)
        if data.hpFill then
            data.hpFill.Size = UDim2.new(math.max(0, data.hp / data.maxHp), -2, 1, -2)
        end
        if data.hpText then
            data.hpText.Text = string.format("%d / %d", math.max(0, math.floor(data.hp)), data.maxHp)
        end
        attachBurningEffect(mob, data)
        entry.released = true
    
        -- Schedule next release based on ORIGINAL spacing.
        -- delay = (this.pathDist - prev.pathDist) / this.speed (for mobs AFTER this one)
        -- Look at the NEXT unreleased entry to compute delay.
        local nextEntry = nil
        for j = entryIdx + 1, #PhoenixQueue.items do
            if not PhoenixQueue.items[j].released then
                nextEntry = PhoenixQueue.items[j]
                break
            end
        end
        if nextEntry then
            local distGap = math.max(0, nextEntry.pathDist - entry.pathDist)
            local delay = distGap / math.max(0.1, nextEntry.speed)
            PhoenixQueue.nextReleaseAt = now + delay
        else
            PhoenixQueue.nextReleaseAt = math.huge  -- no more to release
        end
        return true
    end
    
    -- Called every frame from updateMobs: if the queue has a due mob, release it.
    local function processPhoenixQueue(now)
        if #PhoenixQueue.items == 0 then return end
        local waypoints = ctx.getWaypoints()
        if #waypoints == 0 then return end
        while now >= PhoenixQueue.nextReleaseAt do
            local released = releaseNextPhoenixMob(now, waypoints)
            if not released then break end
        end
        -- Clean up fully-released queue so we don't iterate old entries forever
        local allReleased = true
        for _, e in ipairs(PhoenixQueue.items) do
            if not e.released then allReleased = false; break end
        end
        if allReleased then
            PhoenixQueue.items = {}
            PhoenixQueue.nextReleaseAt = 0
        end
    end
    
    -- Called every frame from updateMobs: during grace, capture any mob that
    -- newly entered the AOE into the queue.
    local function capturePhoenixAOEMobs(_now, heart, waypoints)
        local heartPos = heart.Position
        local radiusSq = PHOENIX_AOE_RADIUS * PHOENIX_AOE_RADIUS
        for mob, data in pairs(ctx.activeMobs) do
            -- Skip mobs already in burn-phase-1 (_phoenixBurning) or limbo (_phoenixQueued)
            if mob.Parent and not data._phoenixQueued and not data._phoenixBurning then
                if (mob.Position - heartPos).Magnitude ^ 2 <= radiusSq then
                    capturePhoenixMob(mob, data, waypoints)
                end
            end
        end
    end
    
    -- Try to consume a Phoenix charge. Returns true if a Phoenix triggered.
    --
    -- Multi-player resolution: when several players in the same server
    -- each have a Phoenix-equipped Core tower with PhoenixReady=true,
    -- the HIGHEST-RARITY tower fires first (Mythical beats Legendary
    -- etc.); coin-flip on ties. Previously the first-found Ready tower
    -- won, which was order-dependent and felt unfair in co-op. Only
    -- one Phoenix consumes per heart-dying-moment — the other(s) stay
    -- Ready for the next near-death. EquippedRarity is the 1..5 int
    -- the attachment store writes; absent → treat as 0 (worst).
    local function tryConsumePhoenix()
        local now = os.clock()
        if now < PhoenixGrace.activeUntil then
            return true  -- grace already active from earlier trigger
        end
        local candidates = {}
        local bestRarity = 0
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local t = towerBase.Parent
            if t and t:GetAttribute("EquippedType") == "Phoenix"
                   and t:GetAttribute("PhoenixReady") == true
                   and (t:GetAttribute("PhoenixCooldown") or 0) > 0 then
                local r = t:GetAttribute("EquippedRarity") or 0
                if r > bestRarity then
                    bestRarity = r
                    table.clear(candidates)
                    table.insert(candidates, t)
                elseif r == bestRarity then
                    table.insert(candidates, t)
                end
            end
        end
        if #candidates == 0 then return false end
        local phoenixTower = candidates[math.random(1, #candidates)]
    
        -- Consume: start cooldown, open grace
        local cd = phoenixTower:GetAttribute("PhoenixCooldown") or 0
        phoenixTower:SetAttribute("PhoenixReady", false)
        phoenixTower:SetAttribute("PhoenixCdRemaining", cd)
        phoenixTower:SetAttribute("PhoenixGraceRemaining", PHOENIX_GRACE_DURATION)
    
        -- Big fire ring at heart + floor-level AOE indicator
        local heart = ctx.getHeart()
        local waypoints = ctx.getWaypoints()
        if heart then
            spawnFireVFX(heart.Position + Vector3.new(0, 1.5, 0), 3.0, 4.0)
            spawnPhoenixAOEFloorFire(heart.Position, PHOENIX_AOE_RADIUS, PHOENIX_GRACE_DURATION)
        end
    
        -- Start burn-in-place on all AOE mobs NOW. They'll transition to the
        -- limbo queue after PHOENIX_BURN_IN_PLACE_DURATION (handled in updateMobs).
        if heart and #waypoints > 0 then
            capturePhoenixAOEMobs(now, heart, waypoints)
        end
    
        PhoenixGrace.activeUntil = now + PHOENIX_GRACE_DURATION
        print(("[Waves] Phoenix consumed — cooldown %ds (AOE %d studs, %.1fs grace)"):format(
            cd, PHOENIX_AOE_RADIUS, PHOENIX_GRACE_DURATION))
        return true
    end

    local function tickPhoenixCooldowns(dt, towerList)
        -- Both cooldown and grace tick wallclock, ungated. (Earlier the cooldown
        -- ticked only during waveInProgress with gameSpeed scaling — but that
        -- meant a player watching the HUD between waves would see it freeze,
        -- which read as a bug. Wallclock + ungated matches player intuition:
        -- "the indicator counts down at the rate it shows.")
        for _, towerBase in ipairs(towerList) do
            local t = towerBase.Parent
            if t and t:GetAttribute("EquippedType") == "Phoenix" then
                -- COOLDOWN tick
                if t:GetAttribute("PhoenixReady") == false then
                    local rem = phoenixDisplayCd[t] or t:GetAttribute("PhoenixCdRemaining") or 0
                    rem = rem - dt
                    if rem <= 0 then
                        phoenixDisplayCd[t] = nil
                        t:SetAttribute("PhoenixCdRemaining", 0)
                        t:SetAttribute("PhoenixReady", true)
                    else
                        phoenixDisplayCd[t] = rem
                        local prevDisplayed = t:GetAttribute("PhoenixCdRemaining") or 0
                        local newDisplayed = math.ceil(rem)
                        if newDisplayed ~= math.ceil(prevDisplayed) then
                            t:SetAttribute("PhoenixCdRemaining", newDisplayed)
                        end
                    end
                end
    
                -- GRACE tick (wallclock, 0.1s precision write)
                local graceFloat = phoenixDisplayGrace[t] or t:GetAttribute("PhoenixGraceRemaining") or 0
                if graceFloat > 0 then
                    graceFloat = graceFloat - dt
                    if graceFloat <= 0 then
                        phoenixDisplayGrace[t] = nil
                        t:SetAttribute("PhoenixGraceRemaining", 0)
                    else
                        phoenixDisplayGrace[t] = graceFloat
                        local prevTenths = math.floor((t:GetAttribute("PhoenixGraceRemaining") or 0) * 10 + 0.5)
                        local newTenths = math.floor(graceFloat * 10 + 0.5)
                        if newTenths ~= prevTenths then
                            t:SetAttribute("PhoenixGraceRemaining", newTenths / 10)
                        end
                    end
                end
            end
        end
    end

    -- Publish
    ctx.tryConsumePhoenix     = tryConsumePhoenix
    ctx.capturePhoenixAOEMobs = capturePhoenixAOEMobs
    ctx.capturePhoenixMob     = capturePhoenixMob
    ctx.processPhoenixQueue   = processPhoenixQueue
    ctx.tickPhoenixCooldowns  = tickPhoenixCooldowns
    ctx.moveToPhoenixLimbo    = moveToPhoenixLimbo
end

return Phoenix
