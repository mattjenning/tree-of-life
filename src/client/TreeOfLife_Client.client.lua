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
local Remotes = require(Shared:WaitForChild("Remotes"))
local Tags    = require(Shared:WaitForChild("Tags"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

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
    local clickableAt = os.clock() + 1.0
    for _, def in ipairs(towerDefs) do
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
local placementMode = nil
local placementDef = nil
local ghostBase, ghostMid, ghostGem = nil, nil, nil
local currentAnchor = nil

local function clearGhost()
    if ghostBase then ghostBase:Destroy() end
    if ghostMid then ghostMid:Destroy() end
    if ghostGem then ghostGem:Destroy() end
    ghostBase, ghostMid, ghostGem = nil, nil, nil
end

local function buildGhost(def)
    clearGhost()
    local function make(shape, size, transparency)
        local p = Instance.new("Part")
        p.Shape = shape
        p.Size = size
        p.Anchored = true
        p.CanCollide = false
        p.CastShadow = false
        p.Transparency = transparency
        p.Material = Enum.Material.Neon
        p.Color = Color3.fromRGB(120, 255, 150)
        p.CFrame = CFrame.new(0, -10000, 0)
        p.Parent = workspace
        return p
    end
    -- Wide base disc and tall cylinder column with gem on top, matching the
    -- starter tower's silhouette but simpler.
    ghostBase = make(Enum.PartType.Cylinder, Vector3.new(3, 7.5, 7.5), 0.4)
    ghostMid  = make(Enum.PartType.Cylinder, Vector3.new(14, 5, 5), 0.4)
    ghostGem  = make(Enum.PartType.Ball,     Vector3.new(4.5, 4.5, 4.5), 0.25)
end

local function updateGhostPosition(anchor, valid, def)
    if not ghostBase or not anchor then
        if ghostBase then ghostBase.CFrame = CFrame.new(0, -10000, 0) end
        if ghostMid then ghostMid.CFrame = CFrame.new(0, -10000, 0) end
        if ghostGem then ghostGem.CFrame = CFrame.new(0, -10000, 0) end
        return
    end
    local fw, fd = def.footprint[1], def.footprint[2]
    local centerCol = anchor[1] + (fw - 1) / 2
    local centerRow = anchor[2] + (fd - 1) / 2
    -- cellCenterWorld dispatches on which map the anchor belongs to — since
    -- canPlaceAt rejects mixed-map footprints, anchor[1] is guaranteed to
    -- be on the same map as centerCol. Ghost lands on map 1 (Y≈1) or map 2
    -- (Y≈501) correctly.
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
    local tint = valid and Color3.fromRGB(120, 255, 150) or Color3.fromRGB(255, 80, 80)
    -- Base disc: centered at Y=2.5, extends Y=1 to Y=4 (3 studs tall)
    ghostBase.CFrame = CFrame.new(top + Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
    ghostBase.Color = tint
    -- Column: centered at Y=11, extends Y=4 to Y=18 (14 studs tall, no gap above base)
    ghostMid.CFrame = CFrame.new(top + Vector3.new(0, 11, 0)) * CFrame.Angles(0, 0, math.rad(90))
    ghostMid.Color = tint
    -- Gem: centered at Y=20 (just above column top)
    ghostGem.CFrame = CFrame.new(top + Vector3.new(0, 20, 0))
    ghostGem.Color = tint
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
        exitPlacementMode()
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

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if placementMode and input.UserInputType == Enum.UserInputType.MouseButton1 and not IS_MOBILE then
        if currentAnchor then
            local fw, fd = placementDef.footprint[1], placementDef.footprint[2]
            if isAnchorValid(currentAnchor[1], currentAnchor[2], fw, fd) then
                ReplicatedStorage:WaitForChild(Remotes.Names.PlaceTower):FireServer(
                    placementMode, currentAnchor[1], currentAnchor[2])
                exitPlacementMode()
            end
        end
        return
    end
    if placementMode and input.KeyCode == Enum.KeyCode.Escape then
        exitPlacementMode()
        return
    end
    for _, def in ipairs(towerDefs) do
        if input.KeyCode == def.hotkeyCode then
            local stock = player:GetAttribute(def.id .. "Stock") or 0
            if stock > 0 then
                if placementMode == def.id then
                    exitPlacementMode()
                else
                    enterPlacementMode(def)
                end
            end
            return
        end
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
    local shown = {}
    for _, def in ipairs(towerDefs) do
        local stock = player:GetAttribute(def.id .. "Stock") or 0
        if stock > 0 then table.insert(shown, def) end
    end
    if #shown == 0 then return end

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

    for _, def in ipairs(shown) do
        local slot = Instance.new("TextButton")
        slot.Size = UDim2.new(0, slotSize, 0, slotSize)
        slot.BackgroundColor3 = def.color
        slot.BorderSizePixel = 0
        slot.AutoButtonColor = false
        slot.Text = ""
        slot.Parent = bar
        round(slot, 0.1)
        local iconBg = Instance.new("Frame")
        iconBg.Size = UDim2.new(1, -8, 1, -8)
        iconBg.Position = UDim2.new(0, 4, 0, 4)
        iconBg.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconBg.BorderSizePixel = 0
        iconBg.Parent = slot
        round(iconBg, 0.08)
        def.iconBuilder(iconBg)
        local keyLabel = Instance.new("TextLabel")
        keyLabel.Size = UDim2.new(0, 20, 0, 20)
        keyLabel.Position = UDim2.new(0, 3, 0, 3)
        keyLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        keyLabel.BackgroundTransparency = 0.2
        keyLabel.BorderSizePixel = 0
        keyLabel.Text = def.hotkey
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

local function fireReset(btn)
    gameLost = false  -- unlock wave HUD; new game starts fresh
    ReplicatedStorage:WaitForChild(Remotes.Names.DevReset):FireServer()
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

        -- Header button: "▶ TITLE" when collapsed, "▼ TITLE" when open
        local header = Instance.new("TextButton")
        header.Size = UDim2.new(1, 0, 0, 30)
        header.LayoutOrder = 1
        header.BackgroundColor3 = Color3.fromRGB(45, 50, 68)
        header.BackgroundTransparency = 0.1
        header.BorderSizePixel = 0
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
        header.MouseButton1Click:Connect(function()
            expandedState = not expandedState
            contents.Visible = expandedState
            header.Text = (expandedState and "▼ " or "▶ ") .. title
        end)

        return contents
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

    -- PROGRESS category (most-used; starts expanded)
    local progressCat = makeCategory("PROGRESS", true)
    local resetBtn = makeBtn(progressCat, 1, "RESET",     Color3.fromRGB(180,  60,  60))
    local skipBtn  = makeBtn(progressCat, 2, "SKIP WAVE", Color3.fromRGB( 60, 120, 180))
    local bossBtn  = makeBtn(progressCat, 3, "BOSS",      Color3.fromRGB(140,  40, 160))

    -- DEV TOOLS category (cheats/modifiers)
    local toolsCat = makeCategory("DEV TOOLS", false)
    local ammoBtn    = makeBtn(toolsCat, 1, "UNLIMITED AMMO: ON", Color3.fromRGB( 60, 160,  90))
    local stunBtn    = makeBtn(toolsCat, 2, "ADD STUN",           Color3.fromRGB(220, 200,  60))
    local resetCdBtn = makeBtn(toolsCat, 3, "RESET COOLDOWNS",    Color3.fromRGB( 80, 180, 180))

    -- TELEPORT category (NEW) — jump to different maps and start waves
    local teleportCat = makeCategory("TELEPORT", false)
    local tpHubBtn   = makeBtn(teleportCat, 1, "HUB",              Color3.fromRGB( 90, 140,  80))
    local tpMap1Btn  = makeBtn(teleportCat, 2, "MAP 1 (CROOK)",    Color3.fromRGB(140, 110,  70))
    local tpMap2Btn  = makeBtn(teleportCat, 3, "MAP 2 (CLIMBING)", Color3.fromRGB(110, 140, 160))

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

    resetBtn.MouseButton1Click:Connect(function()
        fireReset(resetBtn)
        setExpanded(false)
    end)

    skipBtn.MouseButton1Click:Connect(function()
        local skipRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSkipWave)
        if skipRemote then
            skipRemote:FireServer()
            skipBtn.Text = "SKIPPING..."
            task.delay(0.4, function()
                if skipBtn.Parent then skipBtn.Text = "SKIP WAVE" end
            end)
        end
    end)

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

    -- Teleport: HUB / MAP 1 / MAP 2. Collapses the panel after tap so the
    -- player doesn't have it in their face while they look around.
    local function fireTeleport(target, btn, origLabel)
        local remote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevTeleport)
        if not remote then
            btn.Text = "NO REMOTE"
            task.delay(0.8, function() if btn.Parent then btn.Text = origLabel end end)
            return
        end
        remote:FireServer(target)
        btn.Text = "TELEPORTING..."
        setExpanded(false)
        task.delay(0.6, function()
            if btn.Parent then btn.Text = origLabel end
        end)
    end
    tpHubBtn.MouseButton1Click:Connect(function()
        fireTeleport("hub", tpHubBtn, "HUB")
    end)
    tpMap1Btn.MouseButton1Click:Connect(function()
        fireTeleport("map1", tpMap1Btn, "MAP 1 (CROOK)")
    end)
    tpMap2Btn.MouseButton1Click:Connect(function()
        fireTeleport("map2", tpMap2Btn, "MAP 2 (CLIMBING)")
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
        closeBtn.MouseButton1Click:Connect(function()
            if attachGui then attachGui:Destroy(); attachGui = nil end
            attachListFrame = nil
        end)

        -- Initial fetch
        local getRemote = ReplicatedStorage:WaitForChild(Remotes.Names.GetAttachments)
        local ok, payload = pcall(function() return getRemote:InvokeServer() end)
        if ok and payload then renderInventory(payload) end
    end

    attachBtn.MouseButton1Click:Connect(function()
        openAttachments()
        setExpanded(false)
    end)

    -- ADD STUN: fires the dev-only remote that adds a Stun stack to all
    -- of the player's owned towers. Mirrors the Stun upgrade card without
    -- waiting for the RNG to roll one. Updates the tower HUD live since
    -- the server changes the StunDuration attribute, which the HUD
    -- refreshes from on-attribute-changed signals.
    stunBtn.MouseButton1Click:Connect(function()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevAddStun)
        if r then r:FireServer() end
        setExpanded(false)
    end)

    -- BOSS: skip to current stage's boss with simulated upgrades. Server
    -- decides which boss based on StageState.currentStage and synthesizes
    -- the picks the player would have made up to this point with average
    -- luck (display 5 on the meter), filtered by the user's Range cap rule
    -- (don't pick Range over 60% bonus). Server then spawns the boss
    -- directly, skipping the wave-5 mob spawns.
    bossBtn.MouseButton1Click:Connect(function()
        local r = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSkipToBoss)
        if r then r:FireServer() end
        -- Intentionally NOT calling setExpanded(false) — keep the panel
        -- open so you can tap BOSS again for the next stage's boss after
        -- this one dies.
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
    local barWidth = (#SPEEDS * BTN_SIZE) + ((#SPEEDS - 1) * PADDING) + (PADDING * 2)
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

    local buttons = {}  -- speed → TextButton

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

    for i, spd in ipairs(SPEEDS) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE)
        btn.Position = UDim2.new(0, PADDING + (i - 1) * (BTN_SIZE + PADDING), 0, PADDING)
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
            -- Optimistic update: highlight immediately. Server will broadcast
            -- the actual confirmed value via GameSpeedChanged.
            refreshActive(spd)
        end)
    end

    refreshActive(1)  -- initial state matches server default

    -- Server pushes the canonical speed any time it changes (or on PlayerAdded).
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
local waveCorner = Instance.new("UICorner")
waveCorner.CornerRadius = UDim.new(0.18, 0)
waveCorner.Parent = waveFrame

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
local carryCorner = Instance.new("UICorner")
carryCorner.CornerRadius = UDim.new(0.18, 0)
carryCorner.Parent = carryFrame

local carryLabel = Instance.new("TextLabel")
carryLabel.Size = UDim2.fromScale(1, 1)
carryLabel.BackgroundTransparency = 1
carryLabel.Text = "AMMO"
carryLabel.TextColor3 = Color3.fromRGB(40, 20, 0)
carryLabel.Font = Enum.Font.FredokaOne
carryLabel.TextSize = 18
carryLabel.Parent = carryFrame

local function refreshCarryIndicator()
    local count = player:GetAttribute("CarryingAmmo") or 0
    -- Support the legacy boolean value just in case
    if type(count) == "boolean" then count = count and 1 or 0 end
    local maxCarry = player:GetAttribute("MaxCarry") or 10
    if count > 0 then
        carryLabel.Text = string.format("AMMO (%d/%d)", count, maxCarry)
        carryFrame.Visible = true
    else
        carryFrame.Visible = false
    end
end
player:GetAttributeChangedSignal("CarryingAmmo"):Connect(refreshCarryIndicator)
player:GetAttributeChangedSignal("MaxCarry"):Connect(refreshCarryIndicator)
refreshCarryIndicator()

-- Wave state updates from server. Handles live waves, between-waves, and the
-- "wave starting in N seconds" countdown that fires after the first tower is placed.
local currentWaveState = {wave = 0, totalWaves = 5, mobsAlive = 0, inProgress = false}
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

    for _, card in ipairs(cards) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, CARD_W, 0, CARD_H)
        btn.BackgroundColor3 = card.color or Color3.fromRGB(80, 80, 90)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.Parent = row
        local cornerUi = Instance.new("UICorner")
        cornerUi.CornerRadius = UDim.new(0.08, 0)
        cornerUi.Parent = btn

        -- Rarity label (top)
        local rarityLabel = Instance.new("TextLabel")
        rarityLabel.Size = UDim2.new(1, -16, 0, 32)
        rarityLabel.Position = UDim2.new(0, 8, 0, 12)
        rarityLabel.BackgroundTransparency = 1
        rarityLabel.Text = string.upper(card.rarity or "?")
        rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        rarityLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        rarityLabel.TextStrokeTransparency = 0.3
        rarityLabel.Font = Enum.Font.FredokaOne
        rarityLabel.TextSize = IS_MOBILE and 22 or 30
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
            gui:Destroy()
        end)
    end
