--[[
    PermanentTowerRewardModal.lua — The 3-card modal shown when the
    Pickle Lord (run boss) is defeated. Server fires
    Remotes.ShowPermanentTowerReward with payload either:

      { title, subtitle, cards = { card1..3 } }            — picker state
      { title, subtitle, cards = {}, confirmation=true }   — post-pick result

    Cards reuse the temp-tower-picker card layout but with GOLD category
    styling to signal "permanent — kept between runs."

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.IS_MOBILE
      deps.findTowerDefById
]]

local PermanentTowerRewardModal = {}

function PermanentTowerRewardModal.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE
    local findTowerDefById  = deps.findTowerDefById

ReplicatedStorage:WaitForChild(Remotes.Names.ShowPermanentTowerReward).OnClientEvent:Connect(function(payload)
    local cards = (payload and payload.cards) or {}
    local old = playerGui:FindFirstChild("ToL_PermanentTowerReward")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_PermanentTowerReward"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 225
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(40, 20, 12)  -- warm dim for celebration
    bg.BackgroundTransparency = 0.15
    bg.BorderSizePixel = 0
    bg.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, IS_MOBILE and 40 or 54)
    title.Position = UDim2.new(0, 0, 0, IS_MOBILE and 60 or 70)
    title.BackgroundTransparency = 1
    title.Text = payload and payload.title or "PERMANENT TOWER REWARD"
    title.TextColor3 = Color3.fromRGB(255, 220, 120)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.3
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 26 or 38
    title.Parent = bg

    if payload and payload.subtitle then
        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.new(1, -40, 0, IS_MOBILE and 36 or 44)
        sub.Position = UDim2.new(0, 20, 0, IS_MOBILE and 102 or 124)
        sub.BackgroundTransparency = 1
        sub.Text = payload.subtitle
        sub.TextColor3 = Color3.fromRGB(255, 240, 200)
        sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        sub.TextStrokeTransparency = 0.4
        sub.Font = Enum.Font.FredokaOne
        sub.TextSize = IS_MOBILE and 16 or 22
        sub.TextWrapped = true
        sub.Parent = bg
    end

    -- Confirmation state: just a dismiss button, no cards to pick.
    if payload and payload.confirmation then
        local ok = Instance.new("TextButton")
        ok.AnchorPoint = Vector2.new(0.5, 0.5)
        ok.Position = UDim2.new(0.5, 0, 0.55, 0)
        ok.Size = UDim2.new(0, IS_MOBILE and 220 or 280, 0, IS_MOBILE and 48 or 56)
        ok.BackgroundColor3 = Color3.fromRGB(220, 170, 60)
        ok.BorderSizePixel = 0
        ok.AutoButtonColor = false
        ok.Text = "CONTINUE"
        ok.TextColor3 = Color3.fromRGB(255, 255, 255)
        ok.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        ok.TextStrokeTransparency = 0.3
        ok.Font = Enum.Font.FredokaOne
        ok.TextSize = IS_MOBILE and 22 or 28
        ok.Parent = bg
        local okc = Instance.new("UICorner")
        okc.CornerRadius = UDim.new(0.3, 0)
        okc.Parent = ok
        ok.MouseButton1Click:Connect(function() gui:Destroy() end)
        return
    end

    local CARD_W = IS_MOBILE and 200 or 270
    local CARD_H = IS_MOBILE and 280 or 360

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, CARD_H)
    row.Position = UDim2.new(0, 0, 0, IS_MOBILE and 156 or 190)
    row.BackgroundTransparency = 1
    row.Parent = bg
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, IS_MOBILE and 12 or 24)
    rowLayout.Parent = row

    local clickableAt = os.clock() + 0.6

    for cardIndex, card in ipairs(cards) do
        local isDup = card.isDuplicate == true
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, CARD_W, 0, CARD_H)
        btn.BackgroundColor3 = card.color or Color3.fromRGB(80, 80, 90)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.ClipsDescendants = true
        btn.Parent = row
        local cornerUi = Instance.new("UICorner")
        cornerUi.CornerRadius = UDim.new(0.08, 0)
        cornerUi.Parent = btn

        -- Gold stroke + banner to distinguish permanent picks from temp ones.
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(255, 210, 90)
        stroke.Thickness = 5
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Parent = btn

        local banner = Instance.new("TextLabel")
        banner.Size = UDim2.new(1, 0, 0, IS_MOBILE and 28 or 34)
        banner.BackgroundColor3 = Color3.fromRGB(220, 170, 60)
        banner.BorderSizePixel = 0
        banner.Text = isDup and "ALREADY OWNED" or "PERMANENT"
        banner.TextColor3 = Color3.fromRGB(40, 20, 0)
        banner.Font = Enum.Font.FredokaOne
        banner.TextSize = IS_MOBILE and 18 or 22
        banner.Parent = btn

        -- Tower name
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -16, 0, 36)
        nameLabel.Position = UDim2.new(0, 8, 0, IS_MOBILE and 34 or 40)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = card.displayName or "?"
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.TextStrokeTransparency = 0.3
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = IS_MOBILE and 22 or 28
        nameLabel.Parent = btn

        -- Rarity pill
        local rarityPill = Instance.new("TextLabel")
        rarityPill.AnchorPoint = Vector2.new(0.5, 0)
        rarityPill.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 70 or 80)
        rarityPill.Size = UDim2.new(0, IS_MOBILE and 110 or 140, 0, IS_MOBILE and 24 or 28)
        rarityPill.BackgroundColor3 = card.color or Color3.fromRGB(200, 200, 200)
        rarityPill.BorderSizePixel = 0
        rarityPill.Text = string.upper(card.rarity or "?")
        rarityPill.TextColor3 = Color3.fromRGB(255, 255, 255)
        rarityPill.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        rarityPill.TextStrokeTransparency = 0.3
        rarityPill.Font = Enum.Font.FredokaOne
        rarityPill.TextSize = IS_MOBILE and 14 or 18
        rarityPill.Parent = btn
        local pillCorner = Instance.new("UICorner")
        pillCorner.CornerRadius = UDim.new(0.4, 0)
        pillCorner.Parent = rarityPill

        -- Tower icon (reuse hotbar icon builders)
        local iconHolder = Instance.new("Frame")
        iconHolder.AnchorPoint = Vector2.new(0.5, 0)
        iconHolder.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 106 or 120)
        iconHolder.Size = UDim2.new(0, IS_MOBILE and 72 or 96, 0, IS_MOBILE and 72 or 96)
        iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconHolder.BorderSizePixel = 0
        iconHolder.Parent = btn
        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0.12, 0)
        iconCorner.Parent = iconHolder
        do
            local towerDef = findTowerDefById(card.towerId)
            if towerDef and towerDef.iconBuilder then
                towerDef.iconBuilder(iconHolder)
            end
        end

        -- Description
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -20, 0, 40)
        descLabel.Position = UDim2.new(0, 10, 0, IS_MOBILE and 192 or 232)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = card.description or ""
        descLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = 0.3
        descLabel.Font = Enum.Font.FredokaOne
        descLabel.TextSize = IS_MOBILE and 14 or 17
        descLabel.TextWrapped = true
        descLabel.Parent = btn

        -- Dup hint
        if isDup and card.ownedRarity then
            local dupHint = Instance.new("TextLabel")
            dupHint.Size = UDim2.new(1, -20, 0, 22)
            dupHint.Position = UDim2.new(0, 10, 0, IS_MOBILE and 236 or 280)
            dupHint.BackgroundTransparency = 1
            dupHint.Text = "(you have " .. tostring(card.ownedRarity) .. ")"
            dupHint.TextColor3 = Color3.fromRGB(255, 220, 150)
            dupHint.Font = Enum.Font.FredokaOne
            dupHint.TextSize = IS_MOBILE and 14 or 16
            dupHint.Parent = btn
        end

        -- CTA
        local cta = Instance.new("TextLabel")
        cta.Size = UDim2.new(1, -20, 0, IS_MOBILE and 38 or 44)
        cta.Position = UDim2.new(0, 10, 1, IS_MOBILE and -46 or -54)
        cta.BackgroundColor3 = isDup and Color3.fromRGB(100, 70, 30)
            or Color3.fromRGB(220, 170, 60)
        cta.Text = isDup and "NO UPGRADE" or "MAKE PERMANENT!"
        cta.TextColor3 = isDup and Color3.fromRGB(255, 220, 150) or Color3.fromRGB(40, 20, 0)
        cta.Font = Enum.Font.FredokaOne
        cta.TextSize = IS_MOBILE and 18 or 22
        cta.Parent = btn
        local ctaCorner = Instance.new("UICorner")
        ctaCorner.CornerRadius = UDim.new(0.3, 0)
        ctaCorner.Parent = cta

        btn.MouseButton1Click:Connect(function()
            if os.clock() < clickableAt then return end
            ReplicatedStorage:WaitForChild(Remotes.Names.PermanentTowerPicked):FireServer({
                cardIndex = cardIndex,
            })
            -- Server will re-fire ShowPermanentTowerReward with confirmation=true,
            -- which rebuilds the modal. Leave the modal up until then.
        end)
    end
end)

end

return PermanentTowerRewardModal
