--[[
    PlayerHUDs.lua — Two stacked bottom-right pill HUDs that show player
    state at a glance:

      1. RerollTokenHUD: persistent reroll-token count. Updates instantly
         on the per-player RerollTokens attribute.
      2. PhoenixHUD: shows when the player has a Phoenix attachment
         equipped. Three states (priority): grace timer (red, "Phoenix
         Active: X.Xs"), ready (green, "Phoenix: ACTIVE"), cooldown
         (yellow, "Phoenix: M:SS"). Polls 5Hz off the equipped tower's
         attributes.

    They share enough (bottom-right corner, player-attribute-driven,
    AutomaticSize.X for varying labels) that one module is the natural
    unit. Reroll sits 8px above Phoenix.

    setup(deps) captures:
      deps.playerGui
      deps.player
      deps.CollectionService
      deps.Tags
]]

local PlayerHUDs = {}

function PlayerHUDs.setup(deps)
    local playerGui         = deps.playerGui
    local player            = deps.player
    local CollectionService = deps.CollectionService
    local Tags              = deps.Tags

    ------------------------------------------------------------
    -- REROLL TOKEN HUD (bottom-right, above Phoenix HUD): always-visible
    -- pill that shows the player's persistent RerollTokens balance. Polls
    -- the player attribute via GetAttributeChangedSignal so it updates
    -- instantly when tokens are earned (stage clear) or spent (upgrade
    -- picker "USE TOKEN" button).
    ------------------------------------------------------------
    do
        local hudGui = Instance.new("ScreenGui")
        hudGui.Name = "ToL_RerollTokenHUD"
        hudGui.IgnoreGuiInset = true
        hudGui.ResetOnSpawn = false
        hudGui.DisplayOrder = 230
        hudGui.Parent = playerGui

        local frame = Instance.new("Frame")
        frame.AnchorPoint = Vector2.new(1, 1)
        -- 62 = Phoenix HUD is 38 tall + 16 bottom margin + 8 gap above it.
        frame.Position = UDim2.new(1, -16, 1, -62)
        frame.Size = UDim2.new(0, 0, 0, 34)
        frame.AutomaticSize = Enum.AutomaticSize.X
        frame.BackgroundTransparency = 1  -- text-only, no pill background
        frame.BorderSizePixel = 0
        frame.Parent = hudGui

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0, 0, 1, 0)
        label.AutomaticSize = Enum.AutomaticSize.X
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 16
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        label.TextStrokeTransparency = 0.4
        label.TextColor3 = Color3.fromRGB(255, 210, 130)
        label.Parent = frame

        local function refresh()
            local count = player:GetAttribute("RerollTokens") or 0
            label.Text = string.format("REROLL TOKENS: %d", count)
        end
        refresh()
        player:GetAttributeChangedSignal("RerollTokens"):Connect(refresh)
    end

    ------------------------------------------------------------
    -- PHOENIX HUD (bottom-right): visible only while at least one OWNED
    -- tower has EquippedType == "Phoenix". Three states (priority order):
    --   1. GraceRemaining > 0   → red    "Phoenix Active: 3.2s"
    --   2. PhoenixReady == true → green  "Phoenix: ACTIVE"
    --   3. otherwise            → yellow "Phoenix: 11:42"  (M:SS countdown)
    --
    -- Update tick: 5Hz. The grace countdown shows one decimal; cooldown
    -- shows whole minutes:seconds. Server writes attributes at compatible
    -- precision (cooldown = integer seconds, grace = 0.1s tenths) so
    -- polling is cheap.
    ------------------------------------------------------------
    do
        local hudGui = Instance.new("ScreenGui")
        hudGui.Name = "ToL_PhoenixHUD"
        hudGui.IgnoreGuiInset = true
        hudGui.ResetOnSpawn = false
        hudGui.DisplayOrder = 230
        hudGui.Parent = playerGui

        local frame = Instance.new("Frame")
        frame.Name = "Frame"
        frame.AnchorPoint = Vector2.new(1, 1)
        frame.Position = UDim2.new(1, -16, 1, -16)
        frame.Size = UDim2.new(0, 0, 0, 38)
        -- AutomaticSize hugs the text width so the pill is exactly as
        -- wide as the label needs, regardless of state ("READY" vs
        -- "Phoenix Active: 4.5s" vs "Phoenix: 10:00"). Anchor is
        -- bottom-right, so the pill grows to the LEFT as text gets
        -- longer — bottom-right corner stays pinned.
        frame.AutomaticSize = Enum.AutomaticSize.X
        frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
        frame.BackgroundTransparency = 0.25
        frame.BorderSizePixel = 0
        frame.Visible = false
        frame.Parent = hudGui
        local fc = Instance.new("UICorner")
        fc.CornerRadius = UDim.new(0.2, 0)
        fc.Parent = frame
        local fs = Instance.new("UIStroke")
        fs.Thickness = 1
        fs.Color = Color3.fromRGB(120, 120, 120)
        fs.Transparency = 0.4
        fs.Parent = frame
        -- Symmetric padding so the text isn't kissing either edge.
        local fp = Instance.new("UIPadding")
        fp.PaddingLeft = UDim.new(0, 14)
        fp.PaddingRight = UDim.new(0, 14)
        fp.Parent = frame

        local label = Instance.new("TextLabel")
        label.Name = "Label"
        label.Size = UDim2.new(0, 0, 1, 0)
        label.AutomaticSize = Enum.AutomaticSize.X
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 18
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        label.TextStrokeTransparency = 0.4
        label.Text = "Phoenix: ACTIVE"
        label.TextColor3 = Color3.fromRGB(120, 255, 140)
        label.Parent = frame

        local function findOwnedPhoenixTower()
            local uid = player.UserId
            -- Prefer the tower that's CURRENTLY cooling down / in grace —
            -- that's the one the player just activated. Fall back to any
            -- Phoenix tower if none are cooling. Without this preference,
            -- a player with a map-1 Phoenix tower AND a freshly-placed
            -- map-2 Phoenix tower (both present in the CollectionService
            -- registry) would see the HUD lock to whichever came first
            -- in the iteration, which wasn't always the one that
            -- tryConsumePhoenix picked as the "active" one.
            local activeTower, anyTower
            for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local t = towerBase.Parent
                if t and t:GetAttribute("Owner") == uid
                       and t:GetAttribute("EquippedType") == "Phoenix" then
                    local grace = t:GetAttribute("PhoenixGraceRemaining") or 0
                    local ready = t:GetAttribute("PhoenixReady") == true
                    if grace > 0 or not ready then
                        activeTower = t
                        break
                    end
                    anyTower = anyTower or t
                end
            end
            return activeTower or anyTower
        end

        local function fmtCd(seconds)
            seconds = math.max(0, math.ceil(seconds))
            local m = math.floor(seconds / 60)
            local s = seconds % 60
            return string.format("%d:%02d", m, s)
        end

        task.spawn(function()
            while hudGui.Parent do
                -- Show whenever the PLAYER has Phoenix equipped — not
                -- gated on a tower existing yet. This way the HUD appears
                -- the moment they enter the map (when the tower-choice UI
                -- shows), and stays visible even before they've placed
                -- their first tower.
                local equippedType = player:GetAttribute("EquippedAttachmentType") or ""
                if equippedType ~= "Phoenix" then
                    frame.Visible = false
                else
                    -- If a tower with Phoenix is placed, read live
                    -- cooldown/grace from it. Otherwise show "NEEDS TOWER".
                    local t = findOwnedPhoenixTower()
                    if not t then
                        label.Text = "Phoenix: NEEDS TOWER"
                        label.TextColor3 = Color3.fromRGB(255, 200, 110)  -- amber — signals "action required"
                    else
                        local grace = t:GetAttribute("PhoenixGraceRemaining") or 0
                        local ready = t:GetAttribute("PhoenixReady") == true
                        local cdRem = t:GetAttribute("PhoenixCdRemaining") or 0
                        if grace > 0 then
                            label.Text = string.format("Phoenix Active: %.1fs", grace)
                            label.TextColor3 = Color3.fromRGB(255, 110, 110)
                        elseif ready then
                            label.Text = "Phoenix: ACTIVE"
                            label.TextColor3 = Color3.fromRGB(120, 255, 140)
                        else
                            label.Text = "Phoenix: " .. fmtCd(cdRem)
                            label.TextColor3 = Color3.fromRGB(255, 220, 110)
                        end
                    end
                    frame.Visible = true
                end
                task.wait(0.1)
            end
        end)
    end
end

return PlayerHUDs
