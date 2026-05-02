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
--   - fireLeafMessage helper (published on ctx for TowerPlacement +
--     Map2 to fire narrative leaf messages on map entry)
--   - Grid serialization: encodeGridState, broadcastGrid. The Model
--     builders live in src/server/TowerBuilders.lua (ctx.TOWER_BUILDERS);
--     the TowerPicked / PlaceTower / SellTower handlers (along with
--     canPlaceAt, markCellsOccupied, the MAP1_LEAF_LINES intro text)
--     live in src/server/systems/TowerPlacement.lua.
--   - PlayerAdded handler (attachment loading, CharacterAdded attr
--     seeding)
--   - StageAdvanced dispatcher (forwards to ctx.tweenStageLighting /
--     ctx.applyMap2StageVisuals by mapId)
--
-- MODULE SETUP ORDER (the load-bearing part of this file):
--   HubWorld → TdRoom → Grid → Map2 → StageVisuals → Map2StageVisuals
--            → TowerBuilders → Portal → DevRemotes → TempTowerRewards
--            → PermanentTowers → TowerPlacement
-- TowerPlacement runs LAST so ctx.TOWER_BUILDERS / broadcastGrid /
-- grantPermanentStock are all published by the time it reads them.
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
--   Player: PowerStock, ControlCoreStock, SupportCoreStock, CarryingAmmo, MaxCarry, RerollsUsed,
--           HasBeenGrantedStock, HasReceivedFreeReward,
--           DevUnlimitedAmmo, WaveAutoStartScheduled
--           (Final-boss bonus damage moved to FinalBoss.lua's rolling stack
--            in 2026-04 — was a (BonusDamageUntil, BonusDamageExtraPct)
--            attribute pair. No longer player-attribute state.)
--   Heart:  Health, MaxHealth
--
-- ============================================================

local Workspace = game:GetService("Workspace")
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

-- Shared constants modules. Single source of truth for Remote/Bindable
-- names, CollectionService tags, and game-wide config. See src/shared/.
local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local Tags        = require(Shared:WaitForChild("Tags"))
local Config      = require(Shared:WaitForChild("Config"))
-- AttachmentStore (v2): persistent per-player attachment system. Used
-- here by the PlayerAdded handler to pre-load inventory on join.
-- TowerTypes / TempTowers / Attachments requires moved into
-- TowerBuilders.lua + systems/TowerPlacement.lua along with their
-- consumers.
local AttachmentStore = require(ServerScriptService:WaitForChild("AttachmentStore"))

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
local MAP2_TOTAL_COLS = MAP2_COL_OFFSET + MAP2_COLS  -- 135: end of map 2 / start of map 3

-- Map 3 ("Canopy / Nest") parameters. 20% larger than map 2 — by stage 3
-- the player has range-extended towers, so the arena needs to be more open
-- to make positioning matter. Lives 500 studs above map 2 in world space.
-- Grid cols [MAP3_COL_OFFSET..MAP3_TOTAL_COLS-1] in the shared grid.
local MAP3_CENTER     = Vector3.new(2000, 1000, 0)
local MAP3_WIDTH      = 180     -- 150 * 1.20
local MAP3_DEPTH      = 132     -- 110 * 1.20
local MAP3_HEIGHT     = 65      -- taller for openness; nest sits in open canopy
local MAP3_COLS       = MAP3_WIDTH / CELL_SIZE   -- 90
local MAP3_ROWS       = MAP3_DEPTH / CELL_SIZE   -- 66
local MAP3_COL_OFFSET = MAP2_TOTAL_COLS          -- 135: map 3 starts where map 2 ends
local MAP3_TOTAL_COLS = MAP3_COL_OFFSET + MAP3_COLS  -- 225 total cols in shared grid

-- Map 4 ("Pickle Swamp" — Infinite Arena) parameters. Same footprint
-- as map 3 ("more or less" per Matthew). Lives far away on the X axis
-- so its lighting + grid don't collide with the main-run maps. The
-- hub-portal cinematic + Infinite system handle the teleport.
local MAP4_CENTER     = Vector3.new(8000, 100, 0)
local MAP4_WIDTH      = 180
local MAP4_DEPTH      = 132
local MAP4_HEIGHT     = 80      -- open sky for steam clouds + tall pickle trees
local MAP4_COLS       = MAP4_WIDTH / CELL_SIZE   -- 90
local MAP4_ROWS       = MAP4_DEPTH / CELL_SIZE   -- 66
local MAP4_COL_OFFSET = MAP3_TOTAL_COLS          -- 225
local MAP4_TOTAL_COLS = MAP4_COL_OFFSET + MAP4_COLS  -- 315

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

