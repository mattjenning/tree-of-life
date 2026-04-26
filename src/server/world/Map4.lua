--[[
    Map4.lua — Pickle Swamp / Infinite Arena terrain.

    Phase 1 of project_infinite_arena.md (balance / benchmark sandbox).
    Reached via the hub's swirling green portal, NOT via SwitchMap from
    a prior map. Tower placement, mob walking, StatLedger all reuse the
    standard mapId pipeline; the wave system gets a custom infinite
    spawner instead of WAVES[4] (B2d follow-up).

    Visual brief (Matthew, 2026-04-26):
      • Swamp-like base — dark slate-green floor with irregular bumps
      • Steam clouds drifting above the ground (anchored translucent
        spheres bobbing via Heartbeat tweens)
      • Green slime river winding N-S across the map
      • Rickety wooden bridges where the mob path crosses the river
      • A mini volcano in the NE corner oozing green slime + smoke
      • Pickle trees with glowing pickle-fruit point lights — the fruit
        is the primary light source for the map (no skybox sun)

    Mirrors Map3.lua's setup(ctx) shape:
      Reads:  MAP4_CENTER, MAP4_WIDTH, MAP4_DEPTH, MAP4_HEIGHT,
              CELL_SIZE, MAP4_COL_OFFSET, MAP4_TOTAL_COLS, MAP4_ROWS,
              MAP4_COLS, HEART_EXCLUSION_CELLS, makePart, rand,
              cellToWorld, gridState, pathHalf
      Publishes:
              ctx.map4Room
              ctx.map4Heart
              ctx.MAP4_PLAYER_SPAWN_CF
]]

local Workspace         = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags   = require(Shared:WaitForChild("Tags"))
local Config = require(Shared:WaitForChild("Config"))

local Map4 = {}