end)

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
    sub.Size = UDim2.new(1, 0, 0, 40)
    sub.Position = UDim2.new(0, 0, 0.48, 0)
    sub.BackgroundTransparency = 1
    do
        local totalDefeated = payload.totalWavesDefeated or 0
        if isWin then
            if payload.defeatedFinalBoss then
                sub.Text = string.format("You defeated the Pickle Lord after %d waves!", totalDefeated)
            else
                sub.Text = string.format("You defended the Tree through %d waves", totalDefeated)
            end
        else
            if totalDefeated > 0 then
                sub.Text = string.format("You held out for %d waves before falling", totalDefeated)
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
    btn.Position = UDim2.new(0.5, -100, 0.58, 0)
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
        gui:Destroy()
    end)
end)

------------------------------------------------------------
-- Stage cleared modal (between stages 1→2 and 2→3)
-- Shows "Stage N Complete!" with a Continue button. Auto-advances
-- after the server-specified delay if the player ignores it.
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.StageCleared).OnClientEvent:Connect(function(payload)
    local old = playerGui:FindFirstChild("ToL_StageCleared")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_StageCleared"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 215  -- below GameOver (230) but above the wave HUD (225) hides — actually wave HUD should be visible during; bumping below
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(20, 50, 80)
    bg.BackgroundTransparency = 0.3
    bg.BorderSizePixel = 0
    bg.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 70)
    title.Position = UDim2.new(0, 0, 0.32, 0)
    title.BackgroundTransparency = 1
    title.Text = string.format("Stage %d Complete!", payload.stage or 1)
    title.TextColor3 = Color3.fromRGB(255, 255, 200)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.3
    title.Font = Enum.Font.FredokaOne
    title.TextSize = 56
    title.Parent = bg

    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, 0, 0, 36)
    sub.Position = UDim2.new(0, 0, 0.43, 0)
    sub.BackgroundTransparency = 1
    sub.Text = "The Tree heals. Stage " .. (payload.nextStage or 2) .. " awaits."
    sub.TextColor3 = Color3.fromRGB(220, 230, 240)
    sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    sub.TextStrokeTransparency = 0.4
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 20
    sub.Parent = bg

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 220, 0, 50)
    btn.Position = UDim2.new(0.5, -110, 0.55, 0)
    btn.BackgroundColor3 = Color3.fromRGB(80, 180, 120)
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Text = "CONTINUE"
    btn.TextColor3 = Color3.fromRGB(20, 30, 20)
    btn.Font = Enum.Font.FredokaOne
    btn.TextSize = 22
    btn.Parent = bg
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0.2, 0)
    c.Parent = btn

    -- Auto-advance countdown text below the button
    local autoLabel = Instance.new("TextLabel")
    autoLabel.Size = UDim2.new(1, 0, 0, 24)
    autoLabel.Position = UDim2.new(0, 0, 0.65, 0)
    autoLabel.BackgroundTransparency = 1
    autoLabel.TextColor3 = Color3.fromRGB(180, 200, 220)
    autoLabel.Font = Enum.Font.Gotham
    autoLabel.TextSize = 14
    autoLabel.Parent = bg

    local autoDelay = payload.autoContinueIn or 6
    local cancelled = false
    task.spawn(function()
        local remaining = autoDelay
        while remaining > 0 and not cancelled and gui.Parent do
            autoLabel.Text = string.format("Auto-continue in %d…", remaining)
            task.wait(1)
            remaining = remaining - 1
        end
    end)

    btn.MouseButton1Click:Connect(function()
        cancelled = true
        ReplicatedStorage:WaitForChild(Remotes.Names.StageContinue):FireServer()
        gui:Destroy()
    end)

    -- Auto-dismiss when the next wave starts (server fires WaveState updates)
    -- If we time out without the user clicking, server will auto-advance.
    task.delay(autoDelay + 0.5, function()
        if gui.Parent then gui:Destroy() end
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

local function showBossSuccessGlow(duration)
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

    -- "DOUBLE DAMAGE!" floating banner
    local banner = Instance.new("TextLabel")
    banner.Size = UDim2.new(1, 0, 0, 60)
    banner.Position = UDim2.new(0, 0, 0.18, 0)
    banner.BackgroundTransparency = 1
    banner.Text = "DOUBLE DAMAGE!"
    banner.TextColor3 = Color3.fromRGB(255, 220, 100)
    banner.TextStrokeColor3 = Color3.fromRGB(80, 0, 0)
    banner.TextStrokeTransparency = 0.2
    banner.Font = Enum.Font.FredokaOne
    banner.TextSize = 42
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

        btn.MouseButton1Click:Connect(function()
            if minigameDone then return end
            if not btn.Parent then return end
            tappedCount = tappedCount + 1
            -- Pop visual: fade + shrink
            local popInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TweenService:Create(btn, popInfo, {
                Size = UDim2.new(0, TARGET_SIZE * 1.3, 0, TARGET_SIZE * 1.3),
                BackgroundTransparency = 1,
            }):Play()
            TweenService:Create(ring, popInfo, {Transparency = 1}):Play()
            task.delay(0.3, function() if btn.Parent then btn:Destroy() end end)

            if tappedCount >= count then
                minigameDone = true
                -- All blobs tapped in time → fire success once
                ReplicatedStorage:WaitForChild(Remotes.Names.BossTargetTap):FireServer()
                showBossSuccessGlow(payload.bonusDuration or 5)
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
targetModeFrame.Position = UDim2.new(0.5, -220, 0, 90)
targetModeFrame.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
targetModeFrame.BackgroundTransparency = 0.08
targetModeFrame.BorderSizePixel = 0
targetModeFrame.Parent = targetModeGui
local tmCorner = Instance.new("UICorner")
tmCorner.CornerRadius = UDim.new(0.06, 0)
tmCorner.Parent = targetModeFrame

-- Title (left-leaning; X button lives in the right corner)
local hudTitle = Instance.new("TextLabel")
hudTitle.Size = UDim2.new(1, -56, 0, 30)
hudTitle.Position = UDim2.new(0, 16, 0, 8)
hudTitle.BackgroundTransparency = 1
hudTitle.Text = "TOWER"
hudTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
hudTitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
hudTitle.TextStrokeTransparency = 0.4
hudTitle.Font = Enum.Font.FredokaOne
hudTitle.TextSize = 20
hudTitle.TextXAlignment = Enum.TextXAlignment.Left
hudTitle.Parent = targetModeFrame

-- Thin divider under the title
local titleDivider = Instance.new("Frame")
titleDivider.Size = UDim2.new(1, -32, 0, 1)
titleDivider.Position = UDim2.new(0, 16, 0, 44)
titleDivider.BackgroundColor3 = Color3.fromRGB(60, 70, 88)
titleDivider.BackgroundTransparency = 0.4
titleDivider.BorderSizePixel = 0
titleDivider.Parent = targetModeFrame

-- Small X in the top-right corner (closes the HUD)
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 30, 0, 30)
closeBtn.Position = UDim2.new(1, -38, 0, 8)
closeBtn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
closeBtn.BorderSizePixel = 0
closeBtn.AutoButtonColor = false
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
closeBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
closeBtn.TextStrokeTransparency = 0.4
closeBtn.Font = Enum.Font.FredokaOne
closeBtn.TextSize = 18
closeBtn.Parent = targetModeFrame
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0.3, 0)
closeCorner.Parent = closeBtn