ensureRemote(Remotes.Names.EnterPortal)
local splashRemote        = ensureRemote(Remotes.Names.ShowSplash)
ensureRemote(Remotes.Names.ShowIntro)
local towerSelectRemote   = ensureRemote(Remotes.Names.ShowTowerSelect)
-- TowerPicked + PlaceTower remotes are created here so TowerPlacement.lua's
-- WaitForChild resolves at its setup time. Handlers live in that module.
ensureRemote(Remotes.Names.TowerPicked)
ensureRemote(Remotes.Names.PlaceTower)
ensureRemote(Remotes.Names.ShowHotbar)
local gridUpdateRemote    = ensureRemote(Remotes.Names.GridUpdate)
ensureRemote(Remotes.Names.DevReset)
ensureRemote(Remotes.Names.DevTeleport)  -- client → server: teleport to hub/map1/map2 + start waves
-- DevMoveToMapStart remote is created here only so Portal.lua's WaitForChild
-- resolves immediately at server boot. Handler lives in Portal.lua. No local
-- binding needed since Hub doesn't consume it.
ensureRemote(Remotes.Names.DevMoveToMapStart)
ensureRemote(Remotes.Names.DevCycleMapStage)  -- dev: cycle visual stage 1→2→3→4 for a given mapId
ensureRemote(Remotes.Names.DevStartBirdBoss)  -- dev (legacy): manual bird-boss trigger; auto-fires on stage 4 now
ensureRemote(Remotes.Names.BirdClick)         -- client → server: click landed on the bird (10 escapes a grab)
ensureRemote(Remotes.Names.BirdBossCountdown) -- server → client: 1Hz survival countdown for the map-3 night phase
ensureRemote(Remotes.Names.BirdGrabState)     -- server → grabbed-player only: yellow "X TAPS LEFT" indicator state
ensureRemote(Remotes.Names.SetTowerTargetMode)
ensureRemote(Remotes.Names.PickupHoldStart)  -- client → server: E pressed near a pile, start rapid pickup loop
ensureRemote(Remotes.Names.PickupHoldStop)   -- client → server: E released, stop the loop
ensureRemote(Remotes.Names.RerollUpgrades)

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

-- Build GridConfig with ALL its children BEFORE parenting to
-- ReplicatedStorage. Otherwise client-side `WaitForChild(GridConfig)`
-- can resolve while the folder is still empty (parent assignment
-- runs first, child setNum() calls follow), and the subsequent
-- `WaitForChild("Map2CenterX")` blocks for >5s → "Infinite yield
-- possible" warning. Atomic-parent fix per ea3-227.
local gridConfig = ReplicatedStorage:FindFirstChild(Remotes.Names.GridConfig)
if gridConfig then gridConfig:Destroy() end
gridConfig = Instance.new("Folder")
gridConfig.Name = Remotes.Names.GridConfig
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
    -- Map 3 geometry (mirrors Map2* keys). Client uses these to raycast
    -- map 3's floor and translate hits into shared-grid (col, row).
    setNum("Map3CenterX", MAP3_CENTER.X)
    setNum("Map3CenterY", MAP3_CENTER.Y)
    setNum("Map3CenterZ", MAP3_CENTER.Z)
    setNum("Map3Width", MAP3_WIDTH)
    setNum("Map3Depth", MAP3_DEPTH)
    setNum("Map3Cols", MAP3_COLS)
    setNum("Map3Rows", MAP3_ROWS)
    setNum("Map3ColOffset", MAP3_COL_OFFSET)
    setNum("Map3TotalCols", MAP3_TOTAL_COLS)
    setNum("Map3FloorY", MAP3_CENTER.Y + 1)
    -- Map 4 (Pickle Swamp / Infinite Arena) geometry.
    setNum("Map4CenterX", MAP4_CENTER.X)
    setNum("Map4CenterY", MAP4_CENTER.Y)
    setNum("Map4CenterZ", MAP4_CENTER.Z)
    setNum("Map4Width", MAP4_WIDTH)
    setNum("Map4Depth", MAP4_DEPTH)
    setNum("Map4Cols", MAP4_COLS)
    setNum("Map4Rows", MAP4_ROWS)
    setNum("Map4ColOffset", MAP4_COL_OFFSET)
    setNum("Map4TotalCols", MAP4_TOTAL_COLS)
    setNum("Map4FloorY", MAP4_CENTER.Y + 1)