function Map4.setup(ctx)
    local MAP4_CENTER     = ctx.MAP4_CENTER
    local MAP4_WIDTH      = ctx.MAP4_WIDTH
    local MAP4_DEPTH      = ctx.MAP4_DEPTH
    local MAP4_HEIGHT     = ctx.MAP4_HEIGHT
    local CELL_SIZE       = ctx.CELL_SIZE
    local MAP4_COL_OFFSET = ctx.MAP4_COL_OFFSET
    local MAP4_TOTAL_COLS = ctx.MAP4_TOTAL_COLS
    local MAP4_ROWS       = ctx.MAP4_ROWS
    local HEART_EXCLUSION_CELLS = ctx.HEART_EXCLUSION_CELLS

    local makePart = ctx.makePart
    local rand     = ctx.rand

    local cellToWorld = ctx.cellToWorld
    local gridState   = ctx.gridState
    local pathHalf    = ctx.pathHalf

    local map4Room = Instance.new("Model")
    map4Room.Name = "TreeOfLifeMap4Room"
    map4Room.Parent = Workspace

    local m4c       = MAP4_CENTER
    local m4HalfW   = MAP4_WIDTH / 2
    local m4HalfD   = MAP4_DEPTH / 2
    local floorTopY = m4c.Y + 1   -- floor part top surface

    -- Player spawn — on the floor near the path's start corner so the
    -- player lands looking toward the heart on entry.
    local MAP4_PLAYER_SPAWN_POS = m4c + Vector3.new(-m4HalfW + 18, 4, m4HalfD - 22)
    local MAP4_PLAYER_SPAWN_CF = CFrame.lookAt(
        MAP4_PLAYER_SPAWN_POS,
        Vector3.new(m4c.X + 30, m4c.Y + 1, m4c.Z))

    ------------------------------------------------------------
    -- FLOOR — dark slate-green swamp surface. Single big slab; the
    -- "irregular bumps" come from scattered raised slate tiles
    -- placed on top (next block) so we don't have to fragment the
    -- main floor into 4000+ parts.
    ------------------------------------------------------------
    makePart({
        Name = "Map4Floor",
        Size = Vector3.new(MAP4_WIDTH, 2, MAP4_DEPTH),
        CFrame = CFrame.new(m4c),
        Material = Enum.Material.Slate,
        Color = Color3.fromRGB(48, 58, 42),
        Parent = map4Room,
    })

    ------------------------------------------------------------
    -- INVISIBLE WALL BARRIERS (mob/player containment)
    ------------------------------------------------------------
    local INVIS_THICK = 1
    local function invisWall(name, size, cframe)
        local p = makePart({
            Name = name,
            Size = size,
            CFrame = cframe,
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(40, 30, 20),
            Transparency = 1,
            Parent = map4Room,
        })
        p.CastShadow = false
        return p
    end
    invisWall("Map4InvisWallW",
        Vector3.new(INVIS_THICK, MAP4_HEIGHT, MAP4_DEPTH + INVIS_THICK * 2),
        CFrame.new(m4c + Vector3.new(-m4HalfW - INVIS_THICK/2, MAP4_HEIGHT/2, 0)))
    invisWall("Map4InvisWallE",
        Vector3.new(INVIS_THICK, MAP4_HEIGHT, MAP4_DEPTH + INVIS_THICK * 2),
        CFrame.new(m4c + Vector3.new(m4HalfW + INVIS_THICK/2, MAP4_HEIGHT/2, 0)))
    invisWall("Map4InvisWallN",
        Vector3.new(MAP4_WIDTH, MAP4_HEIGHT, INVIS_THICK),
        CFrame.new(m4c + Vector3.new(0, MAP4_HEIGHT/2, -m4HalfD - INVIS_THICK/2)))
    invisWall("Map4InvisWallS",
        Vector3.new(MAP4_WIDTH, MAP4_HEIGHT, INVIS_THICK),
        CFrame.new(m4c + Vector3.new(0, MAP4_HEIGHT/2, m4HalfD + INVIS_THICK/2)))

    ------------------------------------------------------------
    -- ENEMY PATH waypoints (must be declared before river/bridges
    -- so the path-grid marking is in place when river-cells get
    -- "decor" painted under bridges).
    --
    -- Path layout: start in SW, two N-S legs separated by the river,
    -- end at heart in NE. Crosses the river (~col offset+30) twice.
    ------------------------------------------------------------
    local map4PathCells = {
        {MAP4_COL_OFFSET +  5, 58},   -- spawn
        {MAP4_COL_OFFSET + 38, 58},   -- east, just past first bridge
        {MAP4_COL_OFFSET + 38, 32},   -- north
        {MAP4_COL_OFFSET +  8, 32},   -- west — second bridge crossing
        {MAP4_COL_OFFSET +  8,  8},   -- north
        {MAP4_COL_OFFSET + 80,  8},   -- east, all the way to heart
    }
    local function markPathRect(c1, r1, c2, r2)
        local cmin, cmax = math.min(c1, c2), math.max(c1, c2)
        local rmin, rmax = math.min(r1, r2), math.max(r1, r2)
        for c = cmin, cmax do
            for r = rmin, rmax do
                if c >= MAP4_COL_OFFSET and c < MAP4_TOTAL_COLS
                   and r >= 0 and r < MAP4_ROWS then
                    gridState[c][r] = "path"
                end
            end
        end
    end
    for i = 1, #map4PathCells - 1 do
        local a, b = map4PathCells[i], map4PathCells[i+1]
        if a[1] == b[1] then
            markPathRect(a[1] - pathHalf, math.min(a[2], b[2]) - pathHalf,
                         a[1] + pathHalf, math.max(a[2], b[2]) + pathHalf)
        else
            markPathRect(math.min(a[1], b[1]) - pathHalf, a[2] - pathHalf,
                         math.max(a[1], b[1]) + pathHalf, a[2] + pathHalf)
        end
    end
    local m4HeartCell = map4PathCells[#map4PathCells]
    for dc = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
        for dr = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
            local cc, rr = m4HeartCell[1] + dc, m4HeartCell[2] + dr
            if cc >= MAP4_COL_OFFSET and cc < MAP4_TOTAL_COLS
               and rr >= 0 and rr < MAP4_ROWS then
                gridState[cc][rr] = "heart"
            end
        end
    end

    ------------------------------------------------------------
    -- SLIME RIVER — vertical winding ribbon at roughly col offset+22.
    -- Built as overlapping slate-blue cylinder segments (longer-axis
    -- horizontal, lying on the floor) to read as a continuous flow
    -- with subtle wobble. Glows green via Neon material.
    ------------------------------------------------------------
    local SLIME_COLOR = Color3.fromRGB(80, 220, 80)
    local riverCenterCol = MAP4_COL_OFFSET + 22
    local RIVER_HALF_WIDTH = 5  -- studs
    do
        local riverFolder = Instance.new("Folder")
        riverFolder.Name = "Map4SlimeRiver"
        riverFolder.Parent = map4Room
        local segCount = 22
        for i = 0, segCount - 1 do
            local t = i / (segCount - 1)
            local row = t * (MAP4_ROWS - 1)
            -- Sinusoidal wobble keeps it from being a perfectly
            -- straight line. Amplitude is small so the path-crossing
            -- bridge geometry still aligns at the bridge cells.
            local wobble = math.sin(t * math.pi * 1.4) * 4
            local centerCellWorld = cellToWorld(
                math.floor(riverCenterCol + wobble / CELL_SIZE),
                math.floor(row))
            local seg = makePart({
                Name = "SlimeRiverSeg" .. i,
                Size = Vector3.new(RIVER_HALF_WIDTH * 2, 0.6, CELL_SIZE * 4),
                CFrame = CFrame.new(centerCellWorld.X, floorTopY + 0.05, centerCellWorld.Z),
                Material = Enum.Material.Neon,
                Color = SLIME_COLOR,
                Transparency = 0.15,
                CanCollide = false,
                Parent = riverFolder,
            })
            seg.CastShadow = false
        end
        -- Slime banks — slightly raised mucky border parts on each
        -- side of the river to read as the muddy edge.
        for side = -1, 1, 2 do
            for i = 0, segCount - 1 do
                local t = i / (segCount - 1)
                local row = t * (MAP4_ROWS - 1)
                local wobble = math.sin(t * math.pi * 1.4) * 4
                local centerCellWorld = cellToWorld(
                    math.floor(riverCenterCol + wobble / CELL_SIZE),
                    math.floor(row))
                makePart({
                    Name = "SlimeBank" .. side .. "_" .. i,
                    Size = Vector3.new(2.5, 0.4, CELL_SIZE * 4),
                    CFrame = CFrame.new(
                        centerCellWorld.X + side * (RIVER_HALF_WIDTH + 1.2),
                        floorTopY + 0.2,
                        centerCellWorld.Z),
                    Material = Enum.Material.Slate,
                    Color = Color3.fromRGB(60, 70, 50),
                    Parent = riverFolder,
                })
            end
        end
    end

    ------------------------------------------------------------
    -- BRIDGES — at each row where the path crosses the river. Two
    -- planks across the river width, with two short post-pieces on
    -- each side for that "rickety wood" feel.
    ------------------------------------------------------------
    local bridgeRows = {58, 32}
    do
        local bridgeFolder = Instance.new("Folder")
        bridgeFolder.Name = "Map4Bridges"
        bridgeFolder.Parent = map4Room
        for _, br in ipairs(bridgeRows) do
            local crossX = cellToWorld(riverCenterCol, br).X
            local crossZ = cellToWorld(riverCenterCol, br).Z
            for plank = 0, 4 do
                makePart({
                    Name = "BridgePlank_" .. br .. "_" .. plank,
                    Size = Vector3.new(2.4, 0.4, RIVER_HALF_WIDTH * 2.4),
                    CFrame = CFrame.new(
                        crossX - 6 + plank * 3,
                        floorTopY + 0.3,
                        crossZ)
                        * CFrame.Angles(rand(-2, 2) * math.pi / 180,
                                        0,
                                        rand(-3, 3) * math.pi / 180),
                    Material = Enum.Material.Wood,
                    Color = Color3.fromRGB(95, 60, 35),
                    Parent = bridgeFolder,
                })
            end
            -- Posts at each end of the bridge.
            for postSide = -1, 1, 2 do
                makePart({
                    Name = "BridgePost_" .. br .. "_" .. postSide,
                    Size = Vector3.new(0.6, 4, 0.6),
                    CFrame = CFrame.new(
                        crossX + postSide * 7,
                        floorTopY + 2,
                        crossZ - RIVER_HALF_WIDTH * 1.1),
                    Material = Enum.Material.Wood,
                    Color = Color3.fromRGB(85, 55, 30),
                    Parent = bridgeFolder,
                })
                makePart({
                    Name = "BridgePost_" .. br .. "_" .. postSide .. "B",
                    Size = Vector3.new(0.6, 4, 0.6),
                    CFrame = CFrame.new(
                        crossX + postSide * 7,
                        floorTopY + 2,
                        crossZ + RIVER_HALF_WIDTH * 1.1),
                    Material = Enum.Material.Wood,
                    Color = Color3.fromRGB(85, 55, 30),
                    Parent = bridgeFolder,
                })
            end
        end
    end

    ------------------------------------------------------------
    -- MINI VOLCANO — stacked cylinders forming a cone in the NE
    -- corner, with a smoke ParticleEmitter at the top + slime
    -- drips that "ooze" toward the river. Visual only; doesn't
    -- damage / interact with mobs.
    ------------------------------------------------------------
    do
        local volcanoFolder = Instance.new("Folder")
        volcanoFolder.Name = "Map4Volcano"
        volcanoFolder.Parent = map4Room
        local volcanoBase = cellToWorld(MAP4_COL_OFFSET + 78, 58)
        local CONE_LAYERS = 8
        local BASE_R = 7
        local TIP_R  = 1.6
        local CONE_H = 14
        for i = 0, CONE_LAYERS - 1 do
            local t = i / (CONE_LAYERS - 1)
            local r = BASE_R + (TIP_R - BASE_R) * t
            local layer = makePart({
                Name = "VolcanoLayer" .. i,
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(CONE_H / CONE_LAYERS + 0.05, r * 2, r * 2),
                CFrame = CFrame.new(
                    volcanoBase.X,
                    floorTopY + (i + 0.5) * (CONE_H / CONE_LAYERS),
                    volcanoBase.Z)
                    * CFrame.Angles(0, 0, math.rad(90)),
                Material = Enum.Material.Slate,
                -- Gradient base→tip: ashy gray bottom, hot greenish top.
                Color = Color3.fromRGB(
                    math.floor(70 + t * 20),
                    math.floor(70 + t * 60),
                    math.floor(60 + t * 30)),
                Parent = volcanoFolder,
            })
            local _ = layer
        end
        -- Glowing slime mouth at the top.
        makePart({
            Name = "VolcanoMouth",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.6, TIP_R * 2.1, TIP_R * 2.1),
            CFrame = CFrame.new(
                volcanoBase.X, floorTopY + CONE_H + 0.2, volcanoBase.Z)
                * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Neon,
            Color = SLIME_COLOR,
            Transparency = 0.05,
            Parent = volcanoFolder,
        })
        -- Slime drip stream — visual ribbon from the mouth down toward
        -- the river. Anchored Parts; not animated.
        local riverEdgeWorld = cellToWorld(riverCenterCol, 58)
        for i = 0, 14 do
            local t = i / 14
            local px = volcanoBase.X * (1 - t) + riverEdgeWorld.X * t
            local pz = volcanoBase.Z * (1 - t) + riverEdgeWorld.Z * t
            local py = floorTopY + (CONE_H + 0.4) * (1 - t * t)  -- arcs down
            makePart({
                Name = "VolcanoOoze" .. i,
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(1.4 - t * 0.4, 1.4 - t * 0.4, 1.4 - t * 0.4),
                CFrame = CFrame.new(px, py, pz),
                Material = Enum.Material.Neon,
                Color = SLIME_COLOR,
                Transparency = 0.1 + t * 0.2,
                CanCollide = false,
                Parent = volcanoFolder,
            })
        end
        -- Smoke + sparks from the mouth.
        local smokeAttach = Instance.new("Attachment")
        smokeAttach.Position = Vector3.new(0, TIP_R, 0)
        smokeAttach.Parent = volcanoFolder:FindFirstChild("VolcanoMouth")
        local smoke = Instance.new("ParticleEmitter")
        smoke.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(160, 220, 130)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 100, 70)),
        })
        smoke.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1.2),
            NumberSequenceKeypoint.new(1, 4.5),
        })
        smoke.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.4),
            NumberSequenceKeypoint.new(1, 1),
        })
        smoke.Lifetime = NumberRange.new(2, 3.5)
        smoke.Rate = Config.Map4.Volcano.SmokeRate
        smoke.Speed = NumberRange.new(2, 4)
        smoke.SpreadAngle = Vector2.new(20, 20)
        smoke.LightEmission = 0.4
        smoke.Parent = smokeAttach
    end

    ------------------------------------------------------------
    -- STEAM CLOUDS — anchored translucent off-white-green spheres
    -- bobbing up/down via a single Heartbeat sine wave (cheap, no
    -- per-cloud TweenService traffic). Scattered across the map at
    -- low altitude (Y = 4-12 above floor).
    ------------------------------------------------------------
    do
        local steamFolder = Instance.new("Folder")
        steamFolder.Name = "Map4SteamClouds"
        steamFolder.Parent = map4Room
        local clouds = {}
        for i = 1, Config.Map4.SteamClouds.Count do
            -- Random position inside the arena, biased toward the
            -- river (steam rises off slime). Don't worry about path
            -- collision — clouds float well above the path.
            local cellCol = math.floor(MAP4_COL_OFFSET + 2 + rand(0, MAP4_TOTAL_COLS - MAP4_COL_OFFSET - 4))
            local cellRow = math.floor(2 + rand(0, MAP4_ROWS - 4))
            local pos = cellToWorld(cellCol, cellRow)
            local baseY = floorTopY + 5 + rand(0, 8)
            local size = 6 + rand(0, 5)
            local p = makePart({
                Name = "SteamCloud" .. i,
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(size, size * 0.7, size),
                CFrame = CFrame.new(pos.X, baseY, pos.Z),
                Material = Enum.Material.Neon,
                Color = Color3.fromRGB(220, 240, 220),
                Transparency = 0.78,
                CanCollide = false,
                Parent = steamFolder,
            })
            p.CastShadow = false
            table.insert(clouds, {
                part = p,
                baseY = baseY,
                phase = rand(0, math.pi * 2),
            })
        end
        -- Single Heartbeat tick drives all cloud bobs. ~36 sin calls
        -- per frame — negligible CPU.
        local bobAmp    = Config.Map4.SteamClouds.BobAmplitudeStud
        local bobPeriod = Config.Map4.SteamClouds.BobPeriodSec
        game:GetService("RunService").Heartbeat:Connect(function()
            local t = os.clock()
            for _, c in ipairs(clouds) do
                if c.part.Parent then
                    local y = c.baseY + math.sin(t * (math.pi * 2 / bobPeriod) + c.phase) * bobAmp
                    c.part.CFrame = CFrame.new(c.part.Position.X, y, c.part.Position.Z)
                end
            end
        end)
    end

    ------------------------------------------------------------
    -- PICKLE TREES — primary light source. Each tree = a tall
    -- trunk + a leafy canopy + N pickle-fruit Balls with PointLights
    -- inside them. Placed around the perimeter, avoiding the path.
    ------------------------------------------------------------
    do
        local treesFolder = Instance.new("Folder")
        treesFolder.Name = "Map4PickleTrees"
        treesFolder.Parent = map4Room

        -- Place trees at perimeter cells, evenly spaced by angle.
        local treeCount = Config.Map4.PickleTrees.Count
        local fruitsPerTree = Config.Map4.PickleTrees.FruitsPerTree
        local fruitLightRange = Config.Map4.PickleTrees.FruitLightRange
        for i = 1, treeCount do
            local angle = (i / treeCount) * math.pi * 2
            local rx = math.cos(angle) * (m4HalfW - 8)
            local rz = math.sin(angle) * (m4HalfD - 8)
            local trunkBaseX = m4c.X + rx
            local trunkBaseZ = m4c.Z + rz

            -- Skip if too close to a path waypoint (tree would block path).
            local skip = false
            for _, wp in ipairs(map4PathCells) do
                local wpW = cellToWorld(wp[1], wp[2])
                local dx = wpW.X - trunkBaseX
                local dz = wpW.Z - trunkBaseZ
                if dx * dx + dz * dz < 64 then
                    skip = true; break
                end
            end
            if skip then continue end

            local trunkHeight = 18 + rand(-2, 4)
            local trunk = makePart({
                Name = "PickleTreeTrunk" .. i,
                Size = Vector3.new(1.6, trunkHeight, 1.6),
                CFrame = CFrame.new(trunkBaseX, floorTopY + trunkHeight / 2, trunkBaseZ),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(70, 50, 35),
                Parent = treesFolder,
            })
            local _ = trunk

            -- Canopy — three overlapping spheres for a leafy clump.
            for cs = 0, 2 do
                local off = Vector3.new(
                    rand(-2, 2),
                    trunkHeight + 1 + cs * 1.4,
                    rand(-2, 2))
                makePart({
                    Name = "PickleTreeCanopy" .. i .. "_" .. cs,
                    Shape = Enum.PartType.Ball,
                    Size = Vector3.new(7 + rand(0, 2), 6, 7 + rand(0, 2)),
                    CFrame = CFrame.new(trunkBaseX + off.X, floorTopY + off.Y, trunkBaseZ + off.Z),
                    Material = Enum.Material.LeafyGrass,
                    Color = Color3.fromRGB(50, 95, 45),
                    Parent = treesFolder,
                })
            end

            -- Pickle fruit — small glowing green Balls with PointLights.
            for f = 1, fruitsPerTree do
                local fruitOff = Vector3.new(
                    rand(-3, 3),
                    trunkHeight + rand(-1, 3),
                    rand(-3, 3))
                local fruit = makePart({
                    Name = "PickleFruit" .. i .. "_" .. f,
                    Shape = Enum.PartType.Ball,
                    Size = Vector3.new(1.3, 1.6, 1.3),
                    CFrame = CFrame.new(
                        trunkBaseX + fruitOff.X,
                        floorTopY + fruitOff.Y,
                        trunkBaseZ + fruitOff.Z),
                    Material = Enum.Material.Neon,
                    Color = Color3.fromRGB(160, 240, 100),
                    Transparency = 0.05,
                    Parent = treesFolder,
                })
                local light = Instance.new("PointLight")
                light.Color = Color3.fromRGB(160, 240, 130)
                light.Brightness = 1.6
                light.Range = fruitLightRange
                light.Parent = fruit
            end
        end
    end

    ------------------------------------------------------------
    -- ENEMY PATH waypoints (tagged Parts the wave system reads).
    ------------------------------------------------------------
    local map4PathFolder = Instance.new("Folder")
    map4PathFolder.Name = "EnemyPath"
    map4PathFolder.Parent = map4Room
    map4PathFolder:SetAttribute("MapId", 4)
    for i, cell in ipairs(map4PathCells) do
        local worldPos = cellToWorld(cell[1], cell[2]) + Vector3.new(0, 1, 0)
        local part = makePart({
            Name = "Waypoint" .. i,
            Size = Vector3.new(2, 0.2, 2),
            CFrame = CFrame.new(worldPos),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(180, 240, 140),  -- swamp green path glow
            Transparency = 0.55,
            CanCollide = false,
            Parent = map4PathFolder,
        })
        part:SetAttribute("MapId", 4)
        CollectionService:AddTag(part, Tags.EnemyWaypoint)
    end

    ------------------------------------------------------------
    -- Visual path tiles — dirt-colored slate squares above floor
    -- so the path reads even in low light.
    ------------------------------------------------------------
    for c = MAP4_COL_OFFSET, MAP4_TOTAL_COLS - 1 do
        for r = 0, MAP4_ROWS - 1 do
            local s = gridState[c][r]
            if s == "path" or s == "heart" then
                local worldPos = cellToWorld(c, r)
                worldPos = Vector3.new(worldPos.X, floorTopY + 0.15, worldPos.Z)
                makePart({
                    Name = (s == "path") and "PathCell" or "HeartCell",
                    Size = Vector3.new(CELL_SIZE, 0.3, CELL_SIZE),
                    CFrame = CFrame.new(worldPos),
                    Material = Enum.Material.Slate,
                    Color = (s == "path") and Color3.fromRGB(95, 70, 50)
                                           or Color3.fromRGB(140, 110, 70),
                    CanCollide = false,
                    Parent = map4Room,
                })
            end
        end
    end

    ------------------------------------------------------------
    -- HEART — Tree-of-Life heart at the path end.
    ------------------------------------------------------------
    local m4HeartWorldPos = cellToWorld(m4HeartCell[1], m4HeartCell[2])
                          + Vector3.new(0, 4, 0)
    local map4Heart = makePart({
        Name = "TreeHeartMap4",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(14, 14, 14),
        CFrame = CFrame.new(m4HeartWorldPos),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(255, 220, 140),
        Transparency = 0.2,
        CanCollide = false,
        Parent = map4Room,
    })
    CollectionService:AddTag(map4Heart, Tags.EnemyEndPoint)
    map4Heart:SetAttribute("MapId", 4)
    local heartHp = Config.Map4.HeartMaxHp
    map4Heart:SetAttribute("MaxHealth", heartHp)
    map4Heart:SetAttribute("Health", heartHp)
    local heartLight = Instance.new("PointLight")
    heartLight.Color = Color3.fromRGB(255, 220, 140)
    heartLight.Brightness = 3
    heartLight.Range = 60
    heartLight.Parent = map4Heart

    -- HP billboard
    local m4HpAnchor = makePart({
        Name = "HeartHPAnchorMap4",
        Size = Vector3.new(1, 1, 1),
        CFrame = CFrame.new(m4HeartWorldPos + Vector3.new(0, 11, 0)),
        Transparency = 1,
        CanCollide = false,
        Parent = map4Room,
    })
    local m4HpBillboard = Instance.new("BillboardGui")
    m4HpBillboard.Size = UDim2.fromOffset(140, 28)
    m4HpBillboard.AlwaysOnTop = true
    m4HpBillboard.LightInfluence = 0
    m4HpBillboard.MaxDistance = 280
    m4HpBillboard.Parent = m4HpAnchor
    local m4HpBg = Instance.new("Frame")
    m4HpBg.Size = UDim2.fromScale(1, 1)
    m4HpBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    m4HpBg.BackgroundTransparency = 0.2
    m4HpBg.BorderSizePixel = 0
    m4HpBg.Parent = m4HpBillboard
    local m4HpFill = Instance.new("Frame")
    m4HpFill.Size = UDim2.new(1, -2, 1, -2)
    m4HpFill.Position = UDim2.fromOffset(1, 1)
    m4HpFill.BackgroundColor3 = Color3.fromRGB(255, 220, 140)
    m4HpFill.BorderSizePixel = 0
    m4HpFill.Parent = m4HpBg
    local m4HpText = Instance.new("TextLabel")
    m4HpText.Size = UDim2.fromScale(1, 1)
    m4HpText.BackgroundTransparency = 1
    m4HpText.Text = string.format("%d / %d", heartHp, heartHp)
    m4HpText.Font = Enum.Font.FredokaOne
    m4HpText.TextSize = 16
    m4HpText.TextColor3 = Color3.fromRGB(40, 30, 10)
    m4HpText.Parent = m4HpBillboard
    map4Heart:SetAttribute("HPFillSize", m4HpFill.Size)  -- snapshot for damage updater
    map4Heart:GetAttributeChangedSignal("Health"):Connect(function()
        local hp = map4Heart:GetAttribute("Health") or 0
        local max = map4Heart:GetAttribute("MaxHealth") or heartHp
        local frac = math.clamp(hp / max, 0, 1)
        m4HpFill.Size = UDim2.new(frac, -2, 1, -2)
        m4HpText.Text = string.format("%d / %d", math.max(0, math.floor(hp)), max)
    end)

    ------------------------------------------------------------
    -- ENEMY SPAWN at the start of the path.
    ------------------------------------------------------------
    local m4SpawnPos = cellToWorld(map4PathCells[1][1], map4PathCells[1][2])
                     + Vector3.new(0, 1, 0)
    local map4Spawn = makePart({
        Name = "EnemySpawnMap4",
        Size = Vector3.new(3, 0.3, 3),
        CFrame = CFrame.new(m4SpawnPos),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(120, 200, 100),
        Transparency = 0.5,
        CanCollide = false,
        Parent = map4Room,
    })
    map4Spawn:SetAttribute("MapId", 4)
    CollectionService:AddTag(map4Spawn, Tags.EnemySpawn)

    -- Suppress unused-import warning for TweenService — reserved for
    -- B2d follow-up (drifting steam clouds will likely use a global
    -- tween group instead of per-frame Heartbeat at scale).
    local _ = TweenService

    ------------------------------------------------------------
    -- Publish ctx fields so the Infinite system + tower placement
    -- can find the heart, spawn position, and player CFrame.
    ------------------------------------------------------------
    ctx.map4Room              = map4Room
    ctx.map4Heart             = map4Heart
    ctx.MAP4_PLAYER_SPAWN_CF  = MAP4_PLAYER_SPAWN_CF

    print(("[Map4] Pickle Swamp built. Cols %d-%d, %d path waypoints, "
        .. "%d steam clouds, %d pickle trees"):format(
        MAP4_COL_OFFSET, MAP4_TOTAL_COLS - 1, #map4PathCells,
        Config.Map4.SteamClouds.Count, Config.Map4.PickleTrees.Count))
end

return Map4
