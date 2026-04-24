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

local TITLE       = "Tree of Life"
local SUBTITLE    = "Save the world from food gone bad"
local FADE_IN     = 0.9
local HOLD        = 2.1
local FADE_OUT    = 1.1

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

local function showSplash()
    local old = playerGui:FindFirstChild("ToL_Splash")
    if old then old:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_Splash"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 100
    gui.Parent = playerGui
    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    bg.BackgroundTransparency = 1
    bg.BorderSizePixel = 0
    bg.Active = false  -- don't intercept input; player can move/look during splash
    bg.Parent = gui
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 120)
    title.Position = UDim2.new(0, 0, 0.38, 0)
    title.BackgroundTransparency = 1
    title.Text = TITLE
    title.TextColor3 = Color3.fromRGB(230, 255, 230)
    title.Font = Enum.Font.FredokaOne
    title.TextSize = 84
    title.TextTransparency = 1
    title.TextStrokeColor3 = Color3.fromRGB(20, 80, 30)
    title.TextStrokeTransparency = 1
    title.Parent = bg
    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 255, 180)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 255, 150)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 220, 110)),
    })
    gradient.Rotation = 90
    gradient.Parent = title
    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(1, 0, 0, 40)
    subtitle.Position = UDim2.new(0, 0, 0.58, 0)
    subtitle.BackgroundTransparency = 1
    subtitle.Text = SUBTITLE
    subtitle.TextColor3 = Color3.fromRGB(220, 235, 220)
    subtitle.Font = Enum.Font.Gotham
    subtitle.TextSize = 22
    subtitle.TextTransparency = 1
    subtitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    subtitle.TextStrokeTransparency = 0.5
    subtitle.Parent = bg
    local easeIn = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(bg, easeIn, {BackgroundTransparency = 0.25}):Play()
    TweenService:Create(title, easeIn, {TextTransparency = 0, TextStrokeTransparency = 0}):Play()
    TweenService:Create(subtitle, easeIn, {TextTransparency = 0.1}):Play()
    task.wait(FADE_IN + HOLD)
    local easeOut = TweenInfo.new(FADE_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    TweenService:Create(bg, easeOut, {BackgroundTransparency = 1}):Play()
    TweenService:Create(title, easeOut, {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
    TweenService:Create(subtitle, easeOut, {TextTransparency = 1}):Play()
    task.wait(FADE_OUT + 0.2)
    gui:Destroy()
end
ReplicatedStorage:WaitForChild(Remotes.Names.ShowSplash).OnClientEvent:Connect(showSplash)

local function round(frame, radiusScale)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(radiusScale or 0.12, 0)
    c.Parent = frame
end

local function buildPowerIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    for i = 0, 3 do
        local spike = Instance.new("Frame")
        spike.Size = UDim2.new(0.18, 0, 0.65, 0)
        spike.Position = UDim2.new(0.5, 0, 0.5, 0)
        spike.AnchorPoint = Vector2.new(0.5, 0.5)
        spike.Rotation = i * 45
        spike.BackgroundColor3 = Color3.fromRGB(255, 80, 70)
        spike.BorderSizePixel = 0
        spike.Parent = holder
        round(spike, 0.15)
    end
    local core = Instance.new("Frame")
    core.Size = UDim2.new(0.32, 0, 0.32, 0)
    core.Position = UDim2.new(0.5, 0, 0.5, 0)
    core.AnchorPoint = Vector2.new(0.5, 0.5)
    core.BackgroundColor3 = Color3.fromRGB(255, 220, 180)
    core.BorderSizePixel = 0
    core.Parent = holder
    round(core, 0.5)
    local hl = Instance.new("Frame")
    hl.Size = UDim2.new(0.14, 0, 0.14, 0)
    hl.Position = UDim2.new(0.42, 0, 0.42, 0)
    hl.AnchorPoint = Vector2.new(0.5, 0.5)
    hl.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    hl.BorderSizePixel = 0
    hl.Parent = holder
    round(hl, 0.5)
end

local function buildDoTIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local big = Instance.new("Frame")
    big.Size = UDim2.new(0.55, 0, 0.55, 0)
    big.Position = UDim2.new(0.5, 0, 0.62, 0)
    big.AnchorPoint = Vector2.new(0.5, 0.5)
    big.BackgroundColor3 = Color3.fromRGB(80, 200, 100)
    big.BorderSizePixel = 0
    big.Parent = holder
    round(big, 0.5)
    local tip = Instance.new("Frame")
    tip.Size = UDim2.new(0.28, 0, 0.28, 0)
    tip.Position = UDim2.new(0.5, 0, 0.28, 0)
    tip.AnchorPoint = Vector2.new(0.5, 0.5)
    tip.Rotation = 45
    tip.BackgroundColor3 = Color3.fromRGB(80, 200, 100)
    tip.BorderSizePixel = 0
    tip.Parent = holder
    round(tip, 0.15)
    local small = Instance.new("Frame")
    small.Size = UDim2.new(0.22, 0, 0.22, 0)
    small.Position = UDim2.new(0.78, 0, 0.24, 0)
    small.AnchorPoint = Vector2.new(0.5, 0.5)
    small.BackgroundColor3 = Color3.fromRGB(120, 230, 140)
    small.BorderSizePixel = 0
    small.Parent = holder
    round(small, 0.5)
end

local function buildCCIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local outer = Instance.new("Frame")
    outer.Size = UDim2.new(0.75, 0, 0.75, 0)
    outer.Position = UDim2.new(0.5, 0, 0.5, 0)
    outer.AnchorPoint = Vector2.new(0.5, 0.5)
    outer.BackgroundColor3 = Color3.fromRGB(60, 130, 230)
    outer.BorderSizePixel = 0
    outer.Parent = holder
    round(outer, 0.5)
    local mid = Instance.new("Frame")
    mid.Size = UDim2.new(0.5, 0, 0.5, 0)
    mid.Position = UDim2.new(0.5, 0, 0.5, 0)
    mid.AnchorPoint = Vector2.new(0.5, 0.5)
    mid.BackgroundColor3 = Color3.fromRGB(30, 40, 80)
    mid.BorderSizePixel = 0
    mid.Parent = holder
    round(mid, 0.5)
    local inner = Instance.new("Frame")
    inner.Size = UDim2.new(0.3, 0, 0.3, 0)
    inner.Position = UDim2.new(0.5, 0, 0.5, 0)
    inner.AnchorPoint = Vector2.new(0.5, 0.5)
    inner.BackgroundColor3 = Color3.fromRGB(100, 180, 255)
    inner.BorderSizePixel = 0
    inner.Parent = holder
    round(inner, 0.5)
    local center = Instance.new("Frame")
    center.Size = UDim2.new(0.1, 0, 0.1, 0)
    center.Position = UDim2.new(0.5, 0, 0.5, 0)
    center.AnchorPoint = Vector2.new(0.5, 0.5)
    center.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    center.BorderSizePixel = 0
    center.Parent = holder
    round(center, 0.5)
end

-- Frost Melon icon: round pale-teal melon with green stripes, frost spark.
local function buildFrostMelonIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local melon = Instance.new("Frame")
    melon.Size = UDim2.new(0.78, 0, 0.78, 0)
    melon.Position = UDim2.new(0.5, 0, 0.55, 0)
    melon.AnchorPoint = Vector2.new(0.5, 0.5)
    melon.BackgroundColor3 = Color3.fromRGB(150, 210, 220)
    melon.BorderSizePixel = 0
    melon.Parent = holder
    round(melon, 0.5)
    -- Stripes
    for i = -1, 1 do
        local s = Instance.new("Frame")
        s.Size = UDim2.new(0.06, 0, 0.72, 0)
        s.Position = UDim2.new(0.5 + i * 0.18, 0, 0.55, 0)
        s.AnchorPoint = Vector2.new(0.5, 0.5)
        s.BackgroundColor3 = Color3.fromRGB(60, 130, 95)
        s.BorderSizePixel = 0
        s.Parent = melon
        round(s, 0.5)
    end
    -- Frost spark
    local spark = Instance.new("Frame")
    spark.Size = UDim2.new(0.22, 0, 0.22, 0)
    spark.Position = UDim2.new(0.7, 0, 0.25, 0)
    spark.AnchorPoint = Vector2.new(0.5, 0.5)
    spark.Rotation = 45
    spark.BackgroundColor3 = Color3.fromRGB(230, 245, 255)
    spark.BorderSizePixel = 0
    spark.Parent = holder
    round(spark, 0.15)
end

-- Root Sprout icon: low mound with a central green sprout and root tendrils.
local function buildRootSproutIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local mound = Instance.new("Frame")
    mound.Size = UDim2.new(0.82, 0, 0.4, 0)
    mound.Position = UDim2.new(0.5, 0, 0.78, 0)
    mound.AnchorPoint = Vector2.new(0.5, 0.5)
    mound.BackgroundColor3 = Color3.fromRGB(105, 70, 45)
    mound.BorderSizePixel = 0
    mound.Parent = holder
    round(mound, 0.4)
    -- Tendrils — three small slanted rectangles fanning out
    for i = -1, 1 do
        local t = Instance.new("Frame")
        t.Size = UDim2.new(0.12, 0, 0.38, 0)
        t.Position = UDim2.new(0.5 + i * 0.24, 0, 0.55, 0)
        t.AnchorPoint = Vector2.new(0.5, 0.5)
        t.Rotation = i * 25
        t.BackgroundColor3 = Color3.fromRGB(95, 65, 45)
        t.BorderSizePixel = 0
        t.Parent = holder
        round(t, 0.3)
    end
    -- Central sprout leaf
    local leaf = Instance.new("Frame")
    leaf.Size = UDim2.new(0.22, 0, 0.35, 0)
    leaf.Position = UDim2.new(0.5, 0, 0.32, 0)
    leaf.AnchorPoint = Vector2.new(0.5, 0.5)
    leaf.BackgroundColor3 = Color3.fromRGB(70, 150, 65)
    leaf.BorderSizePixel = 0
    leaf.Parent = holder
    round(leaf, 0.4)
    -- Glow seed at top
    local seed = Instance.new("Frame")
    seed.Size = UDim2.new(0.18, 0, 0.18, 0)
    seed.Position = UDim2.new(0.5, 0, 0.22, 0)
    seed.AnchorPoint = Vector2.new(0.5, 0.5)
    seed.BackgroundColor3 = Color3.fromRGB(200, 245, 130)
    seed.BorderSizePixel = 0
    seed.Parent = holder
    round(seed, 0.5)
end

-- Thorn Vine icon: green stalk with red thorn spikes along its length.
local function buildThornVineIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local stalk = Instance.new("Frame")
    stalk.Size = UDim2.new(0.12, 0, 0.85, 0)
    stalk.Position = UDim2.new(0.5, 0, 0.5, 0)
    stalk.AnchorPoint = Vector2.new(0.5, 0.5)
    stalk.BackgroundColor3 = Color3.fromRGB(55, 100, 50)
    stalk.BorderSizePixel = 0
    stalk.Parent = holder
    round(stalk, 0.4)
    -- Thorns alternating left/right
    for i, spec in ipairs({ {y=0.2, dir=-1}, {y=0.45, dir=1}, {y=0.7, dir=-1} }) do
        local thorn = Instance.new("Frame")
        thorn.Size = UDim2.new(0.22, 0, 0.14, 0)
        thorn.Position = UDim2.new(0.5 + spec.dir * 0.15, 0, spec.y, 0)
        thorn.AnchorPoint = Vector2.new(0.5, 0.5)
        thorn.Rotation = spec.dir * 30
        thorn.BackgroundColor3 = Color3.fromRGB(170, 55, 55)
        thorn.BorderSizePixel = 0
        thorn.Parent = holder
        round(thorn, 0.3)
    end
    local bud = Instance.new("Frame")
    bud.Size = UDim2.new(0.2, 0, 0.2, 0)
    bud.Position = UDim2.new(0.5, 0, 0.12, 0)
    bud.AnchorPoint = Vector2.new(0.5, 0.5)
    bud.BackgroundColor3 = Color3.fromRGB(180, 230, 130)
    bud.BorderSizePixel = 0
    bud.Parent = holder
    round(bud, 0.5)
end

-- Honey Hive icon: golden hive (3 stacked discs) with an entry hole.
local function buildHoneyHiveIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    for i, spec in ipairs({ {w=0.72, y=0.75}, {w=0.6, y=0.55}, {w=0.42, y=0.35} }) do
        local disc = Instance.new("Frame")
        disc.Size = UDim2.new(spec.w, 0, 0.2, 0)
        disc.Position = UDim2.new(0.5, 0, spec.y, 0)
        disc.AnchorPoint = Vector2.new(0.5, 0.5)
        disc.BackgroundColor3 = Color3.fromRGB(225, 175, 60)
        disc.BorderSizePixel = 0
        disc.Parent = holder
        round(disc, 0.4)
    end
    -- Entry hole
    local hole = Instance.new("Frame")
    hole.Size = UDim2.new(0.18, 0, 0.18, 0)
    hole.Position = UDim2.new(0.5, 0, 0.65, 0)
    hole.AnchorPoint = Vector2.new(0.5, 0.5)
    hole.BackgroundColor3 = Color3.fromRGB(50, 30, 10)
    hole.BorderSizePixel = 0
    hole.Parent = holder
    round(hole, 0.5)
    -- Drip
    local drip = Instance.new("Frame")
    drip.Size = UDim2.new(0.1, 0, 0.15, 0)
    drip.Position = UDim2.new(0.75, 0, 0.82, 0)
    drip.AnchorPoint = Vector2.new(0.5, 0.5)
    drip.BackgroundColor3 = Color3.fromRGB(255, 215, 100)
    drip.BorderSizePixel = 0
    drip.Parent = holder
    round(drip, 0.5)
end

-- Acorn Sniper icon: brown acorn with darker cap and a crosshair over it.
local function buildAcornSniperIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local body = Instance.new("Frame")
    body.Size = UDim2.new(0.5, 0, 0.55, 0)
    body.Position = UDim2.new(0.5, 0, 0.62, 0)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(190, 140, 75)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.4)
    local cap = Instance.new("Frame")
    cap.Size = UDim2.new(0.58, 0, 0.25, 0)
    cap.Position = UDim2.new(0.5, 0, 0.32, 0)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.BackgroundColor3 = Color3.fromRGB(100, 70, 35)
    cap.BorderSizePixel = 0
    cap.Parent = holder
    round(cap, 0.5)
    -- Crosshair (plus sign)
    local v = Instance.new("Frame")
    v.Size = UDim2.new(0.04, 0, 0.5, 0)
    v.Position = UDim2.new(0.5, 0, 0.62, 0)
    v.AnchorPoint = Vector2.new(0.5, 0.5)
    v.BackgroundColor3 = Color3.fromRGB(255, 230, 120)
    v.BorderSizePixel = 0
    v.Parent = holder
    local h = Instance.new("Frame")
    h.Size = UDim2.new(0.5, 0, 0.04, 0)
    h.Position = UDim2.new(0.5, 0, 0.62, 0)
    h.AnchorPoint = Vector2.new(0.5, 0.5)
    h.BackgroundColor3 = Color3.fromRGB(255, 230, 120)
    h.BorderSizePixel = 0
    h.Parent = holder
end

-- Lightning Radish icon: purple radish with a yellow lightning zigzag.
local function buildLightningRadishIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local body = Instance.new("Frame")
    body.Size = UDim2.new(0.72, 0, 0.62, 0)
    body.Position = UDim2.new(0.5, 0, 0.62, 0)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(195, 80, 165)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.5)
    -- Leaves
    for i = -1, 1 do
        local leaf = Instance.new("Frame")
        leaf.Size = UDim2.new(0.12, 0, 0.32, 0)
        leaf.Position = UDim2.new(0.5 + i * 0.14, 0, 0.22, 0)
        leaf.AnchorPoint = Vector2.new(0.5, 0.5)
        leaf.Rotation = i * 15
        leaf.BackgroundColor3 = Color3.fromRGB(80, 160, 70)
        leaf.BorderSizePixel = 0
        leaf.Parent = holder
        round(leaf, 0.4)
    end
    -- Lightning zigzag (3 angled rectangles)
    for i, spec in ipairs({ {x=0.42, y=0.55, rot=25}, {x=0.58, y=0.65, rot=-25}, {x=0.5, y=0.78, rot=25} }) do
        local zz = Instance.new("Frame")
        zz.Size = UDim2.new(0.08, 0, 0.18, 0)
        zz.Position = UDim2.new(spec.x, 0, spec.y, 0)
        zz.AnchorPoint = Vector2.new(0.5, 0.5)
        zz.Rotation = spec.rot
        zz.BackgroundColor3 = Color3.fromRGB(255, 240, 120)
        zz.BorderSizePixel = 0
        zz.Parent = holder
        round(zz, 0.2)
    end
end

-- Spore Puffball icon: green dome with scattered darker spots.
local function buildSporePuffballIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local dome = Instance.new("Frame")
    dome.Size = UDim2.new(0.78, 0, 0.55, 0)
    dome.Position = UDim2.new(0.5, 0, 0.5, 0)
    dome.AnchorPoint = Vector2.new(0.5, 0.5)
    dome.BackgroundColor3 = Color3.fromRGB(170, 200, 140)
    dome.BorderSizePixel = 0
    dome.Parent = holder
    round(dome, 0.5)
    -- Spots
    for _, spec in ipairs({ {x=0.4, y=0.42}, {x=0.58, y=0.54}, {x=0.48, y=0.62}, {x=0.63, y=0.4} }) do
        local spot = Instance.new("Frame")
        spot.Size = UDim2.new(0.1, 0, 0.1, 0)
        spot.Position = UDim2.new(spec.x, 0, spec.y, 0)
        spot.AnchorPoint = Vector2.new(0.5, 0.5)
        spot.BackgroundColor3 = Color3.fromRGB(90, 140, 80)
        spot.BorderSizePixel = 0
        spot.Parent = holder
        round(spot, 0.5)
    end
    -- Stalk
    local stalk = Instance.new("Frame")
    stalk.Size = UDim2.new(0.22, 0, 0.18, 0)
    stalk.Position = UDim2.new(0.5, 0, 0.82, 0)
    stalk.AnchorPoint = Vector2.new(0.5, 0.5)
    stalk.BackgroundColor3 = Color3.fromRGB(230, 220, 190)
    stalk.BorderSizePixel = 0
    stalk.Parent = holder
    round(stalk, 0.2)
end

-- Pepper Cannon icon: red pepper pointing right with a flame at its tip.
local function buildPepperCannonIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    -- Pepper body (elongated horizontal)
    local body = Instance.new("Frame")
    body.Size = UDim2.new(0.7, 0, 0.28, 0)
    body.Position = UDim2.new(0.45, 0, 0.55, 0)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(210, 55, 40)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.5)
    -- Stem (green nub)
    local stem = Instance.new("Frame")
    stem.Size = UDim2.new(0.12, 0, 0.14, 0)
    stem.Position = UDim2.new(0.12, 0, 0.55, 0)
    stem.AnchorPoint = Vector2.new(0.5, 0.5)
    stem.BackgroundColor3 = Color3.fromRGB(70, 140, 55)
    stem.BorderSizePixel = 0
    stem.Parent = holder
    round(stem, 0.3)
    -- Flame (orange blob at tip, plus small yellow inner)
    local flame = Instance.new("Frame")
    flame.Size = UDim2.new(0.28, 0, 0.35, 0)
    flame.Position = UDim2.new(0.85, 0, 0.55, 0)
    flame.AnchorPoint = Vector2.new(0.5, 0.5)
    flame.BackgroundColor3 = Color3.fromRGB(255, 140, 40)
    flame.BorderSizePixel = 0
    flame.Parent = holder
    round(flame, 0.5)
    local inner = Instance.new("Frame")
    inner.Size = UDim2.new(0.14, 0, 0.18, 0)
    inner.Position = UDim2.new(0.83, 0, 0.55, 0)
    inner.AnchorPoint = Vector2.new(0.5, 0.5)
    inner.BackgroundColor3 = Color3.fromRGB(255, 230, 100)
    inner.BorderSizePixel = 0
    inner.Parent = holder
    round(inner, 0.5)
end

-- Mushroom Mortar icon: big red cap with white spots and an arc trail overhead.
local function buildMushroomMortarIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    -- Cap (bigger dome)
    local cap = Instance.new("Frame")
    cap.Size = UDim2.new(0.82, 0, 0.46, 0)
    cap.Position = UDim2.new(0.5, 0, 0.58, 0)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.BackgroundColor3 = Color3.fromRGB(190, 45, 45)
    cap.BorderSizePixel = 0
    cap.Parent = holder
    round(cap, 0.5)
    -- Stem under cap
    local stem = Instance.new("Frame")
    stem.Size = UDim2.new(0.34, 0, 0.25, 0)
    stem.Position = UDim2.new(0.5, 0, 0.85, 0)
    stem.AnchorPoint = Vector2.new(0.5, 0.5)
    stem.BackgroundColor3 = Color3.fromRGB(240, 220, 190)
    stem.BorderSizePixel = 0
    stem.Parent = holder
    round(stem, 0.2)
    -- Cap spots
    for _, spec in ipairs({ {x=0.35, y=0.5}, {x=0.55, y=0.46}, {x=0.68, y=0.54} }) do
        local spot = Instance.new("Frame")
        spot.Size = UDim2.new(0.1, 0, 0.1, 0)
        spot.Position = UDim2.new(spec.x, 0, spec.y, 0)
        spot.AnchorPoint = Vector2.new(0.5, 0.5)
        spot.BackgroundColor3 = Color3.fromRGB(250, 245, 235)
        spot.BorderSizePixel = 0
        spot.Parent = holder
        round(spot, 0.5)
    end
    -- Arc above — three little balls tracing a lobbing trajectory
    for i, spec in ipairs({ {x=0.15, y=0.25}, {x=0.35, y=0.12}, {x=0.6, y=0.2} }) do
        local p = Instance.new("Frame")
        p.Size = UDim2.new(0.08, 0, 0.08, 0)
        p.Position = UDim2.new(spec.x, 0, spec.y, 0)
        p.AnchorPoint = Vector2.new(0.5, 0.5)
        p.BackgroundColor3 = Color3.fromRGB(255, 180, 80)
        p.BackgroundTransparency = 0.3 + (3 - i) * 0.15
        p.BorderSizePixel = 0
        p.Parent = holder
        round(p, 0.5)
    end
end

local towerDefs = {
    {id = "Power", name = "POWER", desc = "High single-target damage",
     color = Color3.fromRGB(200, 60, 50), accent = Color3.fromRGB(255, 90, 80),
     iconBuilder = buildPowerIcon, enabled = true, hotkey = "1",
     hotkeyCode = Enum.KeyCode.One, footprint = {4, 4}},
    {id = "DoT", name = "DoT", desc = "Damage over time",
     color = Color3.fromRGB(50, 140, 70), accent = Color3.fromRGB(80, 200, 100),
     iconBuilder = buildDoTIcon, enabled = false, hotkey = "2",
     hotkeyCode = Enum.KeyCode.Two, footprint = {1, 1}},
    {id = "CC", name = "CC", desc = "Crowd control & slows",
     color = Color3.fromRGB(45, 90, 180), accent = Color3.fromRGB(80, 150, 230),
     iconBuilder = buildCCIcon, enabled = false, hotkey = "3",
     hotkeyCode = Enum.KeyCode.Three, footprint = {3, 3}},
    -- Temp towers (stock granted from map-boss pickers). `tempReward = true`
    -- keeps them out of the run-start starter-tower picker — the hotbar
    -- builder filters by stock > 0 so unearned slots stay invisible there.
    -- Footprints MUST match TempTowers.Templates on the server or the ghost
    -- outline and the placement check will disagree.
    {id = "FrostMelon", name = "MELON", desc = "Chills enemies in an AOE",
     color = Color3.fromRGB(100, 180, 190), accent = Color3.fromRGB(170, 220, 230),
     iconBuilder = buildFrostMelonIcon, enabled = true, tempReward = true, hotkey = "4",
     hotkeyCode = Enum.KeyCode.Four, footprint = {4, 4}},
    {id = "RootSprout", name = "ROOT", desc = "Periodic short-range stun",
     color = Color3.fromRGB(90, 65, 45), accent = Color3.fromRGB(150, 200, 90),
     iconBuilder = buildRootSproutIcon, enabled = true, tempReward = true, hotkey = "5",
     hotkeyCode = Enum.KeyCode.Five, footprint = {4, 4}},
    {id = "ThornVine", name = "THORN", desc = "Shots pierce through enemies",
     color = Color3.fromRGB(55, 95, 50), accent = Color3.fromRGB(150, 200, 120),
     iconBuilder = buildThornVineIcon, enabled = true, tempReward = true, hotkey = "6",
     hotkeyCode = Enum.KeyCode.Six, footprint = {4, 4}},
    {id = "HoneyHive", name = "HIVE", desc = "Sticky patches slow + tick damage",
     color = Color3.fromRGB(180, 130, 35), accent = Color3.fromRGB(255, 210, 90),
     iconBuilder = buildHoneyHiveIcon, enabled = true, tempReward = true, hotkey = "7",
     hotkeyCode = Enum.KeyCode.Seven, footprint = {4, 6}},
    {id = "AcornSniper", name = "SNIPER", desc = "Long range, heavy single hit",
     color = Color3.fromRGB(120, 80, 45), accent = Color3.fromRGB(255, 220, 120),
     iconBuilder = buildAcornSniperIcon, enabled = true, tempReward = true, hotkey = "8",
     hotkeyCode = Enum.KeyCode.Eight, footprint = {4, 4}},
    {id = "LightningRadish", name = "RADISH", desc = "Chains to nearby enemies",
     color = Color3.fromRGB(150, 60, 130), accent = Color3.fromRGB(230, 180, 255),
     iconBuilder = buildLightningRadishIcon, enabled = true, tempReward = true, hotkey = "9",
     hotkeyCode = Enum.KeyCode.Nine, footprint = {6, 6}},
    {id = "SporePuffball", name = "SPORES", desc = "Poison cloud on impact",
     color = Color3.fromRGB(105, 140, 80), accent = Color3.fromRGB(160, 240, 140),
     iconBuilder = buildSporePuffballIcon, enabled = true, tempReward = true, hotkey = "0",
     hotkeyCode = Enum.KeyCode.Zero, footprint = {6, 6}},
    {id = "PepperCannon", name = "PEPPER", desc = "Heavy splash bomb",
     color = Color3.fromRGB(170, 45, 35), accent = Color3.fromRGB(255, 150, 50),
     iconBuilder = buildPepperCannonIcon, enabled = true, tempReward = true, hotkey = "-",
     hotkeyCode = Enum.KeyCode.Minus, footprint = {8, 8}},
    {id = "MushroomMortar", name = "MORTAR", desc = "Long-range lob with massive blast",
     color = Color3.fromRGB(160, 40, 40), accent = Color3.fromRGB(255, 160, 80),
     iconBuilder = buildMushroomMortarIcon, enabled = true, tempReward = true, hotkey = "=",
     hotkeyCode = Enum.KeyCode.Equals, footprint = {12, 12}},
}

