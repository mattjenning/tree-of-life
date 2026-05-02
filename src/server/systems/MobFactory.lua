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
      scaledHp = def.hp × coopHpScale × effectiveWaveMult × stageHpMult
                 (coopHpScale = 1 + (players - 1) * 0.8)
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
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags   = require(Shared:WaitForChild("Tags"))
local Config = require(Shared:WaitForChild("Config"))
local ZombieRig = require(script.Parent.Parent:WaitForChild("world"):WaitForChild("ZombieRig"))

local MobFactory = {}

-- Mob types that get a Zombie + cardboard-pickle rig as their visual.
-- Bosses (boss / spider / spiderling / bird / finalboss) keep their
-- original geometry (Mold King is a separate model entirely; spider boss
-- has the 8-leg sync; bird has its own custom rig). Per Matthew
-- 2026-05-02: replace every NON-boss mob with the zombie/pickle look.
local ZOMBIE_VARIANT_TYPES = {
    basic = true,
    fast  = true,
    tank  = true,
}

-- Attach a scaled ZombieRig to an existing anchored mob Part. The mob
-- Part itself stays as the simulation entity (CFrame-driven by
-- MobUpdate, anchored, owns HP/targeting attributes). The rig HRP
-- WeldConstraints to the mob Part so the rig follows it through every
-- CFrame update; rig limbs are un-anchored so the Humanoid's Animator
-- can drive them via Motor6D animations.
--
-- Returns the rig Model (parented to the mob Part — when the mob is
-- destroyed in clearAllMobs, the rig goes with it automatically).
local function attachZombieRig(mob, mobType)
    local scale = (Config.ZombieScales and Config.ZombieScales[mobType])
                  or Vector3.new(1, 1, 1)
    local rig = ZombieRig.build(scale)

    -- Position rig at mob position. PivotTo translates the entire rig
    -- so the PrimaryPart (HRP) lands at mob.CFrame.
    rig:PivotTo(mob.CFrame)

    -- Weld rig HRP to the anchored mob Part so the rig rides along
    -- when MobUpdate sets mob.CFrame each frame. Anchored mob + welded
    -- HRP keeps the rig in place; un-anchored limbs let the Animator
    -- drive Motor6Ds for the walk animation.
    local hrp = rig:FindFirstChild("HumanoidRootPart")
    if hrp then
        local weld = Instance.new("WeldConstraint")
        weld.Part0 = mob
        weld.Part1 = hrp
        weld.Parent = hrp
    end

    -- Force every rig BasePart un-anchored — Humanoid + Motor6Ds can't
    -- drive anchored parts. anchorRoot in ZombieRig.build was tuned for
    -- the Animation Editor's "all anchored = error" check; we override
    -- here for runtime spawn since the mob Part holds the assembly via
    -- the weld.
    for _, p in ipairs(rig:GetDescendants()) do
        if p:IsA("BasePart") then
            p.Anchored = false
            p.CanCollide = false
            p.CanQuery = false      -- pass clicks through to towers behind
            p.CastShadow = false    -- save fillrate at scale
        end
    end

    -- Load + play the walk animation on the rig's Humanoid.
    local walkId = Config.ZombieAnimations
                   and Config.ZombieAnimations.Stage
                   and Config.ZombieAnimations.Stage.Walk
    if walkId and walkId ~= "" then
        local hum = rig:FindFirstChildOfClass("Humanoid")
        if hum then
            -- Animator may auto-create when Humanoid is parented; ensure
            -- it exists explicitly so LoadAnimation doesn't no-op.
            local animator = hum:FindFirstChildOfClass("Animator")
            if not animator then
                animator = Instance.new("Animator")
                animator.Parent = hum
            end
            local anim = Instance.new("Animation")
            anim.AnimationId = walkId
            local ok, track = pcall(function()
                return animator:LoadAnimation(anim)
            end)
            if ok and track then
                track.Looped = true
                track.Priority = Enum.AnimationPriority.Movement
                track:Play()
            end
        end
    end

    rig.Parent = mob
    return rig
end

