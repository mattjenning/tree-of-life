--[[
    IntroSplash.lua — first-time intro modal shown once per session on
    first portal entry. Briefly introduces the core concepts: protect
    the heart, Core vs Aux towers, choosing upgrade cards. Reads
    plainly for a 10-year-old player; "Aux, not axe" is the one-joke
    we lean into so the terminology lands.

    Extracted from init.client.lua to ease the main chunk's Luau
    200-register ceiling. The module is self-contained — no outward
    callbacks needed. All state lives in the OnClientEvent closure.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes           — shared Remotes module (for Names lookup)
      deps.IS_MOBILE         — layout-sizing flag
]]

local IntroSplash = {}

function IntroSplash.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE

    ReplicatedStorage:WaitForChild(Remotes.Names.ShowIntro).OnClientEvent:Connect(function()
        local old = playerGui:FindFirstChild("ToL_Intro")
        if old then old:Destroy() end

        -- Pause the game while the intro is up — otherwise the first wave
        -- can start marching while the player is still reading the tutorial.
        -- SetGameSpeed(0) = paused (the speed system preserves the prior
        -- value so unpause restores whatever speed the player had).
        local setSpeed = ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
        if setSpeed then setSpeed:FireServer(0) end

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_Intro"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 240  -- above most other modals during first-entry
        gui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
        dim.BackgroundTransparency = 0.15
        dim.BorderSizePixel = 0
        dim.Parent = gui

        local CARD_W = IS_MOBILE and 340 or 520
        -- Height sized to 4 bullets (was 5). Formula: top (78/90) + bullets
        -- (4 rows @ 60/66 + 3 gaps @ 10/14) + button-area (92/110) ≈ 440/506.
        local CARD_H = IS_MOBILE and 450 or 510
        local card = Instance.new("Frame")
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.fromScale(0.5, 0.5)
        card.Size = UDim2.fromOffset(CARD_W, CARD_H)
        card.BackgroundColor3 = Color3.fromRGB(28, 32, 42)
        card.BorderSizePixel = 0
        card.Parent = dim
        local cc = Instance.new("UICorner")
        cc.CornerRadius = UDim.new(0.05, 0)
        cc.Parent = card
        local cstroke = Instance.new("UIStroke")
        cstroke.Thickness = 3
        cstroke.Color = Color3.fromRGB(120, 200, 130)
        cstroke.Parent = card

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -20, 0, IS_MOBILE and 46 or 56)
        title.Position = UDim2.fromOffset(10, IS_MOBILE and 14 or 18)
        title.BackgroundTransparency = 1
        title.Text = "Welcome to the Tree of Life!"
        title.TextColor3 = Color3.fromRGB(255, 240, 180)
        title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        title.TextStrokeTransparency = 0.3
        title.Font = Enum.Font.FredokaOne
        title.TextSize = IS_MOBILE and 26 or 34
        title.TextWrapped = true
        title.Parent = card

        -- Body: a list of short bullet lines. Each bullet line has a colored
        -- dot prefix (or category swatch) so the reader scans by color.
        local BULLETS = {
            { dot = Color3.fromRGB(255, 215,  70),
              text = "Protect the Golden Pickle." },
            { dot = Color3.fromRGB(  0,   0,   0),  -- CORE banner color = black
              text = "You have one and only one CORE TOWER. Use it well." },
            { dot = Color3.fromRGB(255, 255, 255),  -- AUX banner color = white
              text = "AUX TOWERS are bonus towers you earn from beating a map. They will help you on your run." },
            { dot = Color3.fromRGB(120, 200, 140),
              text = "Choose your upgrade cards wisely!" },
        }

        local bulletsHolder = Instance.new("Frame")
        bulletsHolder.Size = UDim2.new(1, -32, 1, -(IS_MOBILE and 170 or 190))
        bulletsHolder.Position = UDim2.fromOffset(16, IS_MOBILE and 78 or 90)
        bulletsHolder.BackgroundTransparency = 1
        bulletsHolder.Parent = card
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.Padding = UDim.new(0, IS_MOBILE and 10 or 14)
        layout.Parent = bulletsHolder

        for _, bullet in ipairs(BULLETS) do
            local row = Instance.new("Frame")
            row.Size = UDim2.new(1, 0, 0, IS_MOBILE and 60 or 66)
            row.BackgroundTransparency = 1
            row.Parent = bulletsHolder

            local dot = Instance.new("Frame")
            dot.Size = UDim2.fromOffset(14, 14)
            dot.Position = UDim2.fromOffset(0, IS_MOBILE and 6 or 8)
            dot.BackgroundColor3 = bullet.dot
            dot.BorderSizePixel = 0
            dot.Parent = row
            local dotCorner = Instance.new("UICorner")
            dotCorner.CornerRadius = UDim.new(0.5, 0)
            dotCorner.Parent = dot

            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(1, -26, 1, 0)
            lbl.Position = UDim2.fromOffset(26, 0)
            lbl.BackgroundTransparency = 1
            lbl.Text = bullet.text
            lbl.TextColor3 = Color3.fromRGB(235, 235, 240)
            lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            lbl.TextStrokeTransparency = 0.5
            lbl.Font = Enum.Font.Gotham
            lbl.TextSize = IS_MOBILE and 15 or 18
            lbl.TextWrapped = true
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.TextYAlignment = Enum.TextYAlignment.Top
            lbl.Parent = row
        end

        local gotIt = Instance.new("TextButton")
        gotIt.AnchorPoint = Vector2.new(0.5, 1)
        gotIt.Size = UDim2.fromOffset(IS_MOBILE and 220 or 280, IS_MOBILE and 48 or 54)
        gotIt.Position = UDim2.new(0.5, 0, 1, IS_MOBILE and -16 or -22)
        gotIt.BackgroundColor3 = Color3.fromRGB(60, 170, 80)
        gotIt.BorderSizePixel = 0
        gotIt.AutoButtonColor = false
        gotIt.Text = "GOT IT!"
        gotIt.TextColor3 = Color3.fromRGB(255, 255, 255)
        gotIt.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        gotIt.TextStrokeTransparency = 0.3
        gotIt.Font = Enum.Font.FredokaOne
        gotIt.TextSize = IS_MOBILE and 22 or 28
        gotIt.Parent = card
        local gc = Instance.new("UICorner")
        gc.CornerRadius = UDim.new(0.25, 0)
        gc.Parent = gotIt
        gotIt.MouseButton1Click:Connect(function()
            gui:Destroy()
            -- Resume the game at 1x after the player dismisses the intro.
            -- (They can re-pause via the speed-bar HUD if they want.)
            local setSpeed2 = ReplicatedStorage:FindFirstChild(Remotes.Names.SetGameSpeed)
            if setSpeed2 then setSpeed2:FireServer(1) end
        end)
    end)
end

return IntroSplash