local lastShowTowerSelectAt = 0
local function showTowerSelect()
    -- Guard against duplicate UI builds (e.g. portal touch + failsafe loop both firing
    -- in quick succession). Ignore calls within 2s of the previous one.
    local now = os.clock()
    if now - lastShowTowerSelectAt < 2 then return end
    lastShowTowerSelectAt = now

    local old = playerGui:FindFirstChild("ToL_TowerSelect")
    if old then old:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_TowerSelect"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 200
    gui.Parent = playerGui
    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(10, 15, 20)
    bg.BackgroundTransparency = 0.3
    bg.BorderSizePixel = 0
    bg.Parent = gui
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, IS_MOBILE and 40 or 60)
    title.Position = UDim2.new(0, 0, 0, IS_MOBILE and 8 or 16)
    title.BackgroundTransparency = 1
    title.Text = "Choose Your Starting Tower"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.5
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 28 or 48
    title.Parent = bg
    -- Compact card layout so the whole UI fits below the top-anchored title.
    local CARD_W      = IS_MOBILE and 180 or 240
    local CARD_H      = IS_MOBILE and 210 or 280
    local CARD_HOVER_W = IS_MOBILE and 188 or 250
    local CARD_HOVER_H = IS_MOBILE and 220 or 290
    local ICON_SIZE   = IS_MOBILE and 80 or 120
    local ICON_TOP    = IS_MOBILE and 12 or 16
    local NAME_SIZE   = IS_MOBILE and 24 or 32
    local NAME_TOP    = IS_MOBILE and 96 or 140
    local DESC_SIZE   = IS_MOBILE and 12 or 14
    local DESC_TOP    = IS_MOBILE and 128 or 180
    local CTA_SIZE    = IS_MOBILE and 16 or 20
    local CTA_HEIGHT  = IS_MOBILE and 32 or 38
    local ROW_HEIGHT  = IS_MOBILE and 220 or 300
    local ROW_PADDING = IS_MOBILE and 12 or 24

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
    -- Position the row just below the title, not centered on screen
    row.Position = UDim2.new(0, 0, 0, IS_MOBILE and 60 or 90)
    row.BackgroundTransparency = 1
    row.Parent = bg
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, ROW_PADDING)
    rowLayout.Parent = row
    local cards = {}
    -- 1-second delay before cards become clickable, to prevent accidental taps
    -- (e.g., finger already on screen when the UI appears).
    -- Short anti-accidental-tap window — if the player tapped the floor
    -- or some other UI just before the modal opened, that tap could
    -- otherwise fall through and auto-select a tower. 0.3s is enough
    -- to catch that without the "swallowed click" feeling a longer
    -- window gave.
    local clickableAt = os.clock() + 0.3
    for _, def in ipairs(towerDefs) do
        -- Temp towers (FrostMelon etc.) are earned from map-boss drops,
        -- not picked at run start. Skip them in the starter picker.
        if def.tempReward then continue end
        local card = Instance.new("TextButton")
        card.Size = UDim2.new(0, CARD_W, 0, CARD_H)
        card.BackgroundColor3 = def.color
        card.BorderSizePixel = 0
        card.AutoButtonColor = false
        card.Text = ""
        card.Parent = row
        round(card, 0.08)
        card:SetAttribute("Enabled", def.enabled)
        if not def.enabled then card.BackgroundTransparency = 0.5 end
        local iconBg = Instance.new("Frame")
        iconBg.Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE)
        iconBg.Position = UDim2.new(0.5, -ICON_SIZE/2, 0, ICON_TOP)
        iconBg.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconBg.BorderSizePixel = 0
        iconBg.Parent = card
        round(iconBg, 0.1)
        def.iconBuilder(iconBg)
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -20, 0, 40)
        nameLabel.Position = UDim2.new(0, 10, 0, NAME_TOP)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = def.name
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.TextStrokeTransparency = 0
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = NAME_SIZE
        nameLabel.Parent = card
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -16, 0, 36)
        descLabel.Position = UDim2.new(0, 8, 0, DESC_TOP)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = def.desc
        descLabel.TextColor3 = Color3.fromRGB(235, 235, 245)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = 0.4
        descLabel.Font = Enum.Font.Gotham
        descLabel.TextSize = DESC_SIZE
        descLabel.TextWrapped = true
        descLabel.Parent = card
        local cta = Instance.new("Frame")
        cta.Size = UDim2.new(1, -16, 0, CTA_HEIGHT)
        cta.Position = UDim2.new(0, 8, 1, -CTA_HEIGHT - 8)
        cta.BackgroundColor3 = def.enabled and def.accent or Color3.fromRGB(80, 80, 85)
        cta.BorderSizePixel = 0
        cta.Parent = card
        round(cta, 0.15)
        local ctaLabel = Instance.new("TextLabel")
        ctaLabel.Size = UDim2.fromScale(1, 1)
        ctaLabel.BackgroundTransparency = 1
        ctaLabel.Text = def.enabled and "SELECT" or "LOCKED"
        ctaLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        ctaLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        ctaLabel.TextStrokeTransparency = 0.3
        ctaLabel.Font = Enum.Font.FredokaOne
        ctaLabel.TextSize = CTA_SIZE
        ctaLabel.Parent = cta
        if def.enabled then
            local capturedId = def.id
            card.MouseEnter:Connect(function()
                TweenService:Create(card, TweenInfo.new(0.15),
                    {Size = UDim2.new(0, CARD_HOVER_W, 0, CARD_HOVER_H)}):Play()
            end)
            card.MouseLeave:Connect(function()
                TweenService:Create(card, TweenInfo.new(0.15),
                    {Size = UDim2.new(0, CARD_W, 0, CARD_H)}):Play()
            end)
            card.MouseButton1Click:Connect(function()
                if os.clock() < clickableAt then return end  -- 1s input lockout
                for _, c in ipairs(cards) do c.Active = false end
                ReplicatedStorage:WaitForChild(Remotes.Names.TowerPicked):FireServer(capturedId)
                TweenService:Create(bg, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play()
                for _, c in ipairs(cards) do
                    for _, d in ipairs(c:GetDescendants()) do
                        if d:IsA("Frame") or d:IsA("TextButton") then
                            TweenService:Create(d, TweenInfo.new(0.5),
                                {BackgroundTransparency = 1}):Play()
                        end
                        if d:IsA("TextLabel") then
                            TweenService:Create(d, TweenInfo.new(0.5),
                                {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
                        end
                    end
                    TweenService:Create(c, TweenInfo.new(0.5),
                        {BackgroundTransparency = 1}):Play()
                end
                TweenService:Create(title, TweenInfo.new(0.5),
                    {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
                task.wait(0.6)
                gui:Destroy()
            end)
        end
        table.insert(cards, card)
    end
    bg.BackgroundTransparency = 1
    title.TextTransparency = 1
    title.TextStrokeTransparency = 1
    for _, c in ipairs(cards) do
        c.BackgroundTransparency = 1
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("Frame") then d.BackgroundTransparency = 1 end
            if d:IsA("TextLabel") then
                d.TextTransparency = 1
                d.TextStrokeTransparency = 1
            end
        end
    end
    TweenService:Create(bg, TweenInfo.new(0.5), {BackgroundTransparency = 0.3}):Play()
    TweenService:Create(title, TweenInfo.new(0.5),
        {TextTransparency = 0, TextStrokeTransparency = 0.5}):Play()
    for i, card in ipairs(cards) do
        local enabled = card:GetAttribute("Enabled")
        local targetCardBg = enabled and 0 or 0.5
        task.delay(0.1 * i, function()
            TweenService:Create(card, TweenInfo.new(0.4),
                {BackgroundTransparency = targetCardBg}):Play()
            for _, d in ipairs(card:GetDescendants()) do
                if d:IsA("Frame") then
                    TweenService:Create(d, TweenInfo.new(0.4),
                        {BackgroundTransparency = 0}):Play()
                elseif d:IsA("TextLabel") then
                    TweenService:Create(d, TweenInfo.new(0.4),
                        {TextTransparency = 0, TextStrokeTransparency = 0}):Play()
                end
            end
        end)
    end
end
ReplicatedStorage:WaitForChild(Remotes.Names.ShowTowerSelect).OnClientEvent:Connect(showTowerSelect)

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

if true then
    -- Dev panel: small gear icon in the bottom-left. Tapping toggles a
    -- vertical panel with action buttons. Same UI on mobile + desktop.
    local ICON_SIZE = 40
    local PANEL_WIDTH = 170
    local BTN_HEIGHT = 36
    local BTN_GAP = 6

    -- Gear icon button (always visible)
    local iconBtn = Instance.new("TextButton")
    iconBtn.Name = "DevIcon"
    iconBtn.Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE)
    iconBtn.Position = UDim2.new(0, 12, 1, -(ICON_SIZE + 12))
    iconBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
    iconBtn.BackgroundTransparency = 0.25
    iconBtn.BorderSizePixel = 0
    iconBtn.Text = "⚙"
    iconBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
    iconBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    iconBtn.TextStrokeTransparency = 0.4
    iconBtn.Font = Enum.Font.FredokaOne
    iconBtn.TextSize = 24
    iconBtn.AutoButtonColor = false
    iconBtn.Parent = devGui
    local iconCorner = Instance.new("UICorner")
    iconCorner.CornerRadius = UDim.new(0.5, 0)
    iconCorner.Parent = iconBtn

    -- Hotkey hint: small yellow "[ALT]" badge sitting ON the gear icon
    -- (parented to iconBtn so its position follows if the icon ever moves,
    -- and so it inherits layering). Hidden on mobile (no physical kb).
    if not IS_MOBILE then
        local hotkeyHint = Instance.new("TextLabel")
        hotkeyHint.AnchorPoint = Vector2.new(0.5, 0.5)
        hotkeyHint.Position = UDim2.new(0.5, 0, 0.5, 0)  -- dead-center on icon
        hotkeyHint.Size = UDim2.new(0, 34, 0, 16)  -- wider to fit "ALT" vs single letter
        hotkeyHint.BackgroundTransparency = 1
        hotkeyHint.Text = "[ALT]"
        hotkeyHint.TextColor3 = Color3.fromRGB(255, 221, 85)
        hotkeyHint.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        hotkeyHint.TextStrokeTransparency = 0.2
        hotkeyHint.Font = Enum.Font.FredokaOne
        hotkeyHint.TextSize = 13
        hotkeyHint.ZIndex = 3  -- floats above the gear glyph at ZIndex 1
        hotkeyHint.Parent = iconBtn
    end

    -- Panel container holding the action buttons (hidden until expanded).
    -- AutomaticSize.Y so the panel grows to fit however many children it
    -- gets — this matters because we add/remove rows over time and we
    -- don't want to keep recomputing the hard-coded height. AnchorPoint.Y
    -- = 1 anchors the panel by its BOTTOM edge so it grows UPWARD from
    -- just above the gear icon, never overlapping it.
    local panel = Instance.new("Frame")
    panel.Name = "DevPanel"
    panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.Size = UDim2.new(0, PANEL_WIDTH, 0, 0)
    panel.AnchorPoint = Vector2.new(0, 1)
    panel.Position = UDim2.new(0, 12, 1, -(ICON_SIZE + 12 + 8))
    panel.BackgroundColor3 = Color3.fromRGB(25, 28, 38)
    panel.BackgroundTransparency = 0.15
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.Parent = devGui
    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0.08, 0)
    panelCorner.Parent = panel

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Padding = UDim.new(0, BTN_GAP)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = panel
    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, BTN_GAP)
    pad.PaddingBottom = UDim.new(0, BTN_GAP)
    pad.Parent = panel

    ------------------------------------------------------------
    -- ACCORDION CATEGORIES
    --
    -- The panel is organized into collapsible categories. Each category has
    -- a header button (tap to toggle) and a contents frame below that holds
    -- action buttons. Starts with one category expanded (Progress) so the
    -- most-used actions are always one tap away.
    --
    -- Categories: Progress, Dev Tools, Teleport, Inventory. RUN LUCK is
    -- rendered separately as an always-visible readout at the bottom.
    ------------------------------------------------------------

    -- makeCategoryHeader: row that, when tapped, toggles the contents frame
    -- returned alongside it. Contents frame uses UIListLayout so child
    -- buttons stack naturally. Both share AutomaticSize.Y so the whole
    -- accordion expands correctly as categories open/close.
    local nextCategoryOrder = 0
    -- Track every category's collapse fn so opening one can auto-collapse
    -- the others. Accordion behavior — only one dev category visible at a
    -- time keeps the left-side panel short on mobile screens.
    local allCategoryCollapsers = {}
    local function makeCategory(title, startExpanded)
        nextCategoryOrder = nextCategoryOrder + 1
        local catFrame = Instance.new("Frame")
        catFrame.Size = UDim2.new(1, -8, 0, 0)
        catFrame.AutomaticSize = Enum.AutomaticSize.Y
        catFrame.BackgroundTransparency = 1
        catFrame.LayoutOrder = nextCategoryOrder
        catFrame.Parent = panel

        local catLayout = Instance.new("UIListLayout")
        catLayout.FillDirection = Enum.FillDirection.Vertical
        catLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        catLayout.Padding = UDim.new(0, 3)
        catLayout.SortOrder = Enum.SortOrder.LayoutOrder
        catLayout.Parent = catFrame

        -- Header button: "▶ TITLE" when collapsed, "▼ TITLE" when open.
        -- RichText is on so callers can highlight a hotkey letter inside
        -- the title (e.g. "<font color='#ffdd55'>T</font>ELEPORT").
        local header = Instance.new("TextButton")
        header.Size = UDim2.new(1, 0, 0, 30)
        header.LayoutOrder = 1
        header.BackgroundColor3 = Color3.fromRGB(45, 50, 68)
        header.BackgroundTransparency = 0.1
        header.BorderSizePixel = 0
        header.RichText = true
        header.Text = "▶ " .. title
        header.TextColor3 = Color3.fromRGB(220, 220, 230)
        header.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        header.TextStrokeTransparency = 0.5
        header.Font = Enum.Font.FredokaOne
        header.TextSize = 14
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.AutoButtonColor = false
        header.Parent = catFrame
        local headerPad = Instance.new("UIPadding")
        headerPad.PaddingLeft = UDim.new(0, 8)
        headerPad.Parent = header
        local headerC = Instance.new("UICorner")
        headerC.CornerRadius = UDim.new(0.2, 0)
        headerC.Parent = header

        -- Contents frame: AutomaticSize.Y so it grows with children. Hidden
        -- by default unless startExpanded is true.
        local contents = Instance.new("Frame")
        contents.Size = UDim2.new(1, 0, 0, 0)
        contents.AutomaticSize = Enum.AutomaticSize.Y
        contents.BackgroundTransparency = 1
        contents.LayoutOrder = 2
        contents.Visible = startExpanded == true
        contents.Parent = catFrame
        local contentsLayout = Instance.new("UIListLayout")
        contentsLayout.FillDirection = Enum.FillDirection.Vertical
        contentsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        contentsLayout.Padding = UDim.new(0, 3)
        contentsLayout.SortOrder = Enum.SortOrder.LayoutOrder
        contentsLayout.Parent = contents
        local contentsPad = Instance.new("UIPadding")
        contentsPad.PaddingTop = UDim.new(0, 2)
        contentsPad.PaddingBottom = UDim.new(0, 2)
        contentsPad.Parent = contents

        -- Header toggles contents visibility
        local expandedState = startExpanded == true
        header.Text = (expandedState and "▼ " or "▶ ") .. title
        local collapseMe  -- forward decl so allCategoryCollapsers can hold it
        local function setExpanded(v)
            -- Accordion: opening a category auto-collapses every other.
            -- Called BEFORE we flip our own state so our own collapser
            -- doesn't loop back on us.
            if v then
                for _, c in ipairs(allCategoryCollapsers) do
                    if c ~= collapseMe then c() end
                end
            end
            expandedState = v and true or false
            contents.Visible = expandedState
            header.Text = (expandedState and "▼ " or "▶ ") .. title
        end
        collapseMe = function()
            if expandedState then
                expandedState = false
                contents.Visible = false
                header.Text = "▶ " .. title
            end
        end
        table.insert(allCategoryCollapsers, collapseMe)
        header.MouseButton1Click:Connect(function()
            setExpanded(not expandedState)
        end)

        -- Backwards-compatible: call sites that only capture the first
        -- return still get `contents` exactly as before. New call sites
        -- can also grab `setExpanded` for programmatic toggling (used by
        -- the T/C dev hotkeys).
        return contents, setExpanded
    end

    -- makeBtn: adds a button into a given parent frame (a category contents).
    -- Button height + style matches the previous flat layout, just scoped
    -- to its category parent instead of the top-level panel.
    local function makeBtn(parent, order, label, color)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -8, 0, BTN_HEIGHT)
        b.LayoutOrder = order
        b.BackgroundColor3 = color
        b.BackgroundTransparency = 0.05
        b.BorderSizePixel = 0
        b.RichText = true  -- allows per-letter color spans for hotkey hints
        b.Text = label
        b.TextColor3 = Color3.fromRGB(255, 255, 255)
        b.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        b.TextStrokeTransparency = 0.4
        b.Font = Enum.Font.FredokaOne
        b.TextSize = 16
        b.AutoButtonColor = false
        b.Parent = parent
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0.2, 0)
        bc.Parent = b
        return b
    end

    -- Hotkey accent color (yellow, matches FredokaOne bright accents
    -- elsewhere). Used in RichText labels to highlight the key that
    -- maps to each action.
    local HOTKEY_HEX = "#ffdd55"

    -- PROGRESS category (most-used; starts expanded). P toggles its
    -- visibility; the accordion auto-collapses the other categories.
    local progressCat, setProgressExpanded = makeCategory(
        string.format("<font color='%s'>P</font>ROGRESS", HOTKEY_HEX), true)
    local skipBtn_label    = string.format("S<font color='%s'>K</font>IP WAVE", HOTKEY_HEX)
    local bossBtn_label    = string.format("B<font color='%s'>O</font>SS", HOTKEY_HEX)
    local mapBossBtn_label = string.format("<font color='%s'>M</font>AP BOSS", HOTKEY_HEX)
    local resetBtn       = makeBtn(progressCat, 1, "RESET",            Color3.fromRGB(180,  60,  60))
    local skipBtn        = makeBtn(progressCat, 2, skipBtn_label,      Color3.fromRGB( 60, 120, 180))
    local bossBtn        = makeBtn(progressCat, 3, bossBtn_label,      Color3.fromRGB(140,  40, 160))
    local mapBossBtn     = makeBtn(progressCat, 4, mapBossBtn_label,   Color3.fromRGB(200,  80, 220))
    local canopyBtn      = makeBtn(progressCat, 5, "WEB WEAVER",    Color3.fromRGB( 60,  60,  90))
    local birdBtn        = makeBtn(progressCat, 6, "CANOPY BIRD",   Color3.fromRGB(170,  80,  60))
    local pickleLordBtn  = makeBtn(progressCat, 7, "PICKLE LORD",   Color3.fromRGB( 80, 200, 100))

    -- DEV TOOLS category (cheats/modifiers). V opens this category.
    -- O used to toggle DEV TOOLS but now fires BOSS; picked V as the
    -- middle letter of DEV so the hotkey-highlight still lands inside
    -- the label without colliding with other bindings.
    local toolsCat, setToolsExpanded = makeCategory(
        string.format("DE<font color='%s'>V</font> TOOLS", HOTKEY_HEX), false)
    local ammoBtn    = makeBtn(toolsCat, 1, "UNLIMITED AMMO: ON", Color3.fromRGB( 60, 160,  90))
    local stunBtn    = makeBtn(toolsCat, 2, "ADD STUN",           Color3.fromRGB(220, 200,  60))
    local resetCdBtn = makeBtn(toolsCat, 3, "RESET COOLDOWNS",    Color3.fromRGB( 80, 180, 180))
    local statsBtn   = makeBtn(toolsCat, 4, "STATS",              Color3.fromRGB(100, 120, 200))
    local groundZeroBtn = makeBtn(toolsCat, 5, "GROUND ZERO",     Color3.fromRGB(130,  30,  30))

    -- TELEPORT category — T opens it; C then fires MAP 1 (CROOK).
    local teleportCat, setTeleportExpanded = makeCategory(
        string.format("<font color='%s'>T</font>ELEPORT", HOTKEY_HEX), false)
    local tpHubBtn_label  = "HUB"
    local tpMap1Btn_label = string.format("MAP 1 (<font color='%s'>C</font>ROOK)", HOTKEY_HEX)
    local tpMap2Btn_label = string.format("MAP 2 (CLIM<font color='%s'>B</font>ING)", HOTKEY_HEX)
    local tpHubBtn   = makeBtn(teleportCat, 1, tpHubBtn_label,  Color3.fromRGB( 90, 140,  80))
    local tpMap1Btn  = makeBtn(teleportCat, 2, tpMap1Btn_label, Color3.fromRGB(140, 110,  70))
    local tpMap2Btn  = makeBtn(teleportCat, 3, tpMap2Btn_label, Color3.fromRGB(110, 140, 160))

    -- INVENTORY category
    local inventoryCat = makeCategory("INVENTORY", false)
    local attachBtn = makeBtn(inventoryCat, 1, "ATTACHMENTS", Color3.fromRGB(150,  80, 200))


    -- RUN LUCK display: embedded readout (not a button). Shows a normalized
    -- 1-10 score where 5 = the expected average run given the rarity drop
    -- distribution. Updates live whenever the server bumps the player's
    -- RunLuckSum/RunLuckCount attributes (every upgrade picker offered).
    --
    -- Layout: small frame with title + number on top, color-coded bar below.
    -- Uses the same panel UIListLayout via LayoutOrder=5 (after attachBtn).
    local LUCK_ROW_HEIGHT = 56
    local luckRow = Instance.new("Frame")
    luckRow.Size = UDim2.new(1, -8, 0, LUCK_ROW_HEIGHT)
    luckRow.LayoutOrder = 100  -- always last (after all accordion categories)
    luckRow.BackgroundColor3 = Color3.fromRGB(45, 40, 25)
    luckRow.BackgroundTransparency = 0.15
    luckRow.BorderSizePixel = 0
    luckRow.Parent = panel
    local luckRowC = Instance.new("UICorner")
    luckRowC.CornerRadius = UDim.new(0.2, 0)
    luckRowC.Parent = luckRow

    local luckLabel = Instance.new("TextLabel")
    luckLabel.Size = UDim2.new(1, -12, 0, 22)
    luckLabel.Position = UDim2.new(0, 6, 0, 4)
    luckLabel.BackgroundTransparency = 1
    luckLabel.Text = "RUN LUCK: —"
    luckLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
    luckLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    luckLabel.TextStrokeTransparency = 0.4
    luckLabel.Font = Enum.Font.FredokaOne
    luckLabel.TextSize = 14
    luckLabel.TextXAlignment = Enum.TextXAlignment.Center
    luckLabel.Parent = luckRow

    -- Bar background (rounded)
    local luckBarBg = Instance.new("Frame")
    luckBarBg.Size = UDim2.new(1, -16, 0, 14)
    luckBarBg.Position = UDim2.new(0, 8, 0, 30)
    luckBarBg.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
    luckBarBg.BorderSizePixel = 0
    luckBarBg.Parent = luckRow
    local luckBarBgC = Instance.new("UICorner")
    luckBarBgC.CornerRadius = UDim.new(0.5, 0)
    luckBarBgC.Parent = luckBarBg

    -- Bar fill (color and width updated in refresh function below)
    local luckFill = Instance.new("Frame")
    luckFill.Size = UDim2.new(0, 0, 1, 0)
    luckFill.BackgroundColor3 = Color3.fromRGB(180, 180, 190)
    luckFill.BorderSizePixel = 0
    luckFill.Parent = luckBarBg
    local luckFillC = Instance.new("UICorner")
    luckFillC.CornerRadius = UDim.new(0.5, 0)
    luckFillC.Parent = luckFill

    -- Tick mark at the "5" position (visual reference for "average run")
    local luckTick = Instance.new("Frame")
    luckTick.Size = UDim2.new(0, 2, 1, 4)
    luckTick.Position = UDim2.new(0.5, -1, 0, -2)
    luckTick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    luckTick.BackgroundTransparency = 0.4
    luckTick.BorderSizePixel = 0
    luckTick.Parent = luckBarBg

    -- Two-piece linear mapping from raw avg rarity score (1..5) to display
    -- (1..10). Anchor: avg=2.71 → display=5. The 2.71 baseline is the
    -- expected score if a player greedily picks the BEST of 3 offered cards
    -- on every picker, given the rarity distribution (Common=1, Rare=2,
    -- Exceptional/Special=3, Legendary=4, Mythical=5; drop weights 50/25/10+8/5/2).
    -- A player who always picks the rarest card and gets average dice should
    -- land near display=5. Below that → unlucky / picked Commons; above → got
    -- lucky on the picker rolls. (When tracking switched from offered → picked,
    -- the baseline rose from 1.84 to 2.71.)
    local AVG_LUCK_SCORE = 2.71
    local function avgRarityToDisplay(avg)
        if avg <= AVG_LUCK_SCORE then
            return 1 + (avg - 1) / (AVG_LUCK_SCORE - 1) * 4
        else
            return 5 + (avg - AVG_LUCK_SCORE) / (5 - AVG_LUCK_SCORE) * 5
        end
    end

    local function refreshLuck()
        local sum   = player:GetAttribute("RunLuckSum")   or 0
        local count = player:GetAttribute("RunLuckCount") or 0
        if count <= 0 then
            luckLabel.Text = "RUN LUCK: —"
            luckFill.Size = UDim2.new(0, 0, 1, 0)
            return
        end
        local avg = sum / count
        local display = avgRarityToDisplay(avg)
        display = math.clamp(display, 1, 10)
        luckLabel.Text = string.format("RUN LUCK: %.1f / 10", display)
        luckFill.Size = UDim2.new(display / 10, 0, 1, 0)
        -- Color shifts: gray (under-luck) → blue → purple → gold → pink (top)
        local c
        if display < 3      then c = Color3.fromRGB(170, 170, 180)
        elseif display < 5  then c = Color3.fromRGB(120, 170, 240)
        elseif display < 7  then c = Color3.fromRGB(190, 110, 220)
        elseif display < 9  then c = Color3.fromRGB(255, 180, 60)
        else                     c = Color3.fromRGB(255, 90, 160) end
        luckFill.BackgroundColor3 = c
    end

    refreshLuck()
    player:GetAttributeChangedSignal("RunLuckSum"):Connect(refreshLuck)
    player:GetAttributeChangedSignal("RunLuckCount"):Connect(refreshLuck)

    local expanded = false
    local function setExpanded(v)
        expanded = v
        panel.Visible = v
        iconBtn.Text = v and "×" or "⚙"
    end

    iconBtn.MouseButton1Click:Connect(function()
        setExpanded(not expanded)
    end)

    -- Alt-hotkey: toggles the dev panel. Either LeftAlt or RightAlt fires.
    -- Moved off Z (was conflicting with other game keys / Roblox defaults).
    -- T/C bindings that depend on fireTeleport live in a second handler
    -- BELOW the fireTeleport local-function declaration — Lua captures
    -- free variables at function-definition time, so referencing
    -- fireTeleport here would bind to a (nil) global.
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
            setExpanded(not expanded)
        end
    end)

    -- Per user preference: dev panel stays open on any button click —
    -- only closes when the player explicitly taps the collapse icon. So
    -- none of the handlers below call setExpanded(false) anymore.
    resetBtn.MouseButton1Click:Connect(function()
        fireReset(resetBtn)
    end)

    local function fireSkipWave()
        local skipRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSkipWave)
        if skipRemote then
            skipRemote:FireServer()
            skipBtn.Text = "SKIPPING..."
            task.delay(0.4, function()
                if skipBtn.Parent then skipBtn.Text = skipBtn_label end
            end)
        end
    end
    skipBtn.MouseButton1Click:Connect(fireSkipWave)

    -- fireSkipToBoss + fireSkipToMapBoss hoisted here (alongside fireSkipWave)
    -- so the B/M/K hotkey handler below can close over them. The *Btn
    -- MouseButton1Click wirings in the PROGRESS section just reuse them.
    local function fireSkipToBoss()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSkipToBoss)
        if r then r:FireServer() end
    end
    local function fireSkipToMapBoss()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSkipToMapBoss)
        if r then r:FireServer() end
    end

    local ammoOn = true
    ammoBtn.MouseButton1Click:Connect(function()
        ammoOn = not ammoOn
        local ammoRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevUnlimitedAmmo)
        if ammoRemote then ammoRemote:FireServer(ammoOn) end
        ammoBtn.Text = "UNLIMITED AMMO: " .. (ammoOn and "ON" or "OFF")
        ammoBtn.BackgroundColor3 = ammoOn
            and Color3.fromRGB(60, 160, 90)
            or  Color3.fromRGB(80, 80, 110)
    end)

    -- Teleport: HUB / MAP 1 / MAP 2.
    local function fireTeleport(target, btn, origLabel)
        local remote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevTeleport)
        if not remote then
            btn.Text = "NO REMOTE"
            task.delay(0.8, function() if btn.Parent then btn.Text = origLabel end end)
            return
        end
        remote:FireServer(target)
        btn.Text = "TELEPORTING..."
        task.delay(0.6, function()
            if btn.Parent then btn.Text = origLabel end
        end)
    end
    tpHubBtn.MouseButton1Click:Connect(function()
        fireTeleport("hub", tpHubBtn, tpHubBtn_label)
    end)
    tpMap1Btn.MouseButton1Click:Connect(function()
        fireTeleport("map1", tpMap1Btn, tpMap1Btn_label)
    end)
    tpMap2Btn.MouseButton1Click:Connect(function()
        fireTeleport("map2", tpMap2Btn, tpMap2Btn_label)
    end)

    -- Category + action hotkeys (desktop). Panel-open gate applies
    -- (ALT opens/closes the dev panel itself — see the handler up top).
    --   P → toggle PROGRESS category
    --   V → toggle DEV TOOLS category
    --   T → toggle TELEPORT category
    --   O → fire BOSS (skip to current stage's boss)
    --   B → fire MAP 2 (CLIMBING) teleport
    --   M → fire MAP BOSS (skip to current map's final boss)
    --   K → fire SKIP WAVE
    --   C → fire MAP 1 (CROOK) teleport — only when TELEPORT is open
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if not expanded then return end
        local kc = input.KeyCode
        if kc == Enum.KeyCode.P then
            setProgressExpanded(not progressCat.Visible)
        elseif kc == Enum.KeyCode.V then
            setToolsExpanded(not toolsCat.Visible)
        elseif kc == Enum.KeyCode.T then
            setTeleportExpanded(not teleportCat.Visible)
        elseif kc == Enum.KeyCode.O then
            fireSkipToBoss()
        elseif kc == Enum.KeyCode.B then
            fireTeleport("map2", tpMap2Btn, tpMap2Btn_label)
        elseif kc == Enum.KeyCode.M then
            fireSkipToMapBoss()
        elseif kc == Enum.KeyCode.K then
            fireSkipWave()
        elseif kc == Enum.KeyCode.C and teleportCat.Visible then
            fireTeleport("map1", tpMap1Btn, tpMap1Btn_label)
        end
    end)

    -- ATTACHMENT INVENTORY MODAL (v2 schema: one of each type, single equipped slot)
    -- Each owned attachment shown as a card with rarity-colored border and
    -- an EQUIP button. Only one can be equipped at a time. Empty types are
    -- shown as locked silhouettes so the player knows what's possible.
    local RARITY_NAMES  = {"Common", "Rare", "Exceptional", "Legendary", "Mythical"}
    local RARITY_COLORS = {
        Color3.fromRGB(200, 200, 200),
        Color3.fromRGB(80, 150, 255),
        Color3.fromRGB(180, 80, 220),
        Color3.fromRGB(255, 170, 40),
        Color3.fromRGB(255, 60, 140),
    }
    -- Mirror of server-side type defs for display only
    local TYPE_DEFS = {
        PowerCore = {
            displayName = "Power Core",
            blurb = "+%d base damage",
            effectByRarity = {5, 6, 7, 8, 9},
        },
        Detonator = {
            displayName = "Detonator",
            blurb = "Mobs explode on death (%d%% of mob HP, r=%d)",
            effectByRarity = {
                {hpPct = 0.02, radius = 8},
                {hpPct = 0.04, radius = 8},
                {hpPct = 0.06, radius = 8},
                {hpPct = 0.08, radius = 8},
                {hpPct = 0.10, radius = 8},
            },
        },
        Phoenix = {
            displayName = "Phoenix Charm",
            blurb = "Saves the heart from a fatal blow. Recharges every %d min of wave time.",
            effectByRarity = {20 * 60, 18 * 60, 16 * 60, 14 * 60, 12 * 60},
        },
    }
    local TYPE_ORDER = {"PowerCore", "Detonator", "Phoenix"}

    local function describeEffect(attType, rarity)
        local def = TYPE_DEFS[attType]
        if not def then return "" end
        local eff = def.effectByRarity[rarity]
        if attType == "PowerCore" then
            return string.format(def.blurb, eff)
        elseif attType == "Detonator" then
            return string.format(def.blurb,
                math.floor(eff.hpPct * 100 + 0.5), eff.radius)
        elseif attType == "Phoenix" then
            return string.format(def.blurb, math.floor(eff / 60 + 0.5))
        end
        return ""
    end

    local attachGui = nil
    local attachListFrame = nil

    -- Dev modal coordination: only one dev panel visible at a time.
    -- Each openX sets activeDevModalCloser to its own close fn; before
    -- opening, any prior closer runs. Prevents the Stats + Attachments
    -- modals stacking on top of each other and blocking clicks.
    local activeDevModalCloser = nil
    local function closeActiveDevModal()
        local closer = activeDevModalCloser
        activeDevModalCloser = nil
        if closer then
            pcall(closer)
        end
    end

    local function renderInventory(payload)
        if not attachListFrame or not attachListFrame.Parent then return end
        for _, child in ipairs(attachListFrame:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end

        -- Build a quick lookup: type → entry
        local owned = {}
        for _, e in ipairs(payload.owned or {}) do owned[e.type] = e end
        local equippedType = payload.equipped

        for orderIdx, attType in ipairs(TYPE_ORDER) do
            local entry = owned[attType]
            local def = TYPE_DEFS[attType]
            local row = Instance.new("Frame")
            -- Row height bumped from 80 to 100 to give the wrap-enabled
            -- blurb room for two lines (Phoenix's description is the
            -- long pole at ~"Saves the heart from a fatal blow. Recharges
            -- every 18 min of wave time.").
            row.Size = UDim2.new(1, -16, 0, 100)
            row.LayoutOrder = orderIdx
            row.BackgroundColor3 = entry
                and Color3.fromRGB(40, 45, 60)
                or  Color3.fromRGB(28, 30, 40)
            row.BackgroundTransparency = 0.1
            row.BorderSizePixel = 0
            row.Parent = attachListFrame
            local rc = Instance.new("UICorner")
            rc.CornerRadius = UDim.new(0.12, 0)
            rc.Parent = row
            -- Rarity-colored border (gray if unowned)
            local stroke = Instance.new("UIStroke")
            stroke.Thickness = 2
            stroke.Color = entry
                and RARITY_COLORS[entry.rarity]
                or  Color3.fromRGB(60, 60, 70)
            stroke.Parent = row

            -- Title row: "Common Power Core" or "??? (locked)"
            local title = Instance.new("TextLabel")
            title.Size = UDim2.new(1, -16, 0, 22)
            title.Position = UDim2.new(0, 10, 0, 6)
            title.BackgroundTransparency = 1
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.Font = Enum.Font.FredokaOne
            title.TextSize = 16
            if entry then
                title.Text = string.format("%s %s", RARITY_NAMES[entry.rarity], def.displayName)
                title.TextColor3 = RARITY_COLORS[entry.rarity]
            else
                title.Text = string.format("??? %s (locked)", def.displayName)
                title.TextColor3 = Color3.fromRGB(120, 120, 130)
            end
            title.Parent = row

            -- Effect blurb. Wrap enabled + extra height so Phoenix's
            -- two-sentence description fits on two lines without truncation.
            local blurb = Instance.new("TextLabel")
            blurb.Size = UDim2.new(1, -120, 0, 50)
            blurb.Position = UDim2.new(0, 10, 0, 30)
            blurb.BackgroundTransparency = 1
            blurb.TextXAlignment = Enum.TextXAlignment.Left
            blurb.TextYAlignment = Enum.TextYAlignment.Top
            blurb.TextWrapped = true
            blurb.Font = Enum.Font.Gotham
            blurb.TextSize = 13
            blurb.TextColor3 = entry
                and Color3.fromRGB(220, 220, 230)
                or  Color3.fromRGB(110, 110, 120)
            blurb.Text = entry
                and describeEffect(attType, entry.rarity)
                or  "Beat the Pickle Lord to roll a chance at this"
            blurb.Parent = row

            -- Equip / Equipped button on the right (only if owned)
            if entry then
                local isEquipped = (equippedType == attType)
                local equipBtn = Instance.new("TextButton")
                equipBtn.Size = UDim2.new(0, 100, 0, 36)
                -- Vertically centered in the 100px-tall row
                equipBtn.Position = UDim2.new(1, -110, 0, 32)
                equipBtn.BackgroundColor3 = isEquipped
                    and Color3.fromRGB(80, 200, 120)
                    or  Color3.fromRGB(70, 80, 110)
                equipBtn.BorderSizePixel = 0
                equipBtn.AutoButtonColor = false
                equipBtn.Text = isEquipped and "EQUIPPED" or "EQUIP"
                equipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
                equipBtn.Font = Enum.Font.FredokaOne
                equipBtn.TextSize = 14
                equipBtn.Parent = row
                local ec = Instance.new("UICorner")
                ec.CornerRadius = UDim.new(0.25, 0)
                ec.Parent = equipBtn

                equipBtn.MouseButton1Click:Connect(function()
                    local equipRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.EquipAttachment)
                    if equipRemote then
                        -- Tapping EQUIPPED unequips; tapping EQUIP equips this type
                        equipRemote:FireServer(isEquipped and "" or attType)
                    end
                end)
            end
        end
    end

    -- Listen for server-pushed inventory updates (after equip changes / new awards)
    ReplicatedStorage:WaitForChild(Remotes.Names.AttachmentsChanged).OnClientEvent:Connect(function(payload)
        if attachGui and attachGui.Parent then renderInventory(payload) end
    end)

    local function openAttachments()
        closeActiveDevModal()  -- close any other dev panel first
        if attachGui then attachGui:Destroy() end
        attachGui = Instance.new("ScreenGui")
        attachGui.Name = "ToL_Attachments"
        attachGui.IgnoreGuiInset = true
        attachGui.ResetOnSpawn = false
        attachGui.DisplayOrder = 250
        attachGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.4
        dim.BorderSizePixel = 0
        dim.Parent = attachGui

        local modal = Instance.new("Frame")
        modal.Size = UDim2.new(0, 420, 0, 460)
        modal.Position = UDim2.new(0.5, -210, 0.5, -230)
        modal.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        modal.BorderSizePixel = 0
        modal.Parent = attachGui
        local mc = Instance.new("UICorner")
        mc.CornerRadius = UDim.new(0.05, 0)
        mc.Parent = modal

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0, 44)
        title.BackgroundTransparency = 1
        title.Text = "ATTACHMENTS"
        title.TextColor3 = Color3.fromRGB(220, 200, 255)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 22
        title.Parent = modal

        local hint = Instance.new("TextLabel")
        hint.Size = UDim2.new(1, -20, 0, 28)
        hint.Position = UDim2.new(0, 10, 0, 44)
        hint.BackgroundTransparency = 1
        hint.Text = "Equip ONE attachment for your starter tower"
        hint.TextColor3 = Color3.fromRGB(170, 180, 200)
        hint.TextWrapped = true
        hint.Font = Enum.Font.Gotham
        hint.TextSize = 12
        hint.Parent = modal

        attachListFrame = Instance.new("ScrollingFrame")
        attachListFrame.Size = UDim2.new(1, -20, 1, -130)
        attachListFrame.Position = UDim2.new(0, 10, 0, 78)
        attachListFrame.BackgroundTransparency = 1
        attachListFrame.BorderSizePixel = 0
        attachListFrame.ScrollBarThickness = 6
        attachListFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
        attachListFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
        attachListFrame.Parent = modal
        local listLayout = Instance.new("UIListLayout")
        listLayout.FillDirection = Enum.FillDirection.Vertical
        listLayout.Padding = UDim.new(0, 8)
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        listLayout.Parent = attachListFrame
        local listPad = Instance.new("UIPadding")
        listPad.PaddingTop = UDim.new(0, 6)
        listPad.Parent = attachListFrame

        local closeBtn = Instance.new("TextButton")
        closeBtn.Size = UDim2.new(1, -20, 0, 38)
        closeBtn.Position = UDim2.new(0, 10, 1, -48)
        closeBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
        closeBtn.BorderSizePixel = 0
        closeBtn.Text = "CLOSE"
        closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        closeBtn.Font = Enum.Font.FredokaOne
        closeBtn.TextSize = 16
        closeBtn.AutoButtonColor = false
        closeBtn.Parent = modal
        local cbc = Instance.new("UICorner")
        cbc.CornerRadius = UDim.new(0.2, 0)
        cbc.Parent = closeBtn
        local function closeMe()
            if attachGui then attachGui:Destroy(); attachGui = nil end
            attachListFrame = nil
            activeDevModalCloser = nil
        end
        closeBtn.MouseButton1Click:Connect(closeMe)
        activeDevModalCloser = closeMe

        -- Initial fetch
        local getRemote = ReplicatedStorage:WaitForChild(Remotes.Names.GetAttachments)
        local ok, payload = pcall(function() return getRemote:InvokeServer() end)
        if ok and payload then renderInventory(payload) end
    end

    attachBtn.MouseButton1Click:Connect(function()
        openAttachments()
    end)

    -- STATS modal extracted to sibling ModuleScript to take its
    -- ~200 lines of modal code out of the main chunk's register budget.
    -- See TreeOfLife_Client/StatsModal.lua.
    local StatsModal = require(script:WaitForChild("StatsModal")).setup({
        playerGui           = playerGui,
        player              = player,
        CollectionService   = CollectionService,
        Tags                = Tags,
        closeActiveDevModal = closeActiveDevModal,
        registerCloser      = function(fn) activeDevModalCloser = fn end,
    })
    statsBtn.MouseButton1Click:Connect(StatsModal.open)

    -- (former inline stats modal removed in favor of the require above.)
    --[[ OLD INLINE STATS BLOCK
    do
    local statsGui = nil
    local function openStats()
        closeActiveDevModal()  -- close any other dev panel first
        if statsGui then statsGui:Destroy(); statsGui = nil end
        statsGui = Instance.new("ScreenGui")
        statsGui.Name = "ToL_TowerStats"
        statsGui.IgnoreGuiInset = true
        statsGui.ResetOnSpawn = false
        statsGui.DisplayOrder = 250
        statsGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.4
        dim.BorderSizePixel = 0
        dim.Parent = statsGui

        local modal = Instance.new("Frame")
        modal.Size = UDim2.new(0, 460, 0, 520)
        modal.Position = UDim2.new(0.5, -230, 0.5, -260)
        modal.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        modal.BorderSizePixel = 0
        modal.Parent = statsGui
        local mc = Instance.new("UICorner")
        mc.CornerRadius = UDim.new(0.05, 0)
        mc.Parent = modal

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0, 44)
        title.BackgroundTransparency = 1
        title.Text = "TOWER STATS"
        title.TextColor3 = Color3.fromRGB(220, 235, 255)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 22
        title.Parent = modal

        local hint = Instance.new("TextLabel")
        hint.Size = UDim2.new(1, -20, 0, 28)
        hint.Position = UDim2.new(0, 10, 0, 44)
        hint.BackgroundTransparency = 1
        hint.Text = "Total damage dealt + average DPS since first hit"
        hint.TextColor3 = Color3.fromRGB(170, 180, 200)
        hint.TextWrapped = true
        hint.Font = Enum.Font.Gotham
        hint.TextSize = 12
        hint.Parent = modal

        -- Column header
        local hdr = Instance.new("Frame")
        hdr.Size = UDim2.new(1, -20, 0, 22)
        hdr.Position = UDim2.new(0, 10, 0, 78)
        hdr.BackgroundColor3 = Color3.fromRGB(40, 46, 60)
        hdr.BorderSizePixel = 0
        hdr.Parent = modal
        local hdrc = Instance.new("UICorner")
        hdrc.CornerRadius = UDim.new(0.3, 0); hdrc.Parent = hdr
        local function hdrLabel(text, xScale, xOffset, wScale, wOffset, align)
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(wScale, wOffset, 1, 0)
            l.Position = UDim2.new(xScale, xOffset, 0, 0)
            l.BackgroundTransparency = 1
            l.Text = text
            l.TextColor3 = Color3.fromRGB(200, 210, 230)
            l.Font = Enum.Font.GothamBold
            l.TextSize = 11
            l.TextXAlignment = align or Enum.TextXAlignment.Left
            l.Parent = hdr
            return l
        end
        hdrLabel("TOWER",    0, 8, 0.50, -8)
        hdrLabel("DAMAGE",   0.50, 0, 0.25, 0, Enum.TextXAlignment.Right)
        hdrLabel("DPS",      0.75, 0, 0.25, -8, Enum.TextXAlignment.Right)

        local listFrame = Instance.new("ScrollingFrame")
        listFrame.Size = UDim2.new(1, -20, 1, -150)
        listFrame.Position = UDim2.new(0, 10, 0, 104)
        listFrame.BackgroundTransparency = 1
        listFrame.BorderSizePixel = 0
        listFrame.ScrollBarThickness = 6
        listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
        listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
        listFrame.Parent = modal
        local listLayout = Instance.new("UIListLayout")
        listLayout.FillDirection = Enum.FillDirection.Vertical
        listLayout.Padding = UDim.new(0, 4)
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.Parent = listFrame

        local closeBtn = Instance.new("TextButton")
        closeBtn.Size = UDim2.new(1, -20, 0, 38)
        closeBtn.Position = UDim2.new(0, 10, 1, -48)
        closeBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
        closeBtn.BorderSizePixel = 0
        closeBtn.Text = "CLOSE"
        closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        closeBtn.Font = Enum.Font.FredokaOne
        closeBtn.TextSize = 16
        closeBtn.AutoButtonColor = false
        closeBtn.Parent = modal
        local cbc = Instance.new("UICorner")
        cbc.CornerRadius = UDim.new(0.2, 0); cbc.Parent = closeBtn

        -- Row rendering: rebuild the list each refresh. Cheap (≤ ~12 towers)
        -- and avoids tracking per-row state across attribute changes.
        local uid = player.UserId
        local function formatNum(n)
            if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
            if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
            return string.format("%d", math.floor(n + 0.5))
        end
        local function rebuild()
            if not listFrame.Parent then return end
            for _, child in ipairs(listFrame:GetChildren()) do
                if child:IsA("Frame") then child:Destroy() end
            end
            local rows = {}
            for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local t = base.Parent
                if t and t:IsA("Model") and t:GetAttribute("Owner") == uid then
                    local dmg = t:GetAttribute("TotalDamageDone") or 0
                    local firstHit = t:GetAttribute("FirstHitTime")
                    local dps = 0
                    if firstHit then
                        local elapsed = math.max(0.1, os.clock() - firstHit)
                        dps = dmg / elapsed
                    end
                    local ttype = t:GetAttribute("TowerType") or t.Name
                    table.insert(rows, { name = ttype, dmg = dmg, dps = dps })
                end
            end
            table.sort(rows, function(a, b) return a.dmg > b.dmg end)
            for i, row in ipairs(rows) do
                local rf = Instance.new("Frame")
                rf.Size = UDim2.new(1, 0, 0, 24)
                rf.BackgroundColor3 = (i % 2 == 1)
                    and Color3.fromRGB(36, 40, 52) or Color3.fromRGB(32, 36, 48)
                rf.BorderSizePixel = 0
                rf.LayoutOrder = i
                rf.Parent = listFrame
                local rc = Instance.new("UICorner")
                rc.CornerRadius = UDim.new(0.2, 0); rc.Parent = rf
                local function cell(text, xScale, xOffset, wScale, wOffset, align, color)
                    local l = Instance.new("TextLabel")
                    l.Size = UDim2.new(wScale, wOffset, 1, 0)
                    l.Position = UDim2.new(xScale, xOffset, 0, 0)
                    l.BackgroundTransparency = 1
                    l.Text = text
                    l.TextColor3 = color or Color3.fromRGB(230, 235, 245)
                    l.Font = Enum.Font.Gotham
                    l.TextSize = 13
                    l.TextXAlignment = align or Enum.TextXAlignment.Left
                    l.Parent = rf
                end
                cell(row.name, 0, 8, 0.50, -8)
                cell(formatNum(row.dmg), 0.50, 0, 0.25, 0, Enum.TextXAlignment.Right)
                cell(string.format("%.1f", row.dps), 0.75, 0, 0.25, -8, Enum.TextXAlignment.Right)
            end
            if #rows == 0 then
                local empty = Instance.new("TextLabel")
                empty.Size = UDim2.new(1, 0, 0, 40)
                empty.BackgroundTransparency = 1
                empty.Text = "No towers placed."
                empty.TextColor3 = Color3.fromRGB(140, 150, 170)
                empty.Font = Enum.Font.Gotham
                empty.TextSize = 13
                empty.Parent = listFrame
            end
        end
        rebuild()
        local updateTask = task.spawn(function()
            while statsGui and statsGui.Parent do
                task.wait(0.5)
                rebuild()
            end
        end)

        local function closeMe()
            if statsGui then statsGui:Destroy(); statsGui = nil end
            if updateTask then pcall(task.cancel, updateTask); updateTask = nil end
            activeDevModalCloser = nil
        end
        closeBtn.MouseButton1Click:Connect(closeMe)
        activeDevModalCloser = closeMe
    end
    statsBtn.MouseButton1Click:Connect(openStats)
    end  -- end stats-modal do-block
    ]]--

    -- GROUND ZERO: nuclear reset. Wipes DataStores (attachments,
    -- permanent towers, prefs like hasSeenIntro + first-death fairy flag)
    -- and THEN fires the normal DevReset path. Use when you want to
    -- re-experience the game as a brand-new account (fairy dialogs,
    -- intro splash, zero attachments, etc.).
    groundZeroBtn.MouseButton1Click:Connect(function()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevGroundZero)
        if r then r:FireServer() end
    end)

    -- ADD STUN: fires the dev-only remote that adds a Stun stack to all
    -- of the player's owned towers. Mirrors the Stun upgrade card without
    -- waiting for the RNG to roll one. Updates the tower HUD live since
    -- the server changes the StunDuration attribute, which the HUD
    -- refreshes from on-attribute-changed signals.
    stunBtn.MouseButton1Click:Connect(function()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevAddStun)
        if r then r:FireServer() end
    end)

    -- BOSS: skip to current stage's boss with simulated upgrades. Server
    -- decides which boss based on StageState.currentStage and synthesizes
    -- the picks the player would have made up to this point with average
    -- luck (display 5 on the meter), filtered by the user's Range cap rule
    -- (don't pick Range over 60% bonus). Server then spawns the boss
    -- directly, skipping the wave-5 mob spawns. fireSkipToBoss is hoisted
    -- above with fireSkipWave so the B hotkey can reach it.
    bossBtn.MouseButton1Click:Connect(fireSkipToBoss)

    -- MAP BOSS: jump straight to the CURRENT MAP's final boss (stage 3) + kill
    -- it. Server forces stage=3, simulates all 12 picks, spawns+auto-kills,
    -- which triggers the real boss-defeat path → temp-tower picker → ladder.
    -- Useful to skip right to the reward moment from a fresh run.
    mapBossBtn.MouseButton1Click:Connect(fireSkipToMapBoss)

    -- PICKLE LORD: shortcut that fires the permanent-tower reward flow
    -- directly, no mob fight required. Useful for playtesting the
    -- permanent tower path before map 3 + the real Pickle Lord encounter
    -- are built out.
    pickleLordBtn.MouseButton1Click:Connect(function()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevKillPickleLord)
        if r then r:FireServer() end
    end)

    -- WEB WEAVER: spawn the map-2 spider boss on the current map. Web-
    -- attack mechanic kicks in after ~5s. Dying fires BossDefeated(mapId=2)
    -- → temp-tower picker with Map 2 weights.
    canopyBtn.MouseButton1Click:Connect(function()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSpawnCanopySpider)
        if r then r:FireServer() end
    end)

    -- CANOPY BIRD: spawn the map-3 bird boss on the current map. Dive-
    -- strike mechanic kicks in after ~5s. Dying fires BossDefeated(mapId=3)
    -- → temp-tower picker with Map 3 weights.
    birdBtn.MouseButton1Click:Connect(function()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSpawnCanopyBird)
        if r then r:FireServer() end
    end)

    -- RESET COOLDOWNS: fires DevResetCooldowns. Server clears Phoenix
    -- ready/cd/grace on all owned towers AND clears BonusDamageUntil.
    -- Useful for testing Phoenix without waiting 12+ minutes between triggers.
    resetCdBtn.MouseButton1Click:Connect(function()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevResetCooldowns)
        if r then r:FireServer() end
        -- Keep panel open so you can immediately re-trigger Phoenix testing.
    end)


    -- ATTACHMENT REVEAL MODAL (fires after every Final Boss kill)
    -- Big celebratory popover showing what was rolled and whether it was
    -- new / an upgrade / a duplicate. Distinct visual from the inventory.
    ReplicatedStorage:WaitForChild(Remotes.Names.AttachmentRevealed).OnClientEvent:Connect(function(payload)
        local rolled = payload.rolled
        local result = payload.result  -- "new" | "upgraded" | "duplicate"
        local entry  = payload.entry
        if not rolled or not entry then return end

        -- Duplicate rolls don't earn the player anything new, so showing a
        -- blocking "AWESOME" modal is just friction. Silent-skip — the
        -- attachment store already updated server-side, no UI needed.
        if result == "duplicate" then return end

        local def = TYPE_DEFS[rolled.type]
        if not def then return end

        local revealGui = Instance.new("ScreenGui")
        revealGui.Name = "ToL_AttachReveal"
        revealGui.IgnoreGuiInset = true
        revealGui.ResetOnSpawn = false
        revealGui.DisplayOrder = 260  -- above the game-over modal (230)
        revealGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.5
        dim.BorderSizePixel = 0
        dim.Parent = revealGui

        local card = Instance.new("Frame")
        card.Size = UDim2.new(0, 360, 0, 360)
        card.Position = UDim2.new(0.5, -180, 0.5, -180)
        card.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
        card.BorderSizePixel = 0
        card.Parent = revealGui
        local cc = Instance.new("UICorner")
        cc.CornerRadius = UDim.new(0.06, 0)
        cc.Parent = card
        local cstroke = Instance.new("UIStroke")
        cstroke.Thickness = 4
        cstroke.Color = RARITY_COLORS[rolled.rarity]
        cstroke.Parent = card

        local resultText
        if result == "new" then
            resultText = "NEW ATTACHMENT!"
        elseif result == "upgraded" then
            resultText = string.format("UPGRADED! (%s → %s)",
                RARITY_NAMES[payload.oldRarity or 1],
                RARITY_NAMES[rolled.rarity])
        else
            resultText = "Duplicate (already owned at this rarity or higher)"
        end

        local banner = Instance.new("TextLabel")
        banner.Size = UDim2.new(1, -20, 0, 30)
        banner.Position = UDim2.new(0, 10, 0, 14)
        banner.BackgroundTransparency = 1
        banner.Text = resultText
        banner.TextColor3 = (result == "duplicate")
            and Color3.fromRGB(170, 170, 180)
            or  Color3.fromRGB(255, 240, 180)
        banner.Font = Enum.Font.FredokaOne
        banner.TextSize = 18
        banner.Parent = card

        local rarityLabel = Instance.new("TextLabel")
        rarityLabel.Size = UDim2.new(1, -20, 0, 24)
        rarityLabel.Position = UDim2.new(0, 10, 0, 56)
        rarityLabel.BackgroundTransparency = 1
        rarityLabel.Text = RARITY_NAMES[rolled.rarity]
        rarityLabel.TextColor3 = RARITY_COLORS[rolled.rarity]
        rarityLabel.Font = Enum.Font.FredokaOne
        rarityLabel.TextSize = 22
        rarityLabel.Parent = card

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -20, 0, 36)
        nameLabel.Position = UDim2.new(0, 10, 0, 86)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = def.displayName
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = 30
        nameLabel.Parent = card

        local effectLabel = Instance.new("TextLabel")
        -- Autosize Y so longer descriptions (Phoenix's two-sentence blurb)
        -- wrap properly without truncating. Subtle label below uses
        -- LayoutOrder via a UIListLayout would be cleaner, but for one
        -- modal we just give effectLabel a min height and shift subtle.
        effectLabel.Size = UDim2.new(1, -20, 0, 0)
        effectLabel.AutomaticSize = Enum.AutomaticSize.Y
        effectLabel.Position = UDim2.new(0, 10, 0, 138)
        effectLabel.BackgroundTransparency = 1
        effectLabel.Text = describeEffect(rolled.type, rolled.rarity)
        effectLabel.TextColor3 = Color3.fromRGB(200, 220, 240)
        effectLabel.TextWrapped = true
        effectLabel.TextXAlignment = Enum.TextXAlignment.Center
        effectLabel.TextYAlignment = Enum.TextYAlignment.Top
        effectLabel.Font = Enum.Font.Gotham
        effectLabel.TextSize = 16
        effectLabel.Parent = card

        local subtle = Instance.new("TextLabel")
        -- Pushed down to clear the now-autosizing effectLabel above.
        -- Worst-case (Phoenix's two-sentence blurb on a narrow 360-wide card)
        -- effectLabel grows to ~60px, so 138 + 60 + 8 padding = 206.
        subtle.Size = UDim2.new(1, -20, 0, 40)
        subtle.Position = UDim2.new(0, 10, 0, 206)
        subtle.BackgroundTransparency = 1
        subtle.Text = (result == "new")
            and "Auto-equipped. Open Attachments to swap."
            or  (result == "upgraded")
                and "Your existing copy was upgraded."
                or  "No change to your inventory."
        subtle.TextColor3 = Color3.fromRGB(160, 170, 190)
        subtle.TextWrapped = true
        subtle.Font = Enum.Font.Gotham
        subtle.TextSize = 12
        subtle.Parent = card

        local okBtn = Instance.new("TextButton")
        okBtn.Size = UDim2.new(1, -40, 0, 44)
        okBtn.Position = UDim2.new(0, 20, 1, -60)
        okBtn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
        okBtn.BorderSizePixel = 0
        okBtn.AutoButtonColor = false
        okBtn.Text = "AWESOME"
        okBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        okBtn.Font = Enum.Font.FredokaOne
        okBtn.TextSize = 18
        okBtn.Parent = card
        local oc = Instance.new("UICorner")
        oc.CornerRadius = UDim.new(0.2, 0)
        oc.Parent = okBtn
        okBtn.MouseButton1Click:Connect(function()
            revealGui:Destroy()
        end)
    end)
end

------------------------------------------------------------
-- GAME SPEED SELECTOR (top-right): 1× / 2× / 3×
-- Tap a button to fast-forward the entire simulation. The server validates
-- the request (only 1/2/3 allowed) and broadcasts the new speed back so
-- the active button stays in sync across all players in the server.
------------------------------------------------------------
do
    local speedGui = Instance.new("ScreenGui")
    speedGui.Name = "ToL_SpeedSelector"
    speedGui.IgnoreGuiInset = true  -- align with top edge
    speedGui.ResetOnSpawn = false
    speedGui.DisplayOrder = 240  -- above wave HUD so it's never occluded
    speedGui.Parent = playerGui

    local SPEEDS = {1, 2, 3, 5, 10}
    local BTN_SIZE = 44
    local PADDING = 6
    -- Pause button sits to the LEFT of the 1× button, same size, one
    -- extra padding gap. Speed button count stays the same; bar widens
    -- by (BTN_SIZE + PADDING) to accommodate it.
    local barWidth = (#SPEEDS * BTN_SIZE) + ((#SPEEDS - 1) * PADDING) + (PADDING * 2)
                     + BTN_SIZE + PADDING
    local barHeight = BTN_SIZE + (PADDING * 2)

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, barWidth, 0, barHeight)
    bar.Position = UDim2.new(1, -(barWidth + 12), 0, 12)  -- top-right with margin
    bar.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
    bar.BackgroundTransparency = 0.15
    bar.BorderSizePixel = 0
    bar.Parent = speedGui
    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(0.18, 0)
    bc.Parent = bar
    local bs = Instance.new("UIStroke")
    bs.Thickness = 2
    bs.Color = Color3.fromRGB(60, 70, 90)
    bs.Parent = bar

    -- Button registry: speed-number → TextButton. Pause uses key 0.
    local buttons = {}

    local function refreshActive(currentSpeed)
        for spd, btn in pairs(buttons) do
            if spd == currentSpeed then
                btn.BackgroundColor3 = Color3.fromRGB(255, 200, 80)
                btn.TextColor3 = Color3.fromRGB(20, 20, 30)
            else
                btn.BackgroundColor3 = Color3.fromRGB(50, 60, 80)
                btn.TextColor3 = Color3.fromRGB(220, 225, 235)
            end
        end
    end

    -- PAUSE button (leftmost). Sends 0 to SetGameSpeed; server toggles
    -- ctx.paused and broadcasts 0 back. Re-clicking a speed button
    -- unpauses and resumes at that speed.
    local pauseBtn = Instance.new("TextButton")
    pauseBtn.Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE)
    pauseBtn.Position = UDim2.new(0, PADDING, 0, PADDING)
    pauseBtn.BackgroundColor3 = Color3.fromRGB(50, 60, 80)
    pauseBtn.BorderSizePixel = 0
    pauseBtn.AutoButtonColor = false
    pauseBtn.Text = "⏸"  -- pause glyph
    pauseBtn.TextColor3 = Color3.fromRGB(220, 225, 235)
    pauseBtn.Font = Enum.Font.FredokaOne
    pauseBtn.TextSize = 26
    pauseBtn.Parent = bar
    local pauseCorner = Instance.new("UICorner")
    pauseCorner.CornerRadius = UDim.new(0.25, 0)
    pauseCorner.Parent = pauseBtn
    buttons[0] = pauseBtn
    pauseBtn.MouseButton1Click:Connect(function()
        local remote = ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
        if remote then remote:FireServer(0) end
        refreshActive(0)  -- optimistic highlight
    end)

    -- Speed buttons start to the right of the pause button.
    local speedStartX = PADDING + BTN_SIZE + PADDING
    for i, spd in ipairs(SPEEDS) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE)
        btn.Position = UDim2.new(0, speedStartX + (i - 1) * (BTN_SIZE + PADDING), 0, PADDING)
        btn.BackgroundColor3 = Color3.fromRGB(50, 60, 80)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = tostring(spd) .. "×"
        btn.TextColor3 = Color3.fromRGB(220, 225, 235)
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 18
        btn.Parent = bar
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.25, 0)
        c.Parent = btn
        buttons[spd] = btn
        btn.MouseButton1Click:Connect(function()
            local remote = ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
            if remote then remote:FireServer(spd) end
            refreshActive(spd)
        end)
    end

    refreshActive(1)  -- initial state matches server default

    -- Server pushes the canonical speed any time it changes (or on PlayerAdded).
    -- 0 means paused; other values are the active game-speed multiplier.
    local changedRemote = ReplicatedStorage:WaitForChild(Remotes.Names.GameSpeedChanged)
    changedRemote.OnClientEvent:Connect(function(newSpeed)
        if type(newSpeed) ~= "number" then return end
        refreshActive(newSpeed)
    end)
