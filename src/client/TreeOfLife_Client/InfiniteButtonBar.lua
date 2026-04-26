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
    bar.Size = UDim2.fromOffset(360, 44)
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

    local loadoutBtn = makeBarButton("LOADOUT", Color3.fromRGB(120, 220, 140), 1)
    local adminBtn   = makeBarButton("ADMIN",   Color3.fromRGB(220, 180, 80),  2)

    -- LOADOUT: re-open the picker directly via its exported open().
    -- No server round-trip — the picker is purely client-side; only
    -- the START button's PickInfiniteScenario fire goes to server.
    -- Server's enter() now treats a re-pick mid-run as "stop current,
    -- start new" via the restart path.
    local LoadoutPicker = require(script.Parent:WaitForChild("InfiniteLoadoutPicker"))
    loadoutBtn.MouseButton1Click:Connect(function()
        if LoadoutPicker.open then LoadoutPicker.open() end
    end)

    -- ADMIN: open the stub admin panel. Same client-only modal pattern
    -- as the loadout picker. The panel is a sibling module so it can
    -- expand without bloating this bar's register count.
    local AdminPanel = require(script.Parent:WaitForChild("InfiniteAdminPanel"))
    AdminPanel.setup({
        playerGui          = playerGui,
        ReplicatedStorage  = ReplicatedStorage,
        Remotes            = Remotes,
    })
    adminBtn.MouseButton1Click:Connect(function()
        AdminPanel.open()
    end)

    -- Visibility gate: show only when mapId == 4.
    local waveStateRemote = ReplicatedStorage:WaitForChild(Remotes.Names.WaveState)
    waveStateRemote.OnClientEvent:Connect(function(state)
        if type(state) ~= "table" then return end
        gui.Enabled = (state.mapId == 4)
    end)
end

return InfiniteButtonBar
