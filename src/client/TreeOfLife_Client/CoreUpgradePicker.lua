--[[
    CoreUpgradePicker.lua — 3-card modal shown after each map boss
    defeat (alongside the temp-tower picker; this fires AFTER the
    temp picker closes per BossRewardClaimed flow).

    Per Matthew 2026-04-29 design dump (memory:
    project_core_upgrade_picker.md). Phase B (THIS FILE) ships the
    visible UI shell — server-side mechanics for each of the 9
    upgrade options land in Phase C.

    Server fires `ShowCoreUpgradePicker` with payload:
        { coreId = "Power" | "ControlCore" | "SupportCore",
          options = { 3 entries with id/title/description/flavor },
          mapId  = 1 | 2 | 3 }

    Client picks → fires `CoreUpgradePicked` { upgradeId = "..." }

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.IS_MOBILE
]]

local CoreUpgradePicker = {}

-- Per-Core background tint (mild) + accent color (prominent).
-- Mirrors the role-color scheme used everywhere else: Power red,
-- ControlCore purple, SupportCore blue.
local CORE_ACCENT = {
    Power       = Color3.fromRGB(220,  90,  90),
    ControlCore = Color3.fromRGB(180, 100, 230),
    SupportCore = Color3.fromRGB( 80, 180, 240),
}
local CORE_BG = {
    Power       = Color3.fromRGB( 50,  18,  18),
    ControlCore = Color3.fromRGB( 38,  18,  52),
    SupportCore = Color3.fromRGB( 16,  32,  56),
}
local CORE_TITLE = {
    Power       = "Power Surge — Pick One",
    ControlCore = "Control Surge — Pick One",
    SupportCore = "Support Surge — Pick One",
}

