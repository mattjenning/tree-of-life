-- TreeOfLife_Client.lua (v5.9.18)
-- LocalScript: all UI and player input. Owns:
--   • Splash screen and tower-select modal
--   • Hotbar (tower stock buttons)
--   • Placement system: ghost preview, raycast → cell snap, mobile touch
--     tracking with movement-zone exclusion, place/cancel buttons
--   • Tower target-mode HUD (stats, mode buttons, range circle, brackets)
--   • Wave HUD (map • stage • wave, countdown, defeat lock)
--   • Carrying-ammo indicator
--   • Upgrade picker modal (3 cards, reroll button)
--   • Game over modal (win/lose)
--   • Dev reset button (mobile-friendly collapsed form)
--
-- Notes on coordinate system:
--   The TD floor renders cells as Parts at their actual world positions, so
--   placement raycasts and ghost positions share the same grid space directly.
--   No SurfaceGui flipping logic anymore (legacy).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

-- Shared modules — single source of truth for Remote/Tag names.
local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local Tags        = require(Shared:WaitForChild("Tags"))
local TowerTypes  = require(Shared:WaitForChild("TowerTypes"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))
local Rarity      = require(Shared:WaitForChild("Rarity"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- Camera-snap-to-behind after a teleport. Watches the character's
-- HumanoidRootPart each Heartbeat; if its position jumps more than
-- TELEPORT_JUMP_THRESHOLD studs in a single frame, treat it as a
-- teleport (portal, dev-teleport, SwitchMap) and snap the camera
-- directly behind the character. Fixes the "I arrived at map 2
-- facing the wrong way" feeling — the default orbit camera keeps its
-- last orientation through a teleport unless we nudge it.
do
    local RunService = game:GetService("RunService")
    local TELEPORT_JUMP_THRESHOLD = 80
    local lastHrpPos = nil
    local function hookCharacter(char)
        local hrp = char:WaitForChild("HumanoidRootPart", 10)
        if not hrp then return end
        -- Reset baseline on new character so respawn doesn't misfire.
        lastHrpPos = hrp.Position
    end
    if player.Character then hookCharacter(player.Character) end
    player.CharacterAdded:Connect(hookCharacter)

    RunService.Heartbeat:Connect(function()
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        local cur = hrp.Position
        if lastHrpPos then
            local jump = (cur - lastHrpPos).Magnitude
            if jump > TELEPORT_JUMP_THRESHOLD then
                -- Snap camera to behind the character. CFrame.new(pos, lookAt)
                -- builds an orientation facing lookAt; we place the camera
                -- behind the character (-LookVector * distance) + slight
                -- height so the player fills the lower third of the view.
                local behind = cur - hrp.CFrame.LookVector * 12 + Vector3.new(0, 5, 0)
                camera.CFrame = CFrame.new(behind, cur + Vector3.new(0, 2, 0))
            end
        end
        lastHrpPos = cur
    end)
end

local gridConfig = ReplicatedStorage:WaitForChild(Remotes.Names.GridConfig)
local CELL_SIZE    = gridConfig:WaitForChild("CellSize").Value
local GRID_COLS    = gridConfig:WaitForChild("GridCols").Value
local GRID_ROWS    = gridConfig:WaitForChild("GridRows").Value
local ROOM_CENTER_X = gridConfig:WaitForChild("RoomCenterX").Value
local ROOM_CENTER_Z = gridConfig:WaitForChild("RoomCenterZ").Value
local ROOM_WIDTH   = gridConfig:WaitForChild("RoomWidth").Value
local ROOM_DEPTH   = gridConfig:WaitForChild("RoomDepth").Value
local FLOOR_Y      = gridConfig:WaitForChild("FloorY").Value

-- v3 multi-map: map 2 ("Climbing the Tree") sits 500 studs above map 1 in
-- world space but shares the same grid table — cols [MAP2_COL_OFFSET..
-- MAP2_TOTAL_COLS-1] belong to map 2. Placement math dispatches on col.
local MAP2_CENTER_X    = gridConfig:WaitForChild("Map2CenterX").Value
local MAP2_CENTER_Z    = gridConfig:WaitForChild("Map2CenterZ").Value
local MAP2_WIDTH       = gridConfig:WaitForChild("Map2Width").Value
local MAP2_DEPTH       = gridConfig:WaitForChild("Map2Depth").Value
local MAP2_COLS        = gridConfig:WaitForChild("Map2Cols").Value
local MAP2_ROWS        = gridConfig:WaitForChild("Map2Rows").Value
local MAP2_COL_OFFSET  = gridConfig:WaitForChild("Map2ColOffset").Value
local MAP2_TOTAL_COLS  = gridConfig:WaitForChild("Map2TotalCols").Value
local MAP2_FLOOR_Y     = gridConfig:WaitForChild("Map2FloorY").Value

local ROOM_MIN_X = ROOM_CENTER_X - ROOM_WIDTH/2
local ROOM_MIN_Z = ROOM_CENTER_Z - ROOM_DEPTH/2
local MAP2_MIN_X = MAP2_CENTER_X - MAP2_WIDTH/2
local MAP2_MIN_Z = MAP2_CENTER_Z - MAP2_DEPTH/2

-- Grid row-count covers both maps (map 2 is taller). Map 1's legal rows stop
-- at GRID_ROWS-1; cells past that for map-1 cols stay "open" but never get
-- placed on (server canPlaceAt enforces per-map bounds).
local MAX_GRID_ROWS = math.max(GRID_ROWS, MAP2_ROWS)

-- Per-col helpers to figure out which map a cell belongs to and what the
-- legal row bound is on that map.
local function colIsMap2(c) return c >= MAP2_COL_OFFSET end
local function colRowMax(c) return colIsMap2(c) and (MAP2_ROWS - 1) or (GRID_ROWS - 1) end
local function colMaxCol(c) return colIsMap2(c) and (MAP2_TOTAL_COLS - 1) or (GRID_COLS - 1) end
local function colMinCol(c) return colIsMap2(c) and MAP2_COL_OFFSET or 0 end

local localGrid = {}
for c = 0, MAP2_TOTAL_COLS - 1 do
    localGrid[c] = {}
    for r = 0, MAX_GRID_ROWS - 1 do
        localGrid[c][r] = "open"
    end
end

local WIND_STRENGTH = 1.0
local WIND_SPEED = 1.2

ReplicatedStorage:WaitForChild(Remotes.Names.EnterPortal).OnClientEvent:Connect(function()
    print("Portal entered!")
end)

local swayParts = {}
local function registerPart(p)
    if swayParts[p] then return end
    swayParts[p] = {
        origin = p.CFrame,
        phaseX = math.random() * math.pi * 2,
        phaseZ = math.random() * math.pi * 2,
        phaseY = math.random() * math.pi * 2,
        amp = 0.6 + math.random() * 0.8,
    }
end
for _, p in ipairs(CollectionService:GetTagged(Tags.Canopy)) do registerPart(p) end
CollectionService:GetInstanceAddedSignal(Tags.Canopy):Connect(registerPart)
CollectionService:GetInstanceRemovedSignal(Tags.Canopy):Connect(function(p) swayParts[p] = nil end)

RunService.RenderStepped:Connect(function()
    local t = os.clock() * WIND_SPEED
    for part, data in pairs(swayParts) do
        if part.Parent then
            local dx = math.sin(t + data.phaseX) * data.amp * WIND_STRENGTH
            local dz = math.cos(t * 0.8 + data.phaseZ) * data.amp * WIND_STRENGTH
            local dy = math.sin(t * 1.4 + data.phaseY) * data.amp * 0.3 * WIND_STRENGTH
            part.CFrame = data.origin + Vector3.new(dx, dy, dz)
        end
    end
end)

------------------------------------------------------------
-- Splash modal — extracted to sibling ModuleScript.
-- See TreeOfLife_Client/Splash.lua.
------------------------------------------------------------
require(script:WaitForChild("Splash")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    TweenService       = TweenService,
})

local function round(frame, radiusScale)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(radiusScale or 0.12, 0)
    c.Parent = frame
end

-- Tower icon builders (12 small UI compositions per tower type) live in a
-- sibling module; we dispatch into TowerIcons.<id> from towerDefs below so
-- adding a new icon is a one-file edit.
local TowerIcons = require(script:WaitForChild("TowerIcons"))

local towerDefs = {
    {id = "Power", name = "POWER", desc = "High single-target damage",
     color = Color3.fromRGB(200, 60, 50), accent = Color3.fromRGB(255, 90, 80),
     iconBuilder = TowerIcons.Power, enabled = true, hotkey = "1",
     hotkeyCode = Enum.KeyCode.One, footprint = {4, 4}},
    {id = "DoT", name = "DoT", desc = "Damage over time",
     color = Color3.fromRGB(50, 140, 70), accent = Color3.fromRGB(80, 200, 100),
     iconBuilder = TowerIcons.DoT, enabled = false, hotkey = "2",
     hotkeyCode = Enum.KeyCode.Two, footprint = {1, 1}},
    {id = "CC", name = "CC", desc = "Crowd control & slows",
     color = Color3.fromRGB(45, 90, 180), accent = Color3.fromRGB(80, 150, 230),
     iconBuilder = TowerIcons.CC, enabled = false, hotkey = "3",
     hotkeyCode = Enum.KeyCode.Three, footprint = {3, 3}},
    -- Temp towers (stock granted from map-boss pickers). `tempReward = true`
    -- keeps them out of the run-start starter-tower picker — the hotbar
    -- builder filters by stock > 0 so unearned slots stay invisible there.
    -- Footprints below are fallbacks; the sync loop after this table
    -- overrides them from TowerTypes / TempTowers.Templates so the client
    -- can't drift from server truth.
    {id = "FrostMelon", name = "MELON", desc = "Chills enemies in an AOE",
     color = Color3.fromRGB(100, 180, 190), accent = Color3.fromRGB(170, 220, 230),
     iconBuilder = TowerIcons.FrostMelon, enabled = true, tempReward = true, hotkey = "4",
     hotkeyCode = Enum.KeyCode.Four, footprint = {4, 4}},
    {id = "RootSprout", name = "ROOT", desc = "Periodic short-range stun",
     color = Color3.fromRGB(90, 65, 45), accent = Color3.fromRGB(150, 200, 90),
     iconBuilder = TowerIcons.RootSprout, enabled = true, tempReward = true, hotkey = "5",
     hotkeyCode = Enum.KeyCode.Five, footprint = {4, 4}},
    {id = "ThornVine", name = "THORN", desc = "Shots pierce through enemies",
     color = Color3.fromRGB(55, 95, 50), accent = Color3.fromRGB(150, 200, 120),
     iconBuilder = TowerIcons.ThornVine, enabled = true, tempReward = true, hotkey = "6",
     hotkeyCode = Enum.KeyCode.Six, footprint = {4, 4}},
    {id = "HoneyHive", name = "HIVE", desc = "Sticky patches slow + tick damage",
     color = Color3.fromRGB(180, 130, 35), accent = Color3.fromRGB(255, 210, 90),
     iconBuilder = TowerIcons.HoneyHive, enabled = true, tempReward = true, hotkey = "7",
     hotkeyCode = Enum.KeyCode.Seven, footprint = {4, 6}},
    {id = "AcornSniper", name = "SNIPER", desc = "Long range, heavy single hit",
     color = Color3.fromRGB(120, 80, 45), accent = Color3.fromRGB(255, 220, 120),
     iconBuilder = TowerIcons.AcornSniper, enabled = true, tempReward = true, hotkey = "8",
     hotkeyCode = Enum.KeyCode.Eight, footprint = {4, 4}},
    {id = "LightningRadish", name = "RADISH", desc = "Chains to nearby enemies",
     color = Color3.fromRGB(150, 60, 130), accent = Color3.fromRGB(230, 180, 255),
     iconBuilder = TowerIcons.LightningRadish, enabled = true, tempReward = true, hotkey = "9",
     hotkeyCode = Enum.KeyCode.Nine, footprint = {6, 6}},
    {id = "SporePuffball", name = "SPORES", desc = "Poison cloud on impact",
     color = Color3.fromRGB(105, 140, 80), accent = Color3.fromRGB(160, 240, 140),
     iconBuilder = TowerIcons.SporePuffball, enabled = true, tempReward = true, hotkey = "0",
     hotkeyCode = Enum.KeyCode.Zero, footprint = {6, 6}},
    {id = "PepperCannon", name = "PEPPER", desc = "Heavy splash bomb",
     color = Color3.fromRGB(170, 45, 35), accent = Color3.fromRGB(255, 150, 50),
     iconBuilder = TowerIcons.PepperCannon, enabled = true, tempReward = true, hotkey = "-",
     hotkeyCode = Enum.KeyCode.Minus, footprint = {8, 8}},
    {id = "MushroomMortar", name = "MORTAR", desc = "Long-range lob with massive blast",
     color = Color3.fromRGB(160, 40, 40), accent = Color3.fromRGB(255, 160, 80),
     iconBuilder = TowerIcons.MushroomMortar, enabled = true, tempReward = true, hotkey = "=",
     hotkeyCode = Enum.KeyCode.Equals, footprint = {12, 12}},
}

-- Sync footprints from shared data (TowerTypes for Core, TempTowers.Templates
-- for aux) so client hardcoded footprints can't drift from server truth. Each
-- hardcoded `footprint = {fw, fd}` above stays as a FALLBACK for tower IDs
-- that don't yet have a shared entry (DoT, CC stubs). When a new aux tower
-- lands in TempTowers.Templates the client's footprint updates automatically
-- on the next server restart — no hand edits needed.
for _, def in ipairs(towerDefs) do
    local shared = TowerTypes[def.id]
    if not shared and TempTowers.Templates then
        shared = TempTowers.Templates[def.id]
    end
    if shared and shared.footprintWidth and shared.footprintDepth then
        def.footprint = { shared.footprintWidth, shared.footprintDepth }
    end
end

------------------------------------------------------------
-- Starter-tower picker modal — extracted to sibling ModuleScript.
-- See TreeOfLife_Client/TowerSelect.lua.
------------------------------------------------------------
require(script:WaitForChild("TowerSelect")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    IS_MOBILE          = IS_MOBILE,
    TweenService       = TweenService,
    towerDefs          = towerDefs,
})

------------------------------------------------------------
-- GRID VISUALIZATION (PARTS-BASED — no SurfaceGui coordinate confusion)
-- Each cell is a real thin neon Part placed at its actual world position.
-- Same world coordinates as raycast and ghost = guaranteed alignment.
------------------------------------------------------------
local gridFolder = nil
local gridCells = {}  -- gridCells[c][r] = Part
local gridVisible = false

local function findFloor()
    local room = workspace:FindFirstChild("TreeOfLifeTDRoom")
    if not room then return nil end
    return room:FindFirstChild("TDFloor")
end

local function findMap2Floor()
    local room = workspace:FindFirstChild("TreeOfLifeMap2Room")
    if not room then return nil end
    return room:FindFirstChild("Map2Floor")
end

-- Collect every floor the placement ghost should be allowed to hit. Order
-- doesn't matter — we discriminate by comparing result.Instance afterwards.
local function allPlacementFloors()
    local floors = {}
    local f1 = findFloor()
    if f1 then table.insert(floors, f1) end
    local f2 = findMap2Floor()
    if f2 then table.insert(floors, f2) end
    return floors
end

-- Convert a floor raycast hit to a (col, row) in shared-grid coordinates.
-- Dispatches by which floor part was hit so the same world-Z can mean
-- different rows on map 1 vs map 2 (map 2's Z origin differs from map 1's).
local function hitToCell(hitInstance, hitX, hitZ)
    local f1 = findFloor()
    if hitInstance == f1 then
        local col = math.floor((hitX - ROOM_MIN_X) / CELL_SIZE)
        local row = math.floor((hitZ - ROOM_MIN_Z) / CELL_SIZE)
        if col < 0 or col >= GRID_COLS or row < 0 or row >= GRID_ROWS then
            return nil
        end
        return col, row
    end
    local f2 = findMap2Floor()
    if hitInstance == f2 then
        local localCol = math.floor((hitX - MAP2_MIN_X) / CELL_SIZE)
        local row = math.floor((hitZ - MAP2_MIN_Z) / CELL_SIZE)
        if localCol < 0 or localCol >= MAP2_COLS or row < 0 or row >= MAP2_ROWS then
            return nil
        end
        return MAP2_COL_OFFSET + localCol, row
    end
    return nil
end

-- Compute the world-space center of a shared-grid cell, dispatching by col
-- onto map 1 or map 2's origin. Y is the floor top on that map.
local function cellCenterWorld(col, row)
    if colIsMap2(col) then
        local localCol = col - MAP2_COL_OFFSET
        local worldX = MAP2_MIN_X + (localCol + 0.5) * CELL_SIZE
        local worldZ = MAP2_MIN_Z + (row + 0.5) * CELL_SIZE
        return worldX, worldZ, MAP2_FLOOR_Y
    end
    local worldX = ROOM_MIN_X + (col + 0.5) * CELL_SIZE
    local worldZ = ROOM_MIN_Z + (row + 0.5) * CELL_SIZE
    return worldX, worldZ, FLOOR_Y
end

