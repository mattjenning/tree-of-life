--[[
    TowerCard.lua — "i" info button + per-tower modal entry point.

    2026-04-28 dh consolidation per Matthew "i'd like have just one
    tower info card." This module previously had a ~600-line render
    function that duplicated TowerInfoCard.lua's layout. Now it's a
    thin shell that:

      1. Sets up the (i) info button parented into the in-arena
         target-mode HUD frame.
      2. Hooks click → delegates to TowerInfoCard.show() with
         opts.towerModel set (live-tower mode: green-parens base→
         modified stats, Attachment row, rarity-driven title color).
      3. Multi-select branch: when ≥2 towers are ctrl-selected, the
         (i) click opens a compact list-of-(tower → target) popup
         that's unique to this surface (no Balance Studio analog).

    The result is ONE rendering path for every tower-info card across
    the project — TowerInfoCard.show — with the in-arena (this file)
    and Balance Studio (admin panel + tier list) both calling into it.

    Multi-select popup stays here because it's a fundamentally
    different shape (compact list, no per-tower data dive).

    setup(deps) captures:
      deps.playerGui
      deps.TempTowers          — kept for the multi-select rarity color cache
      deps.findTowerDefById    — fn(towerId) → { iconBuilder = fn, ... };
                                 passed through to TowerInfoCard for icon render
      deps.targetModeFrame     — parent Frame for the info button
      deps.getCurrentTower     — fn() → current selected tower model (or nil)
      deps.getMultiSelected    — optional, fn() → list of multi-selected towers
      deps.getManualTargetForTower — optional, fn(tower) → mob or nil

    Returns the infoBtn so the caller can hide it during multi-select
    button-bar refreshes.
]]

local TowerInfoCard = require(script.Parent:WaitForChild("TowerInfoCard"))

local TowerCard = {}

