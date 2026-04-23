-- TreeOfLife_Hub.lua
-- Hub world server. Owns: hub geometry (clearing, tree, portal), TD room
-- (walls, floor, grid, path, heart, ammo piles), tower placement, ammo
-- carry/load flow, tower target-mode HUD support, dev reset, stage lighting
-- and decor transitions.
--
-- Companion script: TreeOfLife_WaveSystem (mob spawning, tower firing,
-- wave progression, upgrade picker generation). The two scripts communicate
-- via RemoteEvents in ReplicatedStorage and a few BindableEvents.
--
-- Companion script: TreeOfLife_Client (LocalScript). Handles all UI and
-- input: placement ghost, hotbar, target-mode HUD, upgrade picker, wave
-- HUD, game over modal, attachment inventory.
--
-- ============================================================
-- ARCHITECTURE NOTES (read before editing)
-- ============================================================
--
-- DEPENDENCY LAYERS (top of file = first to load = lowest layer):
--   L0  Services + module requires + remote setup    (lines ~24-160)
--   L1  Constants + helpers (makePart, splines)      (lines ~160-300)
--   L2  Geometry builders (trees, branches, room)    (lines ~300-1000)
--   L3  Grid state + tower builder                   (lines ~1000-1300)
--   L4  Player flow (PlayerAdded, character handlers,
--       tower placement, target-mode handler)        (lines ~1300-1600)
--   L5  STAGE_LIGHTING + lighting/decor functions    (lines ~1600-1860)
--   L6  Stage-advance handler + DEV RESET            (lines ~1860-1950)
--   L7  Ammo carry+load, attachment endpoints,
--       boss-defeated handler                        (lines ~1950-end)
--
-- EDITING RULES:
--   1. Functions must be declared BEFORE any function that calls them.
--      Lua resolves non-local identifiers as globals at function-DEFINITION
--      time (not call time). A late-declared local resolves to nil global
--      in earlier closures and crashes only on the code path that exercises
--      the call. Don't add forward-decl shims (`local foo = nil`); instead,
--      put the dependency above the consumer.
--   2. Stage lighting + decor block (L5) must stay above DevReset (L6)
--      because DevReset calls cancelLightingTweens() and reads STAGE_LIGHTING.
--
-- TOWER + PLAYER ATTRIBUTES (don't add new ones without a comment):
--   Tower:  Damage, DamageBase, DamageBonusPct, Range, RangeBase, RangeBonusPct,
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
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

-- Shared constants modules. Single source of truth for Remote/Bindable
-- names, CollectionService tags, and game-wide config. See src/shared/.
local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Tags    = require(Shared:WaitForChild("Tags"))
local Config  = require(Shared:WaitForChild("Config"))

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
local towerSelectRemote   = ensureRemote(Remotes.Names.ShowTowerSelect)
local towerPickedRemote   = ensureRemote(Remotes.Names.TowerPicked)
local placeTowerRemote    = ensureRemote(Remotes.Names.PlaceTower)
local showHotbarRemote    = ensureRemote(Remotes.Names.ShowHotbar)
local gridUpdateRemote    = ensureRemote(Remotes.Names.GridUpdate)
local devResetRemote      = ensureRemote(Remotes.Names.DevReset)
local devTeleportRemote   = ensureRemote(Remotes.Names.DevTeleport)  -- client → server: teleport to hub/map1/map2 + start waves
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

-- Bridge ctx fields back to the locals the rest of this file still uses.
-- These bridge locals disappear in Phase 2's final commit once the
-- downstream code has been extracted too.
local hub = ctx.hub
local treeBase = ctx.treeBase
local trunkSurfaceZ = ctx.trunkSurfaceZ
local portal = ctx.portal

-- ============================================================
-- TdRoom — map 1 TD room geometry (walls, floor, ceiling, light shafts)
-- ============================================================
local TdRoom = require(script.Parent:WaitForChild("world"):WaitForChild("TdRoom"))
TdRoom.setup(ctx)

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
local pathHalf = ctx.pathHalf
local MAX_GRID_ROWS = ctx.MAX_GRID_ROWS

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

-- Map2Stage namespace — populated in-place by Map2.setup and read by
-- the MAP 2 STAGE VISUALS section below. ctx.Map2Stage holds the
-- SAME table reference; mutations are visible to both readers.
local Map2Stage = {
    bushLobes    = {},
    fireflies    = {},
    stairParts   = {},
    baseStairTotalHeight = 0,
}

-- Late-resolved through ctx. Initial stub; the MAP 2 STAGE VISUALS
-- section below overwrites ctx.applyMap2Stage1OnEntry with the real
-- implementation. Call sites (Map2's portal handler, hub's dev
-- teleport) read ctx at call time so they pick up the overwrite.
ctx.applyMap2Stage1OnEntry = function() end
ctx.Map2Stage              = Map2Stage
ctx.fireLeafMessage        = fireLeafMessage

local Map2 = require(script.Parent:WaitForChild("world"):WaitForChild("Map2"))
Map2.setup(ctx)

local map2Room             = ctx.map2Room
local map2Heart            = ctx.map2Heart
local MAP2_PLAYER_SPAWN_CF = ctx.MAP2_PLAYER_SPAWN_CF
local MAP2_AMMO_SW_POS     = ctx.MAP2_AMMO_SW_POS
local MAP2_AMMO_SE_POS     = ctx.MAP2_AMMO_SE_POS

------------------------------------------------------------
-- MAP 2 STAGE VISUALS
--
-- Driven by StageAdvanced when currentMapId == 2. Three stage progressions:
-- lighting (early morning → morning → midday → night sentinel for boss),
-- staircase growth (1/3 → 2/3 → full), bushes (2 lobes → 5 → all),
-- fireflies (small → medium → large). Stage 4 sentinel = night/boss.
------------------------------------------------------------

-- Map 2 lighting config. Mirrors STAGE_LIGHTING for map 1 but uses cooler
-- morning-forward tones since map 2 is "up in the canopy" thematically.
local STAGE_LIGHTING_MAP2 = {
    [1] = { clockTime = 5.5,  floorTint = Color3.fromRGB(110,  85,  55), ambient = Color3.fromRGB( 95,  90, 105) },  -- very early morning, cool dawn
    [2] = { clockTime = 8.5,  floorTint = Color3.fromRGB(140, 105,  65), ambient = Color3.fromRGB(140, 135, 115) },  -- warm morning
    [3] = { clockTime = 12,   floorTint = Color3.fromRGB(160, 125,  80), ambient = Color3.fromRGB(170, 160, 140) },  -- bright midday
    [4] = { clockTime = 20,   floorTint = Color3.fromRGB( 55,  45,  70), ambient = Color3.fromRGB( 45,  40,  65) },  -- twilight (boss)
}

-- Track active lighting tweens so DevReset and tweenStageLighting{,Map2}
-- can cancel them before starting a new tween. Hoisted up here (above
-- tweenStageLightingMap2) so that function can see cancelLightingTweens
-- in scope. Lua resolves free-variable references as globals at function
-- DEFINITION time, so defining a local later in the file doesn't retro-
-- actively bind — the earlier function would keep looking up a nil global.
-- (The map-1 variants tweenStageLighting / STAGE_LIGHTING remain further
-- down, but those functions are themselves defined AFTER this block so
-- they correctly capture this same cancelLightingTweens local.)
local activeLightingTween = nil
local activeFloorTween = nil

local function cancelLightingTweens()
    if activeLightingTween then activeLightingTween:Cancel(); activeLightingTween = nil end
    if activeFloorTween then activeFloorTween:Cancel(); activeFloorTween = nil end
end

local function tweenStageLightingMap2(stage)
    local cfg = STAGE_LIGHTING_MAP2[stage]
    if not cfg then return end
    cancelLightingTweens()
    local TweenService = game:GetService("TweenService")
    local info = TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
    activeLightingTween = TweenService:Create(Lighting, info,
        {ClockTime = cfg.clockTime, Ambient = cfg.ambient})
    activeLightingTween:Play()
    -- Map 2 floor is the first child named "Map2Floor" under map2Room
    local map2Room = Workspace:FindFirstChild("TreeOfLifeMap2Room")
    local map2Floor = map2Room and map2Room:FindFirstChild("Map2Floor")
    if map2Floor then
        activeFloorTween = TweenService:Create(map2Floor, info, {Color = cfg.floorTint})
        activeFloorTween:Play()
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
    local TweenService = game:GetService("TweenService")
    local buriedCount, risingCount, alreadyRisenCount = 0, 0, 0

    -- Staircase step + stringer reveal: emerge-from-ground animation.
    -- Parts with unlockStage > stairStage get buried (below floor, transparent).
    -- Parts with unlockStage <= stairStage either:
    --   - if not yet risen: tween from buried → target position (staggered)
    --   - if already risen: stay at target (no-op)
    -- Buried offset: 60 studs below target Y, fully transparent.
    local BURIED_DROP = Config.Map2.BuriedDropStuds
    local RISE_DURATION = Config.Map2.RiseDurationSeconds
    local STAGGER_PER_STEP = Config.Map2.RiseStaggerPerStep  -- seconds of delay per step index within a stage batch

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
            buriedCount = buriedCount + 1
        elseif not entry.risen then
            if animate then
                local buriedCF = entry.targetCFrame - Vector3.new(0, BURIED_DROP, 0)
                entry.part.CFrame = buriedCF
                entry.part.Transparency = 1
                entry.part.CanCollide = false
                entry.risen = true
                risingCount = risingCount + 1

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
                risingCount = risingCount + 1
            end
        else
            alreadyRisenCount = alreadyRisenCount + 1
        end
    end
    print(("[Map2Stage] applyMap2StageVisuals stage=%d animate=%s -> buried=%d, rising=%d, alreadyRisen=%d"):format(
        stage, tostring(animate), buriedCount, risingCount, alreadyRisenCount))

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

-- Implement the forward-declared stub: called when a player enters map 2
-- via the portal OR the dev teleport. Applies map 2 stage 1 lighting +
-- visuals. Animate=false because we don't want the staircase rising every
-- time the player teleports in.
ctx.applyMap2Stage1OnEntry = function()
    tweenStageLightingMap2(1)
    applyMap2StageVisuals(1, false)
end

------------------------------------------------------------
-- AMMO PILES — two piles, opposite corners on the player's (east) side.
-- Players walk up and press E / tap to pick up one package (carry limit 1).
-- Loading into a tower adds 10 shots (1 pip).
------------------------------------------------------------
local ammoPiles = {}  -- collected so we can wire up pickup handlers below

local function buildAmmoPile(center, pileName, parentModel, mapId)
    parentModel = parentModel or tdRoom
    mapId = mapId or 1
    local ammoGroup = Instance.new("Model")
    ammoGroup.Name = pileName
    ammoGroup.Parent = parentModel

    local function makeCrate(offset, size)
        makePart({
            Name = "AmmoCrate",
            Size = size,
            CFrame = CFrame.new(center + offset) * CFrame.Angles(0, math.rad(math.random(-15, 15)), 0),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(180, 140, 70):Lerp(Color3.fromRGB(155, 115, 55), math.random() * 0.3),
            Parent = ammoGroup,
        })
    end

    makeCrate(Vector3.new(-1.2, 1.2, -1.2), Vector3.new(2.2, 2.2, 2.2))
    makeCrate(Vector3.new( 1.2, 1.2, -1.2), Vector3.new(2.2, 2.2, 2.2))
    makeCrate(Vector3.new(-1.2, 1.2,  1.2), Vector3.new(2.2, 2.2, 2.2))
    makeCrate(Vector3.new( 1.2, 1.2,  1.2), Vector3.new(2.2, 2.2, 2.2))
    makeCrate(Vector3.new(-0.8, 3.4, 0), Vector3.new(2.0, 2.0, 2.0))
    makeCrate(Vector3.new( 0.8, 3.4, 0), Vector3.new(2.0, 2.0, 2.0))
    makeCrate(Vector3.new(0, 5.2, 0), Vector3.new(1.8, 1.8, 1.8))

    local ammoGlow = makePart({
        Name = "AmmoGlow",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(1.2, 1.2, 1.2),
        CFrame = CFrame.new(center + Vector3.new(0, 6.8, 0)),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(255, 200, 100),
        Transparency = 0.1,
        CanCollide = false,
        Parent = ammoGroup,
    })
    local ammoLight = Instance.new("PointLight")
    ammoLight.Color = Color3.fromRGB(255, 200, 120)
    ammoLight.Brightness = 2
    ammoLight.Range = 15
    ammoLight.Parent = ammoGlow

    local labelAnchor = makePart({
        Name = "AmmoLabelAnchor",
        Size = Vector3.new(0.1, 0.1, 0.1),
        CFrame = CFrame.new(center + Vector3.new(0, 9, 0)),
        Transparency = 1,
        CanCollide = false,
        Parent = ammoGroup,
    })
    local bb = Instance.new("BillboardGui")
    bb.Size = UDim2.new(0, 160, 0, 30)
    bb.AlwaysOnTop = true
    bb.LightInfluence = 0
    bb.MaxDistance = 120
    bb.Parent = labelAnchor
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "AMMO PILE"
    label.TextColor3 = Color3.fromRGB(255, 220, 150)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 20
    label.Parent = bb

    local prompt = Instance.new("ProximityPrompt")
    prompt.ActionText = "Hold to pick up"
    prompt.ObjectText = "Ammo"
    -- HoldDuration = 0 keeps the prompt as a pure visual hint. Actual hold
    -- detection happens on the client via UserInputService (E key down/up)
    -- because ProximityPrompt's hold semantics were unreliable here:
    -- PromptButtonHoldEnded would fire spuriously after Triggered completed,
    -- killing the loop while the player was still holding.
    prompt.HoldDuration = 0
    prompt.MaxActivationDistance = 12
    prompt.RequiresLineOfSight = false
    prompt.KeyboardKeyCode = Enum.KeyCode.E
    prompt.Parent = ammoGlow

    CollectionService:AddTag(ammoGlow, Tags.AmmoPile)
    ammoGlow:SetAttribute("MapId", mapId)
    table.insert(ammoPiles, {glow = ammoGlow, prompt = prompt})
    return ammoGlow, prompt
end

-- Pile 1: south-west (near the heart, original position)
buildAmmoPile(rc + Vector3.new(-halfW + 8, 0, halfD - 8), "AmmoPile_SW")
-- Pile 2: north-west (also on the heart side, opposite corner from SW)
buildAmmoPile(rc + Vector3.new(-halfW + 8, 0, -halfD + 8), "AmmoPile_NW")

-- MAP 2 AMMO PILES — SW and SE corners of the room (both at the BOTTOM,
-- matching the heart's SE position and the player spawn's south-center
-- view). Positions declared at module scope (MAP2_AMMO_SW_POS /
-- MAP2_AMMO_SE_POS) so bush placement can exclude their neighborhoods.
do
    local map2Room = Workspace:FindFirstChild("TreeOfLifeMap2Room")
    if map2Room then
        buildAmmoPile(MAP2_AMMO_SW_POS, "AmmoPile_Map2_SW", map2Room, 2)
        buildAmmoPile(MAP2_AMMO_SE_POS, "AmmoPile_Map2_SE", map2Room, 2)
        print("[ToL] Map 2 ammo piles built (SW + SE corners)")
    else
        warn("[ToL] Map 2 ammo piles skipped — map2Room missing")
    end
end

local function encodeGridState()
    local chars = {}
    for r = 0, GRID_ROWS - 1 do
        for c = 0, GRID_COLS - 1 do
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
    player:SetAttribute("HasReceivedFreeReward", false)
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

local TOWER_DEFS = {
    Power = {
        footprint = {4, 4},
        damage = 18, range = 30, fireRate = 1.6,
    },
}

local function buildRedPowerTower(centerPos)
    local tower = Instance.new("Model")
    tower.Name = "PowerTower"
    tower.Parent = tdRoom

    -- 4x4 footprint = 8x8 studs. All dimensions scaled ~2x from the old 2x2 tower.
    makePart({
        Name = "TowerBase",
        Shape = Enum.PartType.Cylinder,
        Size = Vector3.new(3, 7.5, 7.5),
        CFrame = CFrame.new(centerPos + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
        Material = Enum.Material.Wood,
        Color = Color3.fromRGB(95, 60, 35),
        Parent = tower,
    })
    makePart({
        Name = "TowerMidBand",
        Shape = Enum.PartType.Cylinder,
        Size = Vector3.new(1.5, 6, 6),
        CFrame = CFrame.new(centerPos + Vector3.new(0, 4, 0)) * CFrame.Angles(0, 0, math.rad(90)),
        Material = Enum.Material.Slate,
        Color = Color3.fromRGB(120, 90, 75),
        Parent = tower,
    })
    makePart({
        Name = "TowerColumn",
        Shape = Enum.PartType.Cylinder,
        Size = Vector3.new(10, 5, 5),
        CFrame = CFrame.new(centerPos + Vector3.new(0, 10, 0)) * CFrame.Angles(0, 0, math.rad(90)),
        Material = Enum.Material.Wood,
        Color = Color3.fromRGB(110, 75, 45),
        Parent = tower,
    })
    for _, y in ipairs({7, 13}) do
        makePart({
            Name = "TowerRing",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.8, 5.6, 5.6),
            CFrame = CFrame.new(centerPos + Vector3.new(0, y, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Metal,
            Color = Color3.fromRGB(180, 140, 80),
            Parent = tower,
        })
    end
    makePart({
        Name = "TowerPlatform",
        Shape = Enum.PartType.Cylinder,
        Size = Vector3.new(2, 6.8, 6.8),
        CFrame = CFrame.new(centerPos + Vector3.new(0, 16, 0)) * CFrame.Angles(0, 0, math.rad(90)),
        Material = Enum.Material.Wood,
        Color = Color3.fromRGB(85, 55, 30),
        Parent = tower,
    })
    local gem = makePart({
        Name = "TowerGem",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(4.5, 4.5, 4.5),
        CFrame = CFrame.new(centerPos + Vector3.new(0, 19.5, 0)),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(255, 70, 60),
        Transparency = 0.1,
        Parent = tower,
    })
    local gemLight = Instance.new("PointLight")
    gemLight.Color = Color3.fromRGB(255, 100, 80)
    gemLight.Brightness = 4
    gemLight.Range = 30
    gemLight.Parent = gem
    for i = 1, 4 do
        local a = (i / 4) * math.pi * 2
        makePart({
            Name = "TowerSpike",
            Size = Vector3.new(0.8, 3, 0.8),
            CFrame = CFrame.new(centerPos + Vector3.new(math.cos(a) * 2.2, 18.5, math.sin(a) * 2.2))
                     * CFrame.Angles(math.rad(15) * math.cos(a + math.pi/2), 0, math.rad(15) * math.sin(a + math.pi/2)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(220, 60, 60),
            Transparency = 0.2,
            Parent = tower,
        })
    end
    CollectionService:AddTag(tower.TowerBase, Tags.Tower)
    tower:SetAttribute("TowerType", "Power")
    tower:SetAttribute("Damage", 18)
    tower:SetAttribute("Range", 30)
    tower:SetAttribute("FireRate", 1.6)
    -- Base snapshots (immutable). Stat upgrades are ADDITIVE percentages of
    -- these base values so multiple picks don't compound exponentially.
    tower:SetAttribute("DamageBase", 18)
    tower:SetAttribute("RangeBase", 30)
    tower:SetAttribute("FireRateBase", 1.6)
    -- Cumulative bonus percentages summed across upgrade picks.
    tower:SetAttribute("DamageBonusPct", 0)
    tower:SetAttribute("RangeBonusPct", 0)
    tower:SetAttribute("FireRateBonusPct", 0)
    return tower
end

local TOWER_BUILDERS = { Power = buildRedPowerTower }

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

local spawn = Workspace:FindFirstChildOfClass("SpawnLocation")
if not spawn then
    spawn = Instance.new("SpawnLocation")
    spawn.Name = "HubSpawn"
    spawn.Size = Vector3.new(8, 1, 8)
    spawn.CFrame = CFrame.new(treeBase.X, 0.5, trunkSurfaceZ + 25)
    spawn.Anchored = true
    spawn.Neutral = true
    spawn.CanCollide = true
    spawn.Transparency = 1
    spawn.TopSurface = Enum.SurfaceType.Smooth
    spawn.Parent = Workspace
end

local TD_SPAWN_CF = CFrame.new(rc + Vector3.new(-halfW + 25, 4, 0))

local teleportCooldown = {}
local function teleportPlayer(player, targetCF)
    local now = os.clock()
    if teleportCooldown[player.UserId] and now - teleportCooldown[player.UserId] < 2 then return end
    teleportCooldown[player.UserId] = now
    local char = player.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    hrp.CFrame = targetCF
end

-- Falling-leaf helper was moved up before the map-2 do-block so its
-- reference is visible inside the map-2 portal handler's closure.

local MAP1_LEAF = "protect me, and I'll reward you"

portal.Touched:Connect(function(hit)
    local char = hit:FindFirstAncestorOfClass("Model")
    if not char then return end
    local player = Players:GetPlayerFromCharacter(char)
    if not player then return end
    teleportPlayer(player, TD_SPAWN_CF)
    remoteEnterPortal:FireClient(player)
    task.wait(0.6)
    towerSelectRemote:FireClient(player)
    -- Note: map 1 leaf message fires AFTER tower pick (in towerPickedRemote
    -- handler) so it doesn't get covered by the picker UI.
end)

local hubClick = Instance.new("ClickDetector", portal)
hubClick.MaxActivationDistance = 32
hubClick.MouseClick:Connect(function(player)
    teleportPlayer(player, TD_SPAWN_CF)
    remoteEnterPortal:FireClient(player)
    task.wait(0.6)
    towerSelectRemote:FireClient(player)
end)

------------------------------------------------------------
-- DEV TELEPORT — jump to hub / map 1 / map 2 from the dev panel.
-- For map 1 and map 2, additionally fires the SwitchMap bindable so
-- the wave system resets mobs, sets currentMapId, and auto-starts
-- wave 1 after 4.5s (same behavior as the portal). For hub, just
-- teleports without touching the wave system.
------------------------------------------------------------
local HUB_SPAWN_CF = CFrame.new(treeBase.X, 2, trunkSurfaceZ + 25)

devTeleportRemote.OnServerEvent:Connect(function(player, target)
    if type(target) ~= "string" then return end
    if target == "hub" then
        teleportPlayer(player, HUB_SPAWN_CF)
        print(("[ToL] DEV %s teleported to hub"):format(player.Name))
    elseif target == "map1" then
        teleportPlayer(player, TD_SPAWN_CF)
        -- Fire SwitchMap to reset wave system → map 1, auto-start wave 1
        local sm = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        if sm then sm:Fire({mapId = 1, mapName = "Crook of the Tree"}) end
        print(("[ToL] DEV %s teleported to map 1, wave 1 starting"):format(player.Name))
    elseif target == "map2" then
        if not MAP2_PLAYER_SPAWN_CF then
            warn("[ToL] DEV teleport to map 2 — MAP2_PLAYER_SPAWN_CF not set (map 2 block failed?)")
            return
        end
        teleportPlayer(player, MAP2_PLAYER_SPAWN_CF)
        local sm = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        if sm then sm:Fire({mapId = 2, mapName = "Climbing the Tree"}) end
        ctx.applyMap2Stage1OnEntry()
        -- Dev convenience: grant starting stock + show hotbar so the player
        -- can immediately place towers without going through the picker.
        if (player:GetAttribute("PowerStock") or 0) <= 0
           and (player:GetAttribute("DoTStock")   or 0) <= 0
           and (player:GetAttribute("CCStock")    or 0) <= 0 then
            player:SetAttribute("PowerStock", 1)
            player:SetAttribute("DoTStock", 0)
            player:SetAttribute("CCStock", 0)
            player:SetAttribute("HasBeenGrantedStock", true)
            showHotbarRemote:FireClient(player)
        end
        print(("[ToL] DEV %s teleported to map 2, wave 1 starting"):format(player.Name))
    else
        warn("[ToL] DEV teleport — unknown target: " .. tostring(target))
    end
end)

towerPickedRemote.OnServerEvent:Connect(function(player, towerType)
    if towerType == "Power" then
        player:SetAttribute("PowerStock", 1)
        player:SetAttribute("DoTStock", 0)
        player:SetAttribute("CCStock", 0)
        -- Flag so the failsafe loop doesn't re-prompt after stock hits 0 from placing
        player:SetAttribute("HasBeenGrantedStock", true)
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
            task.delay(0.4, function() fireLeafMessage(player, MAP1_LEAF, 7) end)
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
    local centerPos = Vector3.new(
        rc.X - halfW + (centerCol + 0.5) * CELL_SIZE,
        1,
        rc.Z - halfD + (centerRow + 0.5) * CELL_SIZE
    )

    local tower = builder(centerPos)
    markCellsOccupied(anchorCol, anchorRow, fw, fd)
    tower:SetAttribute("AnchorCol", anchorCol)
    tower:SetAttribute("AnchorRow", anchorRow)
    tower:SetAttribute("FootprintW", fw)
    tower:SetAttribute("FootprintD", fd)
    tower:SetAttribute("Owner", player.UserId)
    tower:SetAttribute("Ammo", 5)      -- pip count (5 = fully loaded)
    tower:SetAttribute("MaxAmmo", 5)
    tower:SetAttribute("Shots", 50)    -- actual shots remaining (10 per pip)
    tower:SetAttribute("MaxShots", 50)
    tower:SetAttribute("TargetMode", "First")  -- First | Strongest | Center | Last

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
                local pct = tower:GetAttribute("DamageBonusPct") or 0
                tower:SetAttribute("Damage", newBase * (1 + pct / 100))
            elseif equipped.type == "Detonator" and type(effect) == "table" then
                tower:SetAttribute("DetonatorRadius", effect.radius)
                tower:SetAttribute("DetonatorHpPct", effect.hpPct)
            elseif equipped.type == "Phoenix" and type(effect) == "number" then
                tower:SetAttribute("PhoenixCooldown", effect)
                tower:SetAttribute("PhoenixReady", true)
                tower:SetAttribute("PhoenixCdRemaining", 0)
                tower:SetAttribute("PhoenixGraceRemaining", 0)
                print(("[Phoenix DIAG] tower attached: cooldown=%ds Ready=true (rarity %s)"):format(
                    effect, tostring(equipped.rarity)))
            end
            print(("[ToL] %s placed tower with equipped: %s"):format(
                player.Name, Attachments.describe(equipped)))
        end
    end

    -- Ammo HUD billboard: tower name label + horizontal 5-pip bar.
    -- Each pip contains 10 vertical hash marks that drain left-to-right.
    local ammoAnchor = Instance.new("Part")
    ammoAnchor.Name = "AmmoAnchor"
    ammoAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
    ammoAnchor.Transparency = 1
    ammoAnchor.CanCollide = false
    ammoAnchor.Anchored = true
    ammoAnchor.CFrame = CFrame.new(centerPos + Vector3.new(0, 10, 0))  -- middle of tower
    ammoAnchor.Parent = tower

    local ammoBb2 = Instance.new("BillboardGui")
    ammoBb2.Size = UDim2.new(0, 180, 0, 60)  -- horizontal: wide and short
    ammoBb2.AlwaysOnTop = true
    ammoBb2.LightInfluence = 0
    ammoBb2.MaxDistance = 200
    ammoBb2.Parent = ammoAnchor

    -- Title label (tower name) on top
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, 0, 0, 22)
    nameLabel.Position = UDim2.new(0, 0, 0, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = ((tower:GetAttribute("TowerType") or "Power"):upper()) .. " TOWER"
    nameLabel.TextColor3 = Color3.fromRGB(255, 230, 180)
    nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    nameLabel.TextStrokeTransparency = 0.3
    nameLabel.Font = Enum.Font.FredokaOne
    nameLabel.TextSize = 18
    nameLabel.Parent = ammoBb2

    -- Bar container
    local ammoBar = Instance.new("Frame")
    ammoBar.Size = UDim2.new(1, 0, 0, 30)
    ammoBar.Position = UDim2.new(0, 0, 0, 24)
    ammoBar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    ammoBar.BackgroundTransparency = 0.3
    ammoBar.BorderSizePixel = 0
    ammoBar.Parent = ammoBb2
    local barCorner = Instance.new("UICorner")
    barCorner.CornerRadius = UDim.new(0.2, 0)
    barCorner.Parent = ammoBar
    local barPad = Instance.new("UIPadding")
    barPad.PaddingTop = UDim.new(0, 3)
    barPad.PaddingBottom = UDim.new(0, 3)
    barPad.PaddingLeft = UDim.new(0, 4)
    barPad.PaddingRight = UDim.new(0, 4)
    barPad.Parent = ammoBar

    -- Pip bar: pip count = MaxShots / 10. Rebuilt whenever MaxShots changes
    -- (i.e. when the player picks AmmoCapacity special). Each pip = 10 shots.
    local pips = {}
    local PIP_GAP = 0.012

    local function buildPips()
        -- Wipe any existing pips
        for _, p in pairs(pips) do
            if p.frame then p.frame:Destroy() end
        end
        table.clear(pips)

        local maxShots = tower:GetAttribute("MaxShots") or 50
        local pipCount = math.max(1, math.floor(maxShots / 10))
        local pipWidth = (1 - PIP_GAP * (pipCount + 1)) / pipCount

        for i = 1, pipCount do
            local pipFrame = Instance.new("Frame")
            pipFrame.Size = UDim2.new(pipWidth, 0, 1, 0)
            local xPos = PIP_GAP + (i - 1) * (pipWidth + PIP_GAP)
            pipFrame.Position = UDim2.new(xPos, 0, 0, 0)
            pipFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
            pipFrame.BackgroundTransparency = 0.5
            pipFrame.BorderSizePixel = 0
            pipFrame.Parent = ammoBar
            local pc = Instance.new("UICorner")
            pc.CornerRadius = UDim.new(0.2, 0)
            pc.Parent = pipFrame

            -- Hash marks: 10 thin VERTICAL bars laid out left → right inside the pip
            local hashes = {}
            local HASH_GAP = 0.04
            local HASH_W = (1 - HASH_GAP * 11) / 10
            for h = 1, 10 do
                local hash = Instance.new("Frame")
                hash.Size = UDim2.new(HASH_W, 0, 1, -4)
                local hx = HASH_GAP + (h - 1) * (HASH_W + HASH_GAP)
                hash.Position = UDim2.new(hx, 0, 0, 2)
                hash.BackgroundColor3 = Color3.fromRGB(255, 200, 100)
                hash.BorderSizePixel = 0
                hash.Parent = pipFrame
                hashes[h] = hash
            end
            pips[i] = {frame = pipFrame, hashes = hashes}
        end
    end

    local function refreshAmmoBar()
        local shots = tower:GetAttribute("Shots") or 0
        for i, pip in ipairs(pips) do
            local pipShots = math.max(0, math.min(10, shots - (i - 1) * 10))
            for h = 1, 10 do
                pip.hashes[h].BackgroundColor3 = (h <= pipShots)
                    and Color3.fromRGB(255, 200, 100)
                    or Color3.fromRGB(50, 50, 50)
            end
        end
        local pipCount = math.ceil(shots / 10)
        if tower:GetAttribute("Ammo") ~= pipCount then
            tower:SetAttribute("Ammo", pipCount)
        end
    end

    buildPips()
    refreshAmmoBar()
    tower:GetAttributeChangedSignal("Shots"):Connect(refreshAmmoBar)
    tower:GetAttributeChangedSignal("MaxShots"):Connect(function()
        buildPips()
        refreshAmmoBar()
    end)

    -- Load ProximityPrompt on the tower (shows "Load ammo" when carrying + near)
    local loadPrompt = Instance.new("ProximityPrompt")
    loadPrompt.ActionText = "Load ammo"
    loadPrompt.ObjectText = "Tower"
    loadPrompt.HoldDuration = 0
    loadPrompt.MaxActivationDistance = 20
    loadPrompt.RequiresLineOfSight = false
    loadPrompt.KeyboardKeyCode = Enum.KeyCode.E
    loadPrompt.Enabled = false  -- only enabled when player is carrying + tower < max
    loadPrompt.Parent = tower:FindFirstChild("TowerBase") or tower

    player:SetAttribute(stockAttr, stock - 1)
    broadcastGrid()

    -- First-tower-of-the-run bonus reward. Track per-player so we don't
    -- re-fire on subsequent placements within the same run.
    if not player:GetAttribute("HasReceivedFreeReward") then
        player:SetAttribute("HasReceivedFreeReward", true)
        local freeRewardBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.GiveFreeReward)
        if freeRewardBindable then
            freeRewardBindable:Fire(player)
        end
    end

    print(("[TreeOfLife] %s placed %s at (%d,%d); stock remaining = %d")
        :format(player.Name, towerType, anchorCol, anchorRow, stock - 1))
end)

------------------------------------------------------------
-- STAGE TRANSITION (server-side visuals)
-- Wave system fires StageAdvanced bindable when the player advances stages.
-- Stage 1 → 2: sun moves toward midday
-- Stage 2 → 3: sun moves toward dusk
-- Stage 4 (sentinel for final boss spawn): night, torches lit
------------------------------------------------------------
local STAGE_LIGHTING = {
    [1] = { clockTime = 7,    floorTint = Color3.fromRGB(140, 100, 60),  ambient = Color3.fromRGB(120, 100, 80) },
    [2] = { clockTime = 12,   floorTint = Color3.fromRGB(150, 110, 70),  ambient = Color3.fromRGB(160, 150, 130) },
    [3] = { clockTime = 17.5, floorTint = Color3.fromRGB(170, 100, 70),  ambient = Color3.fromRGB(180, 130, 100) },
    [4] = { clockTime = 0,    floorTint = Color3.fromRGB(50, 40, 60),    ambient = Color3.fromRGB(40, 35, 60) },
}

-- (activeLightingTween / activeFloorTween / cancelLightingTweens were
-- hoisted earlier in the file so tweenStageLightingMap2 can see them.
-- tweenStageLighting below captures those same locals because it's
-- defined AFTER them.)

local function tweenStageLighting(stage)
    local cfg = STAGE_LIGHTING[stage]
    if not cfg then return end
    cancelLightingTweens()
    local TweenService = game:GetService("TweenService")
    local info = TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
    activeLightingTween = TweenService:Create(Lighting, info,
        {ClockTime = cfg.clockTime, Ambient = cfg.ambient})
    activeLightingTween:Play()
    if floor and floor.Parent then
        activeFloorTween = TweenService:Create(floor, info, {Color = cfg.floorTint})
        activeFloorTween:Play()
    end
end

local function clearStageDecor()
    local existing = tdRoom:FindFirstChild("StageDecor")
    if existing then existing:Destroy() end
end

-- Trees are pressed against (or slightly into) the inside of the walls.
-- Stages ADD to the existing decor folder rather than replacing it, so
-- stage 3's trees layer on top of stage 2's. Trees on the west wall skip
-- positions that would clip the heart (see placeTreeRing).

-- Trees are wrapped in a Model so we can identify and re-tween the existing
-- ones on the Day → Dusk transition. The Model has a "TreeX"/"TreeZ"
-- position attribute and a "GrowStage" attribute (1 = small at spawn,
-- 2 = stage-2 grown, 3 = stage-3 grown bigger).
local function spawnTree(decor, x, z, tweenDelay)
    local TweenService = game:GetService("TweenService")
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
    local TweenService = game:GetService("TweenService")
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
                -- Trunk grows TALLER and a touch thicker
                TweenService:Create(trunk, info, {
                    Size = Vector3.new(targetTrunkHeight, 2.2, 2.2),
                    CFrame = CFrame.new(x, targetTrunkHeight / 2, z)
                        * CFrame.Angles(0, 0, math.rad(90)),
                }):Play()
                -- Canopy grows BIGGER and rises with the trunk
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

-- Compute world position of heart (cell 4, 28) so stage 3 trees that push
-- deeper into the arena don't overlap it.
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
            -- Evenly distributed slot position with a bit of jitter
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
                -- Skip this slot if it would clip the heart
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
        -- First: grow the stage-2 trees taller and bigger (visible change
        -- the player sees on existing trees they've been looking at all stage)
        growExistingTrees(12, 10)
        -- Then: layer in new trees pushed slightly into the arena
        placeTreeRing(decor, 10, 3.5, 0.03, 20)
    end

    -- Stage 4 (night/final boss): add torches at fixed positions, evenly
    -- spaced around the room perimeter just inside the walls.
    if stage >= 4 then
        local torchInset = 3
        local torchPositions = {
            -- N/S long walls: 4 torches each
            {rc.X - halfW * 0.6, rc.Z - halfD + torchInset},
            {rc.X - halfW * 0.2, rc.Z - halfD + torchInset},
            {rc.X + halfW * 0.2, rc.Z - halfD + torchInset},
            {rc.X + halfW * 0.6, rc.Z - halfD + torchInset},
            {rc.X - halfW * 0.6, rc.Z + halfD - torchInset},
            {rc.X - halfW * 0.2, rc.Z + halfD - torchInset},
            {rc.X + halfW * 0.2, rc.Z + halfD - torchInset},
            {rc.X + halfW * 0.6, rc.Z + halfD - torchInset},
            -- E/W short walls: 2 torches each
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
        tweenStageLighting(stage)
        growStageDecor(stage)
    elseif mapId == 2 then
        print(("[Map2Stage] Firing applyMap2StageVisuals(%d). stairParts count=%d, bushLobes count=%d"):format(
            stage, #Map2Stage.stairParts, #Map2Stage.bushLobes))
        tweenStageLightingMap2(stage)
        applyMap2StageVisuals(stage)
    end
end)

-- DEV RESET: clears all placed towers, resets grid, restores stock to 3.
-- Anyone in the game can fire this from the dev button.
devResetRemote.OnServerEvent:Connect(function(player)
    print(("[ToL] DEV RESET fired by %s"):format(player.Name))

    -- (1) Destroy ALL towers via CollectionService tag. This is more robust
    -- than name-matching children of tdRoom because it catches any tower
    -- regardless of parent, and matches exactly the set the wave system
    -- and Phoenix system also iterate over.
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local model = towerBase.Parent
        if model and model.Parent then
            model:Destroy()
        elseif towerBase.Parent then
            towerBase:Destroy()
        end
    end

    -- (2) Aggressive grid cleanup: any cell that ISN'T path or heart goes
    -- back to "open". This catches any stale state (occupied, reserved, etc.).
    -- Walks the FULL shared grid (both map 1 and map 2 columns) so reset
    -- works regardless of which map the player was in when they reset.
    for c = 0, MAP2_TOTAL_COLS - 1 do
        for r = 0, MAX_GRID_ROWS - 1 do
            local s = gridState[c][r]
            -- Preserve path/heart/decor so permanent geometry (staircase etc.)
            -- stays impassable to tower placement across runs.
            if s ~= "path" and s ~= "heart" and s ~= "decor" then
                gridState[c][r] = "open"
            end
        end
    end

    -- (3) Restore heart HP — both maps' hearts (each has their own MaxHealth)
    for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        h:SetAttribute("Health", h:GetAttribute("MaxHealth") or 500)
    end

    -- (4) Tell wave system to fully reset run/stage state BEFORE we rebuild
    -- hotbars, so the "waveInProgress=false" state is in place when the
    -- auto-start countdown is checked.
    do
        local runResetBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.RunReset)
        if runResetBindable then runResetBindable:Fire() end
    end

    -- (4a) Reset map 2 visuals to stage 1 (re-buries stage 2/3 staircase parts
    -- and makes their risen=false so they'll re-animate on stage advance next run)
    applyMap2StageVisuals(1, false)

    -- (5) Restore everyone's stock and attrs. Set the attribute FIRST, then
    -- wait a frame so the replication lands before we fire ShowHotbar. This
    -- prevents a race where the client rebuilds the hotbar from a stale
    -- stock value of 0.
    for _, p in ipairs(Players:GetPlayers()) do
        p:SetAttribute("PowerStock", 1)
        p:SetAttribute("DoTStock", 0)
        p:SetAttribute("CCStock", 0)
        p:SetAttribute("CarryingAmmo", 0)
        p:SetAttribute("WaveAutoStartScheduled", nil)
        p:SetAttribute("RerollsUsed", 0)
        p:SetAttribute("HasReceivedFreeReward", false)
        p:SetAttribute("BonusDamageUntil", 0)
        p:SetAttribute("MaxCarry", 15)
        p:SetAttribute("RunLuckSum", 0)
        p:SetAttribute("RunLuckCount", 0)
    end
    task.wait()  -- let attribute replication flush
    for _, p in ipairs(Players:GetPlayers()) do
        showHotbarRemote:FireClient(p)
    end

    -- (6) Reset stage visuals to stage 1. Cancel any in-flight stage-lighting
    -- tweens (forward-declared upvalues at file top let us reach them from
    -- this closure) so they don't overwrite the snap a frame later.
    do
        local existing = tdRoom:FindFirstChild("StageDecor")
        if existing then existing:Destroy() end
        cancelLightingTweens()  -- now reachable since the lighting block was moved above DevReset
        local cfg = STAGE_LIGHTING and STAGE_LIGHTING[1]
        if cfg then
            Lighting.ClockTime = cfg.clockTime
            Lighting.Ambient = cfg.ambient
            if floor and floor.Parent then floor.Color = cfg.floorTint end
        end
    end

    -- (7) Re-fire the 5-second countdown since everyone already has stock
    -- (no tower-pick event will fire after a reset).
    RunState.firstPickFired = true
    local wsRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.WaveState)
    if wsRemote then
        wsRemote:FireAllClients({
            wave = 0, totalWaves = 5, mobsAlive = 0, map = "Crook of the Tree (Morning)", stage = 1,
            inProgress = false, pendingCountdown = 5,
        })
    end
    task.delay(5, function()
        autoStartBindable:Fire(player)
    end)

    -- (8) Broadcast updated grid state to all clients
    broadcastGrid()
end)

------------------------------------------------------------
-- AMMO INTERACTION (carry flow)
-- Walk to any pile, press E / tap → pick up 1 package.
-- Walk to your tower, press E / tap → load 10 shots (1 pip) into the tower.
------------------------------------------------------------

-- Per-player carry capacity. Default = DEFAULT_MAX_CARRY; can be raised by
-- the AmmoCapacity special card (each pick adds +DEFAULT_MAX_CARRY to this).
local DEFAULT_MAX_CARRY = 15

local function getMaxCarry(player)
    return player:GetAttribute("MaxCarry") or DEFAULT_MAX_CARRY
end

-- Per-player guard: prevents stacking multiple rapid-pickup loops if the
-- player taps E repeatedly. Maps userId → "pickup" or "load" or nil.
local rapidActionInProgress = {}

local RAPID_INTERVAL = 0.15  -- seconds between repeats

-- Per-player state for the hold-to-pickup loop. holdActive[userId] = true
-- while the loop should keep iterating; flipped false on PromptButtonHoldEnded.
local holdActive = {}

-- Defensive: clear both guards if the player leaves mid-loop
Players.PlayerRemoving:Connect(function(p)
    rapidActionInProgress[p.UserId] = nil
    holdActive[p.UserId] = nil
end)

-- Wire up pickup. The pickup loop runs only while E is HELD on the
-- client. The client fires PickupHoldStart when E goes down near any
-- pile, and PickupHoldStop on E release. Server runs the rapid-pickup
-- loop between those events. This replaces an earlier ProximityPrompt
-- HoldBegan/HoldEnded approach which fired spurious end events after
-- Triggered completed, killing the loop while the player was still
-- holding. ProximityPrompts on the piles are kept as visual hints only.
pickupStartRemote.OnServerEvent:Connect(function(player)
    local userId = player.UserId
    if rapidActionInProgress[userId] then return end
    rapidActionInProgress[userId] = "pickup"
    holdActive[userId] = true
    task.spawn(function()
        while holdActive[userId] do
            local count = player:GetAttribute("CarryingAmmo") or 0
            local cap = getMaxCarry(player)
            if count >= cap then break end
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then break end
            -- Find the closest pile within 12 studs. Player may be moving
            -- between piles mid-hold, so re-resolve each iteration rather
            -- than locking onto whichever pile fired first.
            local nearestPile = nil
            local nearestDist = 12
            for _, pile in ipairs(ammoPiles) do
                local d = (hrp.Position - pile.glow.Position).Magnitude
                if d <= nearestDist then
                    nearestPile = pile
                    nearestDist = d
                end
            end
            if not nearestPile then break end
            player:SetAttribute("CarryingAmmo", count + 1)
            task.wait(RAPID_INTERVAL)
        end
        rapidActionInProgress[userId] = nil
        holdActive[userId] = nil
    end)
end)

pickupStopRemote.OnServerEvent:Connect(function(player)
    holdActive[player.UserId] = false
end)

-- Wire up load prompt on each tower. Each tap of E loads exactly ONE pack
-- (+10 shots). Single-tap behavior — NOT a hold/repeat loop. The pickup
-- side at the piles still uses the rapid-loop pattern (see above).
local function wireTowerLoadPrompt(towerBase)
    local tower = towerBase.Parent
    if not tower then return end
    local prompt = towerBase:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then return end
    prompt.Triggered:Connect(function(player)
        local count = player:GetAttribute("CarryingAmmo") or 0
        if count <= 0 then return end
        if not tower or not tower.Parent then return end
        local shots = tower:GetAttribute("Shots") or 0
        local maxShots = tower:GetAttribute("MaxShots") or 50
        if shots >= maxShots then return end
        local newShots = math.min(maxShots, shots + 10)
        tower:SetAttribute("Shots", newShots)
        player:SetAttribute("CarryingAmmo", count - 1)
    end)
end

for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
    wireTowerLoadPrompt(towerBase)
end
CollectionService:GetInstanceAddedSignal(Tags.Tower):Connect(wireTowerLoadPrompt)

-- Each tower's load prompt is enabled only when:
--   (a) a player carrying ≥1 pack is within 10 studs, AND
--   (b) the tower isn't already full.
-- Each pile's pickup prompt is enabled only when the nearby player isn't at carry cap.
local LOAD_RANGE = 20  -- studs (doubled from 10)

task.spawn(function()
    while true do
        task.wait(0.2)

        -- For each carrying player, find their CLOSEST non-full tower within range.
        -- Only that tower's prompt will be enabled (avoids multiple prompts overlapping).
        -- Ownership doesn't matter: any player can load any tower.
        local enabledTowers = {}  -- [towerBase] = true
        for _, p in ipairs(Players:GetPlayers()) do
            if (p:GetAttribute("CarryingAmmo") or 0) > 0 then
                local char = p.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local bestBase, bestDist = nil, nil
                    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                        local tower = towerBase.Parent
                        if tower then
                            local shots = tower:GetAttribute("Shots") or 0
                            local maxShots = tower:GetAttribute("MaxShots") or 50
                            if shots < maxShots then
                                local d = (hrp.Position - towerBase.Position).Magnitude
                                if d <= LOAD_RANGE and (not bestDist or d < bestDist) then
                                    bestBase = towerBase
                                    bestDist = d
                                end
                            end
                        end
                    end
                    if bestBase then enabledTowers[bestBase] = true end
                end
            end
        end

        -- Apply enabled/disabled state to every tower's prompt
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local prompt = towerBase:FindFirstChildOfClass("ProximityPrompt")
            if prompt then
                prompt.Enabled = enabledTowers[towerBase] == true
            end
        end

        -- Pile pickup prompts: disabled only when a nearby player is already at cap
        for _, pile in ipairs(ammoPiles) do
            local anyAtCapNearby = false
            for _, p in ipairs(Players:GetPlayers()) do
                if (p:GetAttribute("CarryingAmmo") or 0) >= getMaxCarry(p) then
                    local char = p.Character
                    local hrp = char and char:FindFirstChild("HumanoidRootPart")
                    if hrp and (hrp.Position - pile.glow.Position).Magnitude <= 12 then
                        anyAtCapNearby = true
                        break
                    end
                end
            end
            pile.prompt.Enabled = not anyAtCapNearby
        end
    end
end)

-- Target mode change: client → server. Validates the caller owns the tower
-- and the mode is one of the allowed values.
local VALID_TARGET_MODES = {First = true, Strongest = true, Center = true, Last = true}
setTargetModeRemote.OnServerEvent:Connect(function(player, towerModel, mode)
    if typeof(towerModel) ~= "Instance" or not towerModel:IsA("Model") then return end
    if not towerModel.Parent then return end
    if not VALID_TARGET_MODES[mode] then return end
    if towerModel:GetAttribute("Owner") ~= player.UserId then return end
    towerModel:SetAttribute("TargetMode", mode)
    print(("[TreeOfLife] %s set %s TargetMode=%s"):format(
        player.Name, towerModel.Name, mode))
end)



-- BossDefeated → roll a random attachment for each player and try to award.
-- Rarity rolls via Attachments.RARITY_DROP_WEIGHTS; type is uniform across
-- known types. Result is one of: "new" (player didn't own this type),
-- "upgraded" (had lower rarity), or "duplicate" (had same/higher — discarded).
bossDefeatedBindable.Event:Connect(function()
    for _, player in ipairs(Players:GetPlayers()) do
        local rolled = Attachments.rollAttachment()
        local awardResult = AttachmentStore.tryAward(player, rolled.type, rolled.rarity)
        AttachmentStore.save(player)
        print(("[TreeOfLife] %s rolled %s → %s"):format(
            player.Name, Attachments.describe(rolled), awardResult.result))
        local revealRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.AttachmentRevealed)
        if revealRemote then
            revealRemote:FireClient(player, {
                rolled    = rolled,
                result    = awardResult.result,
                entry     = awardResult.entry,
                oldRarity = awardResult.oldRarity,
            })
        end
    end
end)

------------------------------------------------------------
-- Attachment management endpoints (v2 schema)
-- GetAttachments: returns {owned = list of {type, rarity, isEquipped}, equipped = type|nil}
-- EquipAttachment: client picks which type to equip (or empty to unequip)
-- AttachmentsChanged: server pushes refreshed payload after any change
-- AttachmentRevealed: server pushes after Final Boss kill
------------------------------------------------------------
local getAttachmentsFunc = ReplicatedStorage:FindFirstChild(Remotes.Names.GetAttachments)
if not getAttachmentsFunc then
    getAttachmentsFunc = Instance.new("RemoteFunction")
    getAttachmentsFunc.Name = Remotes.Names.GetAttachments
    getAttachmentsFunc.Parent = ReplicatedStorage
end
local equipAttachmentRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.EquipAttachment)
if not equipAttachmentRemote then
    equipAttachmentRemote = Instance.new("RemoteEvent")
    equipAttachmentRemote.Name = Remotes.Names.EquipAttachment
    equipAttachmentRemote.Parent = ReplicatedStorage
end
local attachmentsChangedRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.AttachmentsChanged)
if not attachmentsChangedRemote then
    attachmentsChangedRemote = Instance.new("RemoteEvent")
    attachmentsChangedRemote.Name = Remotes.Names.AttachmentsChanged
    attachmentsChangedRemote.Parent = ReplicatedStorage
end
local attachmentRevealRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.AttachmentRevealed)
if not attachmentRevealRemote then
    attachmentRevealRemote = Instance.new("RemoteEvent")
    attachmentRevealRemote.Name = Remotes.Names.AttachmentRevealed
    attachmentRevealRemote.Parent = ReplicatedStorage
end

local function buildAttachmentPayload(player)
    local owned = AttachmentStore.getOwned(player)
    local equipped = AttachmentStore.load(player).equipped
    local list = {}
    for _, attType in ipairs(Attachments.TYPE_NAMES) do
        local entry = owned[attType]
        if entry then
            table.insert(list, {
                type = entry.type,
                rarity = entry.rarity,
                isEquipped = (equipped == entry.type),
            })
        end
    end
    return {owned = list, equipped = equipped}
end

getAttachmentsFunc.OnServerInvoke = function(player)
    return buildAttachmentPayload(player)
end

equipAttachmentRemote.OnServerEvent:Connect(function(player, attType)
    if attType == "" then attType = nil end
    if attType ~= nil and type(attType) ~= "string" then return end
    AttachmentStore.setEquipped(player, attType)
    AttachmentStore.save(player)
    -- Mirror what's ACTUALLY equipped (re-read from the store rather than
    -- trusting `attType` directly). setEquipped silently rejects requests
    -- to equip un-owned attachments — if we mirrored the request value
    -- naively, the client HUD would think Phoenix was equipped and show
    -- "Phoenix: READY", but no tower would have Phoenix attributes, so
    -- mobs reaching the heart would do damage with no Phoenix interception.
    local actuallyEquipped = AttachmentStore.getEquipped(player)
    player:SetAttribute("EquippedAttachmentType",
        actuallyEquipped and actuallyEquipped.type or "")
    attachmentsChangedRemote:FireClient(player, buildAttachmentPayload(player))
end)

-- Push an attachments-changed payload after each award too (in addition to
-- AttachmentRevealed) so the picker stays in sync if open.
bossDefeatedBindable.Event:Connect(function()
    task.wait(0.1)
    for _, player in ipairs(Players:GetPlayers()) do
        attachmentsChangedRemote:FireClient(player, buildAttachmentPayload(player))
    end
end)

print("[TreeOfLife] v5.10.13 server ready. Grid: " .. GRID_COLS .. "x" .. GRID_ROWS)
