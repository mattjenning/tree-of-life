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

-- Shared modules — single source of truth for Remote/Tag names.
local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local Tags        = require(Shared:WaitForChild("Tags"))
local TowerTypes  = require(Shared:WaitForChild("TowerTypes"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))
local Rarity      = require(Shared:WaitForChild("Rarity"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))
local BBoxUtil    = require(Shared:WaitForChild("BBoxUtil"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- IS_MOBILE: declared near the top of the file so closures defined
-- below this line capture the LOCAL (not a nil global) at definition
-- time. Lua resolves free variables at function-DEFINITION time, not
-- call time — see CLAUDE.md. Was previously declared at line ~949,
-- which meant `shouldKeepPlacing()` and the deps table passed into
-- `TowerSelect.setup({IS_MOBILE = IS_MOBILE, ...})` both saw the
-- pre-line-949 GLOBAL `IS_MOBILE` (nil). Mobile UI was silently broken.
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

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
local CELL_SIZE = gridConfig:WaitForChild("CellSize").Value

-- Per-map grid + world-space metadata, keyed by mapId. Bundled into one
-- table to free ~25 module-scope register slots — init.client.lua sits
-- near the Luau 200-register ceiling. Adding map 4 is a one-row append.
local mapCfg = {
    [1] = {
        centerX   = gridConfig:WaitForChild("RoomCenterX").Value,
        centerZ   = gridConfig:WaitForChild("RoomCenterZ").Value,
        width     = gridConfig:WaitForChild("RoomWidth").Value,
        depth     = gridConfig:WaitForChild("RoomDepth").Value,
        floorY    = gridConfig:WaitForChild("FloorY").Value,
        cols      = gridConfig:WaitForChild("GridCols").Value,
        rows      = gridConfig:WaitForChild("GridRows").Value,
        colOffset = 0,
        totalCols = gridConfig:WaitForChild("GridCols").Value,  -- map 1 ends at mapCfg[1].cols
    },
    [2] = {
        centerX   = gridConfig:WaitForChild("Map2CenterX").Value,
        centerZ   = gridConfig:WaitForChild("Map2CenterZ").Value,
        width     = gridConfig:WaitForChild("Map2Width").Value,
        depth     = gridConfig:WaitForChild("Map2Depth").Value,
        floorY    = gridConfig:WaitForChild("Map2FloorY").Value,
        cols      = gridConfig:WaitForChild("Map2Cols").Value,
        rows      = gridConfig:WaitForChild("Map2Rows").Value,
        colOffset = gridConfig:WaitForChild("Map2ColOffset").Value,
        totalCols = gridConfig:WaitForChild("Map2TotalCols").Value,
    },
    [3] = {
        centerX   = gridConfig:WaitForChild("Map3CenterX").Value,
        centerZ   = gridConfig:WaitForChild("Map3CenterZ").Value,
        width     = gridConfig:WaitForChild("Map3Width").Value,
        depth     = gridConfig:WaitForChild("Map3Depth").Value,
        floorY    = gridConfig:WaitForChild("Map3FloorY").Value,
        cols      = gridConfig:WaitForChild("Map3Cols").Value,
        rows      = gridConfig:WaitForChild("Map3Rows").Value,
        colOffset = gridConfig:WaitForChild("Map3ColOffset").Value,
        totalCols = gridConfig:WaitForChild("Map3TotalCols").Value,
    },
    [4] = {
        centerX   = gridConfig:WaitForChild("Map4CenterX").Value,
        centerZ   = gridConfig:WaitForChild("Map4CenterZ").Value,
        width     = gridConfig:WaitForChild("Map4Width").Value,
        depth     = gridConfig:WaitForChild("Map4Depth").Value,
        floorY    = gridConfig:WaitForChild("Map4FloorY").Value,
        cols      = gridConfig:WaitForChild("Map4Cols").Value,
        rows      = gridConfig:WaitForChild("Map4Rows").Value,
        colOffset = gridConfig:WaitForChild("Map4ColOffset").Value,
        totalCols = gridConfig:WaitForChild("Map4TotalCols").Value,
    },
}
-- Derive XZ minima (commonly used as the cellToWorld origin).
for _, c in pairs(mapCfg) do
    c.minX = c.centerX - c.width / 2
    c.minZ = c.centerZ - c.depth / 2
end


-- Grid row-count covers all four maps. Each map's legal rows stop at
-- its own *_ROWS - 1; cells past that for those cols stay "open" but
-- never get placed on (server canPlaceAt enforces bounds).
local MAX_GRID_ROWS = math.max(
    mapCfg[1].rows, mapCfg[2].rows, mapCfg[3].rows, mapCfg[4].rows)

-- Per-col helpers to figure out which map a cell belongs to and what
-- the legal bounds are on that map. Map 4 (Pickle Swamp / Infinite
-- Arena) lives at colOffset=225+; map 3 is 135-224; map 2 is 60-134;
-- map 1 is 0-59.
local function colIsMap4(c) return c >= mapCfg[4].colOffset end
local function colIsMap3(c) return c >= mapCfg[3].colOffset and c < mapCfg[4].colOffset end
local function colIsMap2(c) return c >= mapCfg[2].colOffset and c < mapCfg[3].colOffset end
local function colRowMax(c)
    if colIsMap4(c) then return mapCfg[4].rows - 1 end
    if colIsMap3(c) then return mapCfg[3].rows - 1 end
    if colIsMap2(c) then return mapCfg[2].rows - 1 end
    return mapCfg[1].rows - 1
end
local function colMaxCol(c)
    if colIsMap4(c) then return mapCfg[4].totalCols - 1 end
    if colIsMap3(c) then return mapCfg[3].totalCols - 1 end
    if colIsMap2(c) then return mapCfg[2].totalCols - 1 end
    return mapCfg[1].cols - 1
end
local function colMinCol(c)
    if colIsMap4(c) then return mapCfg[4].colOffset end
    if colIsMap3(c) then return mapCfg[3].colOffset end
    if colIsMap2(c) then return mapCfg[2].colOffset end
    return 0
end

local localGrid = {}
for c = 0, mapCfg[4].totalCols - 1 do
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
-- Splash modal — DISABLED per Matthew (in-progress map work, the modal
-- blocks the play surface). Re-enable by un-commenting.
-- See TreeOfLife_Client/Splash.lua.
------------------------------------------------------------
-- require(script:WaitForChild("Splash")).setup({
--     playerGui          = playerGui,
--     ReplicatedStorage  = ReplicatedStorage,
--     Remotes            = Remotes,
--     TweenService       = TweenService,
-- })

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
    -- Core variants (Matthew 2026-04-27): selectable in the
    -- Infinite loadout picker. Each run grants ONE of the three
    -- Cores (grantLoadout sets <id>Stock + <id>Equipped). The
    -- hotbar's per-def visibility filter (Equipped attribute)
    -- naturally hides the two non-selected Cores.
    --
    -- All three Cores share hotkey "1" because they're alternatives
    -- — only one is Equipped per run, so the hotbar lookup at
    -- key-press time finds whichever is active.
    {id = "ControlCore", name = "CONTROL", desc = "Stacking DOT — single-target boss killer",
     color = Color3.fromRGB(140, 70, 200), accent = Color3.fromRGB(180, 100, 230),
     iconBuilder = TowerIcons.ControlCore, enabled = true, hotkey = "1",
     hotkeyCode = Enum.KeyCode.One, footprint = {4, 4}},
    {id = "SupportCore", name = "SUPPORT", desc = "Aura buffs nearby towers",
     color = Color3.fromRGB(60, 130, 200), accent = Color3.fromRGB(80, 180, 240),
     iconBuilder = TowerIcons.SupportCore, enabled = true, hotkey = "1",
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
    -- 2026-04-28: 5 new aux towers per Matthew. Hotkeys not bound
    -- (out of digits in the row) — picker UI handles selection on
    -- iPad anyway. Footprint comes from TempTowers.Templates via
    -- the sync loop below.
    {id = "BlinkBerry", name = "BLINK", desc = "Teleports nearby mobs back",
     color = Color3.fromRGB(120, 70, 180), accent = Color3.fromRGB(220, 160, 255),
     iconBuilder = TowerIcons.BlinkBerry, enabled = true, tempReward = true, hotkey = nil,
     footprint = {4, 4}},
    {id = "PaceFlower", name = "PACE", desc = "Aura: nearby towers fire faster",
     color = Color3.fromRGB(220, 180, 60), accent = Color3.fromRGB(255, 230, 140),
     iconBuilder = TowerIcons.PaceFlower, enabled = true, tempReward = true, hotkey = nil,
     footprint = {4, 4}},
    {id = "PowerSeed", name = "SEED", desc = "Aura: nearby towers do more damage",
     color = Color3.fromRGB(220, 80, 60), accent = Color3.fromRGB(255, 160, 100),
     iconBuilder = TowerIcons.PowerSeed, enabled = true, tempReward = true, hotkey = nil,
     footprint = {4, 4}},
    {id = "SpyglassRoot", name = "SPYGLASS", desc = "Aura: nearby towers see further",
     color = Color3.fromRGB(140, 90, 50), accent = Color3.fromRGB(120, 220, 240),
     iconBuilder = TowerIcons.SpyglassRoot, enabled = true, tempReward = true, hotkey = nil,
     footprint = {4, 4}},
    {id = "BloodlinkVine", name = "BLOODLINK", desc = "Aura: damage echoes between linked mobs",
     color = Color3.fromRGB(180, 40, 60), accent = Color3.fromRGB(255, 120, 130),
     iconBuilder = TowerIcons.BloodlinkVine, enabled = true, tempReward = true, hotkey = nil,
     footprint = {4, 4}},
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

local function findMap3Floor()
    local room = workspace:FindFirstChild("TreeOfLifeMap3Room")
    if not room then return nil end
    return room:FindFirstChild("Map3Floor")
end

local function findMap2Floor()
    local room = workspace:FindFirstChild("TreeOfLifeMap2Room")
    if not room then return nil end
    return room:FindFirstChild("Map2Floor")
end

local function findMap4Floor()
    local room = workspace:FindFirstChild("TreeOfLifeMap4Room")
    if not room then return nil end
    return room:FindFirstChild("Map4Floor")
end

-- Collect every floor the placement ghost should be allowed to hit. Order
-- doesn't matter — we discriminate by comparing result.Instance afterwards.
local function allPlacementFloors()
    local floors = {}
    local f1 = findFloor()
    if f1 then table.insert(floors, f1) end
    local f2 = findMap2Floor()
    if f2 then table.insert(floors, f2) end
    local f3 = findMap3Floor()
    if f3 then table.insert(floors, f3) end
    local f4 = findMap4Floor()
    if f4 then table.insert(floors, f4) end
    return floors
end

-- Convert a floor raycast hit to a (col, row) in shared-grid coordinates.
-- Dispatches by which floor part was hit so the same world-Z can mean
-- different rows across maps (each map has its own Z origin).
local function hitToCell(hitInstance, hitX, hitZ)
    local f1 = findFloor()
    if hitInstance == f1 then
        local col = math.floor((hitX - mapCfg[1].minX) / CELL_SIZE)
        local row = math.floor((hitZ - mapCfg[1].minZ) / CELL_SIZE)
        if col < 0 or col >= mapCfg[1].cols or row < 0 or row >= mapCfg[1].rows then
            return nil
        end
        return col, row
    end
    local f2 = findMap2Floor()
    if hitInstance == f2 then
        local localCol = math.floor((hitX - mapCfg[2].minX) / CELL_SIZE)
        local row = math.floor((hitZ - mapCfg[2].minZ) / CELL_SIZE)
        if localCol < 0 or localCol >= mapCfg[2].cols or row < 0 or row >= mapCfg[2].rows then
            return nil
        end
        return mapCfg[2].colOffset + localCol, row
    end
    local f3 = findMap3Floor()
    if hitInstance == f3 then
        local localCol = math.floor((hitX - mapCfg[3].minX) / CELL_SIZE)
        local row = math.floor((hitZ - mapCfg[3].minZ) / CELL_SIZE)
        if localCol < 0 or localCol >= mapCfg[3].cols or row < 0 or row >= mapCfg[3].rows then
            return nil
        end
        return mapCfg[3].colOffset + localCol, row
    end
    local f4 = findMap4Floor()
    if hitInstance == f4 then
        local localCol = math.floor((hitX - mapCfg[4].minX) / CELL_SIZE)
        local row = math.floor((hitZ - mapCfg[4].minZ) / CELL_SIZE)
        if localCol < 0 or localCol >= mapCfg[4].cols or row < 0 or row >= mapCfg[4].rows then
            return nil
        end
        return mapCfg[4].colOffset + localCol, row
    end
    return nil
end

-- Compute the world-space center of a shared-grid cell, dispatching by col
-- onto map 1/2/3/4's origin. Y is the floor top on that map.
local function cellCenterWorld(col, row)
    if colIsMap4(col) then
        local localCol = col - mapCfg[4].colOffset
        local worldX = mapCfg[4].minX + (localCol + 0.5) * CELL_SIZE
        local worldZ = mapCfg[4].minZ + (row + 0.5) * CELL_SIZE
        return worldX, worldZ, mapCfg[4].floorY
    end
    if colIsMap3(col) then
        local localCol = col - mapCfg[3].colOffset
        local worldX = mapCfg[3].minX + (localCol + 0.5) * CELL_SIZE
        local worldZ = mapCfg[3].minZ + (row + 0.5) * CELL_SIZE
        return worldX, worldZ, mapCfg[3].floorY
    end
    if colIsMap2(col) then
        local localCol = col - mapCfg[2].colOffset
        local worldX = mapCfg[2].minX + (localCol + 0.5) * CELL_SIZE
        local worldZ = mapCfg[2].minZ + (row + 0.5) * CELL_SIZE
        return worldX, worldZ, mapCfg[2].floorY
    end
    local worldX = mapCfg[1].minX + (col + 0.5) * CELL_SIZE
    local worldZ = mapCfg[1].minZ + (row + 0.5) * CELL_SIZE
    return worldX, worldZ, mapCfg[1].floorY
end

local function buildGridParts()
    if gridFolder then return end
    -- Build when AT LEAST one floor is loaded so the hub's progressive
    -- map 2 setup doesn't block map 1's grid render. Cells for the missing
    -- map will just sit at their expected world positions; once that floor
    -- loads they appear aligned with it.
    if not findFloor() and not findMap2Floor() and not findMap3Floor() then return end

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
    for c = 0, mapCfg[1].cols - 1 do
        for r = 0, mapCfg[1].rows - 1 do
            makeCell(c, r)
        end
    end
    -- Map 2 cells
    for c = mapCfg[2].colOffset, mapCfg[2].totalCols - 1 do
        for r = 0, mapCfg[2].rows - 1 do
            makeCell(c, r)
        end
    end
    -- Map 3 cells
    for c = mapCfg[3].colOffset, mapCfg[3].totalCols - 1 do
        for r = 0, mapCfg[3].rows - 1 do
            makeCell(c, r)
        end
    end
    -- Map 4 cells (Pickle Swamp / Infinite Arena). Without these the
    -- player can't see placement preview / occupancy state when in
    -- the Infinite arena.
    for c = mapCfg[4].colOffset, mapCfg[4].totalCols - 1 do
        for r = 0, mapCfg[4].rows - 1 do
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
        elseif s == "path" or s == "heart" then
            cell.Transparency = 1
        elseif s == "occupied" then
            cell.Transparency = 0.75
            cell.Color = Color3.fromRGB(200, 80, 60)
        end
    end
    for c = 0, mapCfg[1].cols - 1 do
        for r = 0, mapCfg[1].rows - 1 do paintCell(c, r) end
    end
    for c = mapCfg[2].colOffset, mapCfg[2].totalCols - 1 do
        for r = 0, mapCfg[2].rows - 1 do paintCell(c, r) end
    end
    for c = mapCfg[3].colOffset, mapCfg[3].totalCols - 1 do
        for r = 0, mapCfg[3].rows - 1 do paintCell(c, r) end
    end
    for c = mapCfg[4].colOffset, mapCfg[4].totalCols - 1 do
        for r = 0, mapCfg[4].rows - 1 do paintCell(c, r) end
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
    frame.Size = UDim2.fromOffset(280, 30)
    frame.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
    frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0
    frame.Parent = multiPlaceHintGui
    local fc = Instance.new("UICorner")
    fc.CornerRadius = UDim.new(0.3, 0)
    fc.Parent = frame
    multiPlaceHintLabel = Instance.new("TextLabel")
    multiPlaceHintLabel.Size = UDim2.fromScale(1, 1)
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
    -- grid's full extent (cols 0..mapCfg[4].totalCols-1, rows 0..MAX_GRID_ROWS-1).
    local idx = 1
    for r = 0, MAX_GRID_ROWS - 1 do
        for c = 0, mapCfg[4].totalCols - 1 do
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
    -- button, desktop tells the player to press Q (or Esc) to exit
    -- placement mode.
    local hintText
    if IS_MOBILE then
        hintText = "Tap Cancel to exit"
    else
        hintText = "[Q] to cancel"
    end
    local tipBb = Instance.new("BillboardGui")
    tipBb.Name = "GhostCancelHint"
    tipBb.Size = UDim2.fromOffset(140, 34)
    tipBb.StudsOffset = Vector3.new(0, topY / 2, 0)
    tipBb.AlwaysOnTop = true
    tipBb.LightInfluence = 0
    tipBb.Parent = ghostFootprint
    local tipLabel = Instance.new("TextLabel")
    tipLabel.Size = UDim2.fromScale(1, 1)
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
        for _ = 0, SEGMENTS - 1 do
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
    local isMap3 = colIsMap3(anchor[1])
    local isMap2 = colIsMap2(anchor[1])
    local worldX, worldZ, floorY
    if isMap3 then
        local localCenterCol = centerCol - mapCfg[3].colOffset
        worldX = mapCfg[3].minX + (localCenterCol + 0.5) * CELL_SIZE
        worldZ = mapCfg[3].minZ + (centerRow + 0.5) * CELL_SIZE
        floorY = mapCfg[3].floorY
    elseif isMap2 then
        local localCenterCol = centerCol - mapCfg[2].colOffset
        worldX = mapCfg[2].minX + (localCenterCol + 0.5) * CELL_SIZE
        worldZ = mapCfg[2].minZ + (centerRow + 0.5) * CELL_SIZE
        floorY = mapCfg[2].floorY
    else
        worldX = mapCfg[1].minX + (centerCol + 0.5) * CELL_SIZE
        worldZ = mapCfg[1].minZ + (centerRow + 0.5) * CELL_SIZE
        floorY = mapCfg[1].floorY
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
local placementModeStartTime = 0  -- when current placement mode began (for touch filtering)

-- IS_MOBILE is now declared near the top of the file (right after camera).
-- Touch-only devices (phones, tablets) get a big touch-friendly CANCEL /
-- PLACE bar during placement instead of relying on the grid tap + hotbar.

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
    bar.Size = UDim2.fromOffset(barWidth, slotSize + 20)
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
    cancelBtn.Size = UDim2.fromOffset(cancelW, slotSize)
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
    placeBtn.Size = UDim2.fromOffset(placeW, slotSize)
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
    multiToggle.Size = UDim2.fromOffset(220, 40)
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
    -- Note: activeTouchObject is the canonical local declared lower
    -- in the file (after the mobile touch handlers) and is cleared
    -- by those handlers themselves; this scope can't see it.
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
    -- Suppress placement during the Pickle Lord cinematic. The
    -- cinematic ScreenGui ("ToL_PickleLordCinematic") exists in
    -- playerGui exactly during the rise/camera takeover; using
    -- its presence as the gate avoids a forward-decl on
    -- PickleLordEntrance (which is required AFTER this function
    -- is defined). Also blocks the grid + ghost from spawning
    -- since both are built inside this fn.
    if playerGui:FindFirstChild("ToL_PickleLordCinematic") then return end
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
    local col = getCellAtScreenPos(input.Position.X, input.Position.Y + 24)
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
    if placementMode and (input.KeyCode == Enum.KeyCode.Escape
                          or input.KeyCode == Enum.KeyCode.Q) then
        exitPlacementMode()
        return
    end
    -- Number keys 1..9 map to whichever hotbar SLOT currently occupies that
    -- position. Slot positions are dynamic (populated by buildHotbar from the
    -- player's current stock), so pressing 2 always hits the 2nd visible slot
    -- even if the towerDefs order would have given it a different static hotkey.
    -- (Dev teleport hotkeys are now R/C/N — no need to suppress digits.)
    --
    -- GUARD: skip the hotbar digit binding while a 1-of-N picker modal
    -- is up (TowerSelect / UpgradePicker / TempTowerPicker), OR while
    -- the Pickle Lord entrance cinematic is playing. Each picker has
    -- its own 1/2/3 hotkey listener; the hotbar version racing on the
    -- same input would fire enterPlacementMode the frame the server
    -- grants stock and trigger a "tower placement" error. Cinematic
    -- gating prevents the player from entering placement (and
    -- spawning a grid / ghost) mid-rise.
    if playerGui:FindFirstChild("ToL_TowerSelect")
       or playerGui:FindFirstChild("ToL_UpgradePicker")
       or playerGui:FindFirstChild("ToL_TempTowerPicker")
       or playerGui:FindFirstChild("ToL_PickleLordCinematic") then
        return
    end
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
    -- Slot visibility rule (Matthew 2026-04-26 revision): "show
    -- towers equipped for the current run / phase". The
    -- `<id>Equipped` attribute is the primary signal — set true by
    -- grantLoadout (Infinite picker confirm + AUTO RUN round) for
    -- selected towers + Power, false for un-picked. Once a tower
    -- is placed its stock drops to 0 but the slot stays visible
    -- because Equipped is still true. When the loadout changes,
    -- Equipped flips and the hotbar refreshes.
    --
    -- Legacy fallback (Equipped attribute unset = nil): used by
    -- Map 1-3 regular runs, where towers come from boss-reward
    -- grants that don't touch Equipped. Falls back to "stock > 0
    -- or rarity set" — same logic as before this revision.
    local shown = {}
    for _, def in ipairs(towerDefs) do
        local equipped = player:GetAttribute(def.id .. "Equipped")
        local stock    = player:GetAttribute(def.id .. "Stock") or 0
        local rarity   = player:GetAttribute(def.id .. "Rarity")
        local show = false
        if equipped ~= nil then
            -- Equipped flow (Infinite arena): exact opt-in.
            show = equipped == true
        else
            -- Legacy flow: same rules as pre-2026-04-26.
            if def.id == "Power" then
                show = player:GetAttribute("HasBeenGrantedStock") == true
            elseif def.tempReward then
                show = stock > 0 or rarity ~= nil
            else
                show = def.enabled == true and stock > 0
            end
        end
        if show then table.insert(shown, def) end
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
    bar.Size = UDim2.fromOffset(barWidth, slotSize + 20)
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
        slot.Size = UDim2.fromOffset(slotSize, slotSize)
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
        iconBg.Size = UDim2.fromScale(1, 1)
        iconBg.Position = UDim2.new(0, 0, 0, 0)
        iconBg.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconBg.BorderSizePixel = 0
        iconBg.Parent = slot
        round(iconBg, 0.1)
        def.iconBuilder(iconBg)
        local keyLabel = Instance.new("TextLabel")
        keyLabel.Size = UDim2.fromOffset(20, 20)
        keyLabel.Position = UDim2.fromOffset(3, 3)
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
        countLabel.Size = UDim2.fromOffset(32, 20)
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
                    frame.Size = UDim2.fromOffset(0, 26)
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
                    tooltipLabel.Size = UDim2.fromScale(0, 1)
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
                    frame.Position = UDim2.fromOffset(pos.X + size.X / 2, pos.Y + size.Y + 6)
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

-- Stock + Equipped change listeners for EVERY tower def (not just
-- slots already on the bar). Per-slot listeners can't trigger
-- rebuilds for towers that aren't on the bar yet, so a granted
-- Infinite loadout / freshly-Equipped tower wouldn't surface until
-- some other event fired a buildHotbar(). Module-level listeners
-- close that gap.
for _, def in ipairs(towerDefs) do
    player:GetAttributeChangedSignal(def.id .. "Stock"):Connect(function()
        buildHotbar()
    end)
    player:GetAttributeChangedSignal(def.id .. "Equipped"):Connect(function()
        buildHotbar()
    end)
end

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

-- Run-time HUD state — forward-declared here so fireReset() captures
-- these as upvalues (Lua resolves free vars at function-definition
-- time; declaring them later would leave fireReset reading the GLOBAL
-- nil instead). Real values are written below; the Heartbeat tick + the
-- WaveState handler + HasBeenGrantedStock signal also read these.
-- runTimeLabel is assigned from PlayerHUDs.setup's return value at
-- the call-site near the bottom of this file.
--
-- TWO clocks tracked: wallclock (real seconds) is the headline, game-
-- time (dt × gameSpeed) lives in parens. At 1× they match; at 5× the
-- game-time runs 5× faster. Per Matthew (2026-04): "show actual run
-- time on bottom right hud, and put game time in parentheses."
local runTimeWallSec   = 0
local runTimeGameSec   = 0
local runTimePaused    = true   -- start paused; HasBeenGrantedStock flip unpauses
local runTimeLastMapId = nil
local runTimeLabel     = nil

local function fireReset(btn)
    -- RESET = full fresh-server state regardless of current map. DevReset
    -- on the server destroys towers, frees grid, heals heart, clears stage
    -- + wave state, and resets every per-run player attribute. Also fires
    -- DevTeleport("map1") on completion so the player doesn't end up on
    -- map 2 with a fresh map-1-only state.
    gameLost = false  -- unlock wave HUD; new game starts fresh
    -- Reset the run-time HUD — paused stays TRUE because the player has
    -- just returned to the lobby; HasBeenGrantedStock will fire the
    -- listener and unpause when they re-enter a map.
    runTimeWallSec   = 0
    runTimeGameSec   = 0
    runTimePaused    = true
    runTimeLastMapId = nil
    if runTimeLabel then runTimeLabel.Text = "run time: 0:00 (0:00)" end
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
-- placeAllTowers: dev-only — fire PlaceTower for every tower the player
-- has stock of, spiraling outward from the active map's center for the
-- most-central spots. Tracks just-placed cells locally so multiple towers
-- in one click don't collide. Falls through silently if no map is active.
--
-- AUTO-FIRE: this function ALSO fires automatically right after the
-- player picks their Core on map 1 (one PowerStock-attribute-change
-- listener below). Saves the click-on-grid step so the dev iteration
-- loop is "RESET → pick Core → towers already down". Only map 1 — on
-- map 2/3 the player gets stock from dev-port handlers and we don't
-- want to trample any aux they're trying to place by hand.
local function placeAllTowers()
    if not currentWaveState then return end
    local mapId = currentWaveState.mapId
    local entry = MapRegistry.get(mapId)
    if not entry then return end  -- hub / unknown map — nothing to place on
    local centerCol, centerRow = entry.placeAllCenter.col, entry.placeAllCenter.row
    local placeRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.PlaceTower)
    if not placeRemote then return end
    local justUsed = {}  -- "c,r" → true for cells we placed in THIS batch
    local function fits(anchorCol, anchorRow, fw, fd)
        for fc = 0, fw - 1 do
            for fr = 0, fd - 1 do
                local c, r = anchorCol + fc, anchorRow + fr
                if not localGrid[c] or localGrid[c][r] ~= "open" then return false end
                if justUsed[c .. "," .. r] then return false end
            end
        end
        return true
    end
    local function mark(anchorCol, anchorRow, fw, fd)
        for fc = 0, fw - 1 do
            for fr = 0, fd - 1 do
                justUsed[(anchorCol + fc) .. "," .. (anchorRow + fr)] = true
            end
        end
    end
    local function spiralFind(fw, fd)
        for radius = 0, 30 do
            for dc = -radius, radius do
                for dr = -radius, radius do
                    -- Walk only the perimeter of each radius square.
                    if radius == 0 or math.abs(dc) == radius or math.abs(dr) == radius then
                        local ac = centerCol + dc - math.floor(fw / 2)
                        local ar = centerRow + dr - math.floor(fd / 2)
                        if fits(ac, ar, fw, fd) then return ac, ar end
                    end
                end
            end
        end
        return nil, nil
    end
    for _, def in ipairs(towerDefs) do
        local stock = player:GetAttribute(def.id .. "Stock") or 0
        local fw, fd = def.footprint[1], def.footprint[2]
        for _ = 1, stock do
            local ac, ar = spiralFind(fw, fd)
            if ac and ar then
                placeRemote:FireServer(def.id, ac, ar)
                mark(ac, ar, fw, fd)
            else
                break  -- couldn't fit any more of this type
            end
        end
    end
end

-- ============================================================
-- INFINITE STUDIO auto-place pattern. Fixed cell positions per
-- role so tier-list stat capture is comparable across runs (a
-- ThornVine in run 1 lives in the same spot as a ThornVine in
-- run 47). See project_tower_categories.md for the role taxonomy.
--
-- Coords are offsets from mapCfg[4].colOffset (= 225). Slots are
-- consumed in order; each consumed slot is reserved against
-- justUsed so subsequent placements can't double-anchor.
--
-- Layout intent (per Matthew 2026-04-27 screenshot):
--   left column   = DPS (red), stacked
--   center        = Support (blue), buffs surrounding DPS
--   right side    = Control (purple), 2 anchors
--   Core          = placed first, central anchor
-- ============================================================
-- Auto-place pattern for Map 4. River is now vertical at col 60
-- rows 0-30 (heart side). Pattern zones laid out:
--   • DPS top-left vertical  — col 12 rows 18/22/26
--   • DPS bottom-wide        — row 50 cols 4/12/20/28
--   • Control top-center     — row 22 cols 28/38
--   • Control right-vertical — col 50 rows 18/24/32/42 (left of
--                               the river at col 58-62)
--   • Support top-row        — row 0 cols 6/18/30/42 (no Support
--                               towers exist yet; these are
--                               fallback overflow targets — they
--                               come LAST in the pattern order so
--                               DPS towers fill DPS slots first
--                               instead of falling back to Support
--                               immediately).
--
-- Power Core is treated as a DPS tower (TempTowers.RoleByTowerId.
-- Power = "DPS"). Stock multiplicity is honored — a tower with
-- stock N occupies N pool entries, so all copies get placed.
--
-- Slot order matters for the fallback chain (DPS→Control→Support):
-- iterating DPS slots FIRST means DPS towers always land in DPS
-- positions before the fallback fires. Putting Support slots last
-- prevents them from soaking up DPS towers via the fallback.
-- Per Matthew 2026-04-26: "the core tower got placed her for some
-- reason. outside the dps zone."
-- Tetris-packed layout per Matthew 2026-04-26 ("tetris the towers
-- before placing to maximize real estate"). Path geometry moved
-- (leftmost N-S leg now at col 2 against the boundary), freeing
-- cols 5-10 between the path band and the old DPS column for
-- denser packing.
--
-- Footprint = 4×4 for towers; 5-cell stride = 4 footprint + 1 gap
-- so towers don't overlap and a 1-cell aisle stays between rows.
--
-- AVAILABLE TOWER ZONES on Map 4 (post-path-shift):
--   • Top zone   (rows 11-29): cols 5-58 (avoids river at cols 58-62)
--   • Bottom zone (rows 35-57): cols 5-34 (path comes back at col 38)
--                                cols 41-58 (right of right N-S path
--                                            band cols 36-40)
--
-- ROLE LAYOUT:
--   • DPS column     — col 6  rows 12/17/22/27 (4 slots, against the
--                                                left path)
--   • DPS column 2   — col 12 rows 12/17/22/27 (4 slots)
--   • DPS bottom row — row 50 cols 6/12/18/24/30 + 42/48/54 (8 slots)
--                                                        — split by
--                                                          the right
--                                                          N-S path
--   • Control column — col 18 rows 12/17/22/27 (4 slots)
--   • Control col 2  — col 24 rows 12/17/22/27 (4 slots)
--   • Control rt-col — col 50 rows 12/17/22/27 (4 slots, west of river)
--   • Support row    — row 0 cols 6/12/18/24/30/42/48/54 (8 slots)
--
-- Power Core gets slot index 1 (always col 6 row 12) — deterministic
-- top-of-DPS placement so the Core never falls into a fallback slot
-- near the heart. Per Matthew 2026-04-26: "core tower misplaced
-- (circled)." Pool ordering puts Power FIRST regardless of alphabetic
-- sort (see placeInfinitePattern below).
local INFINITE_PATTERN = {
    -- DPS columns west of the river (rows 12-27 → 4 rows of slots).
    -- Slot 1 reserved for Power Core (the very first DPS pool entry).
    { co =  6, ro = 12, role = "DPS" },   -- slot 1 — Power Core anchor
    { co =  6, ro = 17, role = "DPS" },
    { co =  6, ro = 22, role = "DPS" },
    { co =  6, ro = 27, role = "DPS" },
    { co = 12, ro = 12, role = "DPS" },
    { co = 12, ro = 17, role = "DPS" },
    { co = 12, ro = 22, role = "DPS" },
    { co = 12, ro = 27, role = "DPS" },
    -- DPS bottom-wide block. Row 50 is between middle (row 32) and
    -- bottom (row 58) east paths. Right N-S path covers cols 36-40,
    -- so the row splits: cols 6-30 (5 slots) + cols 42-54 (3 slots).
    { co =  6, ro = 50, role = "DPS" },
    { co = 12, ro = 50, role = "DPS" },
    { co = 18, ro = 50, role = "DPS" },
    { co = 24, ro = 50, role = "DPS" },
    { co = 30, ro = 50, role = "DPS" },
    { co = 42, ro = 50, role = "DPS" },
    { co = 48, ro = 50, role = "DPS" },
    { co = 54, ro = 50, role = "DPS" },
    -- Control columns mid-zone (rows 12-27).
    { co = 18, ro = 12, role = "Control" },
    { co = 18, ro = 17, role = "Control" },
    { co = 18, ro = 22, role = "Control" },
    { co = 18, ro = 27, role = "Control" },
    { co = 24, ro = 12, role = "Control" },
    { co = 24, ro = 17, role = "Control" },
    { co = 24, ro = 22, role = "Control" },
    { co = 24, ro = 27, role = "Control" },
    -- Control right-side column (col 50, west of river at cols 58-62;
    -- clear of right N-S which is cols 36-40).
    { co = 50, ro = 12, role = "Control" },
    { co = 50, ro = 17, role = "Control" },
    { co = 50, ro = 22, role = "Control" },
    { co = 50, ro = 27, role = "Control" },
    -- Support top-row (no Support towers exist yet, but the slots
    -- are here so future Support adds have a home). LAST in order
    -- so DPS / Control fill their dedicated slots first via pass 1
    -- before fallback assigns leftovers here.
    { co =  6, ro = 0, role = "Support" },
    { co = 12, ro = 0, role = "Support" },
    { co = 18, ro = 0, role = "Support" },
    { co = 24, ro = 0, role = "Support" },
    { co = 30, ro = 0, role = "Support" },
    { co = 42, ro = 0, role = "Support" },
    { co = 48, ro = 0, role = "Support" },
    { co = 54, ro = 0, role = "Support" },
}

local function placeInfinitePattern()
    local placeRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.PlaceTower)
    if not placeRemote then return end
    local colOffset = mapCfg[4].colOffset
    local justUsed = {}
    local function fits(anchorCol, anchorRow, fw, fd)
        for fc = 0, fw - 1 do
            for fr = 0, fd - 1 do
                local c, r = anchorCol + fc, anchorRow + fr
                if not localGrid[c] or localGrid[c][r] ~= "open" then return false end
                if justUsed[c .. "," .. r] then return false end
            end
        end
        return true
    end
    local function mark(anchorCol, anchorRow, fw, fd)
        for fc = 0, fw - 1 do
            for fr = 0, fd - 1 do
                justUsed[(anchorCol + fc) .. "," .. (anchorRow + fr)] = true
            end
        end
    end

    -- Build the candidate tower list per role from the player's
    -- stock. Power is now treated as a DPS tower (Matthew 2026-04-26:
    -- "power core should be placed with dps") — its role lookup
    -- comes from TempTowers.RoleByTowerId.Power = "DPS". No more
    -- dedicated Core pool / slot.
    --
    -- Stock multiplicity: a tower with stock N is inserted N times
    -- into its role pool, so all copies get placed (Matthew
    -- 2026-04-26: "it only places 1 aux tower even if there is
    -- multiple stock"). With Power=1 + e.g. ThornVine=3 +
    -- AcornSniper=2, the DPS pool has 6 entries — fills all 6 DPS
    -- slots in the pattern.
    --
    -- Pool order is SORTED ALPHABETICALLY so the same tower always
    -- lands in the same slot across runs — non-deterministic
    -- pairs() order would shuffle towers between runs and ruin the
    -- benchmark consistency the auto-place pattern is meant to give.
    -- Duplicates of the same tower cluster adjacent (alpha order +
    -- stock-expand inserts copies in sequence).
    local pools = { DPS = {}, Control = {}, Support = {} }
    -- Power Core goes FIRST in the DPS pool — slot 1 of the pattern
    -- is the deterministic "Core anchor" position (see INFINITE_PATTERN
    -- comment above). Per Matthew 2026-04-26: "core tower misplaced
    -- (circled)." Was previously sorted alphabetically alongside aux
    -- towers, which let Power land in any DPS slot depending on the
    -- loadout — sometimes far from the canonical Core position.
    do
        -- Cores ALL slot into the DPS pool (Matthew 2026-04-28):
        -- "even though it's supportcore. it's primary purpose is
        -- damage." The Core picks up starting Infinite upgrade
        -- cards (AoE / Stun / Knockback) PLUS per-cycle damage
        -- and fireRate bumps during a run, so its effective DPS
        -- dominates regardless of variant. SupportCore's aura +
        -- ControlCore's stacking-DOT are auxiliary mechanics on
        -- top of "the Core does the most damage in the loadout."
        --
        -- DPS slot 1 of INFINITE_PATTERN is the canonical "Core
        -- anchor" — putting all Cores there keeps the Core in
        -- the same on-path position across Power / Control /
        -- Support sweeps so tier comparisons stay apples-to-apples.
        for _, coreId in ipairs({ "Power", "ControlCore", "SupportCore" }) do
            local stock = player:GetAttribute(coreId .. "Stock") or 0
            for _ = 1, stock do
                table.insert(pools.DPS, coreId)
            end
        end
    end
    local auxIds = {}
    for towerId, _ in pairs(TempTowers.Templates) do
        table.insert(auxIds, towerId)
    end
    table.sort(auxIds)
    for _, towerId in ipairs(auxIds) do
        local stock = player:GetAttribute(towerId .. "Stock") or 0
        local role = TempTowers.RoleByTowerId[towerId]
        -- Support towers route into the DPS pool so the pre-placement
        -- tetris packs them adjacent to the DPS column they're meant
        -- to amplify (per Matthew 2026-04-28: "when doing the pre
        -- placement tetris, put support towers in with dps when
        -- possible"). If DPS slots run out, pass-2 fallback still
        -- spills them into the Support row (row 0) — so the slot
        -- pattern doesn't need to change.
        local placePool = (role == "Support") and "DPS" or role
        if stock > 0 and placePool and pools[placePool] then
            for _ = 1, stock do
                table.insert(pools[placePool], towerId)
            end
        end
    end

    -- Small spiral fallback: if slot's exact anchor doesn't fit (path
    -- cells creep close to a slot, or another tower's footprint
    -- spilled into this one), try positions within 3 cells in each
    -- direction before giving up. Keeps the layout visually close to
    -- the canonical pattern without leaving holes when a single cell
    -- happens to overlap.
    local function findNearAnchor(baseCol, baseRow, fw, fd)
        if fits(baseCol, baseRow, fw, fd) then
            return baseCol, baseRow
        end
        for radius = 1, 3 do
            for dc = -radius, radius do
                for dr = -radius, radius do
                    if math.abs(dc) == radius or math.abs(dr) == radius then
                        local ac, ar = baseCol + dc, baseRow + dr
                        if fits(ac, ar, fw, fd) then return ac, ar end
                    end
                end
            end
        end
        return nil, nil
    end

    -- TWO-PASS placement so role-pure slots fill BEFORE fallback
    -- spills DPS/Control overflow into wrong-role slots. Per
    -- Matthew 2026-04-26: "some control towers are being placed
    -- in dps territory even though there's still space in the
    -- control tower zone" — caused by the prior single-pass loop
    -- which fired fallback the moment a same-role pool drained,
    -- letting Control overflow grab DPS slots before reaching
    -- the still-empty Control slots later in the pattern.
    --
    -- Pass 1: walk slots in pattern order; for each slot, take
    -- ONLY from the matching role pool. If empty, leave the slot
    -- unfilled (don't fallback yet).
    -- Pass 2: walk unfilled slots; for each, allow fallback to
    -- any non-empty pool (DPS → Control → Support).
    local FALLBACK_ORDER = { "DPS", "Control", "Support" }
    local placed = 0
    local skipped = 0
    local unfilled = {}  -- list of slot indices that pass 1 left empty

    local function tryPlaceSlot(_slotIdx, slot, towerId, pickedRole)
        local def
        -- Core variants (Power / ControlCore / SupportCore) live in
        -- TowerTypes. Aux towers live in TempTowers.Templates. Fall
        -- through if neither has it (defensive — shouldn't happen).
        if TowerTypes[towerId] then
            def = TowerTypes[towerId]
        else
            def = TempTowers.Templates[towerId]
        end
        local fw = def.footprintWidth or 4
        local fd = def.footprintDepth or 4
        local baseCol = colOffset + slot.co
        local baseRow = slot.ro
        local ac, ar = findNearAnchor(baseCol, baseRow, fw, fd)
        if ac then
            placeRemote:FireServer(towerId, ac, ar)
            mark(ac, ar, fw, fd)
            placed = placed + 1
            -- (silenced per-slot placement trace — was 5-9 lines × 81 loadouts of spam.)
            return true
        else
            -- Put the tower back in the pool it came from.
            if pools[pickedRole] then
                table.insert(pools[pickedRole], 1, towerId)
            end
            return false
        end
    end

    -- PASS 1: role-pure placement. No fallback.
    for slotIdx, slot in ipairs(INFINITE_PATTERN) do
        local pool = pools[slot.role]
        if pool and #pool > 0 then
            local towerId = table.remove(pool, 1)
            if not tryPlaceSlot(slotIdx, slot, towerId, slot.role) then
                table.insert(unfilled, slotIdx)
            end
        else
            table.insert(unfilled, slotIdx)
        end
    end

    -- PASS 2: overflow fallback for slots pass 1 couldn't fill.
    for _, slotIdx in ipairs(unfilled) do
        local slot = INFINITE_PATTERN[slotIdx]
        local fallbackId, fallbackRole
        for _, role in ipairs(FALLBACK_ORDER) do
            local p = pools[role]
            if p and #p > 0 then
                fallbackId = table.remove(p, 1)
                fallbackRole = role
                break
            end
        end
        if fallbackId then
            tryPlaceSlot(slotIdx, slot, fallbackId, fallbackRole)
        else
            skipped = skipped + 1
        end
    end
    -- (silenced per-slot empty-pool warnings + summary line — 12-27 lines per loadout × 81.)
end

-- Server-triggered: Infinite.enter() fires this after the loadout grant
-- + map switch land. Small client-side delay so the gridUpdate broadcast
-- (path / heart cells) lands before fits() reads localGrid.
ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoPlace).OnClientEvent
    :Connect(function()
        task.defer(placeInfinitePattern)
    end)

-- Auto-place trigger: fire placeAllTowers ONCE per run as soon as the
-- player has both (a) PowerStock > 0 and (b) currentWaveState.mapId == 1
-- AND (c) DevAutoPlace flag is true. The flag is set ONLY by the dev
-- teleport map-1 handler; the natural portal flow (climbing the tree)
-- leaves it unset so the player picks + places their Core themselves.
-- Per Matthew 2026-04-27: "if enter map 1 normally through the portal
-- it should give me the normal game loop ie I should pick and core
-- tower should not be auto placed."
--
-- Listens to BOTH the PowerStock attribute change AND WaveState events
-- because Roblox doesn't guarantee replication order — the Core grant
-- and the SwitchMap broadcast can arrive in either order.
--
-- HasBeenGrantedStock attribute change resets the once-per-run flag —
-- that flag clears on RunReset, so the next run's Core pick re-fires.
do
    local autoPlacedThisRun = false
    local function maybeAutoPlace()
        if autoPlacedThisRun then return end
        if not currentWaveState then return end
        if currentWaveState.mapId ~= 1 then return end
        if (player:GetAttribute("PowerStock") or 0) <= 0 then return end
        if player:GetAttribute("DevAutoPlace") ~= true then return end
        autoPlacedThisRun = true
        -- One frame defer so the grid broadcast (server→client) lands
        -- before placeAllTowers' fits() reads localGrid. Roblox usually
        -- replicates within a few ms, so this is short enough not to
        -- be perceived but long enough to dodge the race.
        task.defer(function()
            if (player:GetAttribute("PowerStock") or 0) > 0 then
                placeAllTowers()
                -- Clear the flag so a subsequent stock grant in the
                -- same session doesn't re-trigger.
                player:SetAttribute("DevAutoPlace", nil)
            end
        end)
    end
    player:GetAttributeChangedSignal("PowerStock"):Connect(maybeAutoPlace)
    ReplicatedStorage:WaitForChild(Remotes.Names.WaveState).OnClientEvent:Connect(maybeAutoPlace)
    player:GetAttributeChangedSignal("DevAutoPlace"):Connect(maybeAutoPlace)
    player:GetAttributeChangedSignal("HasBeenGrantedStock"):Connect(function()
        if not player:GetAttribute("HasBeenGrantedStock") then
            autoPlacedThisRun = false
        end
    end)
end

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
    fireReset           = fireReset,
    placeAllTowers      = placeAllTowers,
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
-- INFINITE STUDIO HUD — top-center "WAVE N (Test)" + countdown.
-- Visible only when on Map 4 (Pickle Swamp).
------------------------------------------------------------
require(script:WaitForChild("InfiniteHUD")).setup({
    player             = player,
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
})

------------------------------------------------------------
-- INFINITE LOADOUT PICKER — PC-only modal: 9-tower grid + slider.
-- Opens on ShowInfiniteScenarioPicker (server fires from hub portal
-- touch / dev F-hotkey). Pick fires PickInfiniteScenario with payload.
------------------------------------------------------------
require(script:WaitForChild("InfiniteLoadoutPicker")).setup({
    player             = player,
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    TempTowers         = TempTowers,
})

------------------------------------------------------------
-- INFINITE BUTTON BAR — LOADOUT + ADMIN buttons above the hotbar
-- while in Map 4. Hidden everywhere else.
------------------------------------------------------------
require(script:WaitForChild("InfiniteButtonBar")).setup({
    player             = player,
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

-- Default size 360×30; PickleLord activation grows it to 360×76 to
-- fit the embedded HP-bar row (30 base + 6 gap + 40 HP row).
local waveFrame = Instance.new("Frame")
waveFrame.Size = UDim2.fromOffset(360, 30)
waveFrame.Position = UDim2.new(0.5, -180, 0, 0)  -- flush to top
waveFrame.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
waveFrame.BackgroundTransparency = 0.25
waveFrame.BorderSizePixel = 0
-- ClipsDescendants so the boss HP bar can never overflow the rounded
-- panel edges (was bleeding off-screen-right on map 3).
waveFrame.ClipsDescendants = true
-- Always-on per Matthew. Pre-game default text shown until the wave system
-- starts broadcasting WaveState.
waveFrame.Visible = true
waveFrame.Parent = waveGui
do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0.18, 0)
    c.Parent = waveFrame
end

-- Single combined label: "Canopy Nest (Night)  ·  ● ● ●  ·  Wave 1 / 5".
-- Map name + stage dots + wave on ONE line, all Gotham. RichText lets the
-- dots inline as colored bullet characters between the two text spans.
local mapLabel = Instance.new("TextLabel")
mapLabel.Size = UDim2.new(1, -16, 1, 0)
mapLabel.Position = UDim2.fromOffset(8, 0)
mapLabel.BackgroundTransparency = 1
mapLabel.RichText = true
-- Initial text: lobby/entrance only — no wave info. The WaveState handler
-- below replaces this when the player actually enters a map (state.map
-- becomes non-empty). If the static text included "Wave 0 / 5" the
-- player saw it FIRST, before any state event landed, and it leaked
-- through during the lobby.
mapLabel.Text = "Entrance to the Tree of Life"
mapLabel.TextColor3 = Color3.fromRGB(220, 230, 245)
mapLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
mapLabel.TextStrokeTransparency = 0.5
mapLabel.Font = Enum.Font.Gotham
mapLabel.TextSize = 14
mapLabel.TextXAlignment = Enum.TextXAlignment.Center
mapLabel.TextYAlignment = Enum.TextYAlignment.Center
mapLabel.Parent = waveFrame

local waveLabel = mapLabel  -- alias for legacy callsites

-- (Pickle Lord HP row is built inside PickleLordEntrance.setup
-- to avoid spending a top-level register on a reference table.
-- Module gets `deps.waveFrame` and builds the row as a second-row
-- child internally.)

-- Stage dots are now INLINE in mapLabel via RichText (between the map
-- name and the wave text — see WaveState handler). Boss HP bar stays as
-- a separate Frame; on map 3 it doubles as a survival COUNTDOWN bar
-- (baby blue, depleting) driven by the BirdBossCountdown remote. The
-- digital m:ss watch sits BELOW the status panel.
local bossHpBg, bossHpFill
do
    bossHpBg = Instance.new("Frame")
    bossHpBg.AnchorPoint = Vector2.new(1, 0.5)
    bossHpBg.Position = UDim2.new(1, -10, 0.5, 0)
    -- Narrower than before (was 220) so there's a clear gap between the
    -- map name on the left and the bar on the right per Matthew's
    -- "give it breathing room" feedback.
    bossHpBg.Size = UDim2.fromOffset(150, 12)
    bossHpBg.BackgroundColor3 = Color3.fromRGB(40, 16, 18)
    bossHpBg.BorderSizePixel = 0
    bossHpBg.Visible = false
    bossHpBg.Parent = waveFrame
    local bgCorner = Instance.new("UICorner")
    bgCorner.CornerRadius = UDim.new(0.5, 0)
    bgCorner.Parent = bossHpBg
    bossHpFill = Instance.new("Frame")
    bossHpFill.Size = UDim2.new(1, -2, 1, -2)
    bossHpFill.Position = UDim2.fromOffset(1, 1)
    bossHpFill.BackgroundColor3 = Color3.fromRGB(220, 50, 70)
    bossHpFill.BorderSizePixel = 0
    bossHpFill.Parent = bossHpBg
    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0.5, 0)
    fillCorner.Parent = bossHpFill
end
-- HP-percent overlay on the boss bar — white text centered on top of the
-- fill, format "XX.X%". Sits at ZIndex 4 so it renders above both bg
-- and fill but below the CLEARED label (ZIndex 5).
local bossHpPctLabel = Instance.new("TextLabel")
bossHpPctLabel.Size = UDim2.fromScale(1, 1)
bossHpPctLabel.BackgroundTransparency = 1
bossHpPctLabel.Text = "100.0%"
bossHpPctLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
bossHpPctLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
bossHpPctLabel.TextStrokeTransparency = 0.2
bossHpPctLabel.Font = Enum.Font.FredokaOne
bossHpPctLabel.TextSize = 11
bossHpPctLabel.TextXAlignment = Enum.TextXAlignment.Center
bossHpPctLabel.TextYAlignment = Enum.TextYAlignment.Center
bossHpPctLabel.ZIndex = 4
bossHpPctLabel.Visible = false
bossHpPctLabel.Parent = bossHpBg
-- "CLEARED" label that swaps in for the boss HP bar after the boss is
-- killed. Lives inside the same bossHpBg slot so the layout doesn't
-- shift. Visible only when the WaveState handler latches the
-- bossCleared one-shot from the server.
local bossClearedLabel = Instance.new("TextLabel")
bossClearedLabel.Size = UDim2.fromScale(1, 1)
bossClearedLabel.BackgroundTransparency = 1
bossClearedLabel.Text = "CLEARED"
bossClearedLabel.TextColor3 = Color3.fromRGB(255, 240, 180)
bossClearedLabel.TextStrokeColor3 = Color3.fromRGB(40, 20, 0)
bossClearedLabel.TextStrokeTransparency = 0.2
bossClearedLabel.Font = Enum.Font.FredokaOne
bossClearedLabel.TextSize = 14
bossClearedLabel.Visible = false
bossClearedLabel.ZIndex = 5
bossClearedLabel.Parent = bossHpBg

-- Digital countdown watch — black m:ss text under the status panel,
-- visible only during the map-3 survival phase. Mimics a digital watch.
local watchLabel = Instance.new("TextLabel")
watchLabel.AnchorPoint = Vector2.new(0.5, 0)
watchLabel.Position = UDim2.new(0.5, 0, 0, 32)
watchLabel.Size = UDim2.fromOffset(110, 28)
watchLabel.BackgroundColor3 = Color3.fromRGB(180, 220, 255)
watchLabel.BackgroundTransparency = 0.05
watchLabel.BorderSizePixel = 0
watchLabel.TextColor3 = Color3.fromRGB(15, 18, 25)
watchLabel.Font = Enum.Font.RobotoMono
watchLabel.TextSize = 22
watchLabel.Text = "5:00"
watchLabel.Visible = false
watchLabel.Parent = waveGui
do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0.2, 0)
    c.Parent = watchLabel
end

-- Local cache of the last bird-boss status payload (renamed from
-- "countdown" — same remote channel, payload is now {active, hp, maxHp}).
local birdBossStatus = { active = false, hp = 0, maxHp = 1, damageable = false }
-- (The first-timer hint is fired server-side as a falling-leaf message
-- — see Map3BirdBoss.lua. No client-side banner.)

-- ============================================================
-- PICKLE LORD ENTRANCE — extracted to sibling ModuleScript.
-- Owns the boss bar UI, the cinematic, the smash camera shake,
-- AND the active/cleared lifecycle flag. Was three top-level
-- locals here (pickleLordActive, pickleLordBar, fadePickleLordBar)
-- plus a long do-block; moving them out keeps init.client.lua
-- under the Luau 200-register ceiling.
-- See TreeOfLife_Client/PickleLordEntrance.lua for the full code.
-- ============================================================
local PickleLordEntrance = require(script:WaitForChild("PickleLordEntrance"))

-- Yellow tap-to-release circle: parented to the BIRD's body (not the
-- player) so the player's tap target sits on the threat itself. Driven
-- by BirdGrabState. Falls back to player HRP if the bird isn't found
-- (network/timing edge case) so the player still has a tap target.
-- Grab indicator: SCREEN-SPACE GUI (NOT BillboardGui). BillboardGui Adornee'd
-- to a fast-moving Part has unreliable input — playtest had many "clicked
-- right on the circle, nothing happened" misses. ScreenGui input always
-- works because the button lives in screen pixels, not world-projected
-- pixels. We track the bird's screen position via WorldToViewportPoint
-- each frame and reposition the button.
-- Bundle all bird-grab UI state into ONE table local. The script is at
-- the Luau 200-register ceiling (see CLAUDE.md); separate locals for
-- each field pushed it over and broke compilation with "Out of local
-- registers". One table = one register; field access is fine since
-- these are mutated rarely (on grab-state remote, on grab end).
--
-- Fields:
--   gui      — ScreenGui parent for the tap button
--   btn      — TextButton (the "10/9/8…" yellow circle)
--   segments — 24-entry array of Frames forming a clock-tick countdown
--              ring around the button. Each segment hides clockwise as
--              the bird carries the player toward death; remaining
--              segments lerp from black → red. (Was a single UIStroke
--              that just changed color; per Matthew's playtest it should
--              also visually shorten so the player reads it as a clock.)
--   conn     — RenderStepped follow connection (button position +
--              segment count + color update per frame)
--   startY   — player's Y at the moment of grab; cached across the
--              tap-decrement payloads which omit it
--   killY    — bounds-kill ceiling Y; same caching semantics as startY
local grabUI = {
    gui      = nil,
    btn      = nil,
    segments = nil,
    conn     = nil,
    startY   = nil,
    killY    = nil,
}
-- Constants for the countdown ring. 16 segments = 22.5° each, with
-- visible gaps between adjacent ticks — reads as a "broken outline"
-- per Matthew's playtest call. LENGTH < arc-per-slot so the gap is
-- always wider than the tick → unambiguously dashed. Bundled into one
-- table to keep the file's register count under the Luau 200 ceiling
-- (see grabUI comment above for the same rationale).
local GRAB_RING = {
    SEGMENTS  = 16,  -- 22.5° each; 10-tap escape gives 1.6 segments per tap of margin
    THICKNESS = 12,  -- segment radial thickness; thicker than the prior 8 — reads as a real border
    LENGTH    = 14,  -- segment tangential length (~70% of arc-per-slot at default button size — clearly dashed but tighter than the 10/half-gap initial pass)
    OUTSET    = 8,   -- pixels the ring sits OUTSIDE the button border; gives breathing room from the "10/9/..." label
}
local function findBirdBody()
    local model = workspace:FindFirstChild("Map3CanopyBird")
    return model and model:FindFirstChild("Body")
end
local function ensureGrabBillboard()
    if grabUI.gui and grabUI.gui.Parent then return end
    grabUI.gui = Instance.new("ScreenGui")
    grabUI.gui.Name = "ToL_BirdGrabIndicator"
    grabUI.gui.IgnoreGuiInset = true
    grabUI.gui.ResetOnSpawn = false
    grabUI.gui.DisplayOrder = 80
    grabUI.gui.Parent = playerGui

    local body = findBirdBody()
    local sizeStud = (body and body:IsA("BasePart") and math.max(body.Size.X, body.Size.Z)) or 8
    local pxPerStud = IS_MOBILE and 17 or 11
    local pxSize    = math.floor(sizeStud * pxPerStud + 0.5)

    local btn = Instance.new("TextButton")
    btn.AnchorPoint = Vector2.new(0.5, 0.5)
    btn.Size = UDim2.fromOffset(pxSize, pxSize)
    btn.Position = UDim2.fromScale(0.5, 0.5)  -- center; updated per frame
    btn.BackgroundColor3 = Color3.fromRGB(255, 215, 70)
    btn.BorderSizePixel = 0
    btn.Text = "10"
    btn.TextColor3 = Color3.fromRGB(20, 20, 20)
    btn.TextStrokeTransparency = 1
    btn.Font = Enum.Font.FredokaOne
    btn.TextSize = math.floor(pxSize * 0.55 + 0.5)
    btn.AutoButtonColor = false
    btn.Active = true
    btn.Parent = grabUI.gui
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(1, 0)  -- circular
        c.Parent = btn
    end
    -- Clock-tick countdown ring: 24 segments arranged around the
    -- button, hiding clockwise as the carry progresses, color lerping
    -- black → red across whatever's left visible. Each segment is a
    -- thin radial bar parented to the button so it follows the button
    -- on the per-frame WorldToViewport reposition (no separate follow
    -- needed). Index 1 = 12 o'clock; subsequent segments rotate
    -- clockwise (positive Y is "down" in screen space, so a positive
    -- angle from -90° rotates clockwise visually).
    do
        local segments = table.create(GRAB_RING.SEGMENTS)
        local outerR = pxSize * 0.5 + GRAB_RING.OUTSET
        for i = 1, GRAB_RING.SEGMENTS do
            -- -90° start = top of the circle; clockwise step thereafter.
            local deg = -90 + (i - 1) * (360 / GRAB_RING.SEGMENTS)
            local rad = math.rad(deg)
            local seg = Instance.new("Frame")
            seg.AnchorPoint = Vector2.new(0.5, 0.5)
            seg.Size = UDim2.fromOffset(GRAB_RING.LENGTH, GRAB_RING.THICKNESS)
            -- Position relative to the button's CENTER. Button is
            -- pxSize×pxSize with AnchorPoint (0.5, 0.5) at (0.5, 0.5)
            -- of its parent — so each segment lives at button center +
            -- (cos·R, sin·R). UDim2 offset is enough; no scale needed.
            seg.Position = UDim2.new(0.5, math.cos(rad) * outerR,
                                     0.5, math.sin(rad) * outerR)
            -- Bar's long axis points TOWARD the center; rotation aligns
            -- the bar with the radial direction. Add 90° because the
            -- frame's "long axis" defaults to horizontal.
            seg.Rotation = deg + 90
            seg.BackgroundColor3 = Color3.fromRGB(255, 140, 0)  -- orange at full timer; lerps to red as it ticks
            seg.BorderSizePixel = 0
            seg.Parent = btn
            -- UICorner with max radius rounds each tick into a pill —
            -- reads more as a stylized dash and less as a hard rectangle.
            -- Scoped do-block releases the local after configure (the
            -- decorator instance stays parented).
            do
                local cc = Instance.new("UICorner")
                cc.CornerRadius = UDim.new(1, 0)  -- caps at half min(W,H) → pill
                cc.Parent = seg
            end
            segments[i] = seg
        end
        grabUI.segments = segments
    end
    grabUI.btn = btn

    -- MouseButton1Click + Activated BOTH fire on a single mouse click
    -- (Activated runs slightly after the click event), so we need a
    -- per-action debounce. 0.18s is short enough to allow rapid 10-tap
    -- escapes, long enough to dedupe the redundant fires.
    local lastFireAt = 0
    local function fireBirdClick()
        local now = os.clock()
        if now - lastFireAt < 0.18 then return end
        lastFireAt = now
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.BirdClick)
        if r then r:FireServer() end
    end
    btn.MouseButton1Click:Connect(fireBirdClick)
    btn.TouchTap:Connect(fireBirdClick)
    btn.Activated:Connect(fireBirdClick)

    -- Per-frame follow: keep the button anchored on the bird's screen
    -- position. Lift = body height * 0.6 + 2.5 stud above body center.
    -- Also drives the UIStroke red-lerp: as the bird carries the player
    -- upward toward the bounds-kill Y, the outline reddens proportionally.
    grabUI.conn = RunService.RenderStepped:Connect(function()
        local b = findBirdBody()
        if not b then
            -- Fall back to player HRP if the bird's gone (edge case during
            -- death animation, etc.) so the circle stays visible.
            local char = player.Character
            b = char and char:FindFirstChild("HumanoidRootPart")
        end
        if not b then return end
        local lift = (b:IsA("BasePart") and b.Size.Y * 0.6 + 2.5) or 5
        local cam = workspace.CurrentCamera
        if not cam then return end
        local sp = cam:WorldToViewportPoint(b.Position + Vector3.new(0, lift, 0))
        if sp.Z > 0 then
            btn.Visible = true
            btn.Position = UDim2.fromOffset(sp.X, sp.Y)
        else
            -- Behind the camera — hide so the circle doesn't snap to a
            -- mirrored on-screen position.
            btn.Visible = false
        end
        -- Countdown ring update. 0 = full ring black (just grabbed),
        -- 1 = no ring + full red (about to die). Visible-segment count
        -- drops clockwise (segment[1] = 12 o'clock disappears first,
        -- then segment[2], etc.). Remaining segments lerp black → red.
        -- Read PLAYER HRP Y, not bird Y, since the kill check on the
        -- server gates on player HRP position.
        if grabUI.segments and grabUI.startY and grabUI.killY
           and grabUI.killY > grabUI.startY then
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local progress = (hrp.Position.Y - grabUI.startY)
                                 / (grabUI.killY - grabUI.startY)
                progress = math.clamp(progress, 0, 1)
                local total = #grabUI.segments
                local hiddenCount = math.floor(progress * total + 0.5)
                -- Lerp orange (255,140,0) → red (255,0,0). Only the green
                -- channel changes; R stays 255, B stays 0. At progress=0
                -- the visible pills match the orange we built them with;
                -- by progress=1 they're full red.
                local segColor = Color3.fromRGB(255,
                    math.floor(140 * (1 - progress) + 0.5),
                    0)
                for i = 1, total do
                    local seg = grabUI.segments[i]
                    if seg then
                        -- segments[1..hiddenCount] = hidden (eaten clockwise);
                        -- the rest stay visible at the lerped color.
                        seg.Visible = i > hiddenCount
                        if seg.Visible then
                            seg.BackgroundColor3 = segColor
                        end
                    end
                end
            end
        end
    end)
end
local function destroyGrabBillboard()
    if grabUI.conn then grabUI.conn:Disconnect(); grabUI.conn = nil end
    if grabUI.gui then
        grabUI.gui:Destroy()
        grabUI.gui      = nil
        grabUI.btn      = nil
        grabUI.segments = nil
    end
    grabUI.startY = nil
    grabUI.killY  = nil
end
-- Camera takeover while grabbed: pull the camera up + behind the bird and
-- tilt it slightly down toward the body so the player has a clear view of
-- themselves being carried + the click circle. Restored on release.
local grabCameraConn = nil
local savedCameraType = nil
local function startGrabCamera()
    local cam = workspace.CurrentCamera
    if not cam then return end
    if savedCameraType == nil then
        savedCameraType = cam.CameraType
    end
    cam.CameraType = Enum.CameraType.Scriptable
    if grabCameraConn then grabCameraConn:Disconnect() end
    grabCameraConn = RunService.RenderStepped:Connect(function()
        local birdModel = workspace:FindFirstChild("Map3CanopyBird")
        local body = birdModel and birdModel:FindFirstChild("Body")
        if not body then return end
        -- Camera ~14 stud above the bird, ~10 stud behind, looking down at
        -- the body. "Slightly above" + tilted down per Matthew's spec.
        local lookFrom = body.Position + Vector3.new(0, 14, -10)
        local lookAt   = body.Position + Vector3.new(0, -2, 0)
        cam.CFrame = CFrame.lookAt(lookFrom, lookAt)
    end)
end
local function stopGrabCamera()
    if grabCameraConn then grabCameraConn:Disconnect(); grabCameraConn = nil end
    local cam = workspace.CurrentCamera
    if cam and savedCameraType then
        cam.CameraType = savedCameraType
    end
    savedCameraType = nil
end
ReplicatedStorage:WaitForChild(Remotes.Names.BirdGrabState).OnClientEvent:Connect(function(payload)
    local grabbed  = payload and payload.grabbed
    local tapsLeft = (payload and payload.tapsLeft) or 0
    if grabbed then
        ensureGrabBillboard()
        if grabUI.btn then
            grabUI.btn.Text = tostring(tapsLeft)
        end
        -- Carry-bounds for the stroke red-lerp. Initial grab fire carries
        -- both startY + killY; subsequent tap-decrement fires omit them
        -- (server skips the field) so we keep the cached values across
        -- updates.
        if payload.startY then grabUI.startY = payload.startY end
        if payload.killY  then grabUI.killY  = payload.killY  end
        startGrabCamera()
    else
        destroyGrabBillboard()
        stopGrabCamera()
    end
end)
-- Forward-declare so the listener (defined after updateBossBar) can call it.
local updateBossBar  -- (declared `local` to be overwritten with the real fn below)
-- Latch for the post-boss "CLEARED" swap on the boss bar slot. Server
-- fires a one-shot bossCleared=true on the broadcast immediately after
-- the final boss dies; the client holds the swap for ~3s so it stays
-- visible during the natural HUD churn that follows boss death.
local bossClearedShownUntil = nil
-- Build the inline-dots RichText fragment based on the current stage.
-- "Start with one dot" per Matthew = stage 1 → 1 yellow dot.
local function buildStageDotsRich(state)
    local total = 3
    local filled = math.min(math.max(state.stage or 1, 1), total)
    -- Final-stage waves cleared but final boss hasn't started yet → all 3 lit.
    if state.wave and state.totalWaves and state.wave >= state.totalWaves
       and not state.inProgress and filled >= 3 then
        filled = 3
    end
    local segments = {}
    for i = 1, total do
        if i <= filled then
            segments[i] = "<font color='#ffd755'>●</font>"
        else
            segments[i] = "<font color='#555555'>●</font>"
        end
    end
    return table.concat(segments, " ")
end
-- Red palette for all boss HP bars (map 3 used to be baby-blue countdown,
-- now reverted to a real HP gauge per Matthew).
local HP_FILL_COLOR = Color3.fromRGB(220,  50,  70)
local HP_BG_COLOR   = Color3.fromRGB( 40,  16,  18)

-- Drives the boss HP bar. Map 3 reads HP from BirdBossCountdown payload
-- (the bird's Health attribute). Other maps use state.bossHealth from
-- WaveState (FinalBossState.instance attributes).
function updateBossBar(state)
    -- One-shot CLEARED swap: server fires bossCleared=true on the broadcast
    -- right after the final boss dies. Show "CLEARED" in the bar slot and
    -- latch it locally for ~3s so the next normal broadcast (which has
    -- bossCleared=false) doesn't immediately hide it.
    -- Pickle Lord defeat: dedicated bottom bar handles the fade-
    -- out; suppress the top-HUD CLEARED latch so we don't get a
    -- surprise "CLEARED" tag in the top-right corner where no bar
    -- was visible the whole fight. handleBossCleared returns true
    -- iff Pickle Lord was active (and it has done the fade-out).
    if state.bossCleared then
        if not PickleLordEntrance.handleBossCleared() then
            bossClearedShownUntil = os.clock() + 3
        end
    end
    -- Pickle Lord uses its own bottom-center bar — suppress the top
    -- mini bar entirely while he's the active boss. The module pulls
    -- bossHealth/bossMaxHealth from the same WaveState fields.
    if PickleLordEntrance.isActive() then
        bossHpBg.Visible = false
        bossHpPctLabel.Visible = false
        bossClearedLabel.Visible = false
        watchLabel.Visible = false
        PickleLordEntrance.applyHpUpdate(state)
        return
    end
    local clearedVisible = bossClearedShownUntil
        and os.clock() < bossClearedShownUntil
    if clearedVisible then
        bossHpBg.Visible = true
        bossHpBg.BackgroundColor3 = Color3.fromRGB(60, 90, 50)
        bossHpFill.Size = UDim2.new(1, -2, 1, -2)
        bossHpFill.BackgroundColor3 = Color3.fromRGB(120, 200, 100)
        bossClearedLabel.Visible = true
        bossHpPctLabel.Visible = false
        watchLabel.Visible = false
        return
    end
    bossClearedLabel.Visible = false
    if not state.finalBossActive then
        bossHpBg.Visible = false
        bossHpPctLabel.Visible = false
        watchLabel.Visible = false
        return
    end
    bossHpBg.Visible = true
    bossHpBg.BackgroundColor3 = HP_BG_COLOR
    bossHpFill.BackgroundColor3 = HP_FILL_COLOR
    watchLabel.Visible = false
    local hp, maxHp
    if state.mapId == 3 and birdBossStatus.active then
        hp    = birdBossStatus.hp
        maxHp = birdBossStatus.maxHp
        -- Bird is only damageable during dive/grab/carry/drop. Gray the
        -- bar fill while it's hovering so players know shooting is
        -- pointless; flip back to red the moment the swoop starts.
        if birdBossStatus.damageable then
            bossHpFill.BackgroundColor3 = HP_FILL_COLOR
        else
            bossHpFill.BackgroundColor3 = Color3.fromRGB(140, 140, 140)
        end
    else
        hp    = state.bossHealth or 0
        maxHp = state.bossMaxHealth or 0
    end
    local frac = (maxHp and maxHp > 0)
                 and math.max(0, math.min(hp / maxHp, 1))
                 or 1
    bossHpFill.Size = UDim2.new(frac, -2, 1, -2)
    -- HP percent overlay — XX.X% format. Hidden when no real HP yet so
    -- a transient zero broadcast doesn't flash "0.0%" before the actual
    -- HP arrives from the boss-spawn broadcast.
    if maxHp and maxHp > 0 then
        bossHpPctLabel.Text = string.format("%.1f%%", frac * 100)
        bossHpPctLabel.Visible = true
    else
        bossHpPctLabel.Visible = false
    end
end

-- Bird boss status listener — payload {active, hp, maxHp}.
ReplicatedStorage:WaitForChild(Remotes.Names.BirdBossCountdown).OnClientEvent:Connect(function(payload)
    birdBossStatus.active     = payload and payload.active or false
    birdBossStatus.hp         = (payload and payload.hp) or 0
    birdBossStatus.maxHp      = (payload and payload.maxHp) or 1
    birdBossStatus.damageable = (payload and payload.damageable) or false
    if currentWaveState then
        updateBossBar(currentWaveState)
    end
end)

-- Carrying-ammo indicator: shown below the wave HUD when the player is holding
-- an ammo package from a pile. Clears when they load it into a tower.
-- Sits inline to the RIGHT of the wave HUD so the whole top strip is horizontal.
local carryFrame = Instance.new("Frame")
carryFrame.Size = UDim2.fromOffset(140, 46)
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

    -- Panel always-on: never hide it, even pre-game.
    -- EXCEPTION: Pickle Swamp / Infinite arena (mapId 4) has its own
    -- HUD (InfiniteHUD's "WAVE N (TestType)" panel + "THE PICKLE
    -- SWAMP" idle label). Showing the regular wave HUD up there with
    -- "Entrance to the Tree of Life" leaks lobby chrome into the
    -- balance studio. Hide the whole frame on Map 4.
    if state.mapId == 4 then
        waveFrame.Visible = false
        return
    end
    waveFrame.Visible = true
    updateBossBar(state)

    -- Run-time pause/resume: pause when a boss is freshly cleared, resume
    -- the moment the player arrives on a new map (mapId changes from
    -- whatever it was). The bossCleared flag is a one-shot the server
    -- sets exactly during the post-kill broadcast, so it fires the pause
    -- once even though the WaveState event arrives many times after.
    if state.bossCleared then
        runTimePaused = true
    end
    if state.mapId and state.mapId ~= runTimeLastMapId then
        if runTimeLastMapId ~= nil then
            -- Real map switch (not the initial broadcast). Resume the timer.
            runTimePaused = false
        end
        runTimeLastMapId = state.mapId
    end

    local hasMap = state.map and state.map ~= ""
    -- Lobby/hub gate: a fresh-spawned player who hasn't entered the TD
    -- room yet sees ONLY the entrance label — no wave/dot info, even
    -- though the wave system has a default currentMapName populated.
    -- HasBeenGrantedStock flips to true as soon as the player gets their
    -- starter tower (which only happens after they go through the portal),
    -- so it's a reliable "have I started the run yet?" signal.
    local inLobby = not player:GetAttribute("HasBeenGrantedStock")
    local mapName = hasMap and state.map or "Entrance to the Tree of Life"
    -- Pickle Lord override: while he's the active boss, the map
    -- name slot reads "The Pickle Lord" instead of "Canopy Nest
    -- (Night)" — the boss IS the venue from a UI standpoint, and
    -- the dedicated HP bar tucks right under this label.
    if PickleLordEntrance.isActive() then
        mapName = "The Pickle Lord"
    end
    -- Entrance / hub: just the entrance label, no wave/dot info.
    if not hasMap or inLobby then
        mapLabel.Text = "Entrance to the Tree of Life"
        mapLabel.Size = UDim2.new(1, -16, 1, 0)
        mapLabel.Position = UDim2.fromOffset(8, 0)
        mapLabel.TextXAlignment = Enum.TextXAlignment.Center
        return
    end
    local dots = buildStageDotsRich(state)
    local SEP = "  ·  "
    -- Boss mode = no wave/dot text; the wide boss HP bar takes the right.
    -- The label only shows the map name (left-aligned, narrowed so it
    -- doesn't overlap the bar).
    --
    -- ALSO applies during the CLEARED latch window — for the 3 seconds
    -- after a boss dies, the bar shows "CLEARED" instead of HP, and we
    -- shouldn't render the wave dots over the same area. Without this
    -- guard the layout briefly flashes "<map> · ● · CLEARED" before the
    -- normal post-boss broadcast lands.
    local clearedVisible = bossClearedShownUntil
        and os.clock() < bossClearedShownUntil
    -- Pickle Lord: enter the boss-label branch even though
    -- StageState.finalBossActive flips false the moment the bird
    -- boss dies (Pickle Lord runs on a separate system, not the
    -- wave-state final-boss flag). Without this, the label fell
    -- through to the regular Wave-N path and read empty during the
    -- run-boss fight.
    if state.finalBossActive or clearedVisible or PickleLordEntrance.isActive() then
        mapLabel.Text = mapName
        if PickleLordEntrance.isActive() then
            -- Pin the label to the TOP 30 stud of the wave HUD
            -- frame. The frame is 76 tall while Pickle Lord is
            -- active (to fit the embedded HP-bar row beneath);
            -- a (1,-16,1,0) sized label would vertically-center
            -- its text at Y=38 — INSIDE the HP-bar row — and
            -- the text would be hidden behind the bar. Fixed
            -- 30-stud height keeps the label up top where the
            -- wave HUD's mapLabel normally sits.
            mapLabel.Size = UDim2.new(1, -16, 0, 30)
            mapLabel.Position = UDim2.fromOffset(8, 0)
            mapLabel.TextXAlignment = Enum.TextXAlignment.Center
        else
            mapLabel.Size = UDim2.new(1, -240, 1, 0)   -- leave 240 stud for the bar
            mapLabel.Position = UDim2.fromOffset(8, 0)
            mapLabel.TextXAlignment = Enum.TextXAlignment.Left
        end
        return
    end
    -- Normal mode: full-width centered, dots inline between map and wave.
    mapLabel.Size = UDim2.new(1, -16, 1, 0)
    mapLabel.Position = UDim2.fromOffset(8, 0)
    mapLabel.TextXAlignment = Enum.TextXAlignment.Center

    local function setLabel(waveText)
        mapLabel.Text = mapName .. SEP .. dots .. SEP .. waveText
    end
    if state.inProgress then
        setLabel(string.format("Wave %d / %d", state.wave, state.totalWaves))
    elseif state.pendingCountdown and state.pendingCountdown > 0 then
        task.spawn(function()
            local remaining = state.pendingCountdown
            while remaining > 0 and countdownToken == myToken do
                setLabel(string.format("Wave %d in %d…", state.wave + 1, remaining))
                task.wait(1)
                remaining = remaining - 1
            end
        end)
    elseif state.wave and state.wave >= (state.totalWaves or 5) then
        setLabel("All waves cleared!")
    elseif (state.wave or 0) == 0 then
        setLabel(string.format("Wave 0 / %d", state.totalWaves or 5))
    else
        setLabel(string.format("Wave %d cleared", state.wave))
    end
end)

-- Re-render the wave HUD when HasBeenGrantedStock flips. Player goes
-- through the portal → server grants stock → this attribute changes →
-- we replay the cached WaveState through the same handler so the
-- lobby-gate check picks up the new value. Without this, the label
-- stays at "The Entrance…" until the next WaveState event (which
-- doesn't fire until wave 1 starts), leaving a stale lobby label
-- visible during the placement window.
player:GetAttributeChangedSignal("HasBeenGrantedStock"):Connect(function()
    if not currentWaveState then return end
    -- Fire the bindable event manually. ReplicatedStorage's WaveState
    -- is a RemoteEvent (server→client only); we can't re-fire it
    -- client-side. Instead, fire a sentinel BindableEvent that the
    -- handler also listens for — but that's overkill. Easier: just
    -- inline a lightweight re-render by reusing the label logic.
    local state = currentWaveState
    local hasMap = state.map and state.map ~= ""
    if not hasMap then return end  -- no real map yet, nothing to upgrade to
    -- Force the WaveState handler to re-run by clearing currentWaveState
    -- and re-publishing through OnClientEvent. Roblox doesn't expose a
    -- way to re-fire a Remote locally, so we settle for a direct relabel
    -- using the same branch logic the handler uses.
    countdownToken = countdownToken + 1
    local mapName = state.map
    local dots = buildStageDotsRich(state)
    local SEP = "  ·  "
    mapLabel.Size = UDim2.new(1, -16, 1, 0)
    mapLabel.Position = UDim2.fromOffset(8, 0)
    mapLabel.TextXAlignment = Enum.TextXAlignment.Center
    if state.finalBossActive then
        mapLabel.Text = mapName
        mapLabel.Size = UDim2.new(1, -240, 1, 0)
        mapLabel.TextXAlignment = Enum.TextXAlignment.Left
    elseif state.inProgress then
        mapLabel.Text = mapName .. SEP .. dots .. SEP
            .. string.format("Wave %d / %d", state.wave, state.totalWaves)
    elseif (state.wave or 0) == 0 then
        mapLabel.Text = mapName .. SEP .. dots .. SEP
            .. string.format("Wave 0 / %d", state.totalWaves or 5)
    else
        mapLabel.Text = mapName .. SEP .. dots
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
    panel.Size = UDim2.fromOffset(IS_MOBILE and 340 or 480, 96)
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
    title.Position = UDim2.fromOffset(8, 8)
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
    sub.Position = UDim2.fromOffset(8, 56)
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
    label.Position = UDim2.fromScale(0, 0.4)
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
    player             = player,
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
targetModeFrame.Size = UDim2.fromOffset(440, 310)
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
hudTitle.Size = UDim2.fromOffset(210, 30)  -- fixed width to leave room for info button
hudTitle.Position = UDim2.fromOffset(16, 8)
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
    d.Position = UDim2.fromOffset(16, 44)
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
closeBtn.Size = UDim2.fromOffset(80, 26)
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
    bullseyeBtn.Size = UDim2.fromOffset(104, 28)
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
    sellBtn.Size = UDim2.fromOffset(116, 28)  -- tight to text + coin (was 140 with a big gap)
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
    sellCostCoin.Size = UDim2.fromOffset(20, 20)
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
statsFrame.Position = UDim2.fromOffset(16, 56)
statsFrame.BackgroundTransparency = 1
statsFrame.Parent = targetModeFrame

do
    local l = Instance.new("UIListLayout")
    l.FillDirection = Enum.FillDirection.Vertical
    l.HorizontalAlignment = Enum.HorizontalAlignment.Left
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Padding = UDim.new(0, 1)  -- compressed (was 4) so 10 stat rows fit
    l.Parent = statsFrame
end

local function makeStatLabel(orderIdx)
    local lbl = Instance.new("TextLabel")
    -- Compressed line height + font (was 20×15) so the stats list
    -- fits the 9-row default plus the new Target row without
    -- overflowing the panel into the TARGET[G] / PICK UP[X] buttons.
    lbl.Size = UDim2.new(1, 0, 0, 16)
    lbl.BackgroundTransparency = 1
    lbl.Text = ""
    lbl.TextColor3 = Color3.fromRGB(220, 230, 240)
    lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    lbl.TextStrokeTransparency = 0.5
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
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
    target    = makeStatLabel(10),  -- "Target: X" — manual target if set
}

-- Forward-decl for the HUD update (line below uses
-- manualTargetsByTower for the Target row; the actual table is
-- assigned further down at line ~3480 alongside the other manual-
-- target state). Using a single bare `local` here so the variable
-- exists at the chunk level for both definers.
local manualTargetsByTower

-- Mode buttons column on the right. Five buttons × 38px + 4 × 8px padding = 222px.
-- Panel is 310 tall; title+divider+padding uses ~66px; bottom padding 16px leaves
-- enough room for the 222 column. The poetic ordering of buttons (First, Last,
-- Center, Strongest, Weakest) puts Center literally at the middle.
local modeRow = Instance.new("Frame")
modeRow.Size = UDim2.fromOffset(160, 222)
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
-- Multi-select state declared HERE (well above its real init at the
-- bullseye state block ~line 3378) so refreshHUD's multi-mode bail —
-- `if #multiSelectedTowers >= 2 then return end` — can capture this
-- as an upvalue. Otherwise refreshHUD's free-variable lookup at
-- definition time would resolve to the global `multiSelectedTowers`
-- which is nil → `attempt to get length of a nil value`.
local multiSelectedTowers = {}

-- Order is poetic: First and Last bracket the path; Center sits literally
-- at the middle; Strongest/Weakest are the HP-based pair below.
-- Server enum stays "First"; UI label is "FRONT" (player-facing renaming
-- per Matthew — easier to read than "First" which sounds temporal).
local MODES = {"First", "Last", "Center", "Strongest", "Weakest"}
local MODE_LABELS = {
    First     = "FRONT",
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

-- 3D selection visuals (corner-bracket cage + blue range ring on floor).
-- Extracted to sibling module. See TreeOfLife_Client/SelectionVisuals.lua.
local SelectionVisuals = require(script:WaitForChild("SelectionVisuals"))
local buildSelectionVisuals = SelectionVisuals.build
local clearSelectionVisuals = SelectionVisuals.clear

local function refreshHUD()
    if not currentTargetTower or not currentTargetTower.Parent then return end
    -- Multi-select gate: when ≥2 towers are ctrl-selected, the panel is
    -- in MULTIPLE TOWERS mode — title is "MULTIPLE TOWERS", coin shows
    -- summed pickup cost, body lists the selected towers, and the
    -- per-tower stats panel + (i) button are hidden. refreshHUD's
    -- per-attribute hooks on the primary tower would otherwise stomp
    -- the title and cost on every attribute tick. Skip the whole
    -- single-tower repaint while multi is active.
    if #multiSelectedTowers >= 2 then return end
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
    local equipType = tower:GetAttribute("EquippedType") or ""
    local equipRar  = tower:GetAttribute("EquippedRarity")  -- int 1..5 or nil
    local aoe       = tower:GetAttribute("AoeRadius")       -- nil if single-target
    local stunDur   = tower:GetAttribute("StunDuration")    -- nil if no Stun special picked
    local knockDist = tower:GetAttribute("Knockback")       -- nil if no Knockback special picked

    -- Format "Stat: value [+N%] [-M]" — bonus tag green + bold +
    -- small. Optional penalty tag red + bold (used for the Range
    -- row when Pickle Lord's RangeDecayMultiplier has shrunk the
    -- effective range; expressed as ABSOLUTE STUDS lost, not a
    -- percent — easier to read against the displayed range).
    local BONUS_GREEN  = "#82e06c"
    local PENALTY_RED  = "#e06c6c"
    local function statLine(label, value, bonus, penaltyStuds)
        local base = string.format("%s: %s", label, value)
        if bonus and bonus > 0 then
            base = string.format('%s  <font color="%s"><b>[+%d%%]</b></font>',
                base, BONUS_GREEN, math.floor(bonus + 0.5))
        end
        if penaltyStuds and penaltyStuds > 0 then
            base = string.format('%s  <font color="%s"><b>[-%d]</b></font>',
                base, PENALTY_RED, math.floor(penaltyStuds + 0.5))
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
    -- ACTUAL effective range = stamped Range × player's
    -- RangeDecayMultiplier (Pickle Lord shrinks it 10% per tick
    -- after the 1-min grace). Displayed as the live number so the
    -- player sees what their tower can ACTUALLY hit right now.
    -- Penalty tag shows studs lost to decay (not a %), so a
    -- range-50 tower at one decay tick reads "Range: 45 [-5]".
    local rangeDecay   = player:GetAttribute("RangeDecayMultiplier") or 1
    local effRange     = range * rangeDecay
    local decayLoss    = math.max(0, range - effRange)
    hudLabels.range.Text    = statLine("Range",     tostring(math.floor(effRange + 0.5)),   rangeBonus, decayLoss)
    hudLabels.fireRate.Text = statLine("Shots/sec", string.format("%.2f", fireRate),       fireRateBonus)
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

    -- Current target row. Manual target stored in
    -- manualTargetsByTower[tower]. Falls back to "—" when no
    -- manual target is set (tower is using its TargetMode logic).
    -- Display name precedence: mob's DisplayName attribute > mob's
    -- Name > "?". Pickle Lord body has DisplayName="The Pickle
    -- Lord"; eggs / regular mobs use mob.Name.
    do
        local manual = manualTargetsByTower[tower]
        if manual and manual.Parent then
            local label = manual:GetAttribute("DisplayName")
                          or manual.Name or "?"
            toggleLine(hudLabels.target, true,
                string.format("Target: %s", label))
        else
            toggleLine(hudLabels.target, true,
                string.format("Target: %s (auto)",
                    tower:GetAttribute("TargetMode") or "First"))
        end
    end

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

-- Forward-decl'd selection-helper dispatcher. Bundled into ONE table
-- local because separate `local fn` decls hit the Luau 200-register
-- ceiling (see CLAUDE.md). Lua captures the table as an upvalue at
-- openForTower / closeTargetModeHUD's definition time; the field
-- bodies land by the time any user action fires select/close.
--
-- Fields (all nil at decl time, real fns assigned in the bullseye
-- do-block further down):
--   cancelBullseye      — close the cursor + reset the TARGET button
--                         color when the player deselects mid-pick
--   clearIndicators     — destroy all visible bullseye indicators on
--                         deselect (each tower owns its own indicator
--                         only while it's the selected tower)
--   restoreIndicator    — on re-select, re-attach the bullseye to the
--                         cached mob if that tower had an active manual
--                         target on its prior selection
--   updateMultiButtons  — refresh the action-button labels (TARGET vs
--                         CHANGE ALL TARGETS, PICK UP vs PICK UP SELECTED)
--                         based on the current ctrl-click selection size
local selFns = {
    cancelBullseye     = nil,
    clearIndicators    = nil,
    restoreIndicator   = nil,
    updateMultiButtons = nil,
    -- Per-tower SelectionBox adornees for ctrl-click multi-select.
    -- The PRIMARY tower (currentTargetTower) keeps its full
    -- SelectionVisuals.build cage + range ring; secondaries get a
    -- lightweight SelectionBox wireframe each so the player can SEE
    -- which towers are batched without the screen filling with rings.
    multiBoxes = {},
}

local function openForTower(tower)
    -- Hook tower-destruction so smash / sell mid-selection auto-
    -- updates the HUD state instead of leaving a "ghost" selection
    -- on a destroyed model. Cleanup helper lives as a selFns field
    -- (assigned right after closeTargetModeHUD is defined below) —
    -- table-field access skips spending a top-level register slot,
    -- which the script doesn't have spare any more.
    if tower and tower.Parent then
        tower.AncestryChanged:Connect(function(_, parent)
            if not parent and selFns.handleSelectionTowerDestroyed then
                selFns.handleSelectionTowerDestroyed(tower)
            end
        end)
    end
    disconnectAttrs()
    -- Tower selection changed → tear down any indicator left over from a
    -- prior tower's manual target (it belongs to the previous selection,
    -- not this one). Then if THIS tower has a cached manual target on
    -- file, re-attach the bullseye to that mob. Result: the indicator
    -- always follows the currently-selected tower.
    if selFns.clearIndicators then selFns.clearIndicators() end
    currentTargetTower = tower
    if selFns.restoreIndicator then selFns.restoreIndicator() end
    if selFns.updateMultiButtons then selFns.updateMultiButtons() end
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
        -- Player-level decay attribute also drives the displayed
        -- "Range: N [-M]" so subscribe to it too. RangeDecayMultiplier
        -- is set by Pickle Lord's range-decay loop. When it changes,
        -- redraw both the HUD row AND the range circle.
        table.insert(attrConns,
            player:GetAttributeChangedSignal("RangeDecayMultiplier"):Connect(function()
                refreshHUD()
                if tower and tower.Parent then
                    buildSelectionVisuals(tower)
                end
            end))
    end
end

-- (forward decls are above openForTower — see the block by attrConns)

local function closeTargetModeHUD()
    disconnectAttrs()
    clearSelectionVisuals()
    if selFns.cancelBullseye then selFns.cancelBullseye() end
    if selFns.clearIndicators then selFns.clearIndicators() end
    multiSelectedTowers = {}
    if selFns.clearAllMultiBoxes then selFns.clearAllMultiBoxes() end
    if selFns.updateMultiButtons then selFns.updateMultiButtons() end
    -- Keep currentTargetTower set even after close so G can re-enter
    -- target mode for the last-selected tower without needing to click
    -- the tower first.
    targetModeGui.Enabled = false
end

closeBtn.MouseButton1Click:Connect(closeTargetModeHUD)

-- Selection tower-destroy cleanup. Hung off selFns rather than as a
-- top-level local because the script is at the Luau 200-register
-- ceiling — selFns is already a module-scope local, so adding a
-- field to it is free. Called from openForTower's AncestryChanged
-- hook + the ctrl-click multi-select branch's hookDestroy() helper.
-- Walks multiSelectedTowers to drop dead refs, then re-evaluates:
--   • 0 towers left  → closeTargetModeHUD
--   • 1 tower  left  → collapse to single-select on the survivor
--   • 2+ towers left → keep multi-select; refresh button labels
selFns.handleSelectionTowerDestroyed = function(_deadTower)
    for i = #multiSelectedTowers, 1, -1 do
        local t = multiSelectedTowers[i]
        if not (t and t.Parent) then
            table.remove(multiSelectedTowers, i)
            if selFns.removeMultiBox then selFns.removeMultiBox(t) end
        end
    end
    local primaryAlive = currentTargetTower and currentTargetTower.Parent
    local count = #multiSelectedTowers
    if count == 0 and not primaryAlive then
        closeTargetModeHUD()
        return
    end
    if count == 1 then
        local survivor = multiSelectedTowers[1]
        multiSelectedTowers = {}
        if selFns.clearAllMultiBoxes then selFns.clearAllMultiBoxes() end
        if survivor and survivor.Parent then
            openForTower(survivor)
        end
        return
    end
    if not primaryAlive and multiSelectedTowers[1] then
        openForTower(multiSelectedTowers[1])
    end
    if selFns.updateMultiButtons then selFns.updateMultiButtons() end
end

-- ============================================================
-- RANGE-DECAY TOWER VISUAL — Pickle Lord shrinks tower range
-- every 30 game-sec (after a 1-min grace). Each tick increments
-- the player's RangeDecayTickCount attribute. We mirror that as
-- a green Highlight on every owned tower; the highlight grows
-- in intensity (lower transparency, brighter green) with each
-- tick so the player can see the timer ticking down on their
-- towers visually. Wrapped in a do-block so its helpers / table
-- don't claim top-level registers (script is at the Luau
-- 200-register ceiling).
-- ============================================================
do
    local highlightsByTower = {}  -- [towerModel] = Highlight
    local smokesByTower     = {}  -- [towerModel] = { smokeAttachment, smokeEmitter }

    local function tickIntensity(ticks)
        -- 0 ticks → no visual.  N ticks → ramp by N*0.12 (alpha).
        -- Capped so even after many ticks the tower stays readable.
        local alpha = math.clamp(ticks * 0.12, 0, 0.7)
        return alpha
    end

    local function clearAllRangeDecayHighlights()
        for tower, hl in pairs(highlightsByTower) do
            if hl and hl.Parent then hl:Destroy() end
            highlightsByTower[tower] = nil
        end
        for tower, refs in pairs(smokesByTower) do
            if refs.attachment and refs.attachment.Parent then
                refs.attachment:Destroy()
            end
            smokesByTower[tower] = nil
        end
    end

    local function refreshAllRangeDecayHighlights()
        local ticks = player:GetAttribute("RangeDecayTickCount") or 0
        if ticks <= 0 then
            clearAllRangeDecayHighlights()
            return
        end
        local alpha = tickIntensity(ticks)
        -- Green ramps from soft lime → bright pickle green as ticks
        -- accumulate. Outline transparency ramps faster than fill so
        -- the silhouette pops first, then the body fills in.
        local color = Color3.fromRGB(120, 230, 80)
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            if base:IsA("BasePart") then
                local model = base:FindFirstAncestorOfClass("Model")
                while model and not model:GetAttribute("TowerType") do
                    model = model.Parent
                            and model.Parent:FindFirstAncestorOfClass("Model")
                end
                if model and model.Parent
                   and model:GetAttribute("Owner") == player.UserId then
                    local hl = highlightsByTower[model]
                    if not (hl and hl.Parent) then
                        hl = Instance.new("Highlight")
                        hl.Name = "RangeDecayMark"
                        hl.FillColor = color
                        hl.OutlineColor = Color3.fromRGB(180, 255, 130)
                        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        hl.Adornee = model
                        hl.Parent = model
                        highlightsByTower[model] = hl
                    end
                    hl.FillTransparency = 1 - alpha           -- 1.0 (none) → 0.3 (strong)
                    hl.OutlineTransparency = math.max(0, 0.6 - alpha * 1.4)

                    -- Foggy smoke VFX on top of the tower. Drifts
                    -- upward, a translucent green haze that gets
                    -- denser as ticks accumulate. ParticleEmitter
                    -- on an Attachment so it follows whichever
                    -- BasePart we anchor to. Re-uses the same
                    -- attachment across ticks; we just bump its
                    -- emitter Rate as decay deepens.
                    local refs = smokesByTower[model]
                    if not (refs and refs.attachment and refs.attachment.Parent) then
                        local anchor = base
                        local att = Instance.new("Attachment")
                        att.Name = "RangeDecaySmoke"
                        att.Position = Vector3.new(0, 1.0, 0)  -- atop the tower base
                        att.Parent = anchor
                        local em = Instance.new("ParticleEmitter")
                        em.Texture = "rbxasset://textures/particles/smoke_main.dds"
                        em.Color = ColorSequence.new({
                            ColorSequenceKeypoint.new(0,
                                Color3.fromRGB(140, 230, 110)),
                            ColorSequenceKeypoint.new(1,
                                Color3.fromRGB(60, 110, 50)),
                        })
                        em.Size = NumberSequence.new({
                            NumberSequenceKeypoint.new(0, 1.5),
                            NumberSequenceKeypoint.new(0.5, 3.5),
                            NumberSequenceKeypoint.new(1, 4.5),
                        })
                        em.Transparency = NumberSequence.new({
                            NumberSequenceKeypoint.new(0, 0.4),
                            NumberSequenceKeypoint.new(0.7, 0.6),
                            NumberSequenceKeypoint.new(1, 1),
                        })
                        em.Lifetime = NumberRange.new(1.6, 2.4)
                        em.Speed = NumberRange.new(1.0, 2.0)
                        em.SpreadAngle = Vector2.new(20, 20)
                        em.EmissionDirection = Enum.NormalId.Top
                        em.Acceleration = Vector3.new(0, 0.5, 0)  -- slight upward drift
                        em.LightEmission = 0.3
                        em.LightInfluence = 0.4
                        em.Parent = att
                        refs = { attachment = att, emitter = em }
                        smokesByTower[model] = refs
                    end
                    -- Rate ramps with ticks: tick 1 → 2 puffs/sec,
                    -- tick 6+ → 12 puffs/sec (capped). Heavier
                    -- smoke on more-decayed towers reads as "this
                    -- one's worse off".
                    refs.emitter.Rate = math.clamp(ticks * 2, 2, 12)
                end
            end
        end
        -- Sweep dead refs (towers destroyed since last tick).
        for tower, _ in pairs(highlightsByTower) do
            if not (tower and tower.Parent) then
                highlightsByTower[tower] = nil
            end
        end
        for tower, _ in pairs(smokesByTower) do
            if not (tower and tower.Parent) then
                smokesByTower[tower] = nil
            end
        end
    end

    -- Refresh on RangeDecayTickCount change AND on new towers
    -- entering the workspace (newly-placed towers also need the
    -- highlight if decay has already started).
    player:GetAttributeChangedSignal("RangeDecayTickCount"):Connect(refreshAllRangeDecayHighlights)
    CollectionService:GetInstanceAddedSignal(Tags.Tower):Connect(function()
        -- Slight defer so the tower model has settled before we walk
        -- it (the tagged part fires immediately; the model might
        -- still be assembling its descendants).
        task.defer(refreshAllRangeDecayHighlights)
    end)
end

-- Shared bullseye/tower-picker state. Declared at module scope (not
-- inside the do-block) so the tower-picker do-block below can read
-- awaitingMobPick + mobPickConsumedAt to decide whether a click was
-- already consumed by the mob-pick handler.
--   awaitingMobPick: true while the bullseye cursor is live, so the
--     next MB1 click on a mob assigns it as the currentTargetTower's
--     manual target. Flips the button color.
--   mobPickConsumedAt: last-consumed click timestamp; suppresses the
--     tower-select handler for the same click (same InputBegan frame).
--   manualTargetIndicators: mob → BillboardGui map. Currently visible
--     indicators only — cleared on tower deselect, re-attached on
--     re-select. (Was "one indicator stays on the mob across selections,"
--     but per Matthew's playtest: the bullseye should belong to the
--     SELECTED tower, not stick to whatever mob you last targeted with
--     anyone. Selecting another tower with its own active manual target
--     swaps the indicator to that tower's target.)
--   manualTargetsByTower: tower → mob cache. Mirrors the SERVER's
--     ctx.towerManualTargets for the LOCAL player only — lets the HUD
--     restore the right indicator on re-select. Stale entries (mob died
--     mid-deselect) get pruned on read.
--   multiSelectedTowers: array of towers when ctrl-click adds to the
--     active selection. The "primary" (currentTargetTower) is element
--     [1]; subsequent ctrl-clicks append. When #>=2 the HUD button
--     labels swap to CHANGE ALL TARGETS / PICK UP SELECTED, and the
--     G / X hotkeys + button clicks fan out across every entry.
local awaitingMobPick = false
local mobPickConsumedAt = 0
local manualTargetIndicators = {}
manualTargetsByTower = {}
-- (multiSelectedTowers declared higher up so refreshHUD can read it)

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
    bb.Size = UDim2.fromOffset(48, 48)
    -- TargetAimOffsetY (set on the boss body) lifts the indicator
    -- from a buried body center up to roughly head height. Default
    -- 4 stud above the mob for normal mobs / eggs / etc.
    local aimYOffset = mob:GetAttribute("TargetAimOffsetY") or 4
    bb.StudsOffsetWorldSpace = Vector3.new(0, aimYOffset, 0)
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

-- Wire the forward-declarations from openForTower / closeTargetModeHUD.
-- These run on every tower select / deselect cycle and keep the bullseye
-- indicator coupled to the currently-selected tower's manual target.
selFns.clearIndicators = clearAllManualTargetIndicators
selFns.restoreIndicator = function()
    if not currentTargetTower or not currentTargetTower.Parent then return end
    local cachedMob = manualTargetsByTower[currentTargetTower]
    if not cachedMob then return end
    -- Stale entry (mob died while another tower was selected) → prune.
    if not cachedMob.Parent then
        manualTargetsByTower[currentTargetTower] = nil
        return
    end
    attachManualTargetIndicator(cachedMob)
end
-- Toggle visibility of every active manual-target indicator without
-- destroying them. Used to hide indicators while the player is grabbed
-- by the bird (player can't usefully re-aim mid-carry); restored on
-- release. Server-side target references are preserved.
local function setManualTargetIndicatorsVisible(visible)
    for _, bb in pairs(manualTargetIndicators) do
        if bb and bb.Parent then
            bb.Enabled = visible
        end
    end
end
-- Hide manual target indicators while the player is grabbed (per Matthew:
-- "hide the target when you're picked up"). Restored on release. Sits
-- here, after setManualTargetIndicatorsVisible's definition; the earlier
-- BirdGrabState listener can't call it because of the forward order.
ReplicatedStorage:WaitForChild(Remotes.Names.BirdGrabState).OnClientEvent:Connect(function(payload)
    local grabbed = payload and payload.grabbed
    setManualTargetIndicatorsVisible(not grabbed)
end)
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
    -- IgnoreGuiInset = true: GUI origin = viewport top-left (matches what
    -- GetMouseLocation returns). With it false, the GUI origin sits BELOW
    -- the topbar, so the bullseye rendered ~36 px below the cursor —
    -- visible as a "cursor jumped down" the moment target mode opens, and
    -- "jumped back" the moment it closes. The earlier comment had this
    -- backwards.
    bullseyeCursorGui.IgnoreGuiInset = true
    bullseyeCursorGui.ResetOnSpawn = false
    bullseyeCursorGui.DisplayOrder = 500
    bullseyeCursorGui.Parent = playerGui
    local label = Instance.new("TextLabel")
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.Size = UDim2.fromOffset(48, 48)
    label.BackgroundTransparency = 1
    label.Text = "◎"
    label.TextColor3 = Color3.fromRGB(255, 220, 120)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.2
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 44
    label.Parent = bullseyeCursorGui
    -- Snap the bullseye to the current mouse position BEFORE hiding the
    -- OS cursor + before the first RenderStepped tick. Without this seed,
    -- the label sits at (0,0) for one frame while the OS cursor vanishes
    -- — visible as a "jump" from where the user clicked to the top-left.
    do
        local m = UserInputService:GetMouseLocation()
        label.Position = UDim2.fromOffset(m.X, m.Y)
    end
    UserInputService.MouseIconEnabled = false
    local RunService = game:GetService("RunService")
    bullseyeCursorConn = RunService.RenderStepped:Connect(function()
        local m = UserInputService:GetMouseLocation()
        label.Position = UDim2.fromOffset(m.X, m.Y)
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
-- Wire the forward-decls. cancelBullseye runs on close (Q / X / Sell /
-- closeBtn) — idempotent no-op when bullseye isn't live. updateMultiButtons
-- swaps the action-button labels + widths between single- and multi-
-- selection modes; called on every selection-set change (open, ctrl-click,
-- close).
selFns.cancelBullseye = function()
    if awaitingMobPick then
        setMobPickMode(false)
    end
end
-- Selection-box helpers for multi-select. SelectionBox is a built-in
-- Roblox class that draws a wireframe cube around its Adornee — much
-- cheaper than re-running the full SelectionVisuals corner-bracket
-- generation per tower, and visually distinct from the primary
-- selection's cage (so the player can tell PRIMARY vs SECONDARY at a
-- glance). Boxes parent to the tower so they auto-clean if the tower
-- gets destroyed.
selFns.addMultiBox = function(tower)
    if not tower or selFns.multiBoxes[tower] then return end
    local sb = Instance.new("SelectionBox")
    sb.Adornee = tower
    sb.Color3 = Color3.fromRGB(120, 220, 150)
    sb.LineThickness = 0.06
    sb.SurfaceColor3 = Color3.fromRGB(120, 220, 150)
    sb.SurfaceTransparency = 0.85
    sb.Parent = tower
    selFns.multiBoxes[tower] = sb
end
selFns.removeMultiBox = function(tower)
    local sb = selFns.multiBoxes[tower]
    if sb then
        if sb.Parent then sb:Destroy() end
        selFns.multiBoxes[tower] = nil
    end
end
selFns.clearAllMultiBoxes = function()
    for tower, sb in pairs(selFns.multiBoxes) do
        if sb and sb.Parent then sb:Destroy() end
        selFns.multiBoxes[tower] = nil
    end
end

selFns.updateMultiButtons = function()
    local count = #multiSelectedTowers
    if count >= 2 then
        -- Inline helpers (totalPickupCost + ensureMultiList) live INSIDE
        -- this function to avoid claiming module-scope register slots.
        -- Both were broken out as locals once but pushed the file over
        -- the Luau 200-register ceiling. Rebuilt inline; selFns.multiListLabel
        -- caches the label across calls so we only build it once.
        local totalCost = 0
        for _, t in ipairs(multiSelectedTowers) do
            if t and t.Parent then
                totalCost = totalCost + (t:GetAttribute("NoAmmo") and 1 or 3)
            end
        end
        local lbl = selFns.multiListLabel
        if not (lbl and lbl.Parent) then
            lbl = Instance.new("TextLabel")
            lbl.Name = "MultiTowerList"
            lbl.Size = UDim2.new(1, -32, 1, -110)
            lbl.Position = UDim2.fromOffset(16, 56)
            lbl.BackgroundTransparency = 1
            lbl.TextColor3 = Color3.fromRGB(220, 230, 245)
            lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            lbl.TextStrokeTransparency = 0.5
            lbl.Font = Enum.Font.Gotham
            lbl.TextSize = 16
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.TextYAlignment = Enum.TextYAlignment.Top
            lbl.RichText = true
            lbl.TextWrapped = true
            lbl.Visible = false
            lbl.Parent = targetModeFrame
            selFns.multiListLabel = lbl
        end
        -- Multi-select layout. Title flips to "MULTIPLE TOWERS"; stats
        -- and mode-row hide; tower-list label fills the body; panel
        -- height collapses to fit (no empty middle). Buttons keep their
        -- y=-52-from-bottom anchor so they ride the new bottom edge.
        hudTitle.Text = "MULTIPLE TOWERS"
        bullseyeBtn.Text = "CHANGE ALL TAR<font color='#ffdd55'>G</font>ETS [G]"
        bullseyeBtn.Size = UDim2.fromOffset(200, 28)
        sellBtn.Text = "PICK UP SELECTED [X]"
        sellBtn.Size = UDim2.fromOffset(200, 28)
        sellBtn.Position = UDim2.new(0, 218, 1, -52)
        if statsFrame then statsFrame.Visible = false end
        if modeRow    then modeRow.Visible    = false end
        if selFns.infoBtn then selFns.infoBtn.Visible = false end
        sellCostCoin.Text = tostring(totalCost)

        -- Build the tower list. Each row "TOWER  →  TARGET" with target
        -- being the manual-target mob's name (if set) or the TargetMode
        -- attribute. Same data the (i) popup shows but compactly inline.
        -- (lbl was created/reused above in the same scope.)
        local lines = {}
        for _, t in ipairs(multiSelectedTowers) do
            if t and t.Parent then
                local towerName = t:GetAttribute("DisplayName") or t.Name
                local manual = manualTargetsByTower[t]
                local targetStr
                if manual and manual.Parent then
                    targetStr = manual:GetAttribute("DisplayName") or manual.Name
                else
                    targetStr = (t:GetAttribute("TargetMode") or "First"):upper()
                end
                table.insert(lines, towerName .. "  →  " .. targetStr)
            end
        end
        lbl.Text = table.concat(lines, "\n")
        lbl.Visible = true

        -- Panel collapse: each row is ~22px line-height; pad title (44)
        -- + bottom-buttons (60) + body line-count for the right-sized
        -- panel. Cap at 310 (single-mode height) so a 9+ tower selection
        -- doesn't grow taller than the original.
        local rowH = 22
        local newH = math.min(310, 44 + count * rowH + 60)
        targetModeFrame.Size = UDim2.fromOffset(440, newH)
    else
        -- Single-select layout. statsFrame / modeRow re-show; the title
        -- is restored by refreshHUD (called right after this from
        -- openForTower); panel returns to the original 310 height.
        bullseyeBtn.Text = "TARGET <font color='#ffdd55'>[G]</font>"
        bullseyeBtn.Size = UDim2.fromOffset(104, 28)
        sellBtn.Text = "PICK UP <font color='#ffdd55'>[X]</font>"
        sellBtn.Size = UDim2.fromOffset(116, 28)
        sellBtn.Position = UDim2.new(0, 122, 1, -52)
        if statsFrame then statsFrame.Visible = true end
        if modeRow    then modeRow.Visible    = true end
        if selFns.infoBtn then selFns.infoBtn.Visible = true end
        if selFns.multiListLabel then
            selFns.multiListLabel.Visible = false
        end
        targetModeFrame.Size = UDim2.fromOffset(440, 310)
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

    -- Sell action: fires SellTower remote for every selected tower.
    -- Single-select uses currentTargetTower; multi-select fans out
    -- across multiSelectedTowers. Server validates ownership + token
    -- cost per tower. Client closes the HUD, selection box, and info
    -- modal immediately so the UI doesn't linger referencing towers
    -- about to vanish — waiting for AncestryChanged replication
    -- round-trip would leave a stale panel for 100-200ms.
    local function trySellSelectedTower()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.SellTower)
        if not r then return end
        if #multiSelectedTowers >= 2 then
            for _, t in ipairs(multiSelectedTowers) do
                if t and t.Parent then
                    r:FireServer({ tower = t })
                end
            end
        elseif currentTargetTower and currentTargetTower.Parent then
            r:FireServer({ tower = currentTargetTower })
        else
            return
        end
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
    local function consider(part)
        if not (part:IsA("BasePart") and part.Parent) then return end
        local sp = cam:WorldToViewportPoint(part.Position)
        if sp.Z <= 0 then return end
        local dx = sp.X - screenX
        local dy = sp.Y - screenY
        local d2 = dx * dx + dy * dy
        if d2 < bestDistSq then
            bestDistSq = d2
            bestMob = part
        end
    end
    for _, mob in ipairs(CollectionService:GetTagged(Tags.Mob)) do
        consider(mob)
    end
    -- Also consider the Map 3 bird boss body even when it's NOT currently
    -- Tags.Mob tagged (the bird is only tagged while damageable — dive /
    -- grab / carry / drop). Per Matthew: "allow setting the target when
    -- the boss hp is grayed out." Lets the player pre-lock a tower onto
    -- the bird while it's hovering; the tower fires once the bird becomes
    -- damageable. Server's Targeting.lua respects the tag, so this is
    -- purely a UX affordance for the manual-pick step.
    local birdModel = workspace:FindFirstChild("Map3CanopyBird")
    local birdBody  = birdModel and birdModel:FindFirstChild("Body")
    if birdBody then
        consider(birdBody)
    end
    -- Direct-raycast fallback for bosses with bodies that project
    -- their CENTER off-screen / behind walls (Pickle Lord's body
    -- center is buried ~125 stud below the platform — proximity
    -- to mob.Position never matches the user's click on the
    -- visible silhouette). If the click ray hits a Tags.Mob part
    -- directly OR a part whose ancestor model contains a
    -- Tags.Mob-tagged part, prefer that result over the proximity
    -- pick.
    --
    -- Diagnostics: prints what the click ray hit and whether we
    -- found a Tags.Mob match. Helps debug "I clicked on the boss
    -- and nothing happened" — the log says exactly which Part the
    -- ray landed on and whether the model walk found the tagged
    -- body part.
    if rayHit and rayHit.Instance then
        local hitPart = rayHit.Instance
        if hitPart:IsA("BasePart") then
            if CollectionService:HasTag(hitPart, Tags.Mob) then
                return hitPart, rayHit.Position
            end
            local model = hitPart:FindFirstAncestorOfClass("Model")
            if model then
                for _, desc in ipairs(model:GetChildren()) do
                    if desc:IsA("BasePart")
                       and CollectionService:HasTag(desc, Tags.Mob) then
                        return desc, rayHit.Position
                    end
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
        -- Single-select fires for currentTargetTower; multi-select fans
        -- out across every entry in multiSelectedTowers. Each tower
        -- gets the same mob as its manual target, and the by-tower
        -- cache picks up each pair so re-selecting any of them later
        -- restores the bullseye to this same mob.
        if r then
            if #multiSelectedTowers >= 2 then
                for _, t in ipairs(multiSelectedTowers) do
                    if t and t.Parent then
                        r:FireServer({ tower = t, mob = mob })
                        manualTargetsByTower[t] = mob
                    end
                end
            else
                r:FireServer({ tower = currentTargetTower, mob = mob })
                manualTargetsByTower[currentTargetTower] = mob
            end
        end
        -- One visible indicator on the picked mob — represents "the
        -- selection is locked on this enemy" regardless of how many
        -- towers are participating. The by-tower cache (above) handles
        -- restoring the indicator on re-select for any participating
        -- tower individually.
        clearAllManualTargetIndicators()
        attachManualTargetIndicator(mob)
        setMobPickMode(false)
        mobPickConsumedAt = os.clock()
        -- Refresh BOTH the per-tower HUD ("Target: X" row) AND the
        -- multi-tower panel ("FrostMelon → The Pickle Lord" lines).
        -- Manual target is stored in manualTargetsByTower (a client
        -- table, not an attribute), so the HUD's attribute-change
        -- listeners don't auto-fire — we have to nudge them.
        if refreshHUD then refreshHUD() end
        if selFns.updateMultiButtons then selFns.updateMultiButtons() end
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
    -- Pad + minimum-rect-size both scale the click area. PAD_PX still adds
    -- a forgiving border on every projected box, AND we enforce an 80×80
    -- floor on the rect itself — distant zoomed-out towers project to
    -- 10×10 pixels, which used to be unselectable on iPad. The floor
    -- expands those tiny rects around their center to a stable thumb-size
    -- target so towers stay clickable at any zoom.
    -- Tuned 2026-04-26: PAD 28→36, MIN 56→80, plus a NEAR_MISS_PX
    -- tolerance below — the strict "cursor inside padded rect" rule
    -- used to drop near-miss clicks like the small-tower screenshot.
    local PAD_PX = 36
    local MIN_RECT_PX = 80
    local NEAR_MISS_PX = 32   -- accept clicks up to this many px outside the padded rect
    -- Three-tier sort to handle clustered towers correctly:
    --   1. bestRectDist  — pixels outside padded rect (0 if cursor inside)
    --   2. bestCamZ      — depth from camera (smaller = closer; foreground
    --                       wins when multiple rects contain the cursor —
    --                       you can't see the back tower THROUGH the front
    --                       one, so clicking should pick the front one)
    --   3. bestCenterDist — rect-center to cursor (last-resort tiebreak
    --                       for towers at identical depth)
    local bestModel = nil
    local bestRectDist, bestCamZ, bestCenterDist = math.huge, math.huge, math.huge
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        if base:IsA("BasePart") then
            local model = base:FindFirstAncestorOfClass("Model")
            while model and not model:GetAttribute("TowerType") do
                model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
            end
            if model and model:IsA("Model") then
                -- World-axis bounding box via shared helper. Click
                -- detection MUST match the visible SelectionBox cube
                -- (SelectionVisuals.lua uses the same helper).
                local minV, maxV = BBoxUtil.worldAxisBounds(model)
                if minV and maxV then
                    local minX, minY, minZ = minV.X, minV.Y, minV.Z
                    local maxX, maxY, maxZ = maxV.X, maxV.Y, maxV.Z
                    -- FloorY override — match SelectionVisuals: the
                    -- world-axis sweep above can include invisible
                    -- VFX anchors that hang below the floor, dragging
                    -- the click hit-area below the visible tower.
                    -- Stamped FloorY pins the bottom edge to the floor
                    -- the tower was placed on.
                    local floorAttr = model:GetAttribute("FloorY")
                    if type(floorAttr) == "number" then
                        minY = floorAttr
                    end
                    -- Project the 8 corners of the world-axis bounding
                    -- box to screen space and take the min/max rect.
                    local minSX, minSY, maxSX, maxSY = math.huge, math.huge, -math.huge, -math.huge
                    local anyOnScreen = false
                    local cornersX = { minX, maxX }
                    local cornersY = { minY, maxY }
                    local cornersZ = { minZ, maxZ }
                    for _, wx in ipairs(cornersX) do
                        for _, wy in ipairs(cornersY) do
                            for _, wz in ipairs(cornersZ) do
                                local sp, onScreen = camera:WorldToViewportPoint(Vector3.new(wx, wy, wz))
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
                        -- Enforce a minimum rect size around the projected
                        -- box's center — keeps distant/zoomed-out towers
                        -- clickable even when their actual screen footprint
                        -- is just a few pixels.
                        local rectW = maxSX - minSX
                        local rectH = maxSY - minSY
                        if rectW < MIN_RECT_PX then
                            local cx = (minSX + maxSX) * 0.5
                            minSX = cx - MIN_RECT_PX * 0.5
                            maxSX = cx + MIN_RECT_PX * 0.5
                        end
                        if rectH < MIN_RECT_PX then
                            local cy = (minSY + maxSY) * 0.5
                            minSY = cy - MIN_RECT_PX * 0.5
                            maxSY = cy + MIN_RECT_PX * 0.5
                        end
                        -- Compare in VIEWPORT coords (both the projected box
                        -- and the input's viewport-corrected X/Y). Inflate
                        -- the rect by PAD_PX so near-misses still register.
                        local dx = math.max(minSX - PAD_PX - viewX, 0, viewX - (maxSX + PAD_PX))
                        local dy = math.max(minSY - PAD_PX - viewY, 0, viewY - (maxSY + PAD_PX))
                        local d = math.sqrt(dx * dx + dy * dy)
                        -- Camera-space depth for tiebreak (foreground first).
                        local centerSp = camera:WorldToViewportPoint(Vector3.new(
                            (minX + maxX) * 0.5,
                            (minY + maxY) * 0.5,
                            (minZ + maxZ) * 0.5))
                        local camZ = centerSp.Z
                        -- Pixel distance from rect-center for last-resort tiebreak.
                        local cx = (minSX + maxSX) * 0.5
                        local cy = (minSY + maxSY) * 0.5
                        local cdx = cx - viewX
                        local cdy = cy - viewY
                        local cd = math.sqrt(cdx * cdx + cdy * cdy)
                        -- Tiebreak order when rectDist matches:
                        --   1. centerDist (rect-center closest to cursor wins).
                        --      Visually-clustered sibling towers project to
                        --      similar depths but the player aims with their
                        --      eyes — the tower whose silhouette the cursor
                        --      is "on" wins, regardless of a 2-5 stud
                        --      front/back delta. Earlier we used camZ here
                        --      and the tower 5 studs closer to camera kept
                        --      eating clicks aimed at its sibling.
                        --   2. camZ (foreground wins) — only as a last
                        --      resort tiebreak, AND only when one tower is
                        --      meaningfully in front of another (Z_EPS=8
                        --      studs). Keeps the original "can't click the
                        --      back tower THROUGH a front one" intent for
                        --      stacked towers without overruling visual
                        --      proximity for siblings on the same plank.
                        local Z_EPS = 8
                        local CD_EPS = 6  -- ~thumb-width; below this two centers are "tied"
                        local better = (d < bestRectDist)
                            or (d == bestRectDist
                                and (cd < bestCenterDist - CD_EPS
                                     or (math.abs(cd - bestCenterDist) <= CD_EPS
                                         and camZ < bestCamZ - Z_EPS)))
                        if better then
                            bestRectDist = d
                            bestCamZ = camZ
                            bestCenterDist = cd
                            bestModel = model
                        end
                    end
                end
            end
        end
    end
    -- Accept the click if the cursor was within the padded rect
    -- OR within NEAR_MISS_PX of its outer edge. Prior rule was a
    -- strict "must be inside" — surfaced as missed clicks on small
    -- aux towers when the cursor landed just outside the padded
    -- bounds. The near-miss band lets a clearly-aimed click on a
    -- tiny tower register even with thumb-on-iPad imprecision.
    if bestRectDist > NEAR_MISS_PX then bestModel = nil end
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
    -- Ctrl-click multi-select: holding either Control key while clicking
    -- a tower ADDS that tower to the selection set instead of replacing
    -- it. Useful for "CHANGE ALL TARGETS" / "PICK UP SELECTED" group
    -- actions. Mobile has no ctrl key — that's fine, multi-select is a
    -- power-user PC feature; iPad players can still operate one tower at
    -- a time. Plain click on the same tower while it's already in the
    -- multi-set REMOVES it (toggle semantics).
    local ctrlHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
                  or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
    if tower then
        if ctrlHeld and currentTargetTower and currentTargetTower.Parent
                    and currentTargetTower ~= tower then
            -- Lazy-seed: first ctrl-click makes the multi-set explicit
            -- with the existing primary as element 1 (and a SelectionBox
            -- wireframe matching the secondary look — primary keeps its
            -- corner-bracket cage from openForTower's earlier
            -- SelectionVisuals.build). Idempotent toggle: re-clicking a
            -- tower already in the set REMOVES it.
            -- Hook the new tower's destroy so smash / sell mid-
            -- selection auto-updates the HUD state. Inline closure
            -- so we can reuse the helper defined alongside
            -- openForTower above.
            local function hookDestroy(t)
                if t and t.Parent then
                    t.AncestryChanged:Connect(function(_, parent)
                        if not parent and selFns.handleSelectionTowerDestroyed then
                            selFns.handleSelectionTowerDestroyed(t)
                        end
                    end)
                end
            end
            if #multiSelectedTowers == 0 then
                table.insert(multiSelectedTowers, currentTargetTower)
                if selFns.addMultiBox then selFns.addMultiBox(currentTargetTower) end
                hookDestroy(currentTargetTower)
            end
            local found = false
            for i, t in ipairs(multiSelectedTowers) do
                if t == tower then
                    table.remove(multiSelectedTowers, i)
                    if selFns.removeMultiBox then selFns.removeMultiBox(tower) end
                    found = true
                    break
                end
            end
            if not found then
                table.insert(multiSelectedTowers, tower)
                if selFns.addMultiBox then selFns.addMultiBox(tower) end
                hookDestroy(tower)
            end
            -- HUD already open from the original openForTower; refresh
            -- the action-button labels (and stats-panel visibility)
            -- to reflect the new count.
            if selFns.updateMultiButtons then selFns.updateMultiButtons() end
        else
            -- Plain click → drop multi-select, single-select this tower.
            multiSelectedTowers = {}
            if selFns.clearAllMultiBoxes then selFns.clearAllMultiBoxes() end
            openForTower(tower)
        end
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
-- TowerCard returns its infoBtn so updateMultiButtons can hide it in
-- multi-mode. Stash on selFns to avoid claiming a module-scope register.
selFns.infoBtn = require(script:WaitForChild("TowerCard")).setup({
    playerGui        = playerGui,
    TempTowers       = TempTowers,
    findTowerDefById = findTowerDefById,
    targetModeFrame  = targetModeFrame,
    getCurrentTower  = function() return currentTargetTower end,
    -- Multi-select integration. When >= 2 towers are ctrl-selected,
    -- TowerCard's info-button click switches from the per-tower detail
    -- modal to a compact list of (tower, current target) pairs. The
    -- target lookup uses the by-tower manual-target cache (mirror of
    -- server's ctx.towerManualTargets for the local player) and falls
    -- back to the tower's TargetMode attribute when no manual is set.
    getMultiSelected = function() return multiSelectedTowers end,
    getManualTargetForTower = function(tower)
        return manualTargetsByTower[tower]
    end,
})

------------------------------------------------------------
-- PICKLE LORD entrance cinematic + smash shake + boss bar.
-- All extracted to sibling ModuleScript PickleLordEntrance.lua.
-- The setup() call below wires its OnClientEvent handlers and
-- builds the bottom-screen boss health bar (initially hidden;
-- faded in by the cinematic's endCinematic).
------------------------------------------------------------
PickleLordEntrance.setup({
    player            = player,
    playerGui         = playerGui,
    workspace         = workspace,
    ReplicatedStorage = ReplicatedStorage,
    UserInputService  = UserInputService,
    RunService        = RunService,
    Remotes           = Remotes,
    IS_MOBILE         = IS_MOBILE,
    -- Module builds the embedded HP row as a child of waveFrame
    -- inside setup() so init.client.lua doesn't have to spend a
    -- top-level register on the reference table.
    waveFrame         = waveFrame,
    -- Defensive: cinematic calls this on start to bail the player
    -- out of placement mode (and tear down the grid + ghost) if
    -- they happened to be mid-place when the boss spawned.
    forceExitPlacement = exitPlacementMode,
})

------------------------------------------------------------
-- Infinite Arena entry/exit cinematic — fade-to-black overlay for
-- "drop through the ground" + return-to-hub transitions. Sibling
-- module so init.client doesn't burn registers on overlay state.
-- See TreeOfLife_Client/InfiniteCinematic.lua.
------------------------------------------------------------
require(script:WaitForChild("InfiniteCinematic")).setup({
    player            = player,
    playerGui         = playerGui,
    ReplicatedStorage = ReplicatedStorage,
    Remotes           = Remotes,
    TweenService      = TweenService,
})


------------------------------------------------------------
-- Hold-E rapid-pickup loop driver — extracted to sibling module.
-- See TreeOfLife_Client/HoldEPickup.lua. Currently dormant (the ammo
-- system itself is retired); kept for the "ammo returns" code path.
------------------------------------------------------------
require(script:WaitForChild("HoldEPickup")).setup({
    player             = player,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    CollectionService  = CollectionService,
    Tags               = Tags,
    UserInputService   = UserInputService,
})

------------------------------------------------------------
-- PLAYER HUDS — bottom-right pills: reroll-token count + Phoenix
-- cooldown/grace status. Extracted to sibling module.
-- See TreeOfLife_Client/PlayerHUDs.lua.
------------------------------------------------------------
do
    local hud = require(script:WaitForChild("PlayerHUDs")).setup({
        playerGui          = playerGui,
        player             = player,
        CollectionService  = CollectionService,
        Tags               = Tags,
    })
    -- Capture the run-time label PlayerHUDs created so the tick below
    -- can write to it. The forward-decl `runTimeLabel` upvalue is the
    -- one read by both this assignment and the Heartbeat tick.
    runTimeLabel = hud and hud.runTimeLabel
end

-- Per-frame run-time tick: advance by dt × gameSpeed when not paused.
-- Pause flips:
--   - paused = true  initially (lobby; no map yet)
--   - paused = false on HasBeenGrantedStock attribute change (player
--                    received their starter Core via portal/dev-port,
--                    which fires whether the route was the natural
--                    portal or a dev panel teleport)
--   - paused = true  on state.bossCleared (boss just died)
--   - paused = false on state.mapId change (player arrived on next map)
-- WaveState handler (further down in this file) drives the boss/map
-- transitions; the listener below drives the lobby-to-map transition.
do
    local RunService = game:GetService("RunService")
    RunService.Heartbeat:Connect(function(dt)
        if runTimePaused then return end
        if not runTimeLabel then return end
        local gs = workspace:GetAttribute("GameSpeed") or 1
        if type(gs) ~= "number" or gs <= 0 then gs = 1 end
        -- Wallclock advances at real seconds, game-time at dt × gameSpeed.
        -- At 1× they match; at 5× game-time outpaces wall by 5×.
        runTimeWallSec = runTimeWallSec + dt
        runTimeGameSec = runTimeGameSec + dt * gs
        local wall = math.floor(runTimeWallSec)
        local game_ = math.floor(runTimeGameSec)
        runTimeLabel.Text = string.format(
            "run time: %d:%02d (%d:%02d)",
            wall // 60, wall % 60,
            game_ // 60, game_ % 60)
    end)

    -- HasBeenGrantedStock: server sets this true when the player gets
    -- their first stock (which only fires after they enter a map via
    -- portal or dev teleport). Use it as the "started a map" signal.
    -- Pre-check covers the case where the attribute was already set
    -- before this listener wired (e.g., rejoining mid-run).
    if player:GetAttribute("HasBeenGrantedStock") then
        runTimePaused = false
    end
    player:GetAttributeChangedSignal("HasBeenGrantedStock"):Connect(function()
        if player:GetAttribute("HasBeenGrantedStock") then
            runTimePaused = false
        else
            -- Reset cleared the flag — pause + zero both clocks.
            runTimePaused  = true
            runTimeWallSec = 0
            runTimeGameSec = 0
            if runTimeLabel then runTimeLabel.Text = "run time: 0:00 (0:00)" end
        end
    end)
end

------------------------------------------------------------
-- Boss-defeat cutscene (map 1 → map 2 transition) — extracted to
-- sibling module. See TreeOfLife_Client/BossDefeatCutscene.lua.
------------------------------------------------------------
require(script:WaitForChild("BossDefeatCutscene")).setup({
    player             = player,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
})

------------------------------------------------------------
-- Falling-leaf narrative message — extracted to sibling module.
-- See TreeOfLife_Client/LeafMessage.lua.
------------------------------------------------------------
require(script:WaitForChild("LeafMessage")).setup({
    playerGui          = playerGui,
    ReplicatedStorage  = ReplicatedStorage,
    Remotes            = Remotes,
    RunService         = RunService,
    IS_MOBILE          = IS_MOBILE,
})

-- Build tag inlined via do-block so Config doesn't consume a top-
-- level register slot (client is at the 200-register Luau ceiling).
do
    local cfg = require(Shared:WaitForChild("Config"))
    print(("[TreeOfLife] Client v5.9.54 ready (build %s)."):format(cfg.BuildTag))
end
