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
    -- 2026-04-29 ea3-22/39: layout collapsed BACK to a single row
    -- after Matthew flagged the duplicate SUPER AUTO entry point.
    -- Per Matthew 2026-04-29: "only one super auto button, make it
    -- under the simulate menu, cyan". The cyan top-row button is
    -- gone; the SIMULATE submenu's SUPER AUTO row is the canonical
    -- entry point + is itself styled cyan to keep the visual cue.
    local bar = Instance.new("Frame")
    bar.AnchorPoint = Vector2.new(0.5, 1)
    bar.Position = UDim2.new(0.5, 0, 1, -132)
    -- Bar widened from 360 → 540 per Matthew 2026-04-27 to fit
    -- the new SIMULATE button (3 buttons × 170 + 2 × 12 gap = 534).
    bar.Size = UDim2.fromOffset(540, 44)
    bar.BackgroundTransparency = 1
    bar.Parent = gui

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
        -- Closure-captured base color for hover handlers. State-driven
        -- recolor (e.g. SIMULATE → STOP red while a sweep is running)
        -- MUST go through the returned setBase() — otherwise the next
        -- MouseLeave restores this captured value and overwrites the
        -- new color. Per Matthew 2026-05-01 "turn STOP red when a sim
        -- is running": pre-fix, applySimulateState set BackgroundColor3
        -- directly and the hover-out handler clobbered it back to blue.
        local baseColor = color
        btn.MouseEnter:Connect(function()
            btn.BackgroundColor3 = Color3.new(
                math.min(1, baseColor.R * 1.2),
                math.min(1, baseColor.G * 1.2),
                math.min(1, baseColor.B * 1.2))
        end)
        btn.MouseLeave:Connect(function()
            btn.BackgroundColor3 = baseColor
        end)
        local function setBase(c)
            baseColor = c
            btn.BackgroundColor3 = c
        end
        return btn, setBase
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
    local simulateBtn, setSimulateBaseColor = makeBarButton("SIMULATE", Color3.fromRGB(120, 180, 240), 3)

    -- Cyan tone reused below to style the submenu's SUPER AUTO row.
    -- (Previously this also painted a top-row dedicated button; that
    -- button is gone — see ea3-39 layout note above.)
    local SUPER_AUTO_COLOR = Color3.fromRGB(80, 210, 220)   -- cyan
    -- ea3-54 — VALIDATE row tone. Per Matthew "make it mauve and
    -- reconfigure it whenever we can press it to do a focused test":
    -- VALIDATE is our flex slot for fast targeted runs. The mauve
    -- visually distinguishes it from the cyan SUPER AUTORUN /
    -- AUTORUN broad-search rows.
    local VALIDATE_COLOR   = Color3.fromRGB(170, 110, 200)  -- mauve
    -- ea3-125 — TARGETED row tone. Yellow visually distinguishes
    -- "variance-driven shorter sweep" from VALIDATE's mauve flex
    -- slot and FAILURE CURVE's mauve full-coverage 105 sweep.
    local TARGETED_COLOR   = Color3.fromRGB(230, 200, 90)   -- yellow

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
    -- ea3-43: forward-decl for closeSimulateMenu so the LOADOUT
    -- click handler can detect "SIMULATE menu is open" + close it
    -- without ALSO opening the loadout picker. Per Matthew "if you
    -- have simulate menu open clicking loadout just closes sub menu
    -- does not also open loadout". Body assigned ~250 lines down
    -- alongside the openSimulateMenu / simulateMenuGui state.
    local closeSimulateMenu  -- forward decl
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
            return
        end
        -- ea3-43: if the SIMULATE submenu is already open, this click
        -- just closes it — DON'T fall through to opening the loadout
        -- picker. Per Matthew "if you have simulate menu open clicking
        -- loadout just closes sub menu does not also open loadout".
        if closeSimulateMenu and closeSimulateMenu() then
            return
        end
        -- LOADOUT path — open the picker.
        if LoadoutPicker.open then LoadoutPicker.open() end
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
    -- (fullAutoRemote / superAutoRemote refs removed 2026-05-01 ea3-139
    -- — both server handlers were orphaned and have been cleaned up.
    -- See Infinite.lua + Remotes.lua for the removal notes.)
    local towerSuperRemote     = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteTowerSuperRun)
    -- (storySuperRemote was retired ea3-52; server handler removed
    -- 2026-05-01 ea3-142. See Infinite.lua + Remotes.lua for the
    -- removal notes. StorySuperAuto module survives for tests +
    -- CoreAutoRunner's reserved future-helper require.)
    -- 2026-04-29 ea3-42 Phase E-3: CORE AUTO. Tests upgrade-option
    -- impact across 12 conditions (3 Cores × 4 paths). See
    -- systems/CoreAutoRunner.lua server-side.
    local coreAutoRemote       = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteCoreAutoRun)
    -- ea3-52 Phase F: bounds-shrinking arena sweep mode.
    --   AUTORUN — greedy 42-combo search
    -- (SUPER AUTORUN removed 2026-05-01 ea3-135 — superseded by
    -- SUPER CURVE × 495's clean-failure-point overnight sweep.)
    local arenaAutorunRemote      = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteArenaAutorun)
    -- ea3-53: single-combo VALIDATE smoke test (~3-5 min run).
    local arenaValidateRemote     = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteArenaValidate)
    -- ea3-71/-110: LONG VALIDATE × 8 and SPOT CHECK × 12 menu rows
    -- removed in ea3-121. Server-side handlers stay registered so
    -- old saved sweeps continue to load; just no client entry to
    -- invoke them.
    -- ea3-116: FAILURE CURVE × 105 — wave-1..28 ramping failure-curve
    -- sweep using AutoPlaceStrategy for tower placement. Replaces the
    -- ea3-115 stopgap which re-exposed the legacy autoRunRemote (its
    -- placement quality was demonstrably worse — see project_failure_
    -- curve_v2.md). v2 shares ArenaSweepRunner's lifecycle (Map4
    -- ArenaSweepActive flag, cooperative abort, env-cull, ETA bar) so
    -- STOP toggle / cleanup integration works uniformly with the other
    -- arena sweep modes. Mauve like the other validator-feeding rows.
    -- ~45-60 min at 20× game speed (105 loadouts × ~30s each).
    local arenaFailureCurveRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteArenaFailureCurve)
    -- ea3-133/134 — SUPER FAILURE CURVE × 495. Two-phase overnight
    -- sweep: Phase A = three FAILURE CURVE × 105 sweeps back-to-back
    -- (3 cores × 105 = 315), Phase B = TARGETED × 60 per Core
    -- (3 cores × 60 = 180). Same wave-1..28 force-failure pipeline
    -- as FAILURE CURVE × 105 throughout — no wave-30 saturation.
    -- ~6.9 hours at 20× game speed; per-combo checkpoint flushes
    -- to DataStore every 10 combos so a Studio crash mid-sweep
    -- preserves work in either phase. Phase B re-runs the loadouts
    -- with the highest sim-vs-real |delta| (= "highest info value")
    -- after Phase A's 315 fresh entries refresh each Core's
    -- validator. Designed to wake up to actionable balance data
    -- across all 3 anchors.
    local arenaSuperFailureCurveRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteArenaSuperFailureCurve)
    -- ea3-125 — TARGETED variance-driven shorter sweep (~10-12 min).
    -- Server reads the latest validator report, sorts perLoadout by
    -- |delta|, queues the top N combos through the FAILURE CURVE
    -- pipeline. Output feeds the validator on the next press.
    local arenaTargetedRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteArenaTargeted)
    -- 2026-04-29 ea3-28: selectAutoRemote ref dropped from this file —
    -- SELECT AUTO moved into the loadout picker (InfiniteLoadoutPicker.lua),
    -- which resolves the remote at click time via Remotes.Names lookup.
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

    -- (Top-row SUPER AUTO click handler removed in ea3-39 alongside
    -- the dedicated button; submenu row owns the click path now.)

    -- Build a small popup menu floating above the SIMULATE button.
    -- Single-instance (re-clicking SIMULATE while open closes it).
    local simulateMenuGui = nil
    -- ea3-43: assigned to the forward-decl'd upvalue (declared near
    -- the LOADOUT click handler above) so that handler can detect
    -- "SIMULATE menu is open" + close it without ALSO opening the
    -- loadout picker. Returns true if a menu was closed; false if
    -- nothing was open. Caller passes via the return value to decide
    -- whether to fall through to the next action.
    closeSimulateMenu = function()
        if simulateMenuGui then
            simulateMenuGui:Destroy()
            simulateMenuGui = nil
            return true
        end
        return false
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
        -- 2026-04-29 ea3-27: row count 5 → 6 (added CORE AUTO disabled).
        -- 2026-04-29 ea3-28: row count 6 → 5 — SELECT AUTO moved to
        --                    the loadout picker; RUN SIM moved to bottom.
        -- Final order: TOWER SUPER AUTO / CORE AUTO (Phase E) /
        --              FULL AUTO / SUPER AUTO / STORY SUPER (WIP) /
        --              RUN SIM
        --
        -- 2026-04-29 ea3-35 Phase E-2: STORY SUPER inserted between
        -- SUPER AUTO and RUN SIM. rows bumped 5 → 6.
        --
        -- ea3-71: 7 menu rows. SUPER AUTORUN / AUTORUN / VALIDATE
        -- (single-combo smoke test) / LONG VALIDATE (8-combo
        -- statistical pass, ~30min) / TOWER SUPER AUTO / CORE AUTO
        -- / RUN SIM.
        --
        -- ea3-110: 7 → 8 rows — SPOT CHECK × 12 inserted between
        -- LONG VALIDATE and TOWER SUPER AUTO. Cycles 4 fixed loadouts
        -- through paired Core-only / ALL-TOWER runs to verify the
        -- Pickle Lord HP target holds across loadouts.
        --
        -- ea3-116: 8 → 9 rows — FAILURE CURVE × 105 row inserted between
        -- SPOT CHECK and TOWER SUPER. Wave-1..28 ramping failure-curve
        -- sweep using AutoPlaceStrategy (replaces ea3-115's stopgap
        -- FAILURE SWEEP which re-exposed the legacy autoRunRemote with
        -- corner-bias placement). The arena sweeps above don't feed
        -- the validator (4-phase boss-kill format); this row produces
        -- the wave-1..28 ramp finalWave that InfiniteValidator.compare
        -- needs for the sim-vs-real delta. Per project_failure_curve_v2.md.
        --
        -- ea3-125: 7 → 8 rows — TARGETED row (yellow) inserted between
        -- FAILURE CURVE × 105 and TOWER SUPER. Variance-driven shorter
        -- sweep — server picks the top-15 worst-|delta| combos from the
        -- latest validator report, queues them through the same
        -- wave-1..28 ramp pipeline as FAILURE CURVE × 105. ~10-12 min
        -- at 20× game speed; output feeds the validator on next press.
        -- Per Matthew "yellow TARGETED button [...] highest information
        -- value combinations".
        -- 2026-05-01 ea3-135: 9 → 8 rows — SUPER AUTORUN row removed
        -- (superseded by SUPER CURVE × 495). New order: AUTORUN /
        -- VALIDATE / CURVE / SUPER CURVE / TARGETED / TOWER SUPER /
        -- CORE AUTO / RUN SIM.
        local MENU_W = 200
        local ROW_H = 40
        local PAD = 6
        local rows = 8
        local menuH = ROW_H * rows + PAD * (rows + 1)
        local menu = Instance.new("Frame")
        menu.AnchorPoint = Vector2.new(0.5, 1)
        -- SIMULATE is the rightmost button in the 540-wide bar
        -- centered on screen. Each button is 170 wide with 12px
        -- gap; the SIMULATE midpoint is bar-center + (170+12) =
        -- bar-center + 182. So menu midpoint matches.
        --
        -- ea3-39: bar back to 1 row → menu Y offset just above bar
        -- top (-132 bar bottom + 44 bar height + 6 padding gap).
        menu.Position = UDim2.new(0.5, 182, 1, -132 - 44 - 6)
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
            -- opts.bgColor: optional override for the row background.
            -- Used to style the SUPER AUTO row cyan (ea3-39 — Matthew
            -- "only one super auto button, make it under the simulate
            -- menu, cyan"). Disabled rows still use the grey override
            -- so a greyed cyan row doesn't read as enabled.
            local override = opts and opts.bgColor
            b.BackgroundColor3 = enabled
                and (override or Color3.fromRGB(60, 90, 130))
                or Color3.fromRGB(50, 55, 65)
            b.BorderSizePixel = 0
            b.AutoButtonColor = enabled
            b.Text = text
            b.Font = Enum.Font.FredokaOne
            b.TextSize = 16
            -- Cyan rows want darker text for contrast with the bright
            -- cyan; default rows keep the off-white tone.
            b.TextColor3 = enabled
                and (override and Color3.fromRGB(20, 30, 40) or Color3.fromRGB(240, 245, 250))
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

        -- 2026-05-01 ea3-135 menu reorganization. SUPER AUTORUN row
        -- removed — fully superseded by SUPER CURVE × 495 (overnight
        -- 3-Core failure-curve sweep with clean failure points,
        -- per-combo checkpointing, and Phase B TARGETED extras).
        -- The arena-shrinking 1092-combo full coverage that this row
        -- invoked has wave-30 saturation issues at the top of the
        -- field; SUPER CURVE × 495 produces fractional finalWave for
        -- every loadout instead. Old order: SUPER AUTORUN / AUTORUN /
        -- VALIDATE / CURVE / SUPER CURVE / TARGETED / TOWER SUPER /
        -- CORE AUTO / RUN SIM (9 rows). New order shifts everything
        -- up by 1 (8 rows).
        makeRow(1, "AUTORUN", true, function()
            kickAutoRun(function()
                arenaAutorunRemote:FireServer()
            end)
        end, { bgColor = SUPER_AUTO_COLOR })
        -- ea3-53/54 VALIDATE — the FLEX test slot. Per Matthew:
        -- "make it mauve and reconfigure it whenever we can press
        -- it to do a focused test". Default behavior (ea3-53) is a
        -- single-combo arena sweep through all 4 phases (~3-5 min).
        -- Whenever we're iterating on a specific scenario (a tower
        -- balance change, a phase 4 mini-pickle tuning pass, a Core
        -- upgrade-option comparison) the SERVER HANDLER for
        -- arenaValidateRemote (Infinite.lua) gets repointed to
        -- whatever the current focused test is — the button stays,
        -- the wiring inside it changes per session.
        makeRow(2, "VALIDATE", true, function()
            kickAutoRun(function()
                arenaValidateRemote:FireServer()
            end)
        end, { bgColor = VALIDATE_COLOR })
        -- ea3-121: LONG VALIDATE × 8 and SPOT CHECK × 12 removed
        -- per Matthew. The 4-phase scripted-map model both used has
        -- been superseded by FAILURE CURVE × 105 for sim-vs-real
        -- validation; their server handlers stay in place as dead
        -- code (no menu entry to invoke them).
        --
        -- ea3-116 FAILURE CURVE × 105 — wave-1..28 ramping failure-
        -- curve sweep using AutoPlaceStrategy for placement. Replaces
        -- the ea3-115 FAILURE SWEEP stopgap which used the legacy
        -- INFINITE_PATTERN slot table (corner-bias placement, ~25% of
        -- range bulging off-map). v2 places towers where the path
        -- actually winds — sim and live now agree on placement, so
        -- the validator delta isolates true sim-model error rather
        -- than placement variance. Per project_failure_curve_v2.md.
        --
        -- Same queue: 14 solos + C(14,2) = 91 duos = 105 loadouts.
        -- ~45-60 min at 20× game speed (~50s per combo observed).
        makeRow(3, "CURVE × 105", true, function()
            kickAutoRun(function()
                arenaFailureCurveRemote:FireServer()
            end)
        end, { bgColor = VALIDATE_COLOR })
        -- ea3-133/134 SUPER FAILURE CURVE × 495 — two-phase overnight
        -- sweep. Phase A: 3 cores × 105 = 315 (every solo + every
        -- duo per Core). Phase B: TARGETED × 60 per Core = 180
        -- (top worst-|delta| picks per Core, refreshes the loadouts
        -- where sim disagrees most with real). ~6.9 hours; same
        -- wave-1..28 force-failure pipeline throughout, per-combo
        -- checkpointing every 10 combos. Phase B fires AFTER Phase A
        -- regenerates each Core's validator, so it picks the
        -- post-Phase-A worst-|delta| loadouts (which is what
        -- "high info value" means in this codebase per Matthew's
        -- TARGETED framing). VALIDATE color + "× 495" suffix.
        makeRow(4, "SUPER CURVE × 495", true, function()
            kickAutoRun(function()
                arenaSuperFailureCurveRemote:FireServer()
            end)
        end, { bgColor = VALIDATE_COLOR })
        -- ea3-125 TARGETED — server reads the latest validator report
        -- and queues the top-N worst-|delta| combos through the same
        -- wave-1..28 ramp pipeline as FAILURE CURVE × 105. Server
        -- decides whether the press is actionable (no validator
        -- report yet → server warns + no-ops); we always enable the
        -- row client-side so the kick-speed-to-20× behavior fires
        -- consistently and the analyst sees the warn line.
        makeRow(5, "TARGETED × 15", true, function()
            kickAutoRun(function()
                arenaTargetedRemote:FireServer()
            end)
        end, { bgColor = TARGETED_COLOR })
        -- TOWER SUPER reads the player's currently-saved focus aux.
        -- Greyed when no aux is locked. Stays on the OLD broad-sweep
        -- path for now (will port to arena in a follow-up).
        local focusAuxId   = selection.auxIds and selection.auxIds[1]
        local towerSuperEnabled = (focusAuxId ~= nil)
        makeRow(6, "TOWER SUPER AUTO", towerSuperEnabled, function()
            kickAutoRun(function()
                towerSuperRemote:FireServer({ focusAuxId = focusAuxId })
            end)
        end)
        makeRow(7, "CORE AUTO", true, function()
            kickAutoRun(function()
                coreAutoRemote:FireServer()
            end)
        end)
        -- The legacy SELECT AUTO unused-locals gate (kept so picker
        -- close-and-reopen paths still cache selection state).
        local _ = selectAutoEnabled
        local _ = lockedCount
        local _ = slotCount
        local _ = selection
        makeRow(8, "RUN SIM", true, function()
            if simulating then return end
            simulating = true
            simulateBtn.Text = "SIM<font color=\"rgb(255,255,180)\">U</font>LATING…"
            simulateRemote:FireServer()
        end, { keepOpen = true })
    end

    -- ea3-74: SIMULATE button doubles as STOP while a sweep is
    -- running. Workspace.Map4ArenaSweepActive is set true by
    -- ArenaSweepRunner.runOneCombo on entry / cleared on exit;
    -- we watch it and swap text/color/click-handler accordingly.
    -- Per Matthew "turn SIMULATE to STOP when validation is
    -- running" (a 30-min LONG VALIDATE needs an obvious bail-out
    -- if the analyst sees the run is failing fast).
    local arenaStopRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteArenaStop)
    local STOP_COLOR     = Color3.fromRGB(220, 90, 90)
    local SIMULATE_COLOR = Color3.fromRGB(120, 180, 240)
    local SIM_NORMAL_TEXT = 'SIM<font color="rgb(255,255,180)">U</font>LATE'
    local STOP_TEXT       = "STOP"
    local function applySimulateState()
        local sweepActive = Workspace:GetAttribute("Map4ArenaSweepActive") == true
        if sweepActive then
            simulateBtn.Text = STOP_TEXT
            -- ea3-121: route the recolor through setSimulateBaseColor
            -- so the hover handlers' closure-captured base updates too.
            -- Direct BackgroundColor3 assignment got clobbered by the
            -- next MouseLeave (which restored the original blue).
            setSimulateBaseColor(STOP_COLOR)
            -- Drop the dim menu if open so the player isn't fighting
            -- a half-modal on top of a STOP click.
            if simulateMenuGui then closeSimulateMenu() end
        else
            simulateBtn.Text = SIM_NORMAL_TEXT
            setSimulateBaseColor(SIMULATE_COLOR)
        end
    end
    Workspace:GetAttributeChangedSignal("Map4ArenaSweepActive"):Connect(applySimulateState)
    applySimulateState()  -- apply current state on boot

    -- Toggle helper used by both the SIMULATE button click and
    -- the U hotkey (Matthew 2026-04-28). When a sweep is active
    -- the click instead fires the STOP remote.
    local function toggleSimulateMenu()
        if Workspace:GetAttribute("Map4ArenaSweepActive") == true then
            -- STOP click — fire abort + hint at the impending bail.
            arenaStopRemote:FireServer()
            simulateBtn.Text = "STOPPING…"
            return
        end
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
