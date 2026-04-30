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
    -- REROLL TOKEN HUD (bottom-right): always-visible pill that shows the
    -- player's persistent RerollTokens balance. Polls the player attribute
    -- via GetAttributeChangedSignal so it updates instantly when tokens
    -- are earned (stage clear) or spent (upgrade picker "USE TOKEN").
    --
    -- VERTICAL POSITION: floats based on Phoenix HUD visibility — when
    -- Phoenix is up (player has it equipped), reroll sits above it at
    -- y = -62 (16 margin + 38 Phoenix + 8 gap). When Phoenix is hidden
    -- (no Phoenix equipped), reroll drops to the bottom at y = -16.
    -- The Phoenix HUD's poll loop calls setRerollAbovePhoenix() each
    -- visibility change.
    ------------------------------------------------------------
    local rerollFrame  -- exposed up so the Phoenix poll loop can move it
    do
        local hudGui = Instance.new("ScreenGui")
        hudGui.Name = "ToL_RerollTokenHUD"
        hudGui.IgnoreGuiInset = true
        hudGui.ResetOnSpawn = false
        hudGui.DisplayOrder = 230
        hudGui.Parent = playerGui

        -- Compressed bottom-right HUD per Matthew 2026-04-27: pulled
        -- down to y=-4 (was -16) and shrunk to 24 high (was 34) so
        -- the Infinite monitor's OVERALL PATTERNS panel doesn't
        -- overlap the reroll line.
        local frame = Instance.new("Frame")
        frame.AnchorPoint = Vector2.new(1, 1)
        frame.Position = UDim2.new(1, -16, 1, -4)
        frame.Size = UDim2.fromOffset(0, 24)
        frame.AutomaticSize = Enum.AutomaticSize.X
        frame.BackgroundTransparency = 1  -- text-only, no pill background
        frame.BorderSizePixel = 0
        frame.Parent = hudGui
        rerollFrame = frame

        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(0, 1)
        label.AutomaticSize = Enum.AutomaticSize.X
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 14
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
    -- RUN TIME HUD (bottom-right, stacks ABOVE the reroll pill): black
    -- "run time: H:MM:SS (H:MM:SS)" label — wallclock seconds outside,
    -- game-time (dt × gameSpeed) in parens. At 1× they match; at higher
    -- speeds the parenthesized clock outpaces the wallclock. ea3-118:
    -- format is H:MM:SS for consistency with the failure-curve sweep
    -- ETA + every other time-status bar in the UI. The TICK +
    -- pause/resume logic lives in init.client.lua (forward-declared
    -- upvalues for fireReset); this module just owns the label's
    -- existence + position so the bottom-right HUD stack stays
    -- consistent.
    ------------------------------------------------------------
    local runTimeFrame
    local runTimeLabel
    do
        local hudGui = Instance.new("ScreenGui")
        hudGui.Name = "ToL_RunTimeHUD"
        hudGui.IgnoreGuiInset = true
        hudGui.ResetOnSpawn = false
        hudGui.DisplayOrder = 230
        hudGui.Parent = playerGui

        local frame = Instance.new("Frame")
        frame.AnchorPoint = Vector2.new(1, 1)
        -- Default: above reroll. Reroll bottom y=-4, reroll height 24
        -- → reroll top at y=-28. Run-time sits 2px above with height
        -- 20 → run-time bottom at y=-30.
        frame.Position = UDim2.new(1, -16, 1, -30)
        frame.Size = UDim2.fromOffset(0, 20)
        frame.AutomaticSize = Enum.AutomaticSize.X
        frame.BackgroundTransparency = 1
        frame.BorderSizePixel = 0
        frame.Parent = hudGui
        runTimeFrame = frame

        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(0, 1)
        label.AutomaticSize = Enum.AutomaticSize.X
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.RobotoMono
        label.TextSize = 13
        label.TextXAlignment = Enum.TextXAlignment.Right
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        label.TextStrokeTransparency = 0.5
        label.TextColor3 = Color3.fromRGB(0, 0, 0)
        label.Text = "run time: 0:00:00 (0:00:00)"
        label.Parent = frame
        runTimeLabel = label
    end

    -- Move reroll + run-time pills above/below the Phoenix HUD. Called by
    -- the Phoenix poll loop whenever its frame.Visible flips. Reroll sits
    -- 8px above Phoenix when visible (or at the bottom); run-time sits
    -- 8px above reroll, regardless of Phoenix state.
    local function setBottomStackAbovePhoenix(phoenixVisible)
        if rerollFrame then
            if phoenixVisible then
                -- Phoenix bottom y=-16, height 38 → top at y=-54.
                -- Reroll 8px above with new height 24 → bottom y=-62.
                rerollFrame.Position = UDim2.new(1, -16, 1, -62)
            else
                -- Bottom default with new compact spacing.
                rerollFrame.Position = UDim2.new(1, -16, 1, -4)
            end
        end
        if runTimeFrame then
            if phoenixVisible then
                -- Reroll above-phoenix: bottom y=-62, top y=-86.
                -- Run-time 2px above → bottom y=-88.
                runTimeFrame.Position = UDim2.new(1, -16, 1, -88)
            else
                -- Reroll at bottom: bottom y=-4, top y=-28.
                -- Run-time 2px above → bottom y=-30.
                runTimeFrame.Position = UDim2.new(1, -16, 1, -30)
            end
        end
    end
    -- Back-compat alias (the old Phoenix poll-loop name still resolves).
    local setRerollAbovePhoenix = setBottomStackAbovePhoenix

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
        frame.Size = UDim2.fromOffset(0, 38)
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
        label.Size = UDim2.fromScale(0, 1)
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
            local lastVisible = nil
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
                -- Tell the reroll HUD to float above us when we're visible,
                -- drop to the bottom corner when we're not. Only fires on
                -- changes so we don't thrash positions every 100ms.
                if frame.Visible ~= lastVisible then
                    lastVisible = frame.Visible
                    setRerollAbovePhoenix(frame.Visible)
                end
                task.wait(0.1)
            end
        end)
    end

    -- Expose the run-time label so init.client.lua's tick + reset hooks
    -- can write to it. The HUD's existence + position lives here so the
    -- bottom-right stack stays consistent with reroll + Phoenix.
    return {
        runTimeLabel = runTimeLabel,
    }
end

return PlayerHUDs