end

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
-- Upgrade picker modal
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.ShowUpgrades).OnClientEvent:Connect(function(payload)
    local cards = payload.cards or {}
    local old = playerGui:FindFirstChild("ToL_UpgradePicker")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_UpgradePicker"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 220
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    bg.BackgroundTransparency = 0.2
    bg.BorderSizePixel = 0
    bg.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, IS_MOBILE and 40 or 60)
    title.Position = UDim2.new(0, 0, 0, IS_MOBILE and 100 or 110)
    title.BackgroundTransparency = 1
    if (payload.wave or 0) == 0 then
        title.Text = "First Tower Bonus — Pick an Upgrade"
    else
        title.Text = "Wave " .. payload.wave .. " Cleared — Upgrade Your Tower"
    end
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.4
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 22 or 36
    title.Parent = bg

    local CARD_W = IS_MOBILE and 180 or 240
    local CARD_H = IS_MOBILE and 210 or 280

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, CARD_H)
    row.Position = UDim2.new(0, 0, 0, IS_MOBILE and 150 or 180)
    row.BackgroundTransparency = 1
    row.Parent = bg
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, IS_MOBILE and 12 or 24)
    rowLayout.Parent = row

    local clickableAt = os.clock() + 0.6  -- short anti-accidental-tap lockout

    -- Category styles:
    --   Core: solid black border + black banner, white text. High contrast,
    --         category-forward. Core is the workhorse; identity first, rarity
    --         second (you still read it on the rarity label inside).
    --   Aux:  border tinted by rarity + white banner with black text. The
    --         rarity-colored border lets the player scan the row of Aux
    --         options and immediately see which is rarer without reading
    --         the rarity label. Banner stays white for legibility of the
    --         "AUX" label across every rarity.
    local CORE_BORDER = Color3.fromRGB(  0,   0,   0)
    local CORE_BANNER = Color3.fromRGB(  0,   0,   0)
    local CORE_TEXT   = Color3.fromRGB(255, 255, 255)
    local AUX_BANNER  = Color3.fromRGB(255, 255, 255)
    local AUX_TEXT    = Color3.fromRGB(  0,   0,   0)

    -- Absolute corner radius shared by card + banner. Must be smaller
    -- than half the banner height or Roblox's UICorner clamps the radius
    -- and the card/banner no longer match. Banner is 28/34 tall, so 12
    -- stays safely under half-height on both.
    local CARD_CORNER_PX = 12

    for _, card in ipairs(cards) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, CARD_W, 0, CARD_H)
        btn.BackgroundColor3 = card.color or Color3.fromRGB(80, 80, 90)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.Parent = row
        local cornerUi = Instance.new("UICorner")
        cornerUi.CornerRadius = UDim.new(0, CARD_CORNER_PX)
        cornerUi.Parent = btn

        -- Category border + banner. Core = black; Aux = rarity-colored
        -- border (so the player can scan "which of these Aux cards is
        -- rarest" at a glance) with a white banner for legibility.
        local cardTarget = card.target or "Core"
        local isAux = (cardTarget == "Aux")
        local rarityColor = card.color or Color3.fromRGB(200, 200, 200)
        local borderColor = isAux and rarityColor or CORE_BORDER
        local bannerColor = isAux and AUX_BANNER   or CORE_BANNER
        local textColor   = isAux and AUX_TEXT     or CORE_TEXT

        local stroke = Instance.new("UIStroke")
        stroke.Color = borderColor
        -- Aux border is the rarity color, which matches the card body. A
        -- thicker stroke ensures the border's OUTER edge (meeting the dim
        -- modal backdrop) stays visibly distinct from the card body.
        stroke.Thickness = isAux and 6 or 4
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Parent = btn

        -- Full-width top banner: CORE / AUX. The banner has its own UICorner
        -- with the same absolute radius as the card so its TOP corners
        -- precisely follow the card's top corners. The banner's BOTTOM
        -- corners would also round (creating "bumps" where the card body
        -- peeks through) — we cover them with a small rectangular "apron"
        -- drawn in the banner's color, just below the banner's rounded
        -- bottom, which visually flattens the banner's base.
        local BANNER_H = IS_MOBILE and 28 or 34
        local banner = Instance.new("TextLabel")
        banner.Size = UDim2.new(1, 0, 0, BANNER_H)
        banner.Position = UDim2.new(0, 0, 0, 0)
        banner.BackgroundColor3 = bannerColor
        banner.BorderSizePixel = 0
        banner.Text = string.upper(cardTarget)
        banner.TextColor3 = textColor
        banner.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        banner.TextStrokeTransparency = isAux and 1 or 0.3
        banner.Font = Enum.Font.FredokaOne
        banner.TextSize = IS_MOBILE and 18 or 22
        banner.ZIndex = 2  -- sits above the apron so CORE/AUX text isn't clipped
        banner.Parent = btn
        local bannerCorner = Instance.new("UICorner")
        bannerCorner.CornerRadius = UDim.new(0, CARD_CORNER_PX)
        bannerCorner.Parent = banner
        -- Apron: a full-width rectangular strip that covers the banner's
        -- rounded bottom corners. Occupies Y = (BANNER_H - radius) to
        -- Y = BANNER_H, same color as the banner. Below the card's own
        -- rounded top-corner area (at Y < radius), so the apron fits
        -- cleanly inside the card's straight-edged middle region. ZIndex
        -- is 1 (below banner at 2) so banner text renders on top of the
        -- apron strip, otherwise the apron clips the bottom of the text.
        local apron = Instance.new("Frame")
        apron.Size = UDim2.new(1, 0, 0, CARD_CORNER_PX)
        apron.Position = UDim2.new(0, 0, 0, BANNER_H - CARD_CORNER_PX)
        apron.BackgroundColor3 = bannerColor
        apron.BorderSizePixel = 0
        apron.ZIndex = 1
        apron.Parent = btn

        -- Rarity label (below the banner)
        local rarityLabel = Instance.new("TextLabel")
        rarityLabel.Size = UDim2.new(1, -16, 0, 32)
        rarityLabel.Position = UDim2.new(0, 8, 0, IS_MOBILE and 34 or 42)
        rarityLabel.BackgroundTransparency = 1
        rarityLabel.Text = string.upper(card.rarity or "?")
        rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        rarityLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        rarityLabel.TextStrokeTransparency = 0.3
        rarityLabel.Font = Enum.Font.FredokaOne
        rarityLabel.TextSize = IS_MOBILE and 20 or 26
        rarityLabel.Parent = btn

        -- Description
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -20, 0, 60)
        descLabel.Position = UDim2.new(0, 10, 0.5, -30)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = card.description or ""
        descLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = 0.3
        descLabel.Font = Enum.Font.FredokaOne
        descLabel.TextSize = IS_MOBILE and 20 or 26
        descLabel.TextWrapped = true
        descLabel.Parent = btn

        local cta = Instance.new("TextLabel")
        cta.Size = UDim2.new(1, -20, 0, 32)
        cta.Position = UDim2.new(0, 10, 1, -44)
        cta.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        cta.BackgroundTransparency = 0.5
        cta.Text = "TAP TO CLAIM"
        cta.TextColor3 = Color3.fromRGB(255, 255, 255)
        cta.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        cta.TextStrokeTransparency = 0.3
        cta.Font = Enum.Font.FredokaOne
        cta.TextSize = IS_MOBILE and 14 or 18
        cta.Parent = btn
        local ctaCorner = Instance.new("UICorner")
        ctaCorner.CornerRadius = UDim.new(0.3, 0)
        ctaCorner.Parent = cta

        btn.MouseButton1Click:Connect(function()
            if os.clock() < clickableAt then return end
            ReplicatedStorage:WaitForChild(Remotes.Names.UpgradePicked):FireServer(card)
            -- Disable first so the screen-space GUI stops absorbing input
            -- this same frame; destroy on task.defer so any in-flight input
            -- events see the gui as non-interactive rather than a torn-down-
            -- but-still-queued reference. MouseBehavior reset force-releases
            -- any mouse capture state Roblox's GuiService held onto during
            -- the click — without it, right-click-to-rotate sometimes no-ops
            -- for a second or two after the picker closes.
            gui.Enabled = false
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            task.defer(function() if gui.Parent then gui:Destroy() end end)
        end)
    end