local function buildGridParts()
    if gridFolder then return end
    -- Build when AT LEAST one floor is loaded so the hub's progressive
    -- map 2 setup doesn't block map 1's grid render. Cells for the missing
    -- map will just sit at their expected world positions; once that floor
    -- loads they appear aligned with it.
    if not findFloor() and not findMap2Floor() then return end

    gridFolder = Instance.new("Folder")
    gridFolder.Name = "ToL_GridParts"
    gridFolder.Parent = workspace

    local CELL_GAP = 0.1  -- studs of empty space around each cell

    local function makeCell(c, r)
        if not gridCells[c] then gridCells[c] = {} end
        local worldX, worldZ, floorY = cellCenterWorld(c, r)
        local cell = Instance.new("Part")
        cell.Name = ("Cell_%d_%d"):format(c, r)
        cell.Size = Vector3.new(CELL_SIZE - CELL_GAP, 0.05, CELL_SIZE - CELL_GAP)
        cell.CFrame = CFrame.new(worldX, floorY + 0.025, worldZ)
        cell.Anchored = true
        cell.CanCollide = false
        cell.CastShadow = false
        cell.Material = Enum.Material.Neon
        cell.Color = Color3.fromRGB(60, 230, 120)
        cell.Transparency = 0.85
        cell.Parent = gridFolder
        gridCells[c][r] = cell
    end

    -- Map 1 cells
    for c = 0, GRID_COLS - 1 do
        for r = 0, GRID_ROWS - 1 do
            makeCell(c, r)
        end
    end
    -- Map 2 cells
    for c = MAP2_COL_OFFSET, MAP2_TOTAL_COLS - 1 do
        for r = 0, MAP2_ROWS - 1 do
            makeCell(c, r)
        end
    end

    gridFolder.Parent = nil  -- hide until shown
end

local function recolorGrid(highlightCells, validHighlight)
    if not gridFolder then return end
    -- Set base color/visibility for every cell (both maps) based on state.
    local function paintCell(c, r)
        local cell = gridCells[c] and gridCells[c][r]
        if not cell then return end
        local s = localGrid[c][r]
        if s == "open" then
            cell.Transparency = 0.85
            cell.Color = Color3.fromRGB(60, 230, 120)
        elseif s == "path" then
            cell.Transparency = 1
        elseif s == "heart" then
            cell.Transparency = 1
        elseif s == "occupied" then
            cell.Transparency = 0.75
            cell.Color = Color3.fromRGB(200, 80, 60)
        end
    end
    for c = 0, GRID_COLS - 1 do
        for r = 0, GRID_ROWS - 1 do paintCell(c, r) end
    end
    for c = MAP2_COL_OFFSET, MAP2_TOTAL_COLS - 1 do
        for r = 0, MAP2_ROWS - 1 do paintCell(c, r) end
    end
    if highlightCells then
        local col = validHighlight
            and Color3.fromRGB(150, 255, 150)
            or Color3.fromRGB(255, 80, 80)
        for _, cellCoord in ipairs(highlightCells) do
            local c, r = cellCoord[1], cellCoord[2]
            local cell = gridCells[c] and gridCells[c][r]
            if cell then
                cell.Transparency = 0.2
                cell.Color = col
            end
        end
    end
end

local function setGridVisible(v)
    gridVisible = v
    if gridFolder then
        gridFolder.Parent = v and workspace or nil
    end
end

-- Multi-place mode:
--   PC: hold LeftShift/RightShift while clicking to stay in placement mode.
--   Mobile: a toggle button above the hotbar sets multiPlaceEnabled.
-- In both cases, after a successful place we only exit placement if the
-- player is out of stock OR not requesting multi-place.
local multiPlaceEnabled = false
local function shouldKeepPlacing()
    if IS_MOBILE then
        return multiPlaceEnabled
    end
    return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- PC-only "[Hold Shift to place multiple]" tooltip. Single persistent
-- ScreenGui that toggles Enabled alongside placement mode. Positioned at
-- the bottom-center of the screen, above the hotbar.
local multiPlaceHintGui, multiPlaceHintLabel
local function ensureMultiPlaceHint()
    if multiPlaceHintGui then return end
    if IS_MOBILE then return end
    multiPlaceHintGui = Instance.new("ScreenGui")
    multiPlaceHintGui.Name = "ToL_MultiPlaceHint"
    multiPlaceHintGui.IgnoreGuiInset = true
    multiPlaceHintGui.ResetOnSpawn = false
    multiPlaceHintGui.DisplayOrder = 55
    multiPlaceHintGui.Enabled = false
    multiPlaceHintGui.Parent = playerGui
    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(0.5, 1)
    -- 120 = approx hotbar height + margin; keeps the hint above the hotbar.
    frame.Position = UDim2.new(0.5, 0, 1, -120)
    frame.Size = UDim2.new(0, 280, 0, 30)
    frame.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
    frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0
    frame.Parent = multiPlaceHintGui
    local fc = Instance.new("UICorner")
    fc.CornerRadius = UDim.new(0.3, 0)
    fc.Parent = frame
    multiPlaceHintLabel = Instance.new("TextLabel")
    multiPlaceHintLabel.Size = UDim2.new(1, 0, 1, 0)
    multiPlaceHintLabel.BackgroundTransparency = 1
    multiPlaceHintLabel.Text = "Hold [Shift] to place multiple"
    multiPlaceHintLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
    multiPlaceHintLabel.Font = Enum.Font.GothamMedium
    multiPlaceHintLabel.TextSize = 15
    multiPlaceHintLabel.Parent = frame
end
local function setMultiPlaceHint(visible)
    if IS_MOBILE then return end
    ensureMultiPlaceHint()
    if multiPlaceHintGui then multiPlaceHintGui.Enabled = visible end
end

ReplicatedStorage:WaitForChild(Remotes.Names.GridUpdate).OnClientEvent:Connect(function(encoded)
    buildGridParts()
    -- Wire format matches server encodeGridState: row-major over the shared
    -- grid's full extent (cols 0..MAP2_TOTAL_COLS-1, rows 0..MAX_GRID_ROWS-1).
    local idx = 1
    for r = 0, MAX_GRID_ROWS - 1 do
        for c = 0, MAP2_TOTAL_COLS - 1 do
            local ch = string.sub(encoded, idx, idx)
            if ch == "." then
                localGrid[c][r] = "open"
            elseif ch == "#" then
                localGrid[c][r] = "path"
            elseif ch == "H" then
                localGrid[c][r] = "heart"
            elseif ch == "O" then
                localGrid[c][r] = "occupied"
            end
            idx = idx + 1
        end
    end
    if gridVisible then recolorGrid() end
end)

------------------------------------------------------------
-- PLACEMENT SYSTEM
------------------------------------------------------------
-- Hoisted above the placement-ghost functions so buildGhost can read the
-- hotbar's digit assignment for the "[N] to cancel" tooltip. Lua resolves
-- free variables at function-definition time, so this local must exist
-- before buildGhost is defined. buildHotbar populates it later.
local hotbarDigitToDef = {}

local placementMode = nil
local placementDef = nil
local ghostFootprint = nil  -- flat slab matching def.footprint exactly
-- List of per-part ghost specs for the tower currently being placed. Each
-- entry: { part = Part, offset = Vector3, rotate = bool }. updateGhost-
-- Position iterates this list to place each silhouette part relative to
-- the footprint center. Replaces the old single "ghostPost" pillar.
local ghostParts = {}
local currentAnchor = nil

-- Per-tower silhouette specs. Each tower lists a handful of parts that
-- approximate its server-built 3D shape — enough for the placing player
-- to read "this is a Mushroom Mortar, not a Power tower." Sizes + Y
-- offsets mirror the server builder's key landmarks (matching heights
-- so the ghost stands where the real tower will). `rotate = true` rotates
-- a cylinder on Z by 90° so its long axis is vertical; omit for Balls
-- and horizontal cylinders (like Pepper Cannon's pepper body).
local TOWER_GHOST_SPECS = {
    Power = {
        -- Matches buildRedPowerTower's key landmarks: wide base disc,
        -- 10-tall column, platform, gem. Was just column + gem before,
        -- which read as a "plain pillar" and didn't hint at the tower's
        -- distinctive wood-and-gem silhouette.
        { shape = Enum.PartType.Cylinder, size = Vector3.new(3, 7.5, 7.5),    y = 1.5, rotate = true },
        { shape = Enum.PartType.Cylinder, size = Vector3.new(10, 5, 5),       y = 10,  rotate = true },
        { shape = Enum.PartType.Cylinder, size = Vector3.new(2, 6.8, 6.8),    y = 16,  rotate = true },
        { shape = Enum.PartType.Ball,     size = Vector3.new(4.5, 4.5, 4.5),  y = 19.5 },
    },
    FrostMelon = {
        { shape = Enum.PartType.Cylinder, size = Vector3.new(2.5, 2, 2),       y = 1.25, rotate = true },
        { shape = Enum.PartType.Ball,     size = Vector3.new(7, 7, 7),         y = 6 },
    },
    RootSprout = {
        { shape = Enum.PartType.Ball,     size = Vector3.new(6, 2, 6),         y = 1 },
        { shape = Enum.PartType.Ball,     size = Vector3.new(1.8, 1.8, 1.8),   y = 3 },
    },
    ThornVine = {
        { shape = Enum.PartType.Ball,     size = Vector3.new(5, 2.4, 5),       y = 1.2 },
        { shape = Enum.PartType.Cylinder, size = Vector3.new(9, 0.9, 0.9),     y = 6, rotate = true },
        { shape = Enum.PartType.Ball,     size = Vector3.new(1.4, 1.4, 1.4),   y = 10.5 },
    },
    HoneyHive = {
        { shape = Enum.PartType.Block,    size = Vector3.new(7, 2, 11),        y = 1 },
        { shape = Enum.PartType.Cylinder, size = Vector3.new(2, 6, 6),         y = 4,   rotate = true },
        { shape = Enum.PartType.Cylinder, size = Vector3.new(2, 5, 5),         y = 7,   rotate = true },
        { shape = Enum.PartType.Cylinder, size = Vector3.new(2, 3.5, 3.5),     y = 9.5, rotate = true },
    },
    AcornSniper = {
        { shape = Enum.PartType.Cylinder, size = Vector3.new(13, 2, 2),        y = 6.5, rotate = true },
        { shape = Enum.PartType.Ball,     size = Vector3.new(4, 4.5, 4),       y = 14 },
        { shape = Enum.PartType.Ball,     size = Vector3.new(4.4, 2.4, 4.4),   y = 16 },
    },
    LightningRadish = {
        { shape = Enum.PartType.Ball,     size = Vector3.new(8, 9, 8),         y = 4.5 },
        { shape = Enum.PartType.Ball,     size = Vector3.new(1.6, 1.6, 1.6),   y = 12.5 },
    },
    SporePuffball = {
        { shape = Enum.PartType.Cylinder, size = Vector3.new(3, 4, 4),         y = 1.5, rotate = true },
        { shape = Enum.PartType.Ball,     size = Vector3.new(10, 8, 10),       y = 6 },
    },
    PepperCannon = {
        { shape = Enum.PartType.Block,    size = Vector3.new(14, 3, 14),       y = 1.5 },
        { shape = Enum.PartType.Cylinder, size = Vector3.new(6.5, 5, 5),       y = 7 },  -- horizontal (no rotate)
        { shape = Enum.PartType.Ball,     size = Vector3.new(2.8, 2.8, 2.8),   y = 7 },
    },
    MushroomMortar = {
        { shape = Enum.PartType.Cylinder, size = Vector3.new(9, 8, 8),         y = 4.5, rotate = true },
        { shape = Enum.PartType.Ball,     size = Vector3.new(22, 12, 22),      y = 12 },
    },
}

local ghostRangeRing = {}  -- list of segment Parts forming the range circle

-- Range lookup for the placement ghost. Uses the same shared tables the
-- server builds the tower with (TowerTypes for Core, TempTowers.Templates
-- for Aux) and THEN applies the player's accumulated RangeBonusPct so
-- the preview ring matches what the live tower will actually have
-- after placement-time stamping (see Hub placement: Core/Aux<Stat>Pct
-- → tower BonusPct + stat = base × (1 + pct/100)). Previously the
-- preview showed only the base range, which was misleading on map 2
-- where players arrive with 60-100% Range stacked.
local function baseRangeFor(towerId)
    local base
    local category
    if towerId == "Power" then
        base = TowerTypes.Power and TowerTypes.Power.range
        category = "Core"
    else
        local tpl = TempTowers.Templates and TempTowers.Templates[towerId]
        base = tpl and tpl.range
        category = "Aux"
    end
    if not base then return nil end
    local pct = player:GetAttribute(category .. "RangePct") or 0
    return base * (1 + pct / 100)
end

local function clearGhost()
    if ghostFootprint then ghostFootprint:Destroy() end
    for _, gp in ipairs(ghostParts) do
        if gp.part then gp.part:Destroy() end
    end
    for _, seg in ipairs(ghostRangeRing) do seg:Destroy() end
    table.clear(ghostRangeRing)
    ghostFootprint = nil
    table.clear(ghostParts)
end

-- Build a placement ghost: flat footprint outline on the floor + a set of
-- tower-specific silhouette parts above it. The silhouette reads "this is
-- [tower name]" so a Mushroom Mortar ghost doesn't look like a Power tower.
-- Fallback: unknown tower ids get a simple center post so at least the
-- center is marked.
local function buildGhost(def)
    clearGhost()
    local fw = (def and def.footprint and def.footprint[1]) or 4
    local fd = (def and def.footprint and def.footprint[2]) or 4

    ghostFootprint = Instance.new("Part")
    ghostFootprint.Shape = Enum.PartType.Block
    ghostFootprint.Size = Vector3.new(fw * CELL_SIZE, 0.2, fd * CELL_SIZE)
    ghostFootprint.Anchored = true
    ghostFootprint.CanCollide = false
    ghostFootprint.CastShadow = false
    ghostFootprint.Transparency = 0.55
    ghostFootprint.Material = Enum.Material.Neon
    ghostFootprint.Color = Color3.fromRGB(120, 255, 150)
    ghostFootprint.CanQuery = false  -- don't show up as Mouse.Target during right-drag
    ghostFootprint.CFrame = CFrame.new(0, -10000, 0)
    ghostFootprint.Parent = workspace

    local specs = def and def.id and TOWER_GHOST_SPECS[def.id]
    if not specs then
        -- Unknown tower — draw a generic center pillar as fallback.
        specs = {
            { shape = Enum.PartType.Cylinder, size = Vector3.new(14, 0.6, 0.6),
              y = 7, rotate = true },
        }
    end

    -- Ghost silhouette matches the real tower's 50% visual scale (server
    -- applies ScaleTo(0.5) at placement; see TreeOfLife_Hub.server.lua).
    -- Footprint slab stays full size — that's the grid area, not tower
    -- visual.
    local TOWER_SCALE = 0.5
    local topY = 0
    for _, spec in ipairs(specs) do
        local p = Instance.new("Part")
        p.Shape = spec.shape
        p.Size = spec.size * TOWER_SCALE
        p.Anchored = true
        p.CanCollide = false
        p.CastShadow = false
        p.CanQuery = false  -- transparent to Mouse.Target so right-drag camera works
        p.Transparency = 0.35
        p.Material = Enum.Material.Neon
        p.Color = Color3.fromRGB(120, 255, 150)
        p.CFrame = CFrame.new(0, -10000, 0)
        p.Parent = workspace
        table.insert(ghostParts, {
            part = p,
            xOffset = (spec.x or 0) * TOWER_SCALE,
            yOffset = (spec.y or 0) * TOWER_SCALE,
            zOffset = (spec.z or 0) * TOWER_SCALE,
            rotate = spec.rotate == true,
        })
        -- Track the tallest point across all silhouette parts so the
        -- cancel-hint can anchor at the tower's visual mid-height.
        local partTop = ((spec.y or 0) + (spec.size.Y / 2)) * TOWER_SCALE
        if partTop > topY then topY = partTop end
    end

    -- Cancel hint that floats in the middle of the ghost. Parented to
    -- ghostFootprint so it follows every CFrame update without extra
    -- bookkeeping; gets destroyed with the footprint in clearGhost.
    -- Copy varies by platform: mobile points at the on-screen Cancel
    -- button, desktop shows the hotbar digit the tower occupies (same
    -- key that entered placement — pressing it again toggles placement
    -- off, so "[2] to cancel" doubles as a reminder of the hotkey).
    local hotkeyDigit
    for d, other in pairs(hotbarDigitToDef) do
        if other and def and other.id == def.id then
            hotkeyDigit = d
            break
        end
    end
    local hintText
    if IS_MOBILE then
        hintText = "Tap Cancel to exit"
    elseif hotkeyDigit then
        hintText = string.format("[%d] to cancel", hotkeyDigit)
    else
        hintText = "[Esc] to cancel"
    end
    local tipBb = Instance.new("BillboardGui")
    tipBb.Name = "GhostCancelHint"
    tipBb.Size = UDim2.new(0, 140, 0, 34)
    tipBb.StudsOffset = Vector3.new(0, topY / 2, 0)
    tipBb.AlwaysOnTop = true
    tipBb.LightInfluence = 0
    tipBb.Parent = ghostFootprint
    local tipLabel = Instance.new("TextLabel")
    tipLabel.Size = UDim2.new(1, 0, 1, 0)
    tipLabel.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
    tipLabel.BackgroundTransparency = 0.25
    tipLabel.BorderSizePixel = 0
    tipLabel.Text = hintText
    tipLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
    tipLabel.Font = Enum.Font.GothamMedium
    tipLabel.TextSize = 14
    tipLabel.Parent = tipBb
    local tipCorner = Instance.new("UICorner")
    tipCorner.CornerRadius = UDim.new(0, 6)
    tipCorner.Parent = tipLabel

    -- Range ring: a thin circle of flat segments on the floor showing where
    -- this tower will cover. Same segment-scheme as the tower-selection
    -- ring in buildSelectionVisuals so the two visuals read identically
    -- (pre-place preview → post-place selection outline). Positioned at
    -- Y=-10000 until updateGhostPosition places it.
    local range = baseRangeFor(def and def.id)
    if range and range > 0 then
        local SEGMENTS = 48
        local segLen = (2 * math.pi * range) / SEGMENTS
        for i = 0, SEGMENTS - 1 do
            local seg = Instance.new("Part")
            seg.Size = Vector3.new(segLen + 0.1, 0.12, 0.35)
            seg.Anchored = true
            seg.CanCollide = false
            seg.CastShadow = false
            seg.CanQuery = false  -- don't intercept Mouse.Target
            seg.Material = Enum.Material.Neon
            seg.Color = Color3.fromRGB(80, 160, 255)
            seg.Transparency = 0.3
            seg.CFrame = CFrame.new(0, -10000, 0)
            seg.Parent = workspace
            table.insert(ghostRangeRing, seg)
        end
    end