end
-- Atomic-parent: client's WaitForChild(GridConfig) doesn't fire
-- until the folder + every NumberValue child is live in one beat.
gridConfig.Parent = ReplicatedStorage

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
ctx.MAP3_CENTER            = MAP3_CENTER
ctx.MAP3_WIDTH             = MAP3_WIDTH
ctx.MAP3_DEPTH             = MAP3_DEPTH
ctx.MAP3_HEIGHT            = MAP3_HEIGHT
ctx.MAP3_COLS              = MAP3_COLS
ctx.MAP3_ROWS              = MAP3_ROWS
ctx.MAP3_COL_OFFSET        = MAP3_COL_OFFSET
ctx.MAP3_TOTAL_COLS        = MAP3_TOTAL_COLS
ctx.MAP4_CENTER            = MAP4_CENTER
ctx.MAP4_WIDTH             = MAP4_WIDTH
ctx.MAP4_DEPTH             = MAP4_DEPTH
ctx.MAP4_HEIGHT            = MAP4_HEIGHT
ctx.MAP4_COLS              = MAP4_COLS
ctx.MAP4_ROWS              = MAP4_ROWS
ctx.MAP4_COL_OFFSET        = MAP4_COL_OFFSET
ctx.MAP4_TOTAL_COLS        = MAP4_TOTAL_COLS
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
-- 2026-05-01 ea3-161: shared GoldenPickleHeart builder. Adds tag,
-- attributes, body + bumps + stem + light. HP bar billboards still
-- live here so the per-map UI specifics (anchor offset, billboard
-- size, refresh closure) stay in the world file.
local GoldenPickleHeart = require(script.Parent:WaitForChild("world"):WaitForChild("GoldenPickleHeart"))
local PICKLE_GOLD = GoldenPickleHeart.PICKLE_GOLD
local heart = GoldenPickleHeart.create({
    name = "TreeHeart",
    mapId = 1,
    position = heartWorldPos,
    height = 12,
    width = 6,
    maxHp = 1000,
    parent = tdRoom,
})

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
hpBillboard.Size = UDim2.fromOffset(140, 28)
hpBillboard.AlwaysOnTop = true
hpBillboard.LightInfluence = 0
hpBillboard.MaxDistance = 250
hpBillboard.StudsOffset = Vector3.new(0, 0, 0)
hpBillboard.Parent = hpAnchor

local hpBg = Instance.new("Frame")
hpBg.Size = UDim2.fromScale(1, 1)
hpBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
hpBg.BackgroundTransparency = 0.2
hpBg.BorderSizePixel = 0
hpBg.Parent = hpBillboard

local hpFill = Instance.new("Frame")
hpFill.Size = UDim2.new(1, -4, 1, -4)
hpFill.Position = UDim2.fromOffset(2, 2)
hpFill.BackgroundColor3 = PICKLE_GOLD  -- match the Golden Pickle glow
hpFill.BorderSizePixel = 0
hpFill.Parent = hpBg

local hpText = Instance.new("TextLabel")
hpText.Size = UDim2.fromScale(1, 1)
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
labelBillboard.Size = UDim2.fromOffset(200, 24)
labelBillboard.AlwaysOnTop = true
labelBillboard.LightInfluence = 0
labelBillboard.MaxDistance = 250
-- Lifted from 1.5 → 3.0 per Matthew 2026-05-02 ea3-182 — the
-- "GOLDEN PICKLE" title was visually clipping into the HP bar
-- frame at the prior offset.
labelBillboard.StudsOffset = Vector3.new(0, 3.0, 0)
labelBillboard.Parent = hpAnchor