end)

------------------------------------------------------------
-- Temp-tower reward picker (map bosses)
-- Parallel to ShowUpgrades but with temp-tower-specific fields: tower
-- name, rarity-scaled stats, footprint indicator, stock count. Cards
-- the player already owns at equal-or-higher rarity arrive flagged
-- `dud = true` — after a brief reveal, those cards visually transform
-- into reroll-token cards. The player still picks ONE card total, so
-- 3 dupes does not mean 3 tokens; it means the player picks one of
-- the 3 token cards and gets +1 token. The server resolves the grant
-- (tower vs token) from its own pending-picker state keyed off cardIndex.
------------------------------------------------------------

-- Plain-English summary of a tower's special mechanic. Designed to read
-- clearly for a ~10-year-old — no "r=7" or percentages, just what the
-- tower actually does. Numbers we DO show are whole + intuitive
-- ("stuns for 1 second" is fine; "stun 0.8s every 2.7s" is not).
local function describeSecondaryStats(stats)
    if stats.slowPct and stats.slowSeconds then
        return "Slows enemies down"
    elseif stats.stunSeconds and stats.stunCooldown then
        return "Freezes enemies in place"
    elseif stats.pierceCount then
        return ("Shoots through %d enemies"):format(stats.pierceCount)
    elseif stats.chainJumps then
        return ("Lightning jumps to %d more"):format(stats.chainJumps)
    elseif stats.cloudRadius and stats.cloudSeconds then
        return "Leaves a poison cloud"
    elseif stats.patchRadius then
        return "Sticky trap slows + hurts"
    elseif stats.splashRadius then
        return "Splash damage"
    elseif stats.blastRadius then
        return "Huge explosion"
    else
        return "Strong single shot"
    end
