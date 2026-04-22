-- TreeOfLife_Client.lua (v5.7.3)
-- Definitive fixes for the grid:
--   • Cells are now guaranteed square: SurfaceGui uses PixelsPerStud=10 so the canvas
--     is exactly (RoomWidth*10)x(RoomDepth*10) pixels with uniform pixel size.
--     Each cell renders as exactly 20x20 pixels = 2x2 studs.
--   • Highlight matches ghost position: SurfaceGui Top face has its UI Y axis
--     flipped relative to world Z, so cell (c, r) is placed at UI position
--     (c, GRID_ROWS-1-r) which inverts the row mapping correctly.
--   • Right-click cancel removed (kept from v5.7.2)
--
-- Why this works: when the floor's Top face is viewed from above looking straight down,
-- the world's +X direction reads as "right" and world's +Z reads as "down" in screen
-- terms. But the SurfaceGui's UI Y axis on Top face goes the OPPOSITE direction
-- of world +Z. So we flip rows when placing UI cells, which makes the visual highlight
-- land on the same physical floor cell that the world-space raycast resolved to.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local gridConfig = ReplicatedStorage:WaitForChild("GridConfig")
local CELL_SIZE    = gridConfig:WaitForChild("CellSize").Value
local GRID_COLS    = gridConfig:WaitForChild("GridCols").Value
local GRID_ROWS    = gridConfig:WaitForChild("GridRows").Value
local ROOM_CENTER_X = gridConfig:WaitForChild("RoomCenterX").Value
local ROOM_CENTER_Z = gridConfig:WaitForChild("RoomCenterZ").Value
local ROOM_WIDTH   = gridConfig:WaitForChild("RoomWidth").Value
local ROOM_DEPTH   = gridConfig:WaitForChild("RoomDepth").Value
local FLOOR_Y      = gridConfig:WaitForChild("FloorY").Value

local ROOM_MIN_X = ROOM_CENTER_X - ROOM_WIDTH/2
local ROOM_MIN_Z = ROOM_CENTER_Z - ROOM_DEPTH/2

local localGrid = {}
for c = 0, GRID_COLS - 1 do
    localGrid[c] = {}
    for r = 0, GRID_ROWS - 1 do
        localGrid[c][r] = "open"
    end
end

local TITLE       = "Tree of Life"
local SUBTITLE    = "Save the world from food gone bad"
local FADE_IN     = 0.9
local HOLD        = 2.1
local FADE_OUT    = 1.1

local TAG_CANOPY = "ToL_Canopy"
local WIND_STRENGTH = 1.0
local WIND_SPEED = 1.2