-- Stats area (left column). Variable-height list: always shows Damage, Range,
-- Shots/sec, Ammo; optionally shows Attach, AOE, Stun, Knockback when present.
local statsFrame = Instance.new("Frame")
statsFrame.Size = UDim2.new(0, 240, 1, -66)
statsFrame.Position = UDim2.new(0, 16, 0, 56)
statsFrame.BackgroundTransparency = 1
statsFrame.Parent = targetModeFrame

local statsLayout = Instance.new("UIListLayout")
statsLayout.FillDirection = Enum.FillDirection.Vertical
statsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
statsLayout.Padding = UDim.new(0, 4)
statsLayout.Parent = statsFrame

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

local damageLabel    = makeStatLabel(1)
local rangeLabel     = makeStatLabel(2)
local fireRateLabel  = makeStatLabel(3)
local ammoLabel      = makeStatLabel(4)
local attachLabel    = makeStatLabel(5)
local aoeLabel       = makeStatLabel(6)
local stunLabel      = makeStatLabel(7)
local knockbackLabel = makeStatLabel(8)

-- Mode buttons column on the right. Four buttons × 38px + 3 × 8px padding = 162px.
-- Panel is 310 tall; title+divider+padding uses ~66px; bottom padding 16px leaves
-- 228px for the column — plenty.
local modeRow = Instance.new("Frame")
modeRow.Size = UDim2.new(0, 160, 0, 176)
modeRow.Position = UDim2.new(1, -176, 0, 56)
modeRow.BackgroundTransparency = 1
modeRow.Parent = targetModeFrame
local modeRowLayout = Instance.new("UIListLayout")
modeRowLayout.FillDirection = Enum.FillDirection.Vertical
modeRowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
modeRowLayout.VerticalAlignment = Enum.VerticalAlignment.Top
modeRowLayout.Padding = UDim.new(0, 8)
modeRowLayout.Parent = modeRow

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
    local base = tower:FindFirstChild("TowerBase")
    if not base then return end

    selectionFolder = Instance.new("Folder")
    selectionFolder.Name = "ToL_TowerSelection"
    selectionFolder.Parent = workspace

    local fw = tower:GetAttribute("FootprintW") or 4
    local fd = tower:GetAttribute("FootprintD") or 4
    local CELL = 2
    local halfX = (fw * CELL) / 2
    local halfZ = (fd * CELL) / 2
    local centerX = base.Position.X
    local centerZ = base.Position.Z
    -- Derive floor Y from the tower's own position so brackets sit on the
    -- correct floor for whichever map (Y≈1 on map 1, Y≈501 on map 2).
    local floorY = base.Position.Y + 0.05

    -- Four L-shaped corner brackets
    local bracketLen = 1.5
    local bracketThickness = 0.2
    local bracketColor = Color3.fromRGB(120, 255, 150)

    local function makeBar(x1, z1, x2, z2)
        local lenX = math.abs(x2 - x1)
        local lenZ = math.abs(z2 - z1)
        local p = Instance.new("Part")
        p.Anchored = true
        p.CanCollide = false
        p.CastShadow = false
        p.Material = Enum.Material.Neon
        p.Color = bracketColor
        p.Transparency = 0.1
        p.Size = Vector3.new(math.max(lenX, bracketThickness), 0.15, math.max(lenZ, bracketThickness))
        p.CFrame = CFrame.new((x1 + x2) / 2, floorY, (z1 + z2) / 2)
        p.Parent = selectionFolder
    end

    -- Corners (NW, NE, SW, SE) — each L is two short bars meeting at the corner
    local corners = {
        {centerX - halfX, centerZ - halfZ,  1,  1},  -- NW: extend into +X, +Z
        {centerX + halfX, centerZ - halfZ, -1,  1},  -- NE: extend into -X, +Z
        {centerX - halfX, centerZ + halfZ,  1, -1},  -- SW: extend into +X, -Z
        {centerX + halfX, centerZ + halfZ, -1, -1},  -- SE: extend into -X, -Z
    }
    for _, c in ipairs(corners) do
        local cx, cz, dx, dz = c[1], c[2], c[3], c[4]
        -- Bar along X axis from corner
        makeBar(cx, cz, cx + dx * bracketLen, cz)
        -- Bar along Z axis from corner
        makeBar(cx, cz, cx, cz + dz * bracketLen)
    end

    -- Range circle on the floor (a thin neon ring approximated by many segments).
    -- Cheaper alternative: a single big disc with a ring texture, but custom
    -- segments are simpler and don't need an asset.
    local range = tower:GetAttribute("Range") or 30
    local SEGMENTS = 48
    local segLen = (2 * math.pi * range) / SEGMENTS
    for i = 0, SEGMENTS - 1 do
        local a = (i / SEGMENTS) * 2 * math.pi
        local x = centerX + math.cos(a) * range
        local z = centerZ + math.sin(a) * range
        local seg = Instance.new("Part")
        seg.Size = Vector3.new(segLen + 0.1, 0.12, 0.35)
        seg.CFrame = CFrame.new(x, floorY, z) * CFrame.Angles(0, -a + math.pi / 2, 0)
        seg.Anchored = true
        seg.CanCollide = false
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
    hudTitle.Text = typ:upper() .. " TOWER"

    local damage    = tower:GetAttribute("Damage") or 0
    local range     = tower:GetAttribute("Range") or 0
    local fireRate  = tower:GetAttribute("FireRate") or 0
    local damageBonus   = tower:GetAttribute("DamageBonusPct") or 0
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

    damageLabel.Text   = statLine("Damage",    tostring(math.floor(damage + 0.5)),  damageBonus)
    rangeLabel.Text    = statLine("Range",     tostring(math.floor(range + 0.5)),   rangeBonus)
    fireRateLabel.Text = statLine("Shots/sec", string.format("%.2f", fireRate),     fireRateBonus)
    ammoLabel.Text     = string.format("Ammo: %d / %d", shots, maxShots)

    -- Attachment row: "Attach: Phoenix (Rare)" with the whole line colored by rarity.
    -- Hidden if no attachment equipped.
    if equipType ~= "" and equipRar and HUD_RARITY_NAMES[equipRar] then
        attachLabel.Visible = true
        local color = HUD_RARITY_COLORS[equipRar]
        local hex = string.format("#%02x%02x%02x",
            math.floor(color.R * 255 + 0.5),
            math.floor(color.G * 255 + 0.5),
            math.floor(color.B * 255 + 0.5))
        attachLabel.Text = string.format(
            'Attach: <b>%s</b> <font color="%s">(%s)</font>',
            equipType, hex, HUD_RARITY_NAMES[equipRar])
    else
        attachLabel.Visible = false
        attachLabel.Text = ""
    end

    if aoe and aoe > 0 then
        aoeLabel.Visible = true
        aoeLabel.Text = string.format("AOE: %d", math.floor(aoe + 0.5))
    else
        aoeLabel.Visible = false
        aoeLabel.Text = ""
    end
    -- Stun and Knockback both have a proc chance per shot (20% / 10%). The
    -- bracketed percent tells the player the listed value isn't applied on
    -- every hit — it's how big the effect is WHEN it procs.
    if stunDur and stunDur > 0 then
        stunLabel.Visible = true
        stunLabel.Text = string.format("Stun: %.1fs (20%%)", stunDur)
    else
        stunLabel.Visible = false
        stunLabel.Text = ""
    end
    if knockDist and knockDist > 0 then
        knockbackLabel.Visible = true
        knockbackLabel.Text = string.format("Knockback: +%d (10%%)", math.floor(knockDist + 0.5))
    else
        knockbackLabel.Visible = false
        knockbackLabel.Text = ""
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
            "DamageBonusPct", "RangeBonusPct", "FireRateBonusPct", -- bonus tags
            "EquippedType", "EquippedRarity",                      -- attachment row
            "StunDuration", "Knockback",                           -- conditional rows
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
    currentTargetTower = nil
    targetModeGui.Enabled = false