end

-- Size bucket from a footprint (max of w, h in grid cells). Kid-friendly
-- size words instead of "8×8 cells."
local function describeSize(fw, fd)
    local m = math.max(fw or 4, fd or 4)
    if m <= 4 then return "Small"
    elseif m <= 6 then return "Medium"
    elseif m <= 8 then return "Big"
    else return "HUGE" end
end

-- Look up a tower def by id so the card can render the tower's icon using
-- the same iconBuilder the hotbar uses — keeps visual identity consistent
-- and lets kids match "the spotted red mushroom on the card" → "the same
-- one on the hotbar after I claim it."
local function findTowerDefById(towerId)
    for _, d in ipairs(towerDefs) do
        if d.id == towerId then return d end
    end
    return nil
end

ReplicatedStorage:WaitForChild(Remotes.Names.ShowTempTowerReward).OnClientEvent:Connect(function(payload)
    local cards = payload.cards or {}
    local old = playerGui:FindFirstChild("ToL_TempTowerPicker")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_TempTowerPicker"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 220
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    bg.BackgroundTransparency = 0.2
    bg.BorderSizePixel = 0
    bg.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, IS_MOBILE and 40 or 60)
    title.Position = UDim2.new(0, 0, 0, IS_MOBILE and 70 or 80)
    title.BackgroundTransparency = 1
    title.Text = payload.title or "Boss Defeated — Choose a Temporary Tower"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.4
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 22 or 34
    title.Parent = bg

    -- Temp tower cards need more vertical room than upgrade cards because
    -- they pack name + rarity + description + stats + secondary + footprint
    -- + stock into one card. Height tuned so all blocks breathe.
    local CARD_W = IS_MOBILE and 200 or 270
    local CARD_H = IS_MOBILE and 280 or 360

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, CARD_H)
    row.Position = UDim2.new(0, 0, 0, IS_MOBILE and 120 or 150)
    row.BackgroundTransparency = 1
    row.Parent = bg
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, IS_MOBILE and 12 or 24)
    rowLayout.Parent = row

    -- Anti-accidental-tap lockout. Also gives the dud-to-token animation
    -- room to complete before the player can click (so they visually see
    -- the card become a token before picking it).
    local clickableAt = os.clock() + 0.9

    for cardIndex, card in ipairs(cards) do
        local dud = card.dud == true
        local baseColor = card.color or Color3.fromRGB(80, 80, 90)
        local dudBg = Color3.fromRGB(55, 55, 60)

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, CARD_W, 0, CARD_H)
        btn.BackgroundColor3 = dud and dudBg or baseColor
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.Parent = row
        local cornerUi = Instance.new("UICorner")
        cornerUi.CornerRadius = UDim.new(0.08, 0)
        cornerUi.Parent = btn

        local function tTxt() return dud and 0.5 or 0 end
        local function tStroke() return dud and 0.8 or 0.3 end

        -- Tower display name — BIG top banner, primary read.
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -16, 0, 40)
        nameLabel.Position = UDim2.new(0, 8, 0, 14)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = card.displayName or "?"
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.TextStrokeTransparency = tStroke()
        nameLabel.TextTransparency = tTxt()
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = IS_MOBILE and 24 or 32
        nameLabel.Parent = btn

        -- Tower icon — use the same flat icon the hotbar uses so the kid
        -- recognizes the tower visually. Big central square.
        local ICON_BG = IS_MOBILE and 72 or 96
        local iconHolder = Instance.new("Frame")
        iconHolder.AnchorPoint = Vector2.new(0.5, 0)
        iconHolder.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 58 or 62)
        iconHolder.Size = UDim2.new(0, ICON_BG, 0, ICON_BG)
        iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconHolder.BackgroundTransparency = dud and 0.3 or 0
        iconHolder.BorderSizePixel = 0
        iconHolder.Parent = btn
        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0.12, 0)
        iconCorner.Parent = iconHolder
        do
            local towerDef = findTowerDefById(card.towerId)
            if towerDef and towerDef.iconBuilder then
                towerDef.iconBuilder(iconHolder)
            end
        end

        -- Rarity pill — small colored strip under the icon. Server already
        -- sent the rarity color on card.color (same palette as upgrade cards).
        local rarityColor = card.color or Color3.fromRGB(200, 200, 200)
        local rarityPill = Instance.new("TextLabel")
        rarityPill.AnchorPoint = Vector2.new(0.5, 0)
        rarityPill.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 138 or 168)
        rarityPill.Size = UDim2.new(0, IS_MOBILE and 110 or 140, 0, IS_MOBILE and 24 or 28)
        rarityPill.BackgroundColor3 = rarityColor
        rarityPill.BackgroundTransparency = dud and 0.5 or 0.1
        rarityPill.BorderSizePixel = 0
        rarityPill.Text = string.upper(card.rarity or "?")
        rarityPill.TextColor3 = Color3.fromRGB(255, 255, 255)
        rarityPill.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        rarityPill.TextStrokeTransparency = tStroke()
        rarityPill.TextTransparency = tTxt()
        rarityPill.Font = Enum.Font.FredokaOne
        rarityPill.TextSize = IS_MOBILE and 14 or 18
        rarityPill.Parent = btn
        local pillCorner = Instance.new("UICorner")
        pillCorner.CornerRadius = UDim.new(0.4, 0)
        pillCorner.Parent = rarityPill

        -- Description — simple sentence describing what the tower feels like.
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -20, 0, IS_MOBILE and 44 or 52)
        descLabel.Position = UDim2.new(0, 10, 0, IS_MOBILE and 168 or 204)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = card.description or ""
        descLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = tStroke()
        descLabel.TextTransparency = tTxt()
        descLabel.Font = Enum.Font.FredokaOne
        descLabel.TextSize = IS_MOBILE and 15 or 18
        descLabel.TextWrapped = true
        descLabel.Parent = btn

        -- Special ability — plain-English mechanic summary, highlighted.
        local stats = card.stats or {}
        local specialLabel = Instance.new("TextLabel")
        specialLabel.Size = UDim2.new(1, -20, 0, IS_MOBILE and 22 or 28)
        specialLabel.Position = UDim2.new(0, 10, 0, IS_MOBILE and 212 or 258)
        specialLabel.BackgroundTransparency = 1
        specialLabel.Text = describeSecondaryStats(stats)
        specialLabel.TextColor3 = Color3.fromRGB(255, 250, 210)
        specialLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        specialLabel.TextStrokeTransparency = tStroke()
        specialLabel.TextTransparency = tTxt()
        specialLabel.Font = Enum.Font.FredokaOne
        specialLabel.TextSize = IS_MOBILE and 15 or 19
        specialLabel.Parent = btn

        -- Badges row: "Place N"  ·  "Size"
        local footprint = card.footprint or { w = 4, h = 4 }
        local fw = footprint.w or footprint[1] or 4
        local fd = footprint.h or footprint[2] or 4
        local badgeRow = Instance.new("TextLabel")
        badgeRow.Size = UDim2.new(1, -20, 0, IS_MOBILE and 24 or 28)
        badgeRow.Position = UDim2.new(0, 10, 1, IS_MOBILE and -78 or -88)
        badgeRow.BackgroundTransparency = 1
        badgeRow.Text = ("Place %d  ·  Size: %s"):format(card.stock or 1, describeSize(fw, fd))
        badgeRow.TextColor3 = Color3.fromRGB(255, 255, 255)
        badgeRow.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        badgeRow.TextStrokeTransparency = tStroke()
        badgeRow.TextTransparency = tTxt()
        badgeRow.Font = Enum.Font.FredokaOne
        badgeRow.TextSize = IS_MOBILE and 15 or 19
        badgeRow.Parent = btn

        -- Big friendly CTA. Duds transform to "CLAIM TOKEN" in the animation
        -- below; for real tower cards, this is a bright green button.
        local cta = Instance.new("TextLabel")
        cta.Size = UDim2.new(1, -20, 0, IS_MOBILE and 38 or 44)
        cta.Position = UDim2.new(0, 10, 1, IS_MOBILE and -46 or -54)
        cta.BackgroundColor3 = dud and Color3.fromRGB(100, 70, 30) or Color3.fromRGB(60, 170, 80)
        cta.BackgroundTransparency = 0
        cta.Text = dud and "ALREADY OWNED" or "CLAIM!"
        cta.TextColor3 = dud and Color3.fromRGB(255, 220, 120) or Color3.fromRGB(255, 255, 255)
        cta.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        cta.TextStrokeTransparency = 0.3
        cta.Font = Enum.Font.FredokaOne
        cta.TextSize = IS_MOBILE and 18 or 24
        cta.Parent = btn
        local ctaCorner = Instance.new("UICorner")
        ctaCorner.CornerRadius = UDim.new(0.3, 0)
        ctaCorner.Parent = cta

        -- Duds animate into reroll-token cards. Sequence:
        --   0.00s: card shows grayed tower data + "ALREADY OWNED" banner so
        --          the player reads why this slot is dud
        --   0.35s: tower labels + footprint fade out
        --   0.65s: card background shifts to amber, token content fades in
        --   0.90s: card fully transformed; clickable picks the reroll token
        -- Click handler is shared — the server decides tower-vs-token based on
        -- its own pending-picker state for this cardIndex, so the client never
        -- has to tell the server which kind of pick it was.
        if dud then
            task.delay(0.35, function()
                if not btn.Parent then return end
                local fadeInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
                for _, child in ipairs(btn:GetChildren()) do
                    if child:IsA("TextLabel") and child ~= cta then
                        TweenService:Create(child, fadeInfo,
                            { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
                    elseif child:IsA("Frame") then
                        -- Footprint holder + its filled rectangle child
                        TweenService:Create(child, fadeInfo, { BackgroundTransparency = 1 }):Play()
                        for _, sub in ipairs(child:GetChildren()) do
                            if sub:IsA("Frame") then
                                TweenService:Create(sub, fadeInfo, { BackgroundTransparency = 1 }):Play()
                            end
                        end
                    end
                end
                task.wait(0.3)
                if not btn.Parent then return end
                -- Swap card to reroll-token visual. Delete all old children
                -- except UICorner (the rounded-corner modifier) and the CTA
                -- (reused with an updated label).
                for _, child in ipairs(btn:GetChildren()) do
                    if not child:IsA("UICorner") and child ~= cta then
                        child:Destroy()
                    end
                end
                -- Amber background = reroll-token palette (matches the purple
                -- reroll button's "token" framing — warm/gold = bonus currency)
                TweenService:Create(btn, fadeInfo,
                    { BackgroundColor3 = Color3.fromRGB(120, 90, 50) }):Play()

                -- Token icon: glowing disc centered on the card
                local tokenHolder = Instance.new("Frame")
                tokenHolder.AnchorPoint = Vector2.new(0.5, 0.5)
                tokenHolder.Position = UDim2.new(0.5, 0, 0.45, 0)
                tokenHolder.Size = UDim2.new(0, 90, 0, 90)
                tokenHolder.BackgroundColor3 = Color3.fromRGB(255, 195, 90)
                tokenHolder.BackgroundTransparency = 1
                tokenHolder.BorderSizePixel = 0
                tokenHolder.Parent = btn
                local tokenCorner = Instance.new("UICorner")
                tokenCorner.CornerRadius = UDim.new(0.5, 0)
                tokenCorner.Parent = tokenHolder
                TweenService:Create(tokenHolder, fadeInfo, { BackgroundTransparency = 0.1 }):Play()

                -- Token glyph — using "↻" (refresh/reroll) over a plain text
                -- label so it reads without needing an image asset.
                local tokenGlyph = Instance.new("TextLabel")
                tokenGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
                tokenGlyph.Position = UDim2.new(0.5, 0, 0.5, 0)
                tokenGlyph.Size = UDim2.new(1, 0, 1, 0)
                tokenGlyph.BackgroundTransparency = 1
                tokenGlyph.Text = "↻"
                tokenGlyph.TextColor3 = Color3.fromRGB(80, 50, 10)
                tokenGlyph.TextStrokeTransparency = 1
                tokenGlyph.Font = Enum.Font.FredokaOne
                tokenGlyph.TextSize = 64
                tokenGlyph.TextTransparency = 1
                tokenGlyph.Parent = tokenHolder
                TweenService:Create(tokenGlyph, fadeInfo, { TextTransparency = 0 }):Play()

                local tokenLabel = Instance.new("TextLabel")
                tokenLabel.Size = UDim2.new(1, -16, 0, 30)
                tokenLabel.Position = UDim2.new(0, 8, 0, 10)
                tokenLabel.BackgroundTransparency = 1
                tokenLabel.Text = "REROLL TOKEN"
                tokenLabel.TextColor3 = Color3.fromRGB(255, 240, 200)
                tokenLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
                tokenLabel.TextStrokeTransparency = 1
                tokenLabel.TextTransparency = 1
                tokenLabel.Font = Enum.Font.FredokaOne
                tokenLabel.TextSize = IS_MOBILE and 20 or 26
                tokenLabel.Parent = btn
                TweenService:Create(tokenLabel, fadeInfo,
                    { TextTransparency = 0, TextStrokeTransparency = 0.3 }):Play()

                -- "(was: <tower name>)" subline so the player sees which dupe
                -- was substituted for the token
                local subLabel = Instance.new("TextLabel")
                subLabel.Size = UDim2.new(1, -16, 0, 22)
                subLabel.Position = UDim2.new(0, 8, 0, 40)
                subLabel.BackgroundTransparency = 1
                subLabel.Text = ("(owned: %s)"):format(card.displayName or "?")
                subLabel.TextColor3 = Color3.fromRGB(220, 200, 160)
                subLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
                subLabel.TextStrokeTransparency = 1
                subLabel.TextTransparency = 1
                subLabel.Font = Enum.Font.FredokaOne
                subLabel.TextSize = IS_MOBILE and 14 or 17
                subLabel.Parent = btn
                TweenService:Create(subLabel, fadeInfo,
                    { TextTransparency = 0.15, TextStrokeTransparency = 0.5 }):Play()

                -- Update the CTA text + color to match the new green CLAIM style
                -- but in an amber flavor so it reads "bonus token, not a tower."
                cta.Text = "CLAIM +1 TOKEN"
                cta.TextColor3 = Color3.fromRGB(255, 235, 180)
                cta.BackgroundColor3 = Color3.fromRGB(200, 140, 50)
            end)
        end

        btn.MouseButton1Click:Connect(function()
            if os.clock() < clickableAt then return end
            ReplicatedStorage:WaitForChild(Remotes.Names.TempTowerPicked):FireServer({ cardIndex = cardIndex })
            -- Same Enabled=false + deferred Destroy + MouseBehavior reset
            -- as the upgrade picker so the subsequent right-click isn't
            -- absorbed by a still-interactive GUI mid-teardown.
            gui.Enabled = false
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            task.defer(function() if gui.Parent then gui:Destroy() end end)
        end)
    end
end)

------------------------------------------------------------
-- Permanent-tower reward modal (Pickle Lord defeat)
-- Server fires ShowPermanentTowerReward when the run boss dies. Payload
-- is either:
--   { title, subtitle, cards = { card1..3 } }          — picker state
--   { title, subtitle, cards = {}, confirmation=true } — post-pick result
-- Cards reuse the temp-tower card layout but with gold category styling
-- to signal "permanent — kept between runs."
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.ShowPermanentTowerReward).OnClientEvent:Connect(function(payload)
    local cards = (payload and payload.cards) or {}
    local old = playerGui:FindFirstChild("ToL_PermanentTowerReward")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_PermanentTowerReward"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 225
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(40, 20, 12)  -- warm dim for celebration
    bg.BackgroundTransparency = 0.15
    bg.BorderSizePixel = 0
    bg.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, IS_MOBILE and 40 or 54)
    title.Position = UDim2.new(0, 0, 0, IS_MOBILE and 60 or 70)
    title.BackgroundTransparency = 1
    title.Text = payload and payload.title or "PERMANENT TOWER REWARD"
    title.TextColor3 = Color3.fromRGB(255, 220, 120)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.3
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 26 or 38
    title.Parent = bg

    if payload and payload.subtitle then
        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.new(1, -40, 0, IS_MOBILE and 36 or 44)
        sub.Position = UDim2.new(0, 20, 0, IS_MOBILE and 102 or 124)
        sub.BackgroundTransparency = 1
        sub.Text = payload.subtitle
        sub.TextColor3 = Color3.fromRGB(255, 240, 200)
        sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        sub.TextStrokeTransparency = 0.4
        sub.Font = Enum.Font.FredokaOne
        sub.TextSize = IS_MOBILE and 16 or 22
        sub.TextWrapped = true
        sub.Parent = bg
    end

    -- Confirmation state: just a dismiss button, no cards to pick.
    if payload and payload.confirmation then
        local ok = Instance.new("TextButton")
        ok.AnchorPoint = Vector2.new(0.5, 0.5)
        ok.Position = UDim2.new(0.5, 0, 0.55, 0)
        ok.Size = UDim2.new(0, IS_MOBILE and 220 or 280, 0, IS_MOBILE and 48 or 56)
        ok.BackgroundColor3 = Color3.fromRGB(220, 170, 60)
        ok.BorderSizePixel = 0
        ok.AutoButtonColor = false
        ok.Text = "CONTINUE"
        ok.TextColor3 = Color3.fromRGB(255, 255, 255)
        ok.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        ok.TextStrokeTransparency = 0.3
        ok.Font = Enum.Font.FredokaOne
        ok.TextSize = IS_MOBILE and 22 or 28
        ok.Parent = bg
        local okc = Instance.new("UICorner")
        okc.CornerRadius = UDim.new(0.3, 0)
        okc.Parent = ok
        ok.MouseButton1Click:Connect(function() gui:Destroy() end)
        return
    end

    local CARD_W = IS_MOBILE and 200 or 270
    local CARD_H = IS_MOBILE and 280 or 360

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, CARD_H)
    row.Position = UDim2.new(0, 0, 0, IS_MOBILE and 156 or 190)
    row.BackgroundTransparency = 1
    row.Parent = bg
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, IS_MOBILE and 12 or 24)
    rowLayout.Parent = row

    local clickableAt = os.clock() + 0.6

    for cardIndex, card in ipairs(cards) do
        local isDup = card.isDuplicate == true
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, CARD_W, 0, CARD_H)
        btn.BackgroundColor3 = card.color or Color3.fromRGB(80, 80, 90)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.ClipsDescendants = true
        btn.Parent = row
        local cornerUi = Instance.new("UICorner")
        cornerUi.CornerRadius = UDim.new(0.08, 0)
        cornerUi.Parent = btn

        -- Gold stroke + banner to distinguish permanent picks from temp ones.
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(255, 210, 90)
        stroke.Thickness = 5
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Parent = btn

        local banner = Instance.new("TextLabel")
        banner.Size = UDim2.new(1, 0, 0, IS_MOBILE and 28 or 34)
        banner.BackgroundColor3 = Color3.fromRGB(220, 170, 60)
        banner.BorderSizePixel = 0
        banner.Text = isDup and "ALREADY OWNED" or "PERMANENT"
        banner.TextColor3 = Color3.fromRGB(40, 20, 0)
        banner.Font = Enum.Font.FredokaOne
        banner.TextSize = IS_MOBILE and 18 or 22
        banner.Parent = btn

        -- Tower name
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -16, 0, 36)
        nameLabel.Position = UDim2.new(0, 8, 0, IS_MOBILE and 34 or 40)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = card.displayName or "?"
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.TextStrokeTransparency = 0.3
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = IS_MOBILE and 22 or 28
        nameLabel.Parent = btn

        -- Rarity pill
        local rarityPill = Instance.new("TextLabel")
        rarityPill.AnchorPoint = Vector2.new(0.5, 0)
        rarityPill.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 70 or 80)
        rarityPill.Size = UDim2.new(0, IS_MOBILE and 110 or 140, 0, IS_MOBILE and 24 or 28)
        rarityPill.BackgroundColor3 = card.color or Color3.fromRGB(200, 200, 200)
        rarityPill.BorderSizePixel = 0
        rarityPill.Text = string.upper(card.rarity or "?")
        rarityPill.TextColor3 = Color3.fromRGB(255, 255, 255)
        rarityPill.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        rarityPill.TextStrokeTransparency = 0.3
        rarityPill.Font = Enum.Font.FredokaOne
        rarityPill.TextSize = IS_MOBILE and 14 or 18
        rarityPill.Parent = btn
        local pillCorner = Instance.new("UICorner")
        pillCorner.CornerRadius = UDim.new(0.4, 0)
        pillCorner.Parent = rarityPill

        -- Tower icon (reuse hotbar icon builders)
        local iconHolder = Instance.new("Frame")
        iconHolder.AnchorPoint = Vector2.new(0.5, 0)
        iconHolder.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 106 or 120)
        iconHolder.Size = UDim2.new(0, IS_MOBILE and 72 or 96, 0, IS_MOBILE and 72 or 96)
        iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconHolder.BorderSizePixel = 0
        iconHolder.Parent = btn
        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0.12, 0)
        iconCorner.Parent = iconHolder
        do
            local towerDef = findTowerDefById(card.towerId)
            if towerDef and towerDef.iconBuilder then
                towerDef.iconBuilder(iconHolder)
            end
        end

        -- Description
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -20, 0, 40)
        descLabel.Position = UDim2.new(0, 10, 0, IS_MOBILE and 192 or 232)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = card.description or ""
        descLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = 0.3
        descLabel.Font = Enum.Font.FredokaOne
        descLabel.TextSize = IS_MOBILE and 14 or 17
        descLabel.TextWrapped = true
        descLabel.Parent = btn

        -- Dup hint
        if isDup and card.ownedRarity then
            local dupHint = Instance.new("TextLabel")
            dupHint.Size = UDim2.new(1, -20, 0, 22)
            dupHint.Position = UDim2.new(0, 10, 0, IS_MOBILE and 236 or 280)
            dupHint.BackgroundTransparency = 1
            dupHint.Text = "(you have " .. tostring(card.ownedRarity) .. ")"
            dupHint.TextColor3 = Color3.fromRGB(255, 220, 150)
            dupHint.Font = Enum.Font.FredokaOne
            dupHint.TextSize = IS_MOBILE and 14 or 16
            dupHint.Parent = btn
        end

        -- CTA
        local cta = Instance.new("TextLabel")
        cta.Size = UDim2.new(1, -20, 0, IS_MOBILE and 38 or 44)
        cta.Position = UDim2.new(0, 10, 1, IS_MOBILE and -46 or -54)
        cta.BackgroundColor3 = isDup and Color3.fromRGB(100, 70, 30)
            or Color3.fromRGB(220, 170, 60)
        cta.Text = isDup and "NO UPGRADE" or "MAKE PERMANENT!"
        cta.TextColor3 = isDup and Color3.fromRGB(255, 220, 150) or Color3.fromRGB(40, 20, 0)
        cta.Font = Enum.Font.FredokaOne
        cta.TextSize = IS_MOBILE and 18 or 22
        cta.Parent = btn
        local ctaCorner = Instance.new("UICorner")
        ctaCorner.CornerRadius = UDim.new(0.3, 0)
        ctaCorner.Parent = cta

        btn.MouseButton1Click:Connect(function()
            if os.clock() < clickableAt then return end
            ReplicatedStorage:WaitForChild(Remotes.Names.PermanentTowerPicked):FireServer({
                cardIndex = cardIndex,
            })
            -- Server will re-fire ShowPermanentTowerReward with confirmation=true,
            -- which rebuilds the modal. Leave the modal up until then.
        end)
    end
end)