ReplicatedStorage:WaitForChild("EnterPortal").OnClientEvent:Connect(function()
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
for _, p in ipairs(CollectionService:GetTagged(TAG_CANOPY)) do registerPart(p) end
CollectionService:GetInstanceAddedSignal(TAG_CANOPY):Connect(registerPart)
CollectionService:GetInstanceRemovedSignal(TAG_CANOPY):Connect(function(p) swayParts[p] = nil end)

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
ReplicatedStorage:WaitForChild("ShowSplash").OnClientEvent:Connect(showSplash)

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
                ReplicatedStorage:WaitForChild("TowerPicked"):FireServer(capturedId)
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
ReplicatedStorage:WaitForChild("ShowTowerSelect").OnClientEvent:Connect(showTowerSelect)

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

local function buildGridParts()
    if gridFolder then return end
    local floor = findFloor()
    if not floor then return end

    gridFolder = Instance.new("Folder")
    gridFolder.Name = "ToL_GridParts"
    gridFolder.Parent = workspace

    for c = 0, GRID_COLS - 1 do
        gridCells[c] = {}
        for r = 0, GRID_ROWS - 1 do
            local worldX = ROOM_MIN_X + (c + 0.5) * CELL_SIZE
            local worldZ = ROOM_MIN_Z + (r + 0.5) * CELL_SIZE
            local cell = Instance.new("Part")
            cell.Name = ("Cell_%d_%d"):format(c, r)
            -- Visible cell is smaller than its grid slot, leaving a visible gap.
            -- Cells still occupy their full CELL_SIZE for placement math; only the
            -- rendered tile is shrunk for clarity.
            local CELL_GAP = 0.1  -- studs of empty space around each cell
            cell.Size = Vector3.new(CELL_SIZE - CELL_GAP, 0.05, CELL_SIZE - CELL_GAP)
            cell.CFrame = CFrame.new(worldX, FLOOR_Y + 0.025, worldZ)
            cell.Anchored = true
            cell.CanCollide = false
            cell.CastShadow = false
            cell.Material = Enum.Material.Neon
            cell.Color = Color3.fromRGB(60, 230, 120)
            cell.Transparency = 0.85
            cell.Parent = gridFolder
            gridCells[c][r] = cell
        end
    end
    gridFolder.Parent = nil  -- hide until shown
end

local function recolorGrid(highlightCells, validHighlight)
    if not gridFolder then return end
    -- Set base color/visibility for every cell based on state
    for c = 0, GRID_COLS - 1 do
        for r = 0, GRID_ROWS - 1 do
            local cell = gridCells[c] and gridCells[c][r]
            if cell then
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
        end
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

ReplicatedStorage:WaitForChild("GridUpdate").OnClientEvent:Connect(function(encoded)
    buildGridParts()
    local idx = 1
    for r = 0, GRID_ROWS - 1 do
        for c = 0, GRID_COLS - 1 do
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
    local worldX = ROOM_MIN_X + (centerCol + 0.5) * CELL_SIZE
    local worldZ = ROOM_MIN_Z + (centerRow + 0.5) * CELL_SIZE
    local top = Vector3.new(worldX, FLOOR_Y, worldZ)
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
    local floor = findFloor()
    if not floor then return nil end
    -- Include filter on floor only — grid Parts and ghost Parts cannot block the ray
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Include
    rp.FilterDescendantsInstances = {floor}
    local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 2000, rp)
    if not result then return nil end
    local hitX = result.Position.X
    local hitZ = result.Position.Z
    local col = math.floor((hitX - ROOM_MIN_X) / CELL_SIZE)
    local row = math.floor((hitZ - ROOM_MIN_Z) / CELL_SIZE)
    if col < 0 or col >= GRID_COLS or row < 0 or row >= GRID_ROWS then
        return nil
    end
    return col, row
end

local function hoveredToAnchor(hoverCol, hoverRow, fw, fd)
    -- Center the footprint on the hovered cell. For odd footprints (1x1, 3x3)
    -- the tap is exactly at the center cell. For even footprints (2x2), we shift
    -- so the tap falls on the top-left of the footprint, which reads better
    -- visually when the camera looks down at the floor at an angle.
    local ac = hoverCol - math.floor(fw / 2)
    local ar = hoverRow - math.floor((fd - 1) / 2)
    ac = math.max(0, math.min(GRID_COLS - fw, ac))
    ar = math.max(0, math.min(GRID_ROWS - fd, ar))
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
    for dc = 0, fw - 1 do
        for dr = 0, fd - 1 do
            local c = anchorCol + dc
            local r = anchorRow + dr
            if c < 0 or c >= GRID_COLS or r < 0 or r >= GRID_ROWS then return false end
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
        ReplicatedStorage:WaitForChild("PlaceTower"):FireServer(
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
    local floor = findFloor()
    if not floor then return nil end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Include
    rp.FilterDescendantsInstances = {floor}
    local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 2000, rp)
    if not result then return nil end
    local hitX = result.Position.X
    local hitZ = result.Position.Z
    local col = math.floor((hitX - ROOM_MIN_X) / CELL_SIZE)
    local row = math.floor((hitZ - ROOM_MIN_Z) / CELL_SIZE)
    if col < 0 or col >= GRID_COLS or row < 0 or row >= GRID_ROWS then return nil end
    return col, row
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
                ReplicatedStorage:WaitForChild("PlaceTower"):FireServer(
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

ReplicatedStorage:WaitForChild("ShowHotbar").OnClientEvent:Connect(function()
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

local function fireReset(btn)
    ReplicatedStorage:WaitForChild("DevReset"):FireServer()
    btn.Text = "RESETTING..."
    task.wait(0.5)
    btn.Text = "RESET"
end

if IS_MOBILE then
    -- Small "-" button in the corner; tap to expand the RESET button.
    local collapseBtn = Instance.new("TextButton")
    collapseBtn.Size = UDim2.new(0, 36, 0, 36)
    collapseBtn.Position = UDim2.new(0, 12, 1, -48)
    collapseBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 100)
    collapseBtn.BackgroundTransparency = 0.4
    collapseBtn.BorderSizePixel = 0
    collapseBtn.Text = "–"
    collapseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    collapseBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    collapseBtn.TextStrokeTransparency = 0.4
    collapseBtn.Font = Enum.Font.FredokaOne
    collapseBtn.TextSize = 28
    collapseBtn.AutoButtonColor = false
    collapseBtn.Parent = devGui
    local cc = Instance.new("UICorner")
    cc.CornerRadius = UDim.new(0.3, 0)
    cc.Parent = collapseBtn

    local resetBtn = Instance.new("TextButton")
    resetBtn.Size = UDim2.new(0, 110, 0, 36)
    resetBtn.Position = UDim2.new(0, 56, 1, -48)
    resetBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
    resetBtn.BackgroundTransparency = 0.1
    resetBtn.BorderSizePixel = 0
    resetBtn.Text = "RESET"
    resetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    resetBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    resetBtn.TextStrokeTransparency = 0.4
    resetBtn.Font = Enum.Font.FredokaOne
    resetBtn.TextSize = 18
    resetBtn.AutoButtonColor = false
    resetBtn.Visible = false
    resetBtn.Parent = devGui
    local rc = Instance.new("UICorner")
    rc.CornerRadius = UDim.new(0.2, 0)
    rc.Parent = resetBtn

    local expanded = false
    local autoCollapseToken = 0  -- cancels pending auto-collapse if re-expanded

    local function collapse()
        expanded = false
        resetBtn.Visible = false
        collapseBtn.Text = "–"
    end

    local function expand()
        expanded = true
        resetBtn.Visible = true
        collapseBtn.Text = "×"
        autoCollapseToken = autoCollapseToken + 1
        local myToken = autoCollapseToken
        task.delay(3, function()
            if autoCollapseToken == myToken and expanded then collapse() end
        end)
    end

    collapseBtn.MouseButton1Click:Connect(function()
        if expanded then collapse() else expand() end
    end)
    resetBtn.MouseButton1Click:Connect(function()
        fireReset(resetBtn)
        collapse()
    end)
else
    local devBtn = Instance.new("TextButton")
    devBtn.Size = UDim2.new(0, 110, 0, 36)
    devBtn.Position = UDim2.new(0, 12, 1, -48)
    devBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 100)
    devBtn.BackgroundTransparency = 0.2
    devBtn.BorderSizePixel = 0
    devBtn.Text = "RESET"
    devBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    devBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    devBtn.TextStrokeTransparency = 0.4
    devBtn.Font = Enum.Font.FredokaOne
    devBtn.TextSize = 18
    devBtn.AutoButtonColor = false
    devBtn.Parent = devGui
    local devCorner = Instance.new("UICorner")
    devCorner.CornerRadius = UDim.new(0.2, 0)
    devCorner.Parent = devBtn

    devBtn.MouseEnter:Connect(function()
        devBtn.BackgroundColor3 = Color3.fromRGB(110, 110, 140)
    end)
    devBtn.MouseLeave:Connect(function()
        devBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 100)
    end)
    devBtn.MouseButton1Click:Connect(function() fireReset(devBtn) end)
