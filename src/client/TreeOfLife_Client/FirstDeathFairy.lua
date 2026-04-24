--[[
    FirstDeathFairy.lua — client-side modal for the first-death tutorial
    loop (server flow in systems/DevRemotes.lua + TreeOfLife_WaveSystem).

    Two remotes handled:
      ShowFirstDeathFairy    — to a first-time player who just died.
                               Offers 1 of 3 common attachments.
      ShowResurrectionNotice — to OTHER players while the first-timer
                               picks. "Someone is being resurrected!"

    Extracted to its own ModuleScript because the init.client.lua main
    chunk is at the Luau 200-register ceiling; moving ~200 lines of
    modal code out frees top-level register slots.

    setup(deps) captures these upvalues (main script owns the state):
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.IS_MOBILE
      deps.unlockGameLost — callback that sets main-chunk gameLost=false
                            so the resurrection WaveState broadcast isn't
                            ignored by the game-over gate.
]]

local FirstDeathFairy = {}

local FAIRY_ATTACHMENTS = {
    {type = "PowerCore",
     title = "Power Core",
     blurb = "Boosts your Core tower's damage. Good for beating stage bosses faster."},
    {type = "Detonator",
     title = "Detonator",
     blurb = "Enemies explode when they die, damaging nearby enemies. Great for clearing waves."},
    {type = "Phoenix",
     title = "Phoenix Charm",
     blurb = "If the heart would die, burns all enemies in a huge area and saves it. Once per long cooldown."},
}