------------------------------------------------------------
-- First-time intro modal
-- Shown once per session on first portal entry. Briefly introduces the
-- core concepts: protect the heart, Core vs Aux towers, rarity colors,
-- ammo piles. Reads plainly for a 10-year-old player; "Aux, not axe" is
-- the one-joke we lean into so the terminology lands.
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.ShowIntro).OnClientEvent:Connect(function()
    local old = playerGui:FindFirstChild("ToL_Intro")
    if old then old:Destroy() end

    -- Pause the game while the intro is up — otherwise the first wave
    -- can start marching while the player is still reading the tutorial.
    -- SetGameSpeed(0) = paused (the speed system preserves the prior
    -- value so unpause restores whatever speed the player had).
    local setSpeed = ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
        or ReplicatedStorage:FindFirstChild("SetGameSpeed")
    if setSpeed then setSpeed:FireServer(0) end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_Intro"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 240  -- above most other modals during first-entry
    gui.Parent = playerGui

    local dim = Instance.new("Frame")
    dim.Size = UDim2.fromScale(1, 1)
    dim.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
    dim.BackgroundTransparency = 0.15
    dim.BorderSizePixel = 0
    dim.Parent = gui

    local CARD_W = IS_MOBILE and 340 or 520
    -- Height sized to 4 bullets (was 5). Formula: top (78/90) + bullets
    -- (4 rows @ 60/66 + 3 gaps @ 10/14) + button-area (92/110) ≈ 440/506.
    local CARD_H = IS_MOBILE and 450 or 510
    local card = Instance.new("Frame")
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.new(0.5, 0, 0.5, 0)
    card.Size = UDim2.new(0, CARD_W, 0, CARD_H)
    card.BackgroundColor3 = Color3.fromRGB(28, 32, 42)
    card.BorderSizePixel = 0
    card.Parent = dim
    local cc = Instance.new("UICorner")
    cc.CornerRadius = UDim.new(0.05, 0)
    cc.Parent = card
    local cstroke = Instance.new("UIStroke")
    cstroke.Thickness = 3
    cstroke.Color = Color3.fromRGB(120, 200, 130)
    cstroke.Parent = card

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 0, IS_MOBILE and 46 or 56)
    title.Position = UDim2.new(0, 10, 0, IS_MOBILE and 14 or 18)
    title.BackgroundTransparency = 1
    title.Text = "Welcome to the Tree of Life!"
    title.TextColor3 = Color3.fromRGB(255, 240, 180)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.3
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 26 or 34
    title.TextWrapped = true
    title.Parent = card

    -- Body: a list of short bullet lines. Each bullet line has a colored
    -- dot prefix (or category swatch) so the reader scans by color.
    local BULLETS = {
        { dot = Color3.fromRGB(220,  80,  90),
          text = "Protect the Tree's Heart." },
        { dot = Color3.fromRGB(  0,   0,   0),  -- CORE banner color = black
          text = "You have one and only one CORE TOWER. Use it well." },
        { dot = Color3.fromRGB(255, 255, 255),  -- AUX banner color = white
          text = "AUX TOWERS are bonus towers you earn from beating a map. They will help you on your run." },
        { dot = Color3.fromRGB(120, 200, 140),
          text = "Choose your upgrade cards wisely!" },
    }

    local bulletsHolder = Instance.new("Frame")
    bulletsHolder.Size = UDim2.new(1, -32, 1, -(IS_MOBILE and 170 or 190))
    bulletsHolder.Position = UDim2.new(0, 16, 0, IS_MOBILE and 78 or 90)
    bulletsHolder.BackgroundTransparency = 1
    bulletsHolder.Parent = card
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.Padding = UDim.new(0, IS_MOBILE and 10 or 14)
    layout.Parent = bulletsHolder

    for _, bullet in ipairs(BULLETS) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, IS_MOBILE and 60 or 66)
        row.BackgroundTransparency = 1
        row.Parent = bulletsHolder

        local dot = Instance.new("Frame")
        dot.Size = UDim2.new(0, 14, 0, 14)
        dot.Position = UDim2.new(0, 0, 0, IS_MOBILE and 6 or 8)
        dot.BackgroundColor3 = bullet.dot
        dot.BorderSizePixel = 0
        dot.Parent = row
        local dotCorner = Instance.new("UICorner")
        dotCorner.CornerRadius = UDim.new(0.5, 0)
        dotCorner.Parent = dot

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -26, 1, 0)
        lbl.Position = UDim2.new(0, 26, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = bullet.text
        lbl.TextColor3 = Color3.fromRGB(235, 235, 240)
        lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        lbl.TextStrokeTransparency = 0.5
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = IS_MOBILE and 15 or 18
        lbl.TextWrapped = true
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextYAlignment = Enum.TextYAlignment.Top
        lbl.Parent = row
    end

    local gotIt = Instance.new("TextButton")
    gotIt.AnchorPoint = Vector2.new(0.5, 1)
    gotIt.Size = UDim2.new(0, IS_MOBILE and 220 or 280, 0, IS_MOBILE and 48 or 54)
    gotIt.Position = UDim2.new(0.5, 0, 1, IS_MOBILE and -16 or -22)
    gotIt.BackgroundColor3 = Color3.fromRGB(60, 170, 80)
    gotIt.BorderSizePixel = 0
    gotIt.AutoButtonColor = false
    gotIt.Text = "GOT IT!"
    gotIt.TextColor3 = Color3.fromRGB(255, 255, 255)
    gotIt.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    gotIt.TextStrokeTransparency = 0.3
    gotIt.Font = Enum.Font.FredokaOne
    gotIt.TextSize = IS_MOBILE and 22 or 28
    gotIt.Parent = card
    local gc = Instance.new("UICorner")
    gc.CornerRadius = UDim.new(0.25, 0)
    gc.Parent = gotIt
    gotIt.MouseButton1Click:Connect(function()
        gui:Destroy()
        -- Resume the game at 1x after the player dismisses the intro.
        -- (They can re-pause via the speed-bar HUD if they want.)
        local setSpeed = ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
            or ReplicatedStorage:FindFirstChild("SetGameSpeed")
        if setSpeed then setSpeed:FireServer(1) end
    end)
end)

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

--[[ OLD INLINE FAIRY BLOCK — superseded by the require() above.
do
    local FAIRY_ATTACHMENTS = {
        {type = "PowerCore",
         title = "Power Core",
         blurb = "Boosts your Core tower's damage. Good for beating stage bosses faster."},
        {type = "Detonator",
         title = "Detonator",
         blurb = "Enemies explode when they die, damaging nearby enemies. Great for clearing waves."},
        {type = "Phoenix",
         title = "Phoenix Charm",
         blurb = "If the heart would die, burns all enemies in a huge area and saves it. Once per long cooldown."},
    }
    ReplicatedStorage:WaitForChild(Remotes.Names.ShowFirstDeathFairy).OnClientEvent:Connect(function()
        local old = playerGui:FindFirstChild("ToL_FirstDeathFairy")
        if old then old:Destroy() end
        -- Close the GameOver banner if it's up — the fairy replaces it.
        -- Also unlock the wave HUD (gameLost gate) so the forthcoming
        -- resurrection broadcast isn't ignored by the WaveState handler.
        local over = playerGui:FindFirstChild("ToL_GameOver")
        if over then over:Destroy() end
        gameLost = false

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_FirstDeathFairy"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 245  -- above game-over banner (220) and intro (240)
        gui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(6, 10, 20)
        dim.BackgroundTransparency = 0.35
        dim.BorderSizePixel = 0
        dim.Parent = gui

        local card = Instance.new("Frame")
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.new(0.5, 0, 0.5, 0)
        card.Size = UDim2.new(0, IS_MOBILE and 360 or 560, 0, IS_MOBILE and 520 or 540)
        card.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        card.BorderSizePixel = 0
        card.Parent = dim
        local cc = Instance.new("UICorner")
        cc.CornerRadius = UDim.new(0.05, 0)
        cc.Parent = card
        local cstroke = Instance.new("UIStroke")
        cstroke.Thickness = 3
        cstroke.Color = Color3.fromRGB(255, 200, 230)
        cstroke.Parent = card

        -- Fairy + title
        local fairy = Instance.new("TextLabel")
        fairy.Size = UDim2.new(1, 0, 0, 54)
        fairy.Position = UDim2.new(0, 0, 0, 14)
        fairy.BackgroundTransparency = 1
        fairy.Text = "✨  A Fairy Appears  ✨"
        fairy.TextColor3 = Color3.fromRGB(255, 220, 240)
        fairy.TextStrokeColor3 = Color3.fromRGB(40, 0, 40)
        fairy.TextStrokeTransparency = 0.3
        fairy.Font = Enum.Font.FredokaOne
        fairy.TextSize = IS_MOBILE and 24 or 30
        fairy.Parent = card

        local speech = Instance.new("TextLabel")
        speech.Size = UDim2.new(1, -32, 0, IS_MOBILE and 100 or 80)
        speech.Position = UDim2.new(0, 16, 0, IS_MOBILE and 70 or 74)
        speech.BackgroundTransparency = 1
        speech.Text = "The Tree of Life is hard. You'll try many times — that's the point.\n\nTake one of these to help you on the way. More help will come if you keep at it."
        speech.TextColor3 = Color3.fromRGB(235, 235, 245)
        speech.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        speech.TextStrokeTransparency = 0.4
        speech.Font = Enum.Font.Gotham
        speech.TextSize = IS_MOBILE and 14 or 16
        speech.TextWrapped = true
        speech.TextXAlignment = Enum.TextXAlignment.Center
        speech.TextYAlignment = Enum.TextYAlignment.Top
        speech.Parent = card

        local choicesHolder = Instance.new("Frame")
        choicesHolder.Size = UDim2.new(1, -32, 1, -(IS_MOBILE and 200 or 180))
        choicesHolder.Position = UDim2.new(0, 16, 0, IS_MOBILE and 180 or 170)
        choicesHolder.BackgroundTransparency = 1
        choicesHolder.Parent = card
        local chLayout = Instance.new("UIListLayout")
        chLayout.FillDirection = Enum.FillDirection.Vertical
        chLayout.Padding = UDim.new(0, 10)
        chLayout.SortOrder = Enum.SortOrder.LayoutOrder
        chLayout.Parent = choicesHolder

        for i, entry in ipairs(FAIRY_ATTACHMENTS) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1, 0, 0, IS_MOBILE and 88 or 92)
            btn.BackgroundColor3 = Color3.fromRGB(44, 50, 70)
            btn.AutoButtonColor = true
            btn.BorderSizePixel = 0
            btn.Text = ""
            btn.LayoutOrder = i
            btn.Parent = choicesHolder
            local bc = Instance.new("UICorner")
            bc.CornerRadius = UDim.new(0.15, 0); bc.Parent = btn

            local title = Instance.new("TextLabel")
            title.Size = UDim2.new(1, -16, 0, 24)
            title.Position = UDim2.new(0, 12, 0, 8)
            title.BackgroundTransparency = 1
            title.Text = entry.title .. "  (Common)"
            title.TextColor3 = Color3.fromRGB(255, 240, 200)
            title.Font = Enum.Font.FredokaOne
            title.TextSize = IS_MOBILE and 18 or 20
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.Parent = btn

            local blurb = Instance.new("TextLabel")
            blurb.Size = UDim2.new(1, -16, 0, IS_MOBILE and 52 or 56)
            blurb.Position = UDim2.new(0, 12, 0, 34)
            blurb.BackgroundTransparency = 1
            blurb.Text = entry.blurb
            blurb.TextColor3 = Color3.fromRGB(210, 220, 235)
            blurb.Font = Enum.Font.Gotham
            blurb.TextSize = IS_MOBILE and 13 or 14
            blurb.TextWrapped = true
            blurb.TextXAlignment = Enum.TextXAlignment.Left
            blurb.TextYAlignment = Enum.TextYAlignment.Top
            blurb.Parent = btn

            btn.MouseButton1Click:Connect(function()
                local r = ReplicatedStorage:FindFirstChild(Remotes.Names.PickFirstDeathAttachment)
                if r then r:FireServer({ attType = entry.type }) end
                gui:Destroy()
            end)
        end
    end)

    -- Co-op toast: fired on players who are NOT the first-death picker,
    -- while the picker chooses their attachment. Auto-dismisses when the
    -- GameOver banner closes (gameLost flag flips false on resurrection)
    -- or after a hard cap so it can't linger forever. Covers the game-
    -- over screen with a soft message so the team knows why wave 1 is
    -- about to restart.
    ReplicatedStorage:WaitForChild(Remotes.Names.ShowResurrectionNotice).OnClientEvent:Connect(function()
        -- Close the GameOver banner + unlock wave HUD so the forthcoming
        -- wave-restart broadcast isn't ignored by the gameLost gate.
        local over = playerGui:FindFirstChild("ToL_GameOver")
        if over then over:Destroy() end
        gameLost = false
        local existing = playerGui:FindFirstChild("ToL_ResurrectionNotice")
        if existing then existing:Destroy() end
        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_ResurrectionNotice"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 246
        gui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(6, 10, 20)
        dim.BackgroundTransparency = 0.5
        dim.BorderSizePixel = 0
        dim.Parent = gui

        local panel = Instance.new("Frame")
        panel.AnchorPoint = Vector2.new(0.5, 0.5)
        panel.Position = UDim2.new(0.5, 0, 0.5, 0)
        panel.Size = UDim2.new(0, IS_MOBILE and 340 or 460, 0, IS_MOBILE and 140 or 160)
        panel.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        panel.BorderSizePixel = 0
        panel.Parent = dim
        local pc = Instance.new("UICorner")
        pc.CornerRadius = UDim.new(0.05, 0); pc.Parent = panel
        local ps = Instance.new("UIStroke")
        ps.Thickness = 2; ps.Color = Color3.fromRGB(255, 200, 230); ps.Parent = panel

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -20, 0, 44)
        title.Position = UDim2.new(0, 10, 0, 18)
        title.BackgroundTransparency = 1
        title.Text = "✨  Someone is being resurrected!  ✨"
        title.TextColor3 = Color3.fromRGB(255, 220, 240)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = IS_MOBILE and 18 or 22
        title.TextWrapped = true
        title.Parent = panel

        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.new(1, -20, 0, 60)
        sub.Position = UDim2.new(0, 10, 0, 64)
        sub.BackgroundTransparency = 1
        sub.Text = "The wave will restart with help from a fairy."
        sub.TextColor3 = Color3.fromRGB(210, 220, 235)
        sub.Font = Enum.Font.Gotham
        sub.TextSize = IS_MOBILE and 14 or 15
        sub.TextWrapped = true
        sub.Parent = panel

        -- Hard-dismiss cap: 30s so a disconnected/AFK picker can't leave
        -- the banner stuck forever. The resurrection BindableEvent on the
        -- server also clears game-over state which the wave broadcast
        -- reflects — the simpler version here just auto-expires.
        task.delay(30, function() if gui.Parent then gui:Destroy() end end)
    end)
end
]]--

------------------------------------------------------------
-- Permanent-tower equip modal (pedestal)
-- Shown when the server fires ShowPermanentEquip after a player taps the
-- pedestal ProximityPrompt. Renders the player's persisted permanent-tower
-- collection. Empty collection shows a "defeat the Pickle Lord" hint so
-- the pedestal reads as "the place your future permanent towers will live"
-- rather than being silently useless.
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.ShowPermanentEquip).OnClientEvent:Connect(function(payload)
    local entries = (payload and payload.entries) or {}
    local equippedType = payload and payload.equipped
    local old = playerGui:FindFirstChild("ToL_PermanentEquip")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_PermanentEquip"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 220
    gui.Parent = playerGui

    -- Background dim covers the screen. Clicking the dim also closes the
    -- popup — the panel itself swallows clicks via its TextButton children
    -- so only dim-clicks reach this handler.
    local bg = Instance.new("TextButton")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    bg.BackgroundTransparency = 0.4
    bg.BorderSizePixel = 0
    bg.AutoButtonColor = false
    bg.Text = ""
    bg.Parent = gui
    bg.MouseButton1Click:Connect(function() gui:Destroy() end)

    -- Centered popup panel (not fullscreen). Sized generously to fit the
    -- existing card layout; bg dim still covers the rest of the screen so
    -- the player reads it as a modal but can easily dismiss by clicking
    -- outside the panel or hitting the X.
    local PANEL_W = IS_MOBILE and 520 or 900
    local PANEL_H = IS_MOBILE and 420 or 520
    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.new(0.5, 0, 0.5, 0)
    panel.Size = UDim2.new(0, PANEL_W, 0, PANEL_H)
    panel.BackgroundColor3 = Color3.fromRGB(28, 30, 42)
    panel.BackgroundTransparency = 0.05
    panel.BorderSizePixel = 0
    panel.Parent = bg
    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 16)
    panelCorner.Parent = panel
    local panelStroke = Instance.new("UIStroke")
    panelStroke.Thickness = 2
    panelStroke.Color = Color3.fromRGB(90, 90, 110)
    panelStroke.Transparency = 0.3
    panelStroke.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -60, 0, IS_MOBILE and 40 or 60)
    title.Position = UDim2.new(0, 12, 0, 12)
    title.BackgroundTransparency = 1
    title.Text = "Equip Permanent Tower"
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.4
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 22 or 30
    title.Parent = panel

    -- Close button — top-right X on the panel itself (not the fullscreen dim).
    local closeBtn = Instance.new("TextButton")
    closeBtn.AnchorPoint = Vector2.new(1, 0)
    closeBtn.Size = UDim2.new(0, 36, 0, 36)
    closeBtn.Position = UDim2.new(1, -12, 0, 12)
    closeBtn.BackgroundColor3 = Color3.fromRGB(160, 60, 60)
    closeBtn.BorderSizePixel = 0
    closeBtn.AutoButtonColor = false
    closeBtn.Text = "×"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.FredokaOne
    closeBtn.TextSize = 26
    closeBtn.Parent = panel
    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0.3, 0)
    closeCorner.Parent = closeBtn
    closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

    -- Escape key closes the popup too.
    local escConn
    escConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Enum.KeyCode.Escape then
            if gui.Parent then gui:Destroy() end
            if escConn then escConn:Disconnect() end
        end
    end)
    gui.AncestryChanged:Connect(function(_, p)
        if not p and escConn then escConn:Disconnect() end
    end)

    if #entries == 0 then
        -- Empty state — first-time pedestal tap before any Pickle Lord kill.
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, -40, 1, -100)
        empty.Position = UDim2.new(0, 20, 0, 80)
        empty.BackgroundTransparency = 1
        empty.Text = "No permanent towers yet.\n\nDefeat the Pickle Lord to unlock a permanent tower you can carry between runs."
        empty.TextColor3 = Color3.fromRGB(235, 230, 200)
        empty.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        empty.TextStrokeTransparency = 0.4
        empty.Font = Enum.Font.FredokaOne
        empty.TextSize = IS_MOBILE and 18 or 22
        empty.TextWrapped = true
        empty.Parent = panel
        return
    end

    local CARD_W = IS_MOBILE and 200 or 240
    local CARD_H = IS_MOBILE and 260 or 300

    local row = Instance.new("ScrollingFrame")
    row.Size = UDim2.new(1, -32, 0, CARD_H + 30)
    row.Position = UDim2.new(0, 16, 0, IS_MOBILE and 70 or 90)
    row.BackgroundTransparency = 1
    row.BorderSizePixel = 0
    row.ScrollBarThickness = 6
    row.CanvasSize = UDim2.new(0, 0, 0, 0)  -- auto-sized by layout
    row.AutomaticCanvasSize = Enum.AutomaticSize.X
    row.ScrollingDirection = Enum.ScrollingDirection.X
    row.Parent = panel
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, IS_MOBILE and 12 or 20)
    rowLayout.Parent = row

    for _, entry in ipairs(entries) do
        local isEquipped = entry.isEquipped
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, CARD_W, 0, CARD_H)
        btn.BackgroundColor3 = entry.color or Color3.fromRGB(80, 80, 90)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.Parent = row
        local cornerUi = Instance.new("UICorner")
        cornerUi.CornerRadius = UDim.new(0.08, 0)
        cornerUi.Parent = btn
        if isEquipped then
            -- Stroke outline + brighter tint so the currently equipped one pops.
            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(255, 255, 255)
            stroke.Thickness = 3
            stroke.Parent = btn
        end

        -- Name
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -16, 0, 36)
        nameLabel.Position = UDim2.new(0, 8, 0, 12)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = entry.displayName or entry.towerId
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.TextStrokeTransparency = 0.3
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = IS_MOBILE and 22 or 28
        nameLabel.Parent = btn

        -- Rarity pill
        local rarityPill = Instance.new("TextLabel")
        rarityPill.AnchorPoint = Vector2.new(0.5, 0)
        rarityPill.Position = UDim2.new(0.5, 0, 0, 52)
        rarityPill.Size = UDim2.new(0, IS_MOBILE and 110 or 130, 0, 24)
        rarityPill.BackgroundColor3 = entry.color or Color3.fromRGB(200, 200, 200)
        rarityPill.BackgroundTransparency = 0.1
        rarityPill.BorderSizePixel = 0
        rarityPill.Text = string.upper(entry.rarity or "?")
        rarityPill.TextColor3 = Color3.fromRGB(255, 255, 255)
        rarityPill.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        rarityPill.TextStrokeTransparency = 0.3
        rarityPill.Font = Enum.Font.FredokaOne
        rarityPill.TextSize = IS_MOBILE and 14 or 18
        rarityPill.Parent = btn
        local pillCorner = Instance.new("UICorner")
        pillCorner.CornerRadius = UDim.new(0.4, 0)
        pillCorner.Parent = rarityPill

        -- Icon using the same hotbar icon builder
        local iconHolder = Instance.new("Frame")
        iconHolder.AnchorPoint = Vector2.new(0.5, 0)
        iconHolder.Position = UDim2.new(0.5, 0, 0, 86)
        iconHolder.Size = UDim2.new(0, IS_MOBILE and 76 or 96, 0, IS_MOBILE and 76 or 96)
        iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconHolder.BorderSizePixel = 0
        iconHolder.Parent = btn
        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0.12, 0)
        iconCorner.Parent = iconHolder
        do
            local towerDef = findTowerDefById(entry.towerId)
            if towerDef and towerDef.iconBuilder then
                towerDef.iconBuilder(iconHolder)
            end
        end

        -- Description
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -20, 0, 44)
        descLabel.Position = UDim2.new(0, 10, 0, IS_MOBILE and 174 or 196)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = entry.description or ""
        descLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = 0.3
        descLabel.Font = Enum.Font.FredokaOne
        descLabel.TextSize = IS_MOBILE and 14 or 17
        descLabel.TextWrapped = true
        descLabel.Parent = btn

        -- CTA
        local cta = Instance.new("TextLabel")
        cta.Size = UDim2.new(1, -20, 0, IS_MOBILE and 36 or 42)
        cta.Position = UDim2.new(0, 10, 1, IS_MOBILE and -44 or -52)
        cta.BackgroundColor3 = isEquipped and Color3.fromRGB(120, 120, 130)
            or Color3.fromRGB(60, 170, 80)
        cta.Text = isEquipped and "EQUIPPED" or "EQUIP!"
        cta.TextColor3 = Color3.fromRGB(255, 255, 255)
        cta.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        cta.TextStrokeTransparency = 0.3
        cta.Font = Enum.Font.FredokaOne
        cta.TextSize = IS_MOBILE and 18 or 22
        cta.Parent = btn
        local ctaCorner = Instance.new("UICorner")
        ctaCorner.CornerRadius = UDim.new(0.3, 0)
        ctaCorner.Parent = cta

        btn.MouseButton1Click:Connect(function()
            if isEquipped then return end
            ReplicatedStorage:WaitForChild(Remotes.Names.PermanentTowerEquipped):FireServer({
                towerId = entry.towerId,
            })
            -- Don't close — the server will re-fire ShowPermanentEquip with the
            -- updated "equipped" state; we leave the modal open so the player
            -- sees confirmation on the card they just picked.
        end)
    end
end)

------------------------------------------------------------
-- CANOPY SPIDER WEB TARGETS
-- Click-to-pop handled entirely by the server-side ClickDetector on the
-- web Part (see systems/CanopySpiderBoss.lua). No client UI — the web
-- ball's glow + cursor hover are the interactability cue.
------------------------------------------------------------