end

------------------------------------------------------------
-- WAVE UI: HUD + start button + upgrade picker + game over
------------------------------------------------------------

-- Wave HUD (top-center): shows wave X / Y and mobs alive
local waveGui = Instance.new("ScreenGui")
waveGui.Name = "ToL_WaveHUD"
waveGui.IgnoreGuiInset = false
waveGui.ResetOnSpawn = false
waveGui.DisplayOrder = 40
waveGui.Parent = playerGui

local waveFrame = Instance.new("Frame")
waveFrame.Size = UDim2.new(0, 240, 0, 40)
waveFrame.Position = UDim2.new(0.5, -120, 0, 12)
waveFrame.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
waveFrame.BackgroundTransparency = 0.25
waveFrame.BorderSizePixel = 0
waveFrame.Visible = false  -- hidden until first WaveState event arrives
waveFrame.Parent = waveGui
local waveCorner = Instance.new("UICorner")
waveCorner.CornerRadius = UDim.new(0.2, 0)
waveCorner.Parent = waveFrame

local waveLabel = Instance.new("TextLabel")
waveLabel.Size = UDim2.fromScale(1, 1)
waveLabel.BackgroundTransparency = 1
waveLabel.Text = ""
waveLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
waveLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
waveLabel.TextStrokeTransparency = 0.4
waveLabel.Font = Enum.Font.FredokaOne
waveLabel.TextSize = 18
waveLabel.Parent = waveFrame

