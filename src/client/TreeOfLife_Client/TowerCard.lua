--[[
    TowerCard.lua — "i" info button + per-tower modal.

    The info button is a small round ℹ️ button parented into the
    target-mode HUD frame (next to the tower name). Tapping it opens
    a modal showing the currently-selected tower's full story:
      - Display name + rarity
      - Icon (reused from the hotbar builder)
      - Description text
      - STATS section with base → modified formatting for Damage /
        Range / Fire Rate, plus Max DPS (modified)
      - SPECIAL EFFECTS section (AOE, Stun chance, Knockback chance,
        Attachment if Core-tower) conditionally shown
      - MECHANIC section for aux towers, driven by the template's
        secondary-stat fields (slowPct, patchTickDmg, cloudRadius, etc.)

    Extracted from init.client.lua to free main-chunk register slots
    (the modal's helper locals + addLine closure were pushing against
    the Luau 200-register limit even when wrapped in a do-block).

    setup(deps) captures:
      deps.playerGui
      deps.TempTowers          — shared module (Templates + RarityColors)
      deps.findTowerDefById    — fn(towerId) → { iconBuilder = fn, ... }
      deps.targetModeFrame     — parent Frame for the info button
      deps.getCurrentTower     — fn() → current selected tower model (or nil)

    Returns: nothing — the button lives inside targetModeFrame after setup.
]]

local TowerCard = {}

local RARITY_NAMES = {"Common", "Rare", "Exceptional", "Legendary", "Mythical"}