------------------------------------------------------------
-- CANOPY BIRD DIVE TARGETS
-- Server spawns Parts tagged `BirdDiveMark` above a targeted tower.
-- Client attaches a "TAP!" BillboardGui button; tapping fires
-- TapBirdDive with the MarkId → server cancels the dive and deals
-- bonus damage to the bird. Pattern mirrors SpiderWeb above; kept in
-- a separate block so they can evolve independently (different button
-- color / text / icon etc.).
------------------------------------------------------------
do
    local function attachBirdTargetUI(markPart)
        if markPart:FindFirstChild("BirdDiveGui") then return end
        local bb = Instance.new("BillboardGui")
        bb.Name = "BirdDiveGui"
        bb.Size = UDim2.new(0, 80, 0, 80)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = 500
        bb.Parent = markPart

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromScale(1, 1)
        btn.BackgroundColor3 = Color3.fromRGB(255, 180, 80)
        btn.BackgroundTransparency = 0.1
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = "TAP!"
        btn.TextColor3 = Color3.fromRGB(40, 20, 0)
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 26
        btn.Parent = bb
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.5, 0)
        corner.Parent = btn
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(255, 255, 255)
        stroke.Thickness = 3
        stroke.Parent = btn

        btn.MouseButton1Click:Connect(function()
            local markId = markPart:GetAttribute("MarkId")
            if not markId then return end
            local r = ReplicatedStorage:FindFirstChild(Remotes.Names.TapBirdDive)
            if r then r:FireServer({ markId = markId }) end
            btn.Visible = false
        end)
    end

    for _, mark in ipairs(CollectionService:GetTagged(Tags.BirdDiveMark)) do
        attachBirdTargetUI(mark)
    end
    CollectionService:GetInstanceAddedSignal(Tags.BirdDiveMark):Connect(attachBirdTargetUI)
end

------------------------------------------------------------
-- WEBBED TOWER VISUAL
-- When a tower's WebbedUntil attribute is set in the future, overlay a
-- sticky-web BillboardGui on it. Removed automatically once the
-- timestamp passes. Simple white-stroked "X" inside a webbed circle
-- reads as "this tower is locked out" without needing an image asset.
------------------------------------------------------------
do
    local function attachWebbedOverlay(tower)
        if not tower:IsDescendantOf(workspace) then return end
        local existing = tower:FindFirstChild("WebbedOverlay")
        if existing then return end

        local anchor = Instance.new("Part")
        anchor.Name = "WebbedOverlay"
        -- Sized to roughly match the BillboardGui bubble's screen area so
        -- a click anywhere on the bubble raycasts onto this Part's hit box
        -- (the BillboardGui's TextButton was supposed to catch clicks but
        -- was unreliable; a ClickDetector on the anchor is the robust path).
        anchor.Shape = Enum.PartType.Ball
        -- 10-stud ball (was 5): gives the 3D ClickDetector backup a much
        -- wider hit box so clicks anywhere near the visible bubble catch,
        -- not just within the original 5-stud core. Invisible, so the
        -- visual impression still matches the BillboardGui circle.
        anchor.Size = Vector3.new(10, 10, 10)
        anchor.Transparency = 1
        anchor.CanCollide = false
        anchor.Anchored = true
        -- Position the overlay at the VERTICAL CENTER of the tower so the
        -- WEBBED bubble sits over the tower body itself — easier to read as
        -- "this tower is the webbed one" and harder to miss-tap than an
        -- overhead bubble that can drift into the HUD band.
        local centerCF
        if tower:IsA("Model") then
            local ok, cf = pcall(function() return tower:GetBoundingBox() end)
            if ok and cf then centerCF = cf end
        end
        local bb = tower:FindFirstChild("TowerBase")
            or tower:FindFirstChildWhichIsA("BasePart")
        if centerCF then
            anchor.CFrame = CFrame.new(centerCF.Position)
        elseif bb then
            anchor.CFrame = CFrame.new(bb.Position)
        end
        anchor.Parent = tower

        local gui = Instance.new("BillboardGui")
        gui.Size = UDim2.new(0, 120, 0, 120)  -- visual only; click zone = the 3D anchor ball
        gui.AlwaysOnTop = true
        gui.LightInfluence = 0
        gui.MaxDistance = 500
        gui.Adornee = anchor  -- explicit to avoid implicit-Adornee quirks
        gui.Parent = anchor

        -- Visual label (NOT a TextButton). Kept non-clickable so in-flight
        -- web Parts in front of the tower win the click raycast — GUI
        -- buttons would eat clicks regardless of what's visually on top,
        -- but a plain Frame is invisible to the input system. Actual
        -- click handling: the server-side WebbedClickDetector parented
        -- to the tower Model catches clicks on any descendant part
        -- (including the 10-stud anchor ball here), so the click area
        -- stays wide without a GUI layer.
        local visual = Instance.new("Frame")
        visual.Size = UDim2.fromScale(1, 1)
        visual.BackgroundColor3 = Color3.fromRGB(240, 240, 255)
        visual.BackgroundTransparency = 0.2
        visual.BorderSizePixel = 0
        visual.Parent = gui
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.5, 0)
        corner.Parent = visual
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(160, 160, 180)
        stroke.Thickness = 2
        stroke.Parent = visual

        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Text = "WEBBED"
        label.TextColor3 = Color3.fromRGB(80, 80, 110)
        label.TextStrokeColor3 = Color3.fromRGB(255, 255, 255)
        label.TextStrokeTransparency = 0.2
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 16
        label.Parent = visual

        local function refresh()
            local taps = tower:GetAttribute("WebTapsRemaining")
            if taps and taps > 0 then
                label.Text = "WEBBED\n" .. tostring(taps)
            else
                label.Text = "WEBBED"
            end
        end
        refresh()
        tower:GetAttributeChangedSignal("WebTapsRemaining"):Connect(refresh)

        -- 3D ClickDetector on the invisible 10-stud anchor. Two reasons
        -- this exists alongside the server-side WebbedClickDetector on
        -- the tower Model:
        --   1. The anchor is a client-only Part — a server ClickDetector
        --      on the Model only reliably catches clicks on SERVER-side
        --      descendants (tower base, column, gem). A click on the
        --      anchor's widened area around the tower needs its own CD.
        --   2. Both ClickDetectors fire `TapSpiderWeb` which the server
        --      handler routes through the SAME decrement path, so they
        --      can't double-count — raycasts hit one Part per click,
        --      and whichever ClickDetector owns that Part fires.
        local cd = Instance.new("ClickDetector")
        cd.MaxActivationDistance = 500
        cd.Parent = anchor
        cd.MouseClick:Connect(function()
            local r = ReplicatedStorage:FindFirstChild(Remotes.Names.TapSpiderWeb)
            if r then r:FireServer({ tower = tower }) end
            visual.BackgroundTransparency = 0.5
            task.delay(0.12, function()
                if visual.Parent then visual.BackgroundTransparency = 0.2 end
            end)
        end)
    end

    local function tickWebbedOverlays()
        local now = os.clock()
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local tower = base.Parent
            if tower and tower.Parent then
                local webbedUntil = tower:GetAttribute("WebbedUntil") or 0
                local existing = tower:FindFirstChild("WebbedOverlay")
                if now < webbedUntil and not existing then
                    attachWebbedOverlay(tower)
                elseif now >= webbedUntil and existing then
                    existing:Destroy()
                end
            end
        end
    end

    RunService.Heartbeat:Connect(tickWebbedOverlays)
end

------------------------------------------------------------
-- Game over modal
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.GameOver).OnClientEvent:Connect(function(payload)
    local old = playerGui:FindFirstChild("ToL_GameOver")
    if old then old:Destroy() end
    -- Also tear down the upgrade picker if it's currently showing, so the
    -- "TAP TO CLAIM" cards don't sit underneath the game-over modal.
    local picker = playerGui:FindFirstChild("ToL_UpgradePicker")
    if picker then picker:Destroy() end
    -- Same for the temp-tower reward picker (boss defeat → pick 1 of 3).
    local tempPicker = playerGui:FindFirstChild("ToL_TempTowerPicker")
    if tempPicker then tempPicker:Destroy() end
    -- Same for the permanent-tower equip modal (pedestal).
    local permEquip = playerGui:FindFirstChild("ToL_PermanentEquip")
    if permEquip then permEquip:Destroy() end
    -- Same for the permanent-tower reward modal (Pickle Lord defeat).
    local permReward = playerGui:FindFirstChild("ToL_PermanentTowerReward")
    if permReward then permReward:Destroy() end
    -- Tear down boss minigame targets if any are still up
    local bossTargets = playerGui:FindFirstChild("ToL_BossTargets")
    if bossTargets then bossTargets:Destroy() end

    local isWin = payload.result == "win"
    -- If we lost, override the wave HUD to say DEFEATED so it doesn't fall
    -- through to the "All waves cleared" branch when the loss happens on
    -- the boss (final wave).
    if not isWin then
        gameLost = true
        waveLabel.Text = "DEFEATED"
        waveFrame.Visible = true
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_GameOver"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 230
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = isWin and Color3.fromRGB(20, 60, 30) or Color3.fromRGB(60, 20, 20)
    bg.BackgroundTransparency = 0.25
    bg.BorderSizePixel = 0
    bg.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 80)
    title.Position = UDim2.new(0, 0, 0.35, 0)
    title.BackgroundTransparency = 1
    title.Text = isWin and "VICTORY!" or "THE HEART FELL"
    title.TextColor3 = isWin and Color3.fromRGB(255, 255, 180) or Color3.fromRGB(255, 120, 120)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.3
    title.Font = Enum.Font.FredokaOne
    title.TextSize = 64
    title.Parent = bg

    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, 0, 0, 64)  -- 2 lines for "...until falling to <long boss name>"
    sub.Position = UDim2.new(0, 0, 0.48, 0)
    sub.BackgroundTransparency = 1
    sub.TextWrapped = true
    do
        local totalDefeated = payload.totalWavesDefeated or 0
        if isWin then
            if payload.defeatedFinalBoss then
                sub.Text = string.format("You defeated the Pickle Lord after %d rounds!", totalDefeated)
            else
                sub.Text = string.format("You defended the Tree through %d rounds", totalDefeated)
            end
        else
            if payload.killerBossName and totalDefeated > 0 then
                sub.Text = string.format("You held out for %d rounds until falling to %s",
                    totalDefeated, payload.killerBossName)
            elseif payload.killerBossName then
                sub.Text = string.format("%s has defeated you", payload.killerBossName)
            elseif totalDefeated > 0 then
                sub.Text = string.format("You held out for %d rounds before falling", totalDefeated)
            else
                sub.Text = "The first wave overwhelmed your defenses"
            end
        end
    end
    sub.TextColor3 = Color3.fromRGB(230, 230, 230)
    sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    sub.TextStrokeTransparency = 0.4
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 22
    sub.Parent = bg

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 200, 0, 50)
    btn.Position = UDim2.new(0.5, -100, 0.62, 0)  -- nudged down to clear the 2-line subtitle
    btn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Text = "RESET & PLAY AGAIN"
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    btn.TextStrokeTransparency = 0.4
    btn.Font = Enum.Font.FredokaOne
    btn.TextSize = 20
    btn.Parent = bg
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0.2, 0)
    c.Parent = btn

    btn.MouseButton1Click:Connect(function()
        -- CRITICAL: clear the gameLost lock so the WaveState handler stops
        -- ignoring server updates. Without this, wave 1 runs server-side
        -- after reset but the HUD stays stuck on DEFEATED, looking frozen.
        gameLost = false
        ReplicatedStorage:WaitForChild(Remotes.Names.DevReset):FireServer()
        -- Always respawn at map 1 on death-reset, regardless of where the
        -- player died. DevReset clears state server-side; DevTeleport moves
        -- the player's character back to the map 1 TD room and auto-starts
        -- wave 1. Without this, a death on map 2 leaves the player on
        -- map 2 while waves run "somewhere" on map 1 — confusing.
        task.delay(0.25, function()
            local tp = ReplicatedStorage:FindFirstChild(Remotes.Names.DevTeleport)
            if tp then tp:FireServer("map1") end
        end)
        gui:Destroy()
    end)
end)

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
-- Final boss minigame: tappable target reticles
-- Server fires BossPhase with {phase, targetCount, window}. We render
-- N targets at random screen positions; tapping each fires BossTargetTap
-- which grants the player a 5s damage bonus.
------------------------------------------------------------
local bossTargetGui = nil
local bossCountdownGui = nil
local bossGlowGui = nil

local function clearBossTargets()
    if bossTargetGui then bossTargetGui:Destroy(); bossTargetGui = nil end
    if bossCountdownGui then bossCountdownGui:Destroy(); bossCountdownGui = nil end
    -- Restore wave HUD visibility
    if waveFrame then waveFrame.Visible = true end
end

local function showBossSuccessGlow(duration, bonusPct)
    bonusPct = bonusPct or 0
    if bossGlowGui then bossGlowGui:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_BossGlow"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 235
    gui.Parent = playerGui
    bossGlowGui = gui

    -- Red vignette: 4 sides feathered toward center
    local vignette = Instance.new("ImageLabel")
    vignette.Size = UDim2.fromScale(1, 1)
    vignette.BackgroundTransparency = 1
    vignette.Image = "rbxassetid://6011489167"  -- common radial gradient asset; falls back to colored bg
    vignette.ImageColor3 = Color3.fromRGB(255, 30, 30)
    vignette.ImageTransparency = 0.3
    vignette.ScaleType = Enum.ScaleType.Stretch
    vignette.Parent = gui

    -- Backup colored border in case the asset fails to load
    local border = Instance.new("Frame")
    border.Size = UDim2.fromScale(1, 1)
    border.BackgroundTransparency = 1
    border.BorderSizePixel = 0
    border.Parent = gui
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 18
    stroke.Color = Color3.fromRGB(255, 40, 40)
    stroke.Transparency = 0.2
    stroke.Parent = border

    -- "BONUS DAMAGE! / 100% + X%" two-line banner with RichText so the
    -- speed-bonus half can be tinted distinctly from the base 100%.
    -- Faster clears → brighter / greener bonus color, making the
    -- payoff read visually as well as numerically.
    local bonusColor
    if bonusPct >= 75 then
        bonusColor = Color3.fromRGB(120, 255, 140)   -- bright green for near-instant
    elseif bonusPct >= 40 then
        bonusColor = Color3.fromRGB(160, 255, 255)   -- cyan for mid-speed
    elseif bonusPct >= 10 then
        bonusColor = Color3.fromRGB(255, 255, 160)   -- pale yellow for slow-ish
    else
        bonusColor = Color3.fromRGB(200, 200, 200)   -- muted for "just in time"
    end
    local bonusHex = string.format("#%02x%02x%02x",
        math.floor(bonusColor.R * 255 + 0.5),
        math.floor(bonusColor.G * 255 + 0.5),
        math.floor(bonusColor.B * 255 + 0.5))

    local banner = Instance.new("TextLabel")
    banner.Size = UDim2.new(1, 0, 0, 110)
    banner.Position = UDim2.new(0, 0, 0.14, 0)
    banner.BackgroundTransparency = 1
    banner.RichText = true
    banner.Text = string.format(
        "BONUS DAMAGE!\n<font size='38'>100%% <font color='%s'>+ %d%%</font></font>",
        bonusHex, bonusPct)
    banner.TextColor3 = Color3.fromRGB(255, 220, 100)
    banner.TextStrokeColor3 = Color3.fromRGB(80, 0, 0)
    banner.TextStrokeTransparency = 0.2
    banner.Font = Enum.Font.FredokaOne
    banner.TextSize = 42
    banner.TextYAlignment = Enum.TextYAlignment.Top
    banner.Parent = gui

    -- Fade out at end
    local TweenService = game:GetService("TweenService")
    task.delay(duration - 0.4, function()
        if not gui.Parent then return end
        local info = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        TweenService:Create(vignette, info, {ImageTransparency = 1}):Play()
        TweenService:Create(stroke, info, {Transparency = 1}):Play()
        TweenService:Create(banner, info, {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
    end)
    task.delay(duration, function()
        if gui.Parent then gui:Destroy() end
        if bossGlowGui == gui then bossGlowGui = nil end
    end)
end

ReplicatedStorage:WaitForChild(Remotes.Names.BossPhase).OnClientEvent:Connect(function(payload)
    clearBossTargets()
    -- Also clear any leftover success glow from the PREVIOUS phase. Without
    -- this, if the player aces 75% (5s glow up) and 50% fires within those
    -- 5s, the misleading "DOUBLE DAMAGE!" banner is still on screen during
    -- the new attempt — making a missed phase look like a successful one.
    if bossGlowGui then
        bossGlowGui:Destroy()
        bossGlowGui = nil
    end
    local count = payload.targetCount or 4
    local window = payload.window or 5
    -- Stamped when the first dot renders so we can compute speed bonus
    -- (remainingTime / window) when all dots are cleared.
    local phaseStartTime = os.clock()

    -- Hide the regular wave HUD; the countdown bar takes its place
    if waveFrame then waveFrame.Visible = false end

    -- Purple countdown bar where the wave HUD used to be
    bossCountdownGui = Instance.new("ScreenGui")
    bossCountdownGui.Name = "ToL_BossCountdown"
    bossCountdownGui.IgnoreGuiInset = true
    bossCountdownGui.ResetOnSpawn = false
    bossCountdownGui.DisplayOrder = 240
    bossCountdownGui.Parent = playerGui

    local cdFrame = Instance.new("Frame")
    cdFrame.Size = UDim2.new(0, 280, 0, 46)
    cdFrame.Position = UDim2.new(0.5, -180, 0, 0)  -- same place as wave HUD, flush top
    cdFrame.BackgroundColor3 = Color3.fromRGB(40, 10, 60)
    cdFrame.BackgroundTransparency = 0.15
    cdFrame.BorderSizePixel = 0
    cdFrame.Parent = bossCountdownGui
    local cdCorner = Instance.new("UICorner")
    cdCorner.CornerRadius = UDim.new(0.18, 0)
    cdCorner.Parent = cdFrame

    -- Fill bar that drains
    local cdFill = Instance.new("Frame")
    cdFill.Size = UDim2.new(1, -8, 0, 8)
    cdFill.Position = UDim2.new(0, 4, 1, -12)
    cdFill.BackgroundColor3 = Color3.fromRGB(180, 80, 220)
    cdFill.BorderSizePixel = 0
    cdFill.Parent = cdFrame
    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0.4, 0)
    fillCorner.Parent = cdFill

    -- "TAP THEM ALL!" header
    local cdLabel = Instance.new("TextLabel")
    cdLabel.Size = UDim2.new(1, 0, 0, 30)
    cdLabel.Position = UDim2.new(0, 0, 0, 4)
    cdLabel.BackgroundTransparency = 1
    cdLabel.Text = "TAP THEM ALL!"
    cdLabel.TextColor3 = Color3.fromRGB(230, 200, 255)
    cdLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    cdLabel.TextStrokeTransparency = 0.4
    cdLabel.Font = Enum.Font.FredokaOne
    cdLabel.TextSize = 22
    cdLabel.Parent = cdFrame

    -- Targets gui
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_BossTargets"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 241
    gui.Parent = playerGui
    bossTargetGui = gui

    local TARGET_SIZE = 90
    local tappedCount = 0
    local minigameDone = false  -- guards against extra taps + late timeouts
    local TweenService = game:GetService("TweenService")

    -- Figure out the screen-space launch point: project the boss's world
    -- position to screen coords. Fallback to screen center if the boss is
    -- off-camera or bossPosition was missing from the payload (e.g., the
    -- boss died mid-windup — shouldn't happen but defend against it).
    local camera = Workspace.CurrentCamera
    local launchSx, launchSy = 0.5, 0.5
    if camera and payload.bossPosition then
        local sp, onScreen = camera:WorldToViewportPoint(payload.bossPosition)
        if onScreen and sp.Z > 0 then
            local vs = camera.ViewportSize
            if vs.X > 0 and vs.Y > 0 then
                launchSx = math.clamp(sp.X / vs.X, 0.05, 0.95)
                launchSy = math.clamp(sp.Y / vs.Y, 0.05, 0.95)
            end
        end
    end

    -- Each spot starts tiny AT the boss's screen position, then tweens
    -- to its final (random) resting spot while scaling up to full size.
    -- This reads as spots being launched OUT of the boss toward the player.
    local function makeBlob(i)
        -- Final landing position somewhere in the central screen area
        local sxFinal = 0.18 + math.random() * 0.64
        local syFinal = 0.22 + math.random() * 0.55

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 6, 0, 6)  -- tiny seed; grows to TARGET_SIZE on arrival
        btn.Position = UDim2.new(launchSx, -3, launchSy, -3)
        btn.BackgroundColor3 = Color3.fromRGB(180, 60, 220)
        btn.BackgroundTransparency = 0
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.Parent = gui
        local cc = Instance.new("UICorner")
        cc.CornerRadius = UDim.new(0.5, 0)
        cc.Parent = btn

        local ring = Instance.new("UIStroke")
        ring.Thickness = 4
        ring.Color = Color3.fromRGB(255, 200, 80)
        ring.Transparency = 0.15
        ring.Parent = btn

        -- Launch tween: fly from boss position to final spot while growing.
        -- Back easing gives a slight overshoot so the spot feels "thrown."
        local flyInfo = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
        TweenService:Create(btn, flyInfo, {
            Size = UDim2.new(0, TARGET_SIZE, 0, TARGET_SIZE),
            Position = UDim2.new(sxFinal, -TARGET_SIZE/2, syFinal, -TARGET_SIZE/2),
        }):Play()

        -- Per-dot guard: the btn lives for ~0.3s after tap during the pop
        -- animation, which is long enough to accept extra clicks. Without
        -- this flag rapid tapping one dot could count as N hits and win
        -- the minigame without actually tapping every dot.
        local tapped = false
        btn.MouseButton1Click:Connect(function()
            if minigameDone then return end
            if tapped then return end
            if not btn.Parent then return end
            tapped = true
            btn.AutoButtonColor = false
            btn.Active = false  -- stop further mouse events on this button
            tappedCount = tappedCount + 1

            -- Pop effect: a white burst ring that scales up + fades out,
            -- spawned as a sibling so destroying btn doesn't kill it mid-
            -- animation. Reads as a more satisfying "pop" than just the
            -- dot fading away.
            local burst = Instance.new("Frame")
            burst.AnchorPoint = Vector2.new(0.5, 0.5)
            burst.Position = UDim2.new(btn.Position.X.Scale, btn.Position.X.Offset + btn.Size.X.Offset / 2,
                                        btn.Position.Y.Scale, btn.Position.Y.Offset + btn.Size.Y.Offset / 2)
            burst.Size = UDim2.new(0, TARGET_SIZE, 0, TARGET_SIZE)
            burst.BackgroundTransparency = 1
            burst.BorderSizePixel = 0
            burst.Parent = gui
            local burstCorner = Instance.new("UICorner")
            burstCorner.CornerRadius = UDim.new(0.5, 0)
            burstCorner.Parent = burst
            local burstStroke = Instance.new("UIStroke")
            burstStroke.Thickness = 6
            burstStroke.Color = Color3.fromRGB(255, 240, 120)
            burstStroke.Transparency = 0
            burstStroke.Parent = burst
            local burstInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TweenService:Create(burst, burstInfo, {
                Size = UDim2.new(0, TARGET_SIZE * 2.2, 0, TARGET_SIZE * 2.2),
            }):Play()
            TweenService:Create(burstStroke, burstInfo, {
                Transparency = 1, Thickness = 1,
            }):Play()
            task.delay(0.45, function() if burst.Parent then burst:Destroy() end end)

            -- Dot itself: quick fade + shrink.
            local popInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TweenService:Create(btn, popInfo, {
                Size = UDim2.new(0, TARGET_SIZE * 0.4, 0, TARGET_SIZE * 0.4),
                BackgroundTransparency = 1,
            }):Play()
            TweenService:Create(ring, popInfo, {Transparency = 1}):Play()
            task.delay(0.25, function() if btn.Parent then btn:Destroy() end end)

            if tappedCount >= count then
                minigameDone = true
                -- Speed bonus: fraction of the window NOT used → extra %
                -- on top of the base 100% damage buff. Instant clear = +100%,
                -- just-in-time clear = +0%.
                local elapsed = os.clock() - phaseStartTime
                local remaining = math.max(0, window - elapsed)
                local bonusPct = math.floor((remaining / window) * 100 + 0.5)
                ReplicatedStorage:WaitForChild(Remotes.Names.BossTargetTap):FireServer({
                    bonusPct = bonusPct,
                })
                showBossSuccessGlow(payload.bonusDuration or 5, bonusPct)
                clearBossTargets()
            end
        end)
    end

    for i = 1, count do makeBlob(i) end

    -- Drain the countdown bar over `window` seconds
    task.spawn(function()
        local tween = TweenService:Create(cdFill,
            TweenInfo.new(window, Enum.EasingStyle.Linear),
            {Size = UDim2.new(0, 0, 0, 8)})
        tween:Play()
    end)

    -- Timeout: if not all blobs were tapped, clean up AND tell the server
    -- so it can web the player.
    task.delay(window, function()
        if minigameDone then return end
        minigameDone = true
        clearBossTargets()
        local missRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.BossPhaseMiss)
        if missRemote then missRemote:FireServer() end
    end)

    -- Boss dies mid-phase cleanup: if towers/Phoenix finish the boss while
    -- the tap targets are still on screen, the dots would otherwise linger
    -- until the window timer runs out. Two-pronged approach because the
    -- AncestryChanged-only fix wasn't reliable:
    --   1. AncestryChanged on the boss mob (covers the common case).
    --   2. A polling loop that fires every 0.25s checking if ANY mob
    --      tagged as a boss is still alive; if not, clear. Covers:
    --      a) The boss dying BEFORE this handler runs (so our AncestryChanged
    --         bind targets a nil boss).
    --      b) The server firing BossPhase in the final hp-gate burst right
    --         as the boss dies — the ancestry event may fire before the
    --         connection is set up.
    --      c) Future boss types whose mob name isn't "Mob_finalboss".
    local BOSS_MOB_NAMES = {
        ["Mob_finalboss"] = true,
        ["Mob_spider"]    = true,
        ["Mob_bird"]      = true,
    }
    local function anyBossAlive()
        for _, p in ipairs(Workspace:GetDescendants()) do
            if p:IsA("BasePart") and BOSS_MOB_NAMES[p.Name] then
                return true
            end
        end
        return false
    end
    local function cleanupIfPhaseActive()
        if not minigameDone then
            minigameDone = true
            clearBossTargets()
        end
    end
    local boss = nil
    for _, p in ipairs(Workspace:GetDescendants()) do
        if p:IsA("BasePart") and BOSS_MOB_NAMES[p.Name] then
            boss = p
            break
        end
    end
    if boss then
        local conn
        conn = boss.AncestryChanged:Connect(function(_, newParent)
            if newParent == nil then
                cleanupIfPhaseActive()
                if conn then conn:Disconnect() end
            end
        end)
    end
    -- Poll fallback — runs until the phase resolves (either the boss dies,
    -- all taps hit, or the timeout). Short loop, cheap, guaranteed to
    -- catch cases the AncestryChanged bind missed.
    task.spawn(function()
        while not minigameDone do
            task.wait(0.25)
            if minigameDone then return end
            if not anyBossAlive() then
                cleanupIfPhaseActive()
                return
            end
        end
    end)
