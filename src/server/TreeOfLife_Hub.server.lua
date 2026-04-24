-- TreeOfLife_Hub.lua
-- Hub world server — now an ORCHESTRATOR after Phase 2. Top-of-file
-- constants + helpers + Remote setup, then a sequence of module
-- setup calls in dependency order. The bulk of world construction
-- lives under src/server/world/ and systems lives under
-- src/server/systems/ — see the module-setup section below.
--
-- Companion script: TreeOfLife_WaveSystem (mob spawning, tower firing,
-- wave progression, upgrade picker generation). The two scripts
-- communicate via RemoteEvents in ReplicatedStorage and a few
-- BindableEvents.
--
-- Companion script: TreeOfLife_Client (LocalScript). Handles all UI
-- and input: placement ghost, hotbar, target-mode HUD, upgrade
-- picker, wave HUD, game over modal, attachment inventory.
--
-- ============================================================
-- ARCHITECTURE NOTES (read before editing)
-- ============================================================
--
-- WHAT STILL LIVES IN THIS FILE (post-Phase-2):
--   - Top-of-file constants (CLEARING_CENTER, TD_ROOM_*, MAP2_*,
--     WALL_RINGS, UMBRELLA_LAYERS, etc.)
--   - Helpers: ensureRemote, makePart, rand, catmullRom, sampleSpline,
--     trunkRadius
--   - Remote/Bindable creation (ensureRemote() calls + BindableEvent
--     setup for StageAdvanced, BossDefeated, WaveAutoStart)
--   - RunState table
--   - HubContext creation + ctx population (constants, helpers) + the
--     ordered Module.setup(ctx) calls
--   - fireLeafMessage helper + MAP1_LEAF constant (used by the
--     tower-picked handler below)
--   - Tower placement scaffolding: canPlaceAt, markCellsOccupied,
--     encodeGridState, broadcastGrid. The Model builders themselves
--     live in src/server/TowerBuilders.lua (published on
--     ctx.TOWER_BUILDERS).
--   - towerPickedRemote + placeTowerRemote handlers (tightly coupled
--     to the tower builders)
--   - PlayerAdded handler (attachment loading, CharacterAdded attr
--     seeding)
--   - StageAdvanced dispatcher (forwards to ctx.tweenStageLighting /
--     ctx.applyMap2StageVisuals by mapId)
--
-- MODULE SETUP ORDER (the load-bearing part of this file):
--   HubWorld → TdRoom → Grid → Map2 → StageVisuals → Map2StageVisuals
--            → Portal → TowerBuilders → DevRemotes
--
--   Each module's setup(ctx) reads fields populated by earlier
--   setups and writes new fields onto ctx. See src/server/HubContext.lua
--   for the field-by-field contract.
--
-- EDITING RULES:
--   1. Functions must be declared BEFORE any function that calls them.
--      Lua resolves non-local identifiers as globals at function-
--      DEFINITION time (not call time). A late-declared local
--      resolves to nil global in earlier closures and crashes only
--      on the code path that exercises the call. Don't add forward-
--      decl shims (`local foo = nil`); instead, put the dependency
--      above the consumer.
--   2. When moving code between the hub and an extracted module, do
--      a FULL grep for every identifier the block defines or reads —
--      free variables that resolve against the module-level scope
--      need an explicit ctx read or direct require.
--
-- TOWER + PLAYER ATTRIBUTES (don't add new ones without a comment):
--   Tower:  Damage, DamageBase, DamageFlat, Range, RangeBase, RangeBonusPct,
--           FireRate, FireRateBase, FireRateBonusPct, Shots, MaxShots, Ammo,
--           MaxAmmo, TargetMode, AoeRadius, Knockback, StunDuration, Owner,
--           TowerType, FootprintW, FootprintD, EquippedType, EquippedRarity,
--           DetonatorRadius, DetonatorHpPct, PhoenixCooldown, PhoenixReady,
--           PhoenixCdRemaining
--   Player: PowerStock, DoTStock, CCStock, CarryingAmmo, MaxCarry, RerollsUsed,
--           HasBeenGrantedStock, HasReceivedFreeReward, BonusDamageUntil,
--           DevUnlimitedAmmo, WaveAutoStartScheduled
--   Heart:  Health, MaxHealth
--
-- ============================================================

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
-- Bump respawn time so game-over ragdolls stay crumpled on the ground
-- through the fairy cinematic + modal rather than auto-respawning at
-- SpawnLocation. We manually :LoadCharacter() in the flows that unlock
-- the game (teleport-when-dead in Portal, resurrection bindable in
-- WaveSystem), so the default 5s auto-respawn would just race those.
Players.RespawnTime = 60
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

-- Shared constants modules. Single source of truth for Remote/Bindable
-- names, CollectionService tags, and game-wide config. See src/shared/.
local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local Tags        = require(Shared:WaitForChild("Tags"))
local Config      = require(Shared:WaitForChild("Config"))
local TowerTypes  = require(Shared:WaitForChild("TowerTypes"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))

-- AttachmentStore (v2): persistent per-player attachment system.
-- Attachments definitions: shared spec for types, rarities, effects.
-- Both placed as ModuleScripts in ServerScriptService.
local AttachmentStore = require(ServerScriptService:WaitForChild("AttachmentStore"))
local Attachments     = require(ServerScriptService:WaitForChild("Attachments"))

local CLEARING_CENTER    = Vector3.new(0, 0, 0)
local CLEARING_RADIUS    = 135
local GIANT_TREE_OFFSET  = Vector3.new(0, 0, -45)
local GIANT_TREE_HEIGHT  = 220
local TRUNK_BASE_RADIUS  = 14
local BASE_FLARE_FACTOR  = 2.2
local BASE_FLARE_FRAC    = 0.18

local WALL_RINGS = {
    {radius = 105, count = 28, heightMin = 32, heightMax = 42},
    {radius = 115, count = 32, heightMin = 38, heightMax = 50},
    {radius = 125, count = 34, heightMin = 44, heightMax = 58},
}

local UMBRELLA_BOTTOM_Y = 75
local UMBRELLA_OUTER_R  = 105
local UMBRELLA_LAYERS = {
    {radius = 105, yOff = 0,  puffs = 22, puffSize = 22},
    {radius = 90,  yOff = 10, puffs = 18, puffSize = 24},
    {radius = 70,  yOff = 22, puffs = 14, puffSize = 26},
    {radius = 48,  yOff = 35, puffs = 10, puffSize = 24},
    {radius = 26,  yOff = 48, puffs = 6,  puffSize = 22},
}

local TD_ROOM_CENTER  = Vector3.new(1000, 0, 0)
local TD_ROOM_WIDTH   = 120
local TD_ROOM_DEPTH   = 88
local TD_ROOM_HEIGHT  = 55
local TD_WALL_THICK   = 4

-- Grid dimensions come from Config (see src/shared/Config.lua). Locals
-- kept so the rest of the file doesn't need to change — they now alias
-- the shared values rather than owning them.
local CELL_SIZE = Config.Grid.CellSize            -- 2
local GRID_COLS = Config.Grid.Map1Cols            -- 60  (was TD_ROOM_WIDTH / CELL_SIZE)
local GRID_ROWS = Config.Grid.Map1Rows            -- 44  (was TD_ROOM_DEPTH / CELL_SIZE)
local PATH_WIDTH_CELLS = Config.Grid.PathWidthCells  -- 4
local HEART_EXCLUSION_CELLS = 3

-- v3 multi-map: Map 2 ("Climbing the Tree") parameters. Lives 500 studs
-- above map 1 in world space. 25% larger play area than map 1 (per the
-- design doc — longer paths means range matters more).
-- Grid coords: map 1 uses cols 0..GRID_COLS-1; map 2 uses cols
-- MAP2_COL_OFFSET..MAP2_COL_OFFSET+MAP2_COLS-1 in the same global grid.
-- cellToWorld dispatches to the right world-space origin based on col.
local MAP2_CENTER     = Vector3.new(1000, 500, 0)
local MAP2_WIDTH      = 150     -- 120 * 1.25
local MAP2_DEPTH      = 110     -- 88 * 1.25
local MAP2_HEIGHT     = 55
local MAP2_COLS       = MAP2_WIDTH / CELL_SIZE   -- 75
local MAP2_ROWS       = MAP2_DEPTH / CELL_SIZE   -- 55
local MAP2_COL_OFFSET = GRID_COLS                -- 60: map 2 cols start where map 1 ends
local MAP2_TOTAL_COLS = MAP2_COL_OFFSET + MAP2_COLS  -- 135 total cols in shared grid

local CLOCK_TIME = 10
local GEO_LATITUDE = 15
local SUN_RAY_DIRECTION = Vector3.new(-0.5, -1.2, 0.2)

local function ensureRemote(name)
    local r = ReplicatedStorage:FindFirstChild(name)
    if not r then
        r = Instance.new("RemoteEvent")
        r.Name = name
        r.Parent = ReplicatedStorage
    end
    return r
end

local remoteEnterPortal   = ensureRemote(Remotes.Names.EnterPortal)
local splashRemote        = ensureRemote(Remotes.Names.ShowSplash)
local introRemote         = ensureRemote(Remotes.Names.ShowIntro)
local towerSelectRemote   = ensureRemote(Remotes.Names.ShowTowerSelect)
local towerPickedRemote   = ensureRemote(Remotes.Names.TowerPicked)
local placeTowerRemote    = ensureRemote(Remotes.Names.PlaceTower)
local showHotbarRemote    = ensureRemote(Remotes.Names.ShowHotbar)
local gridUpdateRemote    = ensureRemote(Remotes.Names.GridUpdate)
local devResetRemote      = ensureRemote(Remotes.Names.DevReset)
local devTeleportRemote   = ensureRemote(Remotes.Names.DevTeleport)  -- client → server: teleport to hub/map1/map2 + start waves
-- DevMoveToMapStart remote is created here only so Portal.lua's WaitForChild
-- resolves immediately at server boot. Handler lives in Portal.lua. No local
-- binding needed since Hub doesn't consume it.
ensureRemote(Remotes.Names.DevMoveToMapStart)
local setTargetModeRemote = ensureRemote(Remotes.Names.SetTowerTargetMode)
local pickupStartRemote   = ensureRemote(Remotes.Names.PickupHoldStart)  -- client → server: E pressed near a pile, start rapid pickup loop
local pickupStopRemote    = ensureRemote(Remotes.Names.PickupHoldStop)   -- client → server: E released, stop the loop
local rerollRemote        = ensureRemote(Remotes.Names.RerollUpgrades)

-- Server-to-server BindableEvent: wave system fires this on stage transitions
-- (server-side visual changes like sun position, trees growing from walls).
-- The matching client-side StageReskin RemoteEvent is fired by the wave system
-- separately for client-side animations.
local stageAdvancedBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.StageAdvanced)
if not stageAdvancedBindable then
    stageAdvancedBindable = Instance.new("BindableEvent")
    stageAdvancedBindable.Name = Remotes.Names.StageAdvanced
    stageAdvancedBindable.Parent = ReplicatedStorage