end

local function updateGhostPosition(anchor, valid, def)
    if not ghostFootprint or not anchor then
        if ghostFootprint then ghostFootprint.CFrame = CFrame.new(0, -10000, 0) end
        for _, gp in ipairs(ghostParts) do
            if gp.part then gp.part.CFrame = CFrame.new(0, -10000, 0) end
        end
        for _, seg in ipairs(ghostRangeRing) do
            seg.CFrame = CFrame.new(0, -10000, 0)
        end
        return
    end
    local fw, fd = def.footprint[1], def.footprint[2]
    local centerCol = anchor[1] + (fw - 1) / 2
    local centerRow = anchor[2] + (fd - 1) / 2
    local isMap2 = colIsMap2(anchor[1])
    local worldX, worldZ, floorY
    if isMap2 then
        local localCenterCol = centerCol - MAP2_COL_OFFSET
        worldX = MAP2_MIN_X + (localCenterCol + 0.5) * CELL_SIZE
        worldZ = MAP2_MIN_Z + (centerRow + 0.5) * CELL_SIZE
        floorY = MAP2_FLOOR_Y
    else
        worldX = ROOM_MIN_X + (centerCol + 0.5) * CELL_SIZE
        worldZ = ROOM_MIN_Z + (centerRow + 0.5) * CELL_SIZE
        floorY = FLOOR_Y
    end
    local top = Vector3.new(worldX, floorY, worldZ)
    -- Green = valid, red = invalid. Keep the tint fixed across all towers —
    -- using each def's accent color collided hard for the Core ghost, whose
    -- accent (coral RGB(255,90,80)) reads as "invalid red" to the player.
    local tint = valid and Color3.fromRGB(120, 255, 150) or Color3.fromRGB(255, 80, 80)

    ghostFootprint.CFrame = CFrame.new(top + Vector3.new(0, 0.15, 0))
    ghostFootprint.Color = tint

    for _, gp in ipairs(ghostParts) do
        local cf = CFrame.new(top + Vector3.new(gp.xOffset, gp.yOffset, gp.zOffset))
        if gp.rotate then
            cf = cf * CFrame.Angles(0, 0, math.rad(90))
        end
        gp.part.CFrame = cf
        gp.part.Color = tint
    end

    -- Range ring: each segment orbits the tower center on the floor plane.
    -- Ring Y sits 0.35 above the floor so it clears the path tiles
    -- (Size Y = 0.3, top = floorY + 0.3) instead of being buried under
    -- them when the ring sweeps across the enemy walkway.
    local ringCount = #ghostRangeRing
    if ringCount > 0 then
        local rangeVal = baseRangeFor(def and def.id) or 0
        local ringY = floorY + 0.35
        for i, seg in ipairs(ghostRangeRing) do
            local a = ((i - 1) / ringCount) * 2 * math.pi
            local x = worldX + math.cos(a) * rangeVal
            local z = worldZ + math.sin(a) * rangeVal
            seg.CFrame = CFrame.new(x, ringY, z)
                * CFrame.Angles(0, -a + math.pi / 2, 0)
        end
    end
end

local function getCellUnderMouse()
    local mousePos = UserInputService:GetMouseLocation()
    local unitRay = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
    local floors = allPlacementFloors()
    if #floors == 0 then return nil end
    -- Include filter on both floors — grid Parts and ghost Parts cannot
    -- block the ray. hitToCell dispatches on which floor the ray landed on.
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Include
    rp.FilterDescendantsInstances = floors
    local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 2000, rp)
    if not result then return nil end
    return hitToCell(result.Instance, result.Position.X, result.Position.Z)
end

local function hoveredToAnchor(hoverCol, hoverRow, fw, fd)
    -- Center the footprint on the hovered cell. For odd footprints (1x1, 3x3)
    -- the tap is exactly at the center cell. For even footprints (2x2), we shift
    -- so the tap falls on the top-left of the footprint, which reads better
    -- visually when the camera looks down at the floor at an angle.
    local ac = hoverCol - math.floor(fw / 2)
    local ar = hoverRow - math.floor((fd - 1) / 2)
    -- Clamp to the hovered cell's map so the footprint can't slide across
    -- the map-1/map-2 column boundary.
    local minCol = colMinCol(hoverCol)
    local maxCol = colMaxCol(hoverCol)
    local maxRow = colRowMax(hoverCol)
    ac = math.max(minCol, math.min(maxCol - fw + 1, ac))
    ar = math.max(0, math.min(maxRow - fd + 1, ar))
    return ac, ar
end

local function footprintCells(anchorCol, anchorRow, fw, fd)
    local cells = {}
    for dc = 0, fw - 1 do
        for dr = 0, fd - 1 do
            table.insert(cells, {anchorCol + dc, anchorRow + dr})
        end
    end
    return cells
end

local function isAnchorValid(anchorCol, anchorRow, fw, fd)
    -- Bounds depend on which map the anchor belongs to (mirrors the server's
    -- canPlaceAt). A footprint that straddles the map-1/map-2 boundary is
    -- rejected here because the "other" col range is outside the anchor's
    -- legal col window.
    local minCol = colMinCol(anchorCol)
    local maxCol = colMaxCol(anchorCol)
    local maxRow = colRowMax(anchorCol)
    for dc = 0, fw - 1 do
        for dr = 0, fd - 1 do
            local c = anchorCol + dc
            local r = anchorRow + dr
            if c < minCol or c > maxCol or r < 0 or r > maxRow then return false end
            if localGrid[c][r] ~= "open" then return false end
        end
    end
    return true
end

local refreshHotbarTints
local hotbarGui = nil  -- forward declaration (actual value set later)
local lastFloorAnchor = nil  -- forward declaration for mobile ghost tracking
local activeTouchObject = nil  -- forward declaration for mobile touch tracking
local placementModeStartTime = 0  -- when current placement mode began (for touch filtering)

-- Mobile detection: touch-only devices (phones, tablets) get a big touch-friendly
-- CANCEL / PLACE bar during placement instead of relying on the grid tap + hotbar.
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local mobilePlaceGui = nil

local function hideMobilePlaceUI()
    if mobilePlaceGui then
        mobilePlaceGui:Destroy()
        mobilePlaceGui = nil
    end
end

local function showMobilePlaceUI()
    hideMobilePlaceUI()
    mobilePlaceGui = Instance.new("ScreenGui")
    mobilePlaceGui.Name = "ToL_MobilePlace"
    mobilePlaceGui.IgnoreGuiInset = false
    mobilePlaceGui.ResetOnSpawn = false
    mobilePlaceGui.DisplayOrder = 60
    mobilePlaceGui.Parent = playerGui

    local slotSize = 80
    local slotPadding = 8
    local barPadding = 12
    -- Cancel (1×), Place (3×): widths 80 and 240
    local cancelW = slotSize
    local placeW = slotSize * 3
    local barWidth = cancelW + placeW + slotPadding + barPadding * 2

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, barWidth, 0, slotSize + 20)
    bar.Position = UDim2.new(0.5, -barWidth/2, 1, -(slotSize + 40))
    bar.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
    bar.BackgroundTransparency = 0.2
    bar.BorderSizePixel = 0
    bar.Parent = mobilePlaceGui
    local barCorner = Instance.new("UICorner")
    barCorner.CornerRadius = UDim.new(0.12, 0)
    barCorner.Parent = bar

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = UDim.new(0, slotPadding)
    layout.Parent = bar

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, barPadding)
    padding.PaddingRight = UDim.new(0, barPadding)
    padding.Parent = bar

    -- CANCEL button (1× tower icon size)
    local cancelBtn = Instance.new("TextButton")
    cancelBtn.Size = UDim2.new(0, cancelW, 0, slotSize)
    cancelBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
    cancelBtn.BorderSizePixel = 0
    cancelBtn.AutoButtonColor = false
    cancelBtn.Text = "×"
    cancelBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    cancelBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    cancelBtn.TextStrokeTransparency = 0.4
    cancelBtn.Font = Enum.Font.FredokaOne
    cancelBtn.TextSize = 56
    cancelBtn.Parent = bar
    local cancelCorner = Instance.new("UICorner")
    cancelCorner.CornerRadius = UDim.new(0.1, 0)
    cancelCorner.Parent = cancelBtn

    -- PLACE button (3× tower icon size)
    local placeBtn = Instance.new("TextButton")
    placeBtn.Size = UDim2.new(0, placeW, 0, slotSize)
    placeBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 80)
    placeBtn.BorderSizePixel = 0
    placeBtn.AutoButtonColor = false
    placeBtn.Text = "PLACE"
    placeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    placeBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    placeBtn.TextStrokeTransparency = 0.4
    placeBtn.Font = Enum.Font.FredokaOne
    placeBtn.TextSize = 28
    placeBtn.Parent = bar
    local placeCorner = Instance.new("UICorner")
    placeCorner.CornerRadius = UDim.new(0.1, 0)
    placeCorner.Parent = placeBtn

    -- MULTI-PLACE toggle (sits above the cancel/place row so the player
    -- can flip "place many of this tower" on before tapping PLACE). Label
    -- includes a ✓ / empty-box glyph that mirrors the persistent state
    -- in multiPlaceEnabled.
    local multiToggle = Instance.new("TextButton")
    multiToggle.AnchorPoint = Vector2.new(0.5, 1)
    multiToggle.Position = UDim2.new(0.5, 0, 1, -(slotSize + 16))
    multiToggle.Size = UDim2.new(0, 220, 0, 40)
    multiToggle.BorderSizePixel = 0
    multiToggle.AutoButtonColor = false
    multiToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
    multiToggle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    multiToggle.TextStrokeTransparency = 0.4
    multiToggle.Font = Enum.Font.FredokaOne
    multiToggle.TextSize = 18
    multiToggle.Parent = mobilePlaceGui
    local mtCorner = Instance.new("UICorner")
    mtCorner.CornerRadius = UDim.new(0.3, 0)
    mtCorner.Parent = multiToggle
    local function refreshMultiToggle()
        if multiPlaceEnabled then
            multiToggle.Text = "☑  Place Multiple"
            multiToggle.BackgroundColor3 = Color3.fromRGB(80, 150, 80)
        else
            multiToggle.Text = "☐  Place Multiple"
            multiToggle.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
        end
    end
    refreshMultiToggle()
    multiToggle.MouseButton1Click:Connect(function()
        multiPlaceEnabled = not multiPlaceEnabled
        refreshMultiToggle()
    end)

    return cancelBtn, placeBtn
end

local function exitPlacementMode()
    placementMode = nil
    placementDef = nil
    currentAnchor = nil
    lastFloorAnchor = nil
    activeTouchObject = nil
    clearGhost()
    setGridVisible(false)
    if IS_MOBILE then
        hideMobilePlaceUI()
        if hotbarGui then hotbarGui.Enabled = true end
    else
        setMultiPlaceHint(false)
    end
    if refreshHotbarTints then refreshHotbarTints() end
end

local function tryPlaceAtCurrentAnchor()
    if not placementMode or not placementDef then return end
    -- On mobile, tapping PLACE sets "mouse position" to the button. Use the
    -- last cached floor anchor instead of whatever currentAnchor is right now.
    local anchorToUse = IS_MOBILE and lastFloorAnchor or currentAnchor
    if not anchorToUse then return end
    local fw, fd = placementDef.footprint[1], placementDef.footprint[2]
    if isAnchorValid(anchorToUse[1], anchorToUse[2], fw, fd) then
        ReplicatedStorage:WaitForChild(Remotes.Names.PlaceTower):FireServer(
            placementMode, anchorToUse[1], anchorToUse[2])
        -- Stay in placement if the player asked for multi-place AND there's
        -- at least one more in stock. Stock hasn't replicated yet; use the
        -- pre-place value minus 1. clearGhost/recolorGrid re-runs so the
        -- ghost repositions cleanly on the next hover.
        local currentStock = player:GetAttribute(placementDef.id .. "Stock") or 0
        if shouldKeepPlacing() and currentStock > 1 then
            recolorGrid()
        else
            exitPlacementMode()
        end
    end
end

local function enterPlacementMode(def)
    local stock = player:GetAttribute(def.id .. "Stock") or 0
    if stock <= 0 then return end
    if placementMode then clearGhost() end
    placementMode = def.id
    placementDef = def
    placementModeStartTime = os.clock()
    buildGhost(def)
    setGridVisible(true)
    recolorGrid()
    if IS_MOBILE then
        if hotbarGui then hotbarGui.Enabled = false end
        local cancelBtn, placeBtn = showMobilePlaceUI()
        cancelBtn.MouseButton1Click:Connect(exitPlacementMode)
        placeBtn.MouseButton1Click:Connect(tryPlaceAtCurrentAnchor)
    else
        setMultiPlaceHint(true)
    end
    if refreshHotbarTints then refreshHotbarTints() end
end

-- Raycast at a specific screen position → grid cell (col, row) if it hits the floor.
-- Used by mobile touch tracking where we need to test arbitrary finger positions
-- rather than UserInputService:GetMouseLocation() (which jumps to UI taps).
local function getCellAtScreenPos(screenX, screenY)
    local unitRay = camera:ViewportPointToRay(screenX, screenY)
    local floors = allPlacementFloors()
    if #floors == 0 then return nil end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Include
    rp.FilterDescendantsInstances = floors
    local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 2000, rp)
    if not result then return nil end
    return hitToCell(result.Instance, result.Position.X, result.Position.Z)
end

-- Mobile: we only move the ghost when a specific touch is actively held on the
-- floor. Once that touch ends, the ghost freezes at its last floor position.
-- Other taps (on UI, elsewhere) do NOT move the ghost. This means tapping PLACE
-- places at the held/last-held position, not at the button's position.
local activeTouchObject = nil  -- the InputObject we're currently tracking

local function updateGhostFromActiveTouch()
    if not activeTouchObject or not placementMode or not placementDef then return end
    local pos = activeTouchObject.Position  -- Vector3: (x, y, 0) screen coords
    -- Mobile touches register slightly above the visual fingertip. Add a small
    -- Y offset so the ghost lines up with where the player's finger appears,
    -- not with the raw touch sensor point.
    local TOUCH_Y_OFFSET = 24
    local col, row = getCellAtScreenPos(pos.X, pos.Y + TOUCH_Y_OFFSET)
    if not col then return end  -- finger not on floor; keep last position
    local fw, fd = placementDef.footprint[1], placementDef.footprint[2]
    local anchorCol, anchorRow = hoveredToAnchor(col, row, fw, fd)
    currentAnchor = {anchorCol, anchorRow}
    lastFloorAnchor = {anchorCol, anchorRow}
end

RunService.RenderStepped:Connect(function()
    if not placementMode then return end

    if IS_MOBILE then
        -- If a touch is actively held, update ghost from that touch only.
        updateGhostFromActiveTouch()
        -- Always redraw ghost at the cached anchor (whether it just moved or not).
        if lastFloorAnchor then
            local fw, fd = placementDef.footprint[1], placementDef.footprint[2]
            local valid = isAnchorValid(lastFloorAnchor[1], lastFloorAnchor[2], fw, fd)
            updateGhostPosition(lastFloorAnchor, valid, placementDef)
            recolorGrid(footprintCells(lastFloorAnchor[1], lastFloorAnchor[2], fw, fd), valid)
        else
            updateGhostPosition(nil, false, placementDef)
            recolorGrid()
        end
        return
    end

    -- Desktop: follow cursor continuously
    local col, row = getCellUnderMouse()
    if not col then
        currentAnchor = nil
        updateGhostPosition(nil, false, placementDef)
        recolorGrid()
        return
    end
    local fw, fd = placementDef.footprint[1], placementDef.footprint[2]
    local anchorCol, anchorRow = hoveredToAnchor(col, row, fw, fd)
    currentAnchor = {anchorCol, anchorRow}
    lastFloorAnchor = {anchorCol, anchorRow}
    local valid = isAnchorValid(anchorCol, anchorRow, fw, fd)
    updateGhostPosition(currentAnchor, valid, placementDef)
    recolorGrid(footprintCells(anchorCol, anchorRow, fw, fd), valid)
end)

-- Mobile touch tracking: capture a touch when it begins on the floor (not UI),
-- follow its movement, release when it ends. Only ONE active touch at a time.
-- Roblox's default mobile thumbstick sits in the bottom-left corner, roughly
-- a 220x220 pixel area. We use fixed pixel sizes (not viewport percentages)
-- to avoid eating half the screen on small devices.
local function isInMovementZone(screenX, screenY)
    local viewport = camera.ViewportSize
    local zoneSize = 240  -- pixels
    return screenX < zoneSize and screenY > (viewport.Y - zoneSize)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if not IS_MOBILE then return end
    if not placementMode then return end
    if gameProcessed then return end  -- skip taps on UI
    if input.UserInputType ~= Enum.UserInputType.Touch then return end
    if activeTouchObject then return end  -- already tracking another finger
    -- Entry-touch grace period: skip the first 0.3s after placement mode
    -- begins so the touch that just selected a tower (and continued into
    -- a drag) can be a camera rotate instead of accidentally anchoring
    -- the ghost.
    if os.clock() - placementModeStartTime < 0.3 then return end
    -- Skip the movement thumbstick area so the left thumb can move the
    -- character without accidentally re-anchoring the ghost. This also catches
    -- the thumbstick-rebuild re-fire after reset, since those touches are in
    -- the thumbstick's screen region.
    if isInMovementZone(input.Position.X, input.Position.Y) then return end
    -- Apply same Y offset as ghost update so "did it land on the floor?" check
    -- matches where the ghost would actually appear.
    local col, row = getCellAtScreenPos(input.Position.X, input.Position.Y + 24)
    if not col then return end
    activeTouchObject = input
end)

UserInputService.InputEnded:Connect(function(input)
    if input == activeTouchObject then
        activeTouchObject = nil  -- freeze ghost at lastFloorAnchor
    end
end)

