--[[
    InfiniteButtonBar.lua — Two buttons that float above the hotbar
    while the player is in the Pickle Swamp (mapId=4):

      [ LOADOUT ]   [ ADMIN ]

    LOADOUT — re-opens the loadout picker. Server treats the picker's
              START while a run is active as "restart with new
              loadout" (stops current spawner, clears towers, re-runs
              enter with the new picks).
    ADMIN  —  opens InfiniteAdminPanel modal (run-reset, total-reset,
              tier displays / stats once persistent storage lands).

    Visible only when WaveState payload reports mapId == 4. Hidden
    automatically when the player exits back to hub (mapId reverts).

    setup(deps):
      deps.player, deps.playerGui, deps.ReplicatedStorage, deps.Remotes
]]

local Workspace = game:GetService("Workspace")

local InfiniteButtonBar = {}

function InfiniteButtonBar.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_InfiniteButtonBar"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 70  -- above hotbar (50-ish), below modals (60+)
    gui.Enabled = false  -- shown only on Map 4
    gui.Parent = playerGui

    -- Bar sits centered above the hotbar (hotbar is bottom-center).
    -- Hotbar height ~120, plus 8 gap.
    --
    -- 2026-04-29 ea3-22 layout: two rows now. Top row = SUPER AUTO
    -- (cyan, promoted from SIMULATE submenu row 4 per Matthew "make
    -- super auto mode button at top and make it cyan"). Bottom row
    -- = the original 3-button row (LOADOUT / ADMIN / SIMULATE).
    -- Container holds both; bottom-anchored so the row layout stays
    -- consistent regardless of how many top-row buttons land later.
    local barContainer = Instance.new("Frame")
    barContainer.AnchorPoint = Vector2.new(0.5, 1)
    barContainer.Position = UDim2.new(0.5, 0, 1, -132)
    barContainer.Size = UDim2.fromOffset(540, 44 + 8 + 44)  -- top row + gap + bottom row
    barContainer.BackgroundTransparency = 1
    barContainer.Parent = gui

    -- Top row holder — SUPER AUTO button only (currently). Centered
    -- horizontally; the button itself drives its own width.
    local topRow = Instance.new("Frame")
    topRow.AnchorPoint = Vector2.new(0.5, 0)
    topRow.Position = UDim2.fromScale(0.5, 0)
    topRow.Size = UDim2.fromOffset(540, 44)
    topRow.BackgroundTransparency = 1
    topRow.Parent = barContainer

    -- Bottom row holder — LOADOUT / ADMIN / SIMULATE. The existing
    -- 3-button bar. Renamed `bar` retained for back-compat with the
    -- rest of this file's button-creation code.
    local bar = Instance.new("Frame")
    bar.AnchorPoint = Vector2.new(0.5, 1)
    bar.Position = UDim2.fromScale(0.5, 1)
    -- Bar widened from 360 → 540 per Matthew 2026-04-27 to fit
    -- the new SIMULATE button (3 buttons × 170 + 2 × 12 gap = 534).
    bar.Size = UDim2.fromOffset(540, 44)
    bar.BackgroundTransparency = 1
    bar.Parent = barContainer

    local function makeBarButton(text, color, layoutOrder)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(170, 44)
        btn.LayoutOrder = layoutOrder
        btn.BackgroundColor3 = color
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = text
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 18
        btn.TextColor3 = Color3.fromRGB(20, 30, 22)
        btn.Parent = bar
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = btn
            local s = Instance.new("UIStroke")
            s.Thickness = 2
            s.Color = Color3.fromRGB(0, 0, 0)
            s.Transparency = 0.5
            -- ApplyStrokeMode = Border so the stroke outlines the
            -- button's RECTANGLE, not the TEXT inside it. Default
            -- ("Contextual") strokes each letter, which created a
            -- weird haloed/double-rendered effect on the highlighted
            -- M in ADMIN / MONITOR (Matthew 2026-04-26: "fix the
            -- font here. theres a weird transparent outer layer").
            s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            s.Parent = btn
        end
        btn.MouseEnter:Connect(function()
            btn.BackgroundColor3 = Color3.new(
                math.min(1, color.R * 1.2),
                math.min(1, color.G * 1.2),
                math.min(1, color.B * 1.2))
        end)
        btn.MouseLeave:Connect(function()
            btn.BackgroundColor3 = color
        end)
        return btn
    end

    do
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Horizontal
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        layout.Padding = UDim.new(0, 12)
        layout.Parent = bar
    end

    local loadoutBtn  = makeBarButton("LOADOUT",  Color3.fromRGB(120, 220, 140), 1)
    local adminBtn    = makeBarButton("ADMIN",    Color3.fromRGB(220, 180, 80),  2)
    local simulateBtn = makeBarButton("SIMULATE", Color3.fromRGB(120, 180, 240), 3)

    -- 2026-04-29 ea3-22: SUPER AUTO promoted to top row, cyan.
    -- Was row 4 of the SIMULATE submenu (still wired there for now
    -- so muscle memory keeps working; can remove from submenu in a
    -- follow-up if redundant). Wider than the bottom-row buttons
    -- since it's the headlining feature now.
    local SUPER_AUTO_COLOR = Color3.fromRGB(80, 210, 220)  -- cyan
    local superAutoBtn = Instance.new("TextButton")
    superAutoBtn.AnchorPoint = Vector2.new(0.5, 0)
    superAutoBtn.Position = UDim2.fromScale(0.5, 0)
    superAutoBtn.Size = UDim2.fromOffset(280, 44)
    superAutoBtn.BackgroundColor3 = SUPER_AUTO_COLOR
    superAutoBtn.BorderSizePixel = 0
    superAutoBtn.AutoButtonColor = false
    superAutoBtn.Text = "SUPER AUTO"
    superAutoBtn.Font = Enum.Font.FredokaOne
    superAutoBtn.TextSize = 20
    superAutoBtn.TextColor3 = Color3.fromRGB(20, 30, 40)
    superAutoBtn.Parent = topRow
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 8)
        c.Parent = superAutoBtn
        local s = Instance.new("UIStroke")
        s.Thickness = 2
        s.Color = Color3.fromRGB(0, 0, 0)
        s.Transparency = 0.5
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Parent = superAutoBtn
    end
    superAutoBtn.MouseEnter:Connect(function()
        superAutoBtn.BackgroundColor3 = Color3.new(
            math.min(1, SUPER_AUTO_COLOR.R * 1.2),
            math.min(1, SUPER_AUTO_COLOR.G * 1.2),
            math.min(1, SUPER_AUTO_COLOR.B * 1.2))
    end)
    superAutoBtn.MouseLeave:Connect(function()
        superAutoBtn.BackgroundColor3 = SUPER_AUTO_COLOR
    end)

    -- Highlight the M in ADMIN. D was an obvious choice but conflicts
    -- with WASD right-strafe (Matthew 2026-04-26: "make it M"); M
    -- doesn't conflict with default movement controls. Hotkey-letter
    -- highlight follows the dev-panel convention from
    -- feedback_dont_be_lazy.md memory.
    --
    -- The in-arena ADMIN button stays ADMIN regardless of AUTO RUN
    -- state — its job is to OPEN the admin panel. The panel-internal
    -- AUTO RUN button is what morphs to MONITOR mid-sweep. Per
    -- Matthew 2026-04-26: "auto run should be replaced with monitor,
    -- not the admin button".
    adminBtn.RichText = true
    adminBtn.Text = 'AD<font color="rgb(255,255,180)">M</font>IN'

    -- Highlight the U in SIMULATE per the same dev-panel hotkey
    -- convention (Matthew 2026-04-28; feedback_dont_be_lazy.md).
    -- U toggles the SIMULATE menu when pressed on Map 4.
    simulateBtn.RichText = true
    simulateBtn.Text = 'SIM<font color="rgb(255,255,180)">U</font>LATE'

    -- LOADOUT: re-open the picker directly via its exported open().
    -- No server round-trip — the picker is purely client-side; only
    -- the GO button's PickInfiniteScenario fire goes to server.
    --
    -- LOADOUT/STOP morph (Matthew 2026-04-27): when a manual run is
    -- active (Workspace.InfiniteManualRunActive == true), the
    -- button's text changes to "STOP" and its background turns red.
    -- Click → confirm modal → fire stopRunRemote with mode=
    -- "manualAbort" so the server tears down the run WITHOUT
    -- recording any stats. AUTO RUN sweeps don't trigger this morph
    -- — they have their own MONITOR / STOP NOW handling in the
    -- admin panel.
    local LoadoutPicker = require(script.Parent:WaitForChild("InfiniteLoadoutPicker"))
    local stopRunRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteStopRun)
    -- 2026-04-29 ea3-9: highlight the L in LOADOUT to flag the new
    -- L hotkey, matching the M-in-ADMIN / U-in-SIMULATE highlight
    -- convention from the dev-panel hotkey style (memory:
    -- feedback_dont_be_lazy.md).
    local LOADOUT_TEXT  = '<font color="rgb(255,255,180)">L</font>OADOUT'
    local STOP_TEXT     = "STOP"
    local LOADOUT_COLOR = Color3.fromRGB(120, 220, 140)  -- green
    local STOP_COLOR    = Color3.fromRGB(220, 90, 90)    -- red
    loadoutBtn.RichText = true
    local function refreshLoadoutBtnMorph()
        local manualActive = Workspace:GetAttribute("InfiniteManualRunActive") == true
        if manualActive then
            loadoutBtn.Text = STOP_TEXT
            loadoutBtn.BackgroundColor3 = STOP_COLOR
        else
            loadoutBtn.Text = LOADOUT_TEXT
            loadoutBtn.BackgroundColor3 = LOADOUT_COLOR
        end
    end
    Workspace:GetAttributeChangedSignal("InfiniteManualRunActive"):Connect(refreshLoadoutBtnMorph)
    refreshLoadoutBtnMorph()  -- initial state in case attribute is already set

    -- Build a tiny confirm modal locally — matches the admin panel's
    -- showConfirm pattern but inlined so this file doesn't pull in
    -- the admin module just for the modal helper.
    local function showStopConfirm(onYes)
        local confirmGui = Instance.new("ScreenGui")
        confirmGui.Name = "ToL_StopConfirmGui"
        confirmGui.IgnoreGuiInset = true
        confirmGui.ResetOnSpawn = false
        confirmGui.DisplayOrder = 240  -- above wave HUD + monitor
        confirmGui.Parent = playerGui
        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.4
        dim.BorderSizePixel = 0
        dim.Parent = confirmGui
        local panel = Instance.new("Frame")
        panel.AnchorPoint = Vector2.new(0.5, 0.5)
        panel.Position = UDim2.fromScale(0.5, 0.5)
        panel.Size = UDim2.fromOffset(420, 200)
        panel.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        panel.BorderSizePixel = 0
        panel.Parent = confirmGui
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 12)
            c.Parent = panel
        end
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -32, 0, 36)
        title.Position = UDim2.fromOffset(16, 18)
        title.BackgroundTransparency = 1
        title.Text = "STOP RUN?"
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 22
        title.TextColor3 = Color3.fromRGB(255, 200, 200)
        title.TextXAlignment = Enum.TextXAlignment.Center
        title.Parent = panel
        local body = Instance.new("TextLabel")
        body.Size = UDim2.new(1, -32, 0, 60)
        body.Position = UDim2.fromOffset(16, 60)
        body.BackgroundTransparency = 1
        body.Text = "Abort the current run? No stats will be recorded."
        body.Font = Enum.Font.Gotham
        body.TextSize = 14
        body.TextColor3 = Color3.fromRGB(220, 225, 230)
        body.TextXAlignment = Enum.TextXAlignment.Center
        body.TextYAlignment = Enum.TextYAlignment.Top
        body.TextWrapped = true
        body.Parent = panel
        local cancel = Instance.new("TextButton")
        cancel.AnchorPoint = Vector2.new(0, 1)
        cancel.Position = UDim2.new(0, 16, 1, -16)
        cancel.Size = UDim2.fromOffset(180, 40)
        cancel.BackgroundColor3 = Color3.fromRGB(80, 90, 100)
        cancel.BorderSizePixel = 0
        cancel.AutoButtonColor = false
        cancel.Text = "CANCEL"
        cancel.Font = Enum.Font.FredokaOne
        cancel.TextSize = 18
        cancel.TextColor3 = Color3.fromRGB(230, 235, 240)
        cancel.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = cancel
        end
        local yes = Instance.new("TextButton")
        yes.AnchorPoint = Vector2.new(1, 1)
        yes.Position = UDim2.new(1, -16, 1, -16)
        yes.Size = UDim2.fromOffset(180, 40)
        yes.BackgroundColor3 = Color3.fromRGB(220, 90, 90)
        yes.BorderSizePixel = 0
        yes.AutoButtonColor = false
        yes.Text = "STOP RUN"
        yes.Font = Enum.Font.FredokaOne
        yes.TextSize = 18
        yes.TextColor3 = Color3.fromRGB(255, 240, 240)
        yes.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = yes
        end
        cancel.Activated:Connect(function() confirmGui:Destroy() end)
        yes.Activated:Connect(function()
            confirmGui:Destroy()
            if onYes then onYes() end
        end)
    end

    loadoutBtn.MouseButton1Click:Connect(function()
        local manualActive = Workspace:GetAttribute("InfiniteManualRunActive") == true
        if manualActive then
            -- STOP path — confirm + abort.
            showStopConfirm(function()
                stopRunRemote:FireServer({ mode = "manualAbort" })
            end)
        else
            -- LOADOUT path — open the picker.
            if LoadoutPicker.open then LoadoutPicker.open() end
        end
    end)

    -- ADMIN button always opens the admin panel. The panel itself
    -- swaps its AUTO RUN button into MONITOR when a sweep is
    -- running (and clicking that opens the monitor window).
    local AdminPanel    = require(script.Parent:WaitForChild("InfiniteAdminPanel"))
    local MonitorWindow = require(script.Parent:WaitForChild("InfiniteMonitorWindow"))
    AdminPanel.setup({
        playerGui          = playerGui,
        ReplicatedStorage  = ReplicatedStorage,
        Remotes            = Remotes,
    })
    MonitorWindow.setup({
        playerGui          = playerGui,
        ReplicatedStorage  = ReplicatedStorage,
        Remotes            = Remotes,
    })

    adminBtn.MouseButton1Click:Connect(function()
        AdminPanel.open()
    end)

    -- SIMULATE: opens a 3-item file menu (RUN SIM / FULL AUTO /
    -- SELECT AUTO) per Matthew 2026-04-28 SIMULATE menu redesign.
    --   • RUN SIM     — closed-form math sweep (was the prior SIMULATE
    --                   click behavior). Pure-data, no real waves run.
    --   • FULL AUTO   — server runs solos + duos + curated trios
    --                   end-to-end. Replaces the old "AUTO RUN" +
    --                   "AUX AUTO" two-step from the admin panel.
    --   • SELECT AUTO — server runs sweeps pinned to the player's
    --                   currently saved loadout (Core + locked auxes).
    --                   Greyed when 3+ auxes are saved (since SELECT
    --                   AUTO needs <=2 locked slots to vary against).
    local simulateRemote       = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteSimulate)
    local simulateDataRemote   = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteSimulateData)
    local fullAutoRemote       = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteFullAutoRun)
    local superAutoRemote      = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteSuperAutoRun)
    local towerSuperRemote     = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteTowerSuperRun)
    local selectAutoRemote     = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteSelectAutoRun)
    local setGameSpeedRemote   = ReplicatedStorage:WaitForChild(Remotes.Names.SetGameSpeed)
    local simulating = false

    -- Speed auto-toggle on AUTO RUN start. Per Matthew 2026-04-28:
    -- "when starting autorun, automatically set speed to 20x. back
    -- to 1x (or whatever it was at originally) when run ends."
    --
    -- savedSpeed snapshot is captured at sweep-start, restored when
    -- autoRunDoneRemote fires (sweep complete) OR the player hits
    -- STOP NOW (via stopRunRemote with mode="manualAbort"). Stays
    -- nil while no sweep is active so reload-during-sweep doesn't
    -- corrupt the restore value.
    local AUTORUN_SPEED = 20
    local savedSpeed = nil
    local function kickAutoRun(fireFn)
        savedSpeed = Workspace:GetAttribute("GameSpeed") or 1
        if savedSpeed ~= AUTORUN_SPEED then
            setGameSpeedRemote:FireServer(AUTORUN_SPEED)
        end
        fireFn()
    end
    local function restoreSpeed()
        if savedSpeed and savedSpeed ~= AUTORUN_SPEED then
            setGameSpeedRemote:FireServer(savedSpeed)
        end
        savedSpeed = nil
    end

    -- 2026-04-29 ea3-22: wire the top-row SUPER AUTO button click.
    -- Deferred to here (vs at button-creation time) because the
    -- click handler needs the kickAutoRun helper + superAutoRemote
    -- ref, which are declared later in setup(). Same fire path as
    -- the SIMULATE submenu row-4 entry; both buttons trigger the
    -- same server flow. Eventually the submenu row may go away.
    superAutoBtn.MouseButton1Click:Connect(function()
        kickAutoRun(function()
            superAutoRemote:FireServer()
        end)
    end)

    -- Build a small popup menu floating above the SIMULATE button.
    -- Single-instance (re-clicking SIMULATE while open closes it).
    local simulateMenuGui = nil
    local function closeSimulateMenu()
        if simulateMenuGui then
            simulateMenuGui:Destroy()
            simulateMenuGui = nil
        end
    end

    local function openSimulateMenu()
        closeSimulateMenu()
        simulateMenuGui = Instance.new("ScreenGui")
        simulateMenuGui.Name = "ToL_SimulateMenu"
        simulateMenuGui.IgnoreGuiInset = true
        simulateMenuGui.ResetOnSpawn = false
        simulateMenuGui.DisplayOrder = 200
        simulateMenuGui.Parent = playerGui

        -- Click-outside-to-dismiss layer.
        local dim = Instance.new("TextButton")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 1
        dim.AutoButtonColor = false
        dim.Text = ""
        dim.Parent = simulateMenuGui
        dim.MouseButton1Click:Connect(closeSimulateMenu)

        -- Anchor the menu above the SIMULATE button. SIMULATE is the
        -- 3rd slot in the bar (LOADOUT / ADMIN / SIMULATE). Bar is
        -- bottom-anchored at y = 1, -132. Menu sits above it.
        --
        -- 2026-04-29 ea: row count 3 → 4 (added SUPER AUTO).
        -- 2026-04-29 ea3-24: row count 4 → 5 (added TOWER SUPER at top).
        -- 2026-04-29 ea3-27: row count 5 → 6 (added CORE AUTO disabled
        --                    placeholder; see memory project_core_upgrade_picker.md
        --                    "CORE AUTO" section — server handler awaits Phase E).
        --
        -- Bar is now 2 rows (top: SUPER AUTO, bottom: 3 standard
        -- buttons including SIMULATE) so menu anchor moves up by
        -- the extra row's height (44 + 8 gap = 52).
        local MENU_W = 200
        local ROW_H = 40
        local PAD = 6
        local rows = 6
        local menuH = ROW_H * rows + PAD * (rows + 1)
        local menu = Instance.new("Frame")
        menu.AnchorPoint = Vector2.new(0.5, 1)
        -- SIMULATE is the rightmost button in the 540-wide bar
        -- centered on screen. Each button is 170 wide with 12px
        -- gap; the SIMULATE midpoint is bar-center + (170+12) =
        -- bar-center + 182. So menu midpoint matches.
        --
        -- 2026-04-29 ea3-24: bar is now 2 rows. Y offset shifted
        -- up by 44+8=52 so the menu anchors above the entire
        -- container (otherwise the menu would render over the
        -- top-row SUPER AUTO button).
        menu.Position = UDim2.new(0.5, 182, 1, -132 - 44 - 8 - 44 - 6)
        menu.Size = UDim2.fromOffset(MENU_W, menuH)
        menu.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        menu.BorderSizePixel = 0
        menu.Parent = simulateMenuGui
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = menu
            local s = Instance.new("UIStroke")
            s.Thickness = 1.5
            s.Color = Color3.fromRGB(120, 180, 240)
            s.Parent = menu
        end

        -- makeRow(idx, text, enabled, onClick, opts?)
        --   opts.keepOpen — if true, click runs onClick WITHOUT
        --     closing the SIMULATE menu first. Used by RUN SIM
        --     so the player can hit it again without re-opening
        --     the menu (Matthew 2026-04-28). FULL AUTO / SELECT
        --     AUTO close because they kick a real-time run.
        local function makeRow(idx, text, enabled, onClick, opts)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, -PAD * 2, 0, ROW_H)
            b.Position = UDim2.fromOffset(PAD, PAD + (idx - 1) * (ROW_H + PAD))
            b.BackgroundColor3 = enabled
                and Color3.fromRGB(60, 90, 130)
                or Color3.fromRGB(50, 55, 65)
            b.BorderSizePixel = 0
            b.AutoButtonColor = enabled
            b.Text = text
            b.Font = Enum.Font.FredokaOne
            b.TextSize = 16
            b.TextColor3 = enabled
                and Color3.fromRGB(240, 245, 250)
                or Color3.fromRGB(120, 125, 130)
            b.Active = enabled
            b.Parent = menu
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 6)
                c.Parent = b
            end
            local keepOpen = opts and opts.keepOpen
            if enabled then
                b.MouseButton1Click:Connect(function()
                    if not keepOpen then
                        closeSimulateMenu()
                    end
                    onClick()
                end)
            end
            return b
        end

        -- Read the player's most recently saved loadout. 2026-04-29
        -- ea3-9: SELECT AUTO no longer needs the K≤2 cap — every-combo
        -- math handles any (K, N) where K ≤ N ≤ 5. Greyed only when
        -- K > N (locked more than the slot count permits, which the
        -- picker already prevents via FIFO eviction but defensive).
        local LoadoutPicker = require(script.Parent:WaitForChild("InfiniteLoadoutPicker"))
        local selection = LoadoutPicker.getCurrentSelection
            and LoadoutPicker.getCurrentSelection()
            or { coreId = "Power", auxIds = {}, slider = 0, rarity = "Common" }
        local lockedCount = #selection.auxIds
        local slotCount   = selection.slider or 0
        local selectAutoEnabled = lockedCount <= slotCount and slotCount <= 5

        -- 2026-04-29 ea3-24 — TOWER SUPER: zoom-in sweep on a single
        -- focus aux across 3 Cores × 5 rarities = 15 sub-sweeps.
        -- Reads the FIRST locked aux from the saved loadout as the
        -- focus tower. Greyed when no aux is locked (defensive).
        local focusAuxId   = selection.auxIds and selection.auxIds[1]
        local towerSuperEnabled = (focusAuxId ~= nil)
        local towerSuperLabel = towerSuperEnabled
            and ("TOWER SUPER AUTO  (%s)"):format(focusAuxId)
            or  "TOWER SUPER AUTO (no aux)"
        makeRow(1, towerSuperLabel, towerSuperEnabled, function()
            kickAutoRun(function()
                towerSuperRemote:FireServer({
                    focusAuxId = focusAuxId,
                })
            end)
        end)
        makeRow(2, "RUN SIM", true, function()
            if simulating then return end
            simulating = true
            simulateBtn.Text = "SIM<font color=\"rgb(255,255,180)\">U</font>LATING…"
            simulateRemote:FireServer()
        end, { keepOpen = true })
        -- 2026-04-29 ea3-27: CORE AUTO placeholder. Greyed/disabled
        -- because the spec ("1-10 wave sequence with the same most
        -- stable combo, choosing the same upgrade path each time +
        -- one of all 3") depends on the Phase E story-progression-
        -- mirror sweep. Reserves the slot + makes the design
        -- visible. See memory project_core_upgrade_picker.md →
        -- CORE AUTO section.
        makeRow(3, "CORE AUTO (Phase E)", false, function()
            -- noop while disabled
        end)
        makeRow(4, "FULL AUTO", true, function()
            -- Auto-bump speed to 20× on AUTO RUN start (Matthew
            -- 2026-04-28). Saved-speed state restored on
            -- autoRunDoneRemote (handler near bottom of setup).
            kickAutoRun(function()
                fullAutoRemote:FireServer()
            end)
        end)
        -- Label format: "SELECT AUTO (K/N)" — rotated count is N-K.
        local label
        if selectAutoEnabled then
            label = ("SELECT AUTO  (%d/%d)"):format(lockedCount, slotCount)
        else
            label = ("SELECT AUTO (%d>%d)"):format(lockedCount, slotCount)
        end
        makeRow(5, label, selectAutoEnabled, function()
            -- Send the locked auxIds + coreId + slot count from the
            -- cached selection so the server builds the every-combo
            -- queue with the right (K, N) shape.
            kickAutoRun(function()
                selectAutoRemote:FireServer({
                    coreId       = selection.coreId,
                    lockedAuxIds = selection.auxIds,
                    slider       = slotCount,
                    rarity       = selection.rarity,
                })
            end)
        end)
        -- 2026-04-29 ea: SUPER AUTO — server runs RUN SIM for all 3
        -- Cores then chains FULL AUTO sweeps Power → Control →
        -- Support, then continuous top-combos. Per Matthew 2026-04-29:
        -- "make a super auto run off the simulate menu that does a
        -- full sweep for all 3 cores then goes into extra tiered
        -- testing. and run the sim for every core when starting."
        --
        -- ea3-23: also surfaced as the cyan top-bar button. Keeping
        -- the submenu row for muscle memory.
        makeRow(6, "SUPER AUTO", true, function()
            kickAutoRun(function()
                superAutoRemote:FireServer()
            end)
        end)
    end

    -- Toggle helper used by both the SIMULATE button click and
    -- the U hotkey (Matthew 2026-04-28).
    local function toggleSimulateMenu()
        if simulateMenuGui then
            closeSimulateMenu()
        else
            openSimulateMenu()
        end
    end
    simulateBtn.MouseButton1Click:Connect(toggleSimulateMenu)
    simulateDataRemote.OnClientEvent:Connect(function(payload)
        simulating = false
        simulateBtn.Text = "SIM<font color=\"rgb(255,255,180)\">U</font>LATE"
        if type(payload) ~= "table" or type(payload.results) ~= "table" then
            print("[InfiniteButtonBar] SIMULATE returned no data.")
            return
        end
        print(("[InfiniteButtonBar] RUN SIM complete — %d loadouts. Server log has the tier list."):format(
            #payload.results))
        print("[InfiniteButtonBar] Top 5 sim results:")
        local sorted = {}
        for _, r in ipairs(payload.results) do table.insert(sorted, r) end
        table.sort(sorted, function(a, b) return (a.finalWave or 0) > (b.finalWave or 0) end)
        for i = 1, math.min(5, #sorted) do
            local r = sorted[i]
            print(("  %d. %s → wave %.2f"):format(i, r.label or "?", r.finalWave or 0))
        end
    end)

    -- Visibility gate: show only when mapId == 4 AND no modal is
    -- open. Same modal-count pattern as InfiniteHUD — picker /
    -- admin panel each increment playerGui.InfiniteModalCount on
    -- open + decrement on close.
    local onMap4 = false
    local function refreshVisibility()
        local count = playerGui:GetAttribute("InfiniteModalCount") or 0
        gui.Enabled = onMap4 and count == 0
    end

    local waveStateRemote = ReplicatedStorage:WaitForChild(Remotes.Names.WaveState)
    waveStateRemote.OnClientEvent:Connect(function(state)
        if type(state) ~= "table" then return end
        onMap4 = (state.mapId == 4)
        refreshVisibility()
    end)
    playerGui:GetAttributeChangedSignal("InfiniteModalCount"):Connect(refreshVisibility)

    -- HOTKEYS — only fire on Map 4 + when not typing in chat / textbox.
    --   M → toggle admin panel (chosen over D to avoid WASD strafe;
    --        per Matthew 2026-04-26: "M should close admin panel").
    --   U → toggle SIMULATE menu (free key; per Matthew 2026-04-28).
    --   L → open the LOADOUT picker (per Matthew 2026-04-29). Only
    --       opens — STOP-mode loadoutBtn (manual run active) ignores
    --       L, since the click path opens a confirm modal that
    --       shouldn't be hotkey-triggered. Falls through silently.
    -- All three use the same gameProcessedEvent guard + onMap4 gate.
    local UserInputService = game:GetService("UserInputService")
    UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if gameProcessedEvent then return end
        if not onMap4 then return end
        if input.KeyCode == Enum.KeyCode.M then
            AdminPanel.toggle()
        elseif input.KeyCode == Enum.KeyCode.U then
            toggleSimulateMenu()
        elseif input.KeyCode == Enum.KeyCode.L then
            local manualActive = Workspace:GetAttribute("InfiniteManualRunActive") == true
            if not manualActive and LoadoutPicker.open then
                LoadoutPicker.open()
            end
        end
    end)

    -- AUTO RUN active → auto-pop the monitor window on the FIRST
    -- progress tick (so the player sees live stats appear without
    -- having to open the admin panel themselves).
    local autoRunProgressRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunProgress)
    local autoRunSeen = false
    autoRunProgressRemote.OnClientEvent:Connect(function()
        if not autoRunSeen then
            autoRunSeen = true
            MonitorWindow.open()
        end
    end)
    local autoRunDoneRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunDone)
    autoRunDoneRemote.OnClientEvent:Connect(function()
        autoRunSeen = false
        -- Restore the pre-AUTO-RUN game speed (Matthew 2026-04-28).
        -- Idempotent — if savedSpeed is nil (sweep wasn't kicked
        -- via the SIMULATE menu, or already restored on STOP NOW)
        -- this is a no-op.
        restoreSpeed()
    end)
end

return InfiniteButtonBar