end

-- BossDefeated: wave system fires this with the player who delivered the
-- killing blow (or the first online player as fallback). Hub awards a
-- persistent attachment.
local bossDefeatedBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.BossDefeated)
if not bossDefeatedBindable then
    bossDefeatedBindable = Instance.new("BindableEvent")
    bossDefeatedBindable.Name = Remotes.Names.BossDefeated
    bossDefeatedBindable.Parent = ReplicatedStorage
end

-- Server-to-server BindableEvent: hub fires this when first tower placed,
-- wave system listens and starts wave 1 after a delay.
local autoStartBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.WaveAutoStart)
if not autoStartBindable then
    autoStartBindable = Instance.new("BindableEvent")
    autoStartBindable.Name = Remotes.Names.WaveAutoStart
    autoStartBindable.Parent = ReplicatedStorage
end

-- Run-scoped server state. Replaces the legacy _G globals.
-- Reset by the DevReset handler (and by future stage transitions).
local RunState = {
    firstPickFired = false,  -- has any player picked their first tower yet?
}

local gridConfig = ReplicatedStorage:FindFirstChild(Remotes.Names.GridConfig)
if gridConfig then gridConfig:Destroy() end
gridConfig = Instance.new("Folder")
gridConfig.Name = Remotes.Names.GridConfig
gridConfig.Parent = ReplicatedStorage
do
    local function setNum(name, v)
        local nv = Instance.new("NumberValue")
        nv.Name = name
        nv.Value = v
        nv.Parent = gridConfig
    end
    setNum("CellSize", CELL_SIZE)
    setNum("GridCols", GRID_COLS)
    setNum("GridRows", GRID_ROWS)
    setNum("RoomCenterX", TD_ROOM_CENTER.X)
    setNum("RoomCenterZ", TD_ROOM_CENTER.Z)
    setNum("RoomWidth", TD_ROOM_WIDTH)
    setNum("RoomDepth", TD_ROOM_DEPTH)
    setNum("FloorY", 1)
    -- Map 2 geometry — client placement code needs these to raycast map 2's
    -- floor and translate hits into shared-grid (col, row). Map 2's floor
    -- part is centered at MAP2_CENTER with thickness 2, so its top surface
    -- sits at MAP2_CENTER.Y + 1.
    setNum("Map2CenterX", MAP2_CENTER.X)
    setNum("Map2CenterY", MAP2_CENTER.Y)
    setNum("Map2CenterZ", MAP2_CENTER.Z)
    setNum("Map2Width", MAP2_WIDTH)
    setNum("Map2Depth", MAP2_DEPTH)
    setNum("Map2Cols", MAP2_COLS)
    setNum("Map2Rows", MAP2_ROWS)
    setNum("Map2ColOffset", MAP2_COL_OFFSET)
    setNum("Map2TotalCols", MAP2_TOTAL_COLS)
    setNum("Map2FloorY", MAP2_CENTER.Y + 1)
end

local existing = Workspace:FindFirstChild("TreeOfLifeHub")
if existing then existing:Destroy() end
local existingRoom = Workspace:FindFirstChild("TreeOfLifeTDRoom")
if existingRoom then existingRoom:Destroy() end

