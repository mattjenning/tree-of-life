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

-- Module-level cache of the most recent in-picker selection.
-- ea3-40 (Matthew "dont reset selection when re opening loadout
-- menu"): cache now updates on close/SAVE/GO so the next
-- picker open re-hydrates the player's prior choice — even if
-- they closed without committing. Read by:
--   • build() — seeds the picker's working state on open
--   • SIMULATE → SELECT AUTO menu via getCurrentSelection()
-- The server still owns the canonical PreferredCoreId DataStore
-- for cross-session persistence; _lastSelection is the per-
-- session in-memory snapshot.
--
-- _lastSelectionSet tracks whether _lastSelection has been
-- populated this session. False on first open → fall back to
-- server-stamped player attributes (PreferredCoreId, etc.) for
-- cross-session continuity. True on subsequent opens → use the
-- cached state directly.
local _lastSelection = {
    coreId = "Power",
    auxIds = {},
    slider = 3,
    rarity = "Common",  -- 2026-04-29 ea3-8 (loadout-picker rarity tier)
}
local _lastSelectionSet = false

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

        -- ea3-40 forward-decls for state-mutation hooks. snapshotSelection
        -- + refreshSelectAutoBtn are assigned later (after their backing
        -- state is fully initialized) but the Core / rarity button click
        -- closures created EARLIER need to see them as locals so the
        -- closure captures the upvalue cell. Without the forward-decl,
        -- Lua treats the name as a global → nil at click time. (Per
        -- CLAUDE.md convention #1.)
        local snapshotSelection      -- forward decl
        local refreshSelectAutoBtn   -- forward decl

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
        -- Pre-select sequence (ea3-40 update):
        --   1. If _lastSelectionSet (player has opened the picker
        --      this session), prefer the in-memory cached Core.
        --   2. Else fall back to PreferredCoreId attribute (server-
        --      stamped from DataStore on PlayerAdded / refreshed on
        --      SAVE/GO/AUTO RUN). Cross-session continuity.
        --   3. Else "Power".
        local cachedCore = _lastSelectionSet and _lastSelection.coreId or nil
        local prefCore = deps.player and deps.player:GetAttribute("PreferredCoreId")
        local seedCore = cachedCore or prefCore
        local selectedCoreId =
            (seedCore == "Power" or seedCore == "ControlCore" or seedCore == "SupportCore")
            and seedCore or "Power"
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
                if snapshotSelection then snapshotSelection() end
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
        --
        -- ea3-40: seed from _lastSelection if the player has opened
        -- the picker this session — the auxIds + slider come back
        -- exactly as the player left them on close, instead of
        -- resetting to "no aux + slider 3" every time.
        local selected = {}     -- { [towerId] = true }
        local selectedOrder = {}  -- ordered list of towerIds
        if _lastSelectionSet then
            for _, towerId in ipairs(_lastSelection.auxIds) do
                selected[towerId] = true
                table.insert(selectedOrder, towerId)
            end
        end

        local towerButtons = {}  -- { [towerId] = TextButton }
        -- Slider seeds from _lastSelection if set, else default 3.
        local sliderValue = _lastSelectionSet and _lastSelection.slider or 3
        -- 2026-04-29 ea3-8: rarity tier (Common / Rare / Exceptional /
        -- Legendary / Mythical). Default Common — matches the historical
        -- balance pool the cumulative results were built against.
        --
        -- ea3-40: prefer cached _lastSelection.rarity over the server-
        -- stamped PreferredRarity for in-session continuity.
        local prefRarity = deps.player and deps.player:GetAttribute("PreferredRarity")
        local VALID_RARITIES = { Common = true, Rare = true, Exceptional = true,
                                 Legendary = true, Mythical = true }
        local cachedRarity = _lastSelectionSet and _lastSelection.rarity or nil
        local seedRarity = cachedRarity or prefRarity
        local selectedRarity = (seedRarity and VALID_RARITIES[seedRarity]) and seedRarity or "Common"

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
            -- ea3-40: keep the SELECT AUTO label + cached selection
            -- in sync with the locked-aux count after every toggle.
            if refreshSelectAutoBtn then refreshSelectAutoBtn() end
            if snapshotSelection then snapshotSelection() end
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
        --
        -- 2026-04-29 ea3-28: split single header label into TWO
        -- labels aligned with the difficulty + rarity tracks below.
        -- Per Matthew "lineup the rarity header with the buttons" —
        -- the screenshot showed RARITY: text crammed against the
        -- DIFFICULTY label instead of sitting over the rarity
        -- buttons on the right. Two-label layout fixes that:
        --   diffLabel:   "AUX SLOTS: N | DIFFICULTY: X×"  over diff track (left)
        --   rarityLabel: "RARITY: <name>"                 over rarity track (right)
        local diffLabel = Instance.new("TextLabel")
        diffLabel.Size = UDim2.new(0.5, -20, 0, 22)  -- match diffTrack width
        diffLabel.Position = UDim2.fromOffset(16, 518)
        diffLabel.BackgroundTransparency = 1
        diffLabel.Text = ""
        diffLabel.Font = Enum.Font.GothamBold
        diffLabel.TextSize = 14
        diffLabel.TextColor3 = Color3.fromRGB(220, 230, 220)
        diffLabel.TextXAlignment = Enum.TextXAlignment.Left
        diffLabel.Parent = panel

        local rarityLabel = Instance.new("TextLabel")
        rarityLabel.Size = UDim2.new(0.5, -20, 0, 22)  -- match rarityTrack width
        rarityLabel.Position = UDim2.new(0.5, 4, 0, 518)  -- match rarityTrack x-offset
        rarityLabel.BackgroundTransparency = 1
        rarityLabel.Text = ""
        rarityLabel.Font = Enum.Font.GothamBold
        rarityLabel.TextSize = 14
        rarityLabel.TextColor3 = Color3.fromRGB(220, 230, 220)
        rarityLabel.TextXAlignment = Enum.TextXAlignment.Left
        rarityLabel.Parent = panel

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
        -- ea3-40: snapshot the live picker state into _lastSelection
        -- on every change. close-without-commit + LOADOUT-toggle-
        -- close paths don't fire buildLoadoutPayload, so without
        -- this hook the in-progress state would be lost on the next
        -- picker open. Called from every state-mutation path
        -- (slider / aux toggle / core click / rarity click).
        -- Body assigned to the forward-decl'd upvalue from above.
        function snapshotSelection()
            local picked = {}
            for _, towerId in ipairs(selectedOrder) do
                table.insert(picked, towerId)
            end
            _lastSelection = {
                coreId = selectedCoreId,
                auxIds = picked,
                slider = sliderValue,
                rarity = selectedRarity,
            }
            _lastSelectionSet = true
        end
        local function refreshLabel()
            diffLabel.Text = string.format(
                "AUX SLOTS: %d   |   DIFFICULTY: %.2f×",
                sliderValue, 1.0 + sliderValue * 0.25)
            rarityLabel.Text = ("RARITY: %s"):format(selectedRarity)
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
            if refreshSelectAutoBtn then refreshSelectAutoBtn() end
            snapshotSelection()
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
                if snapshotSelection then snapshotSelection() end
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
            -- ea3-40: also flips _lastSelectionSet so the next build
            -- pulls from this cache instead of the server attribute.
            _lastSelection = {
                coreId = selectedCoreId,
                auxIds = picked,
                slider = sliderValue,
                rarity = selectedRarity,  -- 2026-04-29 ea3-8
            }
            _lastSelectionSet = true
            return {
                auxIds = picked,
                slider = sliderValue,
                coreId = selectedCoreId,  -- "Power" | "ControlCore" | "SupportCore"
                rarity = selectedRarity,  -- 2026-04-29 ea3-8 (Common..Mythical)
                phase  = phase,           -- "save" | "go"
            }
        end

        -- 2026-04-29 ea3-28 — bottom-row layout reorganized per
        -- Matthew. Final 4-button order:
        --   GO | SELECT AUTO | SAVE | RESET
        -- Plus a corner X (top-right of panel) replaces the prior
        -- CLOSE bottom-row slot. SELECT AUTO moved out of SIMULATE
        -- submenu into the loadout picker. SAVE + RESET shifted
        -- right-side per "switch save and reset buttons to the right
        -- side" — actions (GO / SELECT AUTO) on the left, state-
        -- management (SAVE / RESET) on the right.
        --   GO          : slot 1 → x= 16
        --   SELECT AUTO : slot 2 → x=172
        --   SAVE        : slot 3 → x=328
        --   RESET       : slot 4 → x=484
        local BTN_W = 140
        local BTN_H = 44
        local BTN_GAP = 16
        local function btnX(slot) return 16 + (slot - 1) * (BTN_W + BTN_GAP) end

        -- SAVE — slot 1. Always commits, every click fires the remote
        -- with the current selection regardless of whether anything
        -- changed since last save.
        local saveBtn = Instance.new("TextButton")
        saveBtn.AnchorPoint = Vector2.new(0, 1)
        saveBtn.Position = UDim2.new(0, btnX(3), 1, -14)
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
        resetBtn.Position = UDim2.new(0, btnX(4), 1, -14)
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
        goBtn.Position = UDim2.new(0, btnX(1), 1, -14)
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

        -- SELECT AUTO — slot 2, between GO and the right-side
        -- SAVE/RESET. Moved into the loadout picker per Matthew
        -- 2026-04-29 ea3-28 (was previously in the SIMULATE submenu).
        -- Label format clarified per Matthew 2026-04-29 ea3-40:
        -- "what does 0 / 3 mean on select auto" — was opaque
        -- (K/N), now reads as "K LOCKED / N SLOTS". K = auxes
        -- the player has clicked-to-lock; SELECT AUTO sweeps
        -- every combination of (locked) + (others) filling up
        -- to N slots. Greyed + shows "K > N!" when the player
        -- locked more than the slot count (defensive — picker
        -- normally evicts via FIFO, but the slider can drop
        -- below the locked count).
        --
        -- ea3-40 also wires reactive refresh: previously the
        -- label was set once at picker open, so changing the
        -- slider or locking/unlocking auxes left a stale label.
        -- refreshSelectAutoBtn now reads the live state and
        -- updates Text + colors + enabled state in place.
        local selectAutoBtn = Instance.new("TextButton")
        selectAutoBtn.AnchorPoint = Vector2.new(0, 1)
        selectAutoBtn.Position = UDim2.new(0, btnX(2), 1, -14)
        selectAutoBtn.Size = UDim2.fromOffset(BTN_W, BTN_H)
        selectAutoBtn.BorderSizePixel = 0
        selectAutoBtn.AutoButtonColor = false
        selectAutoBtn.Font = Enum.Font.FredokaOne
        selectAutoBtn.TextSize = 13
        selectAutoBtn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = selectAutoBtn
        end
        local selectAutoEnabled = false  -- updated by refresh below
        -- Assign to the forward-decl'd upvalue (refreshSelectAutoBtn)
        -- so refreshSlider / toggleTower can reach it via closure.
        function refreshSelectAutoBtn()
            local k = 0
            for _ in pairs(selected) do k = k + 1 end
            local n = sliderValue
            selectAutoEnabled = (k <= n) and (n <= 5)
            -- ea3-43: dropped "LOCKED" suffix per Matthew. Compact
            -- "K / N" reads as "K locked / N slots" given the
            -- AUX SLOTS row above shows the slot count explicitly.
            -- ea3-237 (2026-05-03): "SELECT AUTO" → "SELECT" per
            -- Matthew. The "AUTO" suffix was redundant — every sweep
            -- mode is auto-driven; the distinguishing word is SELECT
            -- (the K/N locked-tower mode).
            if selectAutoEnabled then
                selectAutoBtn.Text = ("SELECT  %d / %d"):format(k, n)
                selectAutoBtn.BackgroundColor3 = Color3.fromRGB(120, 180, 240)
                selectAutoBtn.TextColor3 = Color3.fromRGB(20, 30, 40)
            else
                selectAutoBtn.Text = ("SELECT  %d > %d!"):format(k, n)
                selectAutoBtn.BackgroundColor3 = Color3.fromRGB(60, 70, 80)
                selectAutoBtn.TextColor3 = Color3.fromRGB(140, 145, 150)
            end
            selectAutoBtn.Active = selectAutoEnabled
        end
        refreshSelectAutoBtn()
        if true then
            selectAutoBtn.Activated:Connect(function()
                if not selectAutoEnabled then return end
                -- Save the loadout first so the server has the
                -- canonical state (Core / aux / rarity / slider)
                -- before SELECT AUTO fires. Then bump speed to 20×
                -- (autoRunDoneRemote will restore on sweep end).
                pickRemote:FireServer(buildLoadoutPayload("save"))
                local setGameSpeedRemote =
                    ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
                if setGameSpeedRemote then
                    setGameSpeedRemote:FireServer(20)
                end
                local selectAutoRemote =
                    ReplicatedStorage:FindFirstChild(Remotes.Names.InfiniteSelectAutoRun)
                if selectAutoRemote then
                    local picked = {}
                    for _, towerId in ipairs(AUX_DISPLAY_ORDER) do
                        if selected[towerId] then table.insert(picked, towerId) end
                    end
                    selectAutoRemote:FireServer({
                        coreId       = selectedCoreId,
                        lockedAuxIds = picked,
                        slider       = sliderValue,
                        rarity       = selectedRarity,
                    })
                end
                close(gui)
            end)
        end

        -- Corner X close — top-right of the panel. Replaces the
        -- prior bottom-row CLOSE button per Matthew "add the close
        -- button to the top right of the window and make it an X".
        -- 32×32 anchored at the top-right corner with 8px inset.
        -- ea3-43: always-red close button per Matthew "add red box
        -- with white to close not just on hover on loadout". Hover
        -- flicker dropped — the button reads as a destructive
        -- action all the time now, not just when the cursor's over.
        local closeXBtn = Instance.new("TextButton")
        closeXBtn.AnchorPoint = Vector2.new(1, 0)
        closeXBtn.Position = UDim2.new(1, -8, 0, 8)
        closeXBtn.Size = UDim2.fromOffset(32, 32)
        closeXBtn.BackgroundColor3 = Color3.fromRGB(220, 90, 90)
        closeXBtn.BorderSizePixel = 0
        closeXBtn.AutoButtonColor = false
        closeXBtn.Text = "✕"
        closeXBtn.Font = Enum.Font.FredokaOne
        closeXBtn.TextSize = 22
        closeXBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        closeXBtn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = closeXBtn
        end
        -- Subtle hover lift: brighter red on enter, base red on leave.
        -- Keeps the always-red affordance but still gives a click cue.
        closeXBtn.MouseEnter:Connect(function()
            closeXBtn.BackgroundColor3 = Color3.fromRGB(255, 120, 120)
        end)
        closeXBtn.MouseLeave:Connect(function()
            closeXBtn.BackgroundColor3 = Color3.fromRGB(220, 90, 90)
        end)
        closeXBtn.Activated:Connect(function()
            close(gui)  -- no remote fire — dismiss only
        end)
    end

    showRemote.OnClientEvent:Connect(build)

    -- Public open() so the in-Infinite button bar can re-launch the
    -- picker without a remote round-trip. Same builder either way.
    InfiniteLoadoutPicker.open = build
end

return InfiniteLoadoutPicker
