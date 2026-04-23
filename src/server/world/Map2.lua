--[[
    Map2.lua — Map 2 construction: floor/walls/heart, enemy path,
    art deco stained-glass windows, double-helix staircase (sculptural
    centerpiece), bushes and fireflies (ambient decor), and the
    map-1 → map-2 portal on the east wall of the TD room.

    This is the biggest extracted module by line count. It replaces
    the big `do`-block that used to wrap ~35 locals (m2c, STAIR_CENTER,
    map1ToMap2Portal, etc.) to keep them off the main-chunk register
    budget. The setup function naturally provides the same scoping.

    setup(ctx) reads ctx fields populated by earlier modules:
      Constants:  MAP2_CENTER, MAP2_WIDTH, MAP2_DEPTH, MAP2_HEIGHT,
                  TD_WALL_THICK, CELL_SIZE, MAP2_COL_OFFSET
      Helpers:    makePart, rand
      From Grid:  cellToWorld, gridState, pathHalf
      From TdRoom: tdRoom, rc, halfW, halfD (portal sits on TD's east wall)
      From hub:   fireLeafMessage, Map2Stage (empty namespace to populate)

    And publishes downstream:
      ctx.map2Room              -- Model
      ctx.map2Heart             -- Part (EnemyEndPoint tag, MapId=2)
      ctx.MAP2_PLAYER_SPAWN_CF  -- CFrame used by Portal + DevTeleport
      ctx.MAP2_AMMO_SW_POS      -- Vector3, for later Ammo.setup
      ctx.MAP2_AMMO_SE_POS      -- Vector3

    The Map2Stage namespace (bushLobes, fireflies, stairParts,
    baseStairTotalHeight, stairStepCount, stageUnlockFractions,
    stairCenter, axisPart, topLamp) is populated in-place — the
    hub and Map2StageVisuals share the SAME table via ctx.Map2Stage.
]]

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Tags    = require(Shared:WaitForChild("Tags"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config  = require(Shared:WaitForChild("Config"))

local Map2 = {}

function Map2.setup(ctx)
    local MAP2_CENTER     = ctx.MAP2_CENTER
    local MAP2_WIDTH      = ctx.MAP2_WIDTH
    local MAP2_DEPTH      = ctx.MAP2_DEPTH
    local MAP2_HEIGHT     = ctx.MAP2_HEIGHT
    local TD_WALL_THICK   = ctx.TD_WALL_THICK
    local CELL_SIZE       = ctx.CELL_SIZE
    local MAP2_COL_OFFSET = ctx.MAP2_COL_OFFSET
    local MAP2_TOTAL_COLS = ctx.MAP2_TOTAL_COLS
    local MAP2_ROWS       = ctx.MAP2_ROWS
    local MAP2_COLS       = ctx.MAP2_COLS
    local HEART_EXCLUSION_CELLS = ctx.HEART_EXCLUSION_CELLS

    local makePart = ctx.makePart
    local rand     = ctx.rand

    local cellToWorld = ctx.cellToWorld
    local gridState   = ctx.gridState
    local pathHalf    = ctx.pathHalf

    local tdRoom = ctx.tdRoom
    local rc     = ctx.rc
    local halfW  = ctx.halfW
    local halfD  = ctx.halfD

    local fireLeafMessage = ctx.fireLeafMessage
    local Map2Stage       = ctx.Map2Stage

    -- Bindables created by the hub orchestrator BEFORE Map2.setup runs.
    -- Looked up here (not captured via ctx) because the lookup is cheap
    -- and keeps the ctx surface smaller.
    local bossDefeatedBindable = ReplicatedStorage:WaitForChild(Remotes.Names.BossDefeated)
    -- applyMap2Stage1OnEntry is late-resolved via ctx — the hub sets
    -- a stub before this setup() runs, and the MAP 2 STAGE VISUALS
    -- section (still in the hub file) overwrites ctx with the real
    -- implementation. The portal handler below fires after that
    -- overwrite, so ctx.applyMap2Stage1OnEntry() hits the real one.

    -- Module-scope locals assigned INSIDE the do-block body below,
    -- then published to ctx after the block closes.
    local MAP2_PLAYER_SPAWN_CF  -- CFrame

    -- Map 2 ammo pile world positions (declared BEFORE the body so
    -- bush-placement code inside can exclude these spots). Placed in
    -- SW and SE corners (south row 50), tucked outside the path brush.
    local MAP2_AMMO_SW_POS = Vector3.new(
        MAP2_CENTER.X - MAP2_WIDTH/2 +  5.5 * CELL_SIZE,  -- local col 5 (near west wall)
        MAP2_CENTER.Y + 1,
        MAP2_CENTER.Z - MAP2_DEPTH/2 + 50.5 * CELL_SIZE   -- row 50 (south of path brush at rows 44-48)
    )
    local MAP2_AMMO_SE_POS = Vector3.new(
        MAP2_CENTER.X - MAP2_WIDTH/2 + 71.5 * CELL_SIZE,  -- local col 71 (east of path end at col 68)
        MAP2_CENTER.Y + 1,
        MAP2_CENTER.Z - MAP2_DEPTH/2 + 50.5 * CELL_SIZE   -- row 50
    )

    -- ============================================================
    -- BEGIN extracted do-block body (verbatim from hub lines 603-1646)
    -- ============================================================
    local map2Room = Instance.new("Model")
    map2Room.Name = "TreeOfLifeMap2Room"
    map2Room.Parent = Workspace
    
    local m2c = MAP2_CENTER
    local m2HalfW = MAP2_WIDTH / 2
    local m2HalfD = MAP2_DEPTH / 2
    
    -- Floor
    makePart({
        Name = "Map2Floor",
        Size = Vector3.new(MAP2_WIDTH, 2, MAP2_DEPTH),
        CFrame = CFrame.new(m2c),
        Material = Enum.Material.WoodPlanks,
        Color = Color3.fromRGB(140, 100, 60),  -- warmer wood than map 1
        Parent = map2Room,
    })
    
    -- Walls (4 sides, mossy wood)
    local m2WallColor = Color3.fromRGB(80, 110, 60)  -- moss green
    local m2WallMaterial = Enum.Material.Wood
    makePart({
        Name = "Map2WallWest",
        Size = Vector3.new(TD_WALL_THICK, MAP2_HEIGHT, MAP2_DEPTH + TD_WALL_THICK * 2),
        CFrame = CFrame.new(m2c + Vector3.new(-m2HalfW - TD_WALL_THICK/2, MAP2_HEIGHT/2, 0)),
        Material = m2WallMaterial,
        Color = m2WallColor,
        Parent = map2Room,
    })
    makePart({
        Name = "Map2WallEast",
        Size = Vector3.new(TD_WALL_THICK, MAP2_HEIGHT, MAP2_DEPTH + TD_WALL_THICK * 2),
        CFrame = CFrame.new(m2c + Vector3.new(m2HalfW + TD_WALL_THICK/2, MAP2_HEIGHT/2, 0)),
        Material = m2WallMaterial,
        Color = m2WallColor,
        Parent = map2Room,
    })
    makePart({
        Name = "Map2WallNorth",
        Size = Vector3.new(MAP2_WIDTH, MAP2_HEIGHT, TD_WALL_THICK),
        CFrame = CFrame.new(m2c + Vector3.new(0, MAP2_HEIGHT/2, -m2HalfD - TD_WALL_THICK/2)),
        Material = m2WallMaterial,
        Color = m2WallColor,
        Parent = map2Room,
    })
    makePart({
        Name = "Map2WallSouth",
        Size = Vector3.new(MAP2_WIDTH, MAP2_HEIGHT, TD_WALL_THICK),
        CFrame = CFrame.new(m2c + Vector3.new(0, MAP2_HEIGHT/2, m2HalfD + TD_WALL_THICK/2)),
        Material = m2WallMaterial,
        Color = m2WallColor,
        Parent = map2Room,
    })
    
    -- Path: zigzag switchback pattern matching the user's floor-plan diagram.
    -- Spawn at the NW start of leg A, travel east, short south, west (back),
    -- south down the long west leg, then east across the bottom to the heart
    -- in the SE corner. Creates a snake pattern that keeps the center of the
    -- room open for the staircase and provides lots of tower placement space.
    --
    -- Coordinates in SHARED grid space (already include MAP2_COL_OFFSET).
    -- Heart is now at the SE corner (col 68, row 46).
    local map2PathCells = {
        {MAP2_COL_OFFSET +  5,  8},   -- 1. start of leg A (NW-ish)
        {MAP2_COL_OFFSET + 68,  8},   -- 2. end of leg A (NE-ish)
        {MAP2_COL_OFFSET + 68, 20},   -- 3. south (12 rows, giving leg A + B real vertical space)
        {MAP2_COL_OFFSET +  5, 20},   -- 4. end of leg B (west again, now at row 20)
        {MAP2_COL_OFFSET +  5, 46},   -- 5. end of leg C (long south down west side)
        {MAP2_COL_OFFSET + 68, 46},   -- 6. HEART — end of leg D (SE corner)
    }
    
    -- Mark path cells in shared grid using same brush as map 1
    local function markPathRectMap2(c1, r1, c2, r2)
        local cmin, cmax = math.min(c1, c2), math.max(c1, c2)
        local rmin, rmax = math.min(r1, r2), math.max(r1, r2)
        for c = cmin, cmax do
            for r = rmin, rmax do
                if c >= MAP2_COL_OFFSET and c < MAP2_TOTAL_COLS
                   and r >= 0 and r < MAP2_ROWS then
                    gridState[c][r] = "path"
                end
            end
        end
    end
    
    for i = 1, #map2PathCells - 1 do
        local a, b = map2PathCells[i], map2PathCells[i+1]
        -- Sweep a PATH_WIDTH_CELLS-wide brush along each segment
        if a[1] == b[1] then  -- vertical
            markPathRectMap2(a[1] - pathHalf, math.min(a[2], b[2]) - pathHalf,
                             a[1] + pathHalf, math.max(a[2], b[2]) + pathHalf)
        else  -- horizontal
            markPathRectMap2(math.min(a[1], b[1]) - pathHalf, a[2] - pathHalf,
                             math.max(a[1], b[1]) + pathHalf, a[2] + pathHalf)
        end
    end
    
    -- Heart exclusion zone (cells around heart get 'heart' state — towers can't sit on top)
    local m2HeartCell = map2PathCells[#map2PathCells]
    for dc = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
        for dr = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
            local cc, rr = m2HeartCell[1] + dc, m2HeartCell[2] + dr
            if cc >= MAP2_COL_OFFSET and cc < MAP2_TOTAL_COLS
               and rr >= 0 and rr < MAP2_ROWS then
                if gridState[cc][rr] == "open" then
                    gridState[cc][rr] = "heart"
                end
            end
        end
    end
    
    -- EnemyPath folder for map 2 (waypoint Parts)
    local map2PathFolder = Instance.new("Folder")
    map2PathFolder.Name = "EnemyPath"
    map2PathFolder.Parent = map2Room
    map2PathFolder:SetAttribute("MapId", 2)
    
    for i, cell in ipairs(map2PathCells) do
        local worldPos = cellToWorld(cell[1], cell[2]) + Vector3.new(0, 1, 0)
        local part = makePart({
            Name = "Waypoint" .. i,
            Size = Vector3.new(2, 0.2, 2),
            CFrame = CFrame.new(worldPos),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(120, 220, 140),  -- moss-green for map 2
            Transparency = 0.6,
            CanCollide = false,
            Parent = map2PathFolder,
        })
        part:SetAttribute("MapId", 2)
        CollectionService:AddTag(part, Tags.EnemyWaypoint)
    end
    
    -- Visual path tiles for map 2 (mossy stone instead of dirt)
    for c = MAP2_COL_OFFSET, MAP2_TOTAL_COLS - 1 do
        for r = 0, MAP2_ROWS - 1 do
            local s = gridState[c][r]
            if s == "path" or s == "heart" then
                local worldPos = cellToWorld(c, r)
                -- Move the tile to JUST above the floor (floor top = MAP2_CENTER.Y + 1)
                worldPos = Vector3.new(worldPos.X, MAP2_CENTER.Y + 1.15, worldPos.Z)
                makePart({
                    Name = (s == "path") and "PathCell" or "HeartCell",
                    Size = Vector3.new(CELL_SIZE, 0.3, CELL_SIZE),
                    CFrame = CFrame.new(worldPos),
                    Material = Enum.Material.Slate,
                    Color = (s == "path") and Color3.fromRGB(100, 130, 90)
                                           or Color3.fromRGB(70, 110, 70),
                    CanCollide = false,
                    Parent = map2Room,
                })
            end
        end
    end
    
    -- Map 2 Heart — bigger and tougher (5000 HP per design doc)
    local m2HeartWorldPos = cellToWorld(m2HeartCell[1], m2HeartCell[2]) + Vector3.new(0, 3, 0)
    local map2Heart = makePart({
        Name = "TreeHeartMap2",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(12, 12, 12),
        CFrame = CFrame.new(m2HeartWorldPos),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(120, 255, 150),
        Transparency = 0.2,
        CanCollide = false,
        Parent = map2Room,
    })
    CollectionService:AddTag(map2Heart, Tags.EnemyEndPoint)
    map2Heart:SetAttribute("MapId", 2)
    map2Heart:SetAttribute("MaxHealth", 5000)
    map2Heart:SetAttribute("Health", 5000)
    
    local m2HeartLight = Instance.new("PointLight")
    m2HeartLight.Color = Color3.fromRGB(120, 255, 150)
    m2HeartLight.Brightness = 3
    m2HeartLight.Range = 50
    m2HeartLight.Parent = map2Heart
    
    -- Map 2 EnemySpawn at the start of the path
    local map2Spawn = makePart({
        Name = "EnemySpawnMap2",
        Size = Vector3.new(4, 0.5, 4),
        CFrame = CFrame.new(cellToWorld(map2PathCells[1][1], map2PathCells[1][2])
                            + Vector3.new(0, 1.15, 0)),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(255, 100, 100),
        Transparency = 0.4,
        CanCollide = false,
        Parent = map2Room,
    })
    map2Spawn:SetAttribute("MapId", 2)
    CollectionService:AddTag(map2Spawn, Tags.EnemySpawn)
    
    ------------------------------------------------------------
    -- MAP 2 — STAINED GLASS WINDOWS (ART DECO, FLOOR-TO-MID-WALL)
    --
    -- Art deco pattern: strong vertical emphasis with 5 columns of panels,
    -- central symmetry, and horizontal dark banding at top + mid dividers.
    -- Each column has 3 panels stacked (bottom / middle / top rows). Colors
    -- are picked from a symmetric palette so left-right mirrors.
    --
    -- Window extends from near floor (Y = floor + 2) up to ~65% of the wall
    -- height, ~38 studs tall, 12 studs wide.
    --
    -- Still pcall-wrapped so any failure is logged without halting the hub.
    ------------------------------------------------------------
    local WINDOW_OK, WINDOW_ERR = pcall(function()
        -- Symmetric 5-column palette: center stands out, sides mirror.
        -- Row colors (bottom / middle / top) per column.
        local COLUMNS = {
            -- Outer columns (1 & 5): deep jewel tones, mirrored
            {Color3.fromRGB( 70, 110, 160), Color3.fromRGB(180,  90, 170), Color3.fromRGB( 60, 100, 150)},
            -- Secondary columns (2 & 4): gold/amber tones
            {Color3.fromRGB(230, 180,  60), Color3.fromRGB(220, 130,  60), Color3.fromRGB(230, 180,  60)},
            -- Center column: the hero column, red/gold/deep-red
            {Color3.fromRGB(200,  60,  60), Color3.fromRGB(230, 180,  60), Color3.fromRGB(160,  40,  40)},
        }
        -- Indexed 1..5 with mirror: column 1 = COLUMNS[1], 2 = COLUMNS[2], 3 = COLUMNS[3], 4 = COLUMNS[2], 5 = COLUMNS[1]
        local COLUMN_INDEX = {1, 2, 3, 2, 1}
    
        local WIN_WIDTH = 12         -- total window width in studs (X on N/S walls, Z on E/W walls)
        local WIN_HEIGHT = 38        -- total window height
        local WIN_BOTTOM_OFFSET = 2  -- studs above floor where window starts
        local NUM_COLS = 5
        local NUM_ROWS = 3
        local PANEL_WIDTH = WIN_WIDTH / NUM_COLS   -- 2.4 studs each
        local PANEL_HEIGHT = WIN_HEIGHT / NUM_ROWS -- ~12.67 studs each
        local PANEL_THICK = 0.4
        local GAP = 0.15             -- gap between panels for the dark "leading" look
        local DARK_LEAD = Color3.fromRGB(40, 28, 18)
    
        -- Build one stained glass window. `pos` is the CENTER of the window.
        -- `axis` = "Z" for N/S walls, "X" for E/W walls.
        local function buildWindow(pos, axis)
            local horizontalAxis, panelSize
            if axis == "Z" then
                horizontalAxis = Vector3.new(1, 0, 0)
                panelSize = Vector3.new(PANEL_WIDTH - GAP, PANEL_HEIGHT - GAP, PANEL_THICK)
            else
                horizontalAxis = Vector3.new(0, 0, 1)
                panelSize = Vector3.new(PANEL_THICK, PANEL_HEIGHT - GAP, PANEL_WIDTH - GAP)
            end
            local verticalAxis = Vector3.new(0, 1, 0)
    
            -- Stained glass panels (5 cols × 3 rows grid)
            for colIdx = 1, NUM_COLS do
                local paletteCol = COLUMNS[COLUMN_INDEX[colIdx]]
                for rowIdx = 1, NUM_ROWS do
                    -- hOffset: -2 to +2 times PANEL_WIDTH centered around pos
                    local hOffset = (colIdx - (NUM_COLS + 1) / 2) * PANEL_WIDTH
                    -- vOffset: -1 to +1 times PANEL_HEIGHT centered around pos.
                    -- Remember rowIdx 1 = bottom, 3 = top; Y axis increases upward.
                    local vOffset = (rowIdx - (NUM_ROWS + 1) / 2) * PANEL_HEIGHT
                    local panelPos = pos + horizontalAxis * hOffset + verticalAxis * vOffset
                    makePart({
                        Name = "StainedPanel",
                        Size = panelSize,
                        CFrame = CFrame.new(panelPos),
                        Material = Enum.Material.Neon,
                        Color = paletteCol[rowIdx],
                        Transparency = 0.22,
                        CanCollide = false,
                        Parent = map2Room,
                    })
                end
            end
    
            -- Horizontal dark leading bands at top, middle-upper divider, and bottom.
            -- These thin dark strips are the "art deco banding" that separates the
            -- three rows horizontally and frames the whole window.
            local bandThick = 0.5
            local bandLength = WIN_WIDTH + 0.8
            local bandSize
            if axis == "Z" then
                bandSize = Vector3.new(bandLength, bandThick, PANEL_THICK + 0.15)
            else
                bandSize = Vector3.new(PANEL_THICK + 0.15, bandThick, bandLength)
            end
            -- Positions: 5 bands — top, between top/middle, between middle/bottom, bottom
            -- Actually 4 bands: top, between row 3 & 2, between row 2 & 1, bottom
            local bandVOffsets = {
                -WIN_HEIGHT / 2,                           -- bottom
                -WIN_HEIGHT / 2 + PANEL_HEIGHT,            -- between rows 1 and 2
                -WIN_HEIGHT / 2 + PANEL_HEIGHT * 2,        -- between rows 2 and 3
                WIN_HEIGHT / 2,                            -- top
            }
            for _, vOff in ipairs(bandVOffsets) do
                makePart({
                    Name = "WindowLeading",
                    Size = bandSize,
                    CFrame = CFrame.new(pos + verticalAxis * vOff),
                    Material = Enum.Material.Wood,
                    Color = DARK_LEAD,
                    CanCollide = false,
                    Parent = map2Room,
                })
            end
    
            -- Vertical thin leading between columns (4 strips)
            local vStripThick = 0.3
            local vStripLen = WIN_HEIGHT
            local vStripSize
            if axis == "Z" then
                vStripSize = Vector3.new(vStripThick, vStripLen, PANEL_THICK + 0.15)
            else
                vStripSize = Vector3.new(PANEL_THICK + 0.15, vStripLen, vStripThick)
            end
            for stripIdx = 1, NUM_COLS - 1 do
                local hOff = (stripIdx - NUM_COLS / 2) * PANEL_WIDTH
                makePart({
                    Name = "WindowLeading",
                    Size = vStripSize,
                    CFrame = CFrame.new(pos + horizontalAxis * hOff),
                    Material = Enum.Material.Wood,
                    Color = DARK_LEAD,
                    CanCollide = false,
                    Parent = map2Room,
                })
            end
    
            -- Warm PointLight inside the wall to cast inward-glowing light.
            -- Lower Y than panel center so light appears to come from within.
            local anchor = makePart({
                Name = "WindowLightAnchor",
                Size = Vector3.new(0.2, 0.2, 0.2),
                CFrame = CFrame.new(pos),
                Transparency = 1,
                CanCollide = false,
                Parent = map2Room,
            })
            local light = Instance.new("PointLight")
            light.Color = Color3.fromRGB(255, 230, 180)
            light.Brightness = 3
            light.Range = 32
            light.Parent = anchor
        end
    
        -- Window Y: center it so the window spans from (floor + 2) to (floor + 2 + WIN_HEIGHT).
        -- Center Y = floor + 2 + WIN_HEIGHT/2.
        local floorY = m2c.Y  -- map 2 floor top (floor Part is 2 thick, centered at m2c.Y)
        local winY = floorY + WIN_BOTTOM_OFFSET + WIN_HEIGHT / 2
    
        -- Windows: 3 each on east + west (long 110-stud walls spanning the map's
        -- depth), 2 each on north + south (the shorter walls where mobs travel
        -- along). 10 total.
        local westX = m2c.X - m2HalfW
        local eastX = m2c.X + m2HalfW
        local northZ = m2c.Z - m2HalfD
        local southZ = m2c.Z + m2HalfD
        -- E/W walls: 3 windows at t = 1/4, 1/2, 3/4 across the depth
        for i = 1, 3 do
            local tLerp = i / 4
            local z = m2c.Z - m2HalfD + tLerp * MAP2_DEPTH
            buildWindow(Vector3.new(westX, winY, z), "X")
            buildWindow(Vector3.new(eastX, winY, z), "X")
        end
        -- N/S walls: 2 windows at t = 1/3, 2/3 across the width
        for i = 1, 2 do
            local tLerp = i / 3
            local x = m2c.X - m2HalfW + tLerp * MAP2_WIDTH
            buildWindow(Vector3.new(x, winY, northZ), "Z")
            buildWindow(Vector3.new(x, winY, southZ), "Z")
        end
    end)
    
    if not WINDOW_OK then
        warn("[ToL] Stained glass windows failed to build: " .. tostring(WINDOW_ERR))
    end
    
    ------------------------------------------------------------
    -- MAP 2 — DOUBLE HELIX STAIRCASE (sculptural centerpiece)
    --
    -- Redesigned v5.9.58 to match the reference image: FLOATING substantial
    -- steps (no thick central trunk), a curved outer stringer forming the
    -- sweeping spiral silhouette, and bigger treads the player can plant
    -- both feet on. Two helices interweave at 180° offset.
    --
    -- Step geometry: 9 studs long (outer edge to inner edge), 4 studs deep
    -- (tread front-to-back), 0.5 studs thick. Inner edge sits at radius 3
    -- (so there's a narrow void in the middle rather than a fat trunk).
    -- Outer edge at radius 12.
    --
    -- Outer stringer: a thin Part placed between each consecutive pair of
    -- outer-edge points, forming a faceted helical band — the sculptural
    -- "ribbon" that gives the reference its iconic look.
    --
    -- Steps stay low (1.2 stud rise, 4 stud tread) so the character walks
    -- up without needing to jump.
    ------------------------------------------------------------
    -- Staircase positioned centered between the upper switchback leg (row 20)
    -- and the bottom path leg (row 46). Midpoint = row 33 ≈ map-center row
    -- 27.5 + 5.5 rows south = +11 studs in Z.
    -- This gives equal breathing room above and below the staircase, and
    -- frames the player's north-facing view from the south-center spawn.
    local STAIR_CENTER = m2c + Vector3.new(0, 0, 11)
    local STAIR_OUTER_R = Config.Map2.StairOuterRadius       -- outer edge of steps
    local STAIR_INNER_R = Config.Map2.StairInnerRadius       -- inner edge of steps (narrow central void)
    local STAIR_STEP_COUNT = Config.Map2.StairStepCount
    local STAIR_STEP_HEIGHT = Config.Map2.StairStepHeight
    local STAIR_STEP_ANGLE_DEG = Config.Map2.StairStepAngleDeg
    local STAIR_STEP_DEPTH = Config.Map2.StairStepDepth
    local STAIR_TOTAL_HEIGHT = STAIR_STEP_COUNT * STAIR_STEP_HEIGHT
    
    -- Wood tones for the two helices. Subtly different so they read as
    -- distinct spirals but harmonize as one piece of architecture.
    local HELIX_A_COLOR = Color3.fromRGB(145, 105, 65)   -- honey oak
    local HELIX_B_COLOR = Color3.fromRGB(105,  72, 42)   -- walnut
    
    -- Assigned at the end of this file so the stage-advance handler can
    -- compute unlockStage per step. STAGE_UNLOCK_FRACTIONS = what fraction of
    -- the 120-step staircase is visible at each stage. Tuned so each stage
    -- grows by a manageable amount rather than big jumps:
    --   stage 1 = 5%  (6 steps ≈ 7 studs — barely a stub above the floor)
    --   stage 2 = 25% (30 steps ≈ 36 studs — clearly rising)
    --   stage 3 = 60% (72 steps ≈ 86 studs — most of the way)
    --   stage 4 = 100% (120 steps ≈ 144 studs — full height for the boss fight,
    --                   visible during night stage-4 sentinel)
    local STAGE_UNLOCK_FRACTIONS = Config.Map2.StageUnlockFractions
    Map2Stage.baseStairTotalHeight = STAIR_TOTAL_HEIGHT
    Map2Stage.stageUnlockFractions = STAGE_UNLOCK_FRACTIONS  -- exposed for applyMap2StageVisuals
    
    -- Helper: given a step index (0-based), return its unlockStage (1-4)
    -- based on the STAGE_UNLOCK_FRACTIONS above.
    local function stepIdxToStage(i)
        local stage1Max = math.floor(STAIR_STEP_COUNT * STAGE_UNLOCK_FRACTIONS[1])
        local stage2Max = math.floor(STAIR_STEP_COUNT * STAGE_UNLOCK_FRACTIONS[2])
        local stage3Max = math.floor(STAIR_STEP_COUNT * STAGE_UNLOCK_FRACTIONS[3])
        if i < stage1Max then return 1
        elseif i < stage2Max then return 2
        elseif i < stage3Max then return 3
        else return 4 end
    end
    
    -- Build one helical flight of stairs starting at angleOffsetDeg. Also
    -- builds the outer stringer segments (the curved sweeping band) between
    -- consecutive steps. Returns nothing; just spawns Parts under map2Room.
    -- Each step + stringer is registered in Map2Stage.stairParts with its
    -- unlockStage so the stage-advance handler can reveal them over time.
    --
    -- For the emerge-from-ground animation: each part is built at its target
    -- CFrame, but the entry also stores `targetCFrame` and a `risen` flag.
    -- The stage handler moves parts BELOW the floor initially if their
    -- unlockStage > 1, then tweens them up when their stage activates.
    local function buildStaircaseHelix(angleOffsetDeg, stepColor, stringerColor)
        local outerPoints = {}
        for i = 0, STAIR_STEP_COUNT - 1 do
            local angleRad = math.rad(angleOffsetDeg + i * STAIR_STEP_ANGLE_DEG)
            local y = i * STAIR_STEP_HEIGHT + STAIR_STEP_HEIGHT / 2
            local outX = math.cos(angleRad)
            local outZ = math.sin(angleRad)
    
            local midR = (STAIR_INNER_R + STAIR_OUTER_R) / 2
            local stepCenter = STAIR_CENTER + Vector3.new(outX * midR, y, outZ * midR)
            local stepCF = CFrame.new(stepCenter, stepCenter + Vector3.new(outX, 0, outZ))
            local stepPart = makePart({
                Name = "Map2StaircaseStep",
                Size = Vector3.new(STAIR_OUTER_R - STAIR_INNER_R, 0.5, STAIR_STEP_DEPTH),
                CFrame = stepCF,
                Material = Enum.Material.Wood,
                Color = stepColor,
                Parent = map2Room,
            })
            local unlockStage = stepIdxToStage(i)
            table.insert(Map2Stage.stairParts, {
                part = stepPart,
                unlockStage = unlockStage,
                targetCFrame = stepCF,    -- final position (above ground)
                stepIndex = i,            -- for staggered animation order
                risen = false,            -- set true once it's emerged; prevents re-animation
            })
            outerPoints[i + 1] = {
                pos = STAIR_CENTER + Vector3.new(outX * STAIR_OUTER_R, y, outZ * STAIR_OUTER_R),
                stage = unlockStage,
                stepIndex = i,
            }
        end
    
        -- Outer stringer: connect each pair of adjacent outer-edge points
        for i = 1, #outerPoints - 1 do
            local a = outerPoints[i]
            local b = outerPoints[i + 1]
            local mid = (a.pos + b.pos) / 2
            local delta = b.pos - a.pos
            local len = delta.Magnitude
            if len > 0.1 then
                local cf = CFrame.new(mid, mid + delta)
                local stringerPart = makePart({
                    Name = "Map2StaircaseStringer",
                    Size = Vector3.new(len + 0.2, 2.5, 0.4),
                    CFrame = cf,
                    Material = Enum.Material.Wood,
                    Color = stringerColor,
                    Parent = map2Room,
                })
                local stage = math.max(a.stage, b.stage)
                table.insert(Map2Stage.stairParts, {
                    part = stringerPart,
                    unlockStage = stage,
                    targetCFrame = cf,
                    stepIndex = a.stepIndex,  -- match the lower step so stringers rise with them
                    risen = false,
                })
            end
        end
    end
    
    local STAR_CONSTANTS_DONE = true  -- sentinel to let us drop a block here
    Map2Stage.stairCenter      = STAIR_CENTER
    Map2Stage.stairStepCount   = STAIR_STEP_COUNT
    Map2Stage.stairStepHeight  = STAIR_STEP_HEIGHT
    Map2Stage.stairStepAngle   = STAIR_STEP_ANGLE_DEG
    Map2Stage.stairOuterR      = STAIR_OUTER_R
    
    -- Two helices, 180° apart, different wood tones
    buildStaircaseHelix(0,   HELIX_A_COLOR, HELIX_A_COLOR:Lerp(Color3.new(0,0,0), 0.25))
    buildStaircaseHelix(180, HELIX_B_COLOR, HELIX_B_COLOR:Lerp(Color3.new(0,0,0), 0.25))
    
    -- Subtle accent: a thin vertical visual axis running up the center, just
    -- so there's SOMETHING connecting the two spirals. Much thinner than the
    -- original trunk — reads as a line, not a pillar. Tracked for staging so
    -- it grows with the staircase.
    do
        local axisH = STAIR_TOTAL_HEIGHT + 8
        local axisPart = makePart({
            Name = "Map2StaircaseAxis",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(axisH, 1.0, 1.0),
            CFrame = CFrame.new(STAIR_CENTER + Vector3.new(0, axisH / 2, 0))
                     * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(55, 38, 22),  -- very dark, reads as shadow line
            Parent = map2Room,
        })
        Map2Stage.axisPart = axisPart  -- reposition/resize on stage advance
    end
    
    -- Glowing amber lamp at the TOP of the staircase, visible from below.
    -- Tracked so it can be MOVED up as the staircase grows across stages.
    do
        local topLamp = makePart({
            Name = "Map2StaircaseTopLamp",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(3.5, 3.5, 3.5),
            -- Initial position at STAIR_CENTER + ~18 studs up (approximate
            -- stage-1 axis top). applyMap2StageVisuals will reposition exactly
            -- at boot + on each stage advance.
            CFrame = CFrame.new(STAIR_CENTER + Vector3.new(0, 18, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 200, 120),
            Transparency = 0.2,
            CanCollide = false,
            Parent = map2Room,
        })
        local topLampLight = Instance.new("PointLight")
        topLampLight.Color = Color3.fromRGB(255, 200, 120)
        topLampLight.Brightness = 4
        topLampLight.Range = 45
        topLampLight.Parent = topLamp
        Map2Stage.topLamp = topLamp
    end
    
    -- Block tower placement in a circle around the staircase. Outer radius 12
    -- = 6 cells; add margin for stringers that reach just past it: 7 cells.
    do
        local stairCenterCol = math.floor((STAIR_CENTER.X - m2c.X + m2HalfW) / CELL_SIZE + MAP2_COL_OFFSET)
        local stairCenterRow = math.floor((STAIR_CENTER.Z - m2c.Z + m2HalfD) / CELL_SIZE)
        local STAIR_CELL_RADIUS = 7
        for dc = -STAIR_CELL_RADIUS, STAIR_CELL_RADIUS do
            for dr = -STAIR_CELL_RADIUS, STAIR_CELL_RADIUS do
                if dc * dc + dr * dr <= STAIR_CELL_RADIUS * STAIR_CELL_RADIUS then
                    local cc = stairCenterCol + dc
                    local rr = stairCenterRow + dr
                    if cc >= MAP2_COL_OFFSET and cc < MAP2_TOTAL_COLS
                       and rr >= 0 and rr < MAP2_ROWS then
                        if gridState[cc][rr] == "open" then
                            gridState[cc][rr] = "decor"
                        end
                    end
                end
            end
        end
    end
    
    ------------------------------------------------------------
    -- MAP 2 — BUSHES AND FIREFLIES
    --
    -- Two bush populations:
    --   OUTER bushes: hug the walls. At stage 1 they're a thin line against
    --     the wall, leaving the area in front of windows clear. At stages 2
    --     and 3, additional lobes spawn FURTHER from the wall — the bushes
    --     "grow outward" into the room, potentially covering in-front-of-
    --     window positions. Fireflies cluster on outer bushes.
    --   INNER bushes: small decorative shrubs lining the path. Grow in size
    --     with stages too (1-2 lobes at stage 1, 3 at stage 2, 4-5 at stage 3).
    --
    -- Candidate zones:
    --   - within 2 cells of ANY wall → OUTER zone (wall-hugging)
    --   - within 4 cells of ANY path cell → INNER zone (path-lining)
    --   - else → skip
    --
    -- Fireflies cluster on outer bushes. Plus a swarm around the staircase.
    ------------------------------------------------------------
    local OUTER_BUSH_ENTRIES = {}  -- {pos=Vector3, inwardNormal=Vector3}
    local INNER_BUSH_LOCATIONS = {} -- world-space Vector3 only
    local FIREFLIES = {}
    
    -- Window world-space center positions. Used to block stage-1 outer bushes
    -- from spawning directly in front of a window (so at stage 1 the windows
    -- are unobstructed; at stage 2+3 bushes can creep in front of them).
    local MAP2_WINDOW_POSITIONS = {}
    do
        local winY = m2c.Y + MAP2_HEIGHT * 0.25  -- approximate vertical center (not used, just for compat)
        local westX = m2c.X - m2HalfW
        local eastX = m2c.X + m2HalfW
        local northZ = m2c.Z - m2HalfD
        local southZ = m2c.Z + m2HalfD
        -- E/W walls: 3 windows at 1/4, 2/4, 3/4 along Z
        for i = 1, 3 do
            local tLerp = i / 4
            local z = m2c.Z - m2HalfD + tLerp * MAP2_DEPTH
            table.insert(MAP2_WINDOW_POSITIONS, Vector3.new(westX, m2c.Y, z))
            table.insert(MAP2_WINDOW_POSITIONS, Vector3.new(eastX, m2c.Y, z))
        end
        -- N/S walls: 2 windows at 1/3, 2/3 along X
        for i = 1, 2 do
            local tLerp = i / 3
            local x = m2c.X - m2HalfW + tLerp * MAP2_WIDTH
            table.insert(MAP2_WINDOW_POSITIONS, Vector3.new(x, m2c.Y, northZ))
            table.insert(MAP2_WINDOW_POSITIONS, Vector3.new(x, m2c.Y, southZ))
        end
    end
    
    -- Classify a cell + return the inward wall normal if it's in the outer zone.
    -- Returns: "outer", inwardNormal (Vector3) | "inner", nil | "none", nil
    local function classifyMap2Zone(localCol, row)
        -- Outer = within 2 cells of any wall
        local dW = localCol                      -- distance to west wall
        local dE = (MAP2_COLS - 1) - localCol    -- distance to east wall
        local dN = row                           -- distance to north wall
        local dS = (MAP2_ROWS - 1) - row         -- distance to south wall
        local minD = math.min(dW, dE, dN, dS)
        if minD <= 3 then   -- 3-cell strip for thicker wall-of-bushes look
            -- Pick the closest wall's inward normal
            local normal
            if minD == dW then normal = Vector3.new( 1, 0,  0)
            elseif minD == dE then normal = Vector3.new(-1, 0,  0)
            elseif minD == dN then normal = Vector3.new( 0, 0,  1)
            else                   normal = Vector3.new( 0, 0, -1) end
            return "outer", normal
        end
    
        -- Inner = within 4 cells of any path cell
        local sharedCol = localCol + MAP2_COL_OFFSET
        for dc = -4, 4 do
            for dr = -4, 4 do
                local nc, nr = sharedCol + dc, row + dr
                if nc >= MAP2_COL_OFFSET and nc < MAP2_TOTAL_COLS
                   and nr >= 0 and nr < MAP2_ROWS
                   and gridState[nc][nr] == "path" then
                    return "inner", nil
                end
            end
        end
        return "none", nil
    end
    
    -- Portal landing: south-center of the room matching MAP2_PLAYER_SPAWN_POS
    -- (player pops out of the map-1 portal at the same spot as dev teleport).
    local MAP2_PORTAL_LANDING = Vector3.new(
        m2c.X,
        m2c.Y,
        m2c.Z - m2HalfD + 51.5 * CELL_SIZE
    )
    local MAP2_PORTAL_LANDING_RADIUS = 10
    
    local function bushCellFree(col, row, worldPos)
        if col < MAP2_COL_OFFSET or col >= MAP2_TOTAL_COLS then return false end
        if row < 0 or row >= MAP2_ROWS then return false end
        if gridState[col][row] ~= "open" then return false end
        if worldPos and (worldPos - MAP2_PORTAL_LANDING).Magnitude < MAP2_PORTAL_LANDING_RADIUS then
            return false
        end
        return true
    end
    
    -- Scatter candidate spots. Outer bushes form a DENSE WALL — near-
    -- guaranteed placement (95%) on a tight grid (step 4) so the bushes
    -- visually merge into a solid green border around the room, with gaps
    -- only where windows are (handled by the stage-1 window exclusion).
    -- Inner bushes are sparse path accents.
    do
        local scanStep = 4    -- tight step = near-continuous wall coverage
        local bushClearance = 8
        local bushClearanceSq = bushClearance * bushClearance
    
        for x = m2c.X - m2HalfW + 2, m2c.X + m2HalfW - 2, scanStep do
            for z = m2c.Z - m2HalfD + 2, m2c.Z + m2HalfD - 2, scanStep do
                local jx = x + (math.random() - 0.5) * 1.5
                local jz = z + (math.random() - 0.5) * 1.5
                local sharedCol = math.floor((jx - m2c.X + m2HalfW) / CELL_SIZE + MAP2_COL_OFFSET)
                local row = math.floor((jz - m2c.Z + m2HalfD) / CELL_SIZE)
                local localCol = sharedCol - MAP2_COL_OFFSET
                local worldPos = Vector3.new(jx, m2c.Y + 0.5, jz)
    
                if bushCellFree(sharedCol, row, worldPos) then
                    local dxSW = jx - MAP2_AMMO_SW_POS.X
                    local dzSW = jz - MAP2_AMMO_SW_POS.Z
                    local dxSE = jx - MAP2_AMMO_SE_POS.X
                    local dzSE = jz - MAP2_AMMO_SE_POS.Z
                    local tooCloseToAmmo =
                        (dxSW * dxSW + dzSW * dzSW) < bushClearanceSq
                        or (dxSE * dxSE + dzSE * dzSE) < bushClearanceSq
    
                    if not tooCloseToAmmo then
                        local zone, normal = classifyMap2Zone(localCol, row)
                        if zone == "outer" and math.random() < 0.95 then
                            table.insert(OUTER_BUSH_ENTRIES, {pos = worldPos, inwardNormal = normal})
                        elseif zone == "inner" and math.random() < 0.40 then
                            table.insert(INNER_BUSH_LOCATIONS, worldPos)
                        end
                    end
                end
            end
        end
    end
    
    -- Helper: is worldPos within `blockRadius` studs of a window's center?
    -- Used to suppress stage-1 outer bush lobes in front of windows.
    local WINDOW_BLOCK_RADIUS = 6  -- studs — stage-1 lobes within this of a window are skipped
    local WINDOW_BLOCK_RADIUS_SQ = WINDOW_BLOCK_RADIUS * WINDOW_BLOCK_RADIUS
    local function nearAnyWindow(worldPos)
        for _, wp in ipairs(MAP2_WINDOW_POSITIONS) do
            local dx = worldPos.X - wp.X
            local dz = worldPos.Z - wp.Z
            if dx * dx + dz * dz < WINDOW_BLOCK_RADIUS_SQ then
                return true
            end
        end
        return false
    end
    
    -- Build an OUTER bush at (anchorPos, inwardNormal). Lobes stage-unlock
    -- AND offset along inwardNormal by stage — so stage 1 hugs the wall,
    -- stage 2 pushes out ~3 studs, stage 3 pushes out ~6 studs. This creates
    -- the "growing out of the wall" visual.
    --
    -- Stage-1 lobes near a window are SKIPPED (not spawned) so windows stay
    -- unobstructed initially. Stage-2 and stage-3 lobes are allowed near
    -- windows — bushes can then spread in front of them as they grow.
    local function buildOuterBush(anchorPos, inwardNormal)
        local lobes = 7 + math.random(0, 4)
        for i = 1, lobes do
            local unlockStage
            if i <= 3 then unlockStage = 1
            elseif i <= 7 then unlockStage = 2
            else unlockStage = 3 end
    
            -- Stage-based radial offset from the wall
            local stageOutward = 0
            if unlockStage == 2 then stageOutward = 3.0 + math.random() * 1.5
            elseif unlockStage == 3 then stageOutward = 5.5 + math.random() * 2.5 end
    
            -- Lateral variance along the wall (so lobes fan out, not stacked)
            local lateralOffsetX = (math.random() - 0.5) * 3.5
            local lateralOffsetZ = (math.random() - 0.5) * 3.5
            -- Zero out the component along inwardNormal (so lateral is purely along wall)
            if math.abs(inwardNormal.X) > 0.5 then lateralOffsetX = 0 end
            if math.abs(inwardNormal.Z) > 0.5 then lateralOffsetZ = 0 end
    
            local lobePos = anchorPos
                + inwardNormal * stageOutward
                + Vector3.new(lateralOffsetX, math.random() * 2.5, lateralOffsetZ)
    
            -- Skip stage-1 lobes that would sit in front of a window
            if unlockStage == 1 and nearAnyWindow(lobePos) then
                -- Skip this lobe entirely — don't create a Part, don't register
            else
                local lobeSize = 3.5 + math.random() * 3.0
                local greenShift = math.random(-15, 15)
                local lobeColor = Color3.fromRGB(
                    math.clamp(70 + greenShift, 50, 100),
                    math.clamp(130 + greenShift, 100, 160),
                    math.clamp(60 + greenShift, 40, 90)
                )
                local lobePart = makePart({
                    Name = "Map2BushOuter",
                    Shape = Enum.PartType.Ball,
                    Size = Vector3.new(lobeSize, lobeSize, lobeSize),
                    CFrame = CFrame.new(lobePos),
                    Material = Enum.Material.Grass,
                    Color = lobeColor,
                    CanCollide = false,
                    Parent = map2Room,
                })
                table.insert(Map2Stage.bushLobes, {
                    part = lobePart,
                    baseSize = lobeSize,
                    unlockStage = unlockStage,
                })
            end
        end
    end
    
    -- Build an INNER bush at worldPos. Small path-lining shrub. Lobes grow
    -- with stages:  lobe 1 = stage 1, lobes 2-3 = stage 2, lobe 4-5 = stage 3.
    local function buildInnerBush(worldPos)
        local lobes = 4 + math.random(0, 1)  -- 4 or 5 lobes total
        for i = 1, lobes do
            local unlockStage
            if i <= 1 then unlockStage = 1
            elseif i <= 3 then unlockStage = 2
            else unlockStage = 3 end
    
            local lobeSize = 1.2 + math.random() * 1.3  -- 1.2 to 2.5 studs
            local offset = Vector3.new(
                (math.random() - 0.5) * 2.5,
                math.random() * 1.0,
                (math.random() - 0.5) * 2.5
            )
            local greenShift = math.random(-10, 10)
            local lobeColor = Color3.fromRGB(
                math.clamp(80 + greenShift, 60, 105),
                math.clamp(140 + greenShift, 115, 165),
                math.clamp(70 + greenShift, 55, 95)
            )
            local lobePart = makePart({
                Name = "Map2BushInner",
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(lobeSize, lobeSize, lobeSize),
                CFrame = CFrame.new(worldPos + offset),
                Material = Enum.Material.Grass,
                Color = lobeColor,
                CanCollide = false,
                Parent = map2Room,
            })
            table.insert(Map2Stage.bushLobes, {
                part = lobePart,
                baseSize = lobeSize,
                unlockStage = unlockStage,
            })
        end
    end
    
    for _, entry in ipairs(OUTER_BUSH_ENTRIES) do
        buildOuterBush(entry.pos, entry.inwardNormal)
    end
    for _, pos in ipairs(INNER_BUSH_LOCATIONS) do
        buildInnerBush(pos)
    end
    
    -- Build a single firefly at anchorPos. Small glowing neon sphere with
    -- a subtle PointLight. Registered in both FIREFLIES (for the Heartbeat
    -- animation loop) and Map2Stage.fireflies (for stage scaling).
    local function buildFirefly(anchorPos, color)
        color = color or Color3.fromRGB(255, 230, 140)
        local baseSize = 0.25  -- default small (scales up per stage)
        local part = makePart({
            Name = "Map2Firefly",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(baseSize, baseSize, baseSize),
            CFrame = CFrame.new(anchorPos),
            Material = Enum.Material.Neon,
            Color = color,
            CanCollide = false,
            Parent = map2Room,
        })
        local light = Instance.new("PointLight")
        light.Color = color
        light.Brightness = 1.4
        light.Range = 6
        light.Parent = part
        local entry = {
            part = part,
            light = light,
            anchorPos = anchorPos,
            phase = math.random() * math.pi * 2,
            bobRadius = 0.8 + math.random() * 0.6,   -- 0.8 to 1.4 studs
            baseBrightness = 1.4,
            baseSize = baseSize,
            baseLightRange = 6,
        }
        table.insert(FIREFLIES, entry)
        table.insert(Map2Stage.fireflies, entry)
    end
    
    -- Fireflies cluster on OUTER bushes. Inner bushes don't get firefly swarms
    -- — they're smaller decorative accents, not habitats. 3-5 fireflies per
    -- outer bush, clustered on the anchor (wall-side) position.
    for _, entry in ipairs(OUTER_BUSH_ENTRIES) do
        local count = 3 + math.random(0, 2)
        for i = 1, count do
            local angle = math.random() * math.pi * 2
            local r = 0.5 + math.random() * 2.0
            local yOffset = 0.5 + math.random() * 2.5
            local pos = entry.pos + Vector3.new(math.cos(angle) * r, yOffset, math.sin(angle) * r)
            buildFirefly(pos)
        end
    end
    
    -- Swarm around the staircase: distributed at various heights, various radii
    for i = 1, 40 do
        local angle = math.random() * math.pi * 2
        local r = STAIR_OUTER_R + 1 + math.random() * 4
        local y = m2c.Y + 2 + math.random() * (STAIR_TOTAL_HEIGHT - 2)
        local pos = STAIR_CENTER + Vector3.new(math.cos(angle) * r, y - m2c.Y, math.sin(angle) * r)
        buildFirefly(pos)
    end
    
    -- Heartbeat loop: bob each firefly around its anchor + flicker brightness.
    RunService.Heartbeat:Connect(function()
        local t = os.clock()
        for _, f in ipairs(FIREFLIES) do
            if f.part.Parent then
                local r = f.bobRadius
                local dx = math.sin(t * 0.8 + f.phase) * r
                local dy = math.cos(t * 0.6 + f.phase * 1.3) * r * 0.7
                local dz = math.sin(t * 1.1 + f.phase * 0.7) * r
                f.part.CFrame = CFrame.new(f.anchorPos + Vector3.new(dx, dy, dz))
                f.light.Brightness = f.baseBrightness * (0.8 + 0.2 * math.sin(t * 4 + f.phase))
            end
        end
    end)
    
    print(("[ToL] Map 2 ambiance: %d outer bushes, %d inner bushes, %d fireflies"):format(
        #OUTER_BUSH_ENTRIES, #INNER_BUSH_LOCATIONS, #FIREFLIES))
    
    -- Player spawn on map 2: south-center of the room at local (37, 51),
    -- facing NORTH toward the staircase at map center. This is the "dark blue
    -- marker" position from the diagram. Player lands 3 rows south of the
    -- bottom path brush (rows 44-48) and 3 rows north of the south wall.
    -- Faces the staircase (at map center, local 37.5, 27.5) rather than the
    -- heart (which is now in the SE corner) because the staircase is the
    -- visual centerpiece.
    -- (MAP2_PLAYER_SPAWN_CF is forward-declared ABOVE the do-block so the
    -- DevTeleport handler below the block can read it.)
    local MAP2_PLAYER_SPAWN_POS = Vector3.new(
        m2c.X,                                           -- center column of the map
        m2c.Y + 1,
        m2c.Z - m2HalfD + 51.5 * CELL_SIZE               -- row 51
    )
    MAP2_PLAYER_SPAWN_CF = CFrame.lookAt(
        MAP2_PLAYER_SPAWN_POS,
        Vector3.new(m2c.X, m2c.Y + 1, m2c.Z)             -- face north toward map center (staircase)
    )
    
    ------------------------------------------------------------
    -- MAP 1 → MAP 2 PORTAL
    --
    -- A glowing Part placed on map 1's wall opposite the heart. Disabled
    -- (transparent + non-interactive) until the map 1 final boss dies. When
    -- the boss falls, the portal activates: glowing visual + enabled
    -- ProximityPrompt. Walking up and pressing E teleports the player to
    -- map 2's spawn, fires the SwitchMap bindable so the wave system flips
    -- to map 2's heart/path/spawn, and triggers the map 2 falling-leaf
    -- message ("the heart tells you 'keep climbing'").
    --
    -- Position heuristic: heart is at the LEFT side of map 1's grid (col 4),
    -- so "opposite wall" = the east wall (high X). We place the portal there
    -- centered vertically.
    ------------------------------------------------------------
    local map1ToMap2Portal = makePart({
        Name = "Map1ToMap2Portal",
        Size = Vector3.new(1, 8, 8),
        CFrame = CFrame.new(rc + Vector3.new(halfW - 2, 4, 0)),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(120, 220, 140),
        Transparency = 1,    -- starts hidden (boss not yet defeated)
        CanCollide = false,
        Parent = tdRoom,
    })
    
    local map1ToMap2Prompt = Instance.new("ProximityPrompt")
    map1ToMap2Prompt.ActionText = "Climb the tree"
    map1ToMap2Prompt.ObjectText = "Portal"
    map1ToMap2Prompt.HoldDuration = 0
    map1ToMap2Prompt.MaxActivationDistance = 12
    map1ToMap2Prompt.RequiresLineOfSight = false
    map1ToMap2Prompt.KeyboardKeyCode = Enum.KeyCode.E
    map1ToMap2Prompt.Enabled = false   -- starts disabled
    map1ToMap2Prompt.Parent = map1ToMap2Portal
    
    -- Subtle glow PointLight, also off until activation
    local map1ToMap2Light = Instance.new("PointLight")
    map1ToMap2Light.Color = Color3.fromRGB(120, 220, 140)
    map1ToMap2Light.Brightness = 0
    map1ToMap2Light.Range = 30
    map1ToMap2Light.Parent = map1ToMap2Portal

    ------------------------------------------------------------
    -- ROPE LADDER (visual flourish — drops from ceiling on boss defeat)
    --
    -- Purely cosmetic. The portal's ProximityPrompt (above) is still the
    -- interaction point. The ladder hangs from the ceiling above the
    -- portal, signalling "the path upward is open." All Parts start
    -- offset UP by DROP_OFFSET (above the ceiling, out of sight) and
    -- tween down to rest position when BossDefeated fires.
    --
    -- Geometry:
    --   - Rails: two thin vertical cylinders at +/- 1.5 Z
    --   - Rungs: N horizontal cylinders between the rails at regular
    --     Y intervals
    --   - Everything is CanCollide=false so mobs + players walk through
    ------------------------------------------------------------
    local LADDER_BOTTOM_Y = 1             -- bottom rung near the floor
    local LADDER_TOP_Y    = 52            -- top rung near the ceiling (room height = 55)
    local LADDER_HEIGHT   = LADDER_TOP_Y - LADDER_BOTTOM_Y  -- 51 units
    local LADDER_X_OFFSET = halfW - 3     -- 1 unit in front of the east wall / portal
    local LADDER_HALF_W   = 1.5           -- horizontal spacing between the two rails
    local LADDER_RAIL_R   = 0.15          -- rope rail radius
    local RUNG_COUNT      = 16
    local LADDER_COLOR    = Color3.fromRGB(150, 110, 70)  -- warm brown rope

    local ladderParts = {}  -- {{part, restCFrame}, ...} for animation

    local function addLadderPart(name, size, cf)
        local p = Instance.new("Part")
        p.Name = name
        p.Size = size
        p.CFrame = cf
        p.Anchored = true
        p.CanCollide = false
        p.CastShadow = false
        p.Material = Enum.Material.Fabric
        p.Color = LADDER_COLOR
        p.Transparency = 1  -- hidden until drop
        p.Parent = tdRoom
        table.insert(ladderParts, {part = p, restCFrame = cf})
        return p
    end

    -- Two vertical rails (the two "ropes" of the ladder). Rendered as
    -- thin rectangular parts rather than cylinders so they sway like
    -- rope and hold the rungs at a consistent Z spacing.
    local railCenterY = (LADDER_BOTTOM_Y + LADDER_TOP_Y) / 2
    addLadderPart("LadderRail_L",
        Vector3.new(LADDER_RAIL_R * 2, LADDER_HEIGHT, LADDER_RAIL_R * 2),
        CFrame.new(rc + Vector3.new(LADDER_X_OFFSET, railCenterY, -LADDER_HALF_W)))
    addLadderPart("LadderRail_R",
        Vector3.new(LADDER_RAIL_R * 2, LADDER_HEIGHT, LADDER_RAIL_R * 2),
        CFrame.new(rc + Vector3.new(LADDER_X_OFFSET, railCenterY, LADDER_HALF_W)))

    -- Evenly-spaced horizontal rungs spanning the two rails.
    local RUNG_RADIUS = 0.2
    local RUNG_LENGTH = LADDER_HALF_W * 2 + RUNG_RADIUS * 2  -- bridge the rails
    for i = 1, RUNG_COUNT do
        local t = (i - 1) / (RUNG_COUNT - 1)
        local y = LADDER_BOTTOM_Y + t * LADDER_HEIGHT
        addLadderPart("LadderRung_" .. i,
            Vector3.new(RUNG_RADIUS * 2, RUNG_RADIUS * 2, RUNG_LENGTH),
            CFrame.new(rc + Vector3.new(LADDER_X_OFFSET, y, 0)))
    end

    -- Drop animation state. DROP_OFFSET places the ladder fully above the
    -- ceiling (room height 55) at start; the tween brings it down to rest.
    local LADDER_DROP_OFFSET   = 60
    local LADDER_DROP_DURATION = 2.0
    local ladderDropped = false

    -- Initially place every ladder part DROP_OFFSET above its rest
    -- position so it's hidden above the ceiling. Transparency stays 1
    -- until the drop begins (then fades in during the first half of the
    -- animation so the ladder visually "appears" as it falls).
    for _, entry in ipairs(ladderParts) do
        entry.part.CFrame = entry.restCFrame + Vector3.new(0, LADDER_DROP_OFFSET, 0)
    end

    local function dropLadder()
        if ladderDropped then return end
        ladderDropped = true
        task.spawn(function()
            local t0 = os.clock()
            while true do
                local t = (os.clock() - t0) / LADDER_DROP_DURATION
                if t > 1 then t = 1 end
                -- Ease-out cubic so the ladder starts fast and settles
                local ease = 1 - (1 - t) * (1 - t) * (1 - t)
                local yOff = LADDER_DROP_OFFSET * (1 - ease)
                -- Fade in during the first 40% of the drop so the ladder
                -- is fully visible well before it settles.
                local transparency = math.max(0, 1 - ease * 2.5)
                for _, entry in ipairs(ladderParts) do
                    entry.part.CFrame = entry.restCFrame + Vector3.new(0, yOff, 0)
                    entry.part.Transparency = transparency
                end
                if t >= 1 then break end
                task.wait()
            end
            print("[ToL] Rope ladder drop complete")
        end)
    end

    -- Enable the portal when the map 1 final boss dies. We piggyback on the
    -- existing BossDefeated bindable (which the wave system fires on Pickle
    -- Lord — for now, the only "final boss" in the game). Future maps will
    -- need to either fire a different bindable or carry a mapId payload.
    local map1PortalActive = false
    bossDefeatedBindable.Event:Connect(function()
        -- Always drop the ladder on real boss defeat (dropLadder is
        -- self-guarding via the ladderDropped flag). Done BEFORE the
        -- portal-active guard so that a dev-activated portal doesn't
        -- rob the player of the ladder animation when they later
        -- defeat the boss for real.
        dropLadder()
        if map1PortalActive then return end
        map1PortalActive = true
        map1ToMap2Portal.Transparency = 0.2
        map1ToMap2Prompt.Enabled = true
        map1ToMap2Light.Brightness = 4
        print("[ToL] Map 1 → Map 2 portal activated (final boss defeated)")
    end)
    
    -- Falling-leaf message for map 2 entry
    local MAP2_LEAF = "keep climbing"
    
    -- DEV: auto-enable the portal at startup so we can test map 2 without
    -- having to defeat the map 1 final boss every time. The rope ladder
    -- intentionally does NOT drop here — the ladder is a narrative beat
    -- tied to the real boss defeat, and seeing it at startup spoils the
    -- moment. To see the ladder drop in dev, use Dev Skip to Boss and
    -- kill the Pickle Lord normally. REMOVE this block once map
    -- progression is locked in (or gate it behind a dev flag).
    task.delay(2, function()
        if not map1PortalActive then
            map1PortalActive = true
            map1ToMap2Portal.Transparency = 0.2
            map1ToMap2Prompt.Enabled = true
            map1ToMap2Light.Brightness = 4
            print("[ToL] DEV: portal auto-enabled at startup (ladder deferred to real boss defeat)")
        end
    end)
    
    -- Lazy-bind the SwitchMap bindable (created by wave system on its boot)
    local switchMapBindable = nil
    
    map1ToMap2Prompt.Triggered:Connect(function(player)
        -- FUTURE: the map-1 boss reward is a "pick 1 of 3 temp towers"
        -- per the locked run-shape design (3 maps + Pickle Showdown).
        -- Temp towers are a SEPARATE data model from starter towers —
        -- non-upgradable, placeable in multiples, run-scoped. When the
        -- TempTowerTypes module + picker UI land, fire that picker
        -- HERE (before the teleport below) with 3 random choices from
        -- the map-1 temp-tower pool. Not using ShowTowerSelect — that
        -- UI is for the once-per-run starter-tower pick only.
        if not map1PortalActive then return end
        if not switchMapBindable then
            switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        end
        if not switchMapBindable then
            print("[ToL] Portal triggered but SwitchMap bindable missing — aborting")
            return
        end
        -- Teleport player to map 2 spawn
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then hrp.CFrame = MAP2_PLAYER_SPAWN_CF end
        -- Tell the wave system to switch to map 2 (clears mobs, sets currentMapId,
        -- broadcasts new wave HUD, auto-starts wave 1 of map 2 after 4.5s)
        switchMapBindable:Fire({mapId = 2, mapName = "Climbing the Tree"})
        -- Apply stage-1 visuals for map 2 (lighting, staircase height, bush lobes).
        -- Late-resolved through ctx because Map2StageVisuals installs the real
        -- implementation AFTER Map2.setup has already registered this handler.
        ctx.applyMap2Stage1OnEntry()
        -- Falling-leaf intro for map 2 (slight delay so the teleport lands first)
        task.delay(0.4, function() fireLeafMessage(player, MAP2_LEAF, 7) end)
        print(("[ToL] %s entered map 2 via portal"):format(player.Name))
    end)

    -- ============================================================
    -- END extracted do-block body
    -- ============================================================

    -- Publish fields downstream modules + hub code need.
    ctx.map2Room             = map2Room
    ctx.map2Heart            = map2Heart
    ctx.MAP2_PLAYER_SPAWN_CF = MAP2_PLAYER_SPAWN_CF
    ctx.MAP2_AMMO_SW_POS     = MAP2_AMMO_SW_POS
    ctx.MAP2_AMMO_SE_POS     = MAP2_AMMO_SE_POS
end

return Map2
