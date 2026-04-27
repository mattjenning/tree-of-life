--[[
    InfiniteLoadoutPicker.lua — PC-only modal for picking the run's
    aux towers + difficulty before entering the Pickle Swamp.

    Per Matthew 2026-04-27 spec (project_infinite_arena.md):
      - Slider on bottom: 0-4 aux count. ALSO controls starting difficulty
        (slider value × per-step HP multiplier on RunDifficultyMult).
      - Top: tower grid. All aux grayed by default; click to toggle.
        Can select up to the slider's count; clicking a 5th deselects
        the oldest selection.
      - Each tower shows name + role tag (DPS / Control / Support tinted).
      - START commits → fires PickInfiniteScenario with payload
          { auxIds = [...], slider = N }
        which the server's Infinite.setup pickRemote handler reads
        to grant only the selected towers' stock + bump difficulty.
      - CANCEL closes without entering.

    setup(deps):
      deps.player, deps.playerGui, deps.ReplicatedStorage,
      deps.Remotes, deps.TempTowers
]]

local InfiniteLoadoutPicker = {}

local ROLE_COLORS = {
    DPS     = Color3.fromRGB(220, 90, 90),
    Control = Color3.fromRGB(180, 100, 230),
    Support = Color3.fromRGB(80, 180, 240),
}

-- Display order for the aux-tower grid. 3x3 grid (9 towers fit
-- exactly). Sorted DPS-first then Control so role coloring clusters
-- visually — top two rows + first cell of row 3 are DPS, bottom two
-- cells of row 3 + the last row are Control. Adjust when more towers
-- land. Source of truth is TempTowers.RoleByTowerId; this just
-- imposes a stable presentation order.
local AUX_DISPLAY_ORDER = {
    -- Row 1 (DPS)
    "AcornSniper",     "LightningRadish", "MushroomMortar",
    -- Row 2 (DPS / DPS / Control boundary)
    "PepperCannon",    "ThornVine",       "FrostMelon",
    -- Row 3 (Control)
    "HoneyHive",       "RootSprout",      "SporePuffball",
    -- Future Support towers will require expanding to 4×3 (12 cells)
    -- or 3×4 — adjust GRID_COLS / GRID_ROWS below + repad cells.
}
local GRID_COLS = 3
local GRID_ROWS = 3

