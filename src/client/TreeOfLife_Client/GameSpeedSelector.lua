--[[
    GameSpeedSelector.lua — The top-right HUD bar with PAUSE +
    1× / 2× / 3× / 5× / 10× speed buttons. Tap fires SetGameSpeed
    server-side; the server validates (only the listed values), pauses
    or sets, and broadcasts via GameSpeedChanged so every client's
    active button stays in sync.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
]]

local GameSpeedSelector = {}

function GameSpeedSelector.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes

    local speedGui = Instance.new("ScreenGui")
    speedGui.Name = "ToL_SpeedSelector"
    speedGui.IgnoreGuiInset = true  -- align with top edge
    speedGui.ResetOnSpawn = false
    speedGui.DisplayOrder = 240  -- above wave HUD so it's never occluded
    speedGui.Parent = playerGui

    -- 1×/2×/3×/5×/10× are always available. 20×/30×/50×/100× are
    -- balance-studio benchmarking speeds — gated to Infinite mode
    -- (mapId=4) only, hidden everywhere else. 50× and 100× are
    -- "math-only" tier: visual fidelity drops sharply (mob model
    -- billboards may stutter, projectiles may visually skip), but
    -- the server-side simulation (HP, damage, fire timing) keeps
    -- pace because per-frame work scales linearly with dt.
    -- 200×/400× removed per Matthew 2026-04-27 ("they are broken")
    -- — the substep-batched math at those tiers inflates loadout
    -- survival vs real-time runs even after the wallclock-fix
    -- pass. Cap stays at 100× until validated higher.
    local SPEEDS = {1, 2, 3, 5, 10, 20, 50, 100}
    -- Set of speeds that are ONLY shown in Infinite mode (mapId=4).
    local INFINITE_ONLY = { [20] = true, [50] = true, [100] = true }
    local BTN_SIZE = 44
    local PADDING = 6
    -- Pause button sits to the LEFT of the 1× button. Bar width is
    -- recomputed dynamically when speed buttons hide/show, so the
    -- initial value here is just the maximum extent (all buttons
    -- visible) — actual width is set by setBarLayout below.
    local barHeight = BTN_SIZE + (PADDING * 2)

    local bar = Instance.new("Frame")
    bar.Size = UDim2.fromOffset(0, barHeight)  -- width set by setBarLayout
    bar.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
    bar.BackgroundTransparency = 0.15
    bar.BorderSizePixel = 0
    bar.Parent = speedGui
    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(0.18, 0)
    bc.Parent = bar
    local bs = Instance.new("UIStroke")
    bs.Thickness = 2
    bs.Color = Color3.fromRGB(60, 70, 90)
    bs.Parent = bar

    -- Button registry: speed-number → TextButton. Pause uses key 0.
    local buttons = {}

    local function refreshActive(currentSpeed)
        for spd, btn in pairs(buttons) do
            if spd == currentSpeed then
                btn.BackgroundColor3 = Color3.fromRGB(255, 200, 80)
                btn.TextColor3 = Color3.fromRGB(20, 20, 30)
            else
                btn.BackgroundColor3 = Color3.fromRGB(50, 60, 80)
                btn.TextColor3 = Color3.fromRGB(220, 225, 235)
            end
        end
    end

    -- PAUSE button (leftmost). Sends 0 to SetGameSpeed; server toggles
    -- ctx.paused and broadcasts 0 back. Re-clicking a speed button
    -- unpauses and resumes at that speed.
    local pauseBtn = Instance.new("TextButton")
    pauseBtn.Size = UDim2.fromOffset(BTN_SIZE, BTN_SIZE)
    pauseBtn.Position = UDim2.fromOffset(PADDING, PADDING)
    pauseBtn.BackgroundColor3 = Color3.fromRGB(50, 60, 80)
    pauseBtn.BorderSizePixel = 0
    pauseBtn.AutoButtonColor = false
    pauseBtn.Text = "⏸"  -- pause glyph
    pauseBtn.TextColor3 = Color3.fromRGB(220, 225, 235)
    pauseBtn.Font = Enum.Font.FredokaOne
    pauseBtn.TextSize = 26
    pauseBtn.Parent = bar
    local pauseCorner = Instance.new("UICorner")
    pauseCorner.CornerRadius = UDim.new(0.25, 0)
    pauseCorner.Parent = pauseBtn
    buttons[0] = pauseBtn
    pauseBtn.MouseButton1Click:Connect(function()
        local remote = ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
        if remote then remote:FireServer(0) end
        refreshActive(0)  -- optimistic highlight
    end)

    -- Speed buttons start to the right of the pause button. Created
    -- once; visibility + position re-laid out by setBarLayout based on
    -- whether we're in Infinite mode.
    local speedStartX = PADDING + BTN_SIZE + PADDING
    for _, spd in ipairs(SPEEDS) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(BTN_SIZE, BTN_SIZE)
        btn.BackgroundColor3 = Color3.fromRGB(50, 60, 80)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = tostring(spd) .. "×"
        btn.TextColor3 = Color3.fromRGB(220, 225, 235)
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 18
        btn.Parent = bar
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.25, 0)
        c.Parent = btn
        buttons[spd] = btn
        btn.MouseButton1Click:Connect(function()
            local remote = ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
            if remote then remote:FireServer(spd) end
            refreshActive(spd)
        end)
    end

    -- Position + visibility pass. infiniteMode controls whether the
    -- 20×/30× buttons are shown. Rebuilds the bar width to fit only
    -- the visible buttons + the pause button.
    local function setBarLayout(infiniteMode: boolean)
        local visibleCount = 0
        for i, spd in ipairs(SPEEDS) do
            local btn = buttons[spd]
            if not btn then continue end
            local visible = infiniteMode or not INFINITE_ONLY[spd]
            btn.Visible = visible
            if visible then
                btn.Position = UDim2.fromOffset(
                    speedStartX + visibleCount * (BTN_SIZE + PADDING), PADDING)
                visibleCount = visibleCount + 1
            end
            local _ = i
        end
        local barWidth = (visibleCount * BTN_SIZE)
                       + (math.max(0, visibleCount - 1) * PADDING)
                       + (PADDING * 2) + BTN_SIZE + PADDING
        bar.Size = UDim2.fromOffset(barWidth, barHeight)
        bar.Position = UDim2.new(1, -(barWidth + 12), 0, 12)
    end

    setBarLayout(false)        -- start with Infinite-only buttons hidden
    refreshActive(1)           -- initial state matches server default

    -- Server pushes the canonical speed any time it changes (or on PlayerAdded).
    -- 0 means paused; other values are the active game-speed multiplier.
    local changedRemote = ReplicatedStorage:WaitForChild(Remotes.Names.GameSpeedChanged)
    changedRemote.OnClientEvent:Connect(function(newSpeed)
        if type(newSpeed) ~= "number" then return end
        refreshActive(newSpeed)
    end)

    -- Map-id watcher: WaveState broadcast carries the active mapId.
    -- mapId=4 means Infinite Pickle Swamp → reveal 20×/30×.
    -- Anything else → hide them.
    local waveStateRemote = ReplicatedStorage:WaitForChild(Remotes.Names.WaveState)
    waveStateRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        setBarLayout(payload.mapId == 4)
    end)
end

return GameSpeedSelector
