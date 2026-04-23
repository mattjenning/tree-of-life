--[[
    Map2StageVisuals.lua — Map 2 stage transition visuals: lighting
    (dawn → morning → midday → boss twilight) and geometry reveal
    (staircase rises from the ground in stages, bushes appear, fireflies
    scale up).

    Driven by the StageAdvanced handler still in the hub orchestrator,
    which dispatches to this module for mapId == 2. Map 1's equivalent
    lives in systems/StageVisuals.lua — both modules share the lighting-
    tween state via ctx so DevReset can cancel in-flight tweens from
    either map.

    setup(ctx) reads:
      ctx.Map2Stage            -- namespace populated by Map2.setup
      ctx.cancelLightingTweens, ctx.activeLightingTween, ctx.activeFloorTween
                                -- shared with StageVisuals

    And publishes:
      ctx.tweenStageLightingMap2  -- called by StageAdvanced handler
      ctx.applyMap2StageVisuals   -- called by StageAdvanced handler, DevReset, and...
      ctx.applyMap2Stage1OnEntry  -- ...overwritten from the hub stub so Map2's
                                    portal handler (late-resolved via ctx) fires
                                    the real lighting + visuals on entry.

    CLAUDE.md flagged diagnostic prints inside applyMap2StageVisuals that
    were added to debug staircase growth. Per Phase 2 commit 6's scope,
    those prints are now removed.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Map2StageVisuals = {}

function Map2StageVisuals.setup(ctx)
    local Map2Stage = ctx.Map2Stage

    -- Map 2 lighting config. Mirrors STAGE_LIGHTING for map 1 but uses cooler
    -- morning-forward tones since map 2 is "up in the canopy" thematically.
    local STAGE_LIGHTING_MAP2 = {
        [1] = { clockTime = 5.5,  floorTint = Color3.fromRGB(110,  85,  55), ambient = Color3.fromRGB( 95,  90, 105) },  -- very early morning
        [2] = { clockTime = 8.5,  floorTint = Color3.fromRGB(140, 105,  65), ambient = Color3.fromRGB(140, 135, 115) },  -- warm morning
        [3] = { clockTime = 12,   floorTint = Color3.fromRGB(160, 125,  80), ambient = Color3.fromRGB(170, 160, 140) },  -- bright midday
        [4] = { clockTime = 20,   floorTint = Color3.fromRGB( 55,  45,  70), ambient = Color3.fromRGB( 45,  40,  65) },  -- twilight (boss)
    }

    local function tweenStageLightingMap2(stage)
        local cfg = STAGE_LIGHTING_MAP2[stage]
        if not cfg then return end
        ctx.cancelLightingTweens()
        local info = TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
        ctx.activeLightingTween = TweenService:Create(Lighting, info,
            {ClockTime = cfg.clockTime, Ambient = cfg.ambient})
        ctx.activeLightingTween:Play()
        -- Map 2 floor is the first child named "Map2Floor" under map2Room
        local map2Room = Workspace:FindFirstChild("TreeOfLifeMap2Room")
        local map2Floor = map2Room and map2Room:FindFirstChild("Map2Floor")
        if map2Floor then
            ctx.activeFloorTween = TweenService:Create(map2Floor, info, {Color = cfg.floorTint})
            ctx.activeFloorTween:Play()
        end
    end

    -- Apply stage-gated visibility to staircase / bushes / fireflies. For
    -- steps and bush lobes, parts at unlockStage > current stage are hidden
    -- (Transparency = 1, CanCollide = false). Fireflies scale their Size and
    -- PointLight Brightness/Range via baseSize + baseBrightness.
    -- Stage 4 (boss sentinel) is treated as stage 3 for geometry — everything
    -- is revealed + at max size.
    -- applyMap2StageVisuals(stage, animate)
    --   stage: 1..4 (stage 4 = boss/night sentinel)
    --   animate: true = emerge-from-ground tween for newly-unlocked parts (default)
    --            false = place parts at target/buried instantly (used for boot setup
    --                    so the player doesn't see the whole staircase rise when
    --                    first loading in)
    --
    -- Two stage variables:
    --   stairStage     — used for the staircase (stage 4 reveals the full 100%
    --                    height; this is the "climactic" night-boss view).
    --   effectiveStage — used for bushes + fireflies (capped at 3 because those
    --                    populations only define stage 1/2/3 unlocks; stage 4 is
    --                    the same visual as stage 3 for ambient foliage).
    local function applyMap2StageVisuals(stage, animate)
        if animate == nil then animate = true end
        local stairStage = stage  -- staircase uses full 1..4 range
        local effectiveStage = (stage == 4) and 3 or stage  -- bushes/fireflies cap at 3

        -- Staircase step + stringer reveal: emerge-from-ground animation.
        -- Parts with unlockStage > stairStage get buried (below floor, transparent).
        -- Parts with unlockStage <= stairStage either:
        --   - if not yet risen: tween from buried → target position (staggered)
        --   - if already risen: stay at target (no-op)
        -- Buried offset: Config.Map2.BuriedDropStuds below target Y, fully transparent.
        local BURIED_DROP = Config.Map2.BuriedDropStuds
        local RISE_DURATION = Config.Map2.RiseDurationSeconds
        local STAGGER_PER_STEP = Config.Map2.RiseStaggerPerStep

        for _, entry in ipairs(Map2Stage.stairParts) do
            if entry.unlockStage > stairStage then
                -- BURIED: below floor, transparent, non-collide. Cancel any in-flight
                -- rise tween so the bury doesn't get fought by a tween still running.
                if entry.activeTween then
                    entry.activeTween:Cancel()
                    entry.activeTween = nil
                end
                local buriedCF = entry.targetCFrame - Vector3.new(0, BURIED_DROP, 0)
                entry.part.CFrame = buriedCF
                entry.part.Transparency = 1
                entry.part.CanCollide = false
                entry.risen = false
            elseif not entry.risen then
                if animate then
                    local buriedCF = entry.targetCFrame - Vector3.new(0, BURIED_DROP, 0)
                    entry.part.CFrame = buriedCF
                    entry.part.Transparency = 1
                    entry.part.CanCollide = false
                    entry.risen = true

                    local sF = Map2Stage.stageUnlockFractions or {[1]=0.05,[2]=0.25,[3]=0.60,[4]=1.0}
                    local batchStartIdx
                    if entry.unlockStage == 1 then batchStartIdx = 0
                    elseif entry.unlockStage == 2 then batchStartIdx = math.floor(Map2Stage.stairStepCount * sF[1])
                    elseif entry.unlockStage == 3 then batchStartIdx = math.floor(Map2Stage.stairStepCount * sF[2])
                    else batchStartIdx = math.floor(Map2Stage.stairStepCount * sF[3]) end
                    local batchRelIdx = math.max(0, (entry.stepIndex or 0) - batchStartIdx)
                    local delay = batchRelIdx * STAGGER_PER_STEP

                    task.delay(delay, function()
                        if not entry.part.Parent then return end
                        if not entry.risen then return end  -- reset happened mid-delay
                        local riseInfo = TweenInfo.new(RISE_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
                        local t = TweenService:Create(entry.part, riseInfo, {
                            CFrame = entry.targetCFrame,
                            Transparency = 0,
                        })
                        entry.activeTween = t
                        t.Completed:Connect(function()
                            if entry.activeTween == t then entry.activeTween = nil end
                        end)
                        t:Play()
                        task.delay(RISE_DURATION * 0.6, function()
                            if entry.part.Parent and entry.risen then
                                entry.part.CanCollide = true
                            end
                        end)
                    end)
                else
                    -- INSTANT: place at target with no tween
                    if entry.activeTween then
                        entry.activeTween:Cancel()
                        entry.activeTween = nil
                    end
                    entry.part.CFrame = entry.targetCFrame
                    entry.part.Transparency = 0
                    entry.part.CanCollide = true
                    entry.risen = true
                end
            end
        end

        -- Top lamp + axis follow the visible-top position (tween smoothly if animating,
        -- snap instantly otherwise). Uses stairStage (1..4, not clamped) so the full
        -- 100% height reveals at stage 4.
        local visibleStepCount = math.floor(Map2Stage.stairStepCount * (Map2Stage.stageUnlockFractions or {[1]=1/3,[2]=2/3,[3]=1.0,[4]=1.0})[stairStage])
        local visibleHeight = visibleStepCount * Map2Stage.stairStepHeight
        if Map2Stage.axisPart then
            local newAxisH = visibleHeight + 8
            local newAxisCF = CFrame.new(Map2Stage.stairCenter + Vector3.new(0, newAxisH / 2, 0))
                              * CFrame.Angles(0, 0, math.rad(90))
            if animate then
                local info = TweenInfo.new(RISE_DURATION + 0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
                TweenService:Create(Map2Stage.axisPart, info, {
                    Size = Vector3.new(newAxisH, 1.0, 1.0),
                    CFrame = newAxisCF,
                }):Play()
            else
                Map2Stage.axisPart.Size = Vector3.new(newAxisH, 1.0, 1.0)
                Map2Stage.axisPart.CFrame = newAxisCF
            end
        end
        if Map2Stage.topLamp then
            -- Lamp sits directly on the center axis pole at the top — no
            -- horizontal offset. The axis cylinder runs from floor to
            -- (visibleHeight + 8); lamp hangs ~1 stud below the axis top so it
            -- reads as a lantern on the pole rather than a floating ball.
            local topLampPos = Map2Stage.stairCenter + Vector3.new(0, visibleHeight + 7, 0)
            if animate then
                local info = TweenInfo.new(RISE_DURATION + 0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
                TweenService:Create(Map2Stage.topLamp, info, {
                    CFrame = CFrame.new(topLampPos),
                }):Play()
            else
                Map2Stage.topLamp.CFrame = CFrame.new(topLampPos)
            end
        end

        -- Bush lobes reveal (same on/off pattern; no animation for bushes)
        for _, entry in ipairs(Map2Stage.bushLobes) do
            if entry.unlockStage <= effectiveStage then
                entry.part.Transparency = 0
            else
                entry.part.Transparency = 1
            end
        end

        -- Fireflies: size multiplier per stage
        local sizeMult = 1.0 + 0.5 * (effectiveStage - 1)
        local brightnessMult = 1.0 + 0.35 * (effectiveStage - 1)
        local rangeMult = 1.0 + 0.30 * (effectiveStage - 1)
        for _, f in ipairs(Map2Stage.fireflies) do
            if f.part.Parent then
                local s = f.baseSize * sizeMult
                f.part.Size = Vector3.new(s, s, s)
                f.baseBrightness = 1.4 * brightnessMult
                f.light.Range = f.baseLightRange * rangeMult
            end
        end
    end

    -- Apply stage 1 visuals immediately at hub boot. Animate=false so the
    -- player doesn't see the whole staircase rise when they first load in;
    -- geometry just snaps to stage-1 state. The emerge animation fires for
    -- REAL on stage-advance events.
    task.defer(function()
        applyMap2StageVisuals(1, false)
    end)

    -- Overwrite the forward-declared stub installed by the hub orchestrator.
    -- Map2.setup's portal handler reads ctx.applyMap2Stage1OnEntry at call time,
    -- so the overwrite takes effect for any player who enters map 2 after
    -- Map2StageVisuals.setup has run.
    ctx.applyMap2Stage1OnEntry = function()
        tweenStageLightingMap2(1)
        applyMap2StageVisuals(1, false)
    end

    -- Publish
    ctx.tweenStageLightingMap2 = tweenStageLightingMap2
    ctx.applyMap2StageVisuals  = applyMap2StageVisuals
end

return Map2StageVisuals
