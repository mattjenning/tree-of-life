--[[
    InfiniteHUD.lua — Top-center label "WAVE N (TestType)" for the
    Balance Studio. Visible only when mapId == 4 (Pickle Swamp). Updates
    on every InfiniteRoundUpdate broadcast from systems/Infinite.lua.

    Phase 1 of project_infinite_arena.md — minimal informational HUD so
    the player can tell at a glance which wave they're on + which test
    type is running, without tabbing to the server log.

    Future work (this stays minimal until the user-designed Balance
    Studio panels land):
      - Heart HP overlay
      - Round timer
      - Active-mob count
      - Tower DPS chips

    setup(deps):
      deps.player, deps.playerGui, deps.ReplicatedStorage, deps.Remotes
]]

local InfiniteHUD = {}

-- Color per test type — matches the role-color convention from
-- project_tower_categories.md so the player learns to associate
-- red/blue/purple with the spawn type they're seeing.
local TEST_COLORS = {
    AOE      = Color3.fromRGB(255, 110, 110),   -- DPS-stress red
    Combined = Color3.fromRGB(180, 130, 240),   -- mixed purple
    Solo     = Color3.fromRGB(255, 200, 80),    -- single-target gold
}

function InfiniteHUD.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_InfiniteHUD"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 230
    gui.Enabled = false  -- hidden until first round update lands
    gui.Parent = playerGui

    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0)
    panel.Position = UDim2.new(0.5, 0, 0, 80)  -- below the wave HUD
    panel.Size = UDim2.fromOffset(280, 44)
    panel.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
    panel.BackgroundTransparency = 0.2
    panel.BorderSizePixel = 0
    panel.Parent = gui
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent = panel
        local stroke = Instance.new("UIStroke")
        stroke.Thickness = 2
        stroke.Color = Color3.fromRGB(120, 220, 140)
        stroke.Parent = panel
    end

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = ""
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 22
    label.TextColor3 = Color3.fromRGB(220, 240, 220)
    label.Parent = panel

    -- Big centered countdown overlay (5..4..3..2..1 before wave 1).
    -- Sits OUTSIDE the panel — fills the screen center for visibility.
    local countdownLabel = Instance.new("TextLabel")
    countdownLabel.AnchorPoint = Vector2.new(0.5, 0.5)
    countdownLabel.Position = UDim2.fromScale(0.5, 0.4)
    countdownLabel.Size = UDim2.fromOffset(300, 200)
    countdownLabel.BackgroundTransparency = 1
    countdownLabel.Text = ""
    countdownLabel.Font = Enum.Font.FredokaOne
    countdownLabel.TextSize = 140
    countdownLabel.TextColor3 = Color3.fromRGB(255, 240, 140)
    countdownLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    countdownLabel.TextStrokeTransparency = 0.3
    countdownLabel.Visible = false
    countdownLabel.Parent = gui

    local roundRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteRoundUpdate)
    roundRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local wave     = payload.wave
        local testType = payload.testType
        if type(wave) ~= "number" or type(testType) ~= "string" then return end
        gui.Enabled = true
        label.Text = string.format("WAVE %d  (%s)", wave, testType)
        label.TextColor3 = TEST_COLORS[testType] or Color3.fromRGB(220, 240, 220)
    end)

    local countdownRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteCountdown)
    countdownRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local n = payload.countdown
        if type(n) ~= "number" then return end
        gui.Enabled = true
        if n > 0 then
            countdownLabel.Visible = true
            countdownLabel.Text = tostring(n)
        else
            -- 0 = clear / hide. Wave 1 spawn fires immediately after.
            countdownLabel.Visible = false
            countdownLabel.Text = ""
        end
    end)

    -- Hide whenever the player leaves Map 4 (back to hub or another map).
    -- WaveState payload's mapId tells us the active map.
    local waveStateRemote = ReplicatedStorage:WaitForChild(Remotes.Names.WaveState)
    waveStateRemote.OnClientEvent:Connect(function(state)
        if type(state) ~= "table" then return end
        if state.mapId ~= 4 then
            gui.Enabled = false
            label.Text = ""
        end
    end)
end

return InfiniteHUD