-- DYNAMIC HOTBAR NUMBERING
-- Hotbar slot 1 = starter (Power); slot 2+ = temp towers the player has
-- earned, in towerDefs order. Pressing digit key N activates whatever
-- def is currently at position N. hotbarDigitToDef is hoisted above the
-- PLACEMENT SYSTEM section so the ghost tooltip can read it too; only
-- HOTBAR_DIGIT_FOR_KEYCODE lives down here since it's only consumed by
-- the keybind handler immediately below.
local HOTBAR_DIGIT_FOR_KEYCODE = {
    [Enum.KeyCode.One]   = 1, [Enum.KeyCode.Two]   = 2,
    [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four]  = 4,
    [Enum.KeyCode.Five]  = 5, [Enum.KeyCode.Six]   = 6,
    [Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8,
    [Enum.KeyCode.Nine]  = 9,
}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if placementMode and input.UserInputType == Enum.UserInputType.MouseButton1 and not IS_MOBILE then
        -- Entry-click grace period: the same click that selected the tower
        -- (either from the hotbar or the choice-UI card) can reach this
        -- handler too if the GUI was destroyed before InputBegan walks the
        -- listener chain. 0.3s grace lets the player release/re-click
        -- normally and also lets the next click be a camera rotate rather
        -- than an accidental placement.
        if os.clock() - placementModeStartTime < 0.3 then return end
        if currentAnchor then
            local fw, fd = placementDef.footprint[1], placementDef.footprint[2]
            if isAnchorValid(currentAnchor[1], currentAnchor[2], fw, fd) then
                ReplicatedStorage:WaitForChild(Remotes.Names.PlaceTower):FireServer(
                    placementMode, currentAnchor[1], currentAnchor[2])
                -- Shift-hold keeps placement mode open until stock depletes.
                local currentStock = player:GetAttribute(placementDef.id .. "Stock") or 0
                if shouldKeepPlacing() and currentStock > 1 then
                    recolorGrid()
                else
                    exitPlacementMode()
                end
            end
        end
        return
    end
    if placementMode and input.KeyCode == Enum.KeyCode.Escape then
        exitPlacementMode()
        return
    end
    -- Number keys 1..9 map to whichever hotbar SLOT currently occupies that
    -- position. Slot positions are dynamic (populated by buildHotbar from the
    -- player's current stock), so pressing 2 always hits the 2nd visible slot
    -- even if the towerDefs order would have given it a different static hotkey.
    local digit = HOTBAR_DIGIT_FOR_KEYCODE[input.KeyCode]
    if digit then
        local def = hotbarDigitToDef[digit]
        if def then
            local stock = player:GetAttribute(def.id .. "Stock") or 0
            if stock > 0 then
                if placementMode == def.id then
                    exitPlacementMode()
                else
                    enterPlacementMode(def)
                end
            end
        end
        return
    end
end)

local hotbarSlots = {}

function refreshHotbarTints()
    for id, slot in pairs(hotbarSlots) do
        local stock = player:GetAttribute(id .. "Stock") or 0
        local isActive = placementMode == id
        slot.Slot.BackgroundColor3 = isActive and slot.def.accent or slot.def.color
        slot.Slot.BackgroundTransparency = stock > 0 and 0 or 0.6
        slot.CountLabel.Text = "×" .. stock
    end
end

local function buildHotbar()
    if hotbarGui then hotbarGui:Destroy() end
    hotbarSlots = {}
    -- Clear prior mapping; populated below as we walk `shown`.
    table.clear(hotbarDigitToDef)
    -- Slot visibility rules:
    --   Core (Power): always visible once granted. Stock may drop to 0 after
    --     placing, but keeping the slot on the hotbar lets the player see
    --     "that's my Core tower (out for now)" instead of it vanishing.
    --   Aux (temp towers): visible once the player has ever been granted
    --     any stock of that type this run. Detected via <TowerId>Rarity
    --     being set (only set when the player wins / equips the tower).
    --   Disabled placeholder slots (DoT/CC): hidden unless the enabled
    --     flag is true — those are future starters, not yet implemented.
    local shown = {}
    for _, def in ipairs(towerDefs) do
        local stock   = player:GetAttribute(def.id .. "Stock") or 0
        local rarity  = player:GetAttribute(def.id .. "Rarity")
        local isCore  = (def.id == "Power")
        local everOwned = stock > 0 or rarity ~= nil
        -- Core always shows if it's ever been granted (HasBeenGrantedStock).
        if isCore then
            if player:GetAttribute("HasBeenGrantedStock") then
                table.insert(shown, def)
            end
        elseif def.tempReward then
            if everOwned then table.insert(shown, def) end
        else
            -- Legacy / future starter type (DoT / CC): only show if actually
            -- granted stock > 0, gated by its `enabled` flag.
            if def.enabled and stock > 0 then table.insert(shown, def) end
        end
    end
    if #shown == 0 then return end

    -- Assign digit → def for the first 9 slots (keyboard shortcuts 1..9).
    for i = 1, math.min(9, #shown) do
        hotbarDigitToDef[i] = shown[i]
    end

    hotbarGui = Instance.new("ScreenGui")
    hotbarGui.Name = "ToL_Hotbar"
    hotbarGui.IgnoreGuiInset = false
    hotbarGui.ResetOnSpawn = false
    hotbarGui.DisplayOrder = 50
    hotbarGui.Parent = playerGui

    local slotSize = 80
    local slotPadding = 8
    local barPadding = 12
    local barWidth = (#shown * slotSize) + ((#shown - 1) * slotPadding) + (barPadding * 2)

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, barWidth, 0, slotSize + 20)
    bar.Position = UDim2.new(0.5, -barWidth/2, 1, -(slotSize + 40))
    bar.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
    bar.BackgroundTransparency = 0.2
    bar.BorderSizePixel = 0
    bar.Parent = hotbarGui
    round(bar, 0.12)

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = UDim.new(0, slotPadding)
    layout.Parent = bar

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, barPadding)
    padding.PaddingRight = UDim.new(0, barPadding)
    padding.Parent = bar

    -- Rarity palette — string-keyed to match the `<id>Rarity` player
    -- attribute value set by TempTowerRewards (which stores the rarity
    -- NAME, not an integer). Reuses the shared TempTowers.RarityColors
    -- so the palette stays in lockstep with UpgradeCards.RARITY_TIERS.
    local HOTBAR_RARITY_COLORS = TempTowers.RarityColors

    for slotIndex, def in ipairs(shown) do
        local slot = Instance.new("TextButton")
        slot.Size = UDim2.new(0, slotSize, 0, slotSize)
        slot.BackgroundColor3 = def.color
        slot.BorderSizePixel = 0
        slot.AutoButtonColor = false
        slot.Text = ""
        slot.Parent = bar
        round(slot, 0.1)

        -- Rarity outline: the slot's border matches the tower's rarity
        -- color so the player can read an aux's tier at a glance without
        -- opening a tooltip. Power/Core has no rarity attribute → we hide
        -- the stroke by making it transparent.
        local rarityStroke = Instance.new("UIStroke")
        rarityStroke.Thickness = 3
        rarityStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        rarityStroke.Parent = slot
        local function refreshRarityStroke()
            local rar = player:GetAttribute(def.id .. "Rarity")
            if rar and HOTBAR_RARITY_COLORS[rar] then
                rarityStroke.Color = HOTBAR_RARITY_COLORS[rar]
                rarityStroke.Transparency = 0
            else
                rarityStroke.Transparency = 1
            end
        end
        refreshRarityStroke()
        player:GetAttributeChangedSignal(def.id .. "Rarity"):Connect(refreshRarityStroke)

        -- iconBg fills the whole slot so the slot's def.color never peeks
        -- around the edges as a secondary inner outline. The rarity UIStroke
        -- is now the only visible border on the slot.
        local iconBg = Instance.new("Frame")
        iconBg.Size = UDim2.new(1, 0, 1, 0)
        iconBg.Position = UDim2.new(0, 0, 0, 0)
        iconBg.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconBg.BorderSizePixel = 0
        iconBg.Parent = slot
        round(iconBg, 0.1)
        def.iconBuilder(iconBg)
        local keyLabel = Instance.new("TextLabel")
        keyLabel.Size = UDim2.new(0, 20, 0, 20)
        keyLabel.Position = UDim2.new(0, 3, 0, 3)
        keyLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        keyLabel.BackgroundTransparency = 0.2
        keyLabel.BorderSizePixel = 0
        -- Dynamic slot number (first visible = 1, second = 2, ...) — Power
        -- is always first in towerDefs so Power stays as "1"; temp towers
        -- renumber based on what the player has earned.
        keyLabel.Text = tostring(slotIndex)
        keyLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        keyLabel.Font = Enum.Font.FredokaOne
        keyLabel.TextSize = 16
        keyLabel.ZIndex = 2
        keyLabel.Parent = slot
        round(keyLabel, 0.2)
        local countLabel = Instance.new("TextLabel")
        countLabel.Size = UDim2.new(0, 32, 0, 20)
        countLabel.Position = UDim2.new(1, -34, 1, -22)
        countLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        countLabel.BackgroundTransparency = 0.2
        countLabel.BorderSizePixel = 0
        countLabel.Text = "×1"
        countLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        countLabel.Font = Enum.Font.FredokaOne
        countLabel.TextSize = 16
        countLabel.ZIndex = 2
        countLabel.Parent = slot
        round(countLabel, 0.2)
        slot.MouseButton1Click:Connect(function()
            local stock = player:GetAttribute(def.id .. "Stock") or 0
            if stock <= 0 then return end
            if placementMode == def.id then
                exitPlacementMode()
            else
                enterPlacementMode(def)
            end
        end)

        -- Hover tooltip: resolve the tower's display name from the shared
        -- TowerTypes / TempTowers modules (not def.name — that's the short
        -- all-caps label, e.g. "MELON" vs "Frost Melon"). Tooltip is a
        -- self-contained small ScreenGui positioned above the slot.
        if not IS_MOBILE then
            local tooltipGui, tooltipLabel
            local function showTooltip()
                local displayName
                if def.id == "Power" then
                    displayName = (TowerTypes.Power and TowerTypes.Power.displayName) or "Power Tower"
                else
                    local tpl = TempTowers.Templates and TempTowers.Templates[def.id]
                    displayName = (tpl and tpl.displayName) or def.name or def.id
                end
                if not tooltipGui then
                    tooltipGui = Instance.new("ScreenGui")
                    tooltipGui.Name = "ToL_HotbarTooltip"
                    tooltipGui.IgnoreGuiInset = true
                    tooltipGui.ResetOnSpawn = false
                    tooltipGui.DisplayOrder = 60
                    tooltipGui.Parent = playerGui
                    local frame = Instance.new("Frame")
                    -- Anchor at top-center so the tooltip hangs BELOW the slot.
                    -- Previously (0.5, 1) put it above the slot, which overlapped
                    -- the mob lane on map 2 where towers sit near the path.
                    frame.AnchorPoint = Vector2.new(0.5, 0)
                    frame.Size = UDim2.new(0, 0, 0, 26)
                    frame.AutomaticSize = Enum.AutomaticSize.X
                    frame.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
                    frame.BackgroundTransparency = 0.2
                    frame.BorderSizePixel = 0
                    frame.Parent = tooltipGui
                    local fc = Instance.new("UICorner")
                    fc.CornerRadius = UDim.new(0.3, 0)
                    fc.Parent = frame
                    local pad = Instance.new("UIPadding")
                    pad.PaddingLeft = UDim.new(0, 10)
                    pad.PaddingRight = UDim.new(0, 10)
                    pad.Parent = frame
                    tooltipLabel = Instance.new("TextLabel")
                    tooltipLabel.Size = UDim2.new(0, 0, 1, 0)
                    tooltipLabel.AutomaticSize = Enum.AutomaticSize.X
                    tooltipLabel.BackgroundTransparency = 1
                    tooltipLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
                    tooltipLabel.Font = Enum.Font.GothamMedium
                    tooltipLabel.TextSize = 14
                    tooltipLabel.Parent = frame
                end
                tooltipLabel.Text = displayName
                -- Position below the slot: read slot's absolute screen
                -- position, center the tooltip just under its bottom edge.
                local pos = slot.AbsolutePosition
                local size = slot.AbsoluteSize
                local frame = tooltipGui:FindFirstChildWhichIsA("Frame")
                if frame then
                    frame.Position = UDim2.new(0, pos.X + size.X / 2, 0, pos.Y + size.Y + 6)
                end
                tooltipGui.Enabled = true
            end
            local function hideTooltip()
                if tooltipGui then tooltipGui.Enabled = false end
            end
            slot.MouseEnter:Connect(showTooltip)
            slot.MouseLeave:Connect(hideTooltip)
            slot.AncestryChanged:Connect(function(_, parent)
                if not parent and tooltipGui then tooltipGui:Destroy() end
            end)
        end

        hotbarSlots[def.id] = {Slot = slot, IconBg = iconBg, CountLabel = countLabel, def = def}
        player:GetAttributeChangedSignal(def.id .. "Stock"):Connect(function()
            refreshHotbarTints()
        end)
    end
    refreshHotbarTints()
end

ReplicatedStorage:WaitForChild(Remotes.Names.ShowHotbar).OnClientEvent:Connect(function()
    buildHotbar()
end)

task.spawn(function()
    while not findFloor() do task.wait(0.2) end
    buildGridParts()
end)

------------------------------------------------------------
-- DEV RESET BUTTON (bottom-left)
-- Desktop: always-visible "RESET" button
-- Mobile: collapsed "-" button that expands to reveal RESET (and auto-collapses)
------------------------------------------------------------
local devGui = Instance.new("ScreenGui")
devGui.Name = "ToL_DevConsole"
devGui.IgnoreGuiInset = false
devGui.ResetOnSpawn = false
devGui.DisplayOrder = 10
devGui.Parent = playerGui

-- Forward-declared so fireReset() and the WaveState handler reference
-- the same local. Set true when GameOver "lose" fires; locks wave HUD to
-- DEFEATED until DevReset clears it.
local gameLost = false

-- Forward-declared so fireReset() can branch on mapId. The real WaveState
-- handler below overwrites this table's fields on each broadcast.
local currentWaveState = {wave = 0, totalWaves = 5, mobsAlive = 0, inProgress = false}

local function fireReset(btn)
    -- RESET = full fresh-server state regardless of current map. DevReset
    -- on the server destroys towers, frees grid, heals heart, clears stage
    -- + wave state, and resets every per-run player attribute. Also fires
    -- DevTeleport("map1") on completion so the player doesn't end up on
    -- map 2 with a fresh map-1-only state.
    gameLost = false  -- unlock wave HUD; new game starts fresh
    ReplicatedStorage:WaitForChild(Remotes.Names.DevReset):FireServer()
    -- Small delay so the server's RunReset + grid broadcast happen before
    -- we ship the player back to map 1 — otherwise the teleport can race
    -- the map-2 → map-1 SwitchMap fire.
    task.delay(0.2, function()
        local tp = ReplicatedStorage:FindFirstChild(Remotes.Names.DevTeleport)
        if tp then tp:FireServer("map1") end
    end)
    btn.Text = "RESETTING..."
    task.wait(0.5)
    btn.Text = "RESET"
end

------------------------------------------------------------
-- DEV PANEL — gear-icon dropdown with PROGRESS / TOOLS / TELEPORT /
-- INVENTORY categories + RUN LUCK readout. Extracted to sibling module.
-- See TreeOfLife_Client/DevPanel.lua.
------------------------------------------------------------
require(script:WaitForChild("DevPanel")).setup({
    devGui              = devGui,
    player              = player,
    playerGui           = playerGui,
    IS_MOBILE           = IS_MOBILE,
    ReplicatedStorage   = ReplicatedStorage,
    Remotes             = Remotes,
    CollectionService   = CollectionService,
    UserInputService    = UserInputService,
    Tags                = Tags,
})

------------------------------------------------------------
-- GAME SPEED SELECTOR — top-right HUD bar with PAUSE + 1/2/3/5/10×
-- speed buttons. Extracted to sibling module.
------------------------------------------------------------
require(script:WaitForChild("GameSpeedSelector")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
})

------------------------------------------------------------
-- WAVE UI: HUD + start button + upgrade picker + game over
------------------------------------------------------------

-- Wave HUD (top-center): shows wave X / Y and mobs alive
local waveGui = Instance.new("ScreenGui")
waveGui.Name = "ToL_WaveHUD"
waveGui.IgnoreGuiInset = true  -- push the strip as close to the top edge as possible
waveGui.ResetOnSpawn = false
waveGui.DisplayOrder = 225  -- above upgrade picker (220), below game-over modal (230)
waveGui.Parent = playerGui

local waveFrame = Instance.new("Frame")
waveFrame.Size = UDim2.new(0, 280, 0, 46)
waveFrame.Position = UDim2.new(0.5, -180, 0, 0)  -- flush to top
waveFrame.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
waveFrame.BackgroundTransparency = 0.25
waveFrame.BorderSizePixel = 0
waveFrame.Visible = false
waveFrame.Parent = waveGui
do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0.18, 0)
    c.Parent = waveFrame
end

-- Top line: map name (small)
local mapLabel = Instance.new("TextLabel")
mapLabel.Size = UDim2.new(1, -16, 0, 16)
mapLabel.Position = UDim2.new(0, 8, 0, 3)
mapLabel.BackgroundTransparency = 1
mapLabel.Text = ""
mapLabel.TextColor3 = Color3.fromRGB(180, 220, 240)
mapLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
mapLabel.TextStrokeTransparency = 0.5
mapLabel.Font = Enum.Font.Gotham
mapLabel.TextSize = 13
mapLabel.Parent = waveFrame

