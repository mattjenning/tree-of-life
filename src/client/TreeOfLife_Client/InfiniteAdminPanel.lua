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

local panelGui = nil

local function buildPanel(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_InfiniteAdminPanel"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 65
    gui.Enabled = false
    gui.Parent = playerGui

    local dim = Instance.new("Frame")
    dim.Size = UDim2.fromScale(1, 1)
    dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    dim.BackgroundTransparency = 0.4
    dim.BorderSizePixel = 0
    dim.Parent = gui

    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.Size = UDim2.fromOffset(560, 480)
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
    closeBtn.Parent = panel
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = closeBtn
    end
    closeBtn.MouseButton1Click:Connect(function() gui.Enabled = false end)

    -- Helper for action buttons.
    local function makeActionBtn(yPos, label, color, onClick)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(220, 44)
        btn.Position = UDim2.fromOffset(16, yPos)
        btn.BackgroundColor3 = color
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = label
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 18
        btn.TextColor3 = Color3.fromRGB(20, 30, 22)
        btn.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = btn
        end
        btn.MouseButton1Click:Connect(onClick)
        return btn
    end

    local function makeBtnHelp(yPos, text)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.fromOffset(280, 44)
        lbl.Position = UDim2.fromOffset(248, yPos)
        lbl.BackgroundTransparency = 1
        lbl.Text = text
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 13
        lbl.TextColor3 = Color3.fromRGB(180, 180, 180)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextWrapped = true
        lbl.Parent = panel
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
        box.Size = UDim2.fromOffset(380, 200)
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
        mlbl.Size = UDim2.new(1, -20, 0, 100)
        mlbl.Position = UDim2.fromOffset(10, 14)
        mlbl.BackgroundTransparency = 1
        mlbl.Text = message
        mlbl.Font = Enum.Font.FredokaOne
        mlbl.TextSize = 18
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

    -- ── RUN RESET — exits to hub (no stats recorded since recording
    --    is currently disabled anyway, but the wave/loadout state is
    --    cleared cleanly via the existing exit path).
    local exitRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteForceExit)
    makeActionBtn(70, "RUN RESET", Color3.fromRGB(220, 130, 100), function()
        gui.Enabled = false
        exitRemote:FireServer()
    end)
    makeBtnHelp(70, "Wipe the current run + return to hub. Doesn't "
        .. "record stats (nothing is persistent yet).")

    -- ── TOTAL RESET — confirm modal then fires the (stub) reset.
    --    Placeholder until persistent-run-history lands.
    local totalResetRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteTotalReset)
    makeActionBtn(126, "TOTAL RESET", Color3.fromRGB(220, 80, 80), function()
        showConfirm(
            "TOTAL RESET\n\nErase ALL Balance Studio stats from "
            .. "inception. This can't be undone.\n\n"
            .. "(Stub for now — no persistent stats exist yet.)",
            function()
                totalResetRemote:FireServer()
            end)
    end)
    makeBtnHelp(126, "Erase ALL persistent stats. Use carefully — "
        .. "no undo.")

    -- Divider.
    local divider = Instance.new("Frame")
    divider.Size = UDim2.new(1, -32, 0, 1)
    divider.Position = UDim2.fromOffset(16, 200)
    divider.BackgroundColor3 = Color3.fromRGB(80, 70, 50)
    divider.BorderSizePixel = 0
    divider.Parent = panel

    -- ── Stats placeholder.
    local statsTitle = Instance.new("TextLabel")
    statsTitle.Size = UDim2.new(1, -32, 0, 28)
    statsTitle.Position = UDim2.fromOffset(16, 218)
    statsTitle.BackgroundTransparency = 1
    statsTitle.Text = "RUN STATS  +  TIER LISTS"
    statsTitle.Font = Enum.Font.FredokaOne
    statsTitle.TextSize = 18
    statsTitle.TextColor3 = Color3.fromRGB(255, 200, 140)
    statsTitle.TextXAlignment = Enum.TextXAlignment.Left
    statsTitle.Parent = panel

    local placeholder = Instance.new("TextLabel")
    placeholder.Size = UDim2.new(1, -32, 0, 200)
    placeholder.Position = UDim2.fromOffset(16, 252)
    placeholder.BackgroundTransparency = 1
    placeholder.Text = "Stats are NOT yet persistent.\n\n"
        .. "Coming with the persistent-run-history step:\n"
        .. "  • Highest wave reached (per scenario)\n"
        .. "  • Average wave (rolling)\n"
        .. "  • Per-tower DPS / stun-sec / slow-value / kb-studs\n"
        .. "  • S/A/B/C/D/F tier list per role (DPS / Control / Support)\n\n"
        .. "Recording flag is currently OFF (StatLedger.recordingEnabled=false)\n"
        .. "per Matthew's 'get it working first' decision."
    placeholder.Font = Enum.Font.Gotham
    placeholder.TextSize = 15
    placeholder.TextColor3 = Color3.fromRGB(200, 200, 200)
    placeholder.TextXAlignment = Enum.TextXAlignment.Left
    placeholder.TextYAlignment = Enum.TextYAlignment.Top
    placeholder.TextWrapped = true
    placeholder.Parent = panel

    return gui
end

function InfiniteAdminPanel.setup(deps)
    if panelGui and panelGui.Parent then return end
    panelGui = buildPanel(deps)
end

function InfiniteAdminPanel.open()
    if panelGui and panelGui.Parent then
        panelGui.Enabled = true
    end
end

return InfiniteAdminPanel
