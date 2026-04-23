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

------------------------------------------------------------
-- GRID & PATH
------------------------------------------------------------
local gridState = {}
-- Shared grid: map 1 occupies cols [0, GRID_COLS-1] × rows [0, GRID_ROWS-1].
-- Map 2 occupies cols [MAP2_COL_OFFSET, MAP2_TOTAL_COLS-1] × rows [0, MAP2_ROWS-1].
-- Same gridState table covers both. cellToWorld dispatches by col range.
-- The placement remote validates by checking gridState[c][r] == "open" so
-- it works unchanged across both maps.
local MAX_GRID_ROWS = math.max(GRID_ROWS, MAP2_ROWS)
for c = 0, MAP2_TOTAL_COLS - 1 do
    gridState[c] = {}
    for r = 0, MAX_GRID_ROWS - 1 do
        gridState[c][r] = "open"
    end
end

local function cellToWorld(col, row)
    -- v3 multi-map: cells in MAP2_COL_OFFSET range belong to map 2's
    -- physical location (500 studs above map 1's center).
    if col >= MAP2_COL_OFFSET then
        local localCol = col - MAP2_COL_OFFSET
        return Vector3.new(
            MAP2_CENTER.X - MAP2_WIDTH/2 + (localCol + 0.5) * CELL_SIZE,
            MAP2_CENTER.Y,
            MAP2_CENTER.Z - MAP2_DEPTH/2 + (row + 0.5) * CELL_SIZE
        )
    end
    return Vector3.new(
        rc.X - halfW + (col + 0.5) * CELL_SIZE,
        0,
        rc.Z - halfD + (row + 0.5) * CELL_SIZE
    )
end

local pathWaypointCells = {
    {57,  8},
    {42,  8},
    {42, 34},
    {30, 34},
    {30,  8},
    {18,  8},
    {18, 28},
    { 4, 28},
}

-- KEY FIX: Mark path cells by sweeping a PATH_WIDTH_CELLS-wide brush along each
-- segment. For segment a→b, determine the axis of travel; stretch the brush
-- perpendicular to the direction. Also pad end-points by half-width so corners
-- are fully covered (matches the visual path tiles).
local pathHalf = math.floor(PATH_WIDTH_CELLS / 2)

local function markPathRect(c1, r1, c2, r2)
    local cmin = math.min(c1, c2)
    local cmax = math.max(c1, c2)
    local rmin = math.min(r1, r2)
    local rmax = math.max(r1, r2)
    for c = cmin, cmax do
        for r = rmin, rmax do
            if c >= 0 and c < GRID_COLS and r >= 0 and r < GRID_ROWS then
                gridState[c][r] = "path"
            end
        end
    end
end

for i = 1, #pathWaypointCells - 1 do
    local a = pathWaypointCells[i]
    local b = pathWaypointCells[i + 1]
    local ac, ar = a[1], a[2]
    local bc, br = b[1], b[2]
    -- Horizontal segment
    if ar == br then
        local c1 = math.min(ac, bc) - pathHalf + 1
        local c2 = math.max(ac, bc) + pathHalf
        local r1 = ar - pathHalf + 1
        local r2 = ar + pathHalf
        markPathRect(c1, r1, c2, r2)
    else
        -- Vertical segment
        local c1 = ac - pathHalf + 1
        local c2 = ac + pathHalf
        local r1 = math.min(ar, br) - pathHalf + 1
        local r2 = math.max(ar, br) + pathHalf
        markPathRect(c1, r1, c2, r2)
    end
end

-- Heart exclusion zone
local heartCell = pathWaypointCells[#pathWaypointCells]
for oc = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
    for or_ = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
        local cc, rr = heartCell[1] + oc, heartCell[2] + or_
        if cc >= 0 and cc < GRID_COLS and rr >= 0 and rr < GRID_ROWS then
            if gridState[cc][rr] == "open" then
                gridState[cc][rr] = "heart"
            end
        end
    end
end

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
-- MAP 2 — CLIMBING THE TREE (programmer art for now)
--
-- Lives 500 studs above map 1 (MAP2_CENTER.Y = 500). Uses the SHARED
-- gridState but at columns MAP2_COL_OFFSET..MAP2_TOTAL_COLS-1, with its
-- own world-space origin (cellToWorld already dispatches by col range).
-- Heart HP is 5000 per the design doc (10× map 1's 500 because the path
-- is longer + mobs scale up).
--
-- Visual palette: warmer wood + mossy green accents to read as "inside
-- the living tree." Polished art and the actual double-helix staircase
-- come in a future session.
------------------------------------------------------------
-- Falling-leaf message used on map entry. Looks up the LeafMessage remote
-- (created on demand by the wave system; we tolerate it not existing yet
-- on first launch). Defined here (before the map-2 do-block) so the map-2
-- portal handler's closure can capture it — a closure captures variables
-- by NAME at the time the closure body is parsed, and the portal's
-- task.delay(..., function() fireLeafMessage(...) end) reads the outer
-- scope. If fireLeafMessage were defined after the do-block, the closure
-- would see nil and error at runtime.
local leafMessageRemote_outer = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)
local function fireLeafMessage(player, text, duration)
    if not leafMessageRemote_outer then
        leafMessageRemote_outer = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)
    end
    if leafMessageRemote_outer then
        leafMessageRemote_outer:FireClient(player, {text = text, duration = duration or 6})
    end