function TowerCard.setup(deps)
    local playerGui              = deps.playerGui
    local findTowerDefById       = deps.findTowerDefById
    local targetModeFrame        = deps.targetModeFrame
    local getCurrentTower        = deps.getCurrentTower
    -- Optional multi-select integration. When the player ctrl-clicks
    -- 2+ towers, the info-button click switches to the multi popup.
    local getMultiSelected        = deps.getMultiSelected        or function() return {} end
    local getManualTargetForTower = deps.getManualTargetForTower or function(_) return nil end

    -- (i) info button — parented to the in-arena tower-stats frame.
    local infoBtn = Instance.new("TextButton")
    infoBtn.AnchorPoint = Vector2.new(1, 0)
    infoBtn.Size = UDim2.fromOffset(26, 26)
    infoBtn.Position = UDim2.new(1, -14, 0, 10)
    infoBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 200)
    infoBtn.BorderSizePixel = 0
    infoBtn.AutoButtonColor = false
    infoBtn.Text = "i"
    infoBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    infoBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    infoBtn.TextStrokeTransparency = 0.3
    infoBtn.Font = Enum.Font.FredokaOne
    infoBtn.TextSize = 18
    infoBtn.Parent = targetModeFrame
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.5, 0)
        c.Parent = infoBtn
    end

    -- ── Single-tower info: delegate to TowerInfoCard ───────────
    -- Tower id comes from the live tower's TowerType attribute
    -- (same convention used everywhere else in the codebase).
    -- iconBuilder is passed through so TowerInfoCard knows how to
    -- render Power core's red-gear icon (which lives on the legacy
    -- find-tower-def-by-id table, not in TowerIcons).
    local function openSingle(tower)
        local typ = tower:GetAttribute("TowerType") or "Power"
        local iconBuilder
        local towerDef = findTowerDefById(typ)
        if towerDef and towerDef.iconBuilder then
            iconBuilder = towerDef.iconBuilder
        end
        -- toggle (not show) so a second (i) click closes the card —
        -- preserves the old TowerCard.openTowerCard behavior where
        -- closeTowerCard() ran before each open. Same effect, simpler
        -- code path.
        TowerInfoCard.toggle(playerGui, typ, {
            towerModel  = tower,
            iconBuilder = iconBuilder,
        })
    end

    -- ── Multi-select popup (kept local) ────────────────────────
    -- Shape: dim overlay + centered modal listing one row per
    -- selected tower. Unique to this surface — Balance Studio
    -- never multi-selects so no need to migrate this anywhere.
    local multiGui = nil
    local function closeMulti()
        if multiGui then multiGui:Destroy(); multiGui = nil end
    end
    local function openMulti(selected)
        closeMulti()

        multiGui = Instance.new("ScreenGui")
        multiGui.Name = "ToL_MultiTowerCard"
        multiGui.IgnoreGuiInset = true
        multiGui.ResetOnSpawn = false
        multiGui.DisplayOrder = 260
        multiGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.5
        dim.BorderSizePixel = 0
        dim.Parent = multiGui

        local rowH = 28
        local padTop = 70
        local padBot = 70
        local panelH = padTop + #selected * rowH + padBot
        local modal = Instance.new("Frame")
        modal.AnchorPoint = Vector2.new(0.5, 0.5)
        modal.Size = UDim2.fromOffset(460, panelH)
        modal.Position = UDim2.fromScale(0.5, 0.5)
        modal.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
        modal.BorderSizePixel = 0
        modal.Parent = multiGui
        do
            local mc = Instance.new("UICorner")
            mc.CornerRadius = UDim.new(0, 12); mc.Parent = modal
        end

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -32, 0, 36)
        title.Position = UDim2.fromOffset(16, 14)
        title.BackgroundTransparency = 1
        title.Text = "MULTIPLE TOWERS"
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        title.TextStrokeTransparency = 0.4
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 22
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = modal

        -- One row per selected tower: "TOWER NAME → TARGET". Target
        -- is the manual-target mob's display name when set, else
        -- the tower's TargetMode attribute (FRONT / STRONG / etc.).
        for i, t in ipairs(selected) do
            if t and t.Parent then
                local row = Instance.new("TextLabel")
                row.Size = UDim2.new(1, -32, 0, rowH)
                row.Position = UDim2.fromOffset(16, padTop - 14 + (i - 1) * rowH)
                row.BackgroundTransparency = 1
                row.TextColor3 = Color3.fromRGB(220, 230, 245)
                row.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
                row.TextStrokeTransparency = 0.5
                row.Font = Enum.Font.Gotham
                row.TextSize = 16
                row.TextXAlignment = Enum.TextXAlignment.Left
                local towerName = t:GetAttribute("DisplayName") or t.Name
                local manual = getManualTargetForTower(t)
                local targetStr
                if manual and manual.Parent then
                    targetStr = manual:GetAttribute("DisplayName") or manual.Name
                else
                    targetStr = (t:GetAttribute("TargetMode") or "First"):upper()
                end
                row.Text = string.format("%s  →  %s", towerName, targetStr)
                row.Parent = modal
            end
        end

        local btn = Instance.new("TextButton")
        btn.AnchorPoint = Vector2.new(0.5, 1)
        btn.Position = UDim2.new(0.5, 0, 1, -16)
        btn.Size = UDim2.fromOffset(160, 40)
        btn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = "CLOSE"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        btn.TextStrokeTransparency = 0.3
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 18
        btn.Parent = modal
        do
            local bc = Instance.new("UICorner")
            bc.CornerRadius = UDim.new(0.2, 0); bc.Parent = btn
        end
        btn.MouseButton1Click:Connect(closeMulti)
    end

    infoBtn.MouseButton1Click:Connect(function()
        local multi = getMultiSelected()
        if multi and #multi >= 2 then
            openMulti(multi)
            return
        end
        local cur = getCurrentTower()
        if cur and cur.Parent then
            openSingle(cur)
        end
    end)

    return infoBtn
end

return TowerCard
