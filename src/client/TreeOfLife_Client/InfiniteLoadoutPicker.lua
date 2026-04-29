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

-- Module-level cache of the most recent committed loadout (SAVE or
-- GO). Read by the SIMULATE → SELECT AUTO menu so it can build a
-- sweep pinned to the player's current saved choice. Defaults to
-- DPS Core / no aux until the player commits a loadout this session.
-- The server still owns the canonical PreferredCoreId DataStore for
-- cross-session persistence; this is just the in-memory client
-- snapshot the SIMULATE menu reads synchronously.
local _lastSelection = {
    coreId = "Power",
    auxIds = {},
    slider = 3,
    rarity = "Common",  -- 2026-04-29 ea3-8 (loadout-picker rarity tier)
}

function InfiniteLoadoutPicker.getCurrentSelection()
    -- Returns a clone so callers can't mutate the cache.
    local out = {
        coreId = _lastSelection.coreId,
        slider = _lastSelection.slider,
        rarity = _lastSelection.rarity,
        auxIds = {},
    }
    for _, id in ipairs(_lastSelection.auxIds) do table.insert(out.auxIds, id) end
    return out
end

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
-- 2026-04-28: grid expanded 3×3 → 5×3 to fit 14 aux towers
-- (5 new in build cc: BlinkBerry / PaceFlower / PowerSeed /
-- SpyglassRoot / BloodlinkVine). 15 cells total, 14 used + 1
-- empty in the bottom-right. Cells shrunk 192→110 wide to fit
-- the wider grid in the same panel width.
local AUX_DISPLAY_ORDER = {
    -- Row 1 (DPS — single-target / chain / lob)
    "AcornSniper",     "LightningRadish", "MushroomMortar",  "PepperCannon",   "ThornVine",
    -- Row 2 (1 DPS + 4 Support)
    "SporePuffball",   "PaceFlower",      "PowerSeed",       "SpyglassRoot",   "BloodlinkVine",
    -- Row 3 (4 Control + 1 empty)
    "FrostMelon",      "HoneyHive",       "RootSprout",      "BlinkBerry",
}
local GRID_COLS = 5
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
        panel.Size = UDim2.fromOffset(640, 668)  -- expanded 610→668 to fit core archetype row
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
        subtitle.Text = "Pick a CORE archetype, then click towers to fill aux slots."
        subtitle.Font = Enum.Font.Gotham
        subtitle.TextSize = 13
        subtitle.TextColor3 = Color3.fromRGB(180, 200, 180)
        subtitle.TextXAlignment = Enum.TextXAlignment.Left
        subtitle.Parent = panel

        -- ── Core archetype row ─────────────────────────────────────
        -- Per Matthew 2026-04-27: 3 buttons for core selection (DPS /
        -- Control / Support). Default DPS (Power Core, the existing
        -- behavior). Selection passes through pickRemote payload as
        -- `coreId` and the server's grantLoadout uses it to stamp
        -- the matching core stock.
        --
        -- Stage 1: Visually selectable + plumbed end-to-end. The
        -- Control DOT-stacking + Support aura mechanics land in
        -- Stage 2 (Towers.lua behavior changes).
        local CORES = {
            { id = "Power",       label = "Power Core",   color = Color3.fromRGB(220, 90, 90) },
            { id = "ControlCore", label = "Control Core", color = Color3.fromRGB(180, 100, 230) },
            { id = "SupportCore", label = "Support Core", color = Color3.fromRGB(80, 180, 240) },
        }
        -- Pre-select the player's last-used Core if the server has
        -- stamped PreferredCoreId on them (hydrated from DataStore
        -- on PlayerAdded, refreshed on every SAVE/GO/AUTO RUN).
        -- Falls back to "Power" if the attribute is missing or
        -- malformed. Per Matthew 2026-04-28.
        local prefCore = deps.player and deps.player:GetAttribute("PreferredCoreId")
        local selectedCoreId =
            (prefCore == "Power" or prefCore == "ControlCore" or prefCore == "SupportCore")
            and prefCore or "Power"
        local coreButtons = {}

        local coreRow = Instance.new("Frame")
        coreRow.Position = UDim2.fromOffset(16, 78)
        coreRow.Size = UDim2.new(1, -32, 0, 44)
        coreRow.BackgroundTransparency = 1
        coreRow.Parent = panel
        do
            local layout = Instance.new("UIListLayout")
            layout.FillDirection = Enum.FillDirection.Horizontal
            layout.Padding = UDim.new(0, 12)
            layout.SortOrder = Enum.SortOrder.LayoutOrder
            layout.Parent = coreRow
        end

        local function refreshCoreButtonAppearance()
            for _, info in ipairs(CORES) do
                local btn = coreButtons[info.id]
                if btn then
                    local stroke = btn:FindFirstChildOfClass("UIStroke")
                    if info.id == selectedCoreId then
                        btn.BackgroundColor3 = info.color
                        btn.TextColor3 = Color3.fromRGB(20, 22, 28)
                        if stroke then stroke.Thickness = 3; stroke.Transparency = 0 end
                    else
                        btn.BackgroundColor3 = Color3.fromRGB(36, 42, 36)
                        btn.TextColor3 = info.color
                        if stroke then stroke.Thickness = 1.5; stroke.Transparency = 0.5 end
                    end
                end
            end
        end

        for i, info in ipairs(CORES) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.fromOffset(192, 44)
            btn.LayoutOrder = i
            btn.AutoButtonColor = false
            btn.BorderSizePixel = 0
            btn.Text = info.label
            btn.Font = Enum.Font.FredokaOne
            btn.TextSize = 16
            btn.Parent = coreRow
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 8)
                c.Parent = btn
                local s = Instance.new("UIStroke")
                s.Color = info.color
                s.Thickness = 1.5
                s.Parent = btn
            end
            coreButtons[info.id] = btn
            btn.Activated:Connect(function()
                selectedCoreId = info.id
                refreshCoreButtonAppearance()
            end)
        end
        refreshCoreButtonAppearance()

        -- ── Tower grid (5x3) ──────────────────────────────────────
        -- Cell math (panel is 640 wide, 32 padding total):
        --   inner width   = 608
        --   5 cols × cell + 4 gaps × pad = 608
        --   pad = 12, cell = (608 - 4×12) / 5 = 112 → use 112
        --   3 rows × 110 + 2 × 12 = 354 → grid height
        --
        -- 2026-04-28 expansion: was 3×3 (9 cells, 192-wide). Now 5×3
        -- (15 cells, 112-wide) to fit 14 aux towers. Cell shrunk
        -- 192→112; padding 14→12 to fit the wider grid in the same
        -- 608-wide inner panel area. Grid HEIGHT mostly unchanged
        -- (358 → 354) so the slider / button layout below doesn't
        -- need to move.
        local CELL_W, CELL_H = 112, 110
        local CELL_PAD = 12
        local GRID_W = GRID_COLS * CELL_W + (GRID_COLS - 1) * CELL_PAD
        local GRID_H = GRID_ROWS * CELL_H + (GRID_ROWS - 1) * CELL_PAD

        local grid = Instance.new("Frame")
        grid.AnchorPoint = Vector2.new(0.5, 0)
        grid.Position = UDim2.new(0.5, 0, 0, 142)  -- pushed 84→142 below the core archetype row
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
        -- 2026-04-29 ea3-8: rarity tier (Common / Rare / Exceptional /
        -- Legendary / Mythical). Default Common — matches the historical
        -- balance pool the cumulative results were built against. Picks
        -- up the player's last-saved rarity if PreferredRarity was
        -- stamped by a prior commit.
        local prefRarity = deps.player and deps.player:GetAttribute("PreferredRarity")
        local VALID_RARITIES = { Common = true, Rare = true, Exceptional = true,
                                 Legendary = true, Mythical = true }
        local selectedRarity = (prefRarity and VALID_RARITIES[prefRarity]) and prefRarity or "Common"

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
            -- Font sizes shrunk 2026-04-28 to fit the narrower 5-col
            -- cells (112 wide). 18→14 for tower name + 13→11 for role
            -- tag. "Lightning Radish" / "Mushroom Mortar" / "Spyglass
            -- Root" all fit at 14pt FredokaOne in 96px (cell width
            -- minus 16 padding).
            nameLabel.AnchorPoint = Vector2.new(0.5, 1)
            nameLabel.Position = UDim2.new(0.5, 0, 0.5, 2)
            nameLabel.Size = UDim2.new(1, -8, 0, 24)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = tpl.displayName or towerId
            nameLabel.Font = Enum.Font.FredokaOne
            nameLabel.TextSize = 14
            nameLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
            nameLabel.TextXAlignment = Enum.TextXAlignment.Center
            nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
            nameLabel.Parent = btn
            local roleTag = Instance.new("TextLabel")
            roleTag.AnchorPoint = Vector2.new(0.5, 0)
            roleTag.Position = UDim2.new(0.5, 0, 0.5, 4)
            roleTag.Size = UDim2.new(1, -8, 0, 16)
            roleTag.BackgroundTransparency = 1
            roleTag.Text = role:upper()
            roleTag.Font = Enum.Font.GothamBold
            roleTag.TextSize = 11
            roleTag.TextColor3 = ROLE_COLORS[role] or Color3.fromRGB(180, 180, 180)
            roleTag.TextXAlignment = Enum.TextXAlignment.Center
            roleTag.Parent = btn
            towerButtons[towerId] = btn
            btn.Activated:Connect(function() toggleTower(towerId) end)
        end

        -- ── Difficulty + Rarity row ────────────────────────────────
        -- 2026-04-29 ea3-8 layout: difficulty (left half) + rarity
        -- (right half). Per Matthew "make difficulty selector 50% of
        -- screen and rarity selector the other half (use C, R, E, M,
        -- etc.)". 6 difficulty buttons (0-5) on the left half, 5
        -- rarity buttons (C/R/E/L/M) on the right half. Slot 5
        -- enables the 4-tower lock for SELECT AUTO every-combo
        -- sweeps (5 aux total, 4 locked + 1 rotated).
        --
        -- Grid ends at y = 84 + GRID_H = 84 + 358 = 442. Row sits
        -- below with 16px gap.
        local sliderLabel = Instance.new("TextLabel")
        sliderLabel.Size = UDim2.new(1, -32, 0, 22)
        sliderLabel.Position = UDim2.fromOffset(16, 518)
        sliderLabel.BackgroundTransparency = 1
        sliderLabel.Text = ""
        sliderLabel.Font = Enum.Font.GothamBold
        sliderLabel.TextSize = 14
        sliderLabel.TextColor3 = Color3.fromRGB(220, 230, 220)
        sliderLabel.TextXAlignment = Enum.TextXAlignment.Left
        sliderLabel.Parent = panel

        -- Outer row at y=544. Inside it: left 50% = difficulty track,
        -- right 50% = rarity track. 8px gap between halves.
        local rowFrame = Instance.new("Frame")
        rowFrame.Size = UDim2.new(1, -32, 0, 50)
        rowFrame.Position = UDim2.fromOffset(16, 544)
        rowFrame.BackgroundTransparency = 1
        rowFrame.Parent = panel

        local function makeHalfTrack(xOffset, widthOffset)
            local f = Instance.new("Frame")
            f.AnchorPoint = Vector2.new(0, 0)
            f.Position = UDim2.fromOffset(xOffset, 0)
            f.Size = UDim2.new(0.5, widthOffset, 1, 0)
            f.BackgroundColor3 = Color3.fromRGB(28, 36, 30)
            f.BorderSizePixel = 0
            f.Parent = rowFrame
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = f
            return f
        end
        local diffTrack   = makeHalfTrack(0, -4)
        local rarityTrack = makeHalfTrack(0, -4)
        rarityTrack.Position = UDim2.new(0.5, 4, 0, 0)

        -- ── Difficulty buttons (slots 0..5) ────────────────────────
        local sliderButtons = {}
        local function refreshLabel()
            sliderLabel.Text = string.format(
                "AUX SLOTS: %d   |   DIFFICULTY: %.2f×   |   RARITY: %s",
                sliderValue, 1.0 + sliderValue * 0.25, selectedRarity)
        end
        local function refreshSlider()
            refreshLabel()
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

        -- 6 buttons (0-5) inside the half-track. Inner width ~300,
        -- minus 4px margins each side = 292; 6 buttons × 46 + 5 × 4 = 296,
        -- close enough — buttons share the available space using
        -- UIListLayout for clean horizontal distribution.
        local DIFF_BTN_COUNT = 6
        for v = 0, DIFF_BTN_COUNT - 1 do
            local b = Instance.new("TextButton")
            b.AnchorPoint = Vector2.new(0, 0.5)
            local frac = v / DIFF_BTN_COUNT
            b.Size = UDim2.new(1 / DIFF_BTN_COUNT, -4, 0, 36)
            b.Position = UDim2.new(frac, 2, 0.5, 0)
            b.BackgroundColor3 = Color3.fromRGB(50, 60, 52)
            b.BorderSizePixel = 0
            b.AutoButtonColor = false
            b.Text = tostring(v)
            b.Font = Enum.Font.FredokaOne
            b.TextSize = 22
            b.TextColor3 = Color3.fromRGB(220, 230, 220)
            b.Parent = diffTrack
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

        -- ── Rarity buttons (C/R/E/L/M) ─────────────────────────────
        -- 2026-04-29 ea3-8: per Matthew "use C, R, E, M, etc." — short
        -- labels keep the buttons small enough to fit the half-track
        -- alongside difficulty without crowding. Picks propagate
        -- through pickRemote payload as `rarity` and the server's
        -- grantLoadout stamps `<id>Rarity` on every aux template so
        -- TempTowers.resolveStats picks the right tier at placement.
        local RARITY_ORDER = { "Common", "Rare", "Exceptional", "Legendary", "Mythical" }
        local RARITY_LABELS = {
            Common = "C", Rare = "R", Exceptional = "E", Legendary = "L", Mythical = "M",
        }
        local RARITY_COLORS = {
            Common      = Color3.fromRGB(200, 200, 200),
            Rare        = Color3.fromRGB( 80, 150, 255),
            Exceptional = Color3.fromRGB(180,  80, 220),
            Legendary   = Color3.fromRGB(255, 170,  40),
            Mythical    = Color3.fromRGB(255,  60, 140),
        }
        local rarityButtons = {}
        local function refreshRarityButtons()
            refreshLabel()
            for r, b in pairs(rarityButtons) do
                if r == selectedRarity then
                    b.BackgroundColor3 = RARITY_COLORS[r]
                    b.TextColor3 = Color3.fromRGB(20, 20, 20)
                    -- Slight emphasis stroke on the selected tier.
                    local s = b:FindFirstChildOfClass("UIStroke")
                    if s then s.Transparency = 0 end
                else
                    b.BackgroundColor3 = Color3.fromRGB(50, 60, 52)
                    b.TextColor3 = RARITY_COLORS[r]
                    local s = b:FindFirstChildOfClass("UIStroke")
                    if s then s.Transparency = 0.7 end
                end
            end
        end
        local RARITY_BTN_COUNT = #RARITY_ORDER
        for i, rarity in ipairs(RARITY_ORDER) do
            local b = Instance.new("TextButton")
            b.AnchorPoint = Vector2.new(0, 0.5)
            local frac = (i - 1) / RARITY_BTN_COUNT
            b.Size = UDim2.new(1 / RARITY_BTN_COUNT, -4, 0, 36)
            b.Position = UDim2.new(frac, 2, 0.5, 0)
            b.BackgroundColor3 = Color3.fromRGB(50, 60, 52)
            b.BorderSizePixel = 0
            b.AutoButtonColor = false
            b.Text = RARITY_LABELS[rarity]
            b.Font = Enum.Font.FredokaOne
            b.TextSize = 20
            b.TextColor3 = RARITY_COLORS[rarity]
            b.Parent = rarityTrack
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 6)
                c.Parent = b
                local s = Instance.new("UIStroke")
                s.Color = RARITY_COLORS[rarity]
                s.Thickness = 1.5
                s.Parent = b
            end
            rarityButtons[rarity] = b
            b.Activated:Connect(function()
                selectedRarity = rarity
                refreshRarityButtons()
            end)
        end

        refreshSlider()
        refreshRarityButtons()

        -- ── Buttons row: [SAVE] [RESET] [GO] [CLOSE] ──────────────
        -- Per Matthew 2026-04-27: "closing the loadout should save
        -- the loadout, you should be allowed to place at that point.
        -- change button to SAVE. add button to loadout called GO in
        -- the middle that starts the waves and starts recording and
        -- locks the build." Then: "add CLOSE button back" — distinct
        -- from SAVE so the player can dismiss the picker without
        -- committing the current selection (e.g. opened it to peek
        -- at the slate, doesn't want to overwrite the active loadout).
        -- Then 2026-04-28 df: "save loadout everytime you hit save.
        -- and add a reset button next to save that resets the
        -- selection back to no aux and power core."
        --
        -- SAVE:  grants stock + closes picker. Player can then PLACE
        --        towers manually. Waves don't start yet. Always
        --        commits, regardless of whether selection changed.
        -- RESET: clears auxes + resets Core to Power. UI-only — does
        --        NOT fire the remote. User SAVEs/GOs afterward to
        --        commit the cleared state.
        -- GO:    grants stock + STARTS WAVES IMMEDIATELY (and starts
        --        recording for the cumulative pool). Locks the build.
        --        After GO, a STOP button (in the InfiniteButtonBar)
        --        lets the player abort the run with confirm.
        -- CLOSE: dismiss only — no remote fire, no state change.
        local function buildLoadoutPayload(phase)
            local picked = {}
            for _, towerId in ipairs(AUX_DISPLAY_ORDER) do
                if selected[towerId] then
                    table.insert(picked, towerId)
                end
            end
            -- Cache the commit into the module-level snapshot so
            -- SIMULATE → SELECT AUTO can read the player's current
            -- saved loadout without a server round-trip.
            _lastSelection = {
                coreId = selectedCoreId,
                auxIds = picked,
                slider = sliderValue,
                rarity = selectedRarity,  -- 2026-04-29 ea3-8
            }
            return {
                auxIds = picked,
                slider = sliderValue,
                coreId = selectedCoreId,  -- "Power" | "ControlCore" | "SupportCore"
                rarity = selectedRarity,  -- 2026-04-29 ea3-8 (Common..Mythical)
                phase  = phase,           -- "save" | "go"
            }
        end

        -- 4-button row evenly spaced across the 640 panel width per
        -- Matthew 2026-04-28 dl "evenly space these." Inner area
        -- 640 - 32 margins = 608. 4 × 140 + 3 × 16 = 608 → exact fit.
        --   SAVE  : x= 16  → 156
        --   RESET : x=172  → 312
        --   GO    : x=328  → 468
        --   CLOSE : x=484  → 624 (16px right margin)
        local BTN_W = 140
        local BTN_H = 44
        local BTN_GAP = 16
        local function btnX(slot) return 16 + (slot - 1) * (BTN_W + BTN_GAP) end

        -- SAVE — slot 1. Always commits, every click fires the remote
        -- with the current selection regardless of whether anything
        -- changed since last save.
        local saveBtn = Instance.new("TextButton")
        saveBtn.AnchorPoint = Vector2.new(0, 1)
        saveBtn.Position = UDim2.new(0, btnX(1), 1, -14)
        saveBtn.Size = UDim2.fromOffset(BTN_W, BTN_H)
        saveBtn.BackgroundColor3 = Color3.fromRGB(120, 160, 200)
        saveBtn.BorderSizePixel = 0
        saveBtn.AutoButtonColor = false
        saveBtn.Text = "SAVE"
        saveBtn.Font = Enum.Font.FredokaOne
        saveBtn.TextSize = 18
        saveBtn.TextColor3 = Color3.fromRGB(20, 30, 40)
        saveBtn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = saveBtn
        end
        saveBtn.Activated:Connect(function()
            -- Always commits — buildLoadoutPayload reads the current
            -- selection and fires regardless of whether it differs
            -- from the prior save. Per Matthew 2026-04-28 df: "save
            -- loadout everytime you hit save."
            pickRemote:FireServer(buildLoadoutPayload("save"))
            close(gui)
        end)

        -- RESET — clears all aux selections and resets Core to Power.
        -- Local state reset only; does NOT fire the server remote.
        -- User can SAVE/GO afterward to commit the cleared state.
        -- Per Matthew 2026-04-28 df: "add a reset button next to save
        -- that resets the selection back to no aux and power core."
        local resetBtn = Instance.new("TextButton")
        resetBtn.AnchorPoint = Vector2.new(0, 1)
        resetBtn.Position = UDim2.new(0, btnX(2), 1, -14)
        resetBtn.Size = UDim2.fromOffset(BTN_W, BTN_H)
        resetBtn.BackgroundColor3 = Color3.fromRGB(150, 150, 160)
        resetBtn.BorderSizePixel = 0
        resetBtn.AutoButtonColor = false
        resetBtn.Text = "RESET"
        resetBtn.Font = Enum.Font.FredokaOne
        resetBtn.TextSize = 18
        resetBtn.TextColor3 = Color3.fromRGB(30, 30, 35)
        resetBtn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = resetBtn
        end
        resetBtn.Activated:Connect(function()
            -- Walk the currently-selected set, clear each, refresh
            -- the button's visual state. Walking a copy of the keys
            -- because we mutate `selected` during the loop.
            local toClear = {}
            for towerId in pairs(selected) do
                table.insert(toClear, towerId)
            end
            for _, towerId in ipairs(toClear) do
                selected[towerId] = nil
                updateButtonAppearance(towerId)
            end
            -- Clear the FIFO order list too — without this the next
            -- aux pick would still see the old order tail and evict
            -- a phantom entry on cap-overflow.
            for i = #selectedOrder, 1, -1 do
                selectedOrder[i] = nil
            end
            -- Core back to Power (the DPS default).
            selectedCoreId = "Power"
            refreshCoreButtonAppearance()
        end)

        -- GO — slot 3 (primary action). Width matches the row now;
        -- visual emphasis comes from the green color rather than
        -- a wider button.
        local goBtn = Instance.new("TextButton")
        goBtn.AnchorPoint = Vector2.new(0, 1)
        goBtn.Position = UDim2.new(0, btnX(3), 1, -14)
        goBtn.Size = UDim2.fromOffset(BTN_W, BTN_H)
        goBtn.BackgroundColor3 = Color3.fromRGB(80, 200, 110)
        goBtn.BorderSizePixel = 0
        goBtn.AutoButtonColor = false
        goBtn.Text = "GO"
        goBtn.Font = Enum.Font.FredokaOne
        goBtn.TextSize = 22
        goBtn.TextColor3 = Color3.fromRGB(20, 30, 22)
        goBtn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = goBtn
        end
        goBtn.Activated:Connect(function()
            pickRemote:FireServer(buildLoadoutPayload("go"))
            close(gui)
        end)

        -- CLOSE — right side (dismiss, no commit). Red per Matthew
        -- 2026-04-28 to read as "abort / no commit" alongside SAVE
        -- (blue, neutral commit) and GO (green, run commit).
        local closeBtn = Instance.new("TextButton")
        closeBtn.AnchorPoint = Vector2.new(0, 1)
        closeBtn.Position = UDim2.new(0, btnX(4), 1, -14)
        closeBtn.Size = UDim2.fromOffset(BTN_W, BTN_H)
        closeBtn.BackgroundColor3 = Color3.fromRGB(220, 90, 90)
        closeBtn.BorderSizePixel = 0
        closeBtn.AutoButtonColor = false
        closeBtn.Text = "CLOSE"
        closeBtn.Font = Enum.Font.FredokaOne
        closeBtn.TextSize = 20
        closeBtn.TextColor3 = Color3.fromRGB(255, 245, 245)
        closeBtn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = closeBtn
        end
        closeBtn.Activated:Connect(function()
            close(gui)  -- no remote fire — dismiss only
        end)
    end

    showRemote.OnClientEvent:Connect(build)

    -- Public open() so the in-Infinite button bar can re-launch the
    -- picker without a remote round-trip. Same builder either way.
    InfiniteLoadoutPicker.open = build
end

return InfiniteLoadoutPicker