local labelText = Instance.new("TextLabel")
labelText.Size = UDim2.fromScale(1, 1)
labelText.BackgroundTransparency = 1
labelText.Text = "GOLDEN PICKLE"
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
-- Extracted to src/server/world/Map2.lua.
------------------------------------------------------------
-- Falling-leaf message helper. Defined in the hub (not Map2) because
-- the map-1 portal handler further below also calls it.
local leafMessageRemote_outer = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)
-- 4th param `priority` (boolean): when true, the client clears any
-- pending queued leaves AND fast-forwards whatever leaf is on screen
-- so this one lands within ~0.25s. Used by the Pickle Lord cinematic
-- so "something ancient approaches…" pops up the instant the camera
-- takes over even if a temp-tower-reward leaf is still mid-drift.
local function fireLeafMessage(player, text, duration, priority)
    if not leafMessageRemote_outer then
        leafMessageRemote_outer = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)
    end
    if leafMessageRemote_outer then
        leafMessageRemote_outer:FireClient(player, {
            text     = text,
            duration = duration or 6,
            priority = priority and true or nil,
        })
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

-- Map3Stage namespace — populated in-place by Map3.setup (small branches,
-- flowers, butterflies) and read by Map3StageVisuals.setup (per-stage
-- scale + visibility). Same shared-table pattern as Map2Stage.
ctx.Map3Stage = {
    smallBranches = {},
    flowers       = {},
    butterflies   = {},
}
ctx.applyMap3Stage1OnEntry = function() end

local Map3 = require(script.Parent:WaitForChild("world"):WaitForChild("Map3"))
Map3.setup(ctx)

------------------------------------------------------------
-- Map 4 — Pickle Swamp / Infinite Arena terrain.
-- Entered via the hub portal, not via SwitchMap. See
-- world/Map4.lua + systems/Infinite.lua.
------------------------------------------------------------
local Map4 = require(script.Parent:WaitForChild("world"):WaitForChild("Map4"))
Map4.setup(ctx)

------------------------------------------------------------
-- STAGE VISUALS (map 1 + map 2)
-- Extracted to src/server/systems/StageVisuals.lua
-- and  src/server/systems/Map2StageVisuals.lua.
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

-- Zombie rig: install one static, anchored R6 rig in
-- ReplicatedStorage.Models.ZombieRig so Lily can open it from
-- Studio Explorer and animate it via the Animation Editor. Idempotent
-- on re-runs. Spawn-side integration (replace stage-boss + map-1
-- boss visuals) is a follow-up commit; this just delivers the rig.
do
    local ZombieRig = require(script.Parent:WaitForChild("world"):WaitForChild("ZombieRig"))
    ZombieRig.installSample()
end

local StageVisuals = require(script.Parent:WaitForChild("systems"):WaitForChild("StageVisuals"))
StageVisuals.setup(ctx)

local Map2StageVisuals = require(script.Parent:WaitForChild("systems"):WaitForChild("Map2StageVisuals"))
Map2StageVisuals.setup(ctx)

local Map3StageVisuals = require(script.Parent:WaitForChild("systems"):WaitForChild("Map3StageVisuals"))
Map3StageVisuals.setup(ctx)

-- Map 3 Bird Boss phase — auto-triggered when stage 4 (Night) begins on
-- map 3 (see Portal.lua's DevCycleMapStage handler / wave system stage
-- advance). Publishes ctx.startBirdBoss / ctx.stopBirdBoss.
local Map3BirdBoss = require(script.Parent:WaitForChild("systems"):WaitForChild("Map3BirdBoss"))
Map3BirdBoss.setup(ctx)

-- Pickle Lord — RUN BOSS that follows the bird. Self-triggers on
-- BossRewardClaimed mapId=3 (i.e. AFTER the player has claimed their
-- map-3 temp-tower reward). On HP=0 fires PickleLordDefeated which
-- PermanentTowers.lua picks up to show the permanent picker; permanent
-- claim chains to RunVictory → return to hub. See PickleLordBoss.lua's
-- module header + docs/pickle-lord-spec.md for the full encounter spec.
-- Lives in HubContext (alongside Map3BirdBoss) because the encounter
-- shares the map-3 arena geometry and lighting hooks.
local PickleLordBoss = require(script.Parent:WaitForChild("systems"):WaitForChild("PickleLordBoss"))
PickleLordBoss.setup(ctx)