-- ============================================================
-- Phase 2 context + module helpers
-- ============================================================
-- Shared mutable state populated by each world/* and systems/* module.
-- See src/server/HubContext.lua for the field-by-field contract.
local HubContext = require(script.Parent:WaitForChild("HubContext"))
local ctx = HubContext.new()

local function makePart(props)
    local p = Instance.new("Part")
    p.Anchored = true
    p.CanCollide = true
    p.TopSurface = Enum.SurfaceType.Smooth
    p.BottomSurface = Enum.SurfaceType.Smooth
    for k, v in pairs(props) do p[k] = v end
    return p
end

local function rand(min, max) return min + math.random() * (max - min) end

local function catmullRom(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2*p0 - 5*p1 + 4*p2 - p3) * t2 + (-p0 + 3*p1 - 3*p2 + p3) * t3)
end

local function sampleSpline(points, u)
    local n = #points - 1
    local seg = math.floor(u * n)
    if seg >= n then seg = n - 1 end
    local localT = u * n - seg
    local i1 = seg + 1
    local i0 = math.max(i1 - 1, 1)
    local i2 = math.min(i1 + 1, #points)
    local i3 = math.min(i1 + 2, #points)
    return catmullRom(points[i0], points[i1], points[i2], points[i3], localT)
end

local function trunkRadius(t)
    local base
    if t < BASE_FLARE_FRAC then
        local u = t / BASE_FLARE_FRAC
        local flare = 1 + (BASE_FLARE_FACTOR - 1) * (1 - u) * (1 - u)
        base = TRUNK_BASE_RADIUS * flare
    else
        local u = (t - BASE_FLARE_FRAC) / (1 - BASE_FLARE_FRAC)
        base = TRUNK_BASE_RADIUS * (1 - u * 0.55)
    end
    return base + rand(-0.5, 0.5)
end

-- Publish constants + helpers onto ctx so extracted modules can read them.
ctx.CLEARING_CENTER    = CLEARING_CENTER
ctx.CLEARING_RADIUS    = CLEARING_RADIUS
ctx.GIANT_TREE_OFFSET  = GIANT_TREE_OFFSET
ctx.GIANT_TREE_HEIGHT  = GIANT_TREE_HEIGHT
ctx.TRUNK_BASE_RADIUS  = TRUNK_BASE_RADIUS
ctx.BASE_FLARE_FACTOR  = BASE_FLARE_FACTOR
ctx.BASE_FLARE_FRAC    = BASE_FLARE_FRAC
ctx.WALL_RINGS         = WALL_RINGS
ctx.UMBRELLA_BOTTOM_Y  = UMBRELLA_BOTTOM_Y
ctx.UMBRELLA_OUTER_R   = UMBRELLA_OUTER_R
ctx.UMBRELLA_LAYERS    = UMBRELLA_LAYERS
ctx.SUN_RAY_DIRECTION  = SUN_RAY_DIRECTION
ctx.CLOCK_TIME         = CLOCK_TIME
ctx.GEO_LATITUDE       = GEO_LATITUDE
ctx.TD_ROOM_CENTER     = TD_ROOM_CENTER
ctx.TD_ROOM_WIDTH      = TD_ROOM_WIDTH
ctx.TD_ROOM_DEPTH      = TD_ROOM_DEPTH
ctx.TD_ROOM_HEIGHT     = TD_ROOM_HEIGHT
ctx.TD_WALL_THICK      = TD_WALL_THICK
ctx.CELL_SIZE              = CELL_SIZE
ctx.GRID_COLS              = GRID_COLS
ctx.GRID_ROWS              = GRID_ROWS
ctx.PATH_WIDTH_CELLS       = PATH_WIDTH_CELLS
ctx.HEART_EXCLUSION_CELLS  = HEART_EXCLUSION_CELLS
ctx.MAP2_CENTER            = MAP2_CENTER
ctx.MAP2_WIDTH             = MAP2_WIDTH
ctx.MAP2_DEPTH             = MAP2_DEPTH
ctx.MAP2_HEIGHT            = MAP2_HEIGHT
ctx.MAP2_COLS              = MAP2_COLS
ctx.MAP2_ROWS              = MAP2_ROWS
ctx.MAP2_COL_OFFSET        = MAP2_COL_OFFSET
ctx.MAP2_TOTAL_COLS        = MAP2_TOTAL_COLS
ctx.makePart           = makePart
ctx.rand               = rand
ctx.catmullRom         = catmullRom
ctx.sampleSpline       = sampleSpline
ctx.trunkRadius        = trunkRadius

-- ============================================================
-- HubWorld — hub overworld geometry, canopy, sun rays, Lighting
-- ============================================================
local HubWorld = require(script.Parent:WaitForChild("world"):WaitForChild("HubWorld"))
HubWorld.setup(ctx)

-- ============================================================
-- TdRoom — map 1 TD room geometry (walls, floor, ceiling, light shafts)
-- ============================================================
local TdRoom = require(script.Parent:WaitForChild("world"):WaitForChild("TdRoom"))
TdRoom.setup(ctx)

-- Bridge ctx fields back to local names — only the ones the remaining
-- in-hub code still references. Tower placement + the visible-path-tile
-- loop + the heart-pedestal builder use these. When Phase 4 extracts
-- the tower system, these bridges will go too.
local tdRoom = ctx.tdRoom
local rc = ctx.rc
local halfW = ctx.halfW
local halfD = ctx.halfD
local floor = ctx.floor

-- ============================================================
-- Grid — shared multi-map coordinate system + map 1 path marking
-- ============================================================
local Grid = require(script.Parent:WaitForChild("systems"):WaitForChild("Grid"))
Grid.setup(ctx)

local gridState = ctx.gridState
local cellToWorld = ctx.cellToWorld
local pathWaypointCells = ctx.pathWaypointCells
local heartCell = ctx.heartCell

local pathFolder = Instance.new("Folder")
pathFolder.Name = "EnemyPath"
pathFolder.Parent = tdRoom
-- v3 multi-map: tag this folder + its waypoints as belonging to map 1.
-- The wave system filters by MapId to pick the active map's path.
pathFolder:SetAttribute("MapId", 1)

for i, cell in ipairs(pathWaypointCells) do
    local worldPos = cellToWorld(cell[1], cell[2]) + Vector3.new(0, 1, 0)
    local part = makePart({
        Name = "Waypoint" .. i,
        Size = Vector3.new(2, 0.2, 2),
        CFrame = CFrame.new(worldPos),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(100, 200, 255),
        Transparency = 0.6,
        CanCollide = false,
        Parent = pathFolder,
    })
    part:SetAttribute("MapId", 1)
    CollectionService:AddTag(part, Tags.EnemyWaypoint)
end

-- Visual path tiles: one brown tile per "path" or "heart" cell in the grid.
-- This guarantees the visual exactly matches what the grid considers blocked,
-- with no arithmetic-induced gaps or overhangs at corners. Heart-zone cells
-- get the same brown so the area around the heart looks consistent.
for c = 0, GRID_COLS - 1 do
    for r = 0, GRID_ROWS - 1 do
        local s = gridState[c][r]
        if s == "path" or s == "heart" then
            local worldPos = rc + Vector3.new(
                -halfW + (c + 0.5) * CELL_SIZE,
                1.15,
                -halfD + (r + 0.5) * CELL_SIZE
            )
            makePart({
                Name = (s == "path") and "PathCell" or "HeartCell",
                Size = Vector3.new(CELL_SIZE, 0.3, CELL_SIZE),
                CFrame = CFrame.new(worldPos),
                Material = Enum.Material.Ground,
                Color = Color3.fromRGB(120, 95, 65),
                CanCollide = false,
                Parent = tdRoom,
            })
        end
    end
end

local heartWorldPos = cellToWorld(heartCell[1], heartCell[2]) + Vector3.new(0, 3, 0)
local heart = makePart({
    Name = "TreeHeart",
    Shape = Enum.PartType.Ball,
    Size = Vector3.new(10, 10, 10),
    CFrame = CFrame.new(heartWorldPos),
    Material = Enum.Material.Neon,
    Color = Color3.fromRGB(120, 255, 150),
    Transparency = 0.2,
    CanCollide = false,
    Parent = tdRoom,
})
CollectionService:AddTag(heart, Tags.EnemyEndPoint)
heart:SetAttribute("MapId", 1)
heart:SetAttribute("MaxHealth", 500)
heart:SetAttribute("Health", 500)

local heartLight = Instance.new("PointLight")
heartLight.Color = Color3.fromRGB(120, 255, 150)
heartLight.Brightness = 3
heartLight.Range = 40
heartLight.Parent = heart

makePart({
    Name = "HeartPedestal",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(3, 8, 8),
    CFrame = CFrame.new(heartWorldPos - Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
    Material = Enum.Material.Wood,
    Color = Color3.fromRGB(85, 55, 32),
    Parent = tdRoom,
})

local hpAnchor = makePart({
    Name = "HeartHPAnchor",
    Size = Vector3.new(1,1,1),
    CFrame = CFrame.new(heartWorldPos + Vector3.new(0, 9, 0)),
    Transparency = 1,
    CanCollide = false,
    Parent = tdRoom,
})
-- Heart HP bar: just the numbers inside, separate label billboard above
local hpBillboard = Instance.new("BillboardGui")
hpBillboard.Size = UDim2.new(0, 140, 0, 28)
hpBillboard.AlwaysOnTop = true
hpBillboard.LightInfluence = 0
hpBillboard.MaxDistance = 250
hpBillboard.StudsOffset = Vector3.new(0, 0, 0)
hpBillboard.Parent = hpAnchor

local hpBg = Instance.new("Frame")
hpBg.Size = UDim2.new(1, 0, 1, 0)
hpBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
hpBg.BackgroundTransparency = 0.2
hpBg.BorderSizePixel = 0
hpBg.Parent = hpBillboard

local hpFill = Instance.new("Frame")
hpFill.Size = UDim2.new(1, -4, 1, -4)
hpFill.Position = UDim2.new(0, 2, 0, 2)
hpFill.BackgroundColor3 = Color3.fromRGB(120, 255, 150)
hpFill.BorderSizePixel = 0
hpFill.Parent = hpBg

local hpText = Instance.new("TextLabel")
hpText.Size = UDim2.new(1, 0, 1, 0)
hpText.BackgroundTransparency = 1
hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
hpText.TextStrokeTransparency = 0
hpText.Font = Enum.Font.FredokaOne
hpText.TextSize = 18
hpText.ZIndex = 2
hpText.Parent = hpBg

-- Separate label billboard above the HP bar
local labelBillboard = Instance.new("BillboardGui")
labelBillboard.Size = UDim2.new(0, 200, 0, 24)
labelBillboard.AlwaysOnTop = true
labelBillboard.LightInfluence = 0
labelBillboard.MaxDistance = 250
labelBillboard.StudsOffset = Vector3.new(0, 1.5, 0)
labelBillboard.Parent = hpAnchor

local labelText = Instance.new("TextLabel")
labelText.Size = UDim2.fromScale(1, 1)
labelText.BackgroundTransparency = 1
labelText.Text = "HEART OF THE TREE"
labelText.TextColor3 = Color3.fromRGB(255, 255, 255)
labelText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
labelText.TextStrokeTransparency = 0
labelText.Font = Enum.Font.FredokaOne
labelText.TextSize = 16
labelText.Parent = labelBillboard

-- Pull display straight from the heart attributes so the label is always
-- accurate, even if MaxHealth is changed at startup. Called once at create
-- time AND on every Health change. Avoids drift from a hardcoded literal.
local function refreshHeartHud()
    local hp = heart:GetAttribute("Health") or 0
    local max = heart:GetAttribute("MaxHealth") or 500
    hpFill.Size = UDim2.new(math.max(0, hp / max), -4, 1, -4)
    hpText.Text = string.format("%d / %d", hp, max)
end
refreshHeartHud()
heart:GetAttributeChangedSignal("Health"):Connect(refreshHeartHud)
heart:GetAttributeChangedSignal("MaxHealth"):Connect(refreshHeartHud)

local enemySpawn = makePart({
    Name = "EnemySpawn",
    Size = Vector3.new(4, 0.5, 4),
    CFrame = CFrame.new(cellToWorld(pathWaypointCells[1][1], pathWaypointCells[1][2]) + Vector3.new(0, 1.15, 0)),
    Material = Enum.Material.Neon,
    Color = Color3.fromRGB(255, 100, 100),
    Transparency = 0.4,
    CanCollide = false,
    Parent = tdRoom,
})
enemySpawn:SetAttribute("MapId", 1)
CollectionService:AddTag(enemySpawn, Tags.EnemySpawn)

------------------------------------------------------------
-- MAP 2 — CLIMBING THE TREE
-- Extracted to src/server/world/Map2.lua (Phase 2 commit 5).
------------------------------------------------------------
-- Falling-leaf message helper. Defined in the hub (not Map2) because
-- the map-1 portal handler further below also calls it.
local leafMessageRemote_outer = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)
local function fireLeafMessage(player, text, duration)
    if not leafMessageRemote_outer then
        leafMessageRemote_outer = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)
    end
    if leafMessageRemote_outer then
        leafMessageRemote_outer:FireClient(player, {text = text, duration = duration or 6})
    end
end

-- Map2Stage namespace — populated in-place by Map2.setup (geometry
-- lists) and read by Map2StageVisuals.setup (applies stage-gated
-- reveals). The table is shared via ctx; mutations on either side
-- are visible to both.
ctx.Map2Stage = {
    bushLobes    = {},
    fireflies    = {},
    stairParts   = {},
    baseStairTotalHeight = 0,
}

-- applyMap2Stage1OnEntry is late-resolved through ctx. This initial
-- stub is overwritten by Map2StageVisuals.setup with the real
-- implementation. Map2.lua's portal handler and Portal.lua's dev
-- teleport both read ctx at call time so they pick up the overwrite.
ctx.applyMap2Stage1OnEntry = function() end
ctx.fireLeafMessage        = fireLeafMessage

local Map2 = require(script.Parent:WaitForChild("world"):WaitForChild("Map2"))
Map2.setup(ctx)

------------------------------------------------------------
-- STAGE VISUALS (map 1 + map 2)
-- Extracted to src/server/systems/StageVisuals.lua
-- and  src/server/systems/Map2StageVisuals.lua (Phase 2 commit 6).
------------------------------------------------------------
-- Shared lighting-tween state. Both StageVisuals.tweenStageLighting
-- and Map2StageVisuals.tweenStageLightingMap2 read/write these, and
-- DevReset calls ctx.cancelLightingTweens() to stop any in-flight
-- tween before snapping lighting back to stage-1 defaults.
ctx.activeLightingTween = nil
ctx.activeFloorTween    = nil
ctx.cancelLightingTweens = function()
    if ctx.activeLightingTween then ctx.activeLightingTween:Cancel(); ctx.activeLightingTween = nil end
    if ctx.activeFloorTween    then ctx.activeFloorTween:Cancel();    ctx.activeFloorTween    = nil end
end

local StageVisuals = require(script.Parent:WaitForChild("systems"):WaitForChild("StageVisuals"))
StageVisuals.setup(ctx)

local Map2StageVisuals = require(script.Parent:WaitForChild("systems"):WaitForChild("Map2StageVisuals"))
Map2StageVisuals.setup(ctx)

-- Serialize BOTH maps' cells, row-major over the shared grid's full extent
-- (cols 0..MAP2_TOTAL_COLS-1, rows 0..MAX_GRID_ROWS-1). The client's decoder
-- reads the same range and uses the col split (>= MAP2_COL_OFFSET) to
-- dispatch to the right map. Cells outside a given map's legal area remain
-- "open" in the table — canPlaceAt on the server enforces per-map bounds so
-- nothing actually places there.
local MAX_GRID_ROWS = ctx.MAX_GRID_ROWS
local function encodeGridState()
    local chars = {}
    for r = 0, MAX_GRID_ROWS - 1 do
        for c = 0, MAP2_TOTAL_COLS - 1 do
            local s = gridState[c][r]
            if s == "open" then chars[#chars+1] = "."
            elseif s == "path" then chars[#chars+1] = "#"
            elseif s == "heart" then chars[#chars+1] = "H"
            else chars[#chars+1] = "O"
            end
        end
    end
    return table.concat(chars)
end

local function broadcastGrid()
    local encoded = encodeGridState()
    for _, p in ipairs(Players:GetPlayers()) do
        gridUpdateRemote:FireClient(p, encoded)
    end
end

Players.PlayerAdded:Connect(function(player)
    -- Pre-load persistent attachment inventory so it's cached before they
    -- start placing towers. Non-blocking — load runs in a coroutine.
    task.spawn(function()
        AttachmentStore.load(player)
        -- Count owned types (v2 schema: {[type] = entry, ...})
        local count = 0
        for _ in pairs(AttachmentStore.getOwned(player)) do count = count + 1 end
        print(("[TreeOfLife] Loaded %d attachment(s) for %s"):format(count, player.Name))
        -- Mirror the equipped attachment type onto a player attribute so
        -- client HUDs (Phoenix indicator, etc.) can read it without needing
        -- a server roundtrip OR a placed tower. Empty string = nothing equipped.
        local equipped = AttachmentStore.getEquipped(player)
        player:SetAttribute("EquippedAttachmentType", equipped and equipped.type or "")
    end)

    player:SetAttribute("PowerStock", 0)
    player:SetAttribute("DoTStock", 0)
    player:SetAttribute("CCStock", 0)
    player:SetAttribute("CarryingAmmo", 0)
    player:SetAttribute("MaxCarry", 15)
    player:SetAttribute("RerollsUsed", 0)
    -- RerollTokens: per-run currency granted +1 on each stage boss kill
    -- (all 3 stages per map). Spent on upgrade-picker rerolls and on
    -- SELL (1 token per tower sold). Dev starting amount = 5 so the
    -- sell loop is testable without grinding to a stage boss first.
    -- Run-scoped: cleared on reset (back to 5, not 0 — still dev-stocked).
    player:SetAttribute("RerollTokens", 5)
    -- Seedlings: persistent currency from future Run Boss (Pickle Showdown)
    -- defeats. Spent in a future attachment shop (not yet built). Starts
    -- at 0; no drop source yet, so this is data plumbing for the future.
    player:SetAttribute("Seedlings", 0)
    player:SetAttribute("HasReceivedFreeReward", false)
    -- Per-map free-reward flags (first-tower-placed grant). Set on first
    -- placement on that map; cleared here so every new run gets a fresh
    -- free upgrade on map 1, map 2, and map 3.
    player:SetAttribute("HasReceivedFreeReward_Map1", false)
    player:SetAttribute("HasReceivedFreeReward_Map2", false)
    player:SetAttribute("HasReceivedFreeReward_Map3", false)
    -- Dev convenience: unlimited ammo defaults ON. Toggle off via the dev
    -- panel button if you want to test ammo management. Client button label
    -- starts in the ON state to match.
    player:SetAttribute("DevUnlimitedAmmo", true)
    -- RUN LUCK tracking: average rarity score of every upgrade card OFFERED
    -- this run. Updated by the wave system in generateCardsForPlayer.
    player:SetAttribute("RunLuckSum", 0)
    player:SetAttribute("RunLuckCount", 0)
    -- HasBeenGrantedStock gets set when the player picks a tower via the UI.
    -- Until then, the failsafe loop will prompt them with the tower select.
    player.CharacterAdded:Connect(function()
        task.wait(0.5)
        splashRemote:FireClient(player)
        task.wait(0.2)
        gridUpdateRemote:FireClient(player, encodeGridState())
    end)
end)

-- Failsafe: every 3s, check each player. If they're in the TD room and haven't
-- been granted stock yet (i.e. they missed or dismissed the splash), re-show
-- the tower select UI. Once granted, HasBeenGrantedStock prevents re-prompting.
task.spawn(function()
    while true do
        task.wait(3)
        for _, player in ipairs(Players:GetPlayers()) do
            local char = player.Character
            if char then
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local pos = hrp.Position
                    local inTDRoom = pos.X > rc.X - halfW and pos.X < rc.X + halfW
                                 and pos.Z > rc.Z - halfD and pos.Z < rc.Z + halfD
                    local alreadyGranted = player:GetAttribute("HasBeenGrantedStock")
                    local alreadyPrompted = player:GetAttribute("PromptedTowerSelect")
                    if inTDRoom and not alreadyGranted and not alreadyPrompted then
                        player:SetAttribute("PromptedTowerSelect", true)
                        towerSelectRemote:FireClient(player)
                        print(("[ToL] Failsafe prompting %s for tower select"):format(player.Name))
                    end
                end
            end
        end
    end
end)

-- Tower-type data comes from src/shared/TowerTypes.lua. This local
-- TOWER_DEFS table is a thin lookup index that the placement handler
-- uses to answer "what footprint does this tower type take?" and
-- similar questions before calling the builder. Keeping it here (vs
-- inlining TowerTypes.X reads everywhere) makes the placement code
-- read the same whether or not TowerTypes is the underlying store.
local TOWER_DEFS = {
    Power = {
        footprint = {TowerTypes.Power.footprintWidth, TowerTypes.Power.footprintDepth},
        damage    = TowerTypes.Power.damage,
        range     = TowerTypes.Power.range,
        fireRate  = TowerTypes.Power.fireRate,
    },
}
-- Merge in temp-tower entries. Footprint is the only field read by the
-- placement handler from this table today; damage/range/fireRate here are
-- rarity-neutral placeholders (actual stats come from TempTowers.resolveStats
-- using the player's <TowerId>Rarity attribute at placement time).
for id, tpl in pairs(TempTowers.Templates) do
    TOWER_DEFS[id] = {
        footprint = {tpl.footprintWidth, tpl.footprintDepth},
        damage    = tpl.damage,
        range     = tpl.range,
        fireRate  = tpl.fireRate,
    }
end

------------------------------------------------------------
-- TOWER BUILDERS — Core (Power) + 9 aux tower Model builders.
-- Extracted to src/server/TowerBuilders.lua. The module reads
-- ctx.makePart + ctx.tdRoom and publishes ctx.TOWER_BUILDERS =
-- { [towerTypeName] = builderFn(centerPos, player?) }. Each builder
-- returns a Model parented to tdRoom with per-type attributes stamped;
-- the generic placement handler below layers on Owner / FloorY /
-- Cells / TargetMode after.
------------------------------------------------------------
require(script.Parent:WaitForChild("TowerBuilders")).setup(ctx)
local TOWER_BUILDERS = ctx.TOWER_BUILDERS

local function canPlaceAt(anchorCol, anchorRow, footprintW, footprintD)
    -- v3 multi-map: bounds depend on which map this column belongs to.
    -- Map 1 = cols [0, GRID_COLS-1], rows [0, GRID_ROWS-1].
    -- Map 2 = cols [MAP2_COL_OFFSET, MAP2_TOTAL_COLS-1], rows [0, MAP2_ROWS-1].
    local isMap2 = anchorCol >= MAP2_COL_OFFSET
    local colMin = isMap2 and MAP2_COL_OFFSET or 0
    local colMax = isMap2 and (MAP2_TOTAL_COLS - 1) or (GRID_COLS - 1)
    local rowMax = isMap2 and (MAP2_ROWS - 1) or (GRID_ROWS - 1)
    for dc = 0, footprintW - 1 do
        for dr = 0, footprintD - 1 do
            local c = anchorCol + dc
            local r = anchorRow + dr
            if c < colMin or c > colMax or r < 0 or r > rowMax then return false end
            if gridState[c][r] ~= "open" then return false end
        end
    end
    return true
end

local function markCellsOccupied(anchorCol, anchorRow, footprintW, footprintD)
    for dc = 0, footprintW - 1 do
        for dr = 0, footprintD - 1 do
            gridState[anchorCol + dc][anchorRow + dr] = "occupied"
        end
    end
end

------------------------------------------------------------
-- PORTAL — hub-tree doorway + dev teleport
-- Extracted to src/server/world/Portal.lua (Phase 2 commit 7).
------------------------------------------------------------
local Portal = require(script.Parent:WaitForChild("world"):WaitForChild("Portal"))
Portal.setup(ctx)

-- Map 1 leaf message — fired AFTER the player picks a tower (not at
-- portal entry, so the narrative text doesn't get covered by the
-- tower-picker UI). Stays in the hub because the tower-picked handler
-- below is the only caller. One line is picked at random per run.
local MAP1_LEAF_LINES = {
    "protect me, and I'll reward you",
    "who will help me?",
    "will you reach the top?",
    "what terrors await?",
    "can you save me?",
}

towerPickedRemote.OnServerEvent:Connect(function(player, towerType)
    if towerType == "Power" then
        player:SetAttribute("PowerStock", 1)
        player:SetAttribute("DoTStock", 0)
        player:SetAttribute("CCStock", 0)
        -- Flag so the failsafe loop doesn't re-prompt after stock hits 0 from placing
        player:SetAttribute("HasBeenGrantedStock", true)
        -- If a permanent tower is equipped from a prior run's Pickle Lord kill,
        -- grant that too so the player enters the TD room with Core AND the
        -- carried-over Aux permanent. PermanentTowers system publishes this
        -- helper on ctx; safe no-op if the player has nothing equipped.
        if ctx.grantPermanentStock then
            ctx.grantPermanentStock(player)
        end
        showHotbarRemote:FireClient(player)
        print(("[TreeOfLife] %s picked Power; stock = 1"):format(player.Name))

        -- Fire the 5-second pre-wave countdown on FIRST pick in the server.
        -- RunState.firstPickFired prevents joining players from retriggering it.
        if not RunState.firstPickFired then
            RunState.firstPickFired = true
            local wsRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.WaveState)
            if wsRemote then
                wsRemote:FireAllClients({
                    wave = 0, totalWaves = 5, mobsAlive = 0, map = "Crook of the Tree (Morning)", stage = 1,
                    inProgress = false, pendingCountdown = 5,
                })
            end
            -- Falling-leaf intro for map 1. Fires here (rather than at portal
            -- entry) so the message isn't covered by the tower-picker UI.
            -- Slight delay so the picker has fully closed before the leaf appears.
            local leaf = MAP1_LEAF_LINES[math.random(1, #MAP1_LEAF_LINES)]
            task.delay(0.4, function() fireLeafMessage(player, leaf, 7) end)
            task.delay(5, function()
                autoStartBindable:Fire(player)
            end)
        end
    end
end)

placeTowerRemote.OnServerEvent:Connect(function(player, towerType, anchorCol, anchorRow)
    if type(anchorCol) ~= "number" or type(anchorRow) ~= "number" then
        print(("[ToL] %s placement REJECTED: bad coords %s %s"):format(player.Name, tostring(anchorCol), tostring(anchorRow)))
        return
    end
    anchorCol = math.floor(anchorCol)
    anchorRow = math.floor(anchorRow)
    local def = TOWER_DEFS[towerType]
    if not def then
        print(("[ToL] %s placement REJECTED: unknown tower type %s"):format(player.Name, tostring(towerType)))
        return
    end
    local stockAttr = towerType .. "Stock"
    local stock = player:GetAttribute(stockAttr) or 0
    if stock <= 0 then
        print(("[ToL] %s placement REJECTED: no stock of %s (has %d)"):format(player.Name, towerType, stock))
        return
    end
    local fw, fd = def.footprint[1], def.footprint[2]
    if not canPlaceAt(anchorCol, anchorRow, fw, fd) then
        print(("[ToL] %s placement REJECTED: cells (%d,%d) %dx%d not all open"):format(player.Name, anchorCol, anchorRow, fw, fd))
        return
    end
    local builder = TOWER_BUILDERS[towerType]
    if not builder then
        print(("[ToL] %s placement REJECTED: no builder for %s"):format(player.Name, towerType))
        return
    end

    local centerCol = anchorCol + (fw - 1) / 2
    local centerRow = anchorRow + (fd - 1) / 2
    -- v3 multi-map: pick the right world-space origin for this anchor's map.
    -- Map 2 cells live in cols [MAP2_COL_OFFSET..MAP2_TOTAL_COLS-1] and sit
    -- at MAP2_CENTER (1000, 500, 0) rather than map 1's rc origin.
    local centerPos
    if anchorCol >= MAP2_COL_OFFSET then
        local localCol = centerCol - MAP2_COL_OFFSET
        centerPos = Vector3.new(
            MAP2_CENTER.X - MAP2_WIDTH / 2 + (localCol + 0.5) * CELL_SIZE,
            MAP2_CENTER.Y + 1,
            MAP2_CENTER.Z - MAP2_DEPTH / 2 + (centerRow + 0.5) * CELL_SIZE
        )
    else
        centerPos = Vector3.new(
            rc.X - halfW + (centerCol + 0.5) * CELL_SIZE,
            1,
            rc.Z - halfD + (centerRow + 0.5) * CELL_SIZE
        )
    end

    local tower = builder(centerPos, player)
    -- Visual downscale: towers render at 50% of their authored size. The
    -- grid footprint (def.footprint cells) + collision / click area are
    -- unchanged — this is purely a mobile-readability tweak so a Power
    -- Tower doesn't block half the iPad screen. ScaleTo scales parts +
    -- their positions around the model's pivot, which leaves the base
    -- floating above the floor (pivot is bounding-box center); the
    -- re-seat math below shifts the model down so the new bottom of
    -- the bounding box sits at centerPos.Y again.
    if tower and tower:IsA("Model") then
        local originalPivot = tower:GetPivot()
        tower:ScaleTo(0.5)
        local ok, cf, sz = pcall(function() return tower:GetBoundingBox() end)
        if ok and cf and sz then
            local currentBottomY = cf.Y - sz.Y / 2
            local deltaY = centerPos.Y - currentBottomY
            if math.abs(deltaY) > 0.01 then
                tower:PivotTo(originalPivot + Vector3.new(0, deltaY, 0))
            end
        end
    end
    -- typeData holds Ammo/MaxShots/defaultTargetMode. Both TowerTypes
    -- entries (Power / future Slow / Assassin) and TempTowers.Templates
    -- use the same field names, so either lookup works here.
    local typeData = TowerTypes[towerType] or TempTowers.Templates[towerType]
    if not typeData then
        print(("[ToL] %s placement REJECTED: no typeData for %s"):format(player.Name, towerType))
        tower:Destroy()
        return
    end
    -- Temp towers (from TempTowers.Templates) use no ammo — once placed they
    -- fire forever. Ammo is a core Power-tower mechanic (refill at piles) but
    -- temp towers are "deploy and forget" rewards. The `stock` attribute on
    -- the player limits how many COPIES they can place; each placed copy
    -- just runs. The Towers.lua fire loop reads NoAmmo and treats it as
    -- unlimited; the ammo billboard below is also skipped for these towers.
    local isTempTower = TempTowers.Templates[towerType] ~= nil
    markCellsOccupied(anchorCol, anchorRow, fw, fd)
    tower:SetAttribute("AnchorCol", anchorCol)
    tower:SetAttribute("AnchorRow", anchorRow)
    tower:SetAttribute("FootprintW", fw)
    tower:SetAttribute("FootprintD", fd)
    tower:SetAttribute("Owner", player.UserId)
    if isTempTower then
        tower:SetAttribute("NoAmmo", true)
    else
        -- Ammo model: MaxAmmo is the pip count on the HUD, MaxShots is the
        -- real shot count (10 shots per pip). A pile pickup = +10 shots = +1 pip.
        -- Both start fully loaded at placement.
        tower:SetAttribute("MaxAmmo",  typeData.maxAmmo)
        tower:SetAttribute("Ammo",     typeData.maxAmmo)
        tower:SetAttribute("MaxShots", typeData.maxShots)
        tower:SetAttribute("Shots",    typeData.maxShots)
    end
    tower:SetAttribute("TargetMode", typeData.defaultTargetMode)
    -- Timestamp for lifetime-DPS calc on the client. workspace:GetServerTimeNow()
    -- is synced across server + clients, so the client's (now - PlacementTime)
    -- matches the actual elapsed seconds since placement.
    tower:SetAttribute("PlacementTime", workspace:GetServerTimeNow())
    -- Y coord of the floor this tower sits on, so the client's selection
    -- visuals (bracket cage floor + range ring) can anchor to the real
    -- floor instead of inferring from GetDescendants bounds (which gets
    -- dragged below floor by attachment VFX / invisible anchors).
    tower:SetAttribute("FloorY", centerPos.Y)

    -- Apply cumulative upgrade bonuses the player has already earned this run
    -- to this freshly-placed tower. Without this step, a Core placed on map 2
    -- would start at 0 bonus even though the player picked 8 damage cards
    -- across map 1 — every new placement would discard their upgrade progress.
    -- UpgradeCards.lua maintains per-player cumulative attributes:
    --   <Category>DamageFlat   (flat additive — Damage)
    --   <Category><Stat>Pct    (additive % — Range, FireRate)
    -- We read the category matching this tower and stamp it onto the tower's
    -- Base/Bonus attributes + live stat.
    do
        local category = isTempTower and "Aux" or "Core"
        -- Damage: flat additive bonus.
        local flatDamage = player:GetAttribute(category .. "DamageFlat") or 0
        if flatDamage ~= 0 then
            local baseVal = tower:GetAttribute("DamageBase") or tower:GetAttribute("Damage") or 0
            tower:SetAttribute("DamageFlat", flatDamage)
            tower:SetAttribute("Damage", baseVal + flatDamage)
        end
        -- Range / FireRate: additive percentage bonus.
        for _, stat in ipairs({ "Range", "FireRate" }) do
            local pct = player:GetAttribute(category .. stat .. "Pct") or 0
            if pct ~= 0 then
                local baseVal = tower:GetAttribute(stat .. "Base") or tower:GetAttribute(stat) or 0
                tower:SetAttribute(stat .. "BonusPct", pct)
                tower:SetAttribute(stat, baseVal * (1 + pct / 100))
            end
        end
        -- Core-only specials stacked across picks (Aux doesn't get specials).
        if category == "Core" then
            for _, attrName in ipairs({ "AoeRadius", "StunDuration", "Knockback" }) do
                local stacked = player:GetAttribute("Core" .. attrName)
                if stacked then
                    tower:SetAttribute(attrName, stacked)
                end
            end
            -- Knockback + Stun: per-tower proc chance attributes track the
            -- picked-up chance stack. Copy onto the freshly-placed tower
            -- so Effects.lua's applyHitEffects reads the accumulated chance
            -- (not the 5% default). Core cumulative is authoritative —
            -- placement inherits whatever chance the player has stacked up.
            for _, chanceAttr in ipairs({ "StunChance", "KnockbackChance" }) do
                local c = player:GetAttribute("Core" .. chanceAttr)
                if c then tower:SetAttribute(chanceAttr, c) end
            end
            local ammoMult = player:GetAttribute("CoreMaxShotsMult") or 1.0
            if ammoMult > 1.0 and tower:GetAttribute("MaxShots") then
                local cur = tower:GetAttribute("MaxShots")
                tower:SetAttribute("MaxShots", math.floor(cur * ammoMult + 0.5))
                tower:SetAttribute("Shots", tower:GetAttribute("MaxShots"))
            end
        end
    end

    -- Apply the player's equipped attachment to this tower (if any). The
    -- equipped slot is loadout-style: one chosen attachment per run, applied
    -- to every tower this player places. PowerCore is applied here at
    -- placement; Detonator and Phoenix are read by the wave system at fire
    -- time so we just tag the tower with the attachment metadata.
    do
        local equipped = AttachmentStore.getEquipped(player)
        local mirroredType = player:GetAttribute("EquippedAttachmentType") or "(nil)"
        if not equipped then
            -- Loud warning: if the player attribute claims something is equipped
            -- but the store says otherwise, the HUD will lie about Phoenix being
            -- ready. This was a bug we hit where the equip remote handler set
            -- the attribute even on rejected (un-owned) equips.
            if mirroredType ~= "" and mirroredType ~= "(nil)" then
                warn(("[ToL DIAG] %s placed tower with HUD-claimed-equipped=%s but AttachmentStore says nothing equipped — inconsistency"):format(
                    player.Name, mirroredType))
            else
                print(("[ToL] %s placed tower with no equipped attachment"):format(player.Name))
            end
        end
        if equipped then
            local effect = Attachments.getEffect(equipped)
            tower:SetAttribute("EquippedType", equipped.type)
            tower:SetAttribute("EquippedRarity", equipped.rarity)
            if equipped.type == "PowerCore" and type(effect) == "number" then
                local newBase = (tower:GetAttribute("DamageBase") or 18) + effect
                tower:SetAttribute("DamageBase", newBase)
                local flat = tower:GetAttribute("DamageFlat") or 0
                tower:SetAttribute("Damage", newBase + flat)
            elseif equipped.type == "Detonator" and type(effect) == "table" then
                tower:SetAttribute("DetonatorRadius", effect.radius)
                tower:SetAttribute("DetonatorHpPct", effect.hpPct)
            elseif equipped.type == "Phoenix" and type(effect) == "number" then
                tower:SetAttribute("PhoenixCooldown", effect)
                -- Carryover from the prior map's Core tower (see the
                -- boss-defeat cutscene in systems/TempTowerRewards.lua).
                -- If present, resume the cooldown state so the Phoenix
                -- reads as "the same tower in a new spot" rather than
                -- a fresh instance with a free charge.
                local carryCd    = player:GetAttribute("PhoenixCarryCdRemaining")
                local carryGrace = player:GetAttribute("PhoenixCarryGraceRemaining")
                local carryReady = player:GetAttribute("PhoenixCarryReady")
                if carryCd ~= nil or carryGrace ~= nil or carryReady ~= nil then
                    tower:SetAttribute("PhoenixReady",            carryReady == true)
                    tower:SetAttribute("PhoenixCdRemaining",      carryCd    or 0)
                    tower:SetAttribute("PhoenixGraceRemaining",   carryGrace or 0)
                    player:SetAttribute("PhoenixCarryCdRemaining",    nil)
                    player:SetAttribute("PhoenixCarryGraceRemaining", nil)
                    player:SetAttribute("PhoenixCarryReady",          nil)
                    print(("[Phoenix DIAG] carryover: cdRem=%.1f ready=%s"):format(
                        carryCd or 0, tostring(carryReady == true)))
                else
                    tower:SetAttribute("PhoenixReady", true)
                    tower:SetAttribute("PhoenixCdRemaining", 0)
                    tower:SetAttribute("PhoenixGraceRemaining", 0)
                end
                print(("[Phoenix DIAG] tower attached: cooldown=%ds (rarity %s)"):format(
                    effect, tostring(equipped.rarity)))
            end
            print(("[ToL] %s placed tower with equipped: %s"):format(
                player.Name, Attachments.describe(equipped)))
        end
    end


    player:SetAttribute(stockAttr, stock - 1)
    broadcastGrid()

    -- Dev: first Core placement after a dev map-2 teleport → run the full
    -- map-1 upgrade simulation (12 picks) against this tower. Fires a
    -- BindableEvent that the wave system listens for (cross-script call
    -- into ctx.simulateOnePick). Flag is cleared on the consumer side
    -- so a second Core placement doesn't re-simulate.
    if not isTempTower and player:GetAttribute("DevSimulateMap1OnNextCore") then
        -- Use getOrCreate: if the wave system hasn't wired its listener yet
        -- (unlikely but possible at Studio F5), firing a freshly-created
        -- bindable is a silent no-op. The flag stays consumed by the
        -- Wave-side listener when it IS wired, not here.
        local simBindable = Remotes.getOrCreate(Remotes.Names.DevSimulateMap1Picks, "BindableEvent")
        simBindable:Fire({ player = player, pickCount = 12 })
    end

    print(("[TreeOfLife] %s placed %s at (%d,%d); stock remaining = %d")
        :format(player.Name, towerType, anchorCol, anchorRow, stock - 1))
end)

------------------------------------------------------------
-- SELL TOWER — client fires SellTower with { tower }. Validates ownership,
-- costs 1 reroll token, refunds +1 stock of the tower's type, frees the
-- grid cells it occupied, and destroys the tower. The refund path is the
-- inverse of placement: same AnchorCol/Row/Footprint attributes, same
-- markCells* loop with "open" instead of "occupied". Upgrade stacks stored
-- on the player (Core/AuxDamageFlat, RangePct, etc.) stay — the sell is a
-- reposition tool, not a progression-reset. The next tower of that type
-- placed inherits the accumulated upgrades at placement time.
------------------------------------------------------------
local sellTowerRemote = ensureRemote(Remotes.Names.SellTower)
sellTowerRemote.OnServerEvent:Connect(function(player, payload)
    if type(payload) ~= "table" then return end
    local tower = payload.tower
    if typeof(tower) ~= "Instance" or not tower:IsA("Model") or not tower.Parent then
        return
    end
    if tower:GetAttribute("Owner") ~= player.UserId then
        print(("[ToL] PickUp REJECTED: %s doesn't own %s"):format(player.Name, tower.Name))
        return
    end

    -- Pick-up cost varies by tower category: Core = 3 reroll tokens, Aux = 1.
    -- Core is the more expensive retry because the player has invested
    -- upgrades into it (stamped at placement) and the pick-up lets them
    -- reposition without losing that progress.
    local isTemp = TempTowers.Templates[tower:GetAttribute("TowerType") or ""] ~= nil
    local cost = isTemp and 1 or 3
    local tokens = player:GetAttribute("RerollTokens") or 0
    if tokens < cost then
        print(("[ToL] PickUp REJECTED: %s has %d / %d reroll tokens"):format(
            player.Name, tokens, cost))
        return
    end

    local anchorCol  = tower:GetAttribute("AnchorCol")
    local anchorRow  = tower:GetAttribute("AnchorRow")
    local footprintW = tower:GetAttribute("FootprintW")
    local footprintD = tower:GetAttribute("FootprintD")
    local towerType  = tower:GetAttribute("TowerType")
    if not (anchorCol and anchorRow and footprintW and footprintD and towerType) then
        print(("[ToL] PickUp REJECTED: %s missing placement attrs"):format(tower.Name))
        return
    end

    player:SetAttribute("RerollTokens", tokens - cost)
    local stockAttr = towerType .. "Stock"
    local curStock = player:GetAttribute(stockAttr) or 0
    player:SetAttribute(stockAttr, curStock + 1)

    -- Free the cells this tower held. Use "open" (not path/heart/decor) so
    -- other towers can place here again.
    for dc = 0, footprintW - 1 do
        for dr = 0, footprintD - 1 do
            local c = anchorCol + dc
            local r = anchorRow + dr
            if gridState[c] and gridState[c][r] == "occupied" then
                gridState[c][r] = "open"
            end
        end
    end

    tower:Destroy()
    broadcastGrid()
    showHotbarRemote:FireClient(player)  -- refresh hotbar so new stock count shows
    print(("[ToL] %s picked up %s (+1 %sStock, -%d RerollTokens)"):format(
        player.Name, towerType, towerType, cost))
end)


stageAdvancedBindable.Event:Connect(function(payload)
    -- Backwards-compat: old wave system sent a number; new one sends a table.
    local stage, mapId
    if type(payload) == "table" then
        stage = payload.stage
        mapId = payload.mapId or 1
    else
        stage = payload
        mapId = 1
    end
    print(("[TreeOfLife] Stage advanced to %d (map %d) — applying visuals"):format(stage, mapId))

    if mapId == 1 then
        ctx.tweenStageLighting(stage)
        ctx.growStageDecor(stage)
    elseif mapId == 2 then
        ctx.tweenStageLightingMap2(stage)
        ctx.applyMap2StageVisuals(stage)
    end
end)

------------------------------------------------------------
-- DEV REMOTES — DevReset, SetTowerTargetMode, BossDefeated handlers,
-- attachment endpoints. Extracted to src/server/systems/DevRemotes.lua
-- (Phase 2 commit 9).
------------------------------------------------------------
ctx.RunState      = RunState
ctx.broadcastGrid = broadcastGrid

local DevRemotes = require(script.Parent:WaitForChild("systems"):WaitForChild("DevRemotes"))
DevRemotes.setup(ctx)

-- TempTowerRewards — 3-card picker shown on map boss defeat. Listens to
-- BossDefeated ({mapId}), rolls cards with rarity-scaled stats, handles
-- duplicate-as-reroll-token replacement, and grants <TowerId>Rarity /
-- <TowerId>Stock attributes on pick.
local TempTowerRewards = require(script.Parent:WaitForChild("systems"):WaitForChild("TempTowerRewards"))
TempTowerRewards.setup(ctx)

-- PermanentTowers — pedestal equip flow. Pedestal geometry lives in Map2.lua
-- (rises after a map boss is defeated) and fires OpenPermanentEquip on prompt
-- trigger. This system handles the collection modal, DataStore persistence,
-- and run-start / map-transition stock grants for the equipped permanent tower.
local PermanentTowers = require(script.Parent:WaitForChild("systems"):WaitForChild("PermanentTowers"))
PermanentTowers.setup(ctx)

print("[TreeOfLife] v5.10.13 server ready. Grid: " .. GRID_COLS .. "x" .. GRID_ROWS)