end

closeBtn.MouseButton1Click:Connect(closeTargetModeHUD)

-- Raycast helper: given a screen position, return any tower model under it
-- (ownership is irrelevant for inspecting; UI just shows stats).
local function towerUnderScreenPos(screenX, screenY)
    local ray = camera:ViewportPointToRay(screenX, screenY, 1)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = {player.Character, targetModeGui}
    local hit = workspace:Raycast(ray.Origin, ray.Direction * 300, rp)
    if not hit then return nil end
    local model = hit.Instance:FindFirstAncestorOfClass("Model")
    while model do
        if model:GetAttribute("TowerType") then
            return model
        end
        model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
    end
    return nil
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
       and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    if placementMode then return end

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
        local btn = Instance.new("TextButton")
        btn.Name = "RerollButton"
        btn.Size = UDim2.new(0, 200, 0, 44)
        btn.Position = UDim2.new(0.5, -100, 1, -64)
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
            rerollRemote:FireServer(payload.wave or 1)
            -- The server will fire ShowUpgrades again with a fresh card set
            -- (and an updated rerollsRemaining). The picker will be rebuilt.
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
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local t = towerBase.Parent
            if t and t:GetAttribute("Owner") == uid
                   and t:GetAttribute("EquippedType") == "Phoenix" then
                return t
            end
        end
        return nil
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
-- FALLING-LEAF NARRATIVE MESSAGE
-- Server fires LeafMessage with {text, duration}. We render the text
-- starting near the top-center of the screen, drift it downward with a
-- gentle horizontal sway, and fade out near the end. Doesn't block input.
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.LeafMessage).OnClientEvent:Connect(function(payload)
    local text = payload and payload.text or ""
    local duration = payload and payload.duration or 6
    if text == "" then return end

    -- Stack messages: if one is already up, just push it lower. Cheapest is
    -- to give each its own ScreenGui so they don't collide on cleanup.
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_LeafMsg"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 220
    gui.Parent = playerGui

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.8, 0, 0, 60)
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = UDim2.new(0.5, 0, 0.05, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 26
    label.TextColor3 = Color3.fromRGB(240, 250, 220)
    label.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
    label.TextStrokeTransparency = 0.2
    label.Text = text
    label.TextWrapped = true
    label.Parent = gui

    -- Drift downward + sway. Wallclock-based; simple math each Heartbeat.
    local startedAt = os.clock()
    local startY = 0.05    -- screen-relative
    local endY = 0.40
    local conn
    conn = RunService.Heartbeat:Connect(function()
        local elapsed = os.clock() - startedAt
        local t = math.clamp(elapsed / duration, 0, 1)
        local y = startY + (endY - startY) * t
        local sway = math.sin(elapsed * 1.8) * 0.04  -- subtle horizontal drift
        label.Position = UDim2.new(0.5 + sway, 0, y, 0)
        label.Rotation = math.sin(elapsed * 1.2) * 6  -- gentle leaf-tilt
        if t > 0.7 then
            -- Fade out over the last 30% of the duration
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