-- Serialize ALL FOUR maps' cells, row-major over the shared grid's full extent
-- (cols 0..MAP4_TOTAL_COLS-1, rows 0..MAX_GRID_ROWS-1). MUST match the client
-- decoder's iteration in init.client.lua — if these diverge by a single col,
-- every row offsets by that delta and the entire grid renders as scattered
-- patches because path cells get plotted at the wrong (col, row).
-- Per playtest 2026-04-27: the previous version used MAP3_TOTAL_COLS=225
-- but client had bumped to mapCfg[4].totalCols=315 → 90-col-per-row drift
-- → "patches on the grid" that don't match the actual path.
local MAX_GRID_ROWS = ctx.MAX_GRID_ROWS
local function encodeGridState()
    local chars = {}
    for r = 0, MAX_GRID_ROWS - 1 do
        for c = 0, MAP4_TOTAL_COLS - 1 do
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

    -- 2026-04-28 di: stale DoTStock/CCStock zeroing dropped (DoT
    -- and CC archetype cards removed from the picker). The 3
    -- enabled Cores all init to 0 here; whichever the player picks
    -- gets bumped to 1 in TowerPlacement.lua's TowerPicked handler.
    player:SetAttribute("PowerStock", 0)
    player:SetAttribute("ControlCoreStock", 0)
    player:SetAttribute("SupportCoreStock", 0)
    player:SetAttribute("CarryingAmmo", 0)
    player:SetAttribute("MaxCarry", 15)
    player:SetAttribute("RerollsUsed", 0)
    -- RerollTokens: per-run currency granted +1 on each stage boss kill
    -- (all 3 stages per map). Spent on upgrade-picker rerolls and on
    -- SELL (1 token per tower sold). Starting amount = 3 (everyone, dev
    -- and otherwise) so a fresh run has enough to recover from one or
    -- two bad upgrade rolls without grinding for a stage-boss kill
    -- first. Run-scoped: SwitchMap tops back up to 3 between maps;
    -- RunReset / DevReset restore to 3 on retry.
    player:SetAttribute("RerollTokens", 3)
    -- AuxRerollsRemaining: 1 free reroll per run on the temp-tower
    -- picker (post-map-boss-defeat), per Matthew 2026-04-28 du "give
    -- one aux tower reroll per run." Decremented by the
    -- TempTowerRewards.RerollAuxReward handler on use. Reset on
    -- PlayerAdded + RunReset so each fresh run starts with one.
    player:SetAttribute("AuxRerollsRemaining", 1)
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


------------------------------------------------------------
-- PORTAL — hub-tree doorway + dev teleport
-- Extracted to src/server/world/Portal.lua.
------------------------------------------------------------
local Portal = require(script.Parent:WaitForChild("world"):WaitForChild("Portal"))
Portal.setup(ctx)

-- ============================================================
-- Infinite — Phase-1 Balance Studio entry/exit. Must run AFTER
-- Map4.setup (publishes ctx.MAP4_PLAYER_SPAWN_CF, ctx.map4Heart,
-- ctx.map4Room) AND AFTER Portal.setup (publishes ctx.HUB_SPAWN_CF).
-- See systems/Infinite.lua.
-- ============================================================
local Infinite = require(script.Parent:WaitForChild("systems"):WaitForChild("Infinite"))
Infinite.setup(ctx)
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
    elseif mapId == 3 then
        ctx.tweenStageLightingMap3(stage)
        ctx.applyMap3StageVisuals(stage)
        -- Stage 4 = Night = bird boss phase auto-starts.
        if stage == 4 and ctx.startBirdBoss then
            ctx.startBirdBoss()
        elseif stage ~= 4 and ctx.stopBirdBoss then
            ctx.stopBirdBoss()
        end
    end
end)

------------------------------------------------------------
-- DEV REMOTES — DevReset, SetTowerTargetMode, BossDefeated handlers,
-- attachment endpoints. Extracted to src/server/systems/DevRemotes.lua.
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

