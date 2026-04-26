--[[
    Map3StageVisuals.lua — Map 3 stage transition visuals.

    Per-stage growth:
      stage 1: small branches half-size, no flowers, no butterflies, dawn light
      stage 2: small branches 75%, some flowers visible, 4 butterflies, morning light
      stage 3: full size, all flowers, 10 butterflies, midday canopy light
      stage 4: peak (boss), 14 butterflies, golden-hour light

    Driven by the StageAdvanced handler in the hub orchestrator (mapId == 3).
    Uses the same shared lighting-tween state as map 1 / map 2 so DevReset
    can cancel in-flight tweens cleanly.

    setup(ctx) reads:
      ctx.Map3Stage  — namespace populated by Map3.setup
      ctx.cancelLightingTweens, ctx.activeLightingTween, ctx.activeFloorTween

    Publishes:
      ctx.tweenStageLightingMap3   -- called by StageAdvanced handler
      ctx.applyMap3StageVisuals    -- called by StageAdvanced handler + DevReset
      ctx.applyMap3Stage1OnEntry   -- called when player teleports onto map 3
]]

local Workspace         = game:GetService("Workspace")
local Lighting          = game:GetService("Lighting")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local Map3StageVisuals = {}

function Map3StageVisuals.setup(ctx)
    local Map3Stage = ctx.Map3Stage

    -- Map 3 lighting palette: even brighter / more open than map 2.
    -- Stage 1 is dawn just-after-sunrise; stage 4 is golden hour as the
    -- canopy battle peaks.
    local STAGE_LIGHTING_MAP3 = {
        -- Stage 1 — MORNING (sunrise): low golden sun, peach ambient, warm fog.
        [1] = {
            clockTime  = 6.1,
            floorTint  = Color3.fromRGB(195, 145, 100),
            ambient    = Color3.fromRGB(195, 150, 115),
            outdoor    = Color3.fromRGB(180, 130,  95),
            fogColor   = Color3.fromRGB(255, 195, 145),
            fogStart   = 200,
            fogEnd     = 700,
            sunRays    = 0.55,
        },
        -- Stage 2 — AFTERNOON (3 o'clock): bright sun, neutral fog.
        [2] = {
            clockTime  = 15.0,
            floorTint  = Color3.fromRGB(195, 165, 115),
            ambient    = Color3.fromRGB(195, 185, 160),
            outdoor    = Color3.fromRGB(195, 185, 165),
            fogColor   = Color3.fromRGB(225, 230, 235),
            fogStart   = 300,
            fogEnd     = 900,
            sunRays    = 0.20,
        },
        -- Stage 3 — DUSK (golden hour): warm orange glow, low sun.
        [3] = {
            clockTime  = 17.5,
            floorTint  = Color3.fromRGB(220, 155,  95),
            ambient    = Color3.fromRGB(210, 150, 100),
            outdoor    = Color3.fromRGB(195, 135,  85),
            fogColor   = Color3.fromRGB(250, 175, 120),
            fogStart   = 200,
            fogEnd     = 700,
            sunRays    = 0.55,
        },
        -- Stage 4 — NIGHT: dim, dark blue, low fog so the moon and the
        -- Neon flowers/butterflies are the dominant light sources.
        [4] = {
            clockTime  = 22.0,
            floorTint  = Color3.fromRGB( 75,  70, 100),
            ambient    = Color3.fromRGB( 50,  55,  85),
            outdoor    = Color3.fromRGB( 30,  35,  65),
            fogColor   = Color3.fromRGB( 25,  30,  55),
            fogStart   = 100,
            fogEnd     = 500,
            sunRays    = 0.05,
        },
    }

    local function tweenStageLightingMap3(stage)
        local cfg = STAGE_LIGHTING_MAP3[stage]
        if not cfg then return end
        ctx.cancelLightingTweens()
        local info = TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
        ctx.activeLightingTween = TweenService:Create(Lighting, info, {
            ClockTime      = cfg.clockTime,
            Ambient        = cfg.ambient,
            OutdoorAmbient = cfg.outdoor,
            FogColor       = cfg.fogColor,
            FogStart       = cfg.fogStart,
            FogEnd         = cfg.fogEnd,
        })
        ctx.activeLightingTween:Play()
        -- Tween SunRays intensity too — sunrise gets dramatic god-rays
        -- through the branch gaps; midday backs off to subtle.
        local sunRays = Lighting:FindFirstChildOfClass("SunRaysEffect")
        if sunRays then
            TweenService:Create(sunRays, info, {Intensity = cfg.sunRays}):Play()
        end
        local map3Room = Workspace:FindFirstChild("TreeOfLifeMap3Room")
        local map3Floor = map3Room and map3Room:FindFirstChild("Map3Floor")
        if map3Floor then
            ctx.activeFloorTween = TweenService:Create(map3Floor, info, {Color = cfg.floorTint})
            ctx.activeFloorTween:Play()
        end
    end

    -- RELATIVE-GROWTH model: each entry scales by GROWTH STEP (current
    -- stage − unlockStage + 1), not by absolute current stage. So a branch
    -- that springs out at stage 2 starts at step 1 (small), reaches step 2
    -- by stage 3 — the same size that stage-1 branches reached at stage 2.
    --
    -- Step deltas (per Matthew 2026-04-24): step 1→2 grows 50% more than
    -- prior tuning, step 2→3 grows 100% more. So step 2 → step 3 is the
    -- most dramatic visual jump.
    -- Step 2→3 delta halved per Matthew's tone-back. Step 1→2 unchanged.
    local BRANCH_SCALE_BY_STEP = {
        [1] = 0.55,
        [2] = 1.15,   -- delta +0.60
        [3] = 1.60,   -- delta +0.45 (was +0.90, halved)
        [4] = 1.70,
    }
    -- Leaf clumps grow ~25% more per step than branches — they're round
    -- balls now (not flat plates) so they read as less obtrusive at scale.
    local LEAF_SCALE_BY_STEP = {
        [1] = 0.55,
        [2] = 1.44,    -- 1.15 × 1.25
        [3] = 2.00,    -- 1.60 × 1.25
        [4] = 2.13,    -- 1.70 × 1.25
    }
    -- Flowers visible from step 1 (per Matthew "bring flowers on in stage 2"):
    -- with most flowers at unlockStage=2, step 1 = stage 2.
    local FLOWER_SCALE_BY_STEP = {
        [1] = 0.7,
        [2] = 1.2,
        [3] = 1.55,
        [4] = 1.65,
    }
    -- Buds (closed bulbs, stored in Map3Stage.flowers with isBud=true) DO
    -- show at step 1 (so every just-sprouted branch has at least a tight
    -- bud) and just scale subtly across stages.
    local BUD_SCALE_BY_STEP = {
        [1] = 0.7,
        [2] = 1.0,
        [3] = 1.2,
        [4] = 1.3,
    }

    -- PointLight brightness per ABSOLUTE map stage (not relative growth).
    -- Day stages keep flowers/butterflies cosmetic-bright via Neon material;
    -- dusk/night ramp up the actual emissive PointLight so flowers + bugs
    -- become real light sources illuminating the surroundings.
    local FLOWER_LIGHT_BRIGHTNESS_BY_STAGE = {
        [1] = 0,    -- morning: lights off
        [2] = 0,    -- afternoon: lights off
        [3] = 0.6,  -- dusk: faint glow as ambient drops
        [4] = 2.0,  -- night: bright — flowers are the dominant light source
    }
    local BUTTERFLY_LIGHT_BRIGHTNESS_BY_STAGE = {
        [1] = 0,
        [2] = 0,
        [3] = 0.4,
        [4] = 1.4,
    }

    -- Map an entry's (unlockStage, currentStage) to a clamped growth step.
    local function growthStep(unlockStage, currentStage)
        local step = currentStage - unlockStage + 1
        if step < 1 then return 0 end       -- not yet visible
        if step > 4 then return 4 end       -- mature
        return step
    end

    -- "Dense liquid" pop: BURST (slow inflate past target) → SETTLE
    -- (elastic snap-back-and-bounce). Both leaves and branches use this
    -- shape, with slightly different timings so branches feel weightier.
    -- Per Matthew: slower bounce, more inflation than the previous tuning.
    local LEAF_BURST_INFO = TweenInfo.new(
        0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, false, 0)
    local LEAF_SETTLE_INFO = TweenInfo.new(
        0.85, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out, 0, false, 0)
    local LEAF_OVERSHOOT_FACTOR = 1.45
    -- Branches use the same chained shape so trunk segments visibly
    -- inflate-then-settle instead of jumping size.
    local BRANCH_BURST_INFO = TweenInfo.new(
        0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, false, 0)
    local BRANCH_SETTLE_INFO = TweenInfo.new(
        1.0, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out, 0, false, 0)
    local BRANCH_OVERSHOOT_FACTOR = 1.30
    -- Flowers — slightly snappier (single Back.Out) so they feel like
    -- they're springing OFF the leaves rather than growing with them.
    local FLOWER_BOUNCE_INFO = TweenInfo.new(
        0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0)

    -- Helper: chain a BURST tween into a SETTLE tween. Overshoots target
    -- then settles with elastic. Used for both leaf and branch parts.
    local function popTween(part, target, burstInfo, settleInfo, overshootFactor)
        if not part or not part.Parent then return end
        local oversize = target * overshootFactor
        local burst = TweenService:Create(part, burstInfo, {Size = oversize})
        burst:Play()
        burst.Completed:Connect(function()
            if part.Parent then
                TweenService:Create(part, settleInfo, {Size = target}):Play()
            end
        end)
    end

    local function setBranchVisibility(entry, visible, scaleFactor, animate)
        if not visible then
            entry.part.Transparency = 1
            entry.part.CanCollide = false
            for _, leaf in ipairs(entry.leafParts) do
                leaf.Transparency = 1
            end
            return
        end
        local wasHidden = entry.part.Transparency >= 1
        entry.part.Transparency = 0
        local lenFactor = math.max(0.1, 0.85 * scaleFactor - 0.15)
        local newLen = entry.baseLength * lenFactor
        local newRadius = entry.baseRadius * scaleFactor
        local mid = entry.startPos + entry.sproutDir * (newLen / 2)
        local targetSize = Vector3.new(newLen, newRadius * 2, newRadius * 2)
        local targetCF = CFrame.lookAt(mid, mid + entry.sproutDir)
                       * CFrame.Angles(0, math.rad(90), 0)
        -- CFrame snaps (its midpoint shifts with size — a tween between
        -- different lengths' midpoints would look like a slide, not a pop).
        entry.part.CFrame = targetCF
        if animate then
            -- Newly-visible branches start tiny so the pop has amplitude.
            if wasHidden then
                entry.part.Size = Vector3.new(targetSize.X * 0.2,
                                              targetSize.Y * 0.2,
                                              targetSize.Z * 0.2)
            end
            popTween(entry.part, targetSize,
                BRANCH_BURST_INFO, BRANCH_SETTLE_INFO, BRANCH_OVERSHOOT_FACTOR)
        else
            entry.part.Size = targetSize
        end
        -- Leaves snap to the (new) tip
        local tipPos = entry.startPos + entry.sproutDir * newLen
        for i, leaf in ipairs(entry.leafParts) do
            local wasHidden = leaf.Transparency >= 1
            leaf.Transparency = 0
            local offset
            if i == 1 then
                -- Hero leaf: centered exactly on the cap (no scatter).
                offset = Vector3.new(0, 0, 0)
            else
                local angle = ((i - 1) / math.max(#entry.leafParts - 1, 1)) * math.pi * 2
                offset = Vector3.new(
                    math.cos(angle) * 0.3,
                    ((i - 1) % 2) * 0.15 - 0.05,
                    math.sin(angle) * 0.3
                )
            end
            leaf.CFrame = CFrame.new(tipPos + offset)
                        * CFrame.Angles((math.random() - 0.5) * 0.6,
                                        math.random() * math.pi * 2, 0)
            -- Only reset to the small "starting" size when the leaf was
            -- previously hidden — otherwise the bouncy setLeafScale tween
            -- below would snap-back before bouncing up, killing the effect.
            -- Smaller starting size (×0.2) gives Elastic more amplitude.
            if wasHidden then
                local s = entry.baseLeafSize * LEAF_SCALE_BY_STEP[1] * 0.2
                leaf.Size = Vector3.new(s, s * 0.85, s)
            end
        end
    end

    local function setLeafScale(entry, leafScale, animate)
        for i, leaf in ipairs(entry.leafParts) do
            local s = entry.baseLeafSize * leafScale
            local target = Vector3.new(s, s * 0.85, s)
            if animate then
                local delaySec = (i - 1) * 0.06
                local function play()
                    popTween(leaf, target,
                        LEAF_BURST_INFO, LEAF_SETTLE_INFO, LEAF_OVERSHOOT_FACTOR)
                end
                if delaySec > 0 then task.delay(delaySec, play)
                else play() end
            else
                leaf.Size = target
            end
        end
    end

    local function setFlowerVisibility(entry, visible, scaleFactor, animate)
        if not visible or scaleFactor <= 0 then
            for _, p in ipairs(entry.parts) do
                p.Transparency = 1
            end
            return
        end
        -- BUDS: re-anchor to the parent leaf via stored localOffset.
        if entry.isBud and entry.parentLeaf and entry.parentLeaf.Parent then
            local bud = entry.parts[1]
            if bud then
                local newPos = entry.parentLeaf.Position + entry.localOffset
                bud.CFrame = CFrame.new(newPos) * (bud.CFrame - bud.CFrame.Position)
            end
        end
        -- OPEN FLOWERS: re-anchor to the leaf SURFACE (outside the leaf
        -- ball) using flowerDir + dynamic leaf radius. Each part keeps its
        -- local rotation via the captured partLocalCFrame.
        if (not entry.isBud) and entry.parentLeaf and entry.parentLeaf.Parent
           and entry.partLocalCFrames then
            local leafSize = entry.parentLeaf.Size
            local leafRadius = math.max(leafSize.X, leafSize.Y, leafSize.Z) / 2
            -- Match the build-time inset so the petal ring sits on surface.
            local insetDist = entry.baseSize * 0.45 * scaleFactor
            local newAnchor = entry.parentLeaf.Position
                            + entry.flowerDir * (leafRadius - insetDist)
            for i, p in ipairs(entry.parts) do
                p.CFrame = CFrame.new(newAnchor) * entry.partLocalCFrames[i]
            end
        end
        for i, p in ipairs(entry.parts) do
            local wasHidden = p.Transparency >= 1
            p.Transparency = 0
            local s = entry.baseSize * scaleFactor
            local targetSize
            if entry.isBud then
                targetSize = Vector3.new(s * 0.65, s * 1.4, s * 0.65)
            elseif i == 1 then
                targetSize = Vector3.new(s * 0.6, s * 0.6, s * 0.6)
                local light = p:FindFirstChildOfClass("PointLight")
                if light then
                    local mapStage = Map3Stage.currentStage or 1
                    light.Brightness = FLOWER_LIGHT_BRIGHTNESS_BY_STAGE[mapStage] or 0
                end
            else
                targetSize = Vector3.new(s, s * 0.25, s * 0.6)
            end
            if animate then
                -- Bounce in / grow with Back.Out spring. If just-revealed,
                -- start small so the bounce has visible amplitude.
                if wasHidden then
                    p.Size = Vector3.new(targetSize.X * 0.2,
                                         targetSize.Y * 0.2,
                                         targetSize.Z * 0.2)
                end
                local delaySec = (i - 1) * 0.04
                local function play()
                    if p.Parent then
                        TweenService:Create(p, FLOWER_BOUNCE_INFO, {Size = targetSize}):Play()
                    end
                end
                if delaySec > 0 then task.delay(delaySec, play)
                else play() end
            else
                p.Size = targetSize
            end
        end
    end

    local function setButterflyVisibility(entry, visible)
        local wasVisible = entry.body.Transparency < 1
        local t = visible and 0.1 or 1
        entry.body.Transparency = visible and 0 or 1
        entry.wingL.Transparency = t
        entry.wingR.Transparency = t
        -- Butterfly PointLight: brightness ramps with absolute map stage.
        local bLight = entry.body:FindFirstChildOfClass("PointLight")
        if bLight then
            local mapStage = Map3Stage.currentStage or 1
            bLight.Brightness = visible
                and (BUTTERFLY_LIGHT_BRIGHTNESS_BY_STAGE[mapStage] or 0)
                or 0
        end
        -- When a butterfly first becomes visible, kick off its travel from
        -- middle-of-arena to its flower target. Subsequent re-visibility
        -- (e.g. cycling stages forward then back) re-runs the travel so
        -- they look freshly emerged each time.
        if visible and not wasVisible then
            entry.state = "traveling"
            entry.travelStartTime = os.clock()
            entry.body.CFrame = CFrame.new(entry.startPos)
        end
    end

    -- The applied state. animate=true means tween into place; false snaps
    -- (used at boot so the player doesn't see stage-1 branches grow on entry).
    local function applyMap3StageVisuals(stage, animate)
        if animate == nil then animate = true end
        local s = math.min(math.max(stage, 1), 4)
        -- Stash for setFlowerVisibility / butterfly visibility to drive
        -- PointLight brightness based on absolute map stage.
        Map3Stage.currentStage = s

        -- Small branches — scale + leaf scale by relative growth step.
        for _, entry in ipairs(Map3Stage.smallBranches) do
            local step = growthStep(entry.unlockStage, s)
            if step == 0 then
                setBranchVisibility(entry, false, 0, animate)
            else
                setBranchVisibility(entry, true, BRANCH_SCALE_BY_STEP[step], animate)
                setLeafScale(entry, LEAF_SCALE_BY_STEP[step], animate)
            end
        end

        -- Flowers (and buds, stored in same list) — also relative growth.
        -- Buds use BUD_SCALE_BY_STEP (visible from step 1); open flowers use
        -- FLOWER_SCALE_BY_STEP (start at step 2).
        for _, entry in ipairs(Map3Stage.flowers) do
            local step = growthStep(entry.unlockStage, s)
            local scale
            if entry.isBud then
                scale = BUD_SCALE_BY_STEP[step] or 0
            else
                scale = FLOWER_SCALE_BY_STEP[step] or 0
            end
            if step == 0 or scale <= 0 then
                setFlowerVisibility(entry, false, 0, animate)
            else
                setFlowerVisibility(entry, true, scale, animate)
            end
        end

        -- Butterflies
        for _, entry in ipairs(Map3Stage.butterflies) do
            setButterflyVisibility(entry, entry.unlockStage <= s)
        end
    end

    -- Butterfly hover animation — runs for the lifetime of the server.
    -- Each butterfly bobs in a small horizontal circle around its hoverPos
    -- and flaps its wings up/down on a sine.
    RunService.Heartbeat:Connect(function(_dt)
        local now = os.clock()
        for _, b in ipairs(Map3Stage.butterflies) do
            if b.body.Transparency >= 1 then
                continue
            end
            if not b.body.Parent then continue end
            local pos
            if b.state == "traveling" then
                local elapsed = now - b.travelStartTime
                local t = math.min(elapsed / b.travelDuration, 1)
                -- Smoothstep ease: slow start, slow finish
                local eased = t * t * (3 - 2 * t)
                pos = b.startPos:Lerp(b.hoverPos, eased)
                if t >= 1 then b.state = "orbiting" end
                -- Face the direction of travel
                local lookDir = (b.hoverPos - b.startPos)
                if lookDir.Magnitude > 0.01 then
                    b.body.CFrame = CFrame.lookAt(pos, pos + lookDir.Unit)
                else
                    b.body.CFrame = CFrame.new(pos)
                end
            else
                -- Orbiting around the flower cluster
                local theta = now * b.speed + b.phase
                pos = b.hoverPos + Vector3.new(
                    math.cos(theta) * b.radius,
                    math.sin(theta * 0.7) * 1.2,
                    math.sin(theta) * b.radius
                )
                local tangent = Vector3.new(-math.sin(theta), 0, math.cos(theta))
                b.body.CFrame = CFrame.lookAt(pos, pos + tangent)
            end
            local flap = math.sin(now * 18 + b.phase) * math.rad(35)
            local bs = b.baseSize
            b.wingL.CFrame = b.body.CFrame
                           * CFrame.new(-bs * 0.5, 0, 0)
                           * CFrame.Angles(0, 0,  flap)
            b.wingR.CFrame = b.body.CFrame
                           * CFrame.new( bs * 0.5, 0, 0)
                           * CFrame.Angles(0, 0, -flap)
        end
    end)

    -- Boot: snap to stage 1 (no animation) so the player never sees the
    -- decor grow when first arriving on map 3.
    task.defer(function()
        applyMap3StageVisuals(1, false)
    end)

    ctx.applyMap3Stage1OnEntry = function()
        tweenStageLightingMap3(1)
        applyMap3StageVisuals(1, false)
    end

    ctx.tweenStageLightingMap3 = tweenStageLightingMap3
    ctx.applyMap3StageVisuals  = applyMap3StageVisuals
end

return Map3StageVisuals
