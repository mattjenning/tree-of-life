--[[
    Effects.lua — Combat VFX + secondary hit effects (knockback, stun).

    Owns the visible pyrotechnics the player sees when a tower fires and
    when a mob dies to a Detonator attachment, plus the logic that rolls
    stun + knockback procs on tower hits.

    NOT in this module: Phoenix VFX (spawnFireVFX, spawnPhoenixAOEFloorFire)
    stay with Phoenix mechanics in commit 6 since they're Phoenix-exclusive.

    setup(ctx) reads (late-resolved at call time):
      ctx.tdRoom              -- parent for the temp VFX parts
      ctx.activeMobs          -- mob registry (for applyHitEffects lookup)
      ctx.WaveConfig          -- proc chances + knockback slide time
      ctx.getWaypoints        -- knockback direction (reverse of travel)
      ctx.getSpawnPart        -- knockback clamp (don't slide past spawn)
      ctx.gameSpeed           -- stun uses game-time, not wallclock

    And publishes:
      ctx.spawnDamageNumber(worldPos, amount)
      ctx.fireBolt(fromPos, toPos, color)
      ctx.spawnAoeBurst(centerPos, radius)
      ctx.spawnDetonatorBurst(centerPos, radius)
      ctx.applyHitEffects(towerModel, primaryMob) → procCount
]]

local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local StatLedger = require(script.Parent:WaitForChild("StatLedger"))

local Effects = {}

function Effects.setup(ctx)
    local function spawnDamageNumber(worldPos, amount)
        -- Skip damage popups above 20× speed (math-only mode) OR
        -- when the Balance Studio VISUALS toggle is off. Per
        -- Matthew 2026-04-27: damage popups are part of the
        -- "off, turn off tower shots, mob bodies, and damage"
        -- VISUALS-OFF rule; default is off.
        if ctx.gameSpeed and ctx.gameSpeed > 20 then return end
        if game:GetService("Workspace"):GetAttribute("InfiniteVisuals") ~= true then
            return
        end

        local anchor = Instance.new("Part")
        anchor.Size = Vector3.new(0.1, 0.1, 0.1)
        anchor.Transparency = 1
        anchor.CanCollide = false
        anchor.Anchored = true
        anchor.CFrame = CFrame.new(worldPos + Vector3.new(
            math.random(-10, 10) * 0.1, 2, math.random(-10, 10) * 0.1))
        anchor.Parent = ctx.tdRoom

        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.fromOffset(60, 30)
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = 250
        bb.Parent = anchor

        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Text = "-" .. math.floor(amount)
        label.TextColor3 = Color3.fromRGB(255, 230, 100)
        label.TextStrokeColor3 = Color3.fromRGB(80, 20, 0)
        label.TextStrokeTransparency = 0
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 22
        label.Parent = bb

        -- Animate: float up and fade. Uses wallclock intentionally — damage
        -- numbers are VFX, not game-time-scaled gameplay.
        task.spawn(function()
            local startTime = os.clock()
            local duration = 0.8
            local startPos = anchor.Position
            while true do
                local elapsed = os.clock() - startTime
                local t = elapsed / duration
                if t >= 1 then break end
                anchor.CFrame = CFrame.new(startPos + Vector3.new(0, t * 3, 0))
                label.TextTransparency = t
                label.TextStrokeTransparency = t
                RunService.Heartbeat:Wait()
            end
            anchor:Destroy()
        end)
    end

    local function fireBolt(fromPos, toPos, color)
        -- Math-only mode OR VISUALS-OFF: skip the visual bolt.
        -- Damage is applied by the caller separately; this is
        -- purely cosmetic. Per Matthew 2026-04-27 visuals-off
        -- rule includes tower shots.
        if ctx.mathOnlyMode then return end
        if game:GetService("Workspace"):GetAttribute("InfiniteVisuals") ~= true then
            return
        end
        local mid = (fromPos + toPos) * 0.5
        local dir = toPos - fromPos
        local len = dir.Magnitude
        local bolt = Instance.new("Part")
        bolt.Name = "Bolt"
        bolt.Size = Vector3.new(0.3, 0.3, len)
        bolt.CFrame = CFrame.lookAt(mid, toPos)
        bolt.Anchored = true
        bolt.CanCollide = false
        bolt.CastShadow = false
        bolt.Material = Enum.Material.Neon
        bolt.Color = color or Color3.fromRGB(255, 200, 120)
        bolt.Transparency = 0.1
        bolt.Parent = ctx.tdRoom
        Debris:AddItem(bolt, 0.12)
    end

    -- AOE burst: short-lived expanding sphere at the target position.
    -- Skipped in math-only mode — damage application doesn't depend
    -- on this visual; the caller already applies AOE hits before
    -- spawning the burst.
    local function spawnAoeBurst(centerPos, radius)
        if ctx.mathOnlyMode then return end
        if game:GetService("Workspace"):GetAttribute("InfiniteVisuals") ~= true then
            return
        end
        local burst = Instance.new("Part")
        burst.Name = "AoeBurst"
        burst.Shape = Enum.PartType.Ball
        burst.Size = Vector3.new(1, 1, 1)
        burst.Anchored = true
        burst.CanCollide = false
        burst.CastShadow = false
        burst.Material = Enum.Material.Neon
        burst.Color = Color3.fromRGB(255, 180, 100)
        burst.Transparency = 0.2
        burst.CFrame = CFrame.new(centerPos)
        burst.Parent = ctx.tdRoom

        task.spawn(function()
            local startTime = os.clock()
            local duration = 0.25
            local maxDiameter = radius * 2
            while true do
                local elapsed = os.clock() - startTime
                local t = elapsed / duration
                if t >= 1 then break end
                local d = 1 + (maxDiameter - 1) * t
                burst.Size = Vector3.new(d, d, d)
                burst.Transparency = 0.2 + 0.7 * t
                RunService.Heartbeat:Wait()
            end
            burst:Destroy()
        end)
    end

    -- Detonator burst: visually distinct from spawnAoeBurst so players can
    -- tell Detonator-attachment explosions apart from regular AOE-special
    -- area damage. Style: brief bright-yellow core flash + a ring of red
    -- "shrapnel" cubes that fly outward and fade. Faster and more violent
    -- than the soft orange AOE bloom.
    local function spawnDetonatorBurst(centerPos, radius)
        local core = Instance.new("Part")
        core.Name = "DetonatorCore"
        core.Shape = Enum.PartType.Ball
        core.Size = Vector3.new(2, 2, 2)
        core.Anchored = true
        core.CanCollide = false
        core.CastShadow = false
        core.Material = Enum.Material.Neon
        core.Color = Color3.fromRGB(255, 240, 120)  -- bright yellow
        core.Transparency = 0
        core.CFrame = CFrame.new(centerPos)
        core.Parent = ctx.tdRoom

        -- Shrapnel: 8 small cubes flung outward in a ring
        local shrapnel = {}
        local SHRAPNEL_COUNT = Config.Effects.ShrapnelCount
        for i = 1, SHRAPNEL_COUNT do
            local s = Instance.new("Part")
            s.Name = "DetonatorShrapnel"
            s.Size = Vector3.new(0.6, 0.6, 0.6)
            s.Anchored = true
            s.CanCollide = false
            s.CastShadow = false
            s.Material = Enum.Material.Neon
            s.Color = Color3.fromRGB(255, 90, 60)  -- red-orange
            s.Transparency = 0
            s.CFrame = CFrame.new(centerPos)
            s.Parent = ctx.tdRoom
            local angle = (i - 1) * (math.pi * 2 / SHRAPNEL_COUNT)
            shrapnel[i] = {
                part = s,
                dir = Vector3.new(math.cos(angle), 0.2, math.sin(angle)),
            }
        end

        task.spawn(function()
            local startTime = os.clock()
            local duration = 0.35
            while true do
                local elapsed = os.clock() - startTime
                local t = elapsed / duration
                if t >= 1 then break end
                local coreScale = 2 + (radius * 0.5) * t
                core.Size = Vector3.new(coreScale, coreScale, coreScale)
                core.Transparency = t
                for _, s in ipairs(shrapnel) do
                    local distance = radius * t
                    s.part.CFrame = CFrame.new(centerPos + s.dir * distance)
                    s.part.Transparency = t
                end
                RunService.Heartbeat:Wait()
            end
            core:Destroy()
            for _, s in ipairs(shrapnel) do s.part:Destroy() end
        end)
    end

    -- applyHitEffects(towerModel, primaryMob) → procCount
    --   Rolls stun and knockback (each independent chance per hit). Applies
    --   the status effect on each successful proc and returns the TOTAL
    --   number of procs (0, 1, or 2). Callers in Towers.updateTowers and
    --   Damage.damageMob use the return value to deal one extra hit of
    --   normal attack damage per proc ("on a stun/knockback proc, do
    --   another normal attack damage hit").
    --
    --   CC values are the SAME for bosses and regular mobs. The previous
    --   2x-for-non-bosses multiplier was removed when stun/knockback gained
    --   the extra-damage-per-proc behavior — the damage component now does
    --   most of the work, so symmetric CC durations keep the math simple.
    local function applyHitEffects(towerModel, primaryMob)
        if not primaryMob then return 0 end
        local data = ctx.activeMobs[primaryMob]
        if not data then return 0 end

        local knockback = towerModel:GetAttribute("Knockback")
        local stunDur   = towerModel:GetAttribute("StunDuration")
        -- Per-tower proc chances (stacked via upgrade picks). Fall back to
        -- the global WaveConfig defaults if the tower predates the new
        -- chance-stack system (tower would have Knockback/StunDuration
        -- attributes set but no matching *Chance attribute).
        local knockbackChance = towerModel:GetAttribute("KnockbackChance")
            or ctx.WaveConfig.knockbackTriggerChance
        local stunChance = towerModel:GetAttribute("StunChance")
            or ctx.WaveConfig.stunTriggerChance
        local procCount = 0

        -- Knockback: slide back ALONG THE PATH (not in a straight world-
        -- space line). Previous implementation pushed `-dir * distance`
        -- which shot mobs through corners and out of the map on zigzag
        -- paths. New approach walks the path segments backward,
        -- consuming knockback distance, and also walks the mob's
        -- waypointIndex back so pathing resumes from the correct
        -- segment after the slide.
        if knockback and math.random() < knockbackChance then
            local waypoints = ctx.getWaypoints()
            local curIdx = data.waypointIndex or 1
            local curWp = waypoints[curIdx]
            if curWp and curIdx > 1 then
                local remaining = knockback
                local walkerPos = primaryMob.Position
                local walkerTargetIdx = curIdx - 1  -- next waypoint we're walking back toward
                while remaining > 0 and walkerTargetIdx >= 1 do
                    local target = waypoints[walkerTargetIdx].Position
                    local toTarget = target - walkerPos
                    toTarget = Vector3.new(toTarget.X, 0, toTarget.Z)  -- horizontal only
                    local dist = toTarget.Magnitude
                    if dist <= remaining then
                        walkerPos = target
                        remaining = remaining - dist
                        walkerTargetIdx = walkerTargetIdx - 1
                    else
                        walkerPos = walkerPos + toTarget.Unit * remaining
                        remaining = 0
                    end
                end
                -- Post-slide waypointIndex is the segment we ended up on.
                -- walkerTargetIdx is the LAST waypoint we stepped toward;
                -- if we stopped mid-segment, that waypoint is still our
                -- next target (so waypointIndex stays the same as its
                -- value). If we consumed the whole way back, we clamp at
                -- waypoint 1. MobUpdate's path-follow code reads
                -- waypointIndex as "next waypoint to reach."
                local newWpIdx = math.max(1, walkerTargetIdx + 1)
                data.waypointIndex = newWpIdx
                data.knockback = {
                    fromPos = primaryMob.Position,
                    toPos = Vector3.new(walkerPos.X, primaryMob.Position.Y, walkerPos.Z),
                    startTime = os.clock(),
                    duration = ctx.WaveConfig.knockbackSlideTime,
                }
                -- StatLedger: record the actual studs slid (knockback
                -- minus any unconsumed remaining at end of segment walk).
                StatLedger.recordKnockback(towerModel, knockback - remaining)
                procCount = procCount + 1
            end
        end

        -- Stun. Duration in game-seconds, set against ctx.gameTime
        -- (the simulated game-clock) so substeps inside a single
        -- Heartbeat don't all see the stun as active across 0 ms
        -- of wallclock. Was wallclock-based — broke at high speed.
        if stunDur and stunDur > 0 and math.random() < stunChance then
            data.stunUntil = (ctx.gameTime or 0) + stunDur
            -- StatLedger: stunDur is in GAME-seconds (the spec's unit
            -- for tier-list comparison) — pass through directly.
            StatLedger.recordStun(towerModel, stunDur)
            procCount = procCount + 1
        end

        return procCount
    end

    -- Publish
    ctx.spawnDamageNumber   = spawnDamageNumber
    ctx.fireBolt            = fireBolt
    ctx.spawnAoeBurst       = spawnAoeBurst
    ctx.spawnDetonatorBurst = spawnDetonatorBurst
    ctx.applyHitEffects     = applyHitEffects
end

return Effects