function FirstDeathFairy.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE
    local unlockGameLost    = deps.unlockGameLost

    ReplicatedStorage:WaitForChild(Remotes.Names.ShowFirstDeathFairy).OnClientEvent:Connect(function()
        local old = playerGui:FindFirstChild("ToL_FirstDeathFairy")
        if old then old:Destroy() end
        -- Close the GameOver banner if it's up — the fairy replaces it.
        -- Also unlock the wave HUD (gameLost gate) so the forthcoming
        -- resurrection broadcast isn't ignored by the WaveState handler.
        local over = playerGui:FindFirstChild("ToL_GameOver")
        if over then over:Destroy() end
        unlockGameLost()

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_FirstDeathFairy"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 245  -- above game-over banner (220) and intro (240)
        gui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(6, 10, 20)
        dim.BackgroundTransparency = 0.35
        dim.BorderSizePixel = 0
        dim.Parent = gui

        local card = Instance.new("Frame")
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.new(0.5, 0, 0.5, 0)
        card.Size = UDim2.new(0, IS_MOBILE and 360 or 560, 0, IS_MOBILE and 520 or 540)
        card.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        card.BorderSizePixel = 0
        card.Parent = dim
        local cc = Instance.new("UICorner")
        cc.CornerRadius = UDim.new(0.05, 0)
        cc.Parent = card
        local cstroke = Instance.new("UIStroke")
        cstroke.Thickness = 3
        cstroke.Color = Color3.fromRGB(255, 200, 230)
        cstroke.Parent = card

        local fairy = Instance.new("TextLabel")
        fairy.Size = UDim2.new(1, 0, 0, 54)
        fairy.Position = UDim2.new(0, 0, 0, 14)
        fairy.BackgroundTransparency = 1
        fairy.Text = "✨  A Fairy Appears  ✨"
        fairy.TextColor3 = Color3.fromRGB(255, 220, 240)
        fairy.TextStrokeColor3 = Color3.fromRGB(40, 0, 40)
        fairy.TextStrokeTransparency = 0.3
        fairy.Font = Enum.Font.FredokaOne
        fairy.TextSize = IS_MOBILE and 24 or 30
        fairy.Parent = card

        local speech = Instance.new("TextLabel")
        speech.Size = UDim2.new(1, -32, 0, IS_MOBILE and 100 or 80)
        speech.Position = UDim2.new(0, 16, 0, IS_MOBILE and 70 or 74)
        speech.BackgroundTransparency = 1
        speech.Text = "The Tree of Life is hard. You'll try many times — that's the point.\n\nTake one of these to help you on the way. More help will come if you keep at it."
        speech.TextColor3 = Color3.fromRGB(235, 235, 245)
        speech.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        speech.TextStrokeTransparency = 0.4
        speech.Font = Enum.Font.Gotham
        speech.TextSize = IS_MOBILE and 14 or 16
        speech.TextWrapped = true
        speech.TextXAlignment = Enum.TextXAlignment.Center
        speech.TextYAlignment = Enum.TextYAlignment.Top
        speech.Parent = card

        local choicesHolder = Instance.new("Frame")
        choicesHolder.Size = UDim2.new(1, -32, 1, -(IS_MOBILE and 200 or 180))
        choicesHolder.Position = UDim2.new(0, 16, 0, IS_MOBILE and 180 or 170)
        choicesHolder.BackgroundTransparency = 1
        choicesHolder.Parent = card
        local chLayout = Instance.new("UIListLayout")
        chLayout.FillDirection = Enum.FillDirection.Vertical
        chLayout.Padding = UDim.new(0, 10)
        chLayout.SortOrder = Enum.SortOrder.LayoutOrder
        chLayout.Parent = choicesHolder

        for i, entry in ipairs(FAIRY_ATTACHMENTS) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1, 0, 0, IS_MOBILE and 88 or 92)
            btn.BackgroundColor3 = Color3.fromRGB(44, 50, 70)
            btn.AutoButtonColor = true
            btn.BorderSizePixel = 0
            btn.Text = ""
            btn.LayoutOrder = i
            btn.Parent = choicesHolder
            local bc = Instance.new("UICorner")
            bc.CornerRadius = UDim.new(0.15, 0); bc.Parent = btn

            local title = Instance.new("TextLabel")
            title.Size = UDim2.new(1, -16, 0, 24)
            title.Position = UDim2.new(0, 12, 0, 8)
            title.BackgroundTransparency = 1
            title.Text = entry.title .. "  (Common)"
            title.TextColor3 = Color3.fromRGB(255, 240, 200)
            title.Font = Enum.Font.FredokaOne
            title.TextSize = IS_MOBILE and 18 or 20
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.Parent = btn

            local blurb = Instance.new("TextLabel")
            blurb.Size = UDim2.new(1, -16, 0, IS_MOBILE and 52 or 56)
            blurb.Position = UDim2.new(0, 12, 0, 34)
            blurb.BackgroundTransparency = 1
            blurb.Text = entry.blurb
            blurb.TextColor3 = Color3.fromRGB(210, 220, 235)
            blurb.Font = Enum.Font.Gotham
            blurb.TextSize = IS_MOBILE and 13 or 14
            blurb.TextWrapped = true
            blurb.TextXAlignment = Enum.TextXAlignment.Left
            blurb.TextYAlignment = Enum.TextYAlignment.Top
            blurb.Parent = btn

            btn.MouseButton1Click:Connect(function()
                local r = ReplicatedStorage:FindFirstChild(Remotes.Names.PickFirstDeathAttachment)
                if r then r:FireServer({ attType = entry.type }) end
                gui:Destroy()
            end)
        end
    end)

    -- Co-op toast: fired on players who are NOT the first-death picker
    -- while the picker chooses. Auto-dismisses after 30s or is torn
    -- down by the resurrection WaveState broadcast (indirectly — the
    -- notice is just a banner). Game-over banner + gameLost flag are
    -- cleared here so the forthcoming wave restart isn't ignored.
    ReplicatedStorage:WaitForChild(Remotes.Names.ShowResurrectionNotice).OnClientEvent:Connect(function()
        local over = playerGui:FindFirstChild("ToL_GameOver")
        if over then over:Destroy() end
        unlockGameLost()

        local existing = playerGui:FindFirstChild("ToL_ResurrectionNotice")
        if existing then existing:Destroy() end
        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_ResurrectionNotice"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 246
        gui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(6, 10, 20)
        dim.BackgroundTransparency = 0.5
        dim.BorderSizePixel = 0
        dim.Parent = gui

        local panel = Instance.new("Frame")
        panel.AnchorPoint = Vector2.new(0.5, 0.5)
        panel.Position = UDim2.new(0.5, 0, 0.5, 0)
        panel.Size = UDim2.new(0, IS_MOBILE and 340 or 460, 0, IS_MOBILE and 140 or 160)
        panel.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        panel.BorderSizePixel = 0
        panel.Parent = dim
        local pc = Instance.new("UICorner")
        pc.CornerRadius = UDim.new(0.05, 0); pc.Parent = panel
        local ps = Instance.new("UIStroke")
        ps.Thickness = 2; ps.Color = Color3.fromRGB(255, 200, 230); ps.Parent = panel

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -20, 0, 44)
        title.Position = UDim2.new(0, 10, 0, 18)
        title.BackgroundTransparency = 1
        title.Text = "✨  Someone is being resurrected!  ✨"
        title.TextColor3 = Color3.fromRGB(255, 220, 240)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = IS_MOBILE and 18 or 22
        title.TextWrapped = true
        title.Parent = panel

        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.new(1, -20, 0, 60)
        sub.Position = UDim2.new(0, 10, 0, 64)
        sub.BackgroundTransparency = 1
        sub.Text = "The wave will restart with help from a fairy."
        sub.TextColor3 = Color3.fromRGB(210, 220, 235)
        sub.Font = Enum.Font.Gotham
        sub.TextSize = IS_MOBILE and 14 or 15
        sub.TextWrapped = true
        sub.Parent = panel

        task.delay(30, function() if gui.Parent then gui:Destroy() end end)
    end)
end

return FirstDeathFairy
