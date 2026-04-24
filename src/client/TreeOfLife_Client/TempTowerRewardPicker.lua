--[[
    TempTowerRewardPicker.lua — The 3-card reward picker shown after a
    map boss is defeated. Server fires Remotes.ShowTempTowerReward with
    payload {title, cards = {{towerId, rarity, color, stats, ...}, ...}}.
    Each card describes one of the 9 aux towers, tinted by rarity.

    DUD CARD HANDLING:
    Cards arrive flagged dud=true if the player already owns the same
    aux at equal-or-higher rarity. After a brief reveal the card visually
    morphs into a "+1 TOKEN" card (same slot — server resolves whether
    the click grants a token or a tower based on the cardIndex).

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.IS_MOBILE
      deps.TweenService
      deps.UserInputService
      deps.findTowerDefById  - fn(id) -> towerDef table
]]

local TempTowerRewardPicker = {}

-- Plain-English summary of a tower's special mechanic.
local function describeSecondaryStats(stats)
    if stats.slowPct and stats.slowSeconds then
        return "Slows enemies down"
    elseif stats.stunSeconds and stats.stunCooldown then
        return "Freezes enemies in place"
    elseif stats.pierceCount then
        return ("Shoots through %d enemies"):format(stats.pierceCount)
    elseif stats.chainJumps then
        return ("Lightning jumps to %d more"):format(stats.chainJumps)
    elseif stats.cloudRadius and stats.cloudSeconds then
        return "Leaves a poison cloud"
    elseif stats.patchRadius then
        return "Sticky trap slows + hurts"
    elseif stats.splashRadius then
        return "Splash damage"
    elseif stats.blastRadius then
        return "Huge explosion"
    else
        return "Strong single shot"
    end
end

-- Size bucket from a footprint.
local function describeSize(fw, fd)
    local m = math.max(fw or 4, fd or 4)
    if m <= 4 then return "Small"
    elseif m <= 6 then return "Medium"
    elseif m <= 8 then return "Big"
    else return "HUGE" end
end

function TempTowerRewardPicker.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE
    local TweenService      = deps.TweenService
    local UserInputService  = deps.UserInputService
    local findTowerDefById  = deps.findTowerDefById

