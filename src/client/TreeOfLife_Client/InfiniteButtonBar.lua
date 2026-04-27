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

    -- LOADOUT: re-open the picker directly via its exported open().
    -- No server round-trip — the picker is purely client-side; only
    -- the START button's PickInfiniteScenario fire goes to server.
    -- Server's enter() now treats a re-pick mid-run as "stop current,
    -- start new" via the restart path.
    local LoadoutPicker = require(script.Parent:WaitForChild("InfiniteLoadoutPicker"))
    loadoutBtn.MouseButton1Click:Connect(function()
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

    -- SIMULATE: fires the closed-form math sweep on the server.
    -- Per Matthew 2026-04-27. Results stored in a SEPARATE
    -- `simulatedSweep` cache server-side and DON'T touch the
    -- cumulative tier list / LOAD RUN history. Server prints
    -- the simulated tier list to its log; client gets the
    -- payload via InfiniteSimulateData (currently logged to
    -- F9 so the player can compare to the real-sweep numbers).
    local simulateRemote      = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteSimulate)
    local simulateDataRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteSimulateData)
    local simulating = false
    simulateBtn.MouseButton1Click:Connect(function()
        if simulating then return end
        simulating = true
        simulateBtn.Text = "SIMULATING…"
        simulateRemote:FireServer()
    end)
    simulateDataRemote.OnClientEvent:Connect(function(payload)
        simulating = false
        simulateBtn.Text = "SIMULATE"
        if type(payload) ~= "table" or type(payload.results) ~= "table" then
            print("[InfiniteButtonBar] SIMULATE returned no data.")
            return
        end
        print(("[InfiniteButtonBar] SIMULATE complete — %d loadouts. Server log has the tier list."):format(
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

    -- M hotkey TOGGLES the admin panel — same key opens it from
    -- closed state, closes it from open state. Per Matthew
    -- 2026-04-26: "M should close admin panel".
    --
    -- The button-bar visibility gate (gui.Enabled) only applies
    -- when OPENING — once the panel is up, modal-count makes the
    -- button bar hide itself, so the M-press while panel is open
    -- bypasses the gate (since toggle handles that case via
    -- AdminPanel's own enabled check).
    -- gameProcessedEvent guard prevents the hotkey from triggering
    -- while the player is typing in chat / a text box. M was
    -- chosen over D to avoid conflict with WASD right-strafe.
    local UserInputService = game:GetService("UserInputService")
    UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if gameProcessedEvent then return end
        if input.KeyCode ~= Enum.KeyCode.M then return end
        -- Map 4 gate: only fire if the player is in the swamp.
        -- (Mirror of gui.Enabled check, but allow toggle even when
        -- the bar is hidden because the panel is open.)
        if not onMap4 then return end
        AdminPanel.toggle()
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
    end)
end

return InfiniteButtonBar