-- Bottom line: stage / wave (bigger)
local waveLabel = Instance.new("TextLabel")
waveLabel.Size = UDim2.new(1, -16, 0, 26)
waveLabel.Position = UDim2.new(0, 8, 0, 18)
waveLabel.BackgroundTransparency = 1
waveLabel.Text = ""
waveLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
waveLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
waveLabel.TextStrokeTransparency = 0.4
waveLabel.Font = Enum.Font.FredokaOne
waveLabel.TextSize = 22
waveLabel.Parent = waveFrame

-- Carrying-ammo indicator: shown below the wave HUD when the player is holding
-- an ammo package from a pile. Clears when they load it into a tower.
-- Sits inline to the RIGHT of the wave HUD so the whole top strip is horizontal.
local carryFrame = Instance.new("Frame")
carryFrame.Size = UDim2.new(0, 140, 0, 46)
carryFrame.Position = UDim2.new(0.5, 110, 0, 0)  -- right of wave frame, flush to top
carryFrame.BackgroundColor3 = Color3.fromRGB(255, 180, 60)
carryFrame.BackgroundTransparency = 0.15
carryFrame.BorderSizePixel = 0
carryFrame.Visible = false
carryFrame.Parent = waveGui
do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0.18, 0)
    c.Parent = carryFrame
end

local carryLabel = Instance.new("TextLabel")
carryLabel.Size = UDim2.fromScale(1, 1)
carryLabel.BackgroundTransparency = 1
carryLabel.Text = "AMMO"
carryLabel.TextColor3 = Color3.fromRGB(40, 20, 0)
carryLabel.Font = Enum.Font.FredokaOne
carryLabel.TextSize = 18
carryLabel.Parent = carryFrame

-- Ammo system retired — carry indicator hidden permanently. Left the
-- frame + label in the tree (just invisible) so re-enabling the ammo
-- system later is a one-line flip instead of rebuilding the GUI.
carryFrame.Visible = false

-- Wave state updates from server. Handles live waves, between-waves, and the
-- "wave starting in N seconds" countdown that fires after the first tower is placed.
-- currentWaveState is forward-declared up by fireReset so it can branch on mapId.
local countdownToken = 0  -- cancels any in-progress countdown if a new state arrives
-- gameLost is forward-declared up by fireReset so DevReset can clear it correctly

ReplicatedStorage:WaitForChild(Remotes.Names.WaveState).OnClientEvent:Connect(function(state)
    if gameLost then return end  -- HUD locked to DEFEATED, ignore further updates
    currentWaveState = state
    countdownToken = countdownToken + 1
    local myToken = countdownToken

    waveFrame.Visible = true

    -- Top line: just the map name (Crook of the Tree (Morning/Day/Dusk/Night))
    mapLabel.Text = state.map or ""

    if state.finalBossActive then
        waveLabel.Text = "FINAL BOSS"
    elseif state.inProgress then
        waveLabel.Text = string.format("Wave %d / %d", state.wave, state.totalWaves)
    elseif state.pendingCountdown and state.pendingCountdown > 0 then
        task.spawn(function()
            local remaining = state.pendingCountdown
            while remaining > 0 and countdownToken == myToken do
                waveLabel.Text = string.format("Wave %d in %d…",
                    state.wave + 1, remaining)
                task.wait(1)
                remaining = remaining - 1
            end
        end)
    else
        if state.wave >= state.totalWaves then
            waveLabel.Text = "All waves cleared!"
        elseif state.wave == 0 then
            waveFrame.Visible = false
        else
            waveLabel.Text = string.format("Wave %d cleared", state.wave)
        end
    end
end)

------------------------------------------------------------
-- Upgrade picker modal + its REROLL / USE TOKEN buttons.
-- See TreeOfLife_Client/UpgradePicker.lua.
------------------------------------------------------------
require(script:WaitForChild("UpgradePicker")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    IS_MOBILE          = IS_MOBILE,
    UserInputService   = UserInputService,
    player             = player,
})

-- Look up a tower def by id so card-rendering modules (temp-tower
-- picker, permanent modals, TowerCard) can reuse the same iconBuilder
-- the hotbar uses — keeps visual identity consistent and lets kids
-- match "the spotted red mushroom on the card" → "the same one on
-- the hotbar after I claim it."
local function findTowerDefById(towerId)
    for _, d in ipairs(towerDefs) do
        if d.id == towerId then return d end
    end
    return nil
end

------------------------------------------------------------
-- Temp-tower reward picker (map bosses) — extracted to sibling module.
-- See TreeOfLife_Client/TempTowerRewardPicker.lua.
------------------------------------------------------------
require(script:WaitForChild("TempTowerRewardPicker")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    IS_MOBILE          = IS_MOBILE,
    TweenService       = TweenService,
    UserInputService   = UserInputService,
    findTowerDefById   = findTowerDefById,
})

------------------------------------------------------------
-- Permanent-tower reward modal (Pickle Lord defeat) — extracted to
-- sibling ModuleScript. See TreeOfLife_Client/PermanentTowerRewardModal.lua.
------------------------------------------------------------
require(script:WaitForChild("PermanentTowerRewardModal")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    IS_MOBILE          = IS_MOBILE,
    findTowerDefById   = findTowerDefById,
})

------------------------------------------------------------
-- First-time intro modal — extracted to sibling ModuleScript.
-- See TreeOfLife_Client/IntroSplash.lua.
------------------------------------------------------------
require(script:WaitForChild("IntroSplash")).setup({
    playerGui         = playerGui,
    ReplicatedStorage = ReplicatedStorage,
    Remotes           = Remotes,
    IS_MOBILE         = IS_MOBILE,
})

------------------------------------------------------------
-- FIRST-DEATH FAIRY — extracted to a sibling ModuleScript to take its
-- ~200 lines of modal code out of the main chunk's register budget.
-- See TreeOfLife_Client/FirstDeathFairy.lua. The module handles BOTH
-- the picker modal (ShowFirstDeathFairy) and the other-players toast
-- (ShowResurrectionNotice).
------------------------------------------------------------
require(script:WaitForChild("FirstDeathFairy")).setup({
    playerGui         = playerGui,
    ReplicatedStorage = ReplicatedStorage,
    Remotes           = Remotes,
    IS_MOBILE         = IS_MOBILE,
    player            = player,
    -- Callback so the module can reach through and flip the main-chunk
    -- gameLost flag off when the fairy/notice fires (so the incoming
    -- resurrection WaveState isn't ignored by the game-over gate).
    unlockGameLost = function() gameLost = false end,
})

------------------------------------------------------------
-- Permanent-tower equip modal (pedestal) — extracted to sibling module.
-- See TreeOfLife_Client/PermanentTowerEquipModal.lua.
------------------------------------------------------------
require(script:WaitForChild("PermanentTowerEquipModal")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    IS_MOBILE          = IS_MOBILE,
    UserInputService   = UserInputService,
    findTowerDefById   = findTowerDefById,
})

------------------------------------------------------------
-- BOSS OVERLAYS — Canopy Bird "TAP!" dive markers + Web Weaver "WEBBED"
-- tower lockout bubbles. Extracted to sibling module. Spider web Parts
-- handle their own click detection server-side (no client UI needed).
------------------------------------------------------------
require(script:WaitForChild("BossOverlays")).setup({
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    CollectionService  = CollectionService,
    Tags               = Tags,
    RunService         = RunService,
})

------------------------------------------------------------
-- Game over modal — extracted to sibling ModuleScript.
-- See TreeOfLife_Client/GameOverBanner.lua.
------------------------------------------------------------
require(script:WaitForChild("GameOverBanner")).setup({
    playerGui         = playerGui,
    ReplicatedStorage = ReplicatedStorage,
    Remotes           = Remotes,
    markDefeated      = function()
        gameLost = true
        waveLabel.Text = "DEFEATED"
        waveFrame.Visible = true
    end,
    unlockGameLost    = function() gameLost = false end,
})

------------------------------------------------------------
-- Stage cleared banner (between stages 1→2 and 2→3)
-- Non-blocking: auto-dismisses, no Continue button. Server advances
-- the stage on its own timer (WaveConfig.stageContinueAutoDelay).
-- Shows reward text ("+1 Reroll Token") so the player knows what
-- they earned.
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.StageCleared).OnClientEvent:Connect(function(payload)
    local old = playerGui:FindFirstChild("ToL_StageCleared")
    if old then old:Destroy() end

    local stage = payload.stage or 1
    local rerollsAwarded = payload.rerollsAwarded or 0

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_StageCleared"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    -- Above wave HUD, below game-over. Doesn't block input.
    gui.DisplayOrder = 225
    gui.Parent = playerGui

    -- Banner panel: top-center strip, slides in from above, lingers,
    -- fades out. Semi-transparent dark plate so text reads over any
    -- background. Height sized to fit title + reward line.
    local panel = Instance.new("Frame")
    panel.Size = UDim2.new(0, IS_MOBILE and 340 or 480, 0, 96)
    panel.AnchorPoint = Vector2.new(0.5, 0)
    panel.Position = UDim2.new(0.5, 0, 0, -120)   -- offscreen top
    panel.BackgroundColor3 = Color3.fromRGB(20, 50, 80)
    panel.BackgroundTransparency = 0.15
    panel.BorderSizePixel = 0
    panel.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = panel
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 2
    stroke.Color = Color3.fromRGB(255, 240, 160)
    stroke.Transparency = 0.2
    stroke.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -16, 0, 44)
    title.Position = UDim2.new(0, 8, 0, 8)
    title.BackgroundTransparency = 1
    title.Text = string.format("Stage %d Complete!", stage)
    title.TextColor3 = Color3.fromRGB(255, 255, 200)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.3
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 28 or 34
    title.Parent = panel

    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, -16, 0, 30)
    sub.Position = UDim2.new(0, 8, 0, 56)
    sub.BackgroundTransparency = 1
    -- "Stage Rerolls Refreshed" belongs in this banner because server-side
    -- advanceStage() always resets RerollsUsed → the next stage's free
    -- reroll button is usable again. Mentioning it here keeps the reward
    -- summary in one place alongside the token + heart heal.
    if rerollsAwarded > 0 then
        sub.Text = string.format("+%d Reroll Token · Stage Rerolls Refreshed · The Tree Heals", rerollsAwarded)
    else
        sub.Text = "Stage Rerolls Refreshed · The Tree Heals"
    end
    sub.TextColor3 = Color3.fromRGB(220, 240, 220)
    sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    sub.TextStrokeTransparency = 0.4
    sub.Font = Enum.Font.Gotham
    sub.TextSize = IS_MOBILE and 16 or 18
    sub.Parent = panel

    -- Slide in (0.3s) → hold (2.0s) → fade out (0.6s). Total ~3s,
    -- well under the server's stage-advance delay so the banner
    -- clears before the next wave starts.
    local slideIn = TweenService:Create(panel, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Position = UDim2.new(0.5, 0, 0, 24),
    })
    slideIn:Play()
    task.delay(2.3, function()
        if not gui.Parent then return end
        local fadeOut = TweenService:Create(panel, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Position = UDim2.new(0.5, 0, 0, -120),
            BackgroundTransparency = 1,
        })
        fadeOut:Play()
        TweenService:Create(title, TweenInfo.new(0.6), {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
        TweenService:Create(sub,   TweenInfo.new(0.6), {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
        TweenService:Create(stroke, TweenInfo.new(0.6), {Transparency = 1}):Play()
        task.delay(0.7, function()
            if gui.Parent then gui:Destroy() end
        end)
    end)
end)

------------------------------------------------------------
-- Stage reskin: brief overlay flash announcing the new stage
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.StageReskin).OnClientEvent:Connect(function(payload)
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_StageReskin"
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 210
    gui.Parent = playerGui

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 80)
    label.Position = UDim2.new(0, 0, 0.4, 0)
    label.BackgroundTransparency = 1
    label.Text = "Stage " .. (payload.stage or "?")
    label.TextColor3 = Color3.fromRGB(255, 240, 180)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.3
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 60
    label.TextTransparency = 0
    label.Parent = gui

    -- Fade out over 2.5s, then destroy
    local TweenService = game:GetService("TweenService")
    local info = TweenInfo.new(2.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    TweenService:Create(label, info, {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
    task.delay(2.8, function() if gui.Parent then gui:Destroy() end end)
end)

------------------------------------------------------------
-- BOSS MINIGAME — final-boss tap-the-targets mechanic. Extracted to
-- sibling module. Handles BossWindup / BossPhase / BossPhaseMiss /
-- BossWeb. See TreeOfLife_Client/BossMinigame.lua.
------------------------------------------------------------
require(script:WaitForChild("BossMinigame")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    Rarity             = Rarity,
    TweenService       = TweenService,
    waveFrame          = waveFrame,
})

------------------------------------------------------------
-- TOWER TARGET-MODE HUD + SELECTION VISUALS
-- Click/tap a placed tower → HUD with stats + 3 target-mode buttons + close X.
-- Selected tower gets bracket markers and a blue range circle on the floor.
------------------------------------------------------------

local setTargetModeRemote = ReplicatedStorage:WaitForChild(Remotes.Names.SetTowerTargetMode)

local targetModeGui = Instance.new("ScreenGui")
targetModeGui.Name = "ToL_TargetModeHUD"
targetModeGui.IgnoreGuiInset = false
targetModeGui.ResetOnSpawn = false
targetModeGui.DisplayOrder = 60
targetModeGui.Enabled = false
targetModeGui.Parent = playerGui

-- Rarity palette aliases for legacy HUD call sites (tower HUD, tower
-- info popup). New code should use `Rarity.Colors` / `Rarity.Names`
-- directly — imported once at the top of this script.
local HUD_RARITY_COLORS = Rarity.Colors
local HUD_RARITY_NAMES  = Rarity.Names

-- Outer panel. Taller than before (310 vs 220) so all 4 target-mode buttons
-- fit in the right column without clipping. Small X in the corner replaces
-- the old full-width red CLOSE button.
local targetModeFrame = Instance.new("Frame")
targetModeFrame.Size = UDim2.new(0, 440, 0, 310)
-- Default to the right edge of the screen (AnchorPoint top-right, 12px
-- from the right border, 90px from top). Draggable, so players can pull
-- it center if they want — right-dock keeps the 3D world visible under
-- the most common camera orientations.
targetModeFrame.AnchorPoint = Vector2.new(1, 0)
targetModeFrame.Position = UDim2.new(1, -12, 0, 90)
targetModeFrame.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
targetModeFrame.BackgroundTransparency = 0.08
targetModeFrame.BorderSizePixel = 0
targetModeFrame.Parent = targetModeGui
do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0.06, 0)
    c.Parent = targetModeFrame
end

-- Title (left-leaning; X button lives in the right corner)
local hudTitle = Instance.new("TextLabel")
hudTitle.Size = UDim2.new(0, 210, 0, 30)  -- fixed width to leave room for info button
hudTitle.Position = UDim2.new(0, 16, 0, 8)
hudTitle.BackgroundTransparency = 1
hudTitle.RichText = true  -- aux tower titles color the name by rarity
hudTitle.Text = "TOWER"
hudTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
hudTitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
hudTitle.TextStrokeTransparency = 0.4
hudTitle.Font = Enum.Font.FredokaOne
hudTitle.TextSize = 20
hudTitle.TextXAlignment = Enum.TextXAlignment.Left
hudTitle.Parent = targetModeFrame

-- Info (i) button + tower card modal are declared together down near
-- currentTargetTower's scope (see "Tower card modal" do-block further
-- below). Keeps the info affordance + its handler bundled and, more
-- importantly, keeps this file's register usage in check — infoBtn
-- doesn't need to be a top-level local since nothing else references
-- it outside that one do-block.

-- Thin divider under the title
do
    local d = Instance.new("Frame")
    d.Size = UDim2.new(1, -32, 0, 1)
    d.Position = UDim2.new(0, 16, 0, 44)
    d.BackgroundColor3 = Color3.fromRGB(60, 70, 88)
    d.BackgroundTransparency = 0.4
    d.BorderSizePixel = 0
    d.Parent = targetModeFrame
end

-- Red CLOSE [Q] button — top-right of the panel, immediately left of the
-- info (i) button. The (i) is at AnchorPoint(1,0) Position(1,-14,0,10)
-- size 26×26 (TowerCard.lua), so its left edge sits at right-40. CLOSE
-- anchors top-right too, sized 80×26, with a 6px gap → its right edge at
-- right-46. Slim row of two square-ish glyphs reads as "controls" without
-- eating the panel's interior space.
local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Size = UDim2.new(0, 80, 0, 26)
closeBtn.Position = UDim2.new(1, -46, 0, 10)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 55, 55)
closeBtn.BorderSizePixel = 0
closeBtn.AutoButtonColor = false
closeBtn.RichText = true
closeBtn.Text = "CLOSE <font color='#ffdd55'>[Q]</font>"
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.TextStrokeColor3 = Color3.fromRGB(40, 0, 0)
closeBtn.TextStrokeTransparency = 0.3
closeBtn.Font = Enum.Font.FredokaOne
closeBtn.TextSize = 14
closeBtn.Parent = targetModeFrame
do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0.25, 0)
    c.Parent = closeBtn
end

-- TARGET + SELL buttons: slim horizontal pair tucked into the bottom-left
-- of the HUD. TARGET enters mob-pick mode (G hotkey same); SELL destroys
-- the tower for 1 reroll token and refunds +1 stock (X hotkey same).
-- Only bullseyeBtn escapes the block — corner is a build-time decorator
-- and doesn't need a module-level local (the client script is at the
-- Luau 200-register ceiling). Position y = 1, -52 puts the button's
-- bottom edge at the same y as the CLOSE button (CLOSE at y=244, h=42
-- → bottom=286; panel h=310 → 310-24-28 = 258, which is what y=-52
-- resolves to).
local bullseyeBtn
do
    bullseyeBtn = Instance.new("TextButton")
    bullseyeBtn.Size = UDim2.new(0, 104, 0, 28)
    bullseyeBtn.Position = UDim2.new(0, 12, 1, -52)
    bullseyeBtn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
    bullseyeBtn.BorderSizePixel = 0
    bullseyeBtn.AutoButtonColor = false
    bullseyeBtn.RichText = true
    bullseyeBtn.Text = "TARGET <font color='#ffdd55'>[G]</font>"
    bullseyeBtn.TextColor3 = Color3.fromRGB(255, 220, 120)
    bullseyeBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    bullseyeBtn.TextStrokeTransparency = 0.3
    bullseyeBtn.Font = Enum.Font.FredokaOne
    bullseyeBtn.TextSize = 15
    bullseyeBtn.Parent = targetModeFrame
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.3, 0)
    corner.Parent = bullseyeBtn
