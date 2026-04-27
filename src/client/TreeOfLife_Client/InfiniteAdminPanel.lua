--[[
    InfiniteAdminPanel.lua — Admin overlay for the Balance Studio.
    Currently a stub with the two reset buttons working; tier displays
    + run-stats dashboard land once persistent run history is wired
    (see project_infinite_arena.md implementation order steps 3 + 5).

    Layout:
      [ TITLE ]                                          [ X ]

      [ RUN RESET ]              wipe current run; no stats recorded
      [ TOTAL RESET ]            confirm modal → erase ALL persistent stats
      [ PER-TOWER WIPE ]         confirm modal per tower (stub for now)

      ──────────────────────────────────────────────────
      RUN STATS                  (placeholder — needs persistent storage)
      TIER LISTS                 (placeholder)

    Persistence isn't there yet, so the section under the divider just
    shows "Stats not yet persistent — coming with run-history step 3".

    setup(deps): builds the modal once + caches it (open()/close()
    just toggle visibility). open() is the public API the button-bar
    calls.
]]

local InfiniteAdminPanel = {}

-- Format relative-time string. completedAt is os.time() seconds.
-- Cheap conversion — minutes-resolution is fine for "when did this
-- finish" context. Module-level so both the history picker and the
-- live renderSweep call it.
local function relTime(secAgo)
    if secAgo < 60 then return "just now" end
    if secAgo < 3600 then return string.format("%d min ago", math.floor(secAgo / 60)) end
    return string.format("%.1f hr ago", secAgo / 3600)
end

local panelGui = nil
-- Tracks playerGui ref so open()/close() can bump the modal counter
-- without re-walking the deps table.
local panelPlayerGui = nil

-- Modal-state count: HUD + button-bar hide when this is > 0. Picker
-- open = +1, close = -1. Admin does the same. Counter pattern
-- survives overlapping modals (e.g. AUTO RUN confirm dialog inside
-- admin panel).
local function bumpModalCount(playerGui, delta)
    local cur = playerGui:GetAttribute("InfiniteModalCount") or 0
    playerGui:SetAttribute("InfiniteModalCount", math.max(0, cur + delta))
end