ReplicatedStorage:WaitForChild(Remotes.Names.ShowTempTowerReward).OnClientEvent:Connect(function(payload)
    local cards = payload.cards or {}
    local old = playerGui:FindFirstChild("ToL_TempTowerPicker")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_TempTowerPicker"
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
    title.Position = UDim2.new(0, 0, 0, IS_MOBILE and 70 or 80)
    title.BackgroundTransparency = 1
    title.Text = payload.title or "Boss Defeated — Choose a Temporary Tower"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    title.TextStrokeTransparency = 0.4
    title.Font = Enum.Font.FredokaOne
    title.TextSize = IS_MOBILE and 22 or 34
    title.Parent = bg

    -- Temp tower cards need more vertical room than upgrade cards because
    -- they pack name + rarity + description + stats + secondary + footprint
    -- + stock into one card. Height tuned so all blocks breathe.
    local CARD_W = IS_MOBILE and 200 or 270
    local CARD_H = IS_MOBILE and 280 or 360

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, CARD_H)
    row.Position = UDim2.new(0, 0, 0, IS_MOBILE and 120 or 150)
    row.BackgroundTransparency = 1
    row.Parent = bg
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, IS_MOBILE and 12 or 24)
    rowLayout.Parent = row

    -- Anti-accidental-tap lockout. Also gives the dud-to-token animation
    -- room to complete before the player can click (so they visually see
    -- the card become a token before picking it).
    local clickableAt = os.clock() + 0.9

    for cardIndex, card in ipairs(cards) do
        local dud = card.dud == true
        local baseColor = card.color or Color3.fromRGB(80, 80, 90)
        local dudBg = Color3.fromRGB(55, 55, 60)

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, CARD_W, 0, CARD_H)
        btn.BackgroundColor3 = dud and dudBg or baseColor
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.Parent = row
        local cornerUi = Instance.new("UICorner")
        cornerUi.CornerRadius = UDim.new(0.08, 0)
        cornerUi.Parent = btn

        local function tTxt() return dud and 0.5 or 0 end
        local function tStroke() return dud and 0.8 or 0.3 end

        -- Tower display name — BIG top banner, primary read.
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -16, 0, 40)
        nameLabel.Position = UDim2.new(0, 8, 0, 14)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = card.displayName or "?"
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.TextStrokeTransparency = tStroke()
        nameLabel.TextTransparency = tTxt()
        nameLabel.Font = Enum.Font.FredokaOne
        nameLabel.TextSize = IS_MOBILE and 24 or 32
        nameLabel.Parent = btn

        -- Tower icon — use the same flat icon the hotbar uses so the kid
        -- recognizes the tower visually. Big central square.
        local ICON_BG = IS_MOBILE and 72 or 96
        local iconHolder = Instance.new("Frame")
        iconHolder.AnchorPoint = Vector2.new(0.5, 0)
        iconHolder.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 58 or 62)
        iconHolder.Size = UDim2.new(0, ICON_BG, 0, ICON_BG)
        iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
        iconHolder.BackgroundTransparency = dud and 0.3 or 0
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

        -- Rarity pill — small colored strip under the icon. Server already
        -- sent the rarity color on card.color (same palette as upgrade cards).
        local rarityColor = card.color or Color3.fromRGB(200, 200, 200)
        local rarityPill = Instance.new("TextLabel")
        rarityPill.AnchorPoint = Vector2.new(0.5, 0)
        rarityPill.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 138 or 168)
        rarityPill.Size = UDim2.new(0, IS_MOBILE and 110 or 140, 0, IS_MOBILE and 24 or 28)
        rarityPill.BackgroundColor3 = rarityColor
        rarityPill.BackgroundTransparency = dud and 0.5 or 0.1
        rarityPill.BorderSizePixel = 0
        rarityPill.Text = string.upper(card.rarity or "?")
        rarityPill.TextColor3 = Color3.fromRGB(255, 255, 255)
        rarityPill.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        rarityPill.TextStrokeTransparency = tStroke()
        rarityPill.TextTransparency = tTxt()
        rarityPill.Font = Enum.Font.FredokaOne
        rarityPill.TextSize = IS_MOBILE and 14 or 18
        rarityPill.Parent = btn
        local pillCorner = Instance.new("UICorner")
        pillCorner.CornerRadius = UDim.new(0.4, 0)
        pillCorner.Parent = rarityPill

        -- Description — simple sentence describing what the tower feels like.
        local descLabel = Instance.new("TextLabel")
        descLabel.Size = UDim2.new(1, -20, 0, IS_MOBILE and 44 or 52)
        descLabel.Position = UDim2.new(0, 10, 0, IS_MOBILE and 168 or 204)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = card.description or ""
        descLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        descLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLabel.TextStrokeTransparency = tStroke()
        descLabel.TextTransparency = tTxt()
        descLabel.Font = Enum.Font.FredokaOne
        descLabel.TextSize = IS_MOBILE and 15 or 18
        descLabel.TextWrapped = true
        descLabel.Parent = btn

        -- Special ability — plain-English mechanic summary, highlighted.
        local stats = card.stats or {}
        local specialLabel = Instance.new("TextLabel")
        specialLabel.Size = UDim2.new(1, -20, 0, IS_MOBILE and 22 or 28)
        specialLabel.Position = UDim2.new(0, 10, 0, IS_MOBILE and 212 or 258)
        specialLabel.BackgroundTransparency = 1
        specialLabel.Text = describeSecondaryStats(stats)
        specialLabel.TextColor3 = Color3.fromRGB(255, 250, 210)
        specialLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        specialLabel.TextStrokeTransparency = tStroke()
        specialLabel.TextTransparency = tTxt()
        specialLabel.Font = Enum.Font.FredokaOne
        specialLabel.TextSize = IS_MOBILE and 15 or 19
        specialLabel.Parent = btn

        -- Badges row: "Place N"  ·  "Size"
        local footprint = card.footprint or { w = 4, h = 4 }
        local fw = footprint.w or footprint[1] or 4
        local fd = footprint.h or footprint[2] or 4
        local badgeRow = Instance.new("TextLabel")
        badgeRow.Size = UDim2.new(1, -20, 0, IS_MOBILE and 24 or 28)
        badgeRow.Position = UDim2.new(0, 10, 1, IS_MOBILE and -78 or -88)
        badgeRow.BackgroundTransparency = 1
        badgeRow.Text = ("Place %d  ·  Size: %s"):format(card.stock or 1, describeSize(fw, fd))
        badgeRow.TextColor3 = Color3.fromRGB(255, 255, 255)
        badgeRow.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        badgeRow.TextStrokeTransparency = tStroke()
        badgeRow.TextTransparency = tTxt()
        badgeRow.Font = Enum.Font.FredokaOne
        badgeRow.TextSize = IS_MOBILE and 15 or 19
        badgeRow.Parent = btn

        -- Big friendly CTA. Duds transform to "CLAIM TOKEN" in the animation
        -- below; for real tower cards, this is a bright green button.
        local cta = Instance.new("TextLabel")
        cta.Size = UDim2.new(1, -20, 0, IS_MOBILE and 38 or 44)
        cta.Position = UDim2.new(0, 10, 1, IS_MOBILE and -46 or -54)
        cta.BackgroundColor3 = dud and Color3.fromRGB(100, 70, 30) or Color3.fromRGB(60, 170, 80)
        cta.BackgroundTransparency = 0
        cta.Text = dud and "ALREADY OWNED" or "CLAIM!"
        cta.TextColor3 = dud and Color3.fromRGB(255, 220, 120) or Color3.fromRGB(255, 255, 255)
        cta.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        cta.TextStrokeTransparency = 0.3
        cta.Font = Enum.Font.FredokaOne
        cta.TextSize = IS_MOBILE and 18 or 24
        cta.Parent = btn
        local ctaCorner = Instance.new("UICorner")
        ctaCorner.CornerRadius = UDim.new(0.3, 0)
        ctaCorner.Parent = cta

        -- Duds animate into reroll-token cards. Sequence:
        --   0.00s: card shows grayed tower data + "ALREADY OWNED" banner so
        --          the player reads why this slot is dud
        --   0.35s: tower labels + footprint fade out
        --   0.65s: card background shifts to amber, token content fades in
        --   0.90s: card fully transformed; clickable picks the reroll token
        -- Click handler is shared — the server decides tower-vs-token based on
        -- its own pending-picker state for this cardIndex, so the client never
        -- has to tell the server which kind of pick it was.
        if dud then
            task.delay(0.35, function()
                if not btn.Parent then return end
                local fadeInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
                for _, child in ipairs(btn:GetChildren()) do
                    if child:IsA("TextLabel") and child ~= cta then
                        TweenService:Create(child, fadeInfo,
                            { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
                    elseif child:IsA("Frame") then
                        -- Footprint holder + its filled rectangle child
                        TweenService:Create(child, fadeInfo, { BackgroundTransparency = 1 }):Play()
                        for _, sub in ipairs(child:GetChildren()) do
                            if sub:IsA("Frame") then
                                TweenService:Create(sub, fadeInfo, { BackgroundTransparency = 1 }):Play()
                            end
                        end
                    end
                end
                task.wait(0.3)
                if not btn.Parent then return end
                -- Swap card to reroll-token visual. Delete all old children
                -- except UICorner (the rounded-corner modifier) and the CTA
                -- (reused with an updated label).
                for _, child in ipairs(btn:GetChildren()) do
                    if not child:IsA("UICorner") and child ~= cta then
                        child:Destroy()
                    end
                end
                -- Amber background = reroll-token palette (matches the purple
                -- reroll button's "token" framing — warm/gold = bonus currency)
                TweenService:Create(btn, fadeInfo,
                    { BackgroundColor3 = Color3.fromRGB(120, 90, 50) }):Play()

                -- Token icon: glowing disc centered on the card
                local tokenHolder = Instance.new("Frame")
                tokenHolder.AnchorPoint = Vector2.new(0.5, 0.5)
                tokenHolder.Position = UDim2.new(0.5, 0, 0.45, 0)
                tokenHolder.Size = UDim2.new(0, 90, 0, 90)
                tokenHolder.BackgroundColor3 = Color3.fromRGB(255, 195, 90)
                tokenHolder.BackgroundTransparency = 1
                tokenHolder.BorderSizePixel = 0
                tokenHolder.Parent = btn
                local tokenCorner = Instance.new("UICorner")
                tokenCorner.CornerRadius = UDim.new(0.5, 0)
                tokenCorner.Parent = tokenHolder
                TweenService:Create(tokenHolder, fadeInfo, { BackgroundTransparency = 0.1 }):Play()

                -- Token glyph — using "↻" (refresh/reroll) over a plain text
                -- label so it reads without needing an image asset.
                local tokenGlyph = Instance.new("TextLabel")
                tokenGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
                tokenGlyph.Position = UDim2.new(0.5, 0, 0.5, 0)
                tokenGlyph.Size = UDim2.new(1, 0, 1, 0)
                tokenGlyph.BackgroundTransparency = 1
                tokenGlyph.Text = "↻"
                tokenGlyph.TextColor3 = Color3.fromRGB(80, 50, 10)
                tokenGlyph.TextStrokeTransparency = 1
                tokenGlyph.Font = Enum.Font.FredokaOne
                tokenGlyph.TextSize = 64
                tokenGlyph.TextTransparency = 1
                tokenGlyph.Parent = tokenHolder
                TweenService:Create(tokenGlyph, fadeInfo, { TextTransparency = 0 }):Play()

                local tokenLabel = Instance.new("TextLabel")
                tokenLabel.Size = UDim2.new(1, -16, 0, 30)
                tokenLabel.Position = UDim2.new(0, 8, 0, 10)
                tokenLabel.BackgroundTransparency = 1
                tokenLabel.Text = "REROLL TOKEN"
                tokenLabel.TextColor3 = Color3.fromRGB(255, 240, 200)
                tokenLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
                tokenLabel.TextStrokeTransparency = 1
                tokenLabel.TextTransparency = 1
                tokenLabel.Font = Enum.Font.FredokaOne
                tokenLabel.TextSize = IS_MOBILE and 20 or 26
                tokenLabel.Parent = btn
                TweenService:Create(tokenLabel, fadeInfo,
                    { TextTransparency = 0, TextStrokeTransparency = 0.3 }):Play()

                -- "(was: <tower name>)" subline so the player sees which dupe
                -- was substituted for the token
                local subLabel = Instance.new("TextLabel")
                subLabel.Size = UDim2.new(1, -16, 0, 22)
                subLabel.Position = UDim2.new(0, 8, 0, 40)
                subLabel.BackgroundTransparency = 1
                subLabel.Text = ("(owned: %s)"):format(card.displayName or "?")
                subLabel.TextColor3 = Color3.fromRGB(220, 200, 160)
                subLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
                subLabel.TextStrokeTransparency = 1
                subLabel.TextTransparency = 1
                subLabel.Font = Enum.Font.FredokaOne
                subLabel.TextSize = IS_MOBILE and 14 or 17
                subLabel.Parent = btn
                TweenService:Create(subLabel, fadeInfo,
                    { TextTransparency = 0.15, TextStrokeTransparency = 0.5 }):Play()

                -- Update the CTA text + color to match the new green CLAIM style
                -- but in an amber flavor so it reads "bonus token, not a tower."
                cta.Text = "CLAIM +1 TOKEN"
                cta.TextColor3 = Color3.fromRGB(255, 235, 180)
                cta.BackgroundColor3 = Color3.fromRGB(200, 140, 50)
            end)
        end

        btn.MouseButton1Click:Connect(function()
            if os.clock() < clickableAt then return end
            ReplicatedStorage:WaitForChild(Remotes.Names.TempTowerPicked):FireServer({ cardIndex = cardIndex })
            -- Same Enabled=false + deferred Destroy + MouseBehavior reset
            -- as the upgrade picker so the subsequent right-click isn't
            -- absorbed by a still-interactive GUI mid-teardown.
            gui.Enabled = false
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            task.defer(function() if gui.Parent then gui:Destroy() end end)
        end)
    end
end)
end

return TempTowerRewardPicker
