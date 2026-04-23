--[[
    StageVisuals.lua — Map 1 stage transition visuals: lighting tweens
    (morning → day → dusk → night boss) and per-stage decor (trees that
    spawn at the walls and grow, torches for the night sentinel stage).

    Driven by the StageAdvanced handler still in the hub orchestrator,
    which dispatches to this module for mapId == 1. Map 2's equivalent
    lives in systems/Map2StageVisuals.lua — both share the tween state
    on ctx so DevReset can cancel in-flight tweens from either map.

    setup(ctx) reads:
      ctx.floor                -- TD floor Part (tweened on stage change)
      ctx.tdRoom               -- StageDecor folder parented here
      ctx.rc, halfW, halfD     -- used by placeTreeRing
      ctx.cellToWorld, heartCell -- used to compute heart exclusion for tree ring
      ctx.cancelLightingTweens, ctx.activeLightingTween, ctx.activeFloorTween
                                -- shared with Map2StageVisuals; see hub orchestrator

    And publishes:
      ctx.STAGE_LIGHTING       -- read by DevReset to snap lighting back to stage 1
      ctx.tweenStageLighting   -- called by StageAdvanced handler
      ctx.growStageDecor       -- called by StageAdvanced handler (stages 2+)
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local StageVisuals = {}

function StageVisuals.setup(ctx)
    local floor       = ctx.floor
    local tdRoom      = ctx.tdRoom
    local rc          = ctx.rc
    local halfW       = ctx.halfW
    local halfD       = ctx.halfD
    local cellToWorld = ctx.cellToWorld
    local heartCell   = ctx.heartCell

    local STAGE_LIGHTING = {
        [1] = { clockTime = 7,    floorTint = Color3.fromRGB(140, 100, 60),  ambient = Color3.fromRGB(120, 100, 80) },
        [2] = { clockTime = 12,   floorTint = Color3.fromRGB(150, 110, 70),  ambient = Color3.fromRGB(160, 150, 130) },
        [3] = { clockTime = 17.5, floorTint = Color3.fromRGB(170, 100, 70),  ambient = Color3.fromRGB(180, 130, 100) },
        [4] = { clockTime = 0,    floorTint = Color3.fromRGB(50, 40, 60),    ambient = Color3.fromRGB(40, 35, 60) },
    }

    local function tweenStageLighting(stage)
        local cfg = STAGE_LIGHTING[stage]
        if not cfg then return end
        ctx.cancelLightingTweens()
        local info = TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
        ctx.activeLightingTween = TweenService:Create(Lighting, info,
            {ClockTime = cfg.clockTime, Ambient = cfg.ambient})
        ctx.activeLightingTween:Play()
        if floor and floor.Parent then
            ctx.activeFloorTween = TweenService:Create(floor, info, {Color = cfg.floorTint})
            ctx.activeFloorTween:Play()
        end
    end

    local function clearStageDecor()
        local existing = tdRoom:FindFirstChild("StageDecor")
        if existing then existing:Destroy() end
    end

    -- Trees are wrapped in a Model so we can identify and re-tween the existing
    -- ones on the Day → Dusk transition. The Model has a "TreeX"/"TreeZ"
    -- position attribute and a "GrowStage" attribute (1 = small at spawn,
    -- 2 = stage-2 grown, 3 = stage-3 grown bigger).
    local function spawnTree(decor, x, z, tweenDelay)
        local info = TweenInfo.new(2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

        local treeModel = Instance.new("Model")
        treeModel.Name = "StageTree"
        treeModel:SetAttribute("TreeX", x)
        treeModel:SetAttribute("TreeZ", z)
        treeModel:SetAttribute("GrowStage", 1)
        treeModel.Parent = decor

        local trunk = Instance.new("Part")
        trunk.Name = "Trunk"
        trunk.Shape = Enum.PartType.Cylinder
        trunk.Size = Vector3.new(0.5, 1.6, 1.6)
        trunk.CFrame = CFrame.new(x, 1.5, z) * CFrame.Angles(0, 0, math.rad(90))
        trunk.Material = Enum.Material.Wood
        trunk.Color = Color3.fromRGB(80, 50, 30)
        trunk.Anchored = true
        trunk.CanCollide = false
        trunk.Parent = treeModel

        local canopy = Instance.new("Part")
        canopy.Name = "Canopy"
        canopy.Shape = Enum.PartType.Ball
        canopy.Size = Vector3.new(1, 1, 1)
        canopy.CFrame = CFrame.new(x, 2, z)
        canopy.Material = Enum.Material.Grass
        canopy.Color = Color3.fromRGB(60, 110, 50)
        canopy.Anchored = true
        canopy.CanCollide = false
        canopy.Parent = treeModel

        task.delay(tweenDelay or 0, function()
            if not treeModel.Parent then return end
            TweenService:Create(trunk, info, {
                Size = Vector3.new(8, 1.6, 1.6),
                CFrame = CFrame.new(x, 5, z) * CFrame.Angles(0, 0, math.rad(90)),
            }):Play()
            TweenService:Create(canopy, info, {
                Size = Vector3.new(7, 7, 7),
                CFrame = CFrame.new(x, 11, z),
            }):Play()
            treeModel:SetAttribute("GrowStage", 2)
        end)
    end

    -- Tween every existing tree to the given size profile. Used on Day → Dusk
    -- so the trees the player has been looking at all of stage 2 visibly grow
    -- bigger and taller before the new stage-3 trees appear around them.
    local function growExistingTrees(targetTrunkHeight, targetCanopySize)
        local info = TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
        local decor = tdRoom:FindFirstChild("StageDecor")
        if not decor then return end
        local count = 0
        for _, child in ipairs(decor:GetChildren()) do
            if child:IsA("Model") and child.Name == "StageTree" then
                local x = child:GetAttribute("TreeX")
                local z = child:GetAttribute("TreeZ")
                local trunk = child:FindFirstChild("Trunk")
                local canopy = child:FindFirstChild("Canopy")
                if trunk and canopy and x and z then
                    count = count + 1
                    TweenService:Create(trunk, info, {
                        Size = Vector3.new(targetTrunkHeight, 2.2, 2.2),
                        CFrame = CFrame.new(x, targetTrunkHeight / 2, z)
                            * CFrame.Angles(0, 0, math.rad(90)),
                    }):Play()
                    TweenService:Create(canopy, info, {
                        Size = Vector3.new(targetCanopySize, targetCanopySize, targetCanopySize),
                        CFrame = CFrame.new(x, targetTrunkHeight + targetCanopySize / 2 - 1, z),
                    }):Play()
                    child:SetAttribute("GrowStage", 3)
                end
            end
        end
        if count > 0 then
            print(("[TreeOfLife] Growing %d existing trees to dusk size"):format(count))
        end
    end

    local function spawnTorch(decor, x, z)
        -- Torch: dark cylinder shaft + neon orange ball top with a flickering PointLight
        local shaft = Instance.new("Part")
        shaft.Size = Vector3.new(0.6, 6, 0.6)
        shaft.CFrame = CFrame.new(x, 3, z)
        shaft.Material = Enum.Material.Wood
        shaft.Color = Color3.fromRGB(50, 30, 18)
        shaft.Anchored = true
        shaft.CanCollide = false
        shaft.Parent = decor

        local flame = Instance.new("Part")
        flame.Shape = Enum.PartType.Ball
        flame.Size = Vector3.new(1.4, 1.4, 1.4)
        flame.CFrame = CFrame.new(x, 6.5, z)
        flame.Material = Enum.Material.Neon
        flame.Color = Color3.fromRGB(255, 160, 60)
        flame.Anchored = true
        flame.CanCollide = false
        flame.Parent = decor

        local light = Instance.new("PointLight")
        light.Color = Color3.fromRGB(255, 170, 80)
        light.Brightness = 3
        light.Range = 22
        light.Parent = flame

        -- Subtle flicker: jitter brightness over time
        task.spawn(function()
            while flame.Parent do
                light.Brightness = 2.4 + math.random() * 0.9
                task.wait(0.08 + math.random() * 0.07)
            end
        end)
    end

    -- Compute world position of heart so stage 3 trees that push deeper into
    -- the arena don't overlap it.
    local heartXZ = cellToWorld(heartCell[1], heartCell[2])

    -- Place `countPerSide` trees evenly distributed along each of the 4 walls,
    -- with a random jitter in the along-wall axis. Deeper `inset` pushes the
    -- trees slightly into the arena floor. Trees on the west wall skip positions
    -- near the heart (within `heartAvoid` studs).
    local function placeTreeRing(decor, countPerSide, inset, startDelayStep, indexOffset)
        indexOffset = indexOffset or 0
        local heartAvoid = 14  -- studs of clearance around the heart
        local sides = {"N", "S", "E", "W"}
        local i = indexOffset
        for _, side in ipairs(sides) do
            for k = 1, countPerSide do
                local t = (k - 0.5) / countPerSide  -- 0..1 along the wall
                local x, z
                if side == "N" then
                    x = rc.X - halfW + 8 + t * (2 * halfW - 16) + math.random(-2, 2)
                    z = rc.Z - halfD + inset
                elseif side == "S" then
                    x = rc.X - halfW + 8 + t * (2 * halfW - 16) + math.random(-2, 2)
                    z = rc.Z + halfD - inset
                elseif side == "E" then
                    x = rc.X + halfW - inset
                    z = rc.Z - halfD + 8 + t * (2 * halfD - 16) + math.random(-2, 2)
                else  -- W
                    x = rc.X - halfW + inset
                    z = rc.Z - halfD + 8 + t * (2 * halfD - 16) + math.random(-2, 2)
                    local dx, dz = x - heartXZ.X, z - heartXZ.Z
                    if math.sqrt(dx*dx + dz*dz) < heartAvoid then
                        i = i + 1  -- still bump the stagger counter so timing doesn't clump
                        continue
                    end
                end
                i = i + 1
                spawnTree(decor, x, z, (startDelayStep or 0.04) * i)
            end
        end
    end

    local function growStageDecor(stage)
        -- Stages 2+ ADD to existing decor rather than replacing it, so stage 3
        -- keeps the stage 2 trees and adds more. Find-or-create the folder.
        local decor = tdRoom:FindFirstChild("StageDecor")
        if not decor then
            decor = Instance.new("Folder")
            decor.Name = "StageDecor"
            decor.Parent = tdRoom
        end

        if stage < 2 then return end  -- stage 1 has no extra decor

        -- Tree placement per stage. Each stage ADDS a ring:
        --   Stage 2 (Day):   4 per side × 4 sides = 16 trees, flush to wall (inset 1.5)
        --   Stage 3 (Dusk): +10 per side × 4 sides = 40 more, pushed slightly into
        --                    the arena (inset 3.5) so they stand out visually
        --   Stage 4 (Night): no new trees (keeps stage 3's), plus torches
        if stage == 2 then
            placeTreeRing(decor, 4, 1.5, 0.06, 0)
        elseif stage == 3 then
            growExistingTrees(12, 10)
            placeTreeRing(decor, 10, 3.5, 0.03, 20)
        end

        -- Stage 4 (night/final boss): add torches at fixed positions, evenly
        -- spaced around the room perimeter just inside the walls.
        if stage >= 4 then
            local torchInset = 3
            local torchPositions = {
                {rc.X - halfW * 0.6, rc.Z - halfD + torchInset},
                {rc.X - halfW * 0.2, rc.Z - halfD + torchInset},
                {rc.X + halfW * 0.2, rc.Z - halfD + torchInset},
                {rc.X + halfW * 0.6, rc.Z - halfD + torchInset},
                {rc.X - halfW * 0.6, rc.Z + halfD - torchInset},
                {rc.X - halfW * 0.2, rc.Z + halfD - torchInset},
                {rc.X + halfW * 0.2, rc.Z + halfD - torchInset},
                {rc.X + halfW * 0.6, rc.Z + halfD - torchInset},
                {rc.X - halfW + torchInset, rc.Z - halfD * 0.4},
                {rc.X - halfW + torchInset, rc.Z + halfD * 0.4},
                {rc.X + halfW - torchInset, rc.Z - halfD * 0.4},
                {rc.X + halfW - torchInset, rc.Z + halfD * 0.4},
            }
            for _, pos in ipairs(torchPositions) do
                spawnTorch(decor, pos[1], pos[2])
            end
        end
    end

    -- Publish
    ctx.STAGE_LIGHTING     = STAGE_LIGHTING
    ctx.tweenStageLighting = tweenStageLighting
    ctx.growStageDecor     = growStageDecor
    ctx.clearStageDecor    = clearStageDecor  -- DevReset uses this
end

return StageVisuals