-- Carrying-ammo indicator: shown below the wave HUD when the player is holding
-- an ammo package from a pile. Clears when they load it into a tower.
local carryFrame = Instance.new("Frame")
carryFrame.Size = UDim2.new(0, 200, 0, 32)
carryFrame.Position = UDim2.new(0.5, -100, 0, 60)
carryFrame.BackgroundColor3 = Color3.fromRGB(255, 180, 60)
carryFrame.BackgroundTransparency = 0.15
carryFrame.BorderSizePixel = 0
carryFrame.Visible = false
carryFrame.Parent = waveGui
local carryCorner = Instance.new("UICorner")
carryCorner.CornerRadius = UDim.new(0.3, 0)
carryCorner.Parent = carryFrame

local carryLabel = Instance.new("TextLabel")
carryLabel.Size = UDim2.fromScale(1, 1)
carryLabel.BackgroundTransparency = 1
carryLabel.Text = "CARRYING AMMO"
carryLabel.TextColor3 = Color3.fromRGB(40, 20, 0)
carryLabel.Font = Enum.Font.FredokaOne
carryLabel.TextSize = 14
carryLabel.Parent = carryFrame

local function refreshCarryIndicator()
    carryFrame.Visible = player:GetAttribute("CarryingAmmo") == true
end
player:GetAttributeChangedSignal("CarryingAmmo"):Connect(refreshCarryIndicator)
refreshCarryIndicator()

-- Wave state updates from server. Handles live waves, between-waves, and the
-- "wave starting in N seconds" countdown that fires after the first tower is placed.
local currentWaveState = {wave = 0, totalWaves = 3, mobsAlive = 0, inProgress = false}
local countdownToken = 0  -- cancels any in-progress countdown if a new state arrives

ReplicatedStorage:WaitForChild("WaveState").OnClientEvent:Connect(function(state)
    currentWaveState = state
    countdownToken = countdownToken + 1
    local myToken = countdownToken

    waveFrame.Visible = true

    if state.inProgress then
        waveLabel.Text = string.format("Wave %d / %d  •  Mobs: %d",
            state.wave, state.totalWaves, state.mobsAlive)
    elseif state.pendingCountdown and state.pendingCountdown > 0 then
        -- Show a live countdown ticking down each second
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
            -- No wave yet, no countdown active — keep HUD hidden
            waveFrame.Visible = false
        else
            waveLabel.Text = string.format("Wave %d cleared", state.wave)
        end
    end
end)

------------------------------------------------------------
-- Upgrade picker modal
------------------------------------------------------------
ReplicatedStorage:WaitForChild("ShowUpgrades").OnClientEvent:Connect(function(payload)
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
    title.Position = UDim2.new(0, 0, 0, IS_MOBILE and 8 or 16)
    title.BackgroundTransparency = 1
    title.Text = "Wave " .. (payload.wave or "?") .. " Cleared — Upgrade Your Tower"
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
    row.Position = UDim2.new(0, 0, 0, IS_MOBILE and 60 or 90)
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
            ReplicatedStorage:WaitForChild("UpgradePicked"):FireServer(card)
            gui:Destroy()
        end)
    end
end)

------------------------------------------------------------
-- Game over modal
------------------------------------------------------------
ReplicatedStorage:WaitForChild("GameOver").OnClientEvent:Connect(function(payload)
    local old = playerGui:FindFirstChild("ToL_GameOver")
    if old then old:Destroy() end
    -- Also tear down the upgrade picker if it's currently showing, so the
    -- "TAP TO CLAIM" cards don't sit underneath the game-over modal.
    local picker = playerGui:FindFirstChild("ToL_UpgradePicker")
    if picker then picker:Destroy() end

    local isWin = payload.result == "win"

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
    sub.Text = isWin
        and string.format("You defended the Tree through %d waves", payload.finalWave or 0)
        or string.format("Wave %d overwhelmed your defenses", payload.finalWave or 0)
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
        ReplicatedStorage:WaitForChild("DevReset"):FireServer()
        gui:Destroy()
    end)
end)

print("[TreeOfLife] Client v5.9.9 ready.")
