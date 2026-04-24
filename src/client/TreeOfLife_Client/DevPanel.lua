--[[
    DevPanel.lua — The dev gear-icon panel in the bottom-left corner.
    Holds three categories (PROGRESS / TOOLS / TELEPORT) of buttons that
    fire dev RemoteEvents (skip wave, skip-to-boss, teleport, ground
    zero, etc.) plus the inventory category which routes to the
    AttachmentsModal + StatsModal sibling modules. Same UI on mobile +
    desktop with hotkeys (P / V / T / O / B / M / K / C) on desktop.

    Inventory + dev modal coordination — only one dev panel modal
    visible at a time; the AttachmentsModal/StatsModal subsetup uses
    the closeActiveDevModal / registerCloser callbacks to hand off.

    setup(deps) captures:
      deps.devGui              — ScreenGui parented to PlayerGui
      deps.player
      deps.playerGui
      deps.IS_MOBILE           — mobile flag (hides keyboard hotkey hints)
      deps.ReplicatedStorage
      deps.Remotes
      deps.CollectionService
      deps.UserInputService
      deps.Tags                — for AttachmentsModal/StatsModal subsetups
]]

local DevPanel = {}

function DevPanel.setup(deps)
    local devGui              = deps.devGui
    local player              = deps.player
    local playerGui           = deps.playerGui
    local IS_MOBILE           = deps.IS_MOBILE
    local ReplicatedStorage   = deps.ReplicatedStorage
    local Remotes             = deps.Remotes
    local CollectionService   = deps.CollectionService
    local UserInputService    = deps.UserInputService
    local Tags                = deps.Tags

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

    -- ATTACHMENTS MODAL extracted to sibling ModuleScript.
    -- See TreeOfLife_Client/AttachmentsModal.lua.
    local AttachmentsModal = require(script:WaitForChild("AttachmentsModal")).setup({
        playerGui           = playerGui,
        ReplicatedStorage   = ReplicatedStorage,
        Remotes             = Remotes,
        closeActiveDevModal = closeActiveDevModal,
        registerCloser      = function(fn) activeDevModalCloser = fn end,
    })

    attachBtn.MouseButton1Click:Connect(AttachmentsModal.open)

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

return DevPanel