end

------------------------------------------------------------
-- Wrapped in a do-block so its ~35 locals (map2Room, m2c, STAIR_CENTER,
-- map1ToMap2Portal, etc.) are scoped to this block and don't count
-- toward the script's top-level register budget. Luau caps the main
-- chunk at 200 locals; map 2 alone would put us at 201.

-- FORWARD-DECLARE: module-scope local that gets assigned INSIDE the
-- do-block. Readable by the DevTeleport handler below the block.
local MAP2_PLAYER_SPAWN_CF  -- CFrame, nil until map 2 block runs

-- Map 2 ammo pile world positions. Declared here so:
--   1. Bush placement inside the do-block can exclude these spots
--   2. buildAmmoPile calls outside the do-block can read them
-- Placed in the TRUE NE and SE corners of the room (local cols 70+, rows
-- <= 6 and >= 50) — outside the outer-lap path brush so mobs walk PAST
-- the piles but not ONTO them. Bushes cluster around but don't cover.
-- Map 2 ammo pile world positions. Declared here so:
--   1. Bush placement inside the do-block can exclude these spots
--   2. buildAmmoPile calls outside the do-block can read them
-- Placed in SW and SE corners (bottom). Heart is at SE (68, 46) — the SE
-- ammo sits 3 cols east + 4 rows south so it's tucked in the true corner
-- and doesn't overlap the path end at the heart.
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
-- Legacy alias removed: the old NE ammo pile is gone; we use SW + SE now.
-- Bush-placement and buildAmmoPile calls below reference SW + SE directly.

-- FORWARD-DECLARE: hook the portal + dev teleport call after firing SwitchMap
-- so map-2-specific visuals (lighting, stage-1 staircase height, etc.) get
-- applied. Implementation lives below the do-block (needs applyMap2StageVisuals).
local applyMap2Stage1OnEntry = function() end  -- stub; overwritten below

-- FORWARD-DECLARE: Map2Stage namespace gathers stage-progression state
-- (bush lobes, firefly list, staircase parts) so the StageAdvanced
-- handler below the do-block can drive them. Assigned inside the block.
local Map2Stage = {
    bushLobes    = {},  -- array of {part=Part, baseSize=num, unlockStage=int}
    fireflies    = {},  -- array of firefly entries (shared with Heartbeat anim loop)
    stairParts   = {},  -- array of {part=Part, unlockStage=int} (steps + stringers)
    baseStairTotalHeight = 0,  -- set inside the block; used to compute unlockStage per step
}

do
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

-- Enable the portal when the map 1 final boss dies. We piggyback on the
-- existing BossDefeated bindable (which the wave system fires on Pickle
-- Lord — for now, the only "final boss" in the game). Future maps will
-- need to either fire a different bindable or carry a mapId payload.
local map1PortalActive = false
bossDefeatedBindable.Event:Connect(function()
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
-- having to defeat the map 1 final boss every time. REMOVE this block
-- once map progression is locked in (or gate it behind a dev flag).
task.delay(2, function()
    if not map1PortalActive then
        map1PortalActive = true
        map1ToMap2Portal.Transparency = 0.2
        map1ToMap2Prompt.Enabled = true
        map1ToMap2Light.Brightness = 4
        print("[ToL] DEV: portal auto-enabled at startup")
    end
end)

-- Lazy-bind the SwitchMap bindable (created by wave system on its boot)
local switchMapBindable = nil

map1ToMap2Prompt.Triggered:Connect(function(player)
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
    -- Apply stage-1 visuals for map 2 (lighting, staircase height, bush lobes)
    applyMap2Stage1OnEntry()
    -- Falling-leaf intro for map 2 (slight delay so the teleport lands first)
    task.delay(0.4, function() fireLeafMessage(player, MAP2_LEAF, 7) end)
    print(("[ToL] %s entered map 2 via portal"):format(player.Name))
end)
end  -- close map 2 + staircase + portal do-block

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
applyMap2Stage1OnEntry = function()
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
        applyMap2Stage1OnEntry()
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