function InfiniteLoadoutPicker.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local TempTowers        = deps.TempTowers

    local showRemote = ReplicatedStorage:WaitForChild(Remotes.Names.ShowInfiniteScenarioPicker)
    local pickRemote = ReplicatedStorage:WaitForChild(Remotes.Names.PickInfiniteScenario)

    -- Modal-state count: HUD + button-bar hide when this is > 0.
    -- Picker open = +1, close = -1. Admin panel does the same.
    -- Counter pattern survives overlapping modals.
    local function bumpModalCount(delta)
        local cur = playerGui:GetAttribute("InfiniteModalCount") or 0
        playerGui:SetAttribute("InfiniteModalCount", math.max(0, cur + delta))
    end

    local function close(gui)
        if gui and gui.Parent then
            gui:Destroy()
            bumpModalCount(-1)
        end
    end

    local function build()
        -- Tear down any previous picker first so re-touching the
        -- portal / re-pressing F doesn't stack modals. If we destroy
        -- an open picker here, decrement the modal count first so
        -- the count stays balanced.
        local existing = playerGui:FindFirstChild("ToL_InfiniteLoadoutPicker")
        if existing then
            existing:Destroy()
            bumpModalCount(-1)
        end
        bumpModalCount(1)

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_InfiniteLoadoutPicker"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 60
        gui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.35
        dim.BorderSizePixel = 0
        dim.Parent = gui

        local panel = Instance.new("Frame")
        panel.AnchorPoint = Vector2.new(0.5, 0.5)
        panel.Position = UDim2.fromScale(0.5, 0.5)
        panel.Size = UDim2.fromOffset(640, 610)
        panel.BackgroundColor3 = Color3.fromRGB(20, 28, 22)
        panel.BorderSizePixel = 0
        panel.Parent = gui
        do
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 14)
            corner.Parent = panel
            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(120, 220, 140)
            stroke.Thickness = 2.5
            stroke.Parent = panel
        end

        -- Title + subtitle
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -32, 0, 38)
        title.Position = UDim2.fromOffset(16, 14)
        title.BackgroundTransparency = 1
        title.Text = "PICKLE SWAMP — LOADOUT"
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 26
        title.TextColor3 = Color3.fromRGB(180, 255, 200)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = panel

        local subtitle = Instance.new("TextLabel")
        subtitle.Size = UDim2.new(1, -32, 0, 22)
        subtitle.Position = UDim2.fromOffset(16, 50)
        subtitle.BackgroundTransparency = 1
        subtitle.Text = "Slider sets aux-tower count AND starting difficulty. "
                     .. "Click towers below to fill your slots."
        subtitle.Font = Enum.Font.Gotham
        subtitle.TextSize = 13
        subtitle.TextColor3 = Color3.fromRGB(180, 200, 180)
        subtitle.TextXAlignment = Enum.TextXAlignment.Left
        subtitle.Parent = panel

        -- ── Tower grid (3x3) ──────────────────────────────────────
        -- Cell math (panel is 640 wide, 32 padding total):
        --   inner width   = 608
        --   3 cols × cell + 2 gaps × pad = 608
        --   pad = 14, cell = (608 - 28) / 3 = 193.3 → round to 192
        --   3 rows × 110 + 2 × 14 = 358 → grid height
        local CELL_W, CELL_H = 192, 110
        local CELL_PAD = 14
        local GRID_W = GRID_COLS * CELL_W + (GRID_COLS - 1) * CELL_PAD
        local GRID_H = GRID_ROWS * CELL_H + (GRID_ROWS - 1) * CELL_PAD

        local grid = Instance.new("Frame")
        grid.AnchorPoint = Vector2.new(0.5, 0)
        grid.Position = UDim2.new(0.5, 0, 0, 84)
        grid.Size = UDim2.fromOffset(GRID_W, GRID_H)
        grid.BackgroundTransparency = 1
        grid.Parent = panel
        do
            local layout = Instance.new("UIGridLayout")
            layout.CellSize = UDim2.fromOffset(CELL_W, CELL_H)
            layout.CellPadding = UDim2.fromOffset(CELL_PAD, CELL_PAD)
            layout.FillDirection = Enum.FillDirection.Horizontal
            layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            layout.VerticalAlignment = Enum.VerticalAlignment.Top
            layout.SortOrder = Enum.SortOrder.LayoutOrder
            layout.Parent = grid
        end

        -- Selection state. selected[towerId] = true when picked. Order
        -- list tracks oldest-first so a 5th click can deselect the
        -- oldest (FIFO eviction) when slider count is at cap.
        local selected = {}     -- { [towerId] = true }
        local selectedOrder = {}  -- ordered list of towerIds

        local towerButtons = {}  -- { [towerId] = TextButton }
        local sliderValue = 3    -- default: 3 aux + 1 Core = full loadout

        local function updateButtonAppearance(towerId)
            local btn = towerButtons[towerId]
            if not btn then return end
            local isSelected = selected[towerId] == true
            local stroke = btn:FindFirstChildOfClass("UIStroke")
            if isSelected then
                btn.BackgroundColor3 = Color3.fromRGB(60, 80, 60)
                if stroke then
                    stroke.Thickness = 3
                    stroke.Transparency = 0
                end
            else
                btn.BackgroundColor3 = Color3.fromRGB(36, 42, 36)
                if stroke then
                    stroke.Thickness = 1.5
                    stroke.Transparency = 0.6
                end
            end
        end

        local function evictOldestIfOverCap()
            while #selectedOrder > sliderValue do
                local oldest = table.remove(selectedOrder, 1)
                selected[oldest] = nil
                updateButtonAppearance(oldest)
            end
        end

        local function toggleTower(towerId)
            if selected[towerId] then
                -- Deselect.
                selected[towerId] = nil
                for i, id in ipairs(selectedOrder) do
                    if id == towerId then
                        table.remove(selectedOrder, i)
                        break
                    end
                end
            else
                -- Select. If at cap, evict oldest.
                if sliderValue == 0 then return end  -- can't select with 0 slots
                selected[towerId] = true
                table.insert(selectedOrder, towerId)
                evictOldestIfOverCap()
            end
            updateButtonAppearance(towerId)
        end

        for layoutOrder, towerId in ipairs(AUX_DISPLAY_ORDER) do
            local tpl = TempTowers.Templates[towerId]
            if not tpl then continue end
            local role = TempTowers.RoleByTowerId[towerId] or "DPS"
            local btn = Instance.new("TextButton")
            btn.LayoutOrder = layoutOrder
            btn.AutoButtonColor = false
            btn.Text = ""
            btn.BackgroundColor3 = Color3.fromRGB(36, 42, 36)
            btn.BorderSizePixel = 0
            btn.Parent = grid
            do
                local corner = Instance.new("UICorner")
                corner.CornerRadius = UDim.new(0, 8)
                corner.Parent = btn
                local stroke = Instance.new("UIStroke")
                stroke.Color = ROLE_COLORS[role] or Color3.fromRGB(120, 120, 120)
                stroke.Thickness = 1.5
                stroke.Transparency = 0.6
                stroke.Parent = btn
            end
            -- Center-stack: name on top, role tag immediately below.
            -- Anchored at 0.5 / 0.5 so vertical centering is implicit
            -- — easier to balance than absolute offsets when the cell
            -- size changes. Name + tag share a 60-tall band centered
            -- on the cell.
            local nameLabel = Instance.new("TextLabel")
            nameLabel.AnchorPoint = Vector2.new(0.5, 1)
            nameLabel.Position = UDim2.new(0.5, 0, 0.5, 2)
            nameLabel.Size = UDim2.new(1, -16, 0, 28)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = tpl.displayName or towerId
            nameLabel.Font = Enum.Font.FredokaOne
            nameLabel.TextSize = 18
            nameLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
            nameLabel.TextXAlignment = Enum.TextXAlignment.Center
            nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
            nameLabel.Parent = btn
            local roleTag = Instance.new("TextLabel")
            roleTag.AnchorPoint = Vector2.new(0.5, 0)
            roleTag.Position = UDim2.new(0.5, 0, 0.5, 6)
            roleTag.Size = UDim2.new(1, -16, 0, 18)
            roleTag.BackgroundTransparency = 1
            roleTag.Text = role:upper()
            roleTag.Font = Enum.Font.GothamBold
            roleTag.TextSize = 13
            roleTag.TextColor3 = ROLE_COLORS[role] or Color3.fromRGB(180, 180, 180)
            roleTag.TextXAlignment = Enum.TextXAlignment.Center
            roleTag.Parent = btn
            towerButtons[towerId] = btn
            btn.Activated:Connect(function() toggleTower(towerId) end)
        end

        -- ── Slider ─────────────────────────────────────────────────
        -- Stepper-style slider: 5 button positions (0/1/2/3/4). Easier
        -- to hit than a true click-and-drag track and gives the
        -- discrete count semantics directly.
        -- Grid ends at y = 84 + GRID_H = 84 + 358 = 442. Slider sits
        -- below with 16px gap.
        local sliderLabel = Instance.new("TextLabel")
        sliderLabel.Size = UDim2.new(1, -32, 0, 22)
        sliderLabel.Position = UDim2.fromOffset(16, 460)
        sliderLabel.BackgroundTransparency = 1
        sliderLabel.Text = ""
        sliderLabel.Font = Enum.Font.GothamBold
        sliderLabel.TextSize = 14
        sliderLabel.TextColor3 = Color3.fromRGB(220, 230, 220)
        sliderLabel.TextXAlignment = Enum.TextXAlignment.Left
        sliderLabel.Parent = panel

        local sliderTrack = Instance.new("Frame")
        sliderTrack.Size = UDim2.new(1, -32, 0, 50)
        sliderTrack.Position = UDim2.fromOffset(16, 486)
        sliderTrack.BackgroundColor3 = Color3.fromRGB(28, 36, 30)
        sliderTrack.BorderSizePixel = 0
        sliderTrack.Parent = panel
        do
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 8)
            corner.Parent = sliderTrack
        end

        local sliderButtons = {}
        local function refreshSlider()
            sliderLabel.Text = string.format(
                "AUX SLOTS: %d   |   DIFFICULTY: %.2f×",
                sliderValue, 1.0 + sliderValue * 0.25)
            for v, b in pairs(sliderButtons) do
                if v == sliderValue then
                    b.BackgroundColor3 = Color3.fromRGB(120, 220, 140)
                    b.TextColor3 = Color3.fromRGB(20, 30, 22)
                else
                    b.BackgroundColor3 = Color3.fromRGB(50, 60, 52)
                    b.TextColor3 = Color3.fromRGB(220, 230, 220)
                end
            end
            evictOldestIfOverCap()
        end

        for v = 0, 4 do
            local b = Instance.new("TextButton")
            b.AnchorPoint = Vector2.new(0, 0.5)
            b.Size = UDim2.fromOffset(110, 36)
            b.Position = UDim2.new(0, 5 + v * 118, 0.5, 0)
            b.BackgroundColor3 = Color3.fromRGB(50, 60, 52)
            b.BorderSizePixel = 0
            b.AutoButtonColor = false
            b.Text = tostring(v)
            b.Font = Enum.Font.FredokaOne
            b.TextSize = 22
            b.TextColor3 = Color3.fromRGB(220, 230, 220)
            b.Parent = sliderTrack
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 6)
                c.Parent = b
            end
            sliderButtons[v] = b
            b.Activated:Connect(function()
                sliderValue = v
                refreshSlider()
            end)
        end
        refreshSlider()

        -- ── Buttons row (CANCEL + START) ───────────────────────────
        local startBtn = Instance.new("TextButton")
        startBtn.AnchorPoint = Vector2.new(1, 1)
        startBtn.Position = UDim2.new(1, -16, 1, -14)
        startBtn.Size = UDim2.fromOffset(180, 44)
        startBtn.BackgroundColor3 = Color3.fromRGB(80, 200, 110)
        startBtn.BorderSizePixel = 0
        startBtn.AutoButtonColor = false
        startBtn.Text = "START"
        startBtn.Font = Enum.Font.FredokaOne
        startBtn.TextSize = 22
        startBtn.TextColor3 = Color3.fromRGB(20, 30, 22)
        startBtn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = startBtn
        end

        local cancelBtn = Instance.new("TextButton")
        cancelBtn.AnchorPoint = Vector2.new(0, 1)
        cancelBtn.Position = UDim2.new(0, 16, 1, -14)
        cancelBtn.Size = UDim2.fromOffset(140, 44)
        cancelBtn.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
        cancelBtn.BorderSizePixel = 0
        cancelBtn.AutoButtonColor = false
        cancelBtn.Text = "CANCEL"
        cancelBtn.Font = Enum.Font.FredokaOne
        cancelBtn.TextSize = 18
        cancelBtn.TextColor3 = Color3.fromRGB(240, 200, 200)
        cancelBtn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = cancelBtn
        end
        cancelBtn.Activated:Connect(function() close(gui) end)

        startBtn.Activated:Connect(function()
            -- Build a stable list (display order) of the picked towers.
            local picked = {}
            for _, towerId in ipairs(AUX_DISPLAY_ORDER) do
                if selected[towerId] then
                    table.insert(picked, towerId)
                end
            end
            pickRemote:FireServer({
                auxIds   = picked,
                slider   = sliderValue,
            })
            close(gui)
        end)
    end

    showRemote.OnClientEvent:Connect(build)

    -- Public open() so the in-Infinite button bar can re-launch the
    -- picker without a remote round-trip. Same builder either way.
    InfiniteLoadoutPicker.open = build
end

return InfiniteLoadoutPicker
