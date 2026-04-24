--[[
    LeafMessage.lua — Falling-leaf flavor text. Server fires LeafMessage
    with `{ text, duration, static? }`. The text drifts downward with a
    gentle sway + rotation (the "feather effect"); `static = true`
    suppresses the motion when the surrounding visual beat already
    implies falling — e.g. the rope-ladder drop after a map-1 boss
    defeat, where the ladder itself is what's falling and competing
    motion would muddle the read.

    Each fire spawns its own ScreenGui so consecutive messages stack
    naturally instead of fighting over one slot.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.RunService
]]

local LeafMessage = {}

function LeafMessage.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local RunService        = deps.RunService

    ReplicatedStorage:WaitForChild(Remotes.Names.LeafMessage).OnClientEvent:Connect(function(payload)
        local text = payload and payload.text or ""
        local duration = payload and payload.duration or 6
        local staticMode = payload and payload.static == true
        if text == "" then return end

        -- Stack messages: if one is already up, just push it lower. Cheapest
        -- is to give each its own ScreenGui so they don't collide on cleanup.
        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_LeafMsg"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 220
        gui.Parent = playerGui

        local startY = staticMode and 0.15 or 0.05
        local endY   = staticMode and 0.15 or 0.40

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.8, 0, 0, 60)
        label.AnchorPoint = Vector2.new(0.5, 0)
        label.Position = UDim2.new(0.5, 0, startY, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 26
        label.TextColor3 = Color3.fromRGB(240, 250, 220)
        label.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
        label.TextStrokeTransparency = 0.2
        label.Text = text
        label.TextWrapped = true
        label.Parent = gui

        -- Heartbeat loop: drifts downward with sway+tilt (unless static),
        -- and fades out over the last 30% of the duration.
        local startedAt = os.clock()
        local conn
        conn = RunService.Heartbeat:Connect(function()
            local elapsed = os.clock() - startedAt
            local t = math.clamp(elapsed / duration, 0, 1)
            if not staticMode then
                local y = startY + (endY - startY) * t
                local sway = math.sin(elapsed * 1.8) * 0.04
                label.Position = UDim2.new(0.5 + sway, 0, y, 0)
                label.Rotation = math.sin(elapsed * 1.2) * 6
            end
            if t > 0.7 then
                local fadeT = (t - 0.7) / 0.3
                label.TextTransparency = fadeT
                label.TextStrokeTransparency = 0.2 + fadeT * 0.8
            end
            if elapsed >= duration + 0.2 then
                if conn then conn:Disconnect() end
                if gui.Parent then gui:Destroy() end
            end
        end)
    end)
end

return LeafMessage
