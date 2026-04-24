--[[
    UpgradePicker.lua — The 3-card "pick an upgrade" modal shown after
    every wave clear (and once at first-tower-placed). Server fires
    Remotes.ShowUpgrades with a payload; this module renders the cards,
    routes a tap to UpgradePicked, and tears the modal down.

    The card visual is layered: rarity-tinted body + Core/Aux category
    banner (CORE = black banner / AUX = white banner with rarity-color
    border for at-a-glance rarity scanning) + rarity label + description
    + "TAP TO CLAIM" CTA. See in-line comments for the apron trick that
    flattens the banner's rounded bottom edge.

    Note: a SECOND ShowUpgrades handler later in init.client.lua adds the
    REROLL + USE TOKEN buttons after this one builds the picker. They run
    on the same OnClientEvent fire (Roblox sequences subscribers), so
    keeping the reroll handler in the main chunk for now is fine.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.IS_MOBILE
      deps.UserInputService
]]

local UpgradePicker = {}

function UpgradePicker.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE
    local UserInputService  = deps.UserInputService

    ReplicatedStorage:WaitForChild(Remotes.Names.ShowUpgrades).OnClientEvent:Connect(function(payload)
        local cards = payload.cards or {}
        local old = playerGui:FindFirstChild("ToL_UpgradePicker")
        if old then old:Destroy() end

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_UpgradePicker"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 220
        gui.Parent = playerGui

        local bg = Instance.new("Frame")
        bg.Size = UDim2.fromScale(1, 1)
        bg.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
        bg.BackgroundTransparency = 0.2
        bg.BorderSizePixel = 0
        bg.Parent = gui

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0, IS_MOBILE and 40 or 60)
        title.Position = UDim2.new(0, 0, 0, IS_MOBILE and 100 or 110)
        title.BackgroundTransparency = 1
        if (payload.wave or 0) == 0 then
            title.Text = "First Tower Bonus — Pick an Upgrade"
        else
            title.Text = "Wave " .. payload.wave .. " Cleared — Upgrade Your Tower"
        end
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        title.TextStrokeTransparency = 0.4
        title.Font = Enum.Font.FredokaOne
        title.TextSize = IS_MOBILE and 22 or 36
        title.Parent = bg

        local CARD_W = IS_MOBILE and 180 or 240
        local CARD_H = IS_MOBILE and 210 or 280

        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, CARD_H)
        row.Position = UDim2.new(0, 0, 0, IS_MOBILE and 150 or 180)
        row.BackgroundTransparency = 1
        row.Parent = bg
        local rowLayout = Instance.new("UIListLayout")
        rowLayout.FillDirection = Enum.FillDirection.Horizontal
        rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        rowLayout.Padding = UDim.new(0, IS_MOBILE and 12 or 24)
        rowLayout.Parent = row

        local clickableAt = os.clock() + 0.6  -- short anti-accidental-tap lockout

        -- Category styles:
        --   Core: solid black border + black banner, white text. High contrast,
        --         category-forward. Core is the workhorse; identity first, rarity
        --         second (you still read it on the rarity label inside).
        --   Aux:  border tinted by rarity + white banner with black text. The
        --         rarity-colored border lets the player scan the row of Aux
        --         options and immediately see which is rarer without reading
        --         the rarity label. Banner stays white for legibility of the
        --         "AUX" label across every rarity.
        local CORE_BORDER = Color3.fromRGB(  0,   0,   0)
        local CORE_BANNER = Color3.fromRGB(  0,   0,   0)
        local CORE_TEXT   = Color3.fromRGB(255, 255, 255)
        local AUX_BANNER  = Color3.fromRGB(255, 255, 255)
        local AUX_TEXT    = Color3.fromRGB(  0,   0,   0)

        -- Absolute corner radius shared by card + banner. Must be smaller
        -- than half the banner height or Roblox's UICorner clamps the radius
        -- and the card/banner no longer match. Banner is 28/34 tall, so 12
        -- stays safely under half-height on both.
        local CARD_CORNER_PX = 12

        for _, card in ipairs(cards) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(0, CARD_W, 0, CARD_H)
            btn.BackgroundColor3 = card.color or Color3.fromRGB(80, 80, 90)
            btn.BorderSizePixel = 0
            btn.AutoButtonColor = false
            btn.Text = ""
            btn.Parent = row
            local cornerUi = Instance.new("UICorner")
            cornerUi.CornerRadius = UDim.new(0, CARD_CORNER_PX)
            cornerUi.Parent = btn

            -- Category border + banner. Core = black; Aux = rarity-colored
            -- border (so the player can scan "which of these Aux cards is
            -- rarest" at a glance) with a white banner for legibility.
            local cardTarget = card.target or "Core"
            local isAux = (cardTarget == "Aux")
            local rarityColor = card.color or Color3.fromRGB(200, 200, 200)
            local borderColor = isAux and rarityColor or CORE_BORDER
            local bannerColor = isAux and AUX_BANNER   or CORE_BANNER
            local textColor   = isAux and AUX_TEXT     or CORE_TEXT

            local stroke = Instance.new("UIStroke")
            stroke.Color = borderColor
            -- Aux border is the rarity color, which matches the card body. A
            -- thicker stroke ensures the border's OUTER edge (meeting the dim
            -- modal backdrop) stays visibly distinct from the card body.
            stroke.Thickness = isAux and 6 or 4
            stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            stroke.Parent = btn

            -- Full-width top banner: CORE / AUX. The banner has its own UICorner
            -- with the same absolute radius as the card so its TOP corners
            -- precisely follow the card's top corners. The banner's BOTTOM
            -- corners would also round (creating "bumps" where the card body
            -- peeks through) — we cover them with a small rectangular "apron"
            -- drawn in the banner's color, just below the banner's rounded
            -- bottom, which visually flattens the banner's base.
            local BANNER_H = IS_MOBILE and 28 or 34
            local banner = Instance.new("TextLabel")
            banner.Size = UDim2.new(1, 0, 0, BANNER_H)
            banner.Position = UDim2.new(0, 0, 0, 0)
            banner.BackgroundColor3 = bannerColor
            banner.BorderSizePixel = 0
            banner.Text = string.upper(cardTarget)
            banner.TextColor3 = textColor
            banner.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            banner.TextStrokeTransparency = isAux and 1 or 0.3
            banner.Font = Enum.Font.FredokaOne
            banner.TextSize = IS_MOBILE and 18 or 22
            banner.ZIndex = 2  -- sits above the apron so CORE/AUX text isn't clipped
            banner.Parent = btn
            local bannerCorner = Instance.new("UICorner")
            bannerCorner.CornerRadius = UDim.new(0, CARD_CORNER_PX)
            bannerCorner.Parent = banner
            -- Apron: a full-width rectangular strip that covers the banner's
            -- rounded bottom corners. Occupies Y = (BANNER_H - radius) to
            -- Y = BANNER_H, same color as the banner. Below the card's own
            -- rounded top-corner area (at Y < radius), so the apron fits
            -- cleanly inside the card's straight-edged middle region. ZIndex
            -- is 1 (below banner at 2) so banner text renders on top of the
            -- apron strip, otherwise the apron clips the bottom of the text.
            local apron = Instance.new("Frame")
            apron.Size = UDim2.new(1, 0, 0, CARD_CORNER_PX)
            apron.Position = UDim2.new(0, 0, 0, BANNER_H - CARD_CORNER_PX)
            apron.BackgroundColor3 = bannerColor
            apron.BorderSizePixel = 0
            apron.ZIndex = 1
            apron.Parent = btn

            -- Rarity label (below the banner)
            local rarityLabel = Instance.new("TextLabel")
            rarityLabel.Size = UDim2.new(1, -16, 0, 32)
            rarityLabel.Position = UDim2.new(0, 8, 0, IS_MOBILE and 34 or 42)
            rarityLabel.BackgroundTransparency = 1
            rarityLabel.Text = string.upper(card.rarity or "?")
            rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
            rarityLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            rarityLabel.TextStrokeTransparency = 0.3
            rarityLabel.Font = Enum.Font.FredokaOne
            rarityLabel.TextSize = IS_MOBILE and 20 or 26
            rarityLabel.Parent = btn

            -- Description
            local descLabel = Instance.new("TextLabel")
            descLabel.Size = UDim2.new(1, -20, 0, 60)
            descLabel.Position = UDim2.new(0, 10, 0.5, -30)
            descLabel.BackgroundTransparency = 1
            descLabel.Text = card.description or ""
            descLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
            descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            descLabel.TextStrokeTransparency = 0.3
            descLabel.Font = Enum.Font.FredokaOne
            descLabel.TextSize = IS_MOBILE and 20 or 26
            descLabel.TextWrapped = true
            descLabel.Parent = btn

            local cta = Instance.new("TextLabel")
            cta.Size = UDim2.new(1, -20, 0, 32)
            cta.Position = UDim2.new(0, 10, 1, -44)
            cta.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            cta.BackgroundTransparency = 0.5
            cta.Text = "TAP TO CLAIM"
            cta.TextColor3 = Color3.fromRGB(255, 255, 255)
            cta.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            cta.TextStrokeTransparency = 0.3
            cta.Font = Enum.Font.FredokaOne
            cta.TextSize = IS_MOBILE and 14 or 18
            cta.Parent = btn
            local ctaCorner = Instance.new("UICorner")
            ctaCorner.CornerRadius = UDim.new(0.3, 0)
            ctaCorner.Parent = cta

            btn.MouseButton1Click:Connect(function()
                if os.clock() < clickableAt then return end
                ReplicatedStorage:WaitForChild(Remotes.Names.UpgradePicked):FireServer(card)
                -- Disable first so the screen-space GUI stops absorbing input
                -- this same frame; destroy on task.defer so any in-flight input
                -- events see the gui as non-interactive rather than a torn-down-
                -- but-still-queued reference. MouseBehavior reset force-releases
                -- any mouse capture state Roblox's GuiService held onto during
                -- the click — without it, right-click-to-rotate sometimes no-ops
                -- for a second or two after the picker closes.
                gui.Enabled = false
                UserInputService.MouseBehavior = Enum.MouseBehavior.Default
                task.defer(function() if gui.Parent then gui:Destroy() end end)
            end)
        end
    end)
end

return UpgradePicker
