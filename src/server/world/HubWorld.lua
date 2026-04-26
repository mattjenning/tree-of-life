--[[
    HubWorld.lua — Hub overworld geometry: clearing, forest trees,
    giant tree with carved doorway + portal, leafy canopy, sun rays,
    and base Lighting tuning.

    setup(ctx) reads module-level constants and helpers from ctx, then
    builds everything under a top-level "TreeOfLifeHub" Model in the
    Workspace. Publishes three fields downstream modules need:
      ctx.hub            -- Model, for any further parenting
      ctx.treeBase       -- Vector3, doorway/portal anchor
      ctx.trunkSurfaceZ  -- number, Z of trunk's front face (used by
                            Portal and DevRemotes for spawn CFrames)

    Constants read from ctx (set by the hub orchestrator):
      CLEARING_CENTER, CLEARING_RADIUS,
      GIANT_TREE_OFFSET, GIANT_TREE_HEIGHT,
      TRUNK_BASE_RADIUS, BASE_FLARE_FACTOR, BASE_FLARE_FRAC,
      WALL_RINGS,
      UMBRELLA_BOTTOM_Y, UMBRELLA_OUTER_R, UMBRELLA_LAYERS,
      SUN_RAY_DIRECTION, CLOCK_TIME, GEO_LATITUDE

    Helpers read from ctx:
      makePart, rand, catmullRom, sampleSpline, trunkRadius
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags = require(Shared:WaitForChild("Tags"))

local HubWorld = {}

function HubWorld.setup(ctx)
    local CLEARING_CENTER    = ctx.CLEARING_CENTER
    local CLEARING_RADIUS    = ctx.CLEARING_RADIUS
    local GIANT_TREE_OFFSET  = ctx.GIANT_TREE_OFFSET
    local GIANT_TREE_HEIGHT  = ctx.GIANT_TREE_HEIGHT
    local TRUNK_BASE_RADIUS  = ctx.TRUNK_BASE_RADIUS
    local BASE_FLARE_FACTOR  = ctx.BASE_FLARE_FACTOR
    local WALL_RINGS         = ctx.WALL_RINGS
    local UMBRELLA_BOTTOM_Y  = ctx.UMBRELLA_BOTTOM_Y
    local UMBRELLA_OUTER_R   = ctx.UMBRELLA_OUTER_R
    local UMBRELLA_LAYERS    = ctx.UMBRELLA_LAYERS
    local SUN_RAY_DIRECTION  = ctx.SUN_RAY_DIRECTION
    local CLOCK_TIME         = ctx.CLOCK_TIME
    local GEO_LATITUDE       = ctx.GEO_LATITUDE

    local makePart      = ctx.makePart
    local rand          = ctx.rand
    local sampleSpline  = ctx.sampleSpline
    local trunkRadius   = ctx.trunkRadius

    local hub = Instance.new("Model")
    hub.Name = "TreeOfLifeHub"
    hub.Parent = Workspace

    ------------------------------------------------------------
    -- HUB
    ------------------------------------------------------------
    makePart({
        Name = "ClearingFloor",
        Shape = Enum.PartType.Cylinder,
        Size = Vector3.new(2, CLEARING_RADIUS * 2, CLEARING_RADIUS * 2),
        CFrame = CFrame.new(CLEARING_CENTER) * CFrame.Angles(0, 0, math.rad(90)),
        Material = Enum.Material.Grass,
        Color = Color3.fromRGB(86, 140, 58),
        Parent = hub,
    })

    local function buildSmallTree(pos, heightMin, heightMax)
        local tree = Instance.new("Model")
        tree.Name = "ForestTree"
        tree.Parent = hub
        local height = rand(heightMin, heightMax)
        local trunkR = rand(2.8, 4.2)
        makePart({
            Name = "Trunk",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(height, trunkR * 2, trunkR * 2),
            CFrame = CFrame.new(pos + Vector3.new(0, height/2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(92, 64, 42),
            Parent = tree,
        })
        for _ = 1, 3 do
            local r = rand(11, 17)
            local offset = Vector3.new(rand(-4,4), height + rand(-3, 6), rand(-4,4))
            makePart({
                Name = "Canopy",
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(r*2, r*2, r*2),
                CFrame = CFrame.new(pos + offset),
                Material = Enum.Material.Grass,
                Color = Color3.fromRGB(48, 110, 50):Lerp(Color3.fromRGB(70, 140, 60), math.random()),
                Parent = tree,
            })
        end
    end

    for ringIdx, ring in ipairs(WALL_RINGS) do
        local phaseOffset = (ringIdx - 1) * (math.pi / 6)
        for i = 1, ring.count do
            local angle = (i / ring.count) * math.pi * 2 + phaseOffset + rand(-0.04, 0.04)
            local r = ring.radius + rand(-4, 4)
            local pos = CLEARING_CENTER + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
            buildSmallTree(pos, ring.heightMin, ring.heightMax)
        end
    end

    local giantTree = Instance.new("Model")
    giantTree.Name = "GiantTree"
    giantTree.Parent = hub

    local treeBase = CLEARING_CENTER + GIANT_TREE_OFFSET
    local H = GIANT_TREE_HEIGHT
    local trunkPoints = {
        treeBase + Vector3.new( 0,      0,    0),
        treeBase + Vector3.new( 1,  H*0.08,   2),
        treeBase + Vector3.new(-3,  H*0.18,   4),
        treeBase + Vector3.new(-5,  H*0.30,   1),
        treeBase + Vector3.new(-2,  H*0.42,  -3),
        treeBase + Vector3.new( 3,  H*0.55,  -2),
        treeBase + Vector3.new( 6,  H*0.68,   1),
        treeBase + Vector3.new( 4,  H*0.80,   4),
        treeBase + Vector3.new( 1,  H*0.90,   3),
        treeBase + Vector3.new( 0,  H,        1),
    }

    local SAMPLES = 50
    local sampledPositions = {}
    for i = 0, SAMPLES do
        sampledPositions[i] = sampleSpline(trunkPoints, i / SAMPLES)
    end
    for i = 0, SAMPLES - 1 do
        local a = sampledPositions[i]
        local b = sampledPositions[i + 1]
        local mid = (a + b) * 0.5
        local dir = (b - a)
        local len = dir.Magnitude
        if len > 0.01 then
            local t = i / SAMPLES
            local radius = trunkRadius(t)
            local cf = CFrame.lookAt(mid, mid + dir) * CFrame.Angles(0, math.rad(90), 0)
            makePart({
                Name = "TrunkSegment",
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(len + 1.0, radius * 2, radius * 2),
                CFrame = cf,
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(110, 78, 48):Lerp(Color3.fromRGB(95, 65, 40), math.random() * 0.3),
                Parent = giantTree,
            })
        end
    end

    local PORTAL_YAW = math.rad(90)
    local PORTAL_GAP = math.rad(35)
    for i = 1, 14 do
        local a = (i / 14) * math.pi * 2
        local diff = math.abs((a - PORTAL_YAW + math.pi) % (2*math.pi) - math.pi)
        if diff > PORTAL_GAP then
            local rootLen = rand(16, 24)
            local rootHeight = rand(7, 11)
            local dist = rand(12, 16)
            makePart({
                Name = "Buttress",
                Size = Vector3.new(rootLen, rootHeight, rand(5, 7)),
                CFrame = CFrame.new(treeBase + Vector3.new(math.cos(a) * dist, rootHeight/2, math.sin(a) * dist))
                         * CFrame.Angles(0, -a, math.rad(rand(12, 22))),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(95, 65, 40),
                Parent = giantTree,
            })
            if math.random() < 0.6 then
                local a2 = a + rand(-0.15, 0.15)
                makePart({
                    Name = "ButtressSmall",
                    Size = Vector3.new(rootLen * 0.6, rootHeight * 0.7, 3),
                    CFrame = CFrame.new(treeBase + Vector3.new(math.cos(a2) * (dist - 2), rootHeight/3, math.sin(a2) * (dist - 2)))
                             * CFrame.Angles(0, -a2, math.rad(rand(10, 20))),
                    Material = Enum.Material.Wood,
                    Color = Color3.fromRGB(88, 60, 38),
                    Parent = giantTree,
                })
            end
        end
    end

    local trunkSurfaceZ = treeBase.Z + TRUNK_BASE_RADIUS * BASE_FLARE_FACTOR
    -- Sphere acts as the hollow: positioned so its front edge sits well inside
    -- the trunk, creating a carved-in appearance.
    local SPHERE_RADIUS = 9
    local SPHERE_BULGE = -5.5  -- negative = front of sphere is recessed into the trunk
    local sphereCenterZ = trunkSurfaceZ - SPHERE_RADIUS + SPHERE_BULGE
    -- Portal sits just in front of the sphere's front face, tilted back to match
    -- the trunk's outward flare so it lays against the slope.
    local PORTAL_TILT_DEG = 8  -- top of portal leans into tree, bottom leans out
    local portalZ = trunkSurfaceZ - 5.5  -- recessed deep into the trunk
    local doorwayCenter = Vector3.new(treeBase.X, 7, portalZ)

    makePart({
        Name = "DoorwayInterior",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(SPHERE_RADIUS * 2, SPHERE_RADIUS * 2, SPHERE_RADIUS * 2),
        CFrame = CFrame.new(treeBase.X, 7, sphereCenterZ),
        Material = Enum.Material.Slate,
        Color = Color3.fromRGB(10, 7, 5),
        Parent = giantTree,
    })

    for i = 0, 14 do
        local a = math.pi + (i / 14) * math.pi
        local archR = 7
        local x = math.cos(a) * archR
        local y = math.sin(a) * archR + 7
        if y > 0.5 then
            makePart({
                Name = "HollowRim",
                Size = Vector3.new(2.5, 2.5, 3),
                CFrame = CFrame.new(treeBase.X + x, y - 7, trunkSurfaceZ - 7)
                         * CFrame.Angles(0, 0, a + math.pi/2),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(75, 48, 28),
                Parent = giantTree,
            })
        end
    end

    -- Portal: rotated 90° around Y to face camera, then tilted back by
    -- PORTAL_TILT_DEG around the X axis so it matches the trunk's flare.
    -- Negative X-rotation tips the top backward (into the tree).
    local portal = makePart({
        Name = "Portal",
        Shape = Enum.PartType.Cylinder,
        Size = Vector3.new(0.6, 13, 11),
        CFrame = CFrame.new(doorwayCenter)
                 * CFrame.Angles(math.rad(-PORTAL_TILT_DEG), math.rad(90), 0),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(60, 255, 120),
        Transparency = 0.15,
        CanCollide = false,
        Parent = giantTree,
    })

    do
        local light = Instance.new("PointLight")
        light.Color = Color3.fromRGB(100, 255, 140)
        light.Brightness = 4
        light.Range = 45
        light.Parent = portal
        local attach = Instance.new("Attachment")
        attach.Parent = portal
        local particles = Instance.new("ParticleEmitter")
        particles.Color = ColorSequence.new(Color3.fromRGB(120, 255, 150))
        particles.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.4),
            NumberSequenceKeypoint.new(1, 2.8),
        })
        particles.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.2),
            NumberSequenceKeypoint.new(1, 1),
        })
        particles.Lifetime = NumberRange.new(1.2, 2.2)
        particles.Rate = 35
        particles.Speed = NumberRange.new(1, 3)
        particles.SpreadAngle = Vector2.new(180, 180)
        particles.LightEmission = 0.6
        particles.Parent = attach
    end

    local signAnchor = makePart({
        Name = "SignAnchor",
        Size = Vector3.new(1, 1, 1),
        CFrame = CFrame.new(treeBase.X, 14, trunkSurfaceZ + 0.5),
        Transparency = 1,
        CanCollide = false,
        Parent = giantTree,
    })
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.fromOffset(360, 90)
    billboard.LightInfluence = 0
    billboard.MaxDistance = 500
    billboard.Parent = signAnchor
    local signLabel = Instance.new("TextLabel")
    signLabel.Size = UDim2.fromScale(1, 1)
    signLabel.BackgroundTransparency = 1
    signLabel.Text = "SAVE THE WORLD"
    signLabel.TextColor3 = Color3.fromRGB(255, 60, 60)
    signLabel.TextStrokeColor3 = Color3.fromRGB(120, 0, 0)
    signLabel.TextStrokeTransparency = 0
    signLabel.Font = Enum.Font.FredokaOne
    signLabel.TextScaled = true
    signLabel.Parent = billboard
    local signLight = Instance.new("PointLight")
    signLight.Color = Color3.fromRGB(255, 60, 60)
    signLight.Brightness = 2.5
    signLight.Range = 22
    signLight.Parent = signAnchor

    local branchDefs = {
        {trunkT = 0.55, yaw = math.rad(  40), length = 30, tilt = math.rad(25)},
        {trunkT = 0.65, yaw = math.rad( 200), length = 28, tilt = math.rad(20)},
        {trunkT = 0.72, yaw = math.rad( 300), length = 26, tilt = math.rad(30)},
        {trunkT = 0.80, yaw = math.rad( 110), length = 24, tilt = math.rad(25)},
        {trunkT = 0.88, yaw = math.rad( 250), length = 22, tilt = math.rad(35)},
    }

    local function buildBranch(def)
        local origin = sampleSpline(trunkPoints, def.trunkT)
        local outDir = Vector3.new(math.cos(def.yaw), math.sin(def.tilt), math.sin(def.yaw)).Unit
        local segments = 3
        local prev = origin
        for s = 1, segments do
            local u = s / segments
            local curveLift = Vector3.new(0, def.length * 0.15 * math.sin(u * math.pi), 0)
            local nextPt = origin + outDir * (def.length * u) + curveLift
            local mid = (prev + nextPt) * 0.5
            local dir = nextPt - prev
            local len = dir.Magnitude
            local radius = 2.5 * (1 - u * 0.6) + 0.5
            makePart({
                Name = "BranchSegment",
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(len + 0.6, radius * 2, radius * 2),
                CFrame = CFrame.lookAt(mid, mid + dir) * CFrame.Angles(0, math.rad(90), 0),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(105, 72, 44),
                Parent = giantTree,
            })
            prev = nextPt
        end
        local actualTip = prev
        local tipCore = makePart({
            Name = "BranchLeafCore",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(16, 12, 16),
            CFrame = CFrame.new(actualTip),
            Material = Enum.Material.Grass,
            Color = Color3.fromRGB(58, 125, 55),
            Parent = giantTree,
        })
        CollectionService:AddTag(tipCore, Tags.Canopy)
        for _ = 1, 4 do
            local off = Vector3.new(rand(-5, 5), rand(-2, 5), rand(-5, 5))
            local r = rand(5, 8)
            local puff = makePart({
                Name = "BranchLeafPuff",
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(r*2, r*2, r*2),
                CFrame = CFrame.new(actualTip + off),
                Material = Enum.Material.Grass,
                Color = Color3.fromRGB(48, 110, 50):Lerp(Color3.fromRGB(80, 160, 70), math.random()),
                Parent = giantTree,
            })
            CollectionService:AddTag(puff, Tags.Canopy)
        end
    end
    for _, def in ipairs(branchDefs) do buildBranch(def) end

    for _, layer in ipairs(UMBRELLA_LAYERS) do
        local layerY = UMBRELLA_BOTTOM_Y + layer.yOff
        for i = 1, layer.puffs do
            local a = (i / layer.puffs) * math.pi * 2 + rand(-0.08, 0.08)
            local pr = layer.puffSize + rand(-3, 3)
            local puff = makePart({
                Name = "UmbrellaPuff",
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(pr*2, pr*1.3, pr*2),
                CFrame = CFrame.new(
                    treeBase.X + math.cos(a) * layer.radius,
                    layerY + rand(-2, 2),
                    treeBase.Z + math.sin(a) * layer.radius
                ),
                Material = Enum.Material.Grass,
                Color = Color3.fromRGB(48, 110, 50):Lerp(Color3.fromRGB(80, 160, 70), math.random()),
                Parent = giantTree,
            })
            CollectionService:AddTag(puff, Tags.Canopy)
        end
        if layer.radius < UMBRELLA_OUTER_R * 0.8 then
            for _ = 1, math.max(3, math.floor(layer.puffs * 0.5)) do
                local a = rand(0, math.pi * 2)
                local innerR = layer.radius * rand(0.3, 0.7)
                local pr = layer.puffSize * rand(0.7, 1.0)
                local puff = makePart({
                    Name = "UmbrellaFill",
                    Shape = Enum.PartType.Ball,
                    Size = Vector3.new(pr*2, pr*1.4, pr*2),
                    CFrame = CFrame.new(
                        treeBase.X + math.cos(a) * innerR,
                        layerY + rand(-2, 3),
                        treeBase.Z + math.sin(a) * innerR
                    ),
                    Material = Enum.Material.Grass,
                    Color = Color3.fromRGB(55, 118, 52):Lerp(Color3.fromRGB(78, 155, 68), math.random()),
                    Parent = giantTree,
                })
                CollectionService:AddTag(puff, Tags.Canopy)
            end
        end
    end

    local topPos = sampleSpline(trunkPoints, 1.0)
    for i = 1, 5 do
        local a = (i / 5) * math.pi * 2
        local pr = rand(14, 20)
        local puff = makePart({
            Name = "CrownPuff",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(pr*2, pr*2, pr*2),
            CFrame = CFrame.new(
                topPos.X + math.cos(a) * 12,
                topPos.Y + rand(-4, 8),
                topPos.Z + math.sin(a) * 12
            ),
            Material = Enum.Material.Grass,
            Color = Color3.fromRGB(60, 130, 58),
            Parent = giantTree,
        })
        CollectionService:AddTag(puff, Tags.Canopy)
    end

    local sunDir = SUN_RAY_DIRECTION.Unit
    local rayLandings = {
        Vector3.new(-30, 0,  20), Vector3.new( 20, 0,  40), Vector3.new( 40, 0, -10),
        Vector3.new(-50, 0, -20), Vector3.new( 10, 0, -30), Vector3.new(-10, 0,  60),
    }
    for _, landing in ipairs(rayLandings) do
        local top = landing - sunDir * 140
        local bot = landing
        local mid = (top + bot) * 0.5
        local dir = bot - top
        local len = dir.Magnitude
        makePart({
            Name = "SunRay",
            Size = Vector3.new(10, len, 10),
            CFrame = CFrame.lookAt(mid, mid + dir) * CFrame.Angles(math.rad(90), 0, 0),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 245, 200),
            Transparency = 0.85,
            CanCollide = false,
            CastShadow = false,
            Parent = hub,
        })
    end

    Lighting.Ambient = Color3.fromRGB(120, 128, 108)
    Lighting.OutdoorAmbient = Color3.fromRGB(140, 148, 120)
    Lighting.Brightness = 2.5
    Lighting.ClockTime = CLOCK_TIME
    Lighting.GeographicLatitude = GEO_LATITUDE
    Lighting.ColorShift_Top = Color3.fromRGB(40, 30, 10)
    Lighting.ColorShift_Bottom = Color3.fromRGB(10, 20, 5)
    Lighting.FogEnd = 380
    Lighting.FogStart = 150
    Lighting.FogColor = Color3.fromRGB(185, 205, 175)

    if not Lighting:FindFirstChildOfClass("SunRaysEffect") then
        local rays = Instance.new("SunRaysEffect")
        rays.Intensity = 0.25
        rays.Spread = 0.8
        rays.Parent = Lighting
    end
    if not Lighting:FindFirstChildOfClass("BloomEffect") then
        local bloom = Instance.new("BloomEffect")
        bloom.Intensity = 0.5
        bloom.Size = 20
        bloom.Threshold = 0.95
        bloom.Parent = Lighting
    end
    if not Lighting:FindFirstChildOfClass("Atmosphere") then
        local atmos = Instance.new("Atmosphere")
        atmos.Density = 0.3
        atmos.Color = Color3.fromRGB(199, 199, 199)
        atmos.Decay = Color3.fromRGB(106, 112, 90)
        atmos.Glare = 0.3
        atmos.Haze = 1.2
        atmos.Parent = Lighting
    end

    -- Publish the fields downstream modules need.
    ------------------------------------------------------------
    -- INFINITE ARENA portal — swirling green disc on the ground,
    -- 50 studs stage-left of the tree (theater convention: tree's
    -- -X) and 10 studs toward the player (+Z). Touch fires the
    -- EnterInfinite remote, which the Infinite system handles.
    --
    -- Phase 1 of project_infinite_arena.md (balance / benchmark
    -- sandbox). Locked behind a successful run normally; for
    -- testing the gate (Workspace.InfiniteUnlocked) is true by
    -- default. Touched mob-tags / character HRP filter is the
    -- standard pattern (don't fire on every leaf that drifts onto
    -- the disc).
    --
    -- Visual: a flat green disc with two concentric rings + a
    -- rotating "spiral arm" cylinder on top. The spiral rotates
    -- via TweenService for the swirl-vortex feel.
    ------------------------------------------------------------
    do
        local infinitePortalPos = treeBase + Vector3.new(-50, 0.05, 10)
        local portalFolder = Instance.new("Folder")
        portalFolder.Name = "InfinitePortal"
        portalFolder.Parent = hub
        print(("[InfinitePortal] built at (%.0f, %.1f, %.0f) — stage-left of tree"):format(
            infinitePortalPos.X, infinitePortalPos.Y, infinitePortalPos.Z))

        -- Sky beam — a tall cylinder reaching up from the disc so the
        -- portal is findable from anywhere in the hub. Visual marker
        -- only; not a hit-test target.
        local beam = makePart({
            Name = "InfinitePortalBeam",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(60, 1.5, 1.5),
            CFrame = CFrame.new(infinitePortalPos + Vector3.new(0, 30, 0))
                   * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(120, 255, 140),
            Transparency = 0.7,
            CanCollide = false,
            Parent = portalFolder,
        })
        beam.CastShadow = false

        -- Floating label so the player can see "INFINITE ARENA" from
        -- the spawn area even before they spot the disc itself.
        local labelAnchor = makePart({
            Name = "InfinitePortalLabelAnchor",
            Size = Vector3.new(0.2, 0.2, 0.2),
            CFrame = CFrame.new(infinitePortalPos + Vector3.new(0, 8, 0)),
            Transparency = 1,
            CanCollide = false,
            Parent = portalFolder,
        })
        local billboard = Instance.new("BillboardGui")
        billboard.Size = UDim2.fromOffset(280, 60)
        billboard.LightInfluence = 0
        billboard.AlwaysOnTop = true
        billboard.MaxDistance = 250
        billboard.Parent = labelAnchor
        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Text = "INFINITE ARENA"
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 32
        label.TextColor3 = Color3.fromRGB(180, 255, 200)
        label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        label.TextStrokeTransparency = 0.3
        label.Parent = billboard

        -- Outer ring: thin cylinder lying flat on its side. We use
        -- Shape=Cylinder which orients along the X axis — rotate 90°
        -- around Z to make it lie flat (axis pointing up).
        local outerRing = makePart({
            Name = "InfinitePortalOuterRing",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.3, 14, 14),
            CFrame = CFrame.new(infinitePortalPos)
                   * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(80, 220, 100),
            Transparency = 0.35,
            CanCollide = false,
            Parent = portalFolder,
        })
        local _ = outerRing

        -- Inner disc: smaller, brighter, this is the actual "vortex
        -- mouth." Touched event fires off this part — the outer ring
        -- is decorative.
        local disc = makePart({
            Name = "InfinitePortalDisc",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.4, 10, 10),
            CFrame = CFrame.new(infinitePortalPos + Vector3.new(0, 0.1, 0))
                   * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(60, 255, 110),
            Transparency = 0.15,
            CanCollide = false,
            Parent = portalFolder,
        })

        -- Spiral arm: a long thin cylinder lying on top of the disc.
        -- Tweened rotation around the world Y axis fakes the swirl.
        -- We nest TWO arms at 120° offsets so the spiral reads as a
        -- vortex rather than a single spinning bar.
        for armI = 0, 1 do
            local arm = makePart({
                Name = "InfinitePortalArm" .. armI,
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(0.15, 9, 0.6),
                -- Cylinder long axis is X. We want it horizontal on
                -- the disc, so place at portal pos + small Y lift,
                -- with the cylinder's X axis lying in the X-Z plane.
                -- An additional 90° around Y gives 2-arm separation.
                CFrame = CFrame.new(infinitePortalPos + Vector3.new(0, 0.18 + armI * 0.05, 0))
                       * CFrame.Angles(0, math.rad(armI * 90), 0),
                Material = Enum.Material.Neon,
                Color = Color3.fromRGB(140, 255, 160),
                Transparency = 0.25,
                CanCollide = false,
                Parent = portalFolder,
            })
            -- Spin via RunService heartbeat — TweenService can't loop
            -- a CFrame indefinitely without re-issuing tweens. A
            -- per-frame angle update is cheap.
            local startAngle = armI * math.pi
            local rotSpeed = (armI == 0) and 1.6 or -1.1  -- counter-rotate for vortex feel
            game:GetService("RunService").Heartbeat:Connect(function()
                if not arm.Parent then return end
                local t = os.clock()
                arm.CFrame = CFrame.new(infinitePortalPos + Vector3.new(0, 0.18 + armI * 0.05, 0))
                           * CFrame.Angles(0, startAngle + t * rotSpeed, 0)
            end)
        end

        -- Glow + particle wash above the portal.
        local light = Instance.new("PointLight")
        light.Color = Color3.fromRGB(120, 255, 140)
        light.Brightness = 5
        light.Range = 30
        light.Parent = disc
        local attach = Instance.new("Attachment")
        attach.Parent = disc
        local particles = Instance.new("ParticleEmitter")
        particles.Color = ColorSequence.new(Color3.fromRGB(140, 255, 160))
        particles.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.3),
            NumberSequenceKeypoint.new(1, 1.6),
        })
        particles.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.3),
            NumberSequenceKeypoint.new(1, 1),
        })
        particles.Lifetime = NumberRange.new(1.5, 2.5)
        particles.Rate = 18
        particles.Speed = NumberRange.new(2, 5)
        particles.SpreadAngle = Vector2.new(15, 15)
        particles.LightEmission = 0.7
        particles.Parent = attach

        -- Touched handler: fires EnterInfinite when a player walks
        -- onto the disc. Filter to HumanoidRootPart hits via the
        -- character lookup — Touched also fires on every dropped
        -- leaf, drifting butterfly, etc. The unlocked gate
        -- (Workspace.InfiniteUnlocked, default true for testing)
        -- is checked here so locked players bounce off without a
        -- server round-trip.
        Workspace:SetAttribute("InfiniteUnlocked", true)
        local Players = game:GetService("Players")
        local lastEnterAt = {}  -- per-player os.clock() of last successful entry; 1s debounce
        disc.Touched:Connect(function(other)
            if not other or not other.Parent then return end
            local character = other.Parent
            local player = Players:GetPlayerFromCharacter(character)
            if not player then
                -- Touched also fires for falling leaves / butterfly drift /
                -- decorative VFX. Quietly ignore non-player touches.
                return
            end
            if other.Name ~= "HumanoidRootPart" then
                print(("[InfinitePortal] touched by '%s' (not HRP) — ignoring"):format(other.Name))
                return
            end
            if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
                print("[InfinitePortal] touched but InfiniteUnlocked=false — ignoring")
                return
            end
            local now = os.clock()
            if now - (lastEnterAt[player.UserId] or 0) < 1.0 then
                return  -- debounced; still in cooldown from prior touch
            end
            lastEnterAt[player.UserId] = now
            -- Canonical entry function lives in systems/Infinite.lua.
            -- Scenario defaults to "Mixed" until the picker UI lands.
            print(("[InfinitePortal] %s touched disc — calling ctx.enterInfinite"):format(player.Name))
            if ctx.enterInfinite then
                ctx.enterInfinite(player, "Mixed")
            else
                warn("[InfinitePortal] ctx.enterInfinite not published — boot order broken!")
            end
        end)
    end

    ctx.hub = hub
    ctx.treeBase = treeBase
    ctx.trunkSurfaceZ = trunkSurfaceZ
    ctx.portal = portal  -- hub-tree doorway; downstream wires Touched + ClickDetector
end

return HubWorld
