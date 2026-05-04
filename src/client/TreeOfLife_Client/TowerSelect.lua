--[[
    TowerSelect.lua — The pre-wave starter-tower picker modal. Server
    fires Remotes.ShowTowerSelect on first TD-room entry (and via the
    failsafe loop if the player misses or dismisses the splash).

    Today the only enabled starter is Power; DoT/CC are stubs flagged
    enabled=false in towerDefs and don't render here. The picker stays
    a modal even with one option so the moment of "you have a tower
    now" lands cleanly.

    Includes a 2-second debounce so portal-touch + failsafe poll firing
    in quick succession can't double-build the picker.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.IS_MOBILE
      deps.TweenService
      deps.towerDefs    — main-chunk table; the picker reads `enabled`,
                          `name`, `desc`, `color`, `iconBuilder` per def.
]]

local TowerSelect = {}

-- Private: attach a UICorner with the given radius scale (4-line dup
-- of the main chunk's `round`; module is self-contained).
local function round(frame, radiusScale)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(radiusScale or 0.12, 0)
    c.Parent = frame
end

function TowerSelect.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE
    local TweenService      = deps.TweenService
    local towerDefs         = deps.towerDefs
    -- UserInputService is optional — only used by the desktop 1/2/3
    -- hotkeys; if a caller forgot to pass it, we just skip hotkeys
    -- rather than break the picker outright.
    local UserInputService  = deps.UserInputService
                              or game:GetService("UserInputService")

local lastShowTowerSelectAt = 0
local function showTowerSelect()
    -- Guard against duplicate UI builds (e.g. portal touch + failsafe loop both firing
    -- in quick succession). Ignore calls within 2s of the previous one.
    local now = os.clock()
    if now - lastShowTowerSelectAt < 2 then return end
    lastShowTowerSelectAt = now

    local old = playerGui:FindFirstChild("ToL_TowerSelect")
    if old then old:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_TowerSelect"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 200
    gui.Parent = playerGui
    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(10, 15, 20)
    bg.BackgroundTransparency = 0.3
    bg.BorderSizePixel = 0
    bg.Parent = gui
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, IS_MOBILE and 40 or 60)
    title.Position = UDim2.fromOffset(0, IS_MOBILE and 8 or 16)
    title.BackgroundTransparency = 1
    title.Text = "Choose Your Starting Tower"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.5
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 28 or 48
    title.Parent = bg
    -- Compact card layout so the whole UI fits below the top-anchored title.
    local CARD_W      = IS_MOBILE and 180 or 240
    local CARD_H      = IS_MOBILE and 210 or 280
    local CARD_HOVER_W = IS_MOBILE and 188 or 250
    local CARD_HOVER_H = IS_MOBILE and 220 or 290
    local ICON_SIZE   = IS_MOBILE and 80 or 120
    local ICON_TOP    = IS_MOBILE and 12 or 16
    local NAME_SIZE   = IS_MOBILE and 24 or 32
    local NAME_TOP    = IS_MOBILE and 96 or 140
    local DESC_SIZE   = IS_MOBILE and 12 or 14
    local DESC_TOP    = IS_MOBILE and 128 or 180
    local CTA_SIZE    = IS_MOBILE and 16 or 20
    local CTA_HEIGHT  = IS_MOBILE and 32 or 38
    local ROW_HEIGHT  = IS_MOBILE and 220 or 300
    local ROW_PADDING = IS_MOBILE and 12 or 24

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
    -- Position the row just below the title, not centered on screen
    row.Position = UDim2.fromOffset(0, IS_MOBILE and 60 or 90)
    row.BackgroundTransparency = 1
    row.Parent = bg
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, ROW_PADDING)
    rowLayout.Parent = row
    local cards = {}
    -- enabledChoices: parallel list of {id} for the 1/2/3 hotkey
    -- dispatch — only enabled cards get a digit. Skipped (disabled
    -- starter / temp reward) defs aren't reachable.
    local enabledChoices = {}
    -- 1-second delay before cards become clickable, to prevent accidental taps
    -- (e.g., finger already on screen when the UI appears).
    -- Short anti-accidental-tap window — if the player tapped the floor
    -- or some other UI just before the modal opened, that tap could
    -- otherwise fall through and auto-select a tower. 0.3s is enough
    -- to catch that without the "swallowed click" feeling a longer
    -- window gave.
    local clickableAt = os.clock() + 0.3
    for _, def in ipairs(towerDefs) do
        -- Temp towers (FrostMelon etc.) are earned from map-boss drops,
        -- not picked at run start. Skip them in the starter picker.
        if def.tempReward then continue end
        local card = Instance.new("TextButton")
        card.Size = UDim2.fromOffset(CARD_W, CARD_H)
        card.BackgroundColor3 = def.color
        card.BorderSizePixel = 0
        card.AutoButtonColor = false
        card.Text = ""
        card.Parent = row
        round(card, 0.08)
        card:SetAttribute("Enabled", def.enabled)
        if not def.enabled then card.BackgroundTransparency = 0.5 end
        local iconBg = Instance.new("Frame")
        iconBg.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
        iconBg.Position = UDim2.new(0.5, -ICON_SIZE/2, 0, ICON_TOP)
        iconBg.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconBg.BorderSizePixel = 0
        iconBg.Parent = card
        round(iconBg, 0.1)
        def.iconBuilder(iconBg)
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -20, 0, 40)
        nameLabel.Position = UDim2.fromOffset(10, NAME_TOP)
        nameLabel.BackgroundTransparency = 1
        -- Hotkey [N] suffix hidden per Matthew 2026-04-27 — hotkeys
        -- still work via the InputBegan listener, just no visual tag.
        nameLabel.Text = def.name
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.TextStrokeTransparency = 0
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = NAME_SIZE
        nameLabel.Parent = card
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -16, 0, 36)
        descLabel.Position = UDim2.fromOffset(8, DESC_TOP)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = def.desc
        descLabel.TextColor3 = Color3.fromRGB(235, 235, 245)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = 0.4
        descLabel.Font = Enum.Font.Gotham
        descLabel.TextSize = DESC_SIZE
        descLabel.TextWrapped = true
        descLabel.Parent = card
        local cta = Instance.new("Frame")
        cta.Size = UDim2.new(1, -16, 0, CTA_HEIGHT)
        cta.Position = UDim2.new(0, 8, 1, -CTA_HEIGHT - 8)
        cta.BackgroundColor3 = def.enabled and def.accent or Color3.fromRGB(80, 80, 85)
        cta.BorderSizePixel = 0
        cta.Parent = card
        round(cta, 0.15)
        local ctaLabel = Instance.new("TextLabel")
        ctaLabel.Size = UDim2.fromScale(1, 1)
        ctaLabel.BackgroundTransparency = 1
        ctaLabel.Text = def.enabled and "SELECT" or "LOCKED"
        ctaLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        ctaLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        ctaLabel.TextStrokeTransparency = 0.3
        ctaLabel.Font = Enum.Font.FredokaOne
        ctaLabel.TextSize = CTA_SIZE
        ctaLabel.Parent = cta
        if def.enabled then
            local capturedId = def.id
            table.insert(enabledChoices, capturedId)
            card.MouseEnter:Connect(function()
                TweenService:Create(card, TweenInfo.new(0.15),
                    {Size = UDim2.fromOffset(CARD_HOVER_W, CARD_HOVER_H)}):Play()
            end)
            card.MouseLeave:Connect(function()
                TweenService:Create(card, TweenInfo.new(0.15),
                    {Size = UDim2.fromOffset(CARD_W, CARD_H)}):Play()
            end)
            card.MouseButton1Click:Connect(function()
                if os.clock() < clickableAt then return end  -- 1s input lockout
                for _, c in ipairs(cards) do c.Active = false end
                ReplicatedStorage:WaitForChild(Remotes.Names.TowerPicked):FireServer(capturedId)
                TweenService:Create(bg, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play()
                for _, c in ipairs(cards) do
                    for _, d in ipairs(c:GetDescendants()) do
                        if d:IsA("Frame") or d:IsA("TextButton") then
                            TweenService:Create(d, TweenInfo.new(0.5),
                                {BackgroundTransparency = 1}):Play()
                        end
                        if d:IsA("TextLabel") then
                            TweenService:Create(d, TweenInfo.new(0.5),
                                {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
                        end
                    end
                    TweenService:Create(c, TweenInfo.new(0.5),
                        {BackgroundTransparency = 1}):Play()
                end
                TweenService:Create(title, TweenInfo.new(0.5),
                    {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
                task.wait(0.6)
                gui:Destroy()
            end)
        end
        table.insert(cards, card)
    end
    -- 1/2/3 hotkeys (desktop only) — fire TowerPicked for the
    -- enabledChoices[idx] tower id. Skips disabled cards. Connection
    -- self-disconnects on gui destroy.
    if not IS_MOBILE then
        local hotkeyConn
        hotkeyConn = UserInputService.InputBegan:Connect(function(input, processed)
            if processed then return end
            if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
            local idx
            if input.KeyCode == Enum.KeyCode.One   then idx = 1
            elseif input.KeyCode == Enum.KeyCode.Two   then idx = 2
            elseif input.KeyCode == Enum.KeyCode.Three then idx = 3
            end
            if not idx then return end
            local towerId = enabledChoices[idx]
            if not towerId then return end
            if os.clock() < clickableAt then return end
            for _, c in ipairs(cards) do c.Active = false end
            ReplicatedStorage:WaitForChild(Remotes.Names.TowerPicked):FireServer(towerId)
            -- Mirror the click-handler tween-out + destroy.
            TweenService:Create(bg, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play()
            for _, c in ipairs(cards) do
                for _, d in ipairs(c:GetDescendants()) do
                    if d:IsA("Frame") or d:IsA("TextButton") then
                        TweenService:Create(d, TweenInfo.new(0.5),
                            {BackgroundTransparency = 1}):Play()
                    end
                    if d:IsA("TextLabel") then
                        TweenService:Create(d, TweenInfo.new(0.5),
                            {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
                    end
                end
                TweenService:Create(c, TweenInfo.new(0.5),
                    {BackgroundTransparency = 1}):Play()
            end
            TweenService:Create(title, TweenInfo.new(0.5),
                {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
            task.delay(0.6, function()
                if gui.Parent then gui:Destroy() end
            end)
            if hotkeyConn then hotkeyConn:Disconnect(); hotkeyConn = nil end
        end)
        gui.AncestryChanged:Connect(function(_, parent)
            if not parent and hotkeyConn then
                hotkeyConn:Disconnect()
                hotkeyConn = nil
            end
        end)
    end

    bg.BackgroundTransparency = 1
    title.TextTransparency = 1
    title.TextStrokeTransparency = 1
    for _, c in ipairs(cards) do
        c.BackgroundTransparency = 1
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("Frame") then d.BackgroundTransparency = 1 end
            if d:IsA("TextLabel") then
                d.TextTransparency = 1
                d.TextStrokeTransparency = 1
            end
        end
    end
    TweenService:Create(bg, TweenInfo.new(0.5), {BackgroundTransparency = 0.3}):Play()
    TweenService:Create(title, TweenInfo.new(0.5),
        {TextTransparency = 0, TextStrokeTransparency = 0.5}):Play()
    for i, card in ipairs(cards) do
        local enabled = card:GetAttribute("Enabled")
        local targetCardBg = enabled and 0 or 0.5
        task.delay(0.1 * i, function()
            TweenService:Create(card, TweenInfo.new(0.4),
                {BackgroundTransparency = targetCardBg}):Play()
            for _, d in ipairs(card:GetDescendants()) do
                if d:IsA("Frame") then
                    TweenService:Create(d, TweenInfo.new(0.4),
                        {BackgroundTransparency = 0}):Play()
                elseif d:IsA("TextLabel") then
                    TweenService:Create(d, TweenInfo.new(0.4),
                        {TextTransparency = 0, TextStrokeTransparency = 0}):Play()
                end
            end
        end)
    end
end

    ReplicatedStorage:WaitForChild(Remotes.Names.ShowTowerSelect).OnClientEvent:Connect(showTowerSelect)
end

return TowerSelect