function CoreUpgradePicker.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE

    local showRemote   = ReplicatedStorage:WaitForChild(Remotes.Names.ShowCoreUpgradePicker)
    local pickedRemote = ReplicatedStorage:WaitForChild(Remotes.Names.CoreUpgradePicked)

    showRemote.OnClientEvent:Connect(function(payload)
        local coreId  = payload and payload.coreId
        local options = payload and payload.options
        if type(options) ~= "table" or #options == 0 then
            warn("[CoreUpgradePicker] payload missing options")
            return
        end

        local accent = CORE_ACCENT[coreId] or Color3.fromRGB(180, 180, 180)
        local bgTint = CORE_BG[coreId]     or Color3.fromRGB(20, 22, 28)

        local existing = playerGui:FindFirstChild("ToL_CoreUpgradePicker")
        if existing then existing:Destroy() end

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_CoreUpgradePicker"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 225  -- above temp-tower picker (220) so we render on top if both somehow open
        gui.Parent = playerGui

        local bg = Instance.new("Frame")
        bg.Size = UDim2.fromScale(1, 1)
        bg.BackgroundColor3 = bgTint
        bg.BackgroundTransparency = 0.25
        bg.BorderSizePixel = 0
        bg.Parent = gui

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0, IS_MOBILE and 40 or 60)
        title.Position = UDim2.fromOffset(0, IS_MOBILE and 70 or 80)
        title.BackgroundTransparency = 1
        title.Text = CORE_TITLE[coreId] or "Core Surge — Pick One"
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        title.TextStrokeTransparency = 0.4
        title.Font = Enum.Font.FredokaOne
        title.TextSize = IS_MOBILE and 22 or 34
        title.Parent = bg

        local subtitle = Instance.new("TextLabel")
        subtitle.Size = UDim2.new(1, 0, 0, IS_MOBILE and 22 or 26)
        subtitle.Position = UDim2.fromOffset(0, (IS_MOBILE and 70 or 80) + (IS_MOBILE and 40 or 60))
        subtitle.BackgroundTransparency = 1
        subtitle.Text = "Boss defeated. Pick a Core upgrade — it stacks across map bosses."
        subtitle.TextColor3 = Color3.fromRGB(220, 225, 230)
        subtitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        subtitle.TextStrokeTransparency = 0.6
        subtitle.Font = Enum.Font.Gotham
        subtitle.TextSize = IS_MOBILE and 14 or 16
        subtitle.Parent = bg

        -- Cards: 3 fixed-size slots in a horizontal row.
        local CARD_W = IS_MOBILE and 200 or 280
        local CARD_H = IS_MOBILE and 240 or 300
        local CARD_GAP = IS_MOBILE and 12 or 24

        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, CARD_H)
        row.Position = UDim2.fromOffset(0, IS_MOBILE and 140 or 180)
        row.BackgroundTransparency = 1
        row.Parent = bg
        do
            local rowLayout = Instance.new("UIListLayout")
            rowLayout.FillDirection = Enum.FillDirection.Horizontal
            rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
            rowLayout.Padding = UDim.new(0, CARD_GAP)
            rowLayout.Parent = row
        end

        -- Anti-accidental-tap lockout — same pattern as TempTowerRewardPicker.
        -- 0.5s gives modal time to fade in before clicks register.
        local clickableAt = os.clock() + 0.5
        local picked = false  -- prevent double-fire if player clicks two cards near-simultaneously

        local function pickCard(opt)
            if picked then return end
            if os.clock() < clickableAt then return end
            picked = true
            pickedRemote:FireServer({ upgradeId = opt.id })
            -- Local cleanup — server may also close on its end via
            -- some future signal but for now the modal is single-fire.
            gui:Destroy()
        end

        for i, opt in ipairs(options) do
            local card = Instance.new("TextButton")
            card.LayoutOrder = i
            card.Size = UDim2.fromOffset(CARD_W, CARD_H)
            card.BackgroundColor3 = bgTint
            card.AutoButtonColor = false
            card.Text = ""
            card.BorderSizePixel = 0
            card.Parent = row
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 12)
                c.Parent = card
                local s = Instance.new("UIStroke")
                s.Thickness = 3
                s.Color = accent
                s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
                s.Parent = card
            end

            local titleLbl = Instance.new("TextLabel")
            titleLbl.Size = UDim2.new(1, -24, 0, IS_MOBILE and 30 or 40)
            titleLbl.Position = UDim2.fromOffset(12, 16)
            titleLbl.BackgroundTransparency = 1
            titleLbl.Text = opt.title or opt.id or "?"
            titleLbl.TextColor3 = accent
            titleLbl.Font = Enum.Font.FredokaOne
            titleLbl.TextSize = IS_MOBILE and 18 or 22
            titleLbl.TextXAlignment = Enum.TextXAlignment.Center
            titleLbl.TextWrapped = true
            titleLbl.Parent = card

            local divider = Instance.new("Frame")
            divider.Size = UDim2.new(1, -40, 0, 2)
            divider.Position = UDim2.fromOffset(20, IS_MOBILE and 50 or 64)
            divider.BackgroundColor3 = accent
            divider.BackgroundTransparency = 0.5
            divider.BorderSizePixel = 0
            divider.Parent = card

            local descLbl = Instance.new("TextLabel")
            descLbl.Size = UDim2.new(1, -24, 0, IS_MOBILE and 100 or 130)
            descLbl.Position = UDim2.fromOffset(12, IS_MOBILE and 60 or 76)
            descLbl.BackgroundTransparency = 1
            descLbl.Text = opt.description or ""
            descLbl.TextColor3 = Color3.fromRGB(230, 235, 240)
            descLbl.Font = Enum.Font.Gotham
            descLbl.TextSize = IS_MOBILE and 13 or 15
            descLbl.TextXAlignment = Enum.TextXAlignment.Center
            descLbl.TextYAlignment = Enum.TextYAlignment.Top
            descLbl.TextWrapped = true
            descLbl.Parent = card

            if opt.flavor then
                local flavorLbl = Instance.new("TextLabel")
                flavorLbl.AnchorPoint = Vector2.new(0, 1)
                flavorLbl.Size = UDim2.new(1, -24, 0, IS_MOBILE and 36 or 48)
                flavorLbl.Position = UDim2.new(0, 12, 1, -16)
                flavorLbl.BackgroundTransparency = 1
                flavorLbl.RichText = true
                flavorLbl.Text = "<i>" .. opt.flavor .. "</i>"
                flavorLbl.TextColor3 = Color3.fromRGB(255, 235, 170)
                flavorLbl.Font = Enum.Font.GothamMedium
                flavorLbl.TextSize = IS_MOBILE and 11 or 13
                flavorLbl.TextXAlignment = Enum.TextXAlignment.Center
                flavorLbl.TextYAlignment = Enum.TextYAlignment.Bottom
                flavorLbl.TextWrapped = true
                flavorLbl.Parent = card
            end

            -- Hover tint (desktop only — mobile has no MouseEnter).
            if not IS_MOBILE then
                card.MouseEnter:Connect(function()
                    card.BackgroundColor3 = Color3.new(
                        math.min(1, bgTint.R * 1.4 + 0.05),
                        math.min(1, bgTint.G * 1.4 + 0.05),
                        math.min(1, bgTint.B * 1.4 + 0.05))
                end)
                card.MouseLeave:Connect(function()
                    card.BackgroundColor3 = bgTint
                end)
            end

            card.Activated:Connect(function() pickCard(opt) end)
        end
    end)
end

return CoreUpgradePicker