-- CoreUpgrades — per-Core upgrade picker shown after each map boss
-- (Phase B: UI shell only — see memory project_core_upgrade_picker.md).
-- Listens to BossRewardClaimed (fired AFTER TempTowerRewards' temp picker
-- closes + cutscene completes) so the Core picker doesn't overlap with
-- the temp-tower flow. Picks stamp `<UpgradeId>Stacks` attributes; Phase
-- C will wire each of the 9 upgrade ids to actual gameplay effects.
local CoreUpgrades = require(script.Parent:WaitForChild("systems"):WaitForChild("CoreUpgrades"))
CoreUpgrades.setup(ctx)

-- PermanentTowers — pedestal equip flow. Pedestal geometry lives in Map2.lua
-- (rises after a map boss is defeated) and fires OpenPermanentEquip on prompt
-- trigger. This system handles the collection modal, DataStore persistence,
-- and run-start / map-transition stock grants for the equipped permanent tower.
local PermanentTowers = require(script.Parent:WaitForChild("systems"):WaitForChild("PermanentTowers"))
PermanentTowers.setup(ctx)

------------------------------------------------------------
-- TOWER PLACEMENT — TowerPicked + PlaceTower + SellTower handlers.
-- Extracted to src/server/systems/TowerPlacement.lua. Runs last so it
-- can read ctx.TOWER_BUILDERS (TowerBuilders), ctx.broadcastGrid, and
-- ctx.grantPermanentStock (PermanentTowers) — all of which must be
-- published before this setup.
------------------------------------------------------------
local TowerPlacement = require(script.Parent:WaitForChild("systems"):WaitForChild("TowerPlacement"))
TowerPlacement.setup(ctx)
-- ea3-49 Phase C: role-aware autoplace scoring (Core central /
-- Control corners / DPS path coverage / Support aura overlap).
-- Used by the new sweep runner (commit D) for tower placement
-- on Map 4. Setup AFTER TowerPlacement so gridState + canPlaceAt
-- are available via ctx.
local AutoPlaceStrategy = require(script.Parent:WaitForChild("systems"):WaitForChild("AutoPlaceStrategy"))
AutoPlaceStrategy.setup(ctx)
ctx.findOptimalPlacementCell = AutoPlaceStrategy.findOptimalCell

-- ea3-50 Phase D: ArenaSweepRunner orchestrates one-combo sweeps
-- through the 4-phase bounds-shrinking arena. Setup AFTER
-- AutoPlaceStrategy so ctx.findOptimalPlacementCell is available.
local ArenaSweepRunner = require(script.Parent:WaitForChild("systems"):WaitForChild("ArenaSweepRunner"))
ArenaSweepRunner.setup(ctx)
ctx.runArenaSweepCombo = ArenaSweepRunner.runOneCombo
ctx.isArenaSweepActive = ArenaSweepRunner.isActive

-- ea3-116: precompute the optimal INFINITE_PATTERN slot table via
-- AutoPlaceStrategy and install it into InfinitePathGeometry so the
-- closed-form simulator scores against the SAME cells that v2's
-- runFailureCurveCombo would actually use. Without this, the sim
-- assumes the legacy hand-tuned slot table (corners-first, ~25%
-- range bulging off-map) while v2 places at AutoPlaceStrategy's
-- max-path-coverage cells — validator delta would be inflated by
-- placement variance instead of measuring true sim model error.
--
-- One-time computation at server boot (~36 findOptimalCell calls).
-- Cost is bounded — bulk of the iteration is the role-DPS slots
-- which scan the full active grid (~2640 cells × ~380 path-overlap
-- ops each). Total ~36s of CPU at boot is acceptable; matches the
-- Map4 setup time for parts/waypoints/etc.
do
    local InfinitePathGeometry = require(script.Parent:WaitForChild("systems"):WaitForChild("InfinitePathGeometry"))
    local computed = AutoPlaceStrategy.computeInfinitePattern({})
    if computed and #computed > 0 then
        InfinitePathGeometry.setInfinitePattern(computed)
    end
end

print(("[TreeOfLife] v5.10.13 server ready (build %s). Grid: %dx%d"):format(
    Config.BuildTag, GRID_COLS, GRID_ROWS))