end

-- PICK UP button: destroys the tower and refunds +1 stock at the cost of
-- N reroll tokens (Core: 3, Aux: 1). The coin badge on the right shows
-- the cost dynamically — refreshHUD updates it via sellCostCoin.
-- Only sellBtn + sellCostCoin need to survive the block (sellBtn for
-- click-handler attachment, sellCostCoin for refreshHUD's text update);
-- the rest (corner, padding, stroke) are purely build-time decorators.
local sellBtn, sellCostCoin
do
    sellBtn = Instance.new("TextButton")
    sellBtn.Size = UDim2.new(0, 116, 0, 28)  -- tight to text + coin (was 140 with a big gap)
    sellBtn.Position = UDim2.new(0, 122, 1, -52)  -- flush-bottom with CLOSE (y=1,-52)
    sellBtn.BackgroundColor3 = Color3.fromRGB(120, 55, 55)
    sellBtn.BorderSizePixel = 0
    sellBtn.AutoButtonColor = false
    sellBtn.RichText = true
    sellBtn.Text = "PICK UP <font color='#ffdd55'>[X]</font>"
    sellBtn.TextColor3 = Color3.fromRGB(255, 220, 200)
    sellBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    sellBtn.TextStrokeTransparency = 0.3
    sellBtn.Font = Enum.Font.FredokaOne
    sellBtn.TextSize = 15
    sellBtn.TextXAlignment = Enum.TextXAlignment.Left
    sellBtn.Parent = targetModeFrame
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.3, 0)
    corner.Parent = sellBtn
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 10)
    pad.Parent = sellBtn

    -- Cost coin: yellow circle with the black reroll-token cost number
    -- (Core = 3, Aux = 1). Sits on the right edge of the button.
    sellCostCoin = Instance.new("TextLabel")
    sellCostCoin.AnchorPoint = Vector2.new(1, 0.5)
    sellCostCoin.Size = UDim2.new(0, 20, 0, 20)
    sellCostCoin.Position = UDim2.new(1, -6, 0.5, 0)
    sellCostCoin.BackgroundColor3 = Color3.fromRGB(240, 200, 60)
    sellCostCoin.BorderSizePixel = 0
    sellCostCoin.Text = "1"
    sellCostCoin.TextColor3 = Color3.fromRGB(0, 0, 0)
    sellCostCoin.Font = Enum.Font.FredokaOne
    sellCostCoin.TextSize = 14
    sellCostCoin.Parent = sellBtn
    local coinCorner = Instance.new("UICorner")
    coinCorner.CornerRadius = UDim.new(0.5, 0)
    coinCorner.Parent = sellCostCoin
    local coinStroke = Instance.new("UIStroke")
    coinStroke.Color = Color3.fromRGB(160, 120, 20)
    coinStroke.Thickness = 1.5
    coinStroke.Parent = sellCostCoin
end

-- Drag support: click + hold anywhere on the panel body (except on one of
-- the interactive child buttons) and the whole tower HUD moves with the
-- cursor. Lets the player reposition the panel if it covers towers or
-- mobs they want to see. A 30px-tall "title bar" region at the top of
-- the frame is the primary grab zone so accidental clicks on stats text
-- don't start drags. The mode buttons / close X have their own Input-
-- Began handlers that consume the event before it reaches us here.
do
    local DRAG_BAR_HEIGHT = 30
    local dragging = false
    local dragStart
    local startPos
    targetModeFrame.Active = true  -- InputBegan only fires on Active GuiObjects
    targetModeFrame.InputBegan:Connect(function(input)
        local isPointerDown =
            input.UserInputType == Enum.UserInputType.MouseButton1 or
            input.UserInputType == Enum.UserInputType.Touch
        if not isPointerDown then return end
        -- Only accept drags that start in the top title-bar region so
        -- button clicks deeper in the panel aren't misread as drag starts.
        local framePos = targetModeFrame.AbsolutePosition
        if input.Position.Y - framePos.Y > DRAG_BAR_HEIGHT then return end
        dragging = true
        dragStart = input.Position
        startPos = targetModeFrame.Position
        local changedConn, endedConn
        changedConn = UserInputService.InputChanged:Connect(function(moveInput)
            if not dragging then return end
            if moveInput.UserInputType ~= Enum.UserInputType.MouseMovement
               and moveInput.UserInputType ~= Enum.UserInputType.Touch then return end
            local delta = moveInput.Position - dragStart
            targetModeFrame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end)
        endedConn = UserInputService.InputEnded:Connect(function(endInput)
            if endInput.UserInputType ~= Enum.UserInputType.MouseButton1
               and endInput.UserInputType ~= Enum.UserInputType.Touch then return end
            dragging = false
            if changedConn then changedConn:Disconnect() end
            if endedConn then endedConn:Disconnect() end
        end)
    end)
end

-- Stats area (left column). Variable-height list: always shows Damage, Range,
-- Shots/sec, Ammo; optionally shows Attach, AOE, Stun, Knockback when present.
local statsFrame = Instance.new("Frame")
statsFrame.Size = UDim2.new(0, 240, 1, -66)
statsFrame.Position = UDim2.new(0, 16, 0, 56)
statsFrame.BackgroundTransparency = 1
statsFrame.Parent = targetModeFrame

do
    local l = Instance.new("UIListLayout")
    l.FillDirection = Enum.FillDirection.Vertical
    l.HorizontalAlignment = Enum.HorizontalAlignment.Left
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Padding = UDim.new(0, 4)
    l.Parent = statsFrame
end

local function makeStatLabel(orderIdx)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 20)
    lbl.BackgroundTransparency = 1
    lbl.Text = ""
    lbl.TextColor3 = Color3.fromRGB(220, 230, 240)
    lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    lbl.TextStrokeTransparency = 0.5
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 15
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.LayoutOrder = orderIdx
    lbl.RichText = true  -- so we can embed <font color> tags for bonuses + rarity
    lbl.Parent = statsFrame
    return lbl
end

-- All HUD stat labels bundled into one table — saves ~8 module-level
-- register slots vs. individual locals (client script is at the Luau
-- 200-register ceiling). Field order matches display order.
local hudLabels = {
    damage    = makeStatLabel(1),
    dps       = makeStatLabel(2),
    range     = makeStatLabel(3),
    fireRate  = makeStatLabel(4),
    ammo      = makeStatLabel(5),
    attach    = makeStatLabel(6),
    aoe       = makeStatLabel(7),
    stun      = makeStatLabel(8),
    knockback = makeStatLabel(9),
}

-- Mode buttons column on the right. Five buttons × 38px + 4 × 8px padding = 222px.
-- Panel is 310 tall; title+divider+padding uses ~66px; bottom padding 16px leaves
-- enough room for the 222 column. The poetic ordering of buttons (First, Last,
-- Center, Strongest, Weakest) puts Center literally at the middle.
local modeRow = Instance.new("Frame")
modeRow.Size = UDim2.new(0, 160, 0, 222)
modeRow.Position = UDim2.new(1, -176, 0, 56)
modeRow.BackgroundTransparency = 1
modeRow.Parent = targetModeFrame
do
    local l = Instance.new("UIListLayout")
    l.FillDirection = Enum.FillDirection.Vertical
    l.HorizontalAlignment = Enum.HorizontalAlignment.Center
    l.VerticalAlignment = Enum.VerticalAlignment.Top
    l.Padding = UDim.new(0, 8)
    l.Parent = modeRow
end

local currentTargetTower = nil  -- the tower currently being configured

-- Order is poetic: First and Last bracket the path; Center sits literally
-- at the middle; Strongest/Weakest are the HP-based pair below.
local MODES = {"First", "Last", "Center", "Strongest", "Weakest"}
local MODE_LABELS = {
    First     = "FIRST",
    Last      = "LAST",
    Center    = "CENTER",
    Strongest = "STRONGEST",
    Weakest   = "WEAKEST",
}
local modeButtons = {}
for _, mode in ipairs(MODES) do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 38)
    btn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Text = MODE_LABELS[mode]
    btn.TextColor3 = Color3.fromRGB(230, 230, 230)
    btn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    btn.TextStrokeTransparency = 0.5
    btn.Font = Enum.Font.FredokaOne
    btn.TextSize = 16
    btn.Parent = modeRow
    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(0.2, 0)
    bc.Parent = btn
    modeButtons[mode] = btn

    btn.MouseButton1Click:Connect(function()
        if not currentTargetTower or not currentTargetTower.Parent then return end
        setTargetModeRemote:FireServer(currentTargetTower, mode)
    end)
end

-- Visual selection: corner brackets + blue range circle, both sit on the floor
-- around the selected tower. Built lazily so they only exist while selecting.
local selectionFolder = nil
local function clearSelectionVisuals()
    if selectionFolder then
        selectionFolder:Destroy()
        selectionFolder = nil
    end
end

local function buildSelectionVisuals(tower)
    clearSelectionVisuals()
    if not tower or not tower.Parent then return end

    selectionFolder = Instance.new("Folder")
    selectionFolder.Name = "ToL_TowerSelection"
    selectionFolder.Parent = workspace

    -- Compute a WORLD-AXIS bounding box by scanning descendants. We can't
    -- rely on Model:GetBoundingBox — when the Model has no PrimaryPart it
    -- falls back to the first child's orientation, which for the Power
    -- Tower means the TowerBase cylinder's rotated CFrame. That made the
    -- cage hang sideways ("oriented incorrectly"). Manual min/max over
    -- every Part's eight world corners gives a proper axis-aligned cage
    -- around Core and Aux alike.
    local minX, minY, minZ =  math.huge,  math.huge,  math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for _, desc in ipairs(tower:GetDescendants()) do
        if desc:IsA("BasePart") then
            local cf, sz = desc.CFrame, desc.Size
            for dx = -1, 1, 2 do
                for dy = -1, 1, 2 do
                    for dz = -1, 1, 2 do
                        local corner = cf:PointToWorldSpace(Vector3.new(
                            sz.X * 0.5 * dx,
                            sz.Y * 0.5 * dy,
                            sz.Z * 0.5 * dz))
                        if corner.X < minX then minX = corner.X end
                        if corner.Y < minY then minY = corner.Y end
                        if corner.Z < minZ then minZ = corner.Z end
                        if corner.X > maxX then maxX = corner.X end
                        if corner.Y > maxY then maxY = corner.Y end
                        if corner.Z > maxZ then maxZ = corner.Z end
                    end
                end
            end
        end
    end
    if minX == math.huge then return end  -- no parts found

    -- Override minY to the tower's stamped FloorY — the Y coord of the
    -- map floor the tower was placed on. The descendant sweep above
    -- includes attachment VFX / invisible anchors / particle containers
    -- that may hang below the visible base after ScaleTo + re-seat,
    -- dragging the cage's floor brackets (and the range ring) below the
    -- actual floor. FloorY is set at placement time to centerPos.Y, so
    -- it always points at the map's floor for this tower regardless of
    -- what extraneous bits ended up in the Model tree.
    local floorAttr = tower:GetAttribute("FloorY")
    if type(floorAttr) == "number" then
        minY = floorAttr
    end

    -- Inflate X/Z a hair so brackets don't z-fight the model's surface.
    -- Y gets a SMALL upward nudge from the tower bottom instead of padding
    -- down — the tower's minY is typically the floor, so extending below
    -- would bury the bottom brackets.
    local PAD = 0.15
    local centerX = (minX + maxX) / 2
    local centerZ = (minZ + maxZ) / 2
    local halfX   = (maxX - minX) / 2 + PAD
    local halfZ   = (maxZ - minZ) / 2 + PAD
    local floorY  = minY + PAD
    local topY    = maxY + PAD

    -- 8 corner brackets forming a 3D cage around the tower. Each corner
    -- has three short bars along ±X, ±Y, ±Z — same scheme as a 3D editor
    -- bounds widget. Bar axes are controlled by dx/dy/dz signs per corner.
    -- Bracket size scaled 50% to match the tower's visual downscale —
    -- old 1.5-stud bars read as huge next to a half-scale Power Tower.
    local bracketLen = 0.75
    local bracketThickness = 0.12
    local bracketColor = Color3.fromRGB(120, 255, 150)

    local function makeBar(x1, y1, z1, x2, y2, z2)
        local lenX = math.abs(x2 - x1)
        local lenY = math.abs(y2 - y1)
        local lenZ = math.abs(z2 - z1)
        local p = Instance.new("Part")
        p.Anchored = true
        p.CanCollide = false
        p.CastShadow = false
        p.CanQuery = false  -- don't block the bullseye mob-pick raycast
        p.Material = Enum.Material.Neon
        p.Color = bracketColor
        p.Transparency = 0.1
        p.Size = Vector3.new(
            math.max(lenX, bracketThickness),
            math.max(lenY, bracketThickness),
            math.max(lenZ, bracketThickness))
        p.CFrame = CFrame.new((x1 + x2) / 2, (y1 + y2) / 2, (z1 + z2) / 2)
        p.Parent = selectionFolder
    end

    -- 8 corners: (sign of X, sign of Y picking floor vs top, sign of Z)
    -- For each corner, dx/dy/dz point INWARD so each bar extends from the
    -- corner toward the cage interior.
    local corners = {
        {centerX - halfX, floorY, centerZ - halfZ,  1,  1,  1},  -- bottom NW
        {centerX + halfX, floorY, centerZ - halfZ, -1,  1,  1},  -- bottom NE
        {centerX - halfX, floorY, centerZ + halfZ,  1,  1, -1},  -- bottom SW
        {centerX + halfX, floorY, centerZ + halfZ, -1,  1, -1},  -- bottom SE
        {centerX - halfX, topY,   centerZ - halfZ,  1, -1,  1},  -- top NW
        {centerX + halfX, topY,   centerZ - halfZ, -1, -1,  1},  -- top NE
        {centerX - halfX, topY,   centerZ + halfZ,  1, -1, -1},  -- top SW
        {centerX + halfX, topY,   centerZ + halfZ, -1, -1, -1},  -- top SE
    }
    for _, c in ipairs(corners) do
        local cx, cy, cz, dx, dy, dz = c[1], c[2], c[3], c[4], c[5], c[6]
        makeBar(cx, cy, cz, cx + dx * bracketLen, cy, cz)                -- X arm
        makeBar(cx, cy, cz, cx, cy + dy * bracketLen, cz)                -- Y arm
        makeBar(cx, cy, cz, cx, cy, cz + dz * bracketLen)                -- Z arm
    end

    -- Range circle on the floor (a thin neon ring approximated by many segments).
    -- Cheaper alternative: a single big disc with a ring texture, but custom
    -- segments are simpler and don't need an asset. Ring Y sits 0.35 above
    -- floorY so it clears path tiles (same offset as the placement ghost).
    local range = tower:GetAttribute("Range") or 30
    local SEGMENTS = 48
    local segLen = (2 * math.pi * range) / SEGMENTS
    local ringY = floorY + 0.35
    for i = 0, SEGMENTS - 1 do
        local a = (i / SEGMENTS) * 2 * math.pi
        local x = centerX + math.cos(a) * range
        local z = centerZ + math.sin(a) * range
        local seg = Instance.new("Part")
        seg.Size = Vector3.new(segLen + 0.1, 0.12, 0.35)
        seg.CFrame = CFrame.new(x, ringY, z) * CFrame.Angles(0, -a + math.pi / 2, 0)
        seg.Anchored = true
        seg.CanCollide = false
        seg.CanQuery = false  -- don't block the bullseye mob-pick raycast
        seg.CastShadow = false
        seg.Material = Enum.Material.Neon
        seg.Color = Color3.fromRGB(80, 160, 255)
        seg.Transparency = 0.25
        seg.Parent = selectionFolder
    end
end