function TowerCard.setup(deps)
    local playerGui              = deps.playerGui
    local TempTowers             = deps.TempTowers
    local findTowerDefById       = deps.findTowerDefById
    local targetModeFrame        = deps.targetModeFrame
    local getCurrentTower        = deps.getCurrentTower
    -- Optional multi-select integration (added 2026-04-25). When the
    -- player ctrl-clicks 2+ towers, the info-button click switches from
    -- the per-tower stat modal to a compact list of (tower → target)
    -- pairs. Both deps return nil-equivalent values when single-select
    -- is active so the legacy single path still runs.
    local getMultiSelected        = deps.getMultiSelected        or function() return {} end
    local getManualTargetForTower = deps.getManualTargetForTower or function(_) return nil end

    local infoBtn = Instance.new("TextButton")
    infoBtn.AnchorPoint = Vector2.new(1, 0)  -- top-right corner anchor
    infoBtn.Size = UDim2.fromOffset(26, 26)
    infoBtn.Position = UDim2.new(1, -14, 0, 10)  -- 14px from right, 10px from top
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
    local infoBtnCorner = Instance.new("UICorner")
    infoBtnCorner.CornerRadius = UDim.new(0.5, 0)
    infoBtnCorner.Parent = infoBtn

    local towerCardGui = nil
    local function closeTowerCard()
        if towerCardGui then towerCardGui:Destroy(); towerCardGui = nil end
    end

    local function openTowerCard(tower)
        closeTowerCard()
        if not tower or not tower.Parent then return end

        towerCardGui = Instance.new("ScreenGui")
        towerCardGui.Name = "ToL_TowerCard"
        towerCardGui.IgnoreGuiInset = true
        towerCardGui.ResetOnSpawn = false
        towerCardGui.DisplayOrder = 260
        towerCardGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.5
        dim.BorderSizePixel = 0
        dim.Parent = towerCardGui

        local modal = Instance.new("Frame")
        modal.Size = UDim2.fromOffset(440, 420)  -- shorter than before (was 520);
                                                -- most towers don't fill that height
        modal.Position = UDim2.new(0.5, -220, 0.5, -210)
        modal.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        modal.BorderSizePixel = 0
        modal.Parent = towerCardGui
        local mc = Instance.new("UICorner")
        mc.CornerRadius = UDim.new(0.04, 0); mc.Parent = modal

        local typ = tower:GetAttribute("TowerType") or "Power"
        local tpl = TempTowers.Templates and TempTowers.Templates[typ]
        local rarity = tower:GetAttribute("Rarity")
        local displayName, desc
        if tpl then
            displayName = tpl.displayName or typ
            desc = tpl.description or ""
        else
            displayName = "Power Tower"
            desc = "Starter tower. Energy shots at waves of mobs. Refill ammo at yellow piles with E. Accepts one attachment (Phoenix / Detonator / PowerCore)."
        end

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -140, 0, 34)  -- leaves room for the icon on the right
        title.Position = UDim2.fromOffset(16, 14)
        title.BackgroundTransparency = 1
        title.RichText = true
        if rarity and TempTowers.RarityColors and TempTowers.RarityColors[rarity] then
            local c = TempTowers.RarityColors[rarity]
            local hex = string.format("#%02x%02x%02x",
                math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5))
            title.Text = string.format("<font color='%s'>%s</font>  <font color='#aaaaaa' size='14'>(%s)</font>",
                hex, displayName, rarity)
        else
            title.Text = displayName
        end
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 22
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = modal

        -- Tower picture: same icon builder used by the hotbar + picker,
        -- rendered at a larger size. Positioned top-right of the modal so
        -- the text (name + description) reads alongside rather than below
        -- a wide banner. Wrapped in a square Frame with subtle background
        -- so icons with transparent edges still read as a tile.
        local iconHolder = Instance.new("Frame")
        iconHolder.Size = UDim2.fromOffset(96, 96)
        iconHolder.Position = UDim2.new(1, -112, 0, 12)
        iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 36)
        iconHolder.BorderSizePixel = 0
        iconHolder.Parent = modal
        local ihc = Instance.new("UICorner")
        ihc.CornerRadius = UDim.new(0.12, 0); ihc.Parent = iconHolder
        do
            local towerDef = findTowerDefById(typ)
            if towerDef and towerDef.iconBuilder then
                towerDef.iconBuilder(iconHolder)
            end
        end

        local descLbl = Instance.new("TextLabel")
        descLbl.Size = UDim2.new(1, -140, 0, 66)  -- tighter width; icon occupies the right
        descLbl.Position = UDim2.fromOffset(16, 52)
        descLbl.BackgroundTransparency = 1
        descLbl.Text = desc
        descLbl.TextColor3 = Color3.fromRGB(200, 210, 225)
        descLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        descLbl.TextStrokeTransparency = 0.6
        descLbl.Font = Enum.Font.Gotham
        descLbl.TextSize = 14
        descLbl.TextWrapped = true
        descLbl.TextXAlignment = Enum.TextXAlignment.Left
        descLbl.TextYAlignment = Enum.TextYAlignment.Top
        descLbl.Parent = modal

        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1, -32, 1, -196)
        scroll.Position = UDim2.fromOffset(16, 124)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 6
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.Parent = modal
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        -- Padding 4 → 2 per Matthew 2026-04-27: "decrease spacing
        -- between damage, range, fire rate, and dps, and then
        -- between all the elements in the MECHANIC section as well."
        layout.Padding = UDim.new(0, 2)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = scroll

        local order = 0
        local function addLine(label, value, color)
            order = order + 1
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, 0, 0, 20)
            l.BackgroundTransparency = 1
            l.RichText = true
            if label then
                l.Text = string.format("<b>%s:</b> %s", label, tostring(value))
            else
                l.Text = tostring(value)
            end
            l.TextColor3 = color or Color3.fromRGB(230, 235, 245)
            l.Font = Enum.Font.Gotham
            l.TextSize = 14
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.LayoutOrder = order
            l.Parent = scroll
        end
        local function addSection(text)
            order = order + 1
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, 0, 0, 22)
            l.BackgroundTransparency = 1
            l.Text = text
            l.TextColor3 = Color3.fromRGB(180, 200, 230)
            l.Font = Enum.Font.GothamBold
            l.TextSize = 13
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.LayoutOrder = order
            l.Parent = scroll
        end

        addSection("STATS")
        -- Stat format: "base (modified)". The modified (post-bonus) value
        -- sits in parens — base number stays visible so the player sees
        -- where the tower started before upgrades. BONUS_GREEN tint on the
        -- parens to make upgrades read at a glance. No parens if unchanged.
        local BONUS_GREEN = "#82e06c"
        local function baseModLine(label, base, total, suffix, fmt)
            fmt = fmt or "%d"
            suffix = suffix or ""
            if math.abs(total - base) < 0.01 then
                addLine(label, string.format(fmt .. suffix, base))
            else
                addLine(label, string.format(
                    "%s%s  <font color='%s'>(%s%s)</font>",
                    string.format(fmt, base), suffix,
                    BONUS_GREEN,
                    string.format(fmt, total), suffix))
            end
        end

        local dmg = tower:GetAttribute("Damage") or 0
        local dmgBase = tower:GetAttribute("DamageBase") or dmg
        baseModLine("Damage", dmgBase, dmg)
        local rng = tower:GetAttribute("Range") or 0
        local rngBase = tower:GetAttribute("RangeBase") or rng
        baseModLine("Range", rngBase, rng)
        local fr = tower:GetAttribute("FireRate") or 0
        local frBase = tower:GetAttribute("FireRateBase") or fr
        baseModLine("Fire Rate", frBase, fr, " /sec", "%.2f")

        -- Max DPS — uses the tower's live Damage × FireRate (post-
        -- upgrade), the theoretical ceiling. Per Matthew 2026-04-27:
        -- "drop the modified from max dps" — every other stat already
        -- shows the modified value in green parens, so labeling THIS
        -- one "(modified)" was redundant.
        addLine("Max DPS", string.format("%.1f", dmg * fr))

        local hasSpecial = false
        local function ensureSpecialSection()
            if not hasSpecial then addSection("SPECIAL EFFECTS"); hasSpecial = true end
        end
        -- Skip AOE radius for aux towers: their template already surfaces
        -- the same value in the MECHANIC section (splashRadius / patchRadius
        -- / cloudRadius / blastRadius), so showing SPECIAL EFFECTS AOE too
        -- gives two numbers for the same concept. Core towers still show
        -- it since their AOE only exists via upgrade cards (no MECHANIC row).
        if not tpl then
            local aoe = tower:GetAttribute("AoeRadius")
            if aoe and aoe > 0 then
                ensureSpecialSection()
                addLine("AOE radius", string.format("%d studs", math.floor(aoe + 0.5)))
            end
        end
        local stunDur = tower:GetAttribute("StunDuration")
        if stunDur and stunDur > 0 then
            ensureSpecialSection()
            local stunPct = math.floor((tower:GetAttribute("StunChance") or 0.05) * 100 + 0.5)
            addLine("Stun", string.format("%.1fs on %d%% of hits", stunDur, stunPct))
        end
        local knock = tower:GetAttribute("Knockback")
        if knock and knock > 0 then
            ensureSpecialSection()
            local kbPct = math.floor((tower:GetAttribute("KnockbackChance") or 0.05) * 100 + 0.5)
            addLine("Knockback", string.format("%d studs on %d%% of hits", math.floor(knock + 0.5), kbPct))
        end
        -- Attachment row: Core-only (aux towers can't equip attachments —
        -- they have their own mechanic baked in via the template). Skip
        -- the whole row for aux so the SPECIAL EFFECTS section doesn't
        -- open just to show one misleading Attachment line.
        if not tpl then
            local equipType = tower:GetAttribute("EquippedType") or ""
            local equipRar = tower:GetAttribute("EquippedRarity")
            if equipType ~= "" and equipRar then
                ensureSpecialSection()
                addLine("Attachment", string.format("%s (%s)", equipType, RARITY_NAMES[equipRar] or "?"))
            end
        end

        if tpl then
            -- Aux-specific secondary stats, rarity-scaled. resolveStats
            -- applies RarityMults.secondary to continuous fields and the
            -- discrete step to pierceCount / chainJumps — so a Legendary
            -- Pepper Cannon's MECHANIC row shows the actual in-game radius
            -- (≈11-12), not the frozen base (10). Falls back to the raw
            -- template if rarity is missing or unknown.
            local scaled = (rarity and TempTowers.resolveStats(typ, rarity)) or tpl
            local fields = {
                {"slowPct", "Slow", "pct"},
                {"slowSeconds", "Slow duration", "sec"},
                {"stunSeconds", "Stun duration", "sec"},
                {"stunCooldown", "Stun cooldown", "sec"},
                {"aoeRadius", "AOE radius", "studs"},
                {"splashRadius", "Splash radius", "studs"},
                {"blastRadius", "Blast radius", "studs"},
                {"patchRadius", "Patch radius", "studs"},
                {"patchSeconds", "Patch duration", "sec"},
                {"patchSlowPct", "Patch slow", "pct"},
                {"patchTickDmg", "Patch tick dmg", "dmg"},
                {"patchTickPerSec", "Patch ticks/sec", "count"},
                {"cloudRadius", "Cloud radius", "studs"},
                {"cloudSeconds", "Cloud duration", "sec"},
                {"cloudTickDmg", "Cloud tick dmg", "dmg"},
                {"cloudTickPerSec", "Cloud ticks/sec", "count"},
                {"chainJumps", "Chain jumps", "count"},
                {"chainRange", "Chain range", "studs"},
                {"chainFalloff", "Chain falloff", "pct"},
                {"pierceCount", "Pierce", "count"},
                {"lobSeconds", "Lob time", "sec"},
            }
            local auxSection = false
            for _, f in ipairs(fields) do
                local v = scaled[f[1]]
                if v ~= nil then
                    if not auxSection then addSection("MECHANIC"); auxSection = true end
                    local valStr
                    if f[3] == "pct" then
                        valStr = string.format("%d%%", math.floor(v * 100 + 0.5))
                    elseif f[3] == "sec" then
                        valStr = string.format("%.1fs", v)
                    elseif f[3] == "count" then
                        valStr = tostring(math.floor(v + 0.5))
                    else
                        valStr = string.format("%d %s", math.floor(v + 0.5), f[3])
                    end
                    addLine(f[2], valStr)
                end
            end
        end

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -32, 0, 44)
        btn.Position = UDim2.new(0, 16, 1, -60)
        btn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = "CLOSE"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 18
        btn.Parent = modal
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0.2, 0); bc.Parent = btn
        btn.MouseButton1Click:Connect(closeTowerCard)
    end

    -- Multi-select info popup. Compact (no rarity / no icon / no
    -- mechanic), just a list of (tower display name → current target).
    -- Reuses the dim + close-on-tap approach the single card uses.
    local function openMultiTowerCard(selected)
        closeTowerCard()

        towerCardGui = Instance.new("ScreenGui")
        towerCardGui.Name = "ToL_TowerCard"
        towerCardGui.IgnoreGuiInset = true
        towerCardGui.ResetOnSpawn = false
        towerCardGui.DisplayOrder = 260
        towerCardGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.5
        dim.BorderSizePixel = 0
        dim.Parent = towerCardGui

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
        modal.Parent = towerCardGui
        local mc = Instance.new("UICorner")
        mc.CornerRadius = UDim.new(0, 12); mc.Parent = modal

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

        -- One row per selected tower: "TOWER NAME → TARGET". Target is
        -- the manual-target mob's name when set, otherwise the tower's
        -- TargetMode (FRONT / STRONG / CLOSE / etc.).
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
                local towerName = t:GetAttribute("DisplayName")
                                  or t.Name
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
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0.2, 0); bc.Parent = btn
        btn.MouseButton1Click:Connect(closeTowerCard)
    end

    infoBtn.MouseButton1Click:Connect(function()
        local multi = getMultiSelected()
        if multi and #multi >= 2 then
            openMultiTowerCard(multi)
            return
        end
        local cur = getCurrentTower()
        if cur and cur.Parent then
            openTowerCard(cur)
        end
    end)
    -- Return the infoBtn so the caller can hide it during multi-select
    -- mode (per Matthew's 2026-04-25 playtest: the (i) is redundant
    -- with the inline tower list in the multi-mode panel).
    return infoBtn
end

return TowerCard
