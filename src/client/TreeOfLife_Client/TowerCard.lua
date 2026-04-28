--[[
    TowerCard.lua — "i" info button + per-tower modal.

    The info button is a small round ℹ️ button parented into the
    target-mode HUD frame (next to the tower name). Tapping it opens
    a modal showing the currently-selected tower's full story:
      - Display name + rarity
      - Icon (reused from the hotbar builder)
      - Two-column body: STATS (left) + SPECIAL EFFECTS (right)
        STATS shows base → modified (green parens) for Damage / Range
          / Fire Rate, plus Max DPS with theoretical multi-target ceiling
          in green parens.
        SPECIAL EFFECTS shows aura, slow, stun, knockback, AOE radius,
          attachment, plus per-template mechanic rows (patch / cloud /
          chain / pierce / lob / blink / link) conditionally.
      - Yellow flavor box at the bottom holds the template's
        description text — matches the SS2 mockup.

    2026-04-28 redesign: collapsed the single-column STATS / SPECIAL
    EFFECTS / MECHANIC scrolling layout into the SS2 two-column
    structure. Description moved out of the top frame into a yellow
    flavor box at the bottom. Aura values now display for support
    Cores and the 3 aux buff towers (PaceFlower / PowerSeed /
    SpyglassRoot). Bloodlink Vine + Blink Berry mechanics show in
    SPECIAL EFFECTS.

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

-- Per-tower mechanical description — the plain text block below
-- the title (NOT the flavor box). Distinct from FLAVOR (poetic
-- one-liners). Per Matthew 2026-04-28 redesign.
local DESCRIPTIONS = {
    Power           = "Standard tower. Fires straight bolts at the front-most enemy in range.",
    ControlCore     = "Slow single-target shots apply a stacking damage-over-time. Best vs solo bosses.",
    SupportCore     = "Doesn't engage directly. Buffs every tower on the map with damage and fire-rate.",
    RootSprout      = "Short-range stunner. Briefly roots enemies in place each time it hits.",
    FrostMelon      = "Small AOE chill. Each shot stacks an extra slow on the hit cluster, up to a cap.",
    ThornVine       = "Each shot pierces through enemies lined up along its arc.",
    HoneyHive       = "Drops sticky patches at the front of the path. Slows AND ticks damage on contact.",
    AcornSniper     = "Long-range single-target. Slow cadence, heavy individual hits.",
    LightningRadish = "Each shot arcs to nearby enemies after the primary, with damage falloff per hop.",
    SporePuffball   = "Direct hit, then leaves a lingering poison cloud that ticks damage inside it.",
    PepperCannon    = "Slow, heavy splash bomb. A decisive AOE anchor for big clusters.",
    MushroomMortar  = "Lobs a slow shell across the map for a massive blast on impact.",
    BlinkBerry      = "Every 8s, teleports nearby enemies back along the path. Also fires light shots.",
    PaceFlower      = "Aura. Nearby towers fire faster. Doesn't fire shots itself.",
    PowerSeed       = "Aura. Nearby towers deal more damage. Doesn't fire shots itself.",
    SpyglassRoot    = "Aura. Nearby towers see further. Doesn't fire shots itself.",
    BloodlinkVine   = "Aura. Damage to any linked enemy mirrors to every other linked enemy.",
}

-- Flavor text per tower — yellow-box content. Mirrors
-- TowerInfoCard.FLAVOR; intentionally duplicated here so each
-- card's text edits are local. Per Matthew 2026-04-28.
local FLAVOR = {
    Power           = "Bottled lightning humming in a clay shell — the tree's first defender.",
    ControlCore     = "Patient. Methodical. Each shot leaves a mark that festers.",
    SupportCore     = "It doesn't fight. It just makes everyone around it fight harder.",
    RootSprout      = "Stops things from going where they're not supposed to.",
    FrostMelon      = "Bites slow when the air bites back.",
    ThornVine       = "One thorn, one line of regrets.",
    HoneyHive       = "Sweet trap. Sticky end.",
    AcornSniper     = "One acorn. One enemy. Every time.",
    LightningRadish = "Storms in a root vegetable. Don't ask.",
    SporePuffball   = "What lingers, kills.",
    PepperCannon    = "Heat in a cone. Mobs scatter — or don't.",
    MushroomMortar  = "Lobs the whole sky at the path.",
    BlinkBerry      = "Reality stretches taut, then snaps backwards.",
    PaceFlower      = "Hums a faster heartbeat for everything in earshot.",
    PowerSeed       = "Whispers to the towers nearby — hit harder.",
    SpyglassRoot    = "Lends its eye to the trees behind it.",
    BloodlinkVine   = "Bind one, hurt all. The vine remembers every wound.",
}

-- buildHighlightRows — same priority cascade as TowerInfoCard so
-- both surfaces show identical signature highlights. Returns an
-- ordered list of {label, value} pairs; empty table = no
-- highlights box.
local function buildHighlightRows(stats)
    local rows = {}
    if stats.auraRadius and stats.auraRadius > 0 then
        local rangeStr = (stats.auraRadius >= 9999)
            and "global"
            or string.format("%d studs", math.floor(stats.auraRadius + 0.5))
        table.insert(rows, { "Aura range", rangeStr })
        if stats.auraFireRateBonusPct and stats.auraFireRateBonusPct > 0 then
            table.insert(rows, { "+Fire rate", string.format("%d%%", stats.auraFireRateBonusPct) })
        end
        if stats.auraDamageBonusPct and stats.auraDamageBonusPct > 0 then
            table.insert(rows, { "+Damage", string.format("%d%%", stats.auraDamageBonusPct) })
        end
        if stats.auraRangeBonusPct and stats.auraRangeBonusPct > 0 then
            table.insert(rows, { "+Range", string.format("%d%%", stats.auraRangeBonusPct) })
        end
        return rows
    end
    if stats.linkRadius and stats.linkRadius > 0 then
        table.insert(rows, { "Link radius", string.format("%d studs", math.floor(stats.linkRadius + 0.5)) })
        local echo = stats.linkEchoFrac or 0.5
        table.insert(rows, { "Echo", string.format("%d%%", math.floor(echo * 100 + 0.5)) })
        return rows
    end
    if stats.blinkInterval and stats.blinkInterval > 0 then
        table.insert(rows, { "Blink interval", string.format("%.1fs", stats.blinkInterval) })
        local d = stats.blinkDistance or 0
        table.insert(rows, { "Setback", string.format("%d studs", math.floor(d + 0.5)) })
        return rows
    end
    if stats.stackDotTickDmg and stats.stackDotTickDmg > 0 then
        table.insert(rows, { "DOT tick", string.format("%d dmg/s", math.floor(stats.stackDotTickDmg + 0.5)) })
        table.insert(rows, { "Max stacks", tostring(stats.maxStacks or 0) })
        return rows
    end
    if stats.splashRadius and stats.splashRadius > 0 then
        table.insert(rows, { "Splash radius", string.format("%d studs", math.floor(stats.splashRadius + 0.5)) })
        return rows
    end
    if stats.blastRadius and stats.blastRadius > 0 then
        table.insert(rows, { "Blast radius", string.format("%d studs", math.floor(stats.blastRadius + 0.5)) })
        if stats.lobSeconds then
            table.insert(rows, { "Lob time", string.format("%.1fs", stats.lobSeconds) })
        end
        return rows
    end
    if stats.chainJumps and stats.chainJumps > 0 then
        table.insert(rows, { "Chain jumps", tostring(stats.chainJumps) })
        if stats.chainFalloff then
            table.insert(rows, { "Falloff", string.format("%d%%", math.floor(stats.chainFalloff * 100 + 0.5)) })
        end
        return rows
    end
    if stats.pierceCount and stats.pierceCount > 0 then
        table.insert(rows, { "Pierce", tostring(stats.pierceCount) })
        return rows
    end
    if stats.patchTickDmg and stats.patchTickDmg > 0 then
        table.insert(rows, { "Patch radius", string.format("%d studs", math.floor((stats.patchRadius or 0) + 0.5)) })
        table.insert(rows, { "Patch slow", string.format("%d%%", math.floor((stats.patchSlowPct or 0) * 100 + 0.5)) })
        return rows
    end
    if stats.cloudTickDmg and stats.cloudTickDmg > 0 then
        table.insert(rows, { "Cloud radius", string.format("%d studs", math.floor((stats.cloudRadius or 0) + 0.5)) })
        table.insert(rows, { "Cloud DOT", string.format("%d/s", math.floor(stats.cloudTickDmg * (stats.cloudTickPerSec or 1) + 0.5)) })
        return rows
    end
    if stats.stunSeconds and stats.stunSeconds > 0 then
        table.insert(rows, { "Stun", string.format("%.1fs", stats.stunSeconds) })
        if stats.stunCooldown then
            table.insert(rows, { "Cooldown", string.format("%.1fs", stats.stunCooldown) })
        end
        return rows
    end
    if stats.slowStackPct or stats.slowPct then
        if stats.slowStackCap then
            table.insert(rows, { "Slow cap", string.format("%d%%", math.floor(stats.slowStackCap * 100 + 0.5)) })
        elseif stats.slowPct then
            table.insert(rows, { "Slow", string.format("%d%%", math.floor(stats.slowPct * 100 + 0.5)) })
        end
        if stats.slowSeconds then
            table.insert(rows, { "Duration", string.format("%.1fs", stats.slowSeconds) })
        end
        return rows
    end
    return rows
end

-- BONUS_GREEN — same green tint used elsewhere for upgrade/modified
-- values so the parens annotations read consistently across the UI.
local BONUS_GREEN = "#82e06c"

-- computeTheoreticalDps — per-copy upper-bound DPS including AOE /
-- chain / pierce / DOT contributions. Used for the green-parens
-- annotation on the Max DPS row. Returns nil for non-firing towers
-- (auras / blink / link) so callers can hide the line entirely.
local function computeTheoreticalDps(stats)
    local dmg = stats.damage or 0
    local fr = stats.fireRate or 0
    local base = dmg * fr
    if base <= 0 then return nil end
    -- Pierce: each shot hits pierceCount+1 mobs.
    if stats.pierceCount and stats.pierceCount > 0 then
        return base * (1 + stats.pierceCount)
    end
    -- Chain: primary + falloff + falloff^2 + ...
    if stats.chainJumps and stats.chainJumps > 0 then
        local falloff = stats.chainFalloff or 0.5
        local mult = 1
        local f = 1
        for _ = 1, stats.chainJumps do
            f = f * falloff
            mult = mult + f
        end
        return base * mult
    end
    -- AOE / splash / blast — assume 3 mobs caught in radius.
    if (stats.splashRadius and stats.splashRadius > 0)
       or (stats.blastRadius and stats.blastRadius > 0)
       or (stats.aoeRadius and stats.aoeRadius > 0) then
        return base * 3
    end
    -- Lingering cloud DOT (Spore).
    if stats.cloudTickDmg and stats.cloudTickDmg > 0 then
        local cloudDps = stats.cloudTickDmg * (stats.cloudTickPerSec or 1)
        return base + cloudDps
    end
    -- Patch DOT (Honey).
    if stats.patchTickDmg and stats.patchTickDmg > 0 then
        local patchDps = stats.patchTickDmg * (stats.patchTickPerSec or 1)
        return base + patchDps
    end
    -- Stacking DOT (ControlCore) — peak DPS at full-stack saturation.
    if stats.stackDotTickDmg and stats.stackDotTickDmg > 0 then
        local dotDps = stats.stackDotTickDmg
                       * (stats.stackDotTickPerSec or 1)
                       * (stats.maxStacks or 1)
        return base + dotDps
    end
    return base
end

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

        -- 2026-04-28 redesign: 480×400 with a top header block
        -- (description on the left + cyan highlights box on the
        -- right beside the icon), then STATS/SPECIAL EFFECTS
        -- columns directly under, flavor box, close button.
        -- Highlights box hides for towers with no signature
        -- mechanic (vanilla Power) so the description gets the
        -- full row width.
        local modal = Instance.new("Frame")
        modal.Size = UDim2.fromOffset(480, 400)
        modal.Position = UDim2.new(0.5, -240, 0.5, -200)
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
            desc = "Starter tower. Energy shots at waves of mobs. Accepts one attachment (Phoenix / Detonator / PowerCore)."
        end

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -88, 0, 28)
        title.Position = UDim2.fromOffset(12, 8)
        title.BackgroundTransparency = 1
        title.RichText = true
        if rarity and TempTowers.RarityColors and TempTowers.RarityColors[rarity] then
            local c = TempTowers.RarityColors[rarity]
            local hex = string.format("#%02x%02x%02x",
                math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5))
            title.Text = string.format("<font color='%s'>%s</font>  <font color='#aaaaaa' size='13'>(%s)</font>",
                hex, displayName, rarity)
        else
            title.Text = displayName
        end
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 20
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = modal

        -- Icon — 64×64 top-right corner.
        local iconHolder = Instance.new("Frame")
        iconHolder.Size = UDim2.fromOffset(64, 64)
        iconHolder.Position = UDim2.new(1, -76, 0, 8)
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

        -- ── HEADER BLOCK ──────────────────────────────────────
        -- Description (plain text) + cyan highlights box. The
        -- box hides when buildHighlightRows returns empty so the
        -- description gets the full width on towers with no
        -- distinctive mechanic.
        local HEADER_TOP = 42
        local HEADER_HEIGHT = 70
        local HIGHLIGHT_W = 160

        -- Build the highlights from a merged stat snapshot:
        -- prefer LIVE tower attributes (so attachments / upgrades
        -- show through if relevant), fall back to template data
        -- when the live tower doesn't expose a field.
        local function liveOrTpl(attr, key)
            local v = tower:GetAttribute(attr)
            if v ~= nil then return v end
            if tpl and tpl[key] ~= nil then return tpl[key] end
            return nil
        end
        local highlightStats = {
            auraRadius           = liveOrTpl("AuraRadius", "auraRadius"),
            auraFireRateBonusPct = liveOrTpl("AuraFireRateBonusPct", "auraFireRateBonusPct"),
            auraDamageBonusPct   = liveOrTpl("AuraDamageBonusPct", "auraDamageBonusPct"),
            auraRangeBonusPct    = liveOrTpl("AuraRangeBonusPct", "auraRangeBonusPct"),
            linkRadius           = liveOrTpl("LinkRadius", "linkRadius"),
            linkEchoFrac         = liveOrTpl("LinkEchoFrac", "linkEchoFrac"),
            blinkInterval        = liveOrTpl("BlinkInterval", "blinkInterval"),
            blinkDistance        = liveOrTpl("BlinkDistance", "blinkDistance"),
            stackDotTickDmg      = tower:GetAttribute("StackDotTickDmg"),
            stackDotTickPerSec   = tower:GetAttribute("StackDotTickPerSec"),
            maxStacks            = tower:GetAttribute("MaxStacks"),
            splashRadius         = liveOrTpl("SplashRadius", "splashRadius"),
            blastRadius          = liveOrTpl("BlastRadius", "blastRadius"),
            lobSeconds           = liveOrTpl("LobSeconds", "lobSeconds"),
            chainJumps           = liveOrTpl("ChainJumps", "chainJumps"),
            chainFalloff         = liveOrTpl("ChainFalloff", "chainFalloff"),
            pierceCount          = liveOrTpl("PierceCount", "pierceCount"),
            patchTickDmg         = liveOrTpl("PatchTickDmg", "patchTickDmg"),
            patchRadius          = liveOrTpl("PatchRadius", "patchRadius"),
            patchSlowPct         = liveOrTpl("PatchSlowPct", "patchSlowPct"),
            cloudTickDmg         = liveOrTpl("CloudTickDmg", "cloudTickDmg"),
            cloudTickPerSec      = liveOrTpl("CloudTickPerSec", "cloudTickPerSec"),
            cloudRadius          = liveOrTpl("CloudRadius", "cloudRadius"),
            stunSeconds          = (tpl and tpl.stunSeconds) or nil,
            stunCooldown         = (tpl and tpl.stunCooldown) or nil,
            slowStackPct         = (tpl and tpl.slowStackPct) or nil,
            slowStackCap         = (tpl and tpl.slowStackCap) or nil,
            slowPct              = (tpl and tpl.slowPct) or nil,
            slowSeconds          = (tpl and tpl.slowSeconds) or nil,
        }
        local highlightRows = buildHighlightRows(highlightStats)
        local hasHighlights = #highlightRows > 0

        local descTextW
        if hasHighlights then
            descTextW = (480 - 12) - HIGHLIGHT_W - 8 - (64 + 12 + 8)
        else
            descTextW = (480 - 12) - (64 + 12 + 8)
        end

        local descLbl = Instance.new("TextLabel")
        descLbl.Size = UDim2.fromOffset(descTextW, HEADER_HEIGHT)
        descLbl.Position = UDim2.fromOffset(12, HEADER_TOP)
        descLbl.BackgroundTransparency = 1
        descLbl.Text = DESCRIPTIONS[typ] or desc or ""
        descLbl.TextColor3 = Color3.fromRGB(220, 230, 245)
        descLbl.Font = Enum.Font.Gotham
        descLbl.TextSize = 13
        descLbl.TextWrapped = true
        descLbl.TextXAlignment = Enum.TextXAlignment.Left
        descLbl.TextYAlignment = Enum.TextYAlignment.Top
        descLbl.Parent = modal

        if hasHighlights then
            local hX = 12 + descTextW + 8
            local hi = Instance.new("Frame")
            hi.Size = UDim2.fromOffset(HIGHLIGHT_W, HEADER_HEIGHT)
            hi.Position = UDim2.fromOffset(hX, HEADER_TOP)
            hi.BackgroundColor3 = Color3.fromRGB(40, 130, 180)
            hi.BorderSizePixel = 0
            hi.Parent = modal
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0.08, 0); c.Parent = hi
            end
            do
                local p = Instance.new("UIPadding")
                p.PaddingLeft = UDim.new(0, 8); p.PaddingRight = UDim.new(0, 8)
                p.PaddingTop = UDim.new(0, 4); p.PaddingBottom = UDim.new(0, 4)
                p.Parent = hi
            end
            local hl = Instance.new("UIListLayout")
            hl.FillDirection = Enum.FillDirection.Vertical
            hl.SortOrder = Enum.SortOrder.LayoutOrder
            hl.Padding = UDim.new(0, 1)
            hl.Parent = hi
            for i, row in ipairs(highlightRows) do
                local l = Instance.new("TextLabel")
                l.Size = UDim2.new(1, 0, 0, 16)
                l.BackgroundTransparency = 1
                l.RichText = true
                l.Text = string.format("<b>%s:</b> %s", row[1], row[2])
                l.TextColor3 = Color3.fromRGB(255, 255, 255)
                l.Font = Enum.Font.Gotham
                l.TextSize = 12
                l.TextXAlignment = Enum.TextXAlignment.Left
                l.LayoutOrder = i
                l.Parent = hi
            end
        end

        -- ── BODY: STATS / SPECIAL EFFECTS columns ─────────────
        -- Sit directly under the header block (no wasted gap).
        local BODY_TOP = HEADER_TOP + HEADER_HEIGHT + 8
        local BODY_HEIGHT = 170
        local COL_W = (480 - 24 - 8) / 2

        local function makeColumn(xOffset, headerText)
            local col = Instance.new("Frame")
            col.Size = UDim2.fromOffset(COL_W, BODY_HEIGHT)
            col.Position = UDim2.fromOffset(xOffset, BODY_TOP)
            col.BackgroundTransparency = 1
            col.Parent = modal

            local header = Instance.new("TextLabel")
            header.Size = UDim2.new(1, 0, 0, 16)
            header.BackgroundTransparency = 1
            header.Text = headerText
            header.TextColor3 = Color3.fromRGB(180, 200, 230)
            header.Font = Enum.Font.GothamBold
            header.TextSize = 11
            header.TextXAlignment = Enum.TextXAlignment.Left
            header.Parent = col

            local scroll = Instance.new("ScrollingFrame")
            scroll.Size = UDim2.new(1, 0, 1, -18)
            scroll.Position = UDim2.fromOffset(0, 18)
            scroll.BackgroundTransparency = 1
            scroll.BorderSizePixel = 0
            scroll.ScrollBarThickness = 3
            scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
            scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
            scroll.Parent = col

            local layout = Instance.new("UIListLayout")
            layout.FillDirection = Enum.FillDirection.Vertical
            layout.Padding = UDim.new(0, 0)
            layout.SortOrder = Enum.SortOrder.LayoutOrder
            layout.Parent = scroll

            return scroll
        end

        local statsCol   = makeColumn(12, "STATS")
        local effectsCol = makeColumn(12 + COL_W + 8, "SPECIAL EFFECTS")

        local function addLineTo(parent, label, value, ord)
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, 0, 0, 16)
            l.BackgroundTransparency = 1
            l.RichText = true
            if label then
                l.Text = string.format("<b>%s:</b> %s", label, tostring(value))
            else
                l.Text = tostring(value)
            end
            l.TextColor3 = Color3.fromRGB(230, 235, 245)
            l.Font = Enum.Font.Gotham
            l.TextSize = 12
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.LayoutOrder = ord
            l.Parent = parent
        end

        local statsOrder = 0
        local function addStat(label, value)
            statsOrder = statsOrder + 1
            addLineTo(statsCol, label, value, statsOrder)
        end

        local effectsOrder = 0
        local function addEffect(label, value)
            effectsOrder = effectsOrder + 1
            addLineTo(effectsCol, label, value, effectsOrder)
        end

        -- STATS column: Damage / Range / Fire Rate / Max DPS with
        -- base→modified parens, then theoretical max in green parens
        -- on the Max DPS row.
        local function baseModLine(label, base, total, suffix, fmt)
            fmt = fmt or "%d"
            suffix = suffix or ""
            if math.abs(total - base) < 0.01 then
                addStat(label, string.format(fmt .. suffix, base))
            else
                addStat(label, string.format(
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

        -- Max DPS — show base damage*fireRate + theoretical max in
        -- green parens. The theoretical bumps for AOE / chain / pierce
        -- / DOT contributions; for towers with no fire (auras / blink
        -- / link) the line is dropped entirely.
        local maxDps = dmg * fr
        if maxDps > 0 then
            -- Theoretical from live tower stats (current Damage/FireRate +
            -- template-derived multipliers like splash / chain / pierce).
            local theoretical
            do
                local statsForCalc = {
                    damage = dmg,
                    fireRate = fr,
                    pierceCount = tower:GetAttribute("PierceCount"),
                    chainJumps = tower:GetAttribute("ChainJumps"),
                    chainFalloff = tower:GetAttribute("ChainFalloff"),
                    splashRadius = tower:GetAttribute("SplashRadius"),
                    blastRadius = tower:GetAttribute("BlastRadius"),
                    aoeRadius = tower:GetAttribute("AoeRadius"),
                    cloudTickDmg = tower:GetAttribute("CloudTickDmg"),
                    cloudTickPerSec = tower:GetAttribute("CloudTickPerSec"),
                    patchTickDmg = tower:GetAttribute("PatchTickDmg"),
                    patchTickPerSec = tower:GetAttribute("PatchTickPerSec"),
                    stackDotTickDmg = tower:GetAttribute("StackDotTickDmg"),
                    stackDotTickPerSec = tower:GetAttribute("StackDotTickPerSec"),
                    maxStacks = tower:GetAttribute("MaxStacks"),
                }
                theoretical = computeTheoreticalDps(statsForCalc)
            end
            if theoretical and math.abs(theoretical - maxDps) > 0.05 then
                addStat("Max DPS", string.format(
                    "%.1f  <font color='%s'>(%.1f)</font>",
                    maxDps, BONUS_GREEN, theoretical))
            else
                addStat("Max DPS", string.format("%.1f", maxDps))
            end
        end

        -- SPECIAL EFFECTS column — upgrade- and attachment-derived
        -- effects only. Aura / link / blink / signature mechanics
        -- moved to the cyan highlights box at the top per Matthew
        -- 2026-04-28 redesign, so this column only shows AOE
        -- radius (Core upgrades), Stun / Knockback, Attachment,
        -- and the broader template MECHANIC list below.

        -- Skip AOE radius for aux towers: their template already
        -- surfaces the same value via splashRadius / patchRadius /
        -- cloudRadius / blastRadius below.
        if not tpl then
            local aoe = tower:GetAttribute("AoeRadius")
            if aoe and aoe > 0 then
                addEffect("AOE radius", string.format("%d studs", math.floor(aoe + 0.5)))
            end
        end
        local stunDur = tower:GetAttribute("StunDuration")
        if stunDur and stunDur > 0 then
            local stunPct = math.floor((tower:GetAttribute("StunChance") or 0.05) * 100 + 0.5)
            addEffect("Stun", string.format("%.1fs on %d%% of hits", stunDur, stunPct))
        end
        local knock = tower:GetAttribute("Knockback")
        if knock and knock > 0 then
            local kbPct = math.floor((tower:GetAttribute("KnockbackChance") or 0.05) * 100 + 0.5)
            addEffect("Knockback", string.format("%d studs on %d%%", math.floor(knock + 0.5), kbPct))
        end
        -- Attachment row: Core-only.
        if not tpl then
            local equipType = tower:GetAttribute("EquippedType") or ""
            local equipRar = tower:GetAttribute("EquippedRarity")
            if equipType ~= "" and equipRar then
                addEffect("Attachment", string.format("%s (%s)", equipType, RARITY_NAMES[equipRar] or "?"))
            end
        end

        if tpl then
            -- Aux-specific secondary stats, rarity-scaled.
            local scaled = (rarity and TempTowers.resolveStats(typ, rarity)) or tpl
            local fields = {
                {"slowPct", "Slow", "pct"},
                {"slowStackPct", "Slow / shot", "pct"},
                {"slowStackCap", "Slow cap", "pct"},
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
            for _, f in ipairs(fields) do
                local v = scaled[f[1]]
                if v ~= nil then
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
                    addEffect(f[2], valStr)
                end
            end
        end

        -- If neither column got any "SPECIAL EFFECTS" rows (rare —
        -- vanilla Power with no upgrades / attachment), drop a placeholder
        -- so the column doesn't read empty.
        if effectsOrder == 0 then
            addEffect(nil, "<i>None.</i>")
        end

        -- Yellow flavor box at the bottom — uses the curated FLAVOR
        -- entry for the tower if available, otherwise falls back to
        -- the template's mechanical description.
        local flavorText = FLAVOR[typ] or desc
        local flavor = Instance.new("Frame")
        flavor.Size = UDim2.new(1, -24, 0, 56)
        flavor.Position = UDim2.new(0, 12, 1, -98)
        flavor.BackgroundColor3 = Color3.fromRGB(80, 70, 30)
        flavor.BorderSizePixel = 0
        flavor.Parent = modal
        local fc = Instance.new("UICorner")
        fc.CornerRadius = UDim.new(0.08, 0); fc.Parent = flavor
        local fs = Instance.new("UIStroke")
        fs.Color = Color3.fromRGB(220, 180, 70)
        fs.Thickness = 1
        fs.Parent = flavor
        local fp = Instance.new("UIPadding")
        fp.PaddingLeft = UDim.new(0, 8)
        fp.PaddingRight = UDim.new(0, 8)
        fp.PaddingTop = UDim.new(0, 4)
        fp.PaddingBottom = UDim.new(0, 4)
        fp.Parent = flavor
        local flavorLbl = Instance.new("TextLabel")
        flavorLbl.Size = UDim2.fromScale(1, 1)
        flavorLbl.BackgroundTransparency = 1
        flavorLbl.Text = flavorText
        flavorLbl.TextColor3 = Color3.fromRGB(255, 235, 170)
        flavorLbl.Font = Enum.Font.GothamMedium
        flavorLbl.TextSize = 12
        flavorLbl.TextWrapped = true
        flavorLbl.TextXAlignment = Enum.TextXAlignment.Left
        flavorLbl.TextYAlignment = Enum.TextYAlignment.Top
        flavorLbl.Parent = flavor

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -24, 0, 32)
        btn.Position = UDim2.new(0, 12, 1, -38)
        btn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = "CLOSE"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 16
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