end)

------------------------------------------------------------
-- BOSS WINDUP: server says the Pickle Lord has stopped and is winding up.
-- Vibrate its Part for the duration by shaking its CFrame around the
-- origin each Heartbeat. The server freezes path movement during this
-- window, so we can safely animate around the mob's current position
-- without fighting the path-advance logic.
--
-- The boss Part is found by walking the Workspace for any Part named
-- "Mob_finalboss". That's how the server names it in makeMob.
------------------------------------------------------------
local function findFinalBossPart()
    for _, p in ipairs(Workspace:GetChildren()) do
        if p:IsA("BasePart") and p.Name == "Mob_finalboss" then return p end
    end
    -- Some mobs live inside sub-folders; do a shallow descendants scan as backup.
    for _, p in ipairs(Workspace:GetDescendants()) do
        if p:IsA("BasePart") and p.Name == "Mob_finalboss" then return p end
    end
    return nil
end

ReplicatedStorage:WaitForChild(Remotes.Names.BossWindup).OnClientEvent:Connect(function(payload)
    local duration = payload.duration or 1.2
    local boss = findFinalBossPart()
    if not boss then return end
    local origin = boss.CFrame
    local startedAt = os.clock()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not boss.Parent then
            if conn then conn:Disconnect(); conn = nil end
            return
        end
        local elapsed = os.clock() - startedAt
        if elapsed >= duration then
            -- Snap back to origin so the next path-advance tick starts clean
            boss.CFrame = origin
            if conn then conn:Disconnect(); conn = nil end
            return
        end
        -- Shake amplitude ramps up over the windup for anticipation.
        local ramp = elapsed / duration
        local amp = 0.15 + ramp * 0.6  -- 0.15 → 0.75 studs
        local dx = (math.random() - 0.5) * 2 * amp
        local dy = (math.random() - 0.5) * 2 * amp
        local dz = (math.random() - 0.5) * 2 * amp
        boss.CFrame = origin + Vector3.new(dx, dy, dz)
    end)
end)

------------------------------------------------------------
-- BOSS WEB: server tells us the player missed a phase → freeze movement
-- and overlay a green web on the screen for the payload duration.
-- Player can still interact with towers (important — they need to keep
-- defending while webbed). Movement + jump are blocked by setting
-- WalkSpeed + JumpPower to 0 on the humanoid; restored on timeout.
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.BossWeb).OnClientEvent:Connect(function(payload)
    local duration = payload.duration or 3
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    -- Save current walk/jump so we can restore whatever the player had
    local savedWalk, savedJump = 16, 50
    if hum then
        savedWalk = hum.WalkSpeed
        savedJump = hum.JumpPower
        hum.WalkSpeed = 0
        hum.JumpPower = 0
    end

    -- Web overlay: a full-screen translucent pale-green tint plus radial
    -- "strands" at each corner drawn with UIStroke + rotated frames.
    local existing = playerGui:FindFirstChild("ToL_BossWeb")
    if existing then existing:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_BossWeb"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 238
    gui.Parent = playerGui

    local tint = Instance.new("Frame")
    tint.Size = UDim2.fromScale(1, 1)
    tint.BackgroundColor3 = Color3.fromRGB(220, 255, 220)
    tint.BackgroundTransparency = 0.55
    tint.BorderSizePixel = 0
    tint.ZIndex = 1
    tint.Parent = gui

    -- Corner strand frames: thin white lines radiating from each corner
    -- toward the center. Rotated rectangles look web-like on the cheap.
    local function addStrand(originScale, rotationDeg)
        local f = Instance.new("Frame")
        f.Size = UDim2.new(0, 600, 0, 3)
        f.AnchorPoint = Vector2.new(0, 0.5)
        f.Position = originScale
        f.Rotation = rotationDeg
        f.BackgroundColor3 = Color3.fromRGB(240, 255, 240)
        f.BackgroundTransparency = 0.2
        f.BorderSizePixel = 0
        f.ZIndex = 2
        f.Parent = gui
    end
    addStrand(UDim2.new(0, 0, 0, 0), 30)
    addStrand(UDim2.new(0, 0, 0, 0), 60)
    addStrand(UDim2.new(1, 0, 0, 0), 120)
    addStrand(UDim2.new(1, 0, 0, 0), 150)
    addStrand(UDim2.new(0, 0, 1, 0), -30)
    addStrand(UDim2.new(0, 0, 1, 0), -60)
    addStrand(UDim2.new(1, 0, 1, 0), -120)
    addStrand(UDim2.new(1, 0, 1, 0), -150)

    -- "WEBBED!" banner so the player understands what happened
    local banner = Instance.new("TextLabel")
    banner.Size = UDim2.new(1, 0, 0, 50)
    banner.Position = UDim2.new(0, 0, 0.35, 0)
    banner.BackgroundTransparency = 1
    banner.Text = "WEBBED!"
    banner.TextColor3 = Color3.fromRGB(160, 255, 160)
    banner.TextStrokeColor3 = Color3.fromRGB(0, 40, 0)
    banner.TextStrokeTransparency = 0.2
    banner.Font = Enum.Font.FredokaOne
    banner.TextSize = 40
    banner.ZIndex = 3
    banner.Parent = gui

    -- Restore movement + remove overlay after duration. Uses wallclock
    -- since this is a client-side penalty tied to real player time.
    task.delay(duration, function()
        if gui.Parent then gui:Destroy() end
        -- Re-resolve humanoid in case the character respawned during the
        -- web window (shouldn't happen in our game but be safe).
        local char2 = player.Character
        local hum2 = char2 and char2:FindFirstChildOfClass("Humanoid")
        if hum2 then
            hum2.WalkSpeed = savedWalk
            hum2.JumpPower = savedJump
        end
    end)
end)

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

-- Rarity colors — duplicated from the attachment inventory modal's local scope
-- so the tower HUD can show equipped-attachment rarity without cross-scope plumbing.
-- If either copy changes, update both. Index is the rarity integer (1..5).
local HUD_RARITY_COLORS = {
    Color3.fromRGB(200, 200, 200),  -- 1 Common
    Color3.fromRGB( 80, 150, 255),  -- 2 Rare
    Color3.fromRGB(180,  80, 220),  -- 3 Exceptional
    Color3.fromRGB(255, 170,  40),  -- 4 Legendary
    Color3.fromRGB(255,  60, 140),  -- 5 Mythical
}
local HUD_RARITY_NAMES = {"Common", "Rare", "Exceptional", "Legendary", "Mythical"}

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

-- Red CLOSE button under the aiming-mode column (right side of the panel).
-- Was a small ✕ in the top-right corner before — the larger labeled button
-- is easier to hit on mobile and reads more obviously as "done inspecting."
-- Matches the aiming-mode column width so it lines up under the mode row.
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 160, 0, 42)
closeBtn.Position = UDim2.new(1, -176, 0, 244)  -- modeRow top 56 + height 176 + 12 gap
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 55, 55)
closeBtn.BorderSizePixel = 0
closeBtn.AutoButtonColor = false
closeBtn.RichText = true
closeBtn.Text = "CLOSE <font color='#ffdd55'>[Q]</font>"
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.TextStrokeColor3 = Color3.fromRGB(40, 0, 0)
closeBtn.TextStrokeTransparency = 0.3
closeBtn.Font = Enum.Font.FredokaOne
closeBtn.TextSize = 18
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

-- Mode buttons column on the right. Four buttons × 38px + 3 × 8px padding = 162px.
-- Panel is 310 tall; title+divider+padding uses ~66px; bottom padding 16px leaves
-- 228px for the column — plenty.
local modeRow = Instance.new("Frame")
modeRow.Size = UDim2.new(0, 160, 0, 176)
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

local MODES = {"First", "Strongest", "Center", "Last"}
local MODE_LABELS = {First = "FIRST", Strongest = "STRONGEST", Center = "CENTER", Last = "LAST"}
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

-- (Click-debug overlay removed — the yellow/orange/magenta rings + cyan
-- floor disc were diagnostic visuals from the "fixing target" bug hunt
-- and are no longer needed now that GetMouseLocation is the single
-- coord source across raycast / overlay / bullseye cursor.)

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

-- Info (i) button + tower card modal. Opens from a small round button
-- next to the hudTitle. Dumps the selected tower's full story — name,
-- description, every stat with base/bonus breakdown, specials,
-- attachment, aux mechanic fields. Wrapped in its own do-block so the
-- helper locals + the button itself don't live in the main chunk's
-- register frame — this client script has been bumping the 200-register
-- ceiling and new top-level locals are expensive.
do
    local infoBtn = Instance.new("TextButton")
    infoBtn.AnchorPoint = Vector2.new(1, 0)  -- top-right corner anchor
    infoBtn.Size = UDim2.new(0, 26, 0, 26)
    infoBtn.Position = UDim2.new(1, -14, 0, 10)  -- 14px from right, 10px from top
    infoBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 200)
    infoBtn.BorderSizePixel = 0
    infoBtn.AutoButtonColor = false
    infoBtn.Text = "i"
    infoBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    infoBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    infoBtn.TextStrokeTransparency = 0.3
    infoBtn.Font = Enum.Font.FredokaOne
    infoBtn.TextSize = 18
    infoBtn.Parent = targetModeFrame
    local infoBtnCorner = Instance.new("UICorner")
    infoBtnCorner.CornerRadius = UDim.new(0.5, 0)
    infoBtnCorner.Parent = infoBtn

    local towerCardGui = nil
    local function closeTowerCard()
        if towerCardGui then towerCardGui:Destroy(); towerCardGui = nil end
    end

    local RARITY_NAMES = {"Common", "Rare", "Exceptional", "Legendary", "Mythical"}

    local function openTowerCard(tower)
        closeTowerCard()
        if not tower or not tower.Parent then return end

        towerCardGui = Instance.new("ScreenGui")
        towerCardGui.Name = "ToL_TowerCard"
        towerCardGui.IgnoreGuiInset = true
        towerCardGui.ResetOnSpawn = false
        towerCardGui.DisplayOrder = 260
        towerCardGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.5
        dim.BorderSizePixel = 0
        dim.Parent = towerCardGui

        local modal = Instance.new("Frame")
        modal.Size = UDim2.new(0, 440, 0, 420)  -- shorter than before (was 520);
                                                -- most towers don't fill that height
        modal.Position = UDim2.new(0.5, -220, 0.5, -210)
        modal.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        modal.BorderSizePixel = 0
        modal.Parent = towerCardGui
        local mc = Instance.new("UICorner")
        mc.CornerRadius = UDim.new(0.04, 0); mc.Parent = modal

        local typ = tower:GetAttribute("TowerType") or "Power"
        local tpl = TempTowers.Templates and TempTowers.Templates[typ]
        local rarity = tower:GetAttribute("Rarity")
        local displayName, desc
        if tpl then
            displayName = tpl.displayName or typ
            desc = tpl.description or ""
        else
            displayName = "Power Tower"
            desc = "Starter tower. Energy shots at waves of mobs. Refill ammo at yellow piles with E. Accepts one attachment (Phoenix / Detonator / PowerCore)."
        end

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -140, 0, 34)  -- leaves room for the icon on the right
        title.Position = UDim2.new(0, 16, 0, 14)
        title.BackgroundTransparency = 1
        title.RichText = true
        if rarity and TempTowers.RarityColors and TempTowers.RarityColors[rarity] then
            local c = TempTowers.RarityColors[rarity]
            local hex = string.format("#%02x%02x%02x",
                math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5))
            title.Text = string.format("<font color='%s'>%s</font>  <font color='#aaaaaa' size='14'>(%s)</font>",
                hex, displayName, rarity)
        else
            title.Text = displayName
        end
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 22
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = modal

        -- Tower picture: same icon builder used by the hotbar + picker,
        -- rendered at a larger size. Positioned top-right of the modal so
        -- the text (name + description) reads alongside rather than below
        -- a wide banner. Wrapped in a square Frame with subtle background
        -- so icons with transparent edges still read as a tile.
        local iconHolder = Instance.new("Frame")
        iconHolder.Size = UDim2.new(0, 96, 0, 96)
        iconHolder.Position = UDim2.new(1, -112, 0, 12)
        iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 36)
        iconHolder.BorderSizePixel = 0
        iconHolder.Parent = modal
        local ihc = Instance.new("UICorner")
        ihc.CornerRadius = UDim.new(0.12, 0); ihc.Parent = iconHolder
        do
            local towerDef = findTowerDefById(typ)
            if towerDef and towerDef.iconBuilder then
                towerDef.iconBuilder(iconHolder)
            end
        end

        local descLbl = Instance.new("TextLabel")
        descLbl.Size = UDim2.new(1, -140, 0, 66)  -- tighter width; icon occupies the right
        descLbl.Position = UDim2.new(0, 16, 0, 52)
        descLbl.BackgroundTransparency = 1
        descLbl.Text = desc
        descLbl.TextColor3 = Color3.fromRGB(200, 210, 225)
        descLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLbl.TextStrokeTransparency = 0.6
        descLbl.Font = Enum.Font.Gotham
        descLbl.TextSize = 14
        descLbl.TextWrapped = true
        descLbl.TextXAlignment = Enum.TextXAlignment.Left
        descLbl.TextYAlignment = Enum.TextYAlignment.Top
        descLbl.Parent = modal

        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1, -32, 1, -196)
        scroll.Position = UDim2.new(0, 16, 0, 124)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 6
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.Parent = modal
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.Padding = UDim.new(0, 4)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = scroll

        local order = 0
        local function addLine(label, value, color)
            order = order + 1
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, 0, 0, 20)
            l.BackgroundTransparency = 1
            l.RichText = true
            if label then
                l.Text = string.format("<b>%s:</b> %s", label, tostring(value))
            else
                l.Text = tostring(value)
            end
            l.TextColor3 = color or Color3.fromRGB(230, 235, 245)
            l.Font = Enum.Font.Gotham
            l.TextSize = 14
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.LayoutOrder = order
            l.Parent = scroll
        end
        local function addSection(text)
            order = order + 1
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, 0, 0, 22)
            l.BackgroundTransparency = 1
            l.Text = text
            l.TextColor3 = Color3.fromRGB(180, 200, 230)
            l.Font = Enum.Font.GothamBold
            l.TextSize = 13
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.LayoutOrder = order
            l.Parent = scroll
        end

        addSection("STATS")
        -- Stat format: "base (modified)". The modified (post-bonus) value
        -- sits in parens — base number stays visible so the player sees
        -- where the tower started before upgrades. BONUS_GREEN tint on the
        -- parens to make upgrades read at a glance. No parens if unchanged.
        local BONUS_GREEN = "#82e06c"
        local function baseModLine(label, base, total, suffix, fmt)
            fmt = fmt or "%d"
            suffix = suffix or ""
            if math.abs(total - base) < 0.01 then
                addLine(label, string.format(fmt .. suffix, base))
            else
                addLine(label, string.format(
                    "%s%s  <font color='%s'>(%s%s)</font>",
                    string.format(fmt, base), suffix,
                    BONUS_GREEN,
                    string.format(fmt, total), suffix))
            end
        end

        local dmg = tower:GetAttribute("Damage") or 0
        local dmgBase = tower:GetAttribute("DamageBase") or dmg
        baseModLine("Damage", dmgBase, dmg)
        local rng = tower:GetAttribute("Range") or 0
        local rngBase = tower:GetAttribute("RangeBase") or rng
        baseModLine("Range", rngBase, rng)
        local fr = tower:GetAttribute("FireRate") or 0
        local frBase = tower:GetAttribute("FireRateBase") or fr
        baseModLine("Fire Rate", frBase, fr, " /sec", "%.2f")

        -- Max DPS labeled "(modified)" — uses the tower's live Damage + FireRate
        -- (post-upgrade), so it already reflects all bonuses. The HUD's main
        -- DPS line shows actual lifetime average; this is the theoretical ceiling.
        addLine("Max DPS (modified)", string.format("%.1f", dmg * fr))

        -- (Ammo Capacity row removed — ammo system retired.)

        local hasSpecial = false
        local function ensureSpecialSection()
            if not hasSpecial then addSection("SPECIAL EFFECTS"); hasSpecial = true end
        end
        local aoe = tower:GetAttribute("AoeRadius")
        if aoe and aoe > 0 then
            ensureSpecialSection()
            addLine("AOE radius", string.format("%d studs", math.floor(aoe + 0.5)))
        end
        local stunDur = tower:GetAttribute("StunDuration")
        if stunDur and stunDur > 0 then
            ensureSpecialSection()
            local stunPct = math.floor((tower:GetAttribute("StunChance") or 0.05) * 100 + 0.5)
            addLine("Stun", string.format("%.1fs on %d%% of hits", stunDur, stunPct))
        end
        local knock = tower:GetAttribute("Knockback")
        if knock and knock > 0 then
            ensureSpecialSection()
            local kbPct = math.floor((tower:GetAttribute("KnockbackChance") or 0.05) * 100 + 0.5)
            addLine("Knockback", string.format("%d studs on %d%% of hits", math.floor(knock + 0.5), kbPct))
        end
        -- Attachment row: Core-only (aux towers can't equip attachments —
        -- they have their own mechanic baked in via the template). Skip
        -- the whole row for aux so the SPECIAL EFFECTS section doesn't
        -- open just to show one misleading Attachment line.
        if not tpl then
            local equipType = tower:GetAttribute("EquippedType") or ""
            local equipRar = tower:GetAttribute("EquippedRarity")
            if equipType ~= "" and equipRar then
                ensureSpecialSection()
                addLine("Attachment", string.format("%s (%s)", equipType, RARITY_NAMES[equipRar] or "?"))
            end
        end

        if tpl then
            -- Aux-specific secondary stats read directly off the template
            -- (same values the tower spawned with, no per-tower mutation).
            local fields = {
                {"slowPct", "Slow", "pct"},
                {"slowSeconds", "Slow duration", "sec"},
                {"stunSeconds", "Stun duration", "sec"},
                {"stunCooldown", "Stun cooldown", "sec"},
                {"aoeRadius", "AOE radius", "studs"},
                {"splashRadius", "Splash radius", "studs"},
                {"blastRadius", "Blast radius", "studs"},
                {"patchRadius", "Patch radius", "studs"},
                {"patchSeconds", "Patch duration", "sec"},
                {"patchSlowPct", "Patch slow", "pct"},
                {"patchTickDmg", "Patch tick dmg", "dmg"},
                {"patchTickPerSec", "Patch ticks/sec", "count"},
                {"cloudRadius", "Cloud radius", "studs"},
                {"cloudSeconds", "Cloud duration", "sec"},
                {"cloudTickDmg", "Cloud tick dmg", "dmg"},
                {"cloudTickPerSec", "Cloud ticks/sec", "count"},
                {"chainJumps", "Chain jumps", "count"},
                {"chainRange", "Chain range", "studs"},
                {"chainFalloff", "Chain falloff", "pct"},
                {"pierceCount", "Pierce", "count"},
                {"lobSeconds", "Lob time", "sec"},
            }
            local auxSection = false
            for _, f in ipairs(fields) do
                local v = tpl[f[1]]
                if v ~= nil then
                    if not auxSection then addSection("MECHANIC"); auxSection = true end
                    local valStr
                    if f[3] == "pct" then
                        valStr = string.format("%d%%", math.floor(v * 100 + 0.5))
                    elseif f[3] == "sec" then
                        valStr = string.format("%.1fs", v)
                    elseif f[3] == "count" then
                        valStr = tostring(math.floor(v + 0.5))
                    else
                        valStr = string.format("%d %s", math.floor(v + 0.5), f[3])
                    end
                    addLine(f[2], valStr)
                end
            end
        end

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -32, 0, 44)
        btn.Position = UDim2.new(0, 16, 1, -60)
        btn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = "CLOSE"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 18
        btn.Parent = modal
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0.2, 0); bc.Parent = btn
        btn.MouseButton1Click:Connect(closeTowerCard)
    end

    infoBtn.MouseButton1Click:Connect(function()
        if currentTargetTower and currentTargetTower.Parent then
            openTowerCard(currentTargetTower)
        end
    end)
end

------------------------------------------------------------
-- REROLL BUTTON in the upgrade picker
------------------------------------------------------------
-- We hook into the existing ShowUpgrades handler by adding a button to the
-- modal. The picker is rebuilt each time ShowUpgrades fires, so we add the
-- button there. To minimize edits, we listen for ShowUpgrades AGAIN here and
-- attach a reroll button after the picker exists.
local rerollRemote = ReplicatedStorage:WaitForChild(Remotes.Names.RerollUpgrades)

ReplicatedStorage:WaitForChild(Remotes.Names.ShowUpgrades).OnClientEvent:Connect(function(payload)
    -- The main picker handler already built the UI. Defer one frame so it
    -- exists, then add the reroll button.
    task.defer(function()
        local picker = playerGui:FindFirstChild("ToL_UpgradePicker")
        if not picker then return end
        if picker:FindFirstChild("RerollButton") then return end  -- already added

        local rerollsRemaining = payload.rerollsRemaining or 0
        local tokenCount = player:GetAttribute("RerollTokens") or 0

        -- Free-reroll button (left): the per-stage freebie.
        local btn = Instance.new("TextButton")
        btn.Name = "RerollButton"
        btn.Size = UDim2.new(0, 200, 0, 44)
        btn.Position = UDim2.new(0.5, -210, 1, -64)
        btn.BackgroundColor3 = (rerollsRemaining > 0)
            and Color3.fromRGB(120, 90, 200)
            or Color3.fromRGB(60, 60, 70)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = (rerollsRemaining > 0)
            and string.format("REROLL (%d left)", rerollsRemaining)
            or "REROLL USED"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 18
        btn.Parent = picker
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0.3, 0)
        bc.Parent = btn

        btn.MouseButton1Click:Connect(function()
            if rerollsRemaining <= 0 then return end
            rerollRemote:FireServer(payload.wave or 1, false)
        end)

        -- Token-reroll button (right): consumes a persistent RerollToken.
        -- Earned from stage-boss clears. Separate button (not a fallback)
        -- so the player chooses consciously whether to spend a token vs
        -- burn the freebie.
        local tokenBtn = Instance.new("TextButton")
        tokenBtn.Name = "RerollTokenButton"
        tokenBtn.Size = UDim2.new(0, 200, 0, 44)
        tokenBtn.Position = UDim2.new(0.5, 10, 1, -64)
        tokenBtn.BackgroundColor3 = (tokenCount > 0)
            and Color3.fromRGB(200, 140, 60)
            or Color3.fromRGB(60, 60, 70)
        tokenBtn.BorderSizePixel = 0
        tokenBtn.AutoButtonColor = false
        tokenBtn.Text = (tokenCount > 0)
            and string.format("USE TOKEN (%d left)", tokenCount)
            or "NO TOKENS"
        tokenBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        tokenBtn.Font = Enum.Font.FredokaOne
        tokenBtn.TextSize = 18
        tokenBtn.Parent = picker
        local tbc = Instance.new("UICorner")
        tbc.CornerRadius = UDim.new(0.3, 0)
        tbc.Parent = tokenBtn

        tokenBtn.MouseButton1Click:Connect(function()
            if tokenCount <= 0 then return end
            rerollRemote:FireServer(payload.wave or 1, true)
        end)
    end)
end)

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
