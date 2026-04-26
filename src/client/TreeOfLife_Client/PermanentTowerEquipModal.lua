--[[
    PermanentTowerEquipModal.lua — The pedestal modal that lets the
    player browse their owned permanent towers and pick one to equip
    for the next run. Shown when the server fires
    Remotes.ShowPermanentEquip after the player taps the pedestal
    ProximityPrompt.

    Empty collection shows a "defeat the Pickle Lord" hint so the
    pedestal reads as "the place your future permanent towers will live"
    rather than being silently useless.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.IS_MOBILE
      deps.UserInputService    — Escape-key dismissal
      deps.findTowerDefById
]]

local PermanentTowerEquipModal = {}

function PermanentTowerEquipModal.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE
    local UserInputService  = deps.UserInputService
    local findTowerDefById  = deps.findTowerDefById

ReplicatedStorage:WaitForChild(Remotes.Names.ShowPermanentEquip).OnClientEvent:Connect(function(payload)
    local entries = (payload and payload.entries) or {}
    local equippedType = payload and payload.equipped
    local old = playerGui:FindFirstChild("ToL_PermanentEquip")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_PermanentEquip"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 220
    gui.Parent = playerGui

    -- Background dim covers the screen. Clicking the dim also closes the
    -- popup — the panel itself swallows clicks via its TextButton children
    -- so only dim-clicks reach this handler.
    local bg = Instance.new("TextButton")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    bg.BackgroundTransparency = 0.4
    bg.BorderSizePixel = 0
    bg.AutoButtonColor = false
    bg.Text = ""
    bg.Parent = gui
    bg.MouseButton1Click:Connect(function() gui:Destroy() end)

    -- Centered popup panel (not fullscreen). Sized generously to fit the
    -- existing card layout; bg dim still covers the rest of the screen so
    -- the player reads it as a modal but can easily dismiss by clicking
    -- outside the panel or hitting the X.
    local PANEL_W = IS_MOBILE and 520 or 900
    local PANEL_H = IS_MOBILE and 420 or 520
    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
    panel.BackgroundColor3 = Color3.fromRGB(28, 30, 42)
    panel.BackgroundTransparency = 0.05
    panel.BorderSizePixel = 0
    panel.Parent = bg
    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 16)
    panelCorner.Parent = panel
    local panelStroke = Instance.new("UIStroke")
    panelStroke.Thickness = 2
    panelStroke.Color = Color3.fromRGB(90, 90, 110)
    panelStroke.Transparency = 0.3
    panelStroke.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -60, 0, IS_MOBILE and 40 or 60)
    title.Position = UDim2.fromOffset(12, 12)
    title.BackgroundTransparency = 1
    title.Text = "Equip Permanent Tower"
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.4
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 22 or 30
    title.Parent = panel

    -- Close button — top-right X on the panel itself (not the fullscreen dim).
    local closeBtn = Instance.new("TextButton")
    closeBtn.AnchorPoint = Vector2.new(1, 0)
    closeBtn.Size = UDim2.fromOffset(36, 36)
    closeBtn.Position = UDim2.new(1, -12, 0, 12)
    closeBtn.BackgroundColor3 = Color3.fromRGB(160, 60, 60)
    closeBtn.BorderSizePixel = 0
    closeBtn.AutoButtonColor = false
    closeBtn.Text = "×"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.FredokaOne
    closeBtn.TextSize = 26
    closeBtn.Parent = panel
    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0.3, 0)
    closeCorner.Parent = closeBtn
    closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

    -- Escape key closes the popup too.
    local escConn
    escConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Enum.KeyCode.Escape then
            if gui.Parent then gui:Destroy() end
            if escConn then escConn:Disconnect() end
        end
    end)
    gui.AncestryChanged:Connect(function(_, p)
        if not p and escConn then escConn:Disconnect() end
    end)

    if #entries == 0 then
        -- Empty state — first-time pedestal tap before any Pickle Lord kill.
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, -40, 1, -100)
        empty.Position = UDim2.fromOffset(20, 80)
        empty.BackgroundTransparency = 1
        empty.Text = "No permanent towers yet.\n\nDefeat the Pickle Lord to unlock a permanent tower you can carry between runs."
        empty.TextColor3 = Color3.fromRGB(235, 230, 200)
        empty.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        empty.TextStrokeTransparency = 0.4
        empty.Font = Enum.Font.FredokaOne
        empty.TextSize = IS_MOBILE and 18 or 22
        empty.TextWrapped = true
        empty.Parent = panel
        return
    end

    local CARD_W = IS_MOBILE and 200 or 240
    local CARD_H = IS_MOBILE and 260 or 300

    local row = Instance.new("ScrollingFrame")
    row.Size = UDim2.new(1, -32, 0, CARD_H + 30)
    row.Position = UDim2.fromOffset(16, IS_MOBILE and 70 or 90)
    row.BackgroundTransparency = 1
    row.BorderSizePixel = 0
    row.ScrollBarThickness = 6
    row.CanvasSize = UDim2.new(0, 0, 0, 0)  -- auto-sized by layout
    row.AutomaticCanvasSize = Enum.AutomaticSize.X
    row.ScrollingDirection = Enum.ScrollingDirection.X
    row.Parent = panel
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, IS_MOBILE and 12 or 20)
    rowLayout.Parent = row

    for _, entry in ipairs(entries) do
        local isEquipped = entry.isEquipped
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(CARD_W, CARD_H)
        btn.BackgroundColor3 = entry.color or Color3.fromRGB(80, 80, 90)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.Parent = row
        local cornerUi = Instance.new("UICorner")
        cornerUi.CornerRadius = UDim.new(0.08, 0)
        cornerUi.Parent = btn
        if isEquipped then
            -- Stroke outline + brighter tint so the currently equipped one pops.
            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(255, 255, 255)
            stroke.Thickness = 3
            stroke.Parent = btn
        end

        -- Name
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -16, 0, 36)
        nameLabel.Position = UDim2.fromOffset(8, 12)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = entry.displayName or entry.towerId
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.TextStrokeTransparency = 0.3
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = IS_MOBILE and 22 or 28
        nameLabel.Parent = btn

        -- Rarity pill
        local rarityPill = Instance.new("TextLabel")
        rarityPill.AnchorPoint = Vector2.new(0.5, 0)
        rarityPill.Position = UDim2.new(0.5, 0, 0, 52)
        rarityPill.Size = UDim2.fromOffset(IS_MOBILE and 110 or 130, 24)
        rarityPill.BackgroundColor3 = entry.color or Color3.fromRGB(200, 200, 200)
        rarityPill.BackgroundTransparency = 0.1
        rarityPill.BorderSizePixel = 0
        rarityPill.Text = string.upper(entry.rarity or "?")
        rarityPill.TextColor3 = Color3.fromRGB(255, 255, 255)
        rarityPill.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        rarityPill.TextStrokeTransparency = 0.3
        rarityPill.Font = Enum.Font.FredokaOne
        rarityPill.TextSize = IS_MOBILE and 14 or 18
        rarityPill.Parent = btn
        local pillCorner = Instance.new("UICorner")
        pillCorner.CornerRadius = UDim.new(0.4, 0)
        pillCorner.Parent = rarityPill

        -- Icon using the same hotbar icon builder
        local iconHolder = Instance.new("Frame")
        iconHolder.AnchorPoint = Vector2.new(0.5, 0)
        iconHolder.Position = UDim2.new(0.5, 0, 0, 86)
        iconHolder.Size = UDim2.fromOffset(IS_MOBILE and 76 or 96, IS_MOBILE and 76 or 96)
        iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconHolder.BorderSizePixel = 0
        iconHolder.Parent = btn
        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0.12, 0)
        iconCorner.Parent = iconHolder
        do
            local towerDef = findTowerDefById(entry.towerId)
            if towerDef and towerDef.iconBuilder then
                towerDef.iconBuilder(iconHolder)
            end
        end

        -- Description
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -20, 0, 44)
        descLabel.Position = UDim2.fromOffset(10, IS_MOBILE and 174 or 196)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = entry.description or ""
        descLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = 0.3
        descLabel.Font = Enum.Font.FredokaOne
        descLabel.TextSize = IS_MOBILE and 14 or 17
        descLabel.TextWrapped = true
        descLabel.Parent = btn

        -- CTA
        local cta = Instance.new("TextLabel")
        cta.Size = UDim2.new(1, -20, 0, IS_MOBILE and 36 or 42)
        cta.Position = UDim2.new(0, 10, 1, IS_MOBILE and -44 or -52)
        cta.BackgroundColor3 = isEquipped and Color3.fromRGB(120, 120, 130)
            or Color3.fromRGB(60, 170, 80)
        cta.Text = isEquipped and "EQUIPPED" or "EQUIP!"
        cta.TextColor3 = Color3.fromRGB(255, 255, 255)
        cta.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        cta.TextStrokeTransparency = 0.3
        cta.Font = Enum.Font.FredokaOne
        cta.TextSize = IS_MOBILE and 18 or 22
        cta.Parent = btn
        local ctaCorner = Instance.new("UICorner")
        ctaCorner.CornerRadius = UDim.new(0.3, 0)
        ctaCorner.Parent = cta

        btn.MouseButton1Click:Connect(function()
            if isEquipped then return end
            ReplicatedStorage:WaitForChild(Remotes.Names.PermanentTowerEquipped):FireServer({
                towerId = entry.towerId,
            })
            -- Don't close — the server will re-fire ShowPermanentEquip with the
            -- updated "equipped" state; we leave the modal open so the player
            -- sees confirmation on the card they just picked.
        end)
    end
end)

end

return PermanentTowerEquipModal
