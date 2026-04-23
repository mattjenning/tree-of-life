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
local Tags   = require(Shared:WaitForChild("Tags"))
local Config = require(Shared:WaitForChild("Config"))

local MobFactory = {}

-- Explicit per-map-per-stage HP for the "boss" mob (the Mold King that
-- spawns alongside wave 5 mobs on every stage). Assigned manually per the
-- 12-boss HP table — no more base×stage×map mult math for stage bosses.
-- The mult system still handles regular mobs and named map bosses.
-- Missing cell → falls back to the mult-computed value (so partial tuning
-- during Map 3 buildout doesn't break).
local STAGE_BOSS_HP = {
    [1] = { [1] = 1500,  [2] = 3500,   [3] = 7000   },   -- Crook
    [2] = { [1] = 22000, [2] = 35000,  [3] = 55000  },   -- Climbing
    [3] = { [1] = 100000,[2] = 150000, [3] = 220000 },   -- Canopy
}

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

        -- Map 2 difficulty: +HP / +speed on top of stage multipliers. Bosses
        -- are exempt so we don't stack with bossHpMult. Tuned in Config.Map2.
        -- When map 3 comes online, it'll apply its own multipliers here.
        local mapHpMult, mapSpeedMult = 1.0, 1.0
        local mapId = (ctx.StageState and ctx.StageState.currentMapId) or 1
        if mapId == 2 and not isFinalBoss then
            local d = Config.Map2 and Config.Map2.Difficulty
            if d then
                if isStageBoss then
                    -- Stage boss gets only the boss-specific multiplier so
                    -- it doesn't stack with the regular HpMult (which would
                    -- make the Mold King crushing).
                    mapHpMult = d.BossHpMult or 1.0
                else
                    -- Regular mobs: baseline × per-stage bump. Each stage
                    -- applies its own factor on top of the flat HpMult, so
                    -- early-map-2 mobs are meaningfully tankier than late
                    -- (the player has less firepower on stage 1 than 3).
                    local curStage = (ctx.StageState and ctx.StageState.currentStage) or 1
                    local byStage  = d.HpMultByStage or {}
                    local stageBump = byStage[curStage] or 1.0
                    mapHpMult    = (d.HpMult or 1.0) * stageBump
                    mapSpeedMult = d.SpeedMult or 1.0
                end
            end
        elseif mapId == 1 and not isFinalBoss then
            -- Map 1 sits below baseline difficulty to compensate for
            -- (1) the starter Power tower's tighter range (24 vs legacy 30)
            -- and (2) the removed first-tower free-upgrade flow (was 0.85,
            -- now another 10% off → 0.765). Applies to regulars (stage
            -- bosses now use the explicit STAGE_BOSS_HP table, final boss
            -- uses its manually-set def.hp).
            mapHpMult = 0.765
            -- Stage 3 is a spike point: regular mobs lean in +10%.
            local curStage = (ctx.StageState and ctx.StageState.currentStage) or 1
            if curStage >= 3 then
                mapHpMult = mapHpMult * 1.10
            end
        end

        local scaledHp
        -- Stage boss HP: explicit override table first (manual per-boss
        -- tuning), fall back to mult computation if cell is missing.
        local stageBossOverride
        if isStageBoss then
            local mapTable = STAGE_BOSS_HP[mapId]
            stageBossOverride = mapTable and mapTable[ctx.StageState.currentStage]
        end
        if stageBossOverride then
            -- Still multiply by playerCount so co-op scales up.
            scaledHp = math.floor(stageBossOverride * playerCount + 0.5)
        else
            scaledHp = math.floor(def.hp * playerCount * effectiveWaveMult
                * stageHpMult * mapHpMult + 0.5)
        end

        -- Round boss HP to readable landmark numbers:
        --   Stage boss (Mold King etc): nearest 100
        --   Map boss / final boss (Pickle Lord, spider, bird): nearest 1000
        -- Uses math.floor(x/N + 0.5)*N for nearest-N (NOT floor-to-N) so
        -- stats don't always drift downward from mult stacking.
        if isFinalBoss then
            scaledHp = math.max(1000, math.floor(scaledHp / 1000 + 0.5) * 1000)
        elseif isStageBoss and not stageBossOverride then
            scaledHp = math.max(100, math.floor(scaledHp / 100 + 0.5) * 100)
        end
        local scaledSpeed = def.speed * stageSpeedMult * mapSpeedMult
        if def.isFinal then scaledSpeed = scaledSpeed * 1.3 end

        -- Spider + spiderling: block body. Default other mobs stay Ball.
        local isSpiderShape = def.isCanopySpider or mobType == "spiderling"
        local mob = Instance.new("Part")
        mob.Name = "Mob_" .. mobType
        if isSpiderShape then
            mob.Shape = Enum.PartType.Block
            mob.Size = Vector3.new(def.size, def.size * 0.5, def.size)
        else
            mob.Shape = Enum.PartType.Ball
            mob.Size = Vector3.new(def.size, def.size, def.size)
        end
        mob.Material = def.isFinal and Enum.Material.Neon or Enum.Material.SmoothPlastic
        mob.Color = def.color
        mob.CFrame = CFrame.new(spawnPart.Position + Vector3.new(0, def.size / 2, 0))
        mob.Anchored = true
        mob.CanCollide = false
        -- CanQuery=false so ClickDetector raycasts pass through the mob to
        -- whatever's behind it. Without this, the spider boss (size 15) can
        -- occlude a webbed Core tower, eating the click. Mob targeting is
        -- screen-space proximity on the client (not raycast-based), so
        -- turning this off doesn't break target selection.
        mob.CanQuery = false
        mob.CastShadow = false
        mob.Parent = ctx.tdRoom
        CollectionService:AddTag(mob, Tags.Mob)

        -- 8 leg Parts that follow the spider body each Heartbeat. Anchored
        -- + manual CFrame sync (not WeldConstraint) because WeldConstraint
        -- on an Anchored root doesn't reliably drive Anchored children
        -- when the body CFrame is scripted (as mob update loops do).
        -- Offsets are captured in local-space so legs rotate with the body
        -- too (not just translate).
        if isSpiderShape then
            local RunService = game:GetService("RunService")
            local legLen = def.size * 0.9
            local legThick = math.max(0.35, def.size * 0.09)
            local bodyHalfW = mob.Size.X * 0.5
            local legs = {}  -- list of {leg, localCFrame}
            for i = 1, 8 do
                local angle = (i / 8) * math.pi * 2
                local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
                -- Local-space position relative to the body center:
                local localPos = Vector3.new(
                    dir.X * (bodyHalfW + legLen * 0.5),
                    -def.size * 0.2,
                    dir.Z * (bodyHalfW + legLen * 0.5))
                -- Local-space orientation — Z-axis points outward.
                local localCF = CFrame.lookAt(localPos, localPos + dir)
                local leg = Instance.new("Part")
                leg.Name = "SpiderLeg"
                leg.Size = Vector3.new(legThick, legThick, legLen)
                leg.Color = def.color:Lerp(Color3.new(0, 0, 0), 0.3)
                leg.Material = mob.Material
                leg.Anchored = true
                leg.CanCollide = false
                leg.CanQuery = false  -- pass clicks through to towers behind
                leg.CastShadow = false
                leg.CFrame = mob.CFrame * localCF
                leg.Parent = mob
                legs[i] = { leg = leg, localCF = localCF }
            end
            -- Per-frame CFrame sync: recompute each leg from the body's
            -- current CFrame. Disconnects when the body is destroyed.
            local conn
            conn = RunService.Heartbeat:Connect(function()
                if not mob.Parent then
                    conn:Disconnect()
                    return
                end
                local bodyCF = mob.CFrame
                for _, entry in ipairs(legs) do
                    if entry.leg.Parent then
                        entry.leg.CFrame = bodyCF * entry.localCF
                    end
                end
            end)
        end
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
