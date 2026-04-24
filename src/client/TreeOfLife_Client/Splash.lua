--[[
    Splash.lua — The "Tree of Life" green-gradient title splash that
    plays on first login (server fires Remotes.ShowSplash). Brief fade-
    in / hold / fade-out sequence with a darkened backdrop. Doesn't
    block input — the player can move/look during the splash.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.TweenService
]]

local Splash = {}

local TITLE    = "Tree of Life"
local SUBTITLE = "Save the world from food gone bad"
local FADE_IN  = 0.9
local HOLD     = 2.1
local FADE_OUT = 1.1

function Splash.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local TweenService      = deps.TweenService

    local function showSplash()
        local old = playerGui:FindFirstChild("ToL_Splash")
        if old then old:Destroy() end
        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_Splash"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 100
        gui.Parent = playerGui
        local bg = Instance.new("Frame")
        bg.Size = UDim2.fromScale(1, 1)
        bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        bg.BackgroundTransparency = 1
        bg.BorderSizePixel = 0
        bg.Active = false  -- don't intercept input; player can move/look during splash
        bg.Parent = gui
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0, 120)
        title.Position = UDim2.new(0, 0, 0.38, 0)
        title.BackgroundTransparency = 1
        title.Text = TITLE
        title.TextColor3 = Color3.fromRGB(230, 255, 230)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 84
        title.TextTransparency = 1
        title.TextStrokeColor3 = Color3.fromRGB(20, 80, 30)
        title.TextStrokeTransparency = 1
        title.Parent = bg
        local gradient = Instance.new("UIGradient")
        gradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 255, 180)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 255, 150)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 220, 110)),
        })
        gradient.Rotation = 90
        gradient.Parent = title
        local subtitle = Instance.new("TextLabel")
        subtitle.Size = UDim2.new(1, 0, 0, 40)
        subtitle.Position = UDim2.new(0, 0, 0.58, 0)
        subtitle.BackgroundTransparency = 1
        subtitle.Text = SUBTITLE
        subtitle.TextColor3 = Color3.fromRGB(220, 235, 220)
        subtitle.Font = Enum.Font.Gotham
        subtitle.TextSize = 22
        subtitle.TextTransparency = 1
        subtitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        subtitle.TextStrokeTransparency = 0.5
        subtitle.Parent = bg
        local easeIn = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        TweenService:Create(bg, easeIn, {BackgroundTransparency = 0.25}):Play()
        TweenService:Create(title, easeIn, {TextTransparency = 0, TextStrokeTransparency = 0}):Play()
        TweenService:Create(subtitle, easeIn, {TextTransparency = 0.1}):Play()
        task.wait(FADE_IN + HOLD)
        local easeOut = TweenInfo.new(FADE_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        TweenService:Create(bg, easeOut, {BackgroundTransparency = 1}):Play()
        TweenService:Create(title, easeOut, {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
        TweenService:Create(subtitle, easeOut, {TextTransparency = 1}):Play()
        task.wait(FADE_OUT + 0.2)
        gui:Destroy()
    end

    ReplicatedStorage:WaitForChild(Remotes.Names.ShowSplash).OnClientEvent:Connect(showSplash)
end

return Splash