-- Stage-boss HP table (manually assigned per boss, not computed via mults).
-- Lives in Config.BossHp.StageByMap alongside other boss/difficulty tuning.
-- Aliased here so the hot inner loop doesn't re-index Config every spawn.
local STAGE_BOSS_HP = Config.BossHp and Config.BossHp.StageByMap or {}

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
        -- Co-op HP scaling: each extra player adds 0.8× the base HP
        -- (not 1.0×). 2 players = 1.8× instead of 2×, 3 players = 2.6×.
        -- Reasoning: two people focus-fire the same target and the second
        -- gun isn't worth a full doubling of HP; the gentler curve keeps
        -- boss fights from dragging even when the roster grows.
        local playerCount = math.max(1, #Players:GetPlayers())
        local coopHpScale = 1 + (playerCount - 1) * 0.8
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

        -- Per-map difficulty multipliers: +HP / +speed on top of stage
        -- multipliers. Bosses are exempt so we don't stack with bossHpMult.
        -- Tuned per-map in Config.MapN.Difficulty.
        local mapHpMult, mapSpeedMult = 1.0, 1.0
        local mapId = (ctx.StageState and ctx.StageState.currentMapId) or 1
        local function applyMapDifficulty(d)
            if not d then return end
            if isStageBoss then
                -- Stage boss gets only the boss-specific multiplier so it
                -- doesn't stack with regular HpMult (would be crushing).
                mapHpMult = d.BossHpMult or 1.0
            else
                -- Regular mobs: baseline × per-stage bump. Earlier stages
                -- apply harder bumps because the player's firepower hasn't
                -- caught up to the map yet.
                local curStage = (ctx.StageState and ctx.StageState.currentStage) or 1
                local byStage  = d.HpMultByStage or {}
                local stageBump = byStage[curStage] or 1.0
                mapHpMult    = (d.HpMult or 1.0) * stageBump
                mapSpeedMult = d.SpeedMult or 1.0
            end
        end
        if mapId == 3 and not isFinalBoss then
            applyMapDifficulty(Config.Map3 and Config.Map3.Difficulty)
        elseif mapId == 2 and not isFinalBoss then
            applyMapDifficulty(Config.Map2 and Config.Map2.Difficulty)
        elseif mapId == 1 and not isFinalBoss then
            -- Map 1 sits below baseline difficulty to compensate for
            -- (1) the starter Power tower's tighter range (24 vs legacy 30)
            -- and (2) the removed first-tower free-upgrade flow. Stacked
            -- reductions: 0.85 (legacy) × 0.9 (v5.11 across-the-board cut)
            -- ≈ 0.6885. Applies to regulars (stage bosses now use the
            -- explicit STAGE_BOSS_HP table, final boss uses def.hp).
            mapHpMult = 0.6885
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
            scaledHp = math.floor(stageBossOverride * coopHpScale + 0.5)
        else
            scaledHp = math.floor(def.hp * coopHpScale * effectiveWaveMult
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
        -- Run-difficulty hook (roadmap: project_difficulty_levels.md).
        -- Workspace.RunDifficultyMult is published by the future
        -- difficulty-tier UI at run-start; defaults to 1.0 (no change).
        -- Applied AFTER landmark rounding so boss HPs stay multiples
        -- of 1000/100 in display, then scale by the chosen tier.
        local runDiff = Workspace:GetAttribute("RunDifficultyMult")
        if type(runDiff) == "number" and runDiff > 0 and runDiff ~= 1.0 then
            scaledHp = math.max(1, math.floor(scaledHp * runDiff + 0.5))
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
        -- VISUALS gate: when Workspace.InfiniteVisuals is false
        -- (default), mob bodies spawn invisible. Game logic (HP,
        -- targeting, damage, movement) is unaffected — only the
        -- render visibility is suppressed. Per Matthew 2026-04-27:
        -- "remove mob visuals completely for now."
        if Workspace:GetAttribute("InfiniteVisuals") ~= true then
            mob.Transparency = 1
        end
        mob.Parent = ctx.tdRoom
        -- Mirror data.hp onto the part's Health/MaxHealth attributes so
        -- consumers that read attributes (broadcastWaveState's boss HP
        -- lookup, the BillboardGui-text path on standalone mobs, the dev
        -- STATS panel) see fresh values. damageMob keeps both data.hp
        -- AND the attribute in sync per-hit.
        mob:SetAttribute("MaxHealth", scaledHp)
        mob:SetAttribute("Health", scaledHp)
        -- Stamp the mob type for downstream consumers. Currently
        -- read by StatLedger.recordDamage to bucket per-tower damage
        -- by mob type (Balance Studio's "% damage to tank vs basic
        -- vs fast" panel). Per Matthew 2026-04-27.
        mob:SetAttribute("MobType", mobType)
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
            -- FinalBoss tag is the HUD's "track this mob's HP for the
            -- boss bar" hook — escorts (spiderlings) get isFinal for
            -- HP-scaling exemption but should NOT pollute that lookup.
            -- Without this gate, broadcastWaveState's tag-fallback
            -- could pick a spiderling over the actual Web Weaver.
            if not def.isEscort then
                CollectionService:AddTag(mob, Tags.FinalBoss)
            end
            -- Purple point light (escorts glow too — visual cohesion).
            local light = Instance.new("PointLight")
            light.Color = Color3.fromRGB(180, 60, 220)
            light.Brightness = 4
            light.Range = 30
            light.Parent = mob
        end

        -- ZOMBIE-RIG VISUAL — non-boss mobs get a scaled R6 zombie +
        -- cardboard-pickle mask + walk animation as their visible body.
        -- Mob Part stays as the simulation entity (anchored, CFrame-
        -- driven by MobUpdate, owns HP/targeting attributes); the rig
        -- rides along via WeldConstraint between mob Part and rig HRP.
        -- Per Matthew 2026-05-02: basic = small / fast = tall thin /
        -- tank = beefy. Scales come from Config.ZombieScales.
        --
        -- We force mob.Transparency = 1 on this branch so the simple
        -- ball/block geometry doesn't overlap the rig when the
        -- InfiniteVisuals debug toggle is on (the visuals gate earlier
        -- only hides when InfiniteVisuals != true).
        if ZOMBIE_VARIANT_TYPES[mobType] then
            mob.Transparency = 1
            attachZombieRig(mob, mobType)
        end

        -- HP bar above the mob — SKIPPED when VISUALS toggle is
        -- off, since the entire BillboardGui (anchor + frames +
        -- text label, plus the per-Heartbeat anchor CFrame sync
        -- in MobUpdate) is dead weight if no one's looking. Saves
        -- ~5 instances per mob spawn and per-tick CFrame writes.
        local hpFill, hpText, bbAnchor = nil, nil, nil
        if Workspace:GetAttribute("InfiniteVisuals") == true then
            bbAnchor = Instance.new("Part")
            bbAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
            bbAnchor.Transparency = 1
            bbAnchor.CanCollide = false
            bbAnchor.Anchored = true
            bbAnchor.CFrame = mob.CFrame + Vector3.new(0, def.size * 0.9, 0)
            bbAnchor.Parent = mob

            local bb = Instance.new("BillboardGui")
            -- ea3-124: bumped from 80×18 → 96×20 for better legibility +
            -- to fit the inside-the-bar HP text without crowding the
            -- numbers at small viewing distances. Reference comparison
            -- (Matthew 2026-05-01 screenshots): the polished tower-defense
            -- style uses ~96-wide bars and reads cleanly even on cluster
            -- mobs.
            bb.Size = UDim2.fromOffset(96, 20)
            bb.AlwaysOnTop = true
            bb.LightInfluence = 0
            bb.MaxDistance = 200
            bb.Parent = bbAnchor

            -- Outer "drained" layer — shows behind the fill bar as HP
            -- depletes. Dark red instead of dark grey gives the bar a
            -- two-tone red-on-red look that reads as "wounded mob"
            -- instead of "empty UI element". Sharp corners + black
            -- stroke matches the flat-rectangle reference style
            -- (Matthew 2026-05-01 screenshots).
            local hpBg = Instance.new("Frame")
            hpBg.Size = UDim2.fromScale(1, 1)
            hpBg.BackgroundColor3 = Color3.fromRGB(80, 20, 20)
            hpBg.BackgroundTransparency = 0.05  -- ea3-124: more solid look
            hpBg.BorderSizePixel = 0
            hpBg.Parent = bb
            do
                local s = Instance.new("UIStroke")
                s.Thickness = 1.5
                s.Color = Color3.fromRGB(0, 0, 0)
                s.Transparency = 0.2
                s.Parent = hpBg
            end

            -- Inner fill — bright red, shrinks as HP drops. Sharp
            -- corners; the stroke on hpBg gives the clean edge.
            -- ea3-124: subtle vertical gradient for depth (bright at
            -- top, ~25% darker at bottom). Modern-TD-game look.
            hpFill = Instance.new("Frame")
            hpFill.Size = UDim2.new(1, -2, 1, -2)
            hpFill.Position = UDim2.fromOffset(1, 1)
            hpFill.BackgroundColor3 = Color3.fromRGB(240, 80, 80)
            hpFill.BorderSizePixel = 0
            hpFill.Parent = hpBg
            do
                local g = Instance.new("UIGradient")
                g.Rotation = 90  -- vertical (top → bottom)
                g.Color = ColorSequence.new({
                    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 110, 110)),  -- brighter top
                    ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 50, 50)),    -- darker bottom
                })
                g.Parent = hpFill
            end

            -- HP number text — inside the bar, centered. ZIndex 3
            -- (above hpFill ZIndex 2 default + hpBg ZIndex 1) so the
            -- text always reads on top of the fill. Stroke gives
            -- contrast against either the bright fill OR the dark
            -- drained portion as the bar empties.
            hpText = Instance.new("TextLabel")
            hpText.Size = UDim2.fromScale(1, 1)
            hpText.BackgroundTransparency = 1
            hpText.Text = string.format("%d / %d", scaledHp, scaledHp)
            hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
            hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            hpText.TextStrokeTransparency = 0
            hpText.Font = Enum.Font.FredokaOne
            hpText.TextSize = 13
            hpText.ZIndex = 3
            hpText.Parent = hpBg
        end

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