local function refreshHUD()
    if not currentTargetTower or not currentTargetTower.Parent then return end
    local tower = currentTargetTower
    local typ = tower:GetAttribute("TowerType") or "Power"
    -- Aux towers: use their displayName + color by their rolled rarity.
    -- Core (Power) stays white — no rarity roll on the starter tower.
    local tpl = TempTowers.Templates and TempTowers.Templates[typ]
    if tpl then
        local rarity = tower:GetAttribute("Rarity")
        local color = rarity and TempTowers.RarityColors and TempTowers.RarityColors[rarity]
        local displayName = (tpl.displayName or typ):upper()
        if color then
            local hex = string.format("#%02x%02x%02x",
                math.floor(color.R * 255 + 0.5),
                math.floor(color.G * 255 + 0.5),
                math.floor(color.B * 255 + 0.5))
            hudTitle.Text = string.format("<font color='%s'>%s</font>", hex, displayName)
        else
            hudTitle.Text = displayName
        end
    else
        hudTitle.Text = typ:upper() .. " TOWER"
    end

    local damage    = tower:GetAttribute("Damage") or 0
    local range     = tower:GetAttribute("Range") or 0
    local fireRate  = tower:GetAttribute("FireRate") or 0
    -- Damage bonus is flat additive (DamageFlat); Range/FireRate still %.
    -- The damage display computes flat = damage - damageBase below, which
    -- is equivalent to DamageFlat now that live Damage = Base + Flat.
    local rangeBonus    = tower:GetAttribute("RangeBonusPct") or 0
    local fireRateBonus = tower:GetAttribute("FireRateBonusPct") or 0
    local shots     = tower:GetAttribute("Shots") or 0
    local maxShots  = tower:GetAttribute("MaxShots") or 0
    local equipType = tower:GetAttribute("EquippedType") or ""
    local equipRar  = tower:GetAttribute("EquippedRarity")  -- int 1..5 or nil
    local aoe       = tower:GetAttribute("AoeRadius")       -- nil if single-target
    local stunDur   = tower:GetAttribute("StunDuration")    -- nil if no Stun special picked
    local knockDist = tower:GetAttribute("Knockback")       -- nil if no Knockback special picked

    -- Format "Stat: value [+N%]" — the bonus tag is green + bold + smaller so
    -- the eye lands on the big live number first, then the bonus as context.
    local BONUS_GREEN = "#82e06c"
    local function statLine(label, value, bonus)
        local base = string.format("%s: %s", label, value)
        if bonus and bonus > 0 then
            return string.format('%s  <font color="%s"><b>[+%d%%]</b></font>', base, BONUS_GREEN, math.floor(bonus + 0.5))
        end
        return base
    end

    -- Damage is presented as a FLAT bonus rather than a percentage. Keeps
    -- the two axes readable at a glance: "Damage: 24 [+6]" means +6 flat
    -- hit, "Shots/sec: 1.60 [+15%]" still speaks in %. Flat bonus =
    -- Damage - DamageBase (Damage is baseline × (1 + bonus%/100), stored
    -- live on the tower).
    local damageBase  = tower:GetAttribute("DamageBase") or damage
    local damageFlat  = math.floor(damage - damageBase + 0.5)
    local function damageLine(label, value, flatBonus)
        local base = string.format("%s: %s", label, value)
        if flatBonus and flatBonus > 0 then
            return string.format('%s  <font color="%s"><b>[+%d]</b></font>', base, BONUS_GREEN, flatBonus)
        end
        return base
    end

    hudLabels.damage.Text = damageLine("Damage", tostring(math.floor(damage + 0.5)), damageFlat)
    -- DPS: LIFETIME actual = TotalDamageDone / (now - PlacementTime). Server
    -- stamps PlacementTime at placement and bumps TotalDamageDone on every
    -- hit (systems/Damage.lua). Before the tower has fired a shot we show
    -- "— " instead of 0.0 so the dev-targeting observer knows it's empty,
    -- not a broken calc.
    do
        local totalDmg = tower:GetAttribute("TotalDamageDone") or 0
        local placedAt = tower:GetAttribute("PlacementTime")
        if placedAt and totalDmg > 0 then
            local elapsed = math.max(0.1, workspace:GetServerTimeNow() - placedAt)
            hudLabels.dps.Text = string.format("DPS: %.1f", totalDmg / elapsed)
        else
            hudLabels.dps.Text = "DPS: —"
        end
    end
    hudLabels.range.Text    = statLine("Range",     tostring(math.floor(range + 0.5)),   rangeBonus)
    hudLabels.fireRate.Text = statLine("Shots/sec", string.format("%.2f", fireRate),     fireRateBonus)
    -- Ammo row hidden on the HUD — the tower's 3D billboard is the primary
    -- indicator; Ammo Capacity lives in the info popup. isAuxTower still
    -- gates the Attach row (Core-only) and the pick-up cost coin.
    local isAuxTower = tower:GetAttribute("NoAmmo")
    hudLabels.ammo.Visible = false
    sellCostCoin.Text = tostring(isAuxTower and 1 or 3)

    -- Attachment row: hidden on aux + when no attachment equipped.
    if not isAuxTower and equipType ~= "" and equipRar and HUD_RARITY_NAMES[equipRar] then
        local color = HUD_RARITY_COLORS[equipRar]
        local hex = string.format("#%02x%02x%02x",
            math.floor(color.R * 255 + 0.5),
            math.floor(color.G * 255 + 0.5),
            math.floor(color.B * 255 + 0.5))
        hudLabels.attach.Visible = true
        hudLabels.attach.Text = string.format(
            'Attach: <b>%s</b> <font color="%s">(%s)</font>',
            equipType, hex, HUD_RARITY_NAMES[equipRar])
    else
        hudLabels.attach.Visible = false
        hudLabels.attach.Text = ""
    end

    -- Conditional rows: show only when the effect is active. Stun +
    -- Knockback chances come off the per-tower attribute (stacked via
    -- upgrade picks; see SPECIAL_EFFECTS in UpgradeCards.lua).
    local function toggleLine(lbl, show, text)
        lbl.Visible = show
        lbl.Text = show and text or ""
    end
    toggleLine(hudLabels.aoe, aoe and aoe > 0,
        string.format("AOE: %d", math.floor((aoe or 0) + 0.5)))
    local stunPct = math.floor((tower:GetAttribute("StunChance") or 0.05) * 100 + 0.5)
    toggleLine(hudLabels.stun, stunDur and stunDur > 0,
        string.format("Stun: %.1fs (%d%%)", stunDur or 0, stunPct))
    local kbPct = math.floor((tower:GetAttribute("KnockbackChance") or 0.05) * 100 + 0.5)
    toggleLine(hudLabels.knockback, knockDist and knockDist > 0,
        string.format("Knockback: +%d (%d%%)", math.floor((knockDist or 0) + 0.5), kbPct))

    -- Highlight the active mode
    local current = tower:GetAttribute("TargetMode") or "First"
    for mode, btn in pairs(modeButtons) do
        if mode == current then
            btn.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
            btn.TextColor3 = Color3.fromRGB(20, 30, 50)
        else
            btn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
            btn.TextColor3 = Color3.fromRGB(230, 230, 230)
        end
    end
end

-- Track all attribute changes that affect the HUD so it stays live (e.g. when
-- an upgrade applies and damage/range/fireRate jumps).
local attrConns = {}
local function disconnectAttrs()
    for _, c in ipairs(attrConns) do c:Disconnect() end
    attrConns = {}
end

local function openForTower(tower)
    disconnectAttrs()
    currentTargetTower = tower
    refreshHUD()
    buildSelectionVisuals(tower)
    targetModeGui.Enabled = true
    if tower then
        local liveAttrs = {
            "TargetMode", "Damage", "Range", "FireRate", "AoeRadius",
            "Shots", "MaxShots",                                   -- ammo row
            "DamageFlat", "RangeBonusPct", "FireRateBonusPct",     -- bonus tags
            "EquippedType", "EquippedRarity",                      -- attachment row
            "StunDuration", "StunChance",                          -- stun row
            "Knockback", "KnockbackChance",                        -- knockback row
            "TotalDamageDone",                                     -- DPS: live per-hit bump
        }
        for _, attr in ipairs(liveAttrs) do
            table.insert(attrConns, tower:GetAttributeChangedSignal(attr):Connect(function()
                refreshHUD()
                if attr == "Range" then
                    buildSelectionVisuals(tower)  -- redraw the range circle
                end
            end))
        end
    end
end

local function closeTargetModeHUD()
    disconnectAttrs()
    clearSelectionVisuals()
    -- Keep currentTargetTower set even after close so G can re-enter
    -- target mode for the last-selected tower without needing to click
    -- the tower first.
    targetModeGui.Enabled = false
end

closeBtn.MouseButton1Click:Connect(closeTargetModeHUD)

-- Shared bullseye/tower-picker state. Declared at module scope (not
-- inside the do-block) so the tower-picker do-block below can read
-- awaitingMobPick + mobPickConsumedAt to decide whether a click was
-- already consumed by the mob-pick handler.
--   awaitingMobPick: true while the bullseye cursor is live, so the
--     next MB1 click on a mob assigns it as the currentTargetTower's
--     manual target. Flips the button color.
--   mobPickConsumedAt: last-consumed click timestamp; suppresses the
--     tower-select handler for the same click (same InputBegan frame).
--   manualTargetIndicators: mob → BillboardGui map (one per tower;
--     new pick clears the prior indicator; auto-cleans on destroy).
local awaitingMobPick = false
local mobPickConsumedAt = 0
local manualTargetIndicators = {}

-- Scoped `do` block: the bullseye + manual-target-indicator code below
-- adds ~10 top-level locals and helper closures. Wrapping in a block
-- releases those locals from the chunk's register pressure (Luau caps
-- per-function register count at 200 and this file has been bumping up
-- against that). Only exposes what other sections need via upvalues.
do

local function clearManualTargetIndicator(mob)
    local gui = manualTargetIndicators[mob]
    if gui then
        if gui.Parent then gui:Destroy() end
        manualTargetIndicators[mob] = nil
    end
end

local function attachManualTargetIndicator(mob)
    if not mob or not mob.Parent then return end
    if manualTargetIndicators[mob] then return end
    local bb = Instance.new("BillboardGui")
    bb.Name = "ManualTargetIndicator"
    bb.Size = UDim2.new(0, 48, 0, 48)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
    bb.AlwaysOnTop = true
    bb.LightInfluence = 0
    bb.MaxDistance = 500
    bb.Adornee = mob
    bb.Parent = mob
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "◎"
    label.TextColor3 = Color3.fromRGB(255, 220, 120)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.3
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 36
    label.Parent = bb
    manualTargetIndicators[mob] = bb
    -- Auto-clean when the mob disappears.
    mob.AncestryChanged:Connect(function(_, parent)
        if not parent then clearManualTargetIndicator(mob) end
    end)
end

local function clearAllManualTargetIndicators()
    for mob in pairs(manualTargetIndicators) do
        clearManualTargetIndicator(mob)
    end
end
-- Custom bullseye cursor shown while target mode is active. We can't
-- rely on MouseIcon without uploading an asset, so we hide the OS
-- cursor with UserInputService.MouseIconEnabled = false and render a
-- follower ScreenGui label at the live mouse position via RenderStepped.
local bullseyeCursorGui, bullseyeCursorConn
local function hideBullseyeCursor()
    if bullseyeCursorConn then
        bullseyeCursorConn:Disconnect()
        bullseyeCursorConn = nil
    end
    if bullseyeCursorGui and bullseyeCursorGui.Parent then
        bullseyeCursorGui:Destroy()
    end
    bullseyeCursorGui = nil
    UserInputService.MouseIconEnabled = true
end
local function showBullseyeCursor()
    if bullseyeCursorGui then return end
    bullseyeCursorGui = Instance.new("ScreenGui")
    bullseyeCursorGui.Name = "ToL_BullseyeCursor"
    bullseyeCursorGui.IgnoreGuiInset = false  -- viewport coords, matches GetMouseLocation
    bullseyeCursorGui.ResetOnSpawn = false
    bullseyeCursorGui.DisplayOrder = 500
    bullseyeCursorGui.Parent = playerGui
    local label = Instance.new("TextLabel")
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.Size = UDim2.new(0, 48, 0, 48)
    label.BackgroundTransparency = 1
    label.Text = "◎"
    label.TextColor3 = Color3.fromRGB(255, 220, 120)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.2
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 44
    label.Parent = bullseyeCursorGui
    UserInputService.MouseIconEnabled = false
    local RunService = game:GetService("RunService")
    bullseyeCursorConn = RunService.RenderStepped:Connect(function()
        local m = UserInputService:GetMouseLocation()
        label.Position = UDim2.new(0, m.X, 0, m.Y)
    end)
end

local function setMobPickMode(v)
    awaitingMobPick = v
    if v then
        bullseyeBtn.BackgroundColor3 = Color3.fromRGB(200, 140, 50)
        bullseyeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        showBullseyeCursor()
    else
        bullseyeBtn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
        bullseyeBtn.TextColor3 = Color3.fromRGB(255, 220, 120)
        hideBullseyeCursor()
    end
end
-- Wrapped in a do-block so the inner named local (`trySellSelectedTower`)
-- doesn't claim a top-level register. The client script is at the Luau
-- 200-register-per-function ceiling — any new main-chunk local pushes over
-- and the script fails to load. do-block scopes this one out.
do
    bullseyeBtn.MouseButton1Click:Connect(function()
        setMobPickMode(not awaitingMobPick)
    end)

    -- Sell action: fires SellTower remote with the currently-selected
    -- tower. Cost (1 reroll token) + ownership check happen server-side.
    -- Client closes the HUD, selection box, and info modal immediately
    -- so the UI doesn't linger referencing a tower that's about to
    -- vanish — waiting for AncestryChanged replication round-trip would
    -- leave a stale panel for 100-200ms.
    local function trySellSelectedTower()
        if not currentTargetTower or not currentTargetTower.Parent then return end
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.SellTower)
        if r then r:FireServer({ tower = currentTargetTower }) end
        closeTargetModeHUD()  -- hides HUD + clears selection ring/range
        local card = playerGui:FindFirstChild("ToL_TowerCard")
        if card then card:Destroy() end
    end
    sellBtn.MouseButton1Click:Connect(trySellSelectedTower)

    -- G = TARGET toggle, X = PICK UP, Q = close HUD. G/X gated on having
    -- a selected tower (they act on it); Q gated on the HUD being up
    -- (it's just a close). Keyboard-only flow mirrors the button panel.
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        local kc = input.KeyCode
        if kc == Enum.KeyCode.Q and targetModeGui.Enabled then
            closeTargetModeHUD()
            return
        end
        if not currentTargetTower or not currentTargetTower.Parent then return end
        if kc == Enum.KeyCode.G then
            setMobPickMode(not awaitingMobPick)
        elseif kc == Enum.KeyCode.X then
            trySellSelectedTower()
        end
    end)
end

-- Raycast helper: return the mob BasePart under a screen position, or
-- nil. Used to resolve the manual-target click. InputObject.Position is
-- in SCREEN space (includes the Roblox top-bar inset) but
-- ViewportPointToRay expects VIEWPORT coords. Subtract the GuiInset to
-- convert — otherwise the ray fires ~36px lower than the cursor, which
-- is why manual-target picks were resolving to the wrong mob.
local GuiService = game:GetService("GuiService")
local function mobUnderScreenPos(screenX, screenY)
    -- Screen-space proximity picker: project every live mob to the
    -- viewport, pick the one whose projected center is closest to the
    -- click pixel. Raycast-based picking was unreliable because:
    --   (a) a nearer mob on the same ray wins even if the user visually
    --       aimed at a further mob;
    --   (b) spider legs (welded child Parts) sit between the camera and
    --       the body, so rays through the leg returned the leg-owner
    --       but could also miss entirely when the leg is thin;
    --   (c) the ray might pierce empty space between mobs and hit a
    --       floor tile, returning nothing.
    -- The proximity approach matches the "click on what I see" intuition.
    local cam = workspace.CurrentCamera
    -- We still fire a raycast so the debug overlay has a world hit point,
    -- but selection uses the proximity result.
    local ray = cam:ViewportPointToRay(screenX, screenY, 1)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = {player.Character, targetModeGui}
    local rayHit = workspace:Raycast(ray.Origin, ray.Direction * 500, rp)
    local debugHitPos = rayHit and rayHit.Position or nil

    -- Tolerance: max screen-space pixel distance to accept a mob click.
    -- Generous enough for iPad thumbs on a crowded spider cluster, tight
    -- enough that an empty-space click still misses.
    local MAX_SCREEN_DIST = 120
    local bestMob, bestDistSq = nil, MAX_SCREEN_DIST * MAX_SCREEN_DIST
    for _, mob in ipairs(CollectionService:GetTagged(Tags.Mob)) do
        if mob:IsA("BasePart") and mob.Parent then
            local sp = cam:WorldToViewportPoint(mob.Position)
            if sp.Z > 0 then
                local dx = sp.X - screenX
                local dy = sp.Y - screenY
                local d2 = dx * dx + dy * dy
                if d2 < bestDistSq then
                    bestDistSq = d2
                    bestMob = mob
                end
            end
        end
    end
    if bestMob then
        return bestMob, debugHitPos or bestMob.Position
    end
    return nil, debugHitPos
end

-- InputBegan hook for the mob-pick click. Runs BEFORE the existing
-- tower-click handler so selecting a target doesn't accidentally reopen
-- the tower HUD on a mob that happened to be behind one.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if not awaitingMobPick then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
       and input.UserInputType ~= Enum.UserInputType.Touch then return end
    if not currentTargetTower or not currentTargetTower.Parent then
        setMobPickMode(false)
        return
    end
    -- Use GetMouseLocation() as the source of truth for click position.
    -- The custom bullseye cursor is drawn at this location every frame,
    -- so the player is aiming AT exactly this point. Earlier we used
    -- input.Position but empirically it fires at a slightly different
    -- viewport Y than GetMouseLocation — the ring / pulse / cursor
    -- stopped agreeing. Switching to one source makes everything align.
    local m = UserInputService:GetMouseLocation()
    local screenX, screenY = m.X, m.Y
    local mob = mobUnderScreenPos(screenX, screenY)
    if mob then
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.SetTowerManualTarget)
        if r then
            r:FireServer({ tower = currentTargetTower, mob = mob })
        end
        -- Clear any prior indicator and attach one to the freshly-picked
        -- mob. Server will fall through to the tower's TargetMode if the
        -- mob leaves range (see Targeting.lua) but the indicator stays
        -- on the mob until it dies or the player picks another.
        clearAllManualTargetIndicators()
        attachManualTargetIndicator(mob)
        setMobPickMode(false)
        mobPickConsumedAt = os.clock()
    else
        -- Missed — stay in mob-pick mode so the player gets another
        -- try. Clicking the bullseye again cancels. Timestamp set so
        -- the tower-select handler doesn't reopen the HUD this frame.
        mobPickConsumedAt = os.clock()
    end
end)

end  -- close the outer bullseye do-block so its ~15 locals release before
     -- the tower-picker section below declares its own. Luau caps at 200
     -- registers per function; splitting the block keeps both halves under.

-- Raycast helper: given a screen position, return any tower model under it
-- (ownership is irrelevant for inspecting; UI just shows stats).
-- Two passes:
--   1. A tight raycast through the cursor — catches dead-on clicks on any
--      tower descendant Part.
--   2. If the ray hits nothing or hits a non-tower (water, path tile,
--      mob), fall back to finding the nearest tower whose tagged base
--      projects within NEAR_CLICK_PX pixels of the cursor. Makes aux
--      towers with small/glow-heavy silhouettes (Spore Puffball,
--      Mushroom Mortar) still register a click even if the ray skims
--      the edge.
do  -- open a fresh do-block for the tower-picker so its locals don't
    -- compound with the bullseye block above.