local function buildPanel(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes

    -- Forward-declared list of currently-open tower-detail modals
    -- (each in its own ScreenGui so panel-drag + Z-stacking work
    -- correctly). Hoisted here so the panel-close handler below
    -- can iterate and destroy them when the user closes the
    -- admin panel.
    local openModalStack = {}

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_InfiniteAdminPanel"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 65
    gui.Enabled = false
    gui.Parent = playerGui

    -- No modal dim — the panel is now draggable + non-blocking so
    -- the player can move it out of the way and keep watching the
    -- arena (Matthew 2026-04-26: "make this moveable"). The window
    -- is anchored top-center on first open; the player can drag it
    -- via the title bar to wherever they want.
    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0)
    panel.Position = UDim2.new(0.5, 0, 0, 60)
    panel.Size = UDim2.fromOffset(720, 660)
    panel.BackgroundColor3 = Color3.fromRGB(28, 24, 18)
    panel.BorderSizePixel = 0
    panel.Parent = gui
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 14)
        corner.Parent = panel
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(220, 180, 80)
        stroke.Thickness = 2.5
        stroke.Parent = panel
    end

    -- Drag handle: invisible Frame covering the title area. Active=
    -- true so it captures input. The X close button + title text
    -- sit on top of it (drawn later, so higher Z), still clickable
    -- because the close button is a TextButton (intercepts its own
    -- input). Drag by clicking-and-holding anywhere on the handle.
    local dragHandle = Instance.new("Frame")
    dragHandle.Size = UDim2.new(1, 0, 0, 60)
    dragHandle.Position = UDim2.fromOffset(0, 0)
    dragHandle.BackgroundTransparency = 1
    dragHandle.Active = true
    dragHandle.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -32, 0, 38)
    title.Position = UDim2.fromOffset(16, 14)
    title.BackgroundTransparency = 1
    title.Text = "BALANCE STUDIO — ADMIN"
    title.Font = Enum.Font.FredokaOne
    title.TextSize = 26
    title.TextColor3 = Color3.fromRGB(255, 220, 140)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    -- Drag wiring. Tracks mouse movement while held; updates panel
    -- Position relative to the start. Works for mouse + touch.
    local UserInputService = game:GetService("UserInputService")
    local dragging, dragStart, startPos = false, nil, nil
    dragHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = panel.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
           and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end)

    local closeBtn = Instance.new("TextButton")
    closeBtn.AnchorPoint = Vector2.new(1, 0)
    closeBtn.Position = UDim2.new(1, -16, 0, 14)
    closeBtn.Size = UDim2.fromOffset(40, 32)
    closeBtn.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
    closeBtn.BorderSizePixel = 0
    closeBtn.AutoButtonColor = false
    closeBtn.Text = "X"
    closeBtn.Font = Enum.Font.FredokaOne
    closeBtn.TextSize = 20
    closeBtn.TextColor3 = Color3.fromRGB(240, 200, 200)
    -- ZIndex above the drag handle (which captures input on the
    -- whole title area) so clicking X actually closes instead of
    -- starting a drag.
    closeBtn.ZIndex = 5
    closeBtn.Parent = panel
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = closeBtn
    end
    closeBtn.MouseButton1Click:Connect(function()
        if gui.Enabled then
            gui.Enabled = false
            bumpModalCount(playerGui, -1)
            -- Tower-detail modals live in separate ScreenGuis (so
            -- panel-drag doesn't drag them); panel-close needs to
            -- explicitly destroy them so they don't outlive the
            -- panel they belong to.
            for _, m in ipairs(table.clone(openModalStack)) do
                if m and m.Parent then m:Destroy() end
            end
        end
    end)

    -- Horizontal button row across the top of the panel. Width
    -- shrunk 160 → 130 per Matthew 2026-04-27 to fit 5 buttons in
    -- the 720-wide panel after VISUALS was added between LOAD RUN
    -- and BALANCE RESET. 5 × 130 + 4 × 12 gap = 698 — fits with
    -- 11px margin each side of the row.
    local BUTTON_ROW_Y     = 58
    local BUTTON_W         = 130
    local BUTTON_H         = 36
    local BUTTON_GAP       = 12
    local function btnXForSlot(slot)
        return 16 + (slot - 1) * (BUTTON_W + BUTTON_GAP)
    end

    local function makeActionBtn(slot, label, color, onClick)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(BUTTON_W, BUTTON_H)
        btn.Position = UDim2.fromOffset(btnXForSlot(slot), BUTTON_ROW_Y)
        btn.BackgroundColor3 = color
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = label
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 16
        btn.TextColor3 = Color3.fromRGB(20, 30, 22)
        btn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = btn
        end
        btn.MouseButton1Click:Connect(onClick)
        return btn
    end

    -- ── Confirm modal helper. Mini overlay parented INSIDE the
    --    admin panel so it stacks visually over the buttons.
    local function showConfirm(message, onConfirm)
        local cgui = Instance.new("Frame")
        cgui.Size = UDim2.fromScale(1, 1)
        cgui.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        cgui.BackgroundTransparency = 0.4
        cgui.BorderSizePixel = 0
        cgui.Parent = panel
        local pcorner = Instance.new("UICorner")
        pcorner.CornerRadius = UDim.new(0, 14)
        pcorner.Parent = cgui

        local box = Instance.new("Frame")
        box.AnchorPoint = Vector2.new(0.5, 0.5)
        box.Position = UDim2.fromScale(0.5, 0.5)
        -- 480 × 360 (was 380 × 200) so the AUTO RUN body text —
        -- 3 loadout-tier rows + difficulty/cap notes — fits without
        -- clipping. Earlier sizing pushed the trio line and the
        -- "wave 30 cap" paragraph behind the CONFIRM/CANCEL row.
        box.Size = UDim2.fromOffset(480, 360)
        box.BackgroundColor3 = Color3.fromRGB(50, 30, 30)
        box.BorderSizePixel = 0
        box.Parent = cgui
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0, 10)
        bc.Parent = box
        local bs = Instance.new("UIStroke")
        bs.Color = Color3.fromRGB(220, 80, 80)
        bs.Thickness = 2.5
        bs.Parent = box

        local mlbl = Instance.new("TextLabel")
        -- Bottom margin = 70 (44 button + 14 padding + 12 buffer)
        -- so the message label can fill the box minus the button row.
        mlbl.Size = UDim2.new(1, -20, 1, -84)
        mlbl.Position = UDim2.fromOffset(10, 14)
        mlbl.BackgroundTransparency = 1
        mlbl.Text = message
        mlbl.Font = Enum.Font.FredokaOne
        mlbl.TextSize = 16
        mlbl.TextColor3 = Color3.fromRGB(240, 220, 220)
        mlbl.TextWrapped = true
        mlbl.TextYAlignment = Enum.TextYAlignment.Top
        mlbl.Parent = box

        local yes = Instance.new("TextButton")
        yes.AnchorPoint = Vector2.new(1, 1)
        yes.Position = UDim2.new(1, -14, 1, -14)
        yes.Size = UDim2.fromOffset(140, 44)
        yes.BackgroundColor3 = Color3.fromRGB(220, 80, 80)
        yes.BorderSizePixel = 0
        yes.AutoButtonColor = false
        yes.Text = "CONFIRM"
        yes.Font = Enum.Font.FredokaOne
        yes.TextSize = 18
        yes.TextColor3 = Color3.fromRGB(30, 20, 20)
        yes.Parent = box
        do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = yes end
        yes.MouseButton1Click:Connect(function()
            cgui:Destroy()
            onConfirm()
        end)

        local no = Instance.new("TextButton")
        no.AnchorPoint = Vector2.new(0, 1)
        no.Position = UDim2.new(0, 14, 1, -14)
        no.Size = UDim2.fromOffset(140, 44)
        no.BackgroundColor3 = Color3.fromRGB(60, 70, 80)
        no.BorderSizePixel = 0
        no.AutoButtonColor = false
        no.Text = "CANCEL"
        no.Font = Enum.Font.FredokaOne
        no.TextSize = 18
        no.TextColor3 = Color3.fromRGB(220, 230, 240)
        no.Parent = box
        do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = no end
        no.MouseButton1Click:Connect(function() cgui:Destroy() end)
    end

    -- Helper that closes the panel and decrements the modal count
    -- exactly once. The action buttons below use this instead of
    -- raw `gui.Enabled = false` so the count stays balanced.
    local function closePanel()
        if gui.Enabled then
            gui.Enabled = false
            bumpModalCount(playerGui, -1)
        end
    end

    -- ── AUTO RUN (slot 1) — kick off the full benchmark sweep.
    --    While a sweep is in progress this button morphs to
    --    MONITOR; clicking it then opens the live-stats window.
    --    First in row so the most-frequent action is leftmost.
    local MonitorWindow = require(script.Parent:WaitForChild("InfiniteMonitorWindow"))
    local autoRunRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRun)
    local autoRunBtnState = "AUTO_RUN"
    local autoRunBtn  -- assigned below
    autoRunBtn = makeActionBtn(1, "AUTO RUN", Color3.fromRGB(120, 220, 140), function()
        if autoRunBtnState == "MONITOR" then
            -- Per Matthew 2026-04-27: "don't close balance studio
            -- admin window when you open up monitor." Open the
            -- monitor as a side panel; admin panel stays put.
            MonitorWindow.open()
            return
        end
        showConfirm(
            "AUTO RUN — benchmark sweep\n\n"
            .. "Runs every loadout permutation (81 runs total):\n"
            .. "  • 9 solos  (Power + 1 aux)                  @ 1.00×\n"
            .. "  • 36 duos  (Power + 2 aux)                  @ 1.25×\n"
            .. "  • 36 trios (Power + 2 aux + InfiniteStandard) @ 1.60×\n\n"
            .. "InfiniteStandard is a Core-like baseline only in "
            .. "trios (clone of AcornSniper). Each tower lands in "
            .. "17 stat runs — symmetric across all 9 aux.\n\n"
            .. "Each run goes until heart death or wave 30 cap. "
            .. "Cumulative tier list builds across sweeps until "
            .. "BALANCE RESET.",
            function()
                closePanel()
                autoRunRemote:FireServer()
            end)
    end)
    -- Listen for sweep state to morph the button.
    local autoRunProgressRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunProgress)
    autoRunProgressRemote.OnClientEvent:Connect(function()
        if autoRunBtnState ~= "MONITOR" then
            autoRunBtnState = "MONITOR"
            autoRunBtn.Text = "MONITOR"
            autoRunBtn.BackgroundColor3 = Color3.fromRGB(220, 180, 80)
        end
    end)
    local autoRunDoneRemote2 = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunDone)
    autoRunDoneRemote2.OnClientEvent:Connect(function()
        autoRunBtnState = "AUTO_RUN"
        autoRunBtn.Text = "AUTO RUN"
        autoRunBtn.BackgroundColor3 = Color3.fromRGB(120, 220, 140)
    end)

    -- ── LOAD RUNS — pull a past balance ERA from DataStore-backed
    --    history. Each row groups every sweep that ran under a
    --    given balanceVersion; clicking loads the full era's
    --    runs into the tier list via InfiniteLastSweepData. Per
    --    Matthew 2026-04-27: "change LOAD RUN to LOAD RUNS and
    --    have it load all runs from a given balance change."
    local sweepHistoryReqRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteRequestSweepHistory)
    local sweepHistoryDataRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteSweepHistoryData)
    local loadByVersionRemote    = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteLoadByBalanceVersion)

    local function showHistoryPicker(versionGroups, currentBalanceVersion)
        versionGroups = versionGroups or {}
        local existing = panel:FindFirstChild("HistoryPickerModal")
        if existing then existing:Destroy() end

        local modal = Instance.new("Frame")
        modal.Name = "HistoryPickerModal"
        modal.AnchorPoint = Vector2.new(0.5, 0.5)
        modal.Position = UDim2.fromScale(0.5, 0.5)
        modal.Size = UDim2.fromOffset(520, 480)
        modal.BackgroundColor3 = Color3.fromRGB(28, 24, 18)
        modal.BorderSizePixel = 0
        modal.ZIndex = 10
        -- Parented to gui (not panel) so panel-drag doesn't drag the
        -- LOAD RUNS picker. Per Matthew 2026-04-27.
        modal.Parent = gui
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 12)
            c.Parent = modal
            local s = Instance.new("UIStroke")
            s.Color = Color3.fromRGB(120, 180, 220)
            s.Thickness = 2
            s.Parent = modal
        end

        local titleLbl = Instance.new("TextLabel")
        titleLbl.Size = UDim2.new(1, -64, 0, 32)
        titleLbl.Position = UDim2.fromOffset(16, 14)
        titleLbl.BackgroundTransparency = 1
        titleLbl.Text = "LOAD PAST RUNS  —  by balance era"
        titleLbl.Font = Enum.Font.FredokaOne
        titleLbl.TextSize = 22
        titleLbl.TextColor3 = Color3.fromRGB(180, 220, 255)
        titleLbl.TextXAlignment = Enum.TextXAlignment.Left
        titleLbl.ZIndex = 11
        titleLbl.Parent = modal

        local closeBtn = Instance.new("TextButton")
        closeBtn.AnchorPoint = Vector2.new(1, 0)
        closeBtn.Position = UDim2.new(1, -16, 0, 14)
        closeBtn.Size = UDim2.fromOffset(36, 32)
        closeBtn.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
        closeBtn.BorderSizePixel = 0
        closeBtn.AutoButtonColor = false
        closeBtn.Text = "X"
        closeBtn.Font = Enum.Font.FredokaOne
        closeBtn.TextSize = 18
        closeBtn.TextColor3 = Color3.fromRGB(240, 200, 200)
        closeBtn.ZIndex = 12
        closeBtn.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = closeBtn
        end
        closeBtn.MouseButton1Click:Connect(function() modal:Destroy() end)

        -- Header hint: "N era(s) on file (newest first). Active = vM."
        local totalRuns = 0
        for _, g in ipairs(versionGroups) do
            totalRuns = totalRuns + (g.totalRuns or 0)
        end
        local hint = Instance.new("TextLabel")
        hint.Size = UDim2.new(1, -32, 0, 18)
        hint.Position = UDim2.fromOffset(16, 50)
        hint.BackgroundTransparency = 1
        hint.Text = ("%d era(s) on file  •  %d total run(s)  •  active = v%s. Click an era to load.")
            :format(#versionGroups, totalRuns, tostring(currentBalanceVersion or "?"))
        hint.Font = Enum.Font.Gotham
        hint.TextSize = 12
        hint.TextColor3 = Color3.fromRGB(180, 200, 200)
        hint.TextXAlignment = Enum.TextXAlignment.Left
        hint.ZIndex = 11
        hint.Parent = modal

        local listScroll = Instance.new("ScrollingFrame")
        listScroll.Size = UDim2.new(1, -32, 0, 396)
        listScroll.Position = UDim2.fromOffset(16, 74)
        listScroll.BackgroundColor3 = Color3.fromRGB(14, 18, 14)
        listScroll.BorderSizePixel = 0
        listScroll.ScrollBarThickness = 6
        listScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        listScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        listScroll.ZIndex = 11
        listScroll.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = listScroll
            local lay = Instance.new("UIListLayout")
            lay.FillDirection = Enum.FillDirection.Vertical
            lay.Padding = UDim.new(0, 2)
            lay.SortOrder = Enum.SortOrder.LayoutOrder
            lay.Parent = listScroll
        end

        if #versionGroups == 0 then
            local empty = Instance.new("TextLabel")
            empty.Size = UDim2.new(1, -8, 0, 32)
            empty.BackgroundTransparency = 1
            empty.Text = "  (no past balance eras on file)"
            empty.Font = Enum.Font.Gotham
            empty.TextSize = 13
            empty.TextColor3 = Color3.fromRGB(140, 140, 140)
            empty.TextXAlignment = Enum.TextXAlignment.Left
            empty.ZIndex = 12
            empty.Parent = listScroll
        else
            for orderIdx, g in ipairs(versionGroups) do
                local newestAgo = math.max(0, os.time() - (g.newestAt or 0))
                local isActive  = (g.balanceVersion == currentBalanceVersion)
                local row = Instance.new("TextButton")
                row.Size = UDim2.new(1, -8, 0, 44)
                row.BackgroundColor3 = isActive
                    and Color3.fromRGB(28, 40, 28)
                    or Color3.fromRGB(20, 30, 24)
                row.BorderSizePixel = 0
                row.AutoButtonColor = false
                row.Text = ""
                row.LayoutOrder = orderIdx
                row.ZIndex = 11
                row.Parent = listScroll
                do
                    local c = Instance.new("UICorner")
                    c.CornerRadius = UDim.new(0, 4)
                    c.Parent = row
                    if isActive then
                        local s = Instance.new("UIStroke")
                        s.Color = Color3.fromRGB(180, 220, 120)
                        s.Thickness = 1.5
                        s.Parent = row
                    end
                end
                local lbl = Instance.new("TextLabel")
                lbl.Size = UDim2.new(1, -16, 1, 0)
                lbl.Position = UDim2.fromOffset(8, 0)
                lbl.BackgroundTransparency = 1
                lbl.RichText = true
                lbl.Text = string.format(
                    '<b>Balance v%d</b>%s   <font color="rgb(180,200,200)">— %d sweep(s), %d run(s)%s — newest %s</font>',
                    g.balanceVersion or 0,
                    isActive and "  <font color=\"rgb(180,220,120)\">(active)</font>" or "",
                    g.sweepCount or 0,
                    g.totalRuns or 0,
                    g.anyAborted and " (some ABORTED)" or "",
                    relTime(newestAgo))
                lbl.Font = Enum.Font.GothamBold
                lbl.TextSize = 13
                lbl.TextColor3 = Color3.fromRGB(220, 240, 220)
                lbl.TextXAlignment = Enum.TextXAlignment.Left
                lbl.TextYAlignment = Enum.TextYAlignment.Center
                lbl.ZIndex = 12
                lbl.Parent = row

                local restingBg = row.BackgroundColor3
                row.MouseEnter:Connect(function()
                    row.BackgroundColor3 = Color3.fromRGB(60, 80, 60)
                end)
                row.MouseLeave:Connect(function()
                    row.BackgroundColor3 = restingBg
                end)
                row.MouseButton1Click:Connect(function()
                    loadByVersionRemote:FireServer({ balanceVersion = g.balanceVersion })
                    modal:Destroy()
                end)
            end
        end
    end

    sweepHistoryDataRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        showHistoryPicker(payload.versionGroups or {}, payload.currentBalanceVersion)
    end)

    -- ── LOAD RUNS / ALL RUNS (slot 2) — morphing button. Default
    --    label is LOAD RUNS: opens the balance-era picker (one row
    --    per balanceVersion). Once a past era is loaded, the
    --    button morphs to ALL RUNS — clicking it switches the
    --    tier-list display back to the active-era cumulative
    --    aggregate (default view). Per Matthew 2026-04-27:
    --    "change LOAD RUN to LOAD RUNS and have it load all runs
    --    from a given balance change."
    local lastSweepReqRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteRequestLastSweep)
    local loadRunBtnState = "LOAD"  -- "LOAD" | "ALL_RUNS"
    local loadRunBtn  -- assigned below
    loadRunBtn = makeActionBtn(2, "LOAD RUNS", Color3.fromRGB(120, 180, 220), function()
        if loadRunBtnState == "ALL_RUNS" then
            -- Switch back to cumulative view.
            lastSweepReqRemote:FireServer()
            -- The lastSweepDataRemote handler renders + the post-
            -- render code below morphs the button back to LOAD.
            return
        end
        sweepHistoryReqRemote:FireServer()
    end)
    -- Helpers for the morph (used by sweepLoaded handler below).
    local function morphLoadRunToAllRuns()
        if loadRunBtnState ~= "ALL_RUNS" then
            loadRunBtnState = "ALL_RUNS"
            loadRunBtn.Text = "ALL RUNS"
            loadRunBtn.BackgroundColor3 = Color3.fromRGB(180, 220, 120)
        end
    end
    local function morphAllRunsToLoad()
        if loadRunBtnState ~= "LOAD" then
            loadRunBtnState = "LOAD"
            loadRunBtn.Text = "LOAD RUNS"
            loadRunBtn.BackgroundColor3 = Color3.fromRGB(120, 180, 220)
        end
    end

    -- ── EXPORT DATA (slot 3) — fires InfiniteExportData; server
    --    replies with a JSON payload that we (a) print to F9 and
    --    (b) show in a copyable TextBox modal. Per Matthew
    --    2026-04-27: "remove the visuals button (now that it's
    --    tied to speed) and move the export data button there."
    --    VISUALS auto-toggles based on game speed (≤20 ON, ≥50
    --    OFF) so the dedicated button is no longer needed.
    local exportRemote      = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteExportData)
    local exportReadyRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteExportDataReady)
    local exportBtn  -- forward-decl so the click handler upvalue resolves
    exportBtn = makeActionBtn(3, "EXPORT DATA", Color3.fromRGB(120, 180, 240), function()
        exportBtn.Text = "EXPORTING…"
        exportRemote:FireServer()
    end)

    -- ── BALANCE RESET (slot 4) — wipes the cumulative tier-list
    --    aggregate so the next sweep restarts the per-tower stat
    --    pool from zero, AND bumps the balance-version counter so
    --    subsequent sweeps form a new era. Doesn't touch
    --    DataStore-backed history (LOAD RUNS can still pull older
    --    eras as their own rows). Per Matthew 2026-04-27: "every
    --    time balance reset is used increase the balance version
    --    # and start a new row."
    local balanceResetRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteBalanceReset)
    makeActionBtn(4, "BALANCE RESET", Color3.fromRGB(220, 130, 100), function()
        showConfirm(
            "BALANCE RESET\n\n"
            .. "Wipe the cumulative tier-list pool AND bump the "
            .. "balance version. Past sweeps stay grouped under "
            .. "their old version in LOAD RUNS. New sweeps after "
            .. "this start a fresh balance era.",
            function()
                balanceResetRemote:FireServer()
            end)
    end)

    -- ── TOTAL RESET (slot 5) — confirm modal then fires the reset.
    local totalResetRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteTotalReset)
    makeActionBtn(5, "TOTAL RESET", Color3.fromRGB(220, 80, 80), function()
        showConfirm(
            "TOTAL RESET\n\nErase ALL Balance Studio stats from "
            .. "inception. This can't be undone.\n\n"
            .. "Wipes BOTH the in-session cumulative pool AND every "
            .. "saved sweep in DataStore (LOAD RUNS history).",
            function()
                totalResetRemote:FireServer()
            end)
    end)

    -- Divider sits just below the horizontal button row. Layout
    -- reclaim: the old vertical 4-button stack ate y=58..210; the
    -- horizontal row takes y=58..94, freeing ~110px of vertical
    -- space that the tier list area below now uses. Per Matthew
    -- 2026-04-26: "and move everything else up."
    local divider = Instance.new("Frame")
    divider.Size = UDim2.new(1, -32, 0, 1)
    divider.Position = UDim2.fromOffset(16, 110)
    divider.BackgroundColor3 = Color3.fromRGB(80, 70, 50)
    divider.BorderSizePixel = 0
    divider.Parent = panel

    -- ── Stats display ────────────────────────────────────────────
    -- Reads in-session cache from the server. Re-fetches on every
    -- open() so a sweep that completes while the panel is closed
    -- still surfaces here next time it opens. Persistent DataStore
    -- backing is a future step (project_infinite_arena.md step 3).
    local statsTitle = Instance.new("TextLabel")
    statsTitle.Size = UDim2.new(1, -32, 0, 28)
    statsTitle.Position = UDim2.fromOffset(16, 122)
    statsTitle.BackgroundTransparency = 1
    statsTitle.Text = "RUN STATS  +  TIER LISTS"
    statsTitle.Font = Enum.Font.FredokaOne
    statsTitle.TextSize = 18
    statsTitle.TextColor3 = Color3.fromRGB(255, 200, 140)
    statsTitle.TextXAlignment = Enum.TextXAlignment.Left
    statsTitle.Parent = panel

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -32, 0, 20)
    statusLabel.Position = UDim2.fromOffset(16, 150)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "(loading...)"
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 13
    statusLabel.TextColor3 = Color3.fromRGB(180, 200, 180)
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = panel

    -- Tier list area: 3 role columns side-by-side. Each column's
    -- header is role-color-tinted; each row shows tier letter +
    -- tower name + avg wave.
    --
    -- Tier colors map to the project's shared rarity palette
    -- (Common gray / Rare blue / Exceptional purple / Legendary
    -- orange / Mythical pink). Matches upgrade cards, attachments,
    -- and tower-card pickers — DO NOT invent new tier colors here.
    -- Source of truth: TempTowers.RarityColors. Only 5 rarities
    -- but 6 tiers, so F gets a dimmer gray below Common.
    local Shared = ReplicatedStorage:WaitForChild("Shared")
    local TempTowers = require(Shared:WaitForChild("TempTowers"))
    local TIER_COLORS = {
        S = TempTowers.RarityColors.Mythical,    -- pink
        A = TempTowers.RarityColors.Legendary,   -- orange
        B = TempTowers.RarityColors.Exceptional, -- purple
        C = TempTowers.RarityColors.Rare,        -- blue
        D = TempTowers.RarityColors.Common,      -- gray
        F = Color3.fromRGB(110, 110, 110),       -- dim gray below Common
    }
    local ROLE_COLORS = {
        DPS     = Color3.fromRGB(220, 90, 90),
        Control = Color3.fromRGB(180, 100, 230),
        Support = Color3.fromRGB(80, 180, 240),
    }

    -- Tier-list frame shifted up to follow the divider/title block
    -- (was y=288 in the vertical-button layout, now y=176 to match
    -- the compressed top section). Heightened to fill the freed
    -- space so the columns have room for full slates.
    local tierFrame = Instance.new("Frame")
    tierFrame.Size = UDim2.new(1, -32, 0, 312)
    tierFrame.Position = UDim2.fromOffset(16, 176)
    tierFrame.BackgroundTransparency = 1
    tierFrame.Parent = panel

    local function clearChildren(p)
        for _, c in ipairs(p:GetChildren()) do
            if c:IsA("GuiObject") then c:Destroy() end
        end
    end

    -- Latest results data, captured each time renderSweep fires.
    -- The tower-detail popup reads this to filter runs containing
    -- the clicked tower. Per Matthew 2026-04-26: "can i make the
    -- tower names clickable to pop up windows with more detailed
    -- stats?"
    local latestResults = nil

    -- Capture median avgWave across all towers in the latest sweep
    -- so the balance verdict can compare a single tower against
    -- the slate. Set inside renderTiers (when fresh sweep data
    -- lands), used inside showTowerDetail.
    local sweepMedianAvgWave = 0

    -- Multi-modal state. Per Matthew 2026-04-27: "make this window
    -- moveable, and allow me to open multiple windows for different
    -- towers." Each modal is a draggable Frame; the stack holds them
    -- in MOST-RECENTLY-OPENED-FIRST order so Q closes the topmost.
    --   • dedup by tower — clicking AcornSniper's row twice doesn't
    --     stack two AcornSniper popups; the existing one bumps to top.
    --   • cascade positioning — each new modal opens 30px down/right
    --     from center, mod-wrapped at 6 so they don't drift off-screen.
    --   • bringToFront — clicking anywhere inside a modal raises its
    --     ZIndex so dragging two overlapping modals keeps the active
    --     one on top.
    -- Multi-modal architecture: each tower-detail modal lives in
    -- its OWN ScreenGui with a unique DisplayOrder. ScreenGui
    -- DisplayOrder is GLOBAL across all GUIs — higher = entirely
    -- on top of lower, with NO cross-tree ZIndex leak. Per Matthew
    -- 2026-04-27: with all modals sharing one ScreenGui (Sibling
    -- ZIndexBehavior), children at Z=11/12 of the back modal
    -- leaked through the front modal's bg at Z=10. Separate
    -- ScreenGuis sidestep that — each modal's internal layout
    -- stays untouched, only the ScreenGui DisplayOrder changes.
    -- (openModalStack forward-declared at the top of buildPanel
    -- so the panel-close handler can clean it up.)
    local MODAL_DISPLAY_ORDER = 100  -- starting DisplayOrder for first modal
    local nextDisplayOrder = MODAL_DISPLAY_ORDER

    local function bringToFront(modal)
        -- Bump THIS modal's ScreenGui to the highest DisplayOrder
        -- so its entire subtree renders above every other modal's
        -- subtree. ScreenGui Active = its parent ScreenGui in
        -- Roblox parlance (the modal is parented to the ScreenGui).
        local screenGui = modal.Parent
        if screenGui and screenGui:IsA("ScreenGui") then
            nextDisplayOrder = nextDisplayOrder + 1
            screenGui.DisplayOrder = nextDisplayOrder
        end
        -- Move to top of the open-stack so Q closes this one first.
        for i, m in ipairs(openModalStack) do
            if m == modal then
                table.remove(openModalStack, i)
                break
            end
        end
        table.insert(openModalStack, 1, modal)
    end

    -- Build the per-tower detail popup. Filters latestResults to
    -- runs containing the tower, then renders summary stats, a
    -- table-formatted per-run breakdown, balance verdict, and a
    -- tuning suggestion.
    local function showTowerDetail(towerId, role, tier, avgWave)
        -- Per-tower dedup: re-clicking the same tower's row brings the
        -- existing modal to the front rather than stacking duplicates.
        local existingName = "TowerDetail_" .. towerId
        for _, m in ipairs(openModalStack) do
            if m.Parent and m.Name == existingName then
                bringToFront(m)
                return
            end
        end

        local matchingRuns = {}
        if latestResults then
            for _, r in ipairs(latestResults) do
                local hit = (towerId == "Power")  -- Power is in every run
                if not hit and type(r.auxIds) == "table" then
                    for _, id in ipairs(r.auxIds) do
                        if id == towerId then hit = true; break end
                    end
                end
                -- Exclude AcornSniper-anchor trio runs from
                -- AcornSniper's own detail view — those 28 runs are
                -- standardization (third aux slot) not tests of
                -- AcornSniper itself. Mirrors the server-side
                -- assembleTiers exclusion. Per Matthew 2026-04-26:
                -- "remove acornsniper trio runs from stats... they're
                -- there just to standardize."
                if hit and towerId == "InfiniteStandard"
                   and type(r.auxIds) == "table" and #r.auxIds >= 3 then
                    hit = false
                end
                if hit then table.insert(matchingRuns, r) end
            end
        end
        table.sort(matchingRuns, function(a, b)
            return (a.finalWave or 0) > (b.finalWave or 0)
        end)

        -- Compute aggregate stats.
        local bestWave, worstWave = 0, math.huge
        local byType = {}  -- testType → { count, sum }
        for _, r in ipairs(matchingRuns) do
            local fw = r.finalWave or 0
            if fw > bestWave then bestWave = fw end
            if fw < worstWave then worstWave = fw end
            local t = r.testType or "?"
            byType[t] = byType[t] or { count = 0, sum = 0 }
            byType[t].count = byType[t].count + 1
            byType[t].sum   = byType[t].sum + fw
        end
        if worstWave == math.huge then worstWave = 0 end

        -- Cascade position: each new modal opens 80px down/right
        -- from screen center, mod-wrapped at 4. Each modal lives
        -- in its OWN ScreenGui (NOT the admin panel) so dragging
        -- the panel doesn't move them AND so each modal renders
        -- in its own DisplayOrder layer (no Z-leak from back modals'
        -- children through front modals' bg).
        local cascade = (#openModalStack % 4) * 80

        nextDisplayOrder = nextDisplayOrder + 1
        local modalGui = Instance.new("ScreenGui")
        modalGui.Name = "ToL_" .. existingName
        modalGui.IgnoreGuiInset = true
        modalGui.ResetOnSpawn = false
        modalGui.DisplayOrder = nextDisplayOrder
        modalGui.Parent = playerGui

        local modal = Instance.new("Frame")
        modal.Name = existingName  -- "TowerDetail_<towerId>" for dedup
        modal.AnchorPoint = Vector2.new(0.5, 0.5)
        modal.Position = UDim2.new(0.5, cascade, 0.5, cascade)
        modal.Size = UDim2.fromOffset(560, 580)
        modal.BackgroundColor3 = Color3.fromRGB(28, 24, 18)
        modal.BorderSizePixel = 0
        modal.ClipsDescendants = false
        -- Active = true so the modal absorbs clicks that fall on its
        -- own bg or non-absorbing children, preventing click-through
        -- to whatever GUI is underneath.
        modal.Active = true
        modal.ZIndex = 10  -- baseline; children at 11/12 sit above
        modal.Parent = modalGui
        table.insert(openModalStack, 1, modal)
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 12)
            c.Parent = modal
            local s = Instance.new("UIStroke")
            s.Color = TIER_COLORS[tier] or Color3.fromRGB(220, 180, 80)
            s.Thickness = 2.5
            s.Parent = modal
        end

        -- Auto-cleanup from the open stack when modal goes away
        -- (clicked CLOSE, Q-pressed, or panel closes / replaces it).
        -- Also destroys the wrapping ScreenGui so we don't leak
        -- empty per-modal GUIs in PlayerGui.
        modal.AncestryChanged:Connect(function()
            if not modal.Parent then
                for i, m in ipairs(openModalStack) do
                    if m == modal then
                        table.remove(openModalStack, i)
                        break
                    end
                end
                if modalGui and modalGui.Parent then
                    modalGui:Destroy()
                end
            end
        end)

        -- (Removed full-modal focusCatch TextButton — its empty
        -- ZIndex-10 hit area was masking child label content
        -- visibility per Matthew 2026-04-27 screenshot bug. The
        -- dragBar at the top of the modal handles bringToFront
        -- via its own InputBegan listener, so focus-on-click on
        -- the title-area still works.)

        -- Title block (two rows):
        --   Row 1: tower name (big, left) + CLOSE [Q] + i (right)
        --   Row 2: role label + tier + avg-wave stats — bottom flush
        --   with the CLOSE button (closeBtn bottom = y=14+32=46).
        -- Per Matthew 2026-04-27 second pass: title nudged up
        -- slightly; role / tier separated by a fixed gap via
        -- horizontal UIListLayout so "Control" doesn't overflow
        -- into "A tier"; avg wave dropped its decimal.
        local titleLbl = Instance.new("TextLabel")
        titleLbl.Size = UDim2.fromOffset(280, 26)
        titleLbl.Position = UDim2.fromOffset(16, 4)
        titleLbl.BackgroundTransparency = 1
        titleLbl.Text = towerId
        titleLbl.Font = Enum.Font.FredokaOne
        titleLbl.TextSize = 24
        titleLbl.TextColor3 = Color3.fromRGB(255, 240, 200)
        titleLbl.TextXAlignment = Enum.TextXAlignment.Left
        titleLbl.TextYAlignment = Enum.TextYAlignment.Center
        titleLbl.ZIndex = 11
        titleLbl.Parent = modal

        -- Header row: role label + tier-stats line, side by side via
        -- a horizontal UIListLayout. The 10px Padding gives a clean,
        -- consistent gap between the role text and the tier text
        -- regardless of role length (DPS / Control / Support all
        -- look the same). Bottom of row at y=46 = closeBtn bottom.
        local headerRow = Instance.new("Frame")
        headerRow.Size = UDim2.new(1, -32, 0, 18)
        headerRow.Position = UDim2.fromOffset(16, 28)
        headerRow.BackgroundTransparency = 1
        headerRow.ZIndex = 11
        headerRow.Parent = modal
        do
            local hl = Instance.new("UIListLayout")
            hl.FillDirection = Enum.FillDirection.Horizontal
            hl.Padding = UDim.new(0, 10)  -- fixed gap between role and tier
            hl.VerticalAlignment = Enum.VerticalAlignment.Center
            hl.SortOrder = Enum.SortOrder.LayoutOrder
            hl.Parent = headerRow
        end

        local subLbl = Instance.new("TextLabel")
        subLbl.AutomaticSize = Enum.AutomaticSize.X  -- fits role text exactly
        subLbl.Size = UDim2.fromOffset(0, 18)
        subLbl.BackgroundTransparency = 1
        subLbl.Text = role
        subLbl.Font = Enum.Font.GothamBold
        subLbl.TextSize = 14
        subLbl.TextColor3 = ROLE_COLORS[role] or Color3.fromRGB(220, 220, 220)
        subLbl.TextXAlignment = Enum.TextXAlignment.Left
        subLbl.TextYAlignment = Enum.TextYAlignment.Center
        subLbl.LayoutOrder = 1
        subLbl.ZIndex = 11
        subLbl.Parent = headerRow

        -- Per Matthew 2026-04-27: SS arrow next to "A tier" was a
        -- *move* indicator, not a strikethrough — tier label belongs
        -- on the stats line. Format: "A tier  Avg wave: N  Runs: N
        -- Best: N  Worst: N". Avg wave uses %d (no decimal) per
        -- 2026-04-27 second pass.
        local tierColor = TIER_COLORS[tier] or Color3.fromRGB(220, 220, 220)
        local tierHex = string.format("rgb(%d,%d,%d)",
            math.floor(tierColor.R * 255 + 0.5),
            math.floor(tierColor.G * 255 + 0.5),
            math.floor(tierColor.B * 255 + 0.5))
        local statsStrip = Instance.new("TextLabel")
        statsStrip.AutomaticSize = Enum.AutomaticSize.X
        statsStrip.Size = UDim2.fromOffset(0, 18)
        statsStrip.BackgroundTransparency = 1
        statsStrip.RichText = true
        statsStrip.Text = string.format(
            '<font color="%s"><b>%s tier</b></font>   Avg wave: <b>%d</b>   Runs: <b>%d</b>   Best: <b>%d</b>   Worst: <b>%d</b>',
            tierHex, tostring(tier or "?"),
            math.floor((avgWave or 0) + 0.5), #matchingRuns, bestWave, worstWave)
        statsStrip.Font = Enum.Font.Gotham
        statsStrip.TextSize = 13
        statsStrip.TextColor3 = Color3.fromRGB(220, 230, 220)
        statsStrip.TextXAlignment = Enum.TextXAlignment.Left
        statsStrip.TextYAlignment = Enum.TextYAlignment.Center
        statsStrip.LayoutOrder = 2
        statsStrip.ZIndex = 11
        statsStrip.Parent = headerRow

        -- Top-right cluster: CLOSE [Q] + circular "i" info icon,
        -- mirroring the SS1 layout the user pointed to. Q hotkey
        -- closes the modal; "i" opens an info card with the
        -- tower's role / archetype thought / base stats.
        local closeBtn = Instance.new("TextButton")
        closeBtn.AnchorPoint = Vector2.new(1, 0)
        closeBtn.Position = UDim2.new(1, -56, 0, 14)
        closeBtn.Size = UDim2.fromOffset(110, 32)
        closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
        closeBtn.BorderSizePixel = 0
        closeBtn.AutoButtonColor = true
        closeBtn.RichText = true
        closeBtn.Text = 'CLOSE <font color="rgb(255,230,80)">[Q]</font>'
        closeBtn.Font = Enum.Font.FredokaOne
        closeBtn.TextSize = 16
        closeBtn.TextColor3 = Color3.fromRGB(245, 230, 230)
        closeBtn.ZIndex = 12
        closeBtn.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = closeBtn
        end
        closeBtn.MouseButton1Click:Connect(function() modal:Destroy() end)

        local infoBtn = Instance.new("TextButton")
        infoBtn.AnchorPoint = Vector2.new(1, 0)
        infoBtn.Position = UDim2.new(1, -16, 0, 14)
        infoBtn.Size = UDim2.fromOffset(32, 32)
        infoBtn.BackgroundColor3 = Color3.fromRGB(80, 140, 220)
        infoBtn.BorderSizePixel = 0
        infoBtn.AutoButtonColor = true
        infoBtn.Text = "i"
        infoBtn.Font = Enum.Font.FredokaOne
        infoBtn.TextSize = 18
        infoBtn.TextColor3 = Color3.fromRGB(240, 245, 255)
        infoBtn.ZIndex = 12
        infoBtn.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(1, 0)  -- circular
            c.Parent = infoBtn
        end

        -- Q hotkey closes the TOPMOST modal (= the one most recently
        -- opened or focused). With multiple modals open, Q peeling
        -- them off in MRU order is the natural behavior. Each modal
        -- registers its own Q listener; the listener checks whether
        -- THIS modal is currently #1 in the stack and only closes if
        -- so. Modals popped from the stack on destroy via the
        -- AncestryChanged hook above; the next modal becomes the new
        -- topmost target for Q.
        local UIS = game:GetService("UserInputService")
        local closeConn
        closeConn = UIS.InputBegan:Connect(function(input, gameProcessed)
            if gameProcessed then return end
            if input.KeyCode == Enum.KeyCode.Q then
                if modal.Parent and openModalStack[1] == modal then
                    modal:Destroy()
                end
            end
        end)
        modal.AncestryChanged:Connect(function()
            if not modal.Parent and closeConn then
                closeConn:Disconnect()
                closeConn = nil
            end
        end)

        -- DRAG: title-area "drag bar" — a transparent Frame across
        -- the top 50px of the modal, BELOW the close / info buttons
        -- (lower ZIndex so they still receive clicks). Mouse-down
        -- starts a drag, mouse-move tracks delta via
        -- UserInputService, mouse-up ends. Per Matthew 2026-04-27:
        -- "make this window moveable."
        --
        -- Switched from TextButton → Frame per Matthew 2026-04-27
        -- "still blank" report: a transparent TextButton at full
        -- modal-area Z-10 was suspected of masking child rendering.
        -- A plain Frame with InputBegan still registers click events
        -- (via UserInputService routing through to the topmost Gui)
        -- but doesn't carry TextButton's input-absorbing semantics.
        local dragBar = Instance.new("Frame")
        dragBar.Size = UDim2.new(1, 0, 0, 50)
        dragBar.Position = UDim2.fromOffset(0, 0)
        dragBar.BackgroundTransparency = 1
        dragBar.Active = true  -- so InputBegan fires for mouse events
        -- ZIndex 11 = above title/sub/stats labels (also at 11) but
        -- since dragBar is parented LATER in sibling order, equal-Z
        -- ties break in dragBar's favor for input routing. closeBtn
        -- + infoBtn (Z=12) still win in their pixel area. The bumped
        -- Z (was 10) makes dragBar win against title labels which
        -- don't absorb input — without this, clicks on the title
        -- text passed through to the panel's drag-handle underneath
        -- and dragged the WHOLE PANEL.
        dragBar.ZIndex = 11
        dragBar.Parent = modal
        do
            -- Drag pattern (corrected per 2026-04-27 "still can't drag"
            -- bug): the first version compared `input == dragInput`
            -- where dragInput was set to the MouseButton1 InputBegan
            -- event, but UIS.InputChanged fires for MouseMovement —
            -- different InputObjects, comparison ALWAYS false, drag
            -- never moved.
            -- Standard Roblox pattern: a `dragging` boolean toggled by
            -- InputBegan/Ended on the drag bar, plus UIS.InputChanged
            -- watching for MouseMovement / Touch events globally so
            -- the drag works even when the cursor leaves the drag-bar
            -- area mid-drag.
            local dragging = false
            local dragStart, startPos
            local moveConn, endConn
            dragBar.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1
                   or input.UserInputType == Enum.UserInputType.Touch then
                    dragging  = true
                    dragStart = input.Position
                    startPos  = modal.Position
                    bringToFront(modal)  -- click-to-focus too
                end
            end)
            moveConn = UIS.InputChanged:Connect(function(input)
                if not dragging then return end
                if input.UserInputType ~= Enum.UserInputType.MouseMovement
                   and input.UserInputType ~= Enum.UserInputType.Touch then
                    return
                end
                local delta = input.Position - dragStart
                modal.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end)
            endConn = UIS.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1
                   or input.UserInputType == Enum.UserInputType.Touch then
                    dragging = false
                end
            end)
            modal.AncestryChanged:Connect(function()
                if not modal.Parent then
                    if moveConn then moveConn:Disconnect(); moveConn = nil end
                    if endConn  then endConn:Disconnect();  endConn  = nil end
                end
            end)
        end

        -- Info card popup — visually matches the story-mode TowerCard
        -- (rarity-tinted title, description, STATS section, MECHANIC
        -- section). Per Matthew 2026-04-27 SS3: "tower info card on
        -- infinite still needs to match info card from game mode."
        -- Differences from TowerCard.lua: no live-tower attributes
        -- (admin has no upgrade state) so STATS show base values
        -- only — matching the SS3 visual shape but without the green
        -- (modified) parens. MECHANIC uses TempTowers.resolveStats at
        -- Rare rarity (= identity multipliers) so per-template values
        -- appear unscaled.
        infoBtn.MouseButton1Click:Connect(function()
            local existingInfo = gui:FindFirstChild("TowerInfoCard")
            if existingInfo then existingInfo:Destroy(); return end
            local tpl = TempTowers.Templates[towerId]
            local card = Instance.new("Frame")
            card.Name = "TowerInfoCard"
            card.AnchorPoint = Vector2.new(0.5, 0.5)
            card.Position = UDim2.fromScale(0.5, 0.5)
            card.Size = UDim2.fromOffset(440, 420)
            card.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
            card.BorderSizePixel = 0
            card.ZIndex = 20
            -- Parented to gui (not panel) so panel-drag doesn't move it.
            card.Parent = gui
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0.04, 0)
                c.Parent = card
            end

            -- Title with rarity-tinted name + "(Rare)" tag (admin uses
            -- Rare = identity rarity for display since templates don't
            -- have a runtime rarity stamped). Mirrors TowerCard's hex
            -- color formatting.
            local displayName = (tpl and tpl.displayName) or towerId
            local DEFAULT_RARITY = "Rare"
            local rc = TempTowers.RarityColors and TempTowers.RarityColors[DEFAULT_RARITY]
            local title = Instance.new("TextLabel")
            title.Size = UDim2.new(1, -32, 0, 34)
            title.Position = UDim2.fromOffset(16, 14)
            title.BackgroundTransparency = 1
            title.RichText = true
            if rc then
                local hex = string.format("#%02x%02x%02x",
                    math.floor(rc.R * 255 + 0.5),
                    math.floor(rc.G * 255 + 0.5),
                    math.floor(rc.B * 255 + 0.5))
                title.Text = string.format(
                    "<font color='%s'>%s</font>  <font color='#aaaaaa' size='14'>(%s)</font>",
                    hex, displayName, DEFAULT_RARITY)
            else
                title.Text = displayName
            end
            title.TextColor3 = Color3.fromRGB(255, 255, 255)
            title.Font = Enum.Font.FredokaOne
            title.TextSize = 22
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.ZIndex = 21
            title.Parent = card

            -- Description (template's description string, or a Power
            -- Core fallback for the Core tower).
            local desc = (tpl and tpl.description)
                or "Power Core (foundation tower)."
            local descLbl = Instance.new("TextLabel")
            descLbl.Size = UDim2.new(1, -32, 0, 40)
            descLbl.Position = UDim2.fromOffset(16, 52)
            descLbl.BackgroundTransparency = 1
            descLbl.Text = desc
            descLbl.TextColor3 = Color3.fromRGB(200, 210, 225)
            descLbl.Font = Enum.Font.Gotham
            descLbl.TextSize = 14
            descLbl.TextWrapped = true
            descLbl.TextXAlignment = Enum.TextXAlignment.Left
            descLbl.TextYAlignment = Enum.TextYAlignment.Top
            descLbl.ZIndex = 21
            descLbl.Parent = card

            -- Scrollable section list — STATS + MECHANIC. Tight
            -- 2px padding per Matthew 2026-04-27: "decrease spacing
            -- between damage, range, fire rate, and dps, and then
            -- between all the elements in the MECHANIC section."
            local scroll = Instance.new("ScrollingFrame")
            scroll.Size = UDim2.new(1, -32, 1, -160)
            scroll.Position = UDim2.fromOffset(16, 100)
            scroll.BackgroundTransparency = 1
            scroll.BorderSizePixel = 0
            scroll.ScrollBarThickness = 6
            scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
            scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
            scroll.ZIndex = 21
            scroll.Parent = card
            local layout = Instance.new("UIListLayout")
            layout.FillDirection = Enum.FillDirection.Vertical
            layout.Padding = UDim.new(0, 2)
            layout.SortOrder = Enum.SortOrder.LayoutOrder
            layout.Parent = scroll

            local order = 0
            local function addLine(label, value)
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
                l.TextColor3 = Color3.fromRGB(230, 235, 245)
                l.Font = Enum.Font.Gotham
                l.TextSize = 14
                l.TextXAlignment = Enum.TextXAlignment.Left
                l.LayoutOrder = order
                l.ZIndex = 22
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
                l.ZIndex = 22
                l.Parent = scroll
            end

            -- STATS section. Admin has no live tower → no modified
            -- values, so we show base only. Stat order matches
            -- TowerCard.lua: Damage / Range / Fire Rate / Max DPS.
            addSection("STATS")
            local baseDmg   = (tpl and tpl.damage) or 0
            local baseRng   = (tpl and tpl.range) or 0
            local baseFr    = (tpl and tpl.fireRate) or 0
            addLine("Damage", string.format("%d", baseDmg))
            addLine("Range",  string.format("%d", baseRng))
            addLine("Fire Rate", string.format("%.2f /sec", baseFr))
            addLine("Max DPS", string.format("%.1f", baseDmg * baseFr))

            -- MECHANIC section — driven by the template's secondary-
            -- stat fields (slowPct, patchTickDmg, cloudRadius, etc.).
            -- Mirror of TowerCard's MECHANIC fields list so the same
            -- towers show the same row labels in both surfaces.
            if tpl then
                local fields = {
                    {"slowPct",         "Slow",            "pct"},
                    {"slowSeconds",     "Slow duration",   "sec"},
                    {"stunSeconds",     "Stun duration",   "sec"},
                    {"stunCooldown",    "Stun cooldown",   "sec"},
                    {"aoeRadius",       "AOE radius",      "studs"},
                    {"splashRadius",    "Splash radius",   "studs"},
                    {"blastRadius",     "Blast radius",    "studs"},
                    {"patchRadius",     "Patch radius",    "studs"},
                    {"patchSeconds",    "Patch duration",  "sec"},
                    {"patchSlowPct",    "Patch slow",      "pct"},
                    {"patchTickDmg",    "Patch tick dmg",  "dmg"},
                    {"patchTickPerSec", "Patch ticks/sec", "count"},
                    {"cloudRadius",     "Cloud radius",    "studs"},
                    {"cloudSeconds",    "Cloud duration",  "sec"},
                    {"cloudTickDmg",    "Cloud tick dmg",  "dmg"},
                    {"cloudTickPerSec", "Cloud ticks/sec", "count"},
                    {"chainJumps",      "Chain jumps",     "count"},
                    {"chainRange",      "Chain range",     "studs"},
                    {"chainFalloff",    "Chain falloff",   "pct"},
                    {"pierceCount",     "Pierce",          "count"},
                    {"lobSeconds",      "Lob time",        "sec"},
                }
                local mechSection = false
                for _, f in ipairs(fields) do
                    local v = tpl[f[1]]
                    if v ~= nil then
                        if not mechSection then addSection("MECHANIC"); mechSection = true end
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

            -- Bottom CLOSE button (full-width, mirrors story-mode).
            local infoClose = Instance.new("TextButton")
            infoClose.Size = UDim2.new(1, -32, 0, 44)
            infoClose.Position = UDim2.new(0, 16, 1, -60)
            infoClose.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
            infoClose.BorderSizePixel = 0
            infoClose.AutoButtonColor = false
            infoClose.Text = "CLOSE"
            infoClose.TextColor3 = Color3.fromRGB(255, 255, 255)
            infoClose.Font = Enum.Font.FredokaOne
            infoClose.TextSize = 18
            infoClose.ZIndex = 22
            infoClose.Parent = card
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0.2, 0)
                c.Parent = infoClose
            end
            infoClose.MouseButton1Click:Connect(function() card:Destroy() end)
        end)

        -- (Aggregate stats row removed per Matthew 2026-04-27.)

        -- Balance verdict — TIER-DRIVEN with solo/duo/trio
        -- compiled commentary. Per Matthew 2026-04-27: "the final
        -- solo, duo, and trio runs for a tower should be compiled
        -- and will become the commentary on balance studio —
        -- admin → clicking on a tower from a completed run."
        --
        -- Stats + commentary span the active dataset
        -- (`matchingRuns` filtered from `latestResults`): when
        -- ALL RUNS is the loaded view, that's every cumulative
        -- run; when a specific past sweep is loaded, just that
        -- sweep. The visible scope thus matches whatever the
        -- player picked via the LOAD RUN / ALL RUNS toggle.
        local diff = (avgWave or 0) - sweepMedianAvgWave
        local absDiff = math.abs(diff)
        local pct = math.clamp(math.floor(absDiff * 5), 5, 50)

        -- Bucket matchingRuns by aux count → solo (1) / duo (2) /
        -- trio (3+). Average wave per bucket gives the compiled
        -- per-category line.
        local byCategory = {
            Solo = { runs = 0, totalWaves = 0 },
            Duo  = { runs = 0, totalWaves = 0 },
            Trio = { runs = 0, totalWaves = 0 },
        }
        for _, run in ipairs(matchingRuns) do
            local n = (run.auxIds and #run.auxIds) or 0
            local cat
            if n == 1 then cat = "Solo"
            elseif n == 2 then cat = "Duo"
            elseif n >= 3 then cat = "Trio"
            end
            if cat then
                byCategory[cat].runs = byCategory[cat].runs + 1
                byCategory[cat].totalWaves = byCategory[cat].totalWaves
                    + (run.finalWave or 0)
            end
        end
        local function fmtCat(cat)
            local b = byCategory[cat]
            if b.runs == 0 then return cat .. ": (no runs)" end
            return string.format("%s: %.2f (%d)",
                cat, b.totalWaves / b.runs, b.runs)
        end

        -- Per-tower-per-tier tuning suggestions, much more specific
        -- than the generic "+/- N% damage". Drilled by archetype:
        --   • DPS towers (Acorn, Thorn, Pepper, Lightning, Mortar)
        --     get raw-DPS levers (damage / fireRate / range).
        --   • Control towers (Frost, Root, Honey, Spore) get mechanic-
        --     specific levers (slowPct, stunSeconds, cloudTickDmg).
        -- Per Matthew 2026-04-27: "i want balance text to be much
        -- more comprehensive. ... suggest changes to the special if
        -- it's support or control."
        local TOWER_TUNING_HINTS = {
            AcornSniper = {
                S = "Cut damage 30 → 25 OR fireRate 0.32 → 0.27. Sniper's burst dominates Solo waves; trim raw DPS.",
                A = "Trim damage 30 → 28 OR fireRate 0.32 → 0.30. Range identity stays.",
                D = "Bump damage 30 → 33 OR fireRate 0.32 → 0.36. Range OK.",
                F = "Bump damage 30 → 38, fireRate → 0.40, OR add light AOE on impact.",
            },
            ThornVine = {
                S = "Cut damage 5 → 4 OR pierceCount 2 → 1. Pierce makes AOE waves trivial.",
                A = "Trim damage 5 → 4. Pierce stays.",
                D = "Bump damage 5 → 6 OR pierceCount 2 → 3.",
                F = "Bump damage 5 → 7, pierceCount → 3, OR widen pierce-line tolerance.",
            },
            PepperCannon = {
                S = "Cut damage 25 → 21 OR splashRadius 10 → 8. Splash-burst dominates AOE + Combined.",
                A = "Trim damage 25 → 23 OR splashRadius 10 → 9.",
                D = "Bump damage 25 → 28 OR splashRadius 10 → 12.",
                F = "Bump damage 25 → 32, splashRadius → 14, OR rework as faster cadence.",
            },
            LightningRadish = {
                S = "Cut chainJumps 2 → 1 OR damage 8 → 7. Chain is over-tuned on AOE clusters.",
                A = "Trim damage 8 → 7 OR chainFalloff 0.6 → 0.5.",
                D = "Bump damage 8 → 9 OR chainJumps 2 → 3.",
                F = "Bump damage 8 → 10, chainJumps → 3, chainFalloff → 0.7.",
            },
            MushroomMortar = {
                S = "Cut damage 40 → 33 OR blastRadius 12 → 10. Splash + range dominates.",
                A = "Trim damage 40 → 36 OR fireRate 0.6 → 0.55.",
                D = "Bump damage 40 → 45 OR blastRadius 12 → 14.",
                F = "Bump damage 40 → 52, lobSeconds 1.67 → 1.3 (faster lob), OR widen blastRadius → 16.",
            },
            FrostMelon = {
                S = "Cut slowPct 0.40 → 0.30 OR slowSeconds 2 → 1.5. Slow lift over-tuned vs DPS contribution.",
                A = "Reduce slowPct 0.40 → 0.35 OR aoeRadius 6 → 5.",
                D = "Increase slowPct 0.40 → 0.45 OR aoeRadius 6 → 7.",
                F = "Increase slowPct → 0.50, aoeRadius → 8, slowSeconds → 3, OR add minor DOT.",
            },
            RootSprout = {
                S = "Cut stunSeconds 0.5 → 0.35 OR stunCooldown 3 → 4. Stun stalls bosses too hard.",
                A = "Trim stunSeconds 0.5 → 0.4.",
                D = "Increase stunSeconds 0.5 → 0.65 OR drop stunCooldown 3 → 2.5.",
                F = "Increase stunSeconds → 0.75, stunCooldown → 2.0, OR add stun-on-pierce.",
            },
            HoneyHive = {
                S = "Cut patchTickDmg 4 → 3 OR patchSlowPct 0.40 → 0.30.",
                A = "Trim patchTickDmg 4 → 3 OR patchTickPerSec 2 → 1.5.",
                D = "Bump patchTickDmg 4 → 5 OR patchSeconds 4 → 5.",
                F = "Bump patchTickDmg → 6, patchSeconds → 6, patchSlowPct → 0.5, OR widen patchRadius.",
            },
            SporePuffball = {
                S = "Cut cloudTickDmg 3 → 2 OR cloudSeconds 3 → 2. DOT cloud is the carry; trim its uptime.",
                A = "Trim cloudTickDmg 3 → 2 OR cloudTickPerSec 4 → 3.",
                D = "Bump cloudTickDmg 3 → 4 OR cloudRadius 8 → 10.",
                F = "Bump cloudTickDmg → 5, cloudRadius → 11, cloudSeconds → 4, OR add slow on cloud.",
            },
        }

        -- Tier label now shown on the header stats line; drop the
        -- "(X tier)" tail from the verdict label so it isn't
        -- duplicated. Per Matthew 2026-04-27 SS annotation.
        local verdictLabel, verdictColor, tuneHint
        local genericHint
        if tier == "S" then
            verdictLabel = "OVER-POWERED"
            verdictColor = Color3.fromRGB(255, 130, 80)
            genericHint = string.format("Cut hard — try -%d%% damage or -%d%% firerate.", pct, pct)
        elseif tier == "A" then
            verdictLabel = "OVER-TUNED"
            verdictColor = Color3.fromRGB(255, 180, 100)
            genericHint = string.format("Light cut — -%d%% damage or -%d%% firerate.", pct, pct)
        elseif tier == "D" then
            verdictLabel = "UNDER-TUNED"
            verdictColor = Color3.fromRGB(255, 200, 120)
            genericHint = string.format("Light bump — +%d%% damage or +%d%% firerate.", pct, pct)
        elseif tier == "F" then
            verdictLabel = "UNDER-POWERED"
            verdictColor = Color3.fromRGB(255, 110, 110)
            genericHint = string.format("Bump hard — +%d%% damage AND +%d%% firerate, or rework special.", pct, pct)
        else  -- B or C
            verdictLabel = "PROPERLY POWERED"
            verdictColor = Color3.fromRGB(140, 220, 140)
            genericHint = "Within sweet spot — no urgent tuning needed."
        end
        -- Prefer the per-tower-per-tier hint when one exists; fall
        -- back to the generic %damage/%firerate copy otherwise.
        local towerHints = TOWER_TUNING_HINTS[towerId]
        local specific = towerHints and towerHints[tier or ""]
        tuneHint = specific or genericHint

        -- Compute best/worst pairings: for each OTHER aux that has
        -- shared a duo or trio run with this tower, accumulate the
        -- avg finalWave. Top 3 = highest avg, worst 3 = lowest.
        -- Excludes the current tower (self) and InfiniteStandard
        -- (anchor, not a real "pairing"). Per Matthew 2026-04-27:
        -- "in the green box, add top 3 best towers to pair with
        -- (based off duo and trio runs) and the worst 3."
        local pairAggs = {}
        for _, run in ipairs(matchingRuns) do
            local n = (run.auxIds and #run.auxIds) or 0
            if n >= 2 then  -- duo or trio only
                for _, otherId in ipairs(run.auxIds) do
                    if otherId ~= towerId and otherId ~= "InfiniteStandard" then
                        local agg = pairAggs[otherId] or { runs = 0, total = 0 }
                        agg.runs = agg.runs + 1
                        agg.total = agg.total + (run.finalWave or 0)
                        pairAggs[otherId] = agg
                    end
                end
            end
        end
        local pairList = {}
        for id, agg in pairs(pairAggs) do
            if agg.runs >= 1 then
                table.insert(pairList, {
                    id = id, avg = agg.total / agg.runs, runs = agg.runs })
            end
        end
        table.sort(pairList, function(a, b) return a.avg > b.avg end)

        local function fmtPair(e)
            -- "TOWERNAME: X.X (S)" per Matthew 2026-04-27 SS spec.
            return string.format("%s: %.1f (%d)", e.id, e.avg, e.runs)
        end
        -- Best 3 = top of sorted (descending) pairList. Worst 3 =
        -- bottom of pairList, displayed top→bottom in descending
        -- avg order (so the "deepest worst" sits at the bottom).
        local best3, worst3 = {}, {}
        for i = 1, math.min(3, #pairList) do
            best3[i] = pairList[i]
        end
        local nWorst = math.min(3, math.max(0, #pairList - 3))
        for i = 1, nWorst do
            worst3[i] = pairList[#pairList - nWorst + i]
        end

        -- Synergy narrative — uses the role of the top/bottom pair
        -- partner to explain WHY they synergize. Per Matthew
        -- 2026-04-27: "give me thoughts on why it pairs well with
        -- other towers." Static lookup keyed by (selfRole, otherRole)
        -- — generic enough to apply across any combo without per-pair
        -- hand-tuning.
        local function synergyReason(selfRole, otherRole, isPositive)
            local key = (selfRole or "?") .. "+" .. (otherRole or "?")
            if isPositive then
                if key == "DPS+Control" or key == "Control+DPS" then
                    return "slow/stun stretches DPS uptime per shot"
                elseif key == "DPS+DPS" then
                    return "stacked raw damage clears trash before heart range"
                elseif key == "Control+Control" then
                    return "stacked CC compounds — slow + stun overlap on the same mob"
                elseif key:find("Support") then
                    return "support buff lifts the partner's effective DPS"
                end
                return "complementary kill-window + control coverage"
            else  -- negative / underperform
                if key == "Control+Control" then
                    return "redundant zone control — both compete for the same mob windows"
                elseif key == "DPS+DPS" then
                    return "no CC layer — fast/tank waves outpace raw DPS"
                elseif key == "DPS+Control" or key == "Control+DPS" then
                    return "control lift wasted on the wrong wave-type cluster"
                end
                return "mechanic overlap blunts each tower's individual contribution"
            end
        end
        local function pairingNarrative()
            if #best3 == 0 then return nil end
            local roleByTowerId = TempTowers.RoleByTowerId or {}
            local selfRole = roleByTowerId[towerId] or role or "?"
            local lines = {}
            local top = best3[1]
            local topRole = roleByTowerId[top.id] or "?"
            table.insert(lines, string.format(
                "Pairs best with %s (%.1f over %d) — %s.",
                top.id, top.avg, top.runs,
                synergyReason(selfRole, topRole, true)))
            if nWorst > 0 then
                local bot = worst3[nWorst]
                local botRole = roleByTowerId[bot.id] or "?"
                table.insert(lines, string.format(
                    "Underperforms with %s (%.1f over %d) — %s.",
                    bot.id, bot.avg, bot.runs,
                    synergyReason(selfRole, botRole, false)))
            end
            return table.concat(lines, " ")
        end
        local pairText = pairingNarrative()

        -- Verdict box: 2-column body. Left = solo/duo/trio averages,
        -- right = pair grid (best 3 stacked left, worst 3 stacked
        -- right). Tuning hint sits below both columns full-width.
        -- Per Matthew 2026-04-27 layout SS.
        -- Verdict box: expanded 134 → 200 per Matthew 2026-04-27 to
        -- fit the per-tower-per-tier tuning hint AND the pairing
        -- narrative (which towers it synergizes / clashes with and
        -- WHY). Tuning hint at y=104 (h=30), pairing narrative at
        -- y=138 (h=58, wraps to ~3 lines).
        local verdictBox = Instance.new("Frame")
        verdictBox.Size = UDim2.new(1, -32, 0, 200)
        verdictBox.Position = UDim2.fromOffset(16, 70)
        verdictBox.BackgroundColor3 = Color3.fromRGB(20, 24, 20)
        verdictBox.BorderSizePixel = 0
        verdictBox.ZIndex = 11
        verdictBox.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = verdictBox
            local s = Instance.new("UIStroke")
            s.Color = verdictColor
            s.Thickness = 1.5
            s.Parent = verdictBox
        end

        local verdictLbl = Instance.new("TextLabel")
        verdictLbl.Size = UDim2.new(1, -16, 0, 22)
        verdictLbl.Position = UDim2.fromOffset(8, 6)
        verdictLbl.BackgroundTransparency = 1
        verdictLbl.Text = "BALANCE: " .. verdictLabel
        verdictLbl.Font = Enum.Font.FredokaOne
        verdictLbl.TextSize = 14
        verdictLbl.TextColor3 = verdictColor
        verdictLbl.TextXAlignment = Enum.TextXAlignment.Left
        verdictLbl.ZIndex = 12
        verdictLbl.Parent = verdictBox

        -- THREE EQUAL COLUMNS — evenly spaced and close together
        -- per Matthew 2026-04-27 SS spec. Modal interior ≈ 528px;
        -- 3 columns × 168 + 2 × 8 gap = 520, plus 4px L/R padding.
        --   Col 1 (Solo/Duo/Trio): x=8,   w=168
        --   Col 2 (Best 3):        x=184, w=168  (8px gap)
        --   Col 3 (Worst 3):       x=360, w=168  (8px gap)
        local function makeCol(xOff, lines)
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.fromOffset(168, 70)
            lbl.Position = UDim2.fromOffset(xOff, 32)
            lbl.BackgroundTransparency = 1
            lbl.Text = lines
            lbl.Font = Enum.Font.Gotham
            lbl.TextSize = 13
            lbl.TextColor3 = Color3.fromRGB(220, 230, 220)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.TextYAlignment = Enum.TextYAlignment.Top
            lbl.ZIndex = 12
            lbl.Parent = verdictBox
            return lbl
        end

        -- Column 1: solo/duo/trio averages, stacked.
        makeCol(8, string.format("%s\n%s\n%s",
            fmtCat("Solo"), fmtCat("Duo"), fmtCat("Trio")))

        -- Helper: pair list → newline-joined text block. Empty
        -- → "(no data)".
        local function pairsBlock(list)
            if #list == 0 then return "(no data)" end
            local out = ""
            for i, e in ipairs(list) do
                out = out .. fmtPair(e)
                if i < #list then out = out .. "\n" end
            end
            return out
        end

        -- Column 2: best 3 pairs.
        makeCol(184, pairsBlock(best3))
        -- Column 3: worst 3 pairs.
        makeCol(360, pairsBlock(worst3))

        -- BOTTOM: tuning hint, full width below both columns.
        -- Pulled up to y=104 (was 130) so it sits flush under the
        -- 3 columns (which end at y=32+70=102) with a 2px gap.
        local tuneLbl = Instance.new("TextLabel")
        tuneLbl.Size = UDim2.new(1, -16, 0, 30)
        tuneLbl.Position = UDim2.fromOffset(8, 104)
        tuneLbl.BackgroundTransparency = 1
        tuneLbl.Text = "→ " .. tuneHint
        tuneLbl.Font = Enum.Font.Gotham
        tuneLbl.TextSize = 13
        tuneLbl.TextColor3 = Color3.fromRGB(220, 230, 220)
        tuneLbl.TextXAlignment = Enum.TextXAlignment.Left
        tuneLbl.TextYAlignment = Enum.TextYAlignment.Top
        tuneLbl.TextWrapped = true
        tuneLbl.ZIndex = 12
        tuneLbl.Parent = verdictBox

        -- Pairing narrative — best/worst pair partners with the WHY
        -- (synergy reasoning derived from each pair's roles). Sits
        -- below the tuning hint, full-width, wrapped to 3 lines max.
        if pairText then
            local pairLbl = Instance.new("TextLabel")
            pairLbl.Size = UDim2.new(1, -16, 0, 58)
            pairLbl.Position = UDim2.fromOffset(8, 138)
            pairLbl.BackgroundTransparency = 1
            pairLbl.Text = pairText
            pairLbl.Font = Enum.Font.Gotham
            pairLbl.TextSize = 13
            pairLbl.TextColor3 = Color3.fromRGB(195, 215, 220)
            pairLbl.TextXAlignment = Enum.TextXAlignment.Left
            pairLbl.TextYAlignment = Enum.TextYAlignment.Top
            pairLbl.TextWrapped = true
            pairLbl.ZIndex = 12
            pairLbl.Parent = verdictBox
        end

        -- Per-run table — sits below the 200px-tall verdict box.
        -- Verdict ends at y=70+200=270; header starts at y=280.
        local runsHeader = Instance.new("TextLabel")
        runsHeader.Size = UDim2.new(1, -32, 0, 18)
        runsHeader.Position = UDim2.fromOffset(16, 280)
        runsHeader.BackgroundTransparency = 1
        runsHeader.Text = "PER-RUN BREAKDOWN  (sorted by wave)"
        runsHeader.Font = Enum.Font.FredokaOne
        runsHeader.TextSize = 13
        runsHeader.TextColor3 = Color3.fromRGB(255, 200, 140)
        runsHeader.TextXAlignment = Enum.TextXAlignment.Left
        runsHeader.ZIndex = 11
        runsHeader.Parent = modal

        -- Table column headers — under the runs header at y=280+22.
        local tableHead = Instance.new("Frame")
        tableHead.Size = UDim2.new(1, -32, 0, 22)
        tableHead.Position = UDim2.fromOffset(16, 302)
        tableHead.BackgroundColor3 = Color3.fromRGB(36, 42, 36)
        tableHead.BorderSizePixel = 0
        tableHead.ZIndex = 11
        tableHead.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 4)
            c.Parent = tableHead
        end
        local function makeColHeader(text, x, w, parent)
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.fromOffset(w, 22)
            lbl.Position = UDim2.fromOffset(x, 0)
            lbl.BackgroundTransparency = 1
            lbl.Text = text
            lbl.Font = Enum.Font.GothamBold
            lbl.TextSize = 11
            lbl.TextColor3 = Color3.fromRGB(220, 220, 220)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.ZIndex = 12
            lbl.Parent = parent
            return lbl
        end
        -- 4-column layout (WAVE / CATEGORY / TYPE / LOADOUT) — the
        -- CATEGORY column is the loadout's aux-count classification
        -- (Solo/Duo/Trio), distinct from TYPE which is the test
        -- mob-spawn type the run died on. Per Matthew 2026-04-27:
        -- "in per run breakdown, add a column if it was (solo,
        -- duo or trio)."
        makeColHeader("WAVE",      8,    50, tableHead)
        makeColHeader("CATEGORY",  62,   60, tableHead)
        makeColHeader("TYPE",      126,  80, tableHead)
        makeColHeader("LOADOUT",   210, 300, tableHead)

        local runsScroll = Instance.new("ScrollingFrame")
        -- Scroll bumped down to y=326 (was 260) and trimmed to h=240
        -- to fit inside the new 580-tall modal (was 520).
        -- 326 + 240 = 566; modal h=580 leaves 14px bottom pad.
        runsScroll.Size = UDim2.new(1, -32, 0, 240)
        runsScroll.Position = UDim2.fromOffset(16, 326)
        runsScroll.BackgroundColor3 = Color3.fromRGB(14, 18, 14)
        runsScroll.BorderSizePixel = 0
        runsScroll.ScrollBarThickness = 6
        runsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        runsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        runsScroll.ZIndex = 11
        runsScroll.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = runsScroll
            local lay = Instance.new("UIListLayout")
            lay.FillDirection = Enum.FillDirection.Vertical
            lay.Padding = UDim.new(0, 1)
            lay.SortOrder = Enum.SortOrder.LayoutOrder
            lay.Parent = runsScroll
        end
        local function makeCell(text, x, w, parent, color)
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.fromOffset(w, 18)
            lbl.Position = UDim2.fromOffset(x, 0)
            lbl.BackgroundTransparency = 1
            lbl.Text = text
            lbl.Font = Enum.Font.Code
            lbl.TextSize = 11
            lbl.TextColor3 = color or Color3.fromRGB(200, 220, 200)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.TextTruncate = Enum.TextTruncate.AtEnd
            lbl.ZIndex = 12
            lbl.Parent = parent
            return lbl
        end
        local TEST_TINTS = {
            AOE      = Color3.fromRGB(255, 110, 110),
            Combined = Color3.fromRGB(180, 130, 240),
            Solo     = Color3.fromRGB(255, 200, 80),
        }
        local CATEGORY_TINTS = {
            Solo = Color3.fromRGB(180, 220, 255),
            Duo  = Color3.fromRGB(180, 255, 200),
            Trio = Color3.fromRGB(255, 200, 180),
        }
        for idx, r in ipairs(matchingRuns) do
            local rowFrame = Instance.new("Frame")
            rowFrame.Size = UDim2.new(1, -8, 0, 18)
            rowFrame.BackgroundColor3 = (idx % 2 == 0) and Color3.fromRGB(20, 24, 20) or Color3.fromRGB(16, 20, 16)
            rowFrame.BorderSizePixel = 0
            rowFrame.LayoutOrder = idx
            rowFrame.ZIndex = 11
            rowFrame.Parent = runsScroll

            -- Loadout category from aux count (1 = Solo, 2 = Duo,
            -- 3 = Trio). Distinct from r.testType which is the
            -- mob-spawn type the run died on.
            local n = (r.auxIds and #r.auxIds) or 0
            local category = "?"
            if n == 1 then category = "Solo"
            elseif n == 2 then category = "Duo"
            elseif n >= 3 then category = "Trio"
            end

            makeCell(string.format("%.2f", r.finalWave or 0),
                4, 50, rowFrame, Color3.fromRGB(255, 220, 140))
            makeCell(category,
                58, 60, rowFrame, CATEGORY_TINTS[category] or Color3.fromRGB(200, 200, 200))
            local tt = r.testType or "?"
            makeCell(tt,
                122, 80, rowFrame, TEST_TINTS[tt])
            -- Strip "Power + " prefix — Power is always present so
            -- it's noise in the loadout column.
            local labelText = r.label or "?"
            labelText = labelText:gsub("^Power %+ ", "")
            makeCell(labelText, 206, 300, rowFrame)
        end
        if #matchingRuns == 0 then
            local none = Instance.new("TextLabel")
            none.Size = UDim2.new(1, -8, 0, 24)
            none.BackgroundTransparency = 1
            none.Text = "  (no runs in cached sweep)"
            none.Font = Enum.Font.Gotham
            none.TextSize = 13
            none.TextColor3 = Color3.fromRGB(140, 140, 140)
            none.TextXAlignment = Enum.TextXAlignment.Left
            none.ZIndex = 12
            none.Parent = runsScroll
        end
    end

    local function renderTiers(tiers)
        clearChildren(tierFrame)
        -- Compute the slate's median avgWave across every tier
        -- entry (DPS+Control+Support combined). Used by the
        -- per-tower popup's balance verdict to compare a single
        -- tower's avgWave against peers.
        if tiers then
            local allAvgs = {}
            for _, role in ipairs({"DPS", "Control", "Support"}) do
                for _, e in ipairs(tiers[role] or {}) do
                    table.insert(allAvgs, e.avgWave or 0)
                end
            end
            if #allAvgs > 0 then
                table.sort(allAvgs)
                sweepMedianAvgWave = allAvgs[math.ceil(#allAvgs / 2)]
            else
                sweepMedianAvgWave = 0
            end
        else
            sweepMedianAvgWave = 0
        end
        if not tiers then
            local empty = Instance.new("TextLabel")
            empty.Size = UDim2.fromScale(1, 1)
            empty.BackgroundTransparency = 1
            empty.Text = "No sweep run yet — press AUTO RUN to populate."
            empty.Font = Enum.Font.Gotham
            empty.TextSize = 14
            empty.TextColor3 = Color3.fromRGB(160, 160, 160)
            empty.Parent = tierFrame
            return
        end
        local roles = {"DPS", "Control", "Support"}
        for i, role in ipairs(roles) do
            local col = Instance.new("Frame")
            col.Size = UDim2.new(1/3, -8, 1, 0)
            col.Position = UDim2.new((i-1)/3, (i-1)*4, 0, 0)
            col.BackgroundColor3 = Color3.fromRGB(20, 24, 20)
            col.BorderSizePixel = 0
            col.Parent = tierFrame
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 6)
                c.Parent = col
            end
            local header = Instance.new("TextLabel")
            header.Size = UDim2.new(1, -8, 0, 22)
            header.Position = UDim2.fromOffset(4, 4)
            header.BackgroundTransparency = 1
            header.Text = role:upper()
            header.Font = Enum.Font.FredokaOne
            header.TextSize = 16
            header.TextColor3 = ROLE_COLORS[role] or Color3.fromRGB(220, 220, 220)
            header.TextXAlignment = Enum.TextXAlignment.Center
            header.Parent = col

            local list = tiers[role] or {}
            if #list == 0 then
                local none = Instance.new("TextLabel")
                none.Size = UDim2.new(1, -8, 0, 18)
                none.Position = UDim2.fromOffset(4, 28)
                none.BackgroundTransparency = 1
                none.Text = "(none)"
                none.Font = Enum.Font.Gotham
                none.TextSize = 12
                none.TextColor3 = Color3.fromRGB(120, 120, 120)
                none.TextXAlignment = Enum.TextXAlignment.Center
                none.Parent = col
            else
                for j, e in ipairs(list) do
                    -- Row is a TextButton so the whole row is
                    -- clickable (Matthew 2026-04-26: "can i make
                    -- the tower names clickable to pop up windows
                    -- with more detailed stats?"). Hover tints the
                    -- row so it reads as interactive.
                    local row = Instance.new("TextButton")
                    row.Size = UDim2.new(1, -8, 0, 18)
                    row.Position = UDim2.fromOffset(4, 28 + (j - 1) * 20)
                    row.BackgroundColor3 = Color3.fromRGB(40, 50, 40)
                    row.BackgroundTransparency = 1
                    row.AutoButtonColor = false
                    row.Text = ""
                    row.Parent = col

                    local tierLbl = Instance.new("TextLabel")
                    tierLbl.Size = UDim2.fromOffset(20, 18)
                    tierLbl.Position = UDim2.fromOffset(0, 0)
                    tierLbl.BackgroundTransparency = 1
                    tierLbl.Text = e.tier or "?"
                    tierLbl.Font = Enum.Font.FredokaOne
                    tierLbl.TextSize = 14
                    tierLbl.TextColor3 = TIER_COLORS[e.tier] or Color3.fromRGB(200, 200, 200)
                    tierLbl.TextXAlignment = Enum.TextXAlignment.Center
                    tierLbl.Parent = row

                    local nameLbl = Instance.new("TextLabel")
                    nameLbl.Size = UDim2.new(1, -64, 1, 0)
                    nameLbl.Position = UDim2.fromOffset(22, 0)
                    nameLbl.BackgroundTransparency = 1
                    nameLbl.Text = e.towerId or "?"
                    nameLbl.Font = Enum.Font.GothamBold
                    nameLbl.TextSize = 12
                    nameLbl.TextColor3 = Color3.fromRGB(220, 220, 220)
                    nameLbl.TextXAlignment = Enum.TextXAlignment.Left
                    nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
                    nameLbl.Parent = row

                    local waveLbl = Instance.new("TextLabel")
                    waveLbl.AnchorPoint = Vector2.new(1, 0)
                    waveLbl.Size = UDim2.fromOffset(40, 18)
                    waveLbl.Position = UDim2.new(1, -2, 0, 0)
                    waveLbl.BackgroundTransparency = 1
                    waveLbl.Text = string.format("%.1f", e.avgWave or 0)
                    waveLbl.Font = Enum.Font.Gotham
                    waveLbl.TextSize = 11
                    waveLbl.TextColor3 = Color3.fromRGB(160, 180, 160)
                    waveLbl.TextXAlignment = Enum.TextXAlignment.Right
                    waveLbl.Parent = row

                    -- Hover tint + click handler. Click opens the
                    -- detail popup with per-run table + balance
                    -- verdict + tuning suggestion.
                    row.MouseEnter:Connect(function()
                        row.BackgroundTransparency = 0.7
                    end)
                    row.MouseLeave:Connect(function()
                        row.BackgroundTransparency = 1
                    end)
                    row.MouseButton1Click:Connect(function()
                        showTowerDetail(e.towerId, role, e.tier, e.avgWave)
                    end)
                end
            end
        end
    end

    -- Last-run stats: scrollable text dump of the most recent
    -- StatLedger.summary() — single-run granular numbers
    -- (per-tower DPS / stun-sec / slow-value / kb-studs).
    local statsHeader = Instance.new("TextLabel")
    statsHeader.Size = UDim2.new(1, -32, 0, 22)
    statsHeader.Position = UDim2.fromOffset(16, 502)
    statsHeader.BackgroundTransparency = 1
    statsHeader.Text = "MOST RECENT RUN — STATLEDGER SNAPSHOT"
    statsHeader.Font = Enum.Font.FredokaOne
    statsHeader.TextSize = 14
    statsHeader.TextColor3 = Color3.fromRGB(255, 200, 140)
    statsHeader.TextXAlignment = Enum.TextXAlignment.Left
    statsHeader.Parent = panel

    local statsScroll = Instance.new("ScrollingFrame")
    statsScroll.Size = UDim2.new(1, -32, 0, 100)
    statsScroll.Position = UDim2.fromOffset(16, 526)
    statsScroll.BackgroundColor3 = Color3.fromRGB(14, 18, 14)
    statsScroll.BorderSizePixel = 0
    statsScroll.ScrollBarThickness = 6
    statsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    statsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    statsScroll.Parent = panel
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = statsScroll
    end

    local statsText = Instance.new("TextLabel")
    statsText.Size = UDim2.new(1, -16, 0, 0)
    statsText.Position = UDim2.fromOffset(8, 6)
    statsText.AutomaticSize = Enum.AutomaticSize.Y
    statsText.BackgroundTransparency = 1
    statsText.Text = ""
    statsText.Font = Enum.Font.Code
    statsText.TextSize = 12
    statsText.TextColor3 = Color3.fromRGB(200, 220, 200)
    statsText.TextXAlignment = Enum.TextXAlignment.Left
    statsText.TextYAlignment = Enum.TextYAlignment.Top
    statsText.TextWrapped = true
    statsText.Parent = statsScroll

    -- (EXPORT DATA button moved to slot 3 of the top button row
    -- per Matthew 2026-04-27, replacing the now-redundant VISUALS
    -- toggle. Modal helper + ready-handler logic stays here.)

    -- Show export payload in a copyable modal + dump to F9.
    local function showExportModal(jsonStr)
        local existing = panel:FindFirstChild("ExportDataModal")
        if existing then existing:Destroy() end
        local modal = Instance.new("Frame")
        modal.Name = "ExportDataModal"
        modal.AnchorPoint = Vector2.new(0.5, 0.5)
        modal.Position = UDim2.fromScale(0.5, 0.5)
        modal.Size = UDim2.fromOffset(620, 480)
        modal.BackgroundColor3 = Color3.fromRGB(22, 28, 34)
        modal.BorderSizePixel = 0
        modal.ZIndex = 30
        -- Parented to gui (not panel) so panel-drag doesn't drag the
        -- EXPORT DATA modal. Per Matthew 2026-04-27.
        modal.Parent = gui
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 12)
            c.Parent = modal
            local s = Instance.new("UIStroke")
            s.Color = Color3.fromRGB(80, 140, 220)
            s.Thickness = 2
            s.Parent = modal
        end
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -56, 0, 28)
        title.Position = UDim2.fromOffset(14, 12)
        title.BackgroundTransparency = 1
        title.Text = ("EXPORT DATA  —  %d chars  (Ctrl+A then Ctrl+C)"):format(#jsonStr)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 16
        title.TextColor3 = Color3.fromRGB(180, 215, 255)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 31
        title.Parent = modal
        local close = Instance.new("TextButton")
        close.AnchorPoint = Vector2.new(1, 0)
        close.Position = UDim2.new(1, -10, 0, 10)
        close.Size = UDim2.fromOffset(36, 28)
        close.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
        close.BorderSizePixel = 0
        close.Text = "X"
        close.Font = Enum.Font.FredokaOne
        close.TextSize = 16
        close.TextColor3 = Color3.fromRGB(240, 200, 200)
        close.ZIndex = 32
        close.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = close
        end
        close.MouseButton1Click:Connect(function() modal:Destroy() end)

        local box = Instance.new("TextBox")
        box.Size = UDim2.new(1, -28, 1, -56)
        box.Position = UDim2.fromOffset(14, 44)
        box.BackgroundColor3 = Color3.fromRGB(14, 18, 22)
        box.BorderSizePixel = 0
        box.ClearTextOnFocus = false
        box.MultiLine = true
        box.TextWrapped = true
        box.Font = Enum.Font.Code
        box.TextSize = 11
        box.TextColor3 = Color3.fromRGB(200, 220, 200)
        box.TextXAlignment = Enum.TextXAlignment.Left
        box.TextYAlignment = Enum.TextYAlignment.Top
        -- Roblox TextBox.Text caps at 200,000 chars. Per Matthew
        -- 2026-04-27: 234k payload triggered "Provided string length
        -- ... is greater than or equal to max length (200000)" and
        -- the modal blew up. Defensive truncate at 195k with a clear
        -- pointer to F9 for the full thing.
        local MAX_TEXTBOX_CHARS = 195000
        if #jsonStr > MAX_TEXTBOX_CHARS then
            box.Text = jsonStr:sub(1, MAX_TEXTBOX_CHARS)
                .. "\n\n[truncated at " .. MAX_TEXTBOX_CHARS
                .. " chars — full payload is in the F9 console]"
        else
            box.Text = jsonStr
        end
        box.ZIndex = 31
        box.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = box
        end
    end

    exportReadyRemote.OnClientEvent:Connect(function(payload)
        exportBtn.Text = "EXPORT DATA"
        if type(payload) ~= "table" or type(payload.json) ~= "string" then
            print("[InfiniteAdminPanel] EXPORT DATA returned no JSON.")
            return
        end
        -- F9 always gets the FULL JSON (Roblox print has no length
        -- cap). Modal prefers the smaller summary payload (towers /
        -- pairs / config — no per-run pool) so the TextBox doesn't
        -- hit Roblox's 200k char limit. If summary is missing for
        -- any reason, fall back to the truncated full json.
        print("[InfiniteAdminPanel] ===== EXPORT DATA START =====")
        print(payload.json)
        print("[InfiniteAdminPanel] ===== EXPORT DATA END =====")
        local modalJson = payload.summary or payload.json
        showExportModal(modalJson)
    end)

    local function renderSweep(payload)
        if type(payload) ~= "table" or payload.empty then
            -- Empty payload — could be either "no sweeps yet" or
            -- post-BALANCE-RESET. Either way the cumulative pool is
            -- empty, so the slot-3 button stays in LOAD RUN mode.
            statusLabel.Text = "No runs in the cumulative pool — press AUTO RUN."
            statusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
            renderTiers(nil)
            latestResults = nil
            morphAllRunsToLoad()
        else
            local resultCount = (payload.results and #payload.results) or 0
            local total = payload.total or 0
            local secAgo = math.max(0, os.time() - (payload.completedAt or 0))
            -- Status prefix tracks WHICH dataset is showing:
            --   • active-era cumulative aggregate    → "ALL RUNS"
            --   • loaded past balance era            → "Balance vN"
            --   • single past sweep (legacy idx)     → "Past sweep"
            --   • aborted partial sweep              → "ABORTED"
            -- The server stamps payload.balanceVersion on
            -- LOAD-by-version replies (era load); the active-era
            -- cumulative path leaves it unset, which is how we
            -- distinguish the two cumulative cases here.
            local prefix
            if payload.cumulative and payload.balanceVersion then
                prefix = string.format("Balance v%d", payload.balanceVersion)
                if payload.sweepCount then
                    prefix = prefix .. string.format(" (%d sweep%s)",
                        payload.sweepCount,
                        payload.sweepCount == 1 and "" or "s")
                end
                morphLoadRunToAllRuns()
            elseif payload.cumulative then
                prefix = "ALL RUNS"
                morphAllRunsToLoad()
            elseif payload.aborted then
                prefix = "ABORTED"
                morphLoadRunToAllRuns()
            else
                prefix = "Past sweep"
                morphLoadRunToAllRuns()
            end
            statusLabel.Text = string.format(
                "%s: %d/%d run(s) — %s",
                prefix, resultCount, total, relTime(secAgo))
            statusLabel.TextColor3 = payload.aborted
                and Color3.fromRGB(220, 160, 100)
                or (payload.cumulative
                    and Color3.fromRGB(140, 200, 240)
                    or Color3.fromRGB(160, 220, 160))
            renderTiers(payload.tiers)
            -- Stash the per-run results so the tower-detail popup
            -- can filter to runs containing a clicked tower.
            latestResults = payload.results
        end
        statsText.Text = (type(payload) == "table" and type(payload.lastRunStats) == "string"
            and payload.lastRunStats ~= "")
            and payload.lastRunStats
            or "(no run stats captured yet — recording is enabled during AUTO RUN only)"
    end

    -- Listener for the cache response. Server fires this on
    -- request OR opportunistically when a sweep completes (the
    -- existing InfiniteAutoRunDone path handles the live case).
    local lastSweepDataRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteLastSweepData)
    lastSweepDataRemote.OnClientEvent:Connect(renderSweep)

    -- Also re-render when a sweep finishes mid-session — saves the
    -- player from manually closing + re-opening the panel.
    local autoRunDoneRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunDone)
    autoRunDoneRemote.OnClientEvent:Connect(function(payload)
        renderSweep(payload)
    end)

    -- Expose a request closure so open() can re-fetch the cache
    -- every time the player opens the panel (cheap; server cache
    -- is just a table read). Request fires the cumulative-aggregate
    -- channel by default — the server's lastSweepReqRemote handler
    -- returns the cumulative pool when populated.
    InfiniteAdminPanel.requestRefresh = function()
        lastSweepReqRemote:FireServer()
    end

    return gui
end

function InfiniteAdminPanel.setup(deps)
    if panelGui and panelGui.Parent then return end
    panelPlayerGui = deps.playerGui
    panelGui = buildPanel(deps)
end

function InfiniteAdminPanel.open()
    if panelGui and panelGui.Parent and not panelGui.Enabled then
        panelGui.Enabled = true
        if panelPlayerGui then
            bumpModalCount(panelPlayerGui, 1)
        end
        -- Refresh stats from the in-session server cache. If a sweep
        -- finished while the panel was closed, the new tier list +
        -- last-run stats land via the InfiniteLastSweepData listener.
        if InfiniteAdminPanel.requestRefresh then
            InfiniteAdminPanel.requestRefresh()
        end
    end
end

function InfiniteAdminPanel.close()
    if panelGui and panelGui.Parent and panelGui.Enabled then
        panelGui.Enabled = false
        if panelPlayerGui then
            bumpModalCount(panelPlayerGui, -1)
        end
    end
end

-- Toggle: M-hotkey calls this so the same key opens AND closes the
-- panel. Per Matthew 2026-04-26: "M should close admin panel".
function InfiniteAdminPanel.toggle()
    if panelGui and panelGui.Parent then
        if panelGui.Enabled then
            InfiniteAdminPanel.close()
        else
            InfiniteAdminPanel.open()
        end
    end
end

return InfiniteAdminPanel
