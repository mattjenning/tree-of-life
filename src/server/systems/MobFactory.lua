--[[
    MobFactory.lua — Mob creation + the shared activeMobs registry.

    Owns:
      - ctx.activeMobs     : [mob instance] → data table shared across
                             frames. Fields: hp, maxHp, speed, damage,
                             waypointIndex, size, hpFill, hpText, bbAnchor,
                             plus transient ones added by other modules
                             (knockback, stunUntil, _phoenixQueued, etc.).

      - ctx.makeMob(mobType, waypoints, hpMult) → Part | nil
          Creates a mob Part, tags it Mob (+ FinalBoss for the pickle lord),
          attaches an HP billboard, registers it in activeMobs. Returns the
          Part so callers can stash it (e.g. FinalBossState.instance).

      - ctx.countActiveMobs() → int
          Fast count of live mobs.

      - ctx.clearAllMobs()
          Destroys every mob Part, empties the registry IN PLACE (so
          references held in other modules stay live), clears Phoenix
          queue + grace state.

    HP scaling invariant (per CLAUDE.md — DO NOT change without balance review):
      scaledHp = def.hp × playerCount × effectiveWaveMult × stageHpMult
      with effectiveWaveMult = 1.0 for stage bosses (waveMult only applies
      to regular mobs + final boss). Final boss gets 1.3× speed.

    setup(ctx) reads (late-resolved at call time):
      ctx.MOB_TYPES, ctx.Stages, ctx.StageState
      ctx.getSpawnPart        (world accessor)
      ctx.tdRoom              (mob Part parent)
      ctx.PhoenixGrace, ctx.PhoenixQueue
                              (cleared by clearAllMobs; published by
                              the orchestrator for now, will move to
                              Phoenix.lua in commit 6 without changing
                              the interface)

    And publishes:
      ctx.activeMobs, ctx.makeMob, ctx.countActiveMobs, ctx.clearAllMobs
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags = require(Shared:WaitForChild("Tags"))

local MobFactory = {}

function MobFactory.setup(ctx)
    local activeMobs = {}  -- [mob instance] = {hp, maxHp, speed, damage, waypointIndex, ...}
    ctx.activeMobs = activeMobs

    local function makeMob(mobType, waypoints, hpMult)
        local def = ctx.MOB_TYPES[mobType]
        local spawnPart = ctx.getSpawnPart()
        if not spawnPart or #waypoints == 0 then return nil end

        -- HP and speed scaling rules:
        --   Regular mobs (basic/fast/tank): scale by stage hpMult + speedMult
        --   Stage boss (Mold King): scale by stage bossHpMult only (NOT hpMult)
        --   Final boss (Pickle Lord): skip stage scaling entirely; +30% speed
        local playerCount = math.max(1, #Players:GetPlayers())
        local waveMult = hpMult or 1.0
        local isStageBoss = (mobType == "boss") and not def.isFinal
        local isFinalBoss = (mobType == "finalboss") or def.isFinal
        local stageHpMult, stageSpeedMult
        local s = ctx.Stages[ctx.StageState.currentStage]
        if isFinalBoss then
            stageHpMult, stageSpeedMult = 1.0, 1.0
        elseif isStageBoss then
            stageHpMult    = (s and s.bossHpMult) or 1.0
            stageSpeedMult = 1.0  -- stage boss speed isn't bumped
        else
            stageHpMult    = (s and s.hpMult)    or 1.0
            stageSpeedMult = (s and s.speedMult) or 1.0
        end
        -- Bosses ignore waveMult (the per-wave HP ramp). bossHpMult is the
        -- sole boss scaling knob. Regular mobs and the final boss still use
        -- the wave-specific multiplier (which is 1.0 for the final boss's
        -- synthetic "wave 0" anyway).
        local effectiveWaveMult = (isStageBoss) and 1.0 or waveMult
        local scaledHp = math.floor(def.hp * playerCount * effectiveWaveMult * stageHpMult + 0.5)
        local scaledSpeed = def.speed * stageSpeedMult
        if def.isFinal then scaledSpeed = scaledSpeed * 1.3 end

        local mob = Instance.new("Part")
        mob.Name = "Mob_" .. mobType
        mob.Shape = Enum.PartType.Ball
        mob.Size = Vector3.new(def.size, def.size, def.size)
        mob.Material = def.isFinal and Enum.Material.Neon or Enum.Material.SmoothPlastic
        mob.Color = def.color
        mob.CFrame = CFrame.new(spawnPart.Position + Vector3.new(0, def.size / 2, 0))
        mob.Anchored = true
        mob.CanCollide = false
        mob.CastShadow = false
        mob.Parent = ctx.tdRoom
        CollectionService:AddTag(mob, Tags.Mob)
        if def.isFinal then
            CollectionService:AddTag(mob, Tags.FinalBoss)
            -- Purple point light
            local light = Instance.new("PointLight")
            light.Color = Color3.fromRGB(180, 60, 220)
            light.Brightness = 4
            light.Range = 30
            light.Parent = mob
        end

        -- HP bar above the mob
        local bbAnchor = Instance.new("Part")
        bbAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
        bbAnchor.Transparency = 1
        bbAnchor.CanCollide = false
        bbAnchor.Anchored = true
        bbAnchor.CFrame = mob.CFrame + Vector3.new(0, def.size * 0.9, 0)
        bbAnchor.Parent = mob

        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.new(0, 80, 0, 18)
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = 200
        bb.Parent = bbAnchor

        local hpBg = Instance.new("Frame")
        hpBg.Size = UDim2.fromScale(1, 1)
        hpBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
        hpBg.BackgroundTransparency = 0.3
        hpBg.BorderSizePixel = 0
        hpBg.Parent = bb

        local hpFill = Instance.new("Frame")
        hpFill.Size = UDim2.new(1, -2, 1, -2)
        hpFill.Position = UDim2.new(0, 1, 0, 1)
        hpFill.BackgroundColor3 = Color3.fromRGB(240, 80, 80)
        hpFill.BorderSizePixel = 0
        hpFill.Parent = hpBg

        local hpText = Instance.new("TextLabel")
        hpText.Size = UDim2.fromScale(1, 1)
        hpText.BackgroundTransparency = 1
        hpText.Text = string.format("%d / %d", scaledHp, scaledHp)
        hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
        hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        hpText.TextStrokeTransparency = 0
        hpText.Font = Enum.Font.FredokaOne
        hpText.TextSize = 12
        hpText.ZIndex = 2
        hpText.Parent = hpBg

        activeMobs[mob] = {
            hp = scaledHp,
            maxHp = scaledHp,
            speed = scaledSpeed,
            damage = scaledHp,  -- damage to heart = mob's max HP (beefier mobs hurt more)
            waypointIndex = 1,
            size = def.size,
            hpFill = hpFill,
            hpText = hpText,
            bbAnchor = bbAnchor,
        }
        return mob
    end

    local function countActiveMobs()
        local n = 0
        for _ in pairs(activeMobs) do n = n + 1 end
        return n
    end

    -- Destroys every mob Part and clears the registry IN PLACE — crucial
    -- because ctx.activeMobs is shared by reference with other modules.
    -- Reassigning (activeMobs = {}) would leave those modules holding
    -- stale table references while the orchestrator moves on with a
    -- fresh table. In-place clear keeps one canonical table forever.
    local function clearAllMobs()
        for mob, data in pairs(activeMobs) do
            if data.stunStars then
                for _, star in ipairs(data.stunStars) do star:Destroy() end
            end
            if mob.Parent then mob:Destroy() end
            activeMobs[mob] = nil
        end
        -- Also clear the Phoenix respawn queue — mobs in there were destroyed above
        if ctx.PhoenixQueue then
            ctx.PhoenixQueue.items = {}
            ctx.PhoenixQueue.nextReleaseAt = 0
        end
        if ctx.PhoenixGrace then
            ctx.PhoenixGrace.activeUntil = 0
        end
    end

    ctx.makeMob         = makeMob
    ctx.countActiveMobs = countActiveMobs
    ctx.clearAllMobs    = clearAllMobs
end

return MobFactory