local function towerUnderScreenPos(screenX, screenY)
    -- InputObject.Position is ALREADY in viewport coords; pass it
    -- directly to ViewportPointToRay / WorldToViewportPoint. The
    -- inset subtraction tried here earlier was backwards.
    local viewX, viewY = screenX, screenY
    local ray = camera:ViewportPointToRay(viewX, viewY, 1)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = {player.Character, targetModeGui}
    local hit = workspace:Raycast(ray.Origin, ray.Direction * 300, rp)
    if hit then
        local model = hit.Instance:FindFirstAncestorOfClass("Model")
        while model do
            if model:GetAttribute("TowerType") then
                return model
            end
            model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
        end
    end

    -- Fallback: walk every tower's bounding box and check whether the
    -- cursor falls INSIDE the box's screen-space projection (plus a
    -- small padding). Replaces the earlier "distance to center" circle
    -- check — a tall Power Tower has its bounding-box center mid-height,
    -- but the top of the model is far from center in screen space at
    -- a top-down angle, so clicks on the gem were missing. Projecting
    -- the top + bottom corners and taking the cursor-inside-rect test
    -- handles short mushroom towers AND tall Power equally well.
    local PAD_PX = 24
    local bestModel, bestRectDist = nil, math.huge
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        if base:IsA("BasePart") then
            local model = base:FindFirstAncestorOfClass("Model")
            while model and not model:GetAttribute("TowerType") do
                model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
            end
            if model and model:IsA("Model") then
                local ok, cf, sz = pcall(function()
                    return model:GetBoundingBox()
                end)
                if ok and cf and sz then
                    -- Project the 8 world-corner points of the bounding box
                    -- to screen space and take the min/max rect.
                    local minSX, minSY, maxSX, maxSY = math.huge, math.huge, -math.huge, -math.huge
                    local anyOnScreen = false
                    for dx = -1, 1, 2 do
                        for dy = -1, 1, 2 do
                            for dz = -1, 1, 2 do
                                local world = cf:PointToWorldSpace(Vector3.new(
                                    sz.X * 0.5 * dx, sz.Y * 0.5 * dy, sz.Z * 0.5 * dz))
                                local sp, onScreen = camera:WorldToViewportPoint(world)
                                if sp.Z > 0 then
                                    if sp.X < minSX then minSX = sp.X end
                                    if sp.Y < minSY then minSY = sp.Y end
                                    if sp.X > maxSX then maxSX = sp.X end
                                    if sp.Y > maxSY then maxSY = sp.Y end
                                    anyOnScreen = anyOnScreen or onScreen
                                end
                            end
                        end
                    end
                    if anyOnScreen then
                        -- Compare in VIEWPORT coords (both the projected box
                        -- and the input's viewport-corrected X/Y). Inflate
                        -- the rect by PAD_PX so near-misses still register.
                        local dx = math.max(minSX - PAD_PX - viewX, 0, viewX - (maxSX + PAD_PX))
                        local dy = math.max(minSY - PAD_PX - viewY, 0, viewY - (maxSY + PAD_PX))
                        local d = math.sqrt(dx * dx + dy * dy)
                        if d < bestRectDist then
                            bestRectDist = d
                            bestModel = model
                        end
                    end
                end
            end
        end
    end
    -- Only accept if the cursor was within the padded rectangle.
    if bestRectDist > 0 then bestModel = nil end
    return bestModel
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
       and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    if placementMode then return end
    -- If the bullseye mob-pick handler is live OR just consumed this click,
    -- don't let this tower-select handler also close the HUD / reopen on
    -- something else. Both handlers run on the same InputBegan — the timestamp
    -- guard covers the case where mob-pick already ran + cleared its flag.
    if awaitingMobPick then return end
    if os.clock() - mobPickConsumedAt < 0.1 then return end

    local pos = input.Position
    local tower = towerUnderScreenPos(pos.X, pos.Y)
    if tower then
        openForTower(tower)
    else
        if targetModeGui.Enabled then
            closeTargetModeHUD()
        end
    end
end)
end  -- end of scoped tower-picker block (second half of the bullseye/picker split)

------------------------------------------------------------
-- Info (i) button + per-tower detail modal — extracted to sibling
-- ModuleScript. See TreeOfLife_Client/TowerCard.lua.
-- getCurrentTower is a closure over the module-scope currentTargetTower
-- so the module stays decoupled from that live upvalue.
------------------------------------------------------------
require(script:WaitForChild("TowerCard")).setup({
    playerGui        = playerGui,
    TempTowers       = TempTowers,
    findTowerDefById = findTowerDefById,
    targetModeFrame  = targetModeFrame,
    getCurrentTower  = function() return currentTargetTower end,
})

------------------------------------------------------------
-- HOLD-E PICKUP DETECTION (replaces the prior ProximityPrompt-driven loop)
--
-- The piles' ProximityPrompts are kept on the server as visual hints, but
-- their hold semantics turned out to be unreliable — PromptButtonHoldEnded
-- could fire spuriously while the player was still holding E, killing
-- the rapid pickup loop. So we drive the loop ourselves: watch E key
-- down/up via UserInputService, fire PickupHoldStart when E goes down
-- AND there's an AmmoPile within 12 studs of the player, fire
-- PickupHoldStop on E release. Server runs the rapid pickup loop between
-- those events.
------------------------------------------------------------
local pickupStartRemote = ReplicatedStorage:WaitForChild(Remotes.Names.PickupHoldStart)
local pickupStopRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.PickupHoldStop)
local pickupLoopActive  = false

local function nearestAmmoPileWithin(maxDist)
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local nearest, nearestDist = nil, maxDist
    for _, glow in ipairs(CollectionService:GetTagged(Tags.AmmoPile)) do
        if glow:IsA("BasePart") then
            local d = (hrp.Position - glow.Position).Magnitude
            if d <= nearestDist then
                nearest = glow
                nearestDist = d
            end
        end
    end
    return nearest
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if input.KeyCode ~= Enum.KeyCode.E then return end
    -- Check nearest pile FIRST. If there's one in range, the player is
    -- clearly trying to pick up — fire the remote even though the pile's
    -- own ProximityPrompt (KeyboardKeyCode = E) has already consumed the
    -- press and set gameProcessed=true. Without a pile nearby, respect
    -- gameProcessed so chat/UI typing doesn't trigger pickup.
    if not nearestAmmoPileWithin(12) then return end
    if pickupLoopActive then return end
    pickupLoopActive = true
    pickupStartRemote:FireServer()
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode ~= Enum.KeyCode.E then return end
    if not pickupLoopActive then return end
    pickupLoopActive = false
    pickupStopRemote:FireServer()
end)

------------------------------------------------------------
-- REROLL TOKEN HUD (bottom-right, above Phoenix HUD): always-visible pill
-- that shows the player's persistent RerollTokens balance. Polls the
-- player attribute (server-set) via GetAttributeChangedSignal so it
-- updates instantly when tokens are earned (stage clear) or spent
-- (upgrade picker "USE TOKEN" button).
------------------------------------------------------------
do
    local hudGui = Instance.new("ScreenGui")
    hudGui.Name = "ToL_RerollTokenHUD"
    hudGui.IgnoreGuiInset = true
    hudGui.ResetOnSpawn = false
    hudGui.DisplayOrder = 230
    hudGui.Parent = playerGui

    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(1, 1)
    -- 62 = Phoenix HUD is 38 tall + 16 bottom margin + 8 gap above it.
    frame.Position = UDim2.new(1, -16, 1, -62)
    frame.Size = UDim2.new(0, 0, 0, 34)
    frame.AutomaticSize = Enum.AutomaticSize.X
    frame.BackgroundTransparency = 1  -- text-only, no pill background
    frame.BorderSizePixel = 0
    frame.Parent = hudGui

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0, 0, 1, 0)
    label.AutomaticSize = Enum.AutomaticSize.X
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 16
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.4
    label.TextColor3 = Color3.fromRGB(255, 210, 130)
    label.Parent = frame

    local function refresh()
        local count = player:GetAttribute("RerollTokens") or 0
        label.Text = string.format("REROLL TOKENS: %d", count)
    end
    refresh()
    player:GetAttributeChangedSignal("RerollTokens"):Connect(refresh)
end

------------------------------------------------------------
-- PHOENIX HUD (bottom-right): visible only while at least one OWNED tower
-- has EquippedType == "Phoenix". Three states (priority order):
--   1. GraceRemaining > 0   → red    "Phoenix Active: 3.2s"
--   2. PhoenixReady == true → green  "Phoenix: ACTIVE"
--   3. otherwise            → yellow "Phoenix: 11:42"  (M:SS countdown)
--
-- Update tick: 5Hz. The grace countdown shows one decimal; cooldown shows
-- whole minutes:seconds. Server writes attributes at compatible precision
-- (cooldown = integer seconds, grace = 0.1s tenths) so polling is cheap.
------------------------------------------------------------
do
    local hudGui = Instance.new("ScreenGui")
    hudGui.Name = "ToL_PhoenixHUD"
    hudGui.IgnoreGuiInset = true
    hudGui.ResetOnSpawn = false
    hudGui.DisplayOrder = 230
    hudGui.Parent = playerGui

    local frame = Instance.new("Frame")
    frame.Name = "Frame"
    frame.AnchorPoint = Vector2.new(1, 1)
    frame.Position = UDim2.new(1, -16, 1, -16)
    frame.Size = UDim2.new(0, 0, 0, 38)
    -- AutomaticSize hugs the text width so the pill is exactly as wide as
    -- the label needs, regardless of state ("READY" vs "Phoenix Active: 4.5s"
    -- vs "Phoenix: 10:00"). Anchor is bottom-right, so the pill grows to
    -- the LEFT as text gets longer — bottom-right corner stays pinned.
    frame.AutomaticSize = Enum.AutomaticSize.X
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0
    frame.Visible = false
    frame.Parent = hudGui
    local fc = Instance.new("UICorner")
    fc.CornerRadius = UDim.new(0.2, 0)
    fc.Parent = frame
    local fs = Instance.new("UIStroke")
    fs.Thickness = 1
    fs.Color = Color3.fromRGB(120, 120, 120)
    fs.Transparency = 0.4
    fs.Parent = frame
    -- Symmetric padding so the text isn't kissing either edge.
    local fp = Instance.new("UIPadding")
    fp.PaddingLeft = UDim.new(0, 14)
    fp.PaddingRight = UDim.new(0, 14)
    fp.Parent = frame

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    -- Width auto-sizes to text. Height fills the frame (minus padding).
    label.Size = UDim2.new(0, 0, 1, 0)
    label.AutomaticSize = Enum.AutomaticSize.X
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 18
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.4
    label.Text = "Phoenix: ACTIVE"
    label.TextColor3 = Color3.fromRGB(120, 255, 140)
    label.Parent = frame

    local function findOwnedPhoenixTower()
        local uid = player.UserId
        -- Prefer the tower that's CURRENTLY cooling down / in grace — that's
        -- the one the player just activated. Fall back to any Phoenix tower
        -- if none are cooling. Without this preference, a player with a map-1
        -- Phoenix tower AND a freshly-placed map-2 Phoenix tower (both
        -- present across the same CollectionService registry) would see the
        -- HUD lock to whichever came first in the iteration, which wasn't
        -- always the one that tryConsumePhoenix picked as the "active" one.
        local activeTower, anyTower
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local t = towerBase.Parent
            if t and t:GetAttribute("Owner") == uid
                   and t:GetAttribute("EquippedType") == "Phoenix" then
                local grace = t:GetAttribute("PhoenixGraceRemaining") or 0
                local ready = t:GetAttribute("PhoenixReady") == true
                if grace > 0 or not ready then
                    activeTower = t
                    break
                end
                anyTower = anyTower or t
            end
        end
        return activeTower or anyTower
    end

    local function fmtCd(seconds)
        seconds = math.max(0, math.ceil(seconds))
        local m = math.floor(seconds / 60)
        local s = seconds % 60
        return string.format("%d:%02d", m, s)
    end

    task.spawn(function()
        while hudGui.Parent do
            -- Show whenever the PLAYER has Phoenix equipped — not gated on
            -- a tower existing yet. This way the HUD appears the moment they
            -- enter the map (when the tower-choice UI shows), and stays
            -- visible even before they've placed their first tower.
            local equippedType = player:GetAttribute("EquippedAttachmentType") or ""
            if equippedType ~= "Phoenix" then
                frame.Visible = false
            else
                -- If a tower with Phoenix is placed, read live cooldown/grace
                -- from it. Otherwise show "READY" (no tower = no cooldown).
                local t = findOwnedPhoenixTower()
                if not t then
                    label.Text = "Phoenix: NEEDS TOWER"
                    label.TextColor3 = Color3.fromRGB(255, 200, 110)  -- amber — signals "action required"
                else
                    local grace = t:GetAttribute("PhoenixGraceRemaining") or 0
                    local ready = t:GetAttribute("PhoenixReady") == true
                    local cdRem = t:GetAttribute("PhoenixCdRemaining") or 0
                    if grace > 0 then
                        label.Text = string.format("Phoenix Active: %.1fs", grace)
                        label.TextColor3 = Color3.fromRGB(255, 110, 110)
                    elseif ready then
                        label.Text = "Phoenix: ACTIVE"
                        label.TextColor3 = Color3.fromRGB(120, 255, 140)
                    else
                        label.Text = "Phoenix: " .. fmtCd(cdRem)
                        label.TextColor3 = Color3.fromRGB(255, 220, 110)
                    end
                end
                frame.Visible = true
            end
            task.wait(0.1)
        end
    end)
end

------------------------------------------------------------
-- BOSS-DEFEAT CUTSCENE (map 1 → map 2)
-- Server fires PlayBossCutscene after the temp-tower picker closes. The
-- cutscene: the character runs over to their Core tower, walks slowly
-- the last ~1s, kneels, pretends to work for a beat, then the tower
-- server-side disappears and Map2 drops the rope ladder.
-- All motion is Humanoid-driven (MoveTo + WalkSpeed) so pathfinding and
-- animation transitions come for free. Player input stays blocked for
-- the ~5-second duration via Humanoid:SetStateEnabled false for walking.
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.PlayBossCutscene).OnClientEvent:Connect(function(payload)
    local target = payload and payload.corePosition
    if not target then return end
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
    if not (hrp and hum) then return end

    -- Stop a couple of studs back from the tower's footprint.
    local dir = hrp.Position - target
    if dir.Magnitude < 0.01 then dir = Vector3.new(0, 0, 4) end
    local approachPos = Vector3.new(
        target.X + dir.Unit.X * 4,
        hrp.Position.Y,
        target.Z + dir.Unit.Z * 4)

    -- Run to the tower, wait for arrival (not a fixed timer — the path
    -- length varies by where the player died relative to where they
    -- placed their Core), then a 0.5s pause, then signal the server to
    -- destroy the tower + drop the ladder. MoveToFinished's `reached`
    -- arg handles both cases (arrived / 8s internal timeout) identically
    -- — either way, we stop and pause at whatever spot we ended up at.
    local origJump = hum.JumpPower
    hum.JumpPower = 0
    hum.WalkSpeed = 22
    hum:MoveTo(approachPos)
    hum.MoveToFinished:Wait()
    hum.WalkSpeed = 0
    hrp.CFrame = CFrame.new(hrp.Position,
        Vector3.new(target.X, hrp.Position.Y, target.Z))
    task.wait(0.5)
    hum.WalkSpeed = 16
    hum.JumpPower = origJump
    local doneRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.BossCutsceneDone)
    if doneRemote then doneRemote:FireServer() end
end)

------------------------------------------------------------
-- NARRATIVE MESSAGE (falling-leaf flavor text)
-- Server fires LeafMessage with { text, duration, static? }.
-- By default the text drifts downward with a gentle leaf-like sway and
-- rotation — "feather effect." Set payload.static = true to suppress the
-- motion (used for moments where the message announces a visual beat that
-- already implies falling, so the text doesn't compete with it — e.g.
-- "a ladder drops from the canopy" where the ladder itself is falling).
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.LeafMessage).OnClientEvent:Connect(function(payload)
    local text = payload and payload.text or ""
    local duration = payload and payload.duration or 6
    local staticMode = payload and payload.static == true
    if text == "" then return end

    -- Stack messages: if one is already up, just push it lower. Cheapest is
    -- to give each its own ScreenGui so they don't collide on cleanup.
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_LeafMsg"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 220
    gui.Parent = playerGui

    local startY = staticMode and 0.15 or 0.05
    local endY   = staticMode and 0.15 or 0.40

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.8, 0, 0, 60)
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = UDim2.new(0.5, 0, startY, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 26
    label.TextColor3 = Color3.fromRGB(240, 250, 220)
    label.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
    label.TextStrokeTransparency = 0.2
    label.Text = text
    label.TextWrapped = true
    label.Parent = gui

    -- Heartbeat loop: drifts downward with sway+tilt (unless static), and
    -- fades out over the last 30% of the duration.
    local startedAt = os.clock()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        local elapsed = os.clock() - startedAt
        local t = math.clamp(elapsed / duration, 0, 1)
        if not staticMode then
            local y = startY + (endY - startY) * t
            local sway = math.sin(elapsed * 1.8) * 0.04
            label.Position = UDim2.new(0.5 + sway, 0, y, 0)
            label.Rotation = math.sin(elapsed * 1.2) * 6
        end
        if t > 0.7 then
            local fadeT = (t - 0.7) / 0.3
            label.TextTransparency = fadeT
            label.TextStrokeTransparency = 0.2 + fadeT * 0.8
        end
        if elapsed >= duration + 0.2 then
            if conn then conn:Disconnect() end
            if gui.Parent then gui:Destroy() end
        end
    end)
end)

print("[TreeOfLife] Client v5.9.54 ready.")
