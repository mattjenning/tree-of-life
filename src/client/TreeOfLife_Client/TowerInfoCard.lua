--[[
    TowerInfoCard.lua — shared tower info-card popup for the
    Infinite Balance Studio.

    Visual: matches the story-mode TowerCard (rarity-tinted title +
    icon + 2-column STATS / SPECIAL EFFECTS body + yellow flavor box +
    bottom CLOSE button). Per Matthew SS2 mockup.

    Surfaces that consume this:
      • InfiniteAdminPanel — tower-detail modal's (i) button
      • InfiniteMonitorWindow — wave-breakdown modal's (i) button

    PUBLIC API:
      TowerInfoCard.toggle(parentGui, towerId)
        Open the card if not present, OR destroy the existing one.
        Returns the new card frame (or nil if it was a close-toggle).

      TowerInfoCard.show(parentGui, towerId)
        Force-open (does not toggle). Caller is responsible for
        cleanup.

    The card auto-destroys via its own bottom CLOSE button. Both
    consumers parent it to a top-level gui (NOT their panel/modal)
    so panel-drag doesn't move the card.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local TempTowers = require(Shared:WaitForChild("TempTowers"))
local TowerTypes = require(Shared:WaitForChild("TowerTypes"))
local TowerCardData = require(Shared:WaitForChild("TowerCardData"))
-- TowerIcons is sibling client-side ModuleScript. Loaded lazily so
-- TowerInfoCard can render a real icon for any towerId (Cores +
-- aux + the 5 new 2026-04-28 aux). pcall keeps the card resilient
-- to load-order issues during early boot.
local TowerIcons
do
    local ok, mod = pcall(function()
        return require(script.Parent:WaitForChild("TowerIcons"))
    end)
    if ok then TowerIcons = mod end
end

-- DESCRIPTIONS / FLAVOR / buildHighlightRows are SHARED between
-- this surface and TowerCard.lua. Source of truth lives in
-- src/shared/TowerCardData.lua — edit there, both surfaces pick
-- up the change.
local DESCRIPTIONS = TowerCardData.DESCRIPTIONS
local FLAVOR = TowerCardData.FLAVOR
local buildHighlightRows = TowerCardData.buildHighlightRows

local TowerInfoCard = {}

local BONUS_GREEN = "#82e06c"

-- Field list mirrored from TowerCard.lua's MECHANIC section so both
-- surfaces show the same row labels for the same towers. Entries
-- with a non-zero value get rendered; missing fields are skipped.
local MECHANIC_FIELDS = {
    {"slowPct",         "Slow",              "pct"},
    {"slowStackPct",    "Slow / shot",       "pct"},
    {"slowStackCap",    "Slow cap",          "pct"},
    {"slowSeconds",     "Slow duration",     "sec"},
    {"stunSeconds",     "Stun duration",     "sec"},
    {"stunCooldown",    "Stun cooldown",     "sec"},
    {"aoeRadius",       "AOE radius",        "studs"},
    {"splashRadius",    "Splash radius",     "studs"},
    {"blastRadius",     "Blast radius",      "studs"},
    {"patchRadius",     "Patch radius",      "studs"},
    {"patchSeconds",    "Patch duration",    "sec"},
    {"patchSlowPct",    "Patch slow",        "pct"},
    {"patchTickDmg",    "Patch tick dmg",    "dmg"},
    {"patchTickPerSec", "Patch ticks/sec",   "count"},
    {"cloudRadius",     "Cloud radius",      "studs"},
    {"cloudSeconds",    "Cloud duration",    "sec"},
    {"cloudTickDmg",    "Cloud tick dmg",    "dmg"},
    {"cloudTickPerSec", "Cloud ticks/sec",   "count"},
    {"chainJumps",      "Chain jumps",       "count"},
    {"chainRange",      "Chain range",       "studs"},
    {"chainFalloff",    "Chain falloff",     "pct"},
    {"pierceCount",     "Pierce",            "count"},
    {"lobSeconds",      "Lob time",          "sec"},
}

-- (pushAuraEffects helper removed 2026-04-28 — aura / link /
-- blink rows moved to the cyan highlights box at the top of the
-- card via buildHighlightRows; SPECIAL EFFECTS column now only
-- renders MECHANIC_FIELDS overflow.)

-- computeTheoreticalDps — same heuristic as TowerCard.lua, scoped to
-- the Common-tier resolved stats so the Balance Studio displays the
-- baseline ceiling, not the live-tower ceiling.
local function computeTheoreticalDps(stats)
    local dmg = stats.damage or 0
    local fr = stats.fireRate or 0
    local base = dmg * fr
    if base <= 0 then return nil end
    if stats.pierceCount and stats.pierceCount > 0 then
        return base * (1 + stats.pierceCount)
    end
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
    if (stats.splashRadius and stats.splashRadius > 0)
       or (stats.blastRadius and stats.blastRadius > 0)
       or (stats.aoeRadius and stats.aoeRadius > 0) then
        return base * 3
    end
    if stats.cloudTickDmg and stats.cloudTickDmg > 0 then
        return base + stats.cloudTickDmg * (stats.cloudTickPerSec or 1)
    end
    if stats.patchTickDmg and stats.patchTickDmg > 0 then
        return base + stats.patchTickDmg * (stats.patchTickPerSec or 1)
    end
    if stats.stackDotTickDmg and stats.stackDotTickDmg > 0 then
        return base + stats.stackDotTickDmg
                      * (stats.stackDotTickPerSec or 1)
                      * (stats.maxStacks or 1)
    end
    return base
end

function TowerInfoCard.show(parentGui, towerId)
    -- Resolve stats from BOTH TempTowers (aux) and TowerTypes (Cores).
    -- Cores live in TowerTypes; aux live in TempTowers. The picker
    -- and tier-list both pass towerId equal to the type name for
    -- both.
    local tpl = TempTowers.Templates[towerId]
    local stats
    if tpl then
        -- Common-tier per Matthew 2026-04-27: "tower info cards
        -- should show the common version of the tower". Falls back
        -- to the raw template if the resolver hits an unknown rarity.
        stats = TempTowers.resolveStats(towerId, "Common")
                or table.clone(tpl)
    else
        local coreTpl = TowerTypes[towerId]
        if coreTpl then
            stats = table.clone(coreTpl)
        else
            stats = {}
        end
    end

    -- Walk up to the parent ScreenGui or PlayerGui so the card's own
    -- ScreenGui sits as a sibling. Falling back to parentGui itself
    -- if it's not a ScreenGui.
    local host = parentGui
    if parentGui then
        if parentGui:IsA("ScreenGui") and parentGui.Parent then
            host = parentGui.Parent
        elseif parentGui:FindFirstAncestorOfClass("PlayerGui") then
            host = parentGui:FindFirstAncestorOfClass("PlayerGui")
        end
    end
    local cardGui = Instance.new("ScreenGui")
    cardGui.Name = "TowerInfoCardGui"
    cardGui.ResetOnSpawn = false
    cardGui.IgnoreGuiInset = true
    cardGui.DisplayOrder = 1000
    cardGui.Parent = host

    -- 2026-04-28 redesign per Matthew: 480×400 with a top header
    -- block (description text on the left + cyan-tinted highlights
    -- box on the right beside the icon), then STATS/SPECIAL EFFECTS
    -- columns directly under, flavor box, close button. The cyan
    -- highlights box hides entirely for towers with no signature
    -- mechanic so the description gets the full width when needed.
    local card = Instance.new("Frame")
    card.Name = "TowerInfoCard"
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.fromOffset(480, 400)
    card.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
    card.BorderSizePixel = 0
    card.ZIndex = 20
    card.Parent = cardGui
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.04, 0)
        c.Parent = card
    end

    -- Title: rarity-tinted name + "(Common)" tag.
    local displayName = (tpl and tpl.displayName)
        or (TowerTypes[towerId] and TowerTypes[towerId].displayName)
        or towerId
    local DEFAULT_RARITY = "Common"
    local rc = TempTowers.RarityColors and TempTowers.RarityColors[DEFAULT_RARITY]
    -- Title (top-left, full-width minus icon).
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -88, 0, 28)
    title.Position = UDim2.fromOffset(12, 8)
    title.BackgroundTransparency = 1
    title.RichText = true
    if rc then
        local hex = string.format("#%02x%02x%02x",
            math.floor(rc.R * 255 + 0.5),
            math.floor(rc.G * 255 + 0.5),
            math.floor(rc.B * 255 + 0.5))
        title.Text = string.format(
            "<font color='%s'>%s</font>  <font color='#aaaaaa' size='13'>(%s)</font>",
            hex, displayName, DEFAULT_RARITY)
    else
        title.Text = displayName
    end
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.Font = Enum.Font.FredokaOne
    title.TextSize = 20
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 21
    title.Parent = card

    -- Icon — 64×64 top-right corner.
    local iconHolder = Instance.new("Frame")
    iconHolder.Size = UDim2.fromOffset(64, 64)
    iconHolder.Position = UDim2.new(1, -76, 0, 8)
    iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 36)
    iconHolder.BorderSizePixel = 0
    iconHolder.ZIndex = 21
    iconHolder.Parent = card
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.12, 0)
        c.Parent = iconHolder
    end
    if TowerIcons and TowerIcons[towerId] then
        TowerIcons[towerId](iconHolder)
    end

    -- ── HEADER BLOCK ──────────────────────────────────────────
    -- Description (plain text, no border) on the left, cyan
    -- highlights box on the right. Hide highlights box entirely
    -- when the tower has no signature mechanic — description
    -- gets the full row width in that case.
    local HEADER_TOP = 42
    local HEADER_HEIGHT = 70
    local HIGHLIGHT_W = 160

    local highlightRows = buildHighlightRows(stats)
    local hasHighlights = #highlightRows > 0

    local descTextW
    if hasHighlights then
        -- Description ends 8px before the highlights box; the box
        -- occupies the right portion of the header row up to the
        -- icon's left edge.
        descTextW = (480 - 12) - HIGHLIGHT_W - 8 - (64 + 12 + 8)
    else
        -- No highlights box: description spans up to the icon.
        descTextW = (480 - 12) - (64 + 12 + 8)
    end

    -- Description label — plain text, no background, no border.
    local descLbl = Instance.new("TextLabel")
    descLbl.Size = UDim2.fromOffset(descTextW, HEADER_HEIGHT)
    descLbl.Position = UDim2.fromOffset(12, HEADER_TOP)
    descLbl.BackgroundTransparency = 1
    descLbl.Text = DESCRIPTIONS[towerId]
        or (tpl and tpl.description)
        or ""
    descLbl.TextColor3 = Color3.fromRGB(220, 230, 245)
    descLbl.Font = Enum.Font.Gotham
    descLbl.TextSize = 13
    descLbl.TextWrapped = true
    descLbl.TextXAlignment = Enum.TextXAlignment.Left
    descLbl.TextYAlignment = Enum.TextYAlignment.Top
    descLbl.ZIndex = 21
    descLbl.Parent = card

    -- Cyan highlights box (only if non-empty). Cyan background +
    -- white text per Matthew "make highlights box cyan with white
    -- text".
    if hasHighlights then
        local hX = 12 + descTextW + 8
        local hi = Instance.new("Frame")
        hi.Size = UDim2.fromOffset(HIGHLIGHT_W, HEADER_HEIGHT)
        hi.Position = UDim2.fromOffset(hX, HEADER_TOP)
        hi.BackgroundColor3 = Color3.fromRGB(40, 130, 180)
        hi.BorderSizePixel = 0
        hi.ZIndex = 21
        hi.Parent = card
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0.08, 0)
            c.Parent = hi
        end
        do
            local p = Instance.new("UIPadding")
            p.PaddingLeft = UDim.new(0, 8)
            p.PaddingRight = UDim.new(0, 8)
            p.PaddingTop = UDim.new(0, 4)
            p.PaddingBottom = UDim.new(0, 4)
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
            l.ZIndex = 22
            l.Parent = hi
        end
    end

    -- ── BODY: STATS / SPECIAL EFFECTS columns ─────────────────
    -- Sit directly under the header block (no "TRIM THIS" gap).
    -- Body fills the band between header (y=112) and flavor box
    -- (y=302). 8px header gap + 12px flavor gap = 170 body band.
    local BODY_TOP = HEADER_TOP + HEADER_HEIGHT + 8
    local BODY_HEIGHT = 170
    local COL_W = (480 - 24 - 8) / 2

    local function makeColumn(xOffset, headerText)
        local col = Instance.new("Frame")
        col.Size = UDim2.fromOffset(COL_W, BODY_HEIGHT)
        col.Position = UDim2.fromOffset(xOffset, BODY_TOP)
        col.BackgroundTransparency = 1
        col.ZIndex = 21
        col.Parent = card

        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, 0, 0, 16)
        header.BackgroundTransparency = 1
        header.Text = headerText
        header.TextColor3 = Color3.fromRGB(180, 200, 230)
        header.Font = Enum.Font.GothamBold
        header.TextSize = 11
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.ZIndex = 22
        header.Parent = col

        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1, 0, 1, -18)
        scroll.Position = UDim2.fromOffset(0, 18)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 3
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.ZIndex = 22
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
        l.ZIndex = 22
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

    -- STATS column. Damage shown as %.1f because Common's 0.91× mult
    -- on integer template damage produces fractional values worth
    -- surfacing.
    local baseDmg = stats.damage   or 0
    local baseRng = stats.range    or 0
    local baseFr  = stats.fireRate or 0
    addStat("Damage", string.format("%.1f", baseDmg))
    addStat("Range",  string.format("%d", math.floor(baseRng + 0.5)))
    addStat("Fire Rate", string.format("%.2f /sec", baseFr))

    local maxDps = baseDmg * baseFr
    if maxDps > 0 then
        local theoretical = computeTheoreticalDps(stats)
        if theoretical and math.abs(theoretical - maxDps) > 0.05 then
            addStat("Max DPS", string.format(
                "%.1f  <font color='%s'>(%.1f)</font>",
                maxDps, BONUS_GREEN, theoretical))
        else
            addStat("Max DPS", string.format("%.1f", maxDps))
        end
    end

    -- SPECIAL EFFECTS column: per-template mechanic rows. Aura /
    -- link / blink mechanics moved to the cyan highlights box at
    -- the top of the card per Matthew 2026-04-28 redesign — so
    -- this column only renders MECHANIC_FIELDS overflow now.
    for _, f in ipairs(MECHANIC_FIELDS) do
        local v = stats[f[1]]
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

    if effectsOrder == 0 then
        addEffect(nil, "<i>None.</i>")
    end

    -- Yellow flavor box at the bottom — uses the curated FLAVOR
    -- entry for the tower if available, otherwise falls back to
    -- the template's mechanical description (so the box never
    -- reads empty for a tower that doesn't have a flavor line yet).
    local desc = FLAVOR[towerId]
        or (tpl and tpl.description)
        or (TowerTypes[towerId] and ("Core tower (" .. (TowerTypes[towerId].displayName or towerId) .. ")."))
        or "Power Core (foundation tower)."

    local flavor = Instance.new("Frame")
    flavor.Size = UDim2.new(1, -24, 0, 56)
    flavor.Position = UDim2.new(0, 12, 1, -98)
    flavor.BackgroundColor3 = Color3.fromRGB(80, 70, 30)
    flavor.BorderSizePixel = 0
    flavor.ZIndex = 21
    flavor.Parent = card
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.08, 0)
        c.Parent = flavor
    end
    do
        local s = Instance.new("UIStroke")
        s.Color = Color3.fromRGB(220, 180, 70)
        s.Thickness = 1
        s.Parent = flavor
    end
    do
        local p = Instance.new("UIPadding")
        p.PaddingLeft = UDim.new(0, 8)
        p.PaddingRight = UDim.new(0, 8)
        p.PaddingTop = UDim.new(0, 4)
        p.PaddingBottom = UDim.new(0, 4)
        p.Parent = flavor
    end
    local flavorLbl = Instance.new("TextLabel")
    flavorLbl.Size = UDim2.fromScale(1, 1)
    flavorLbl.BackgroundTransparency = 1
    flavorLbl.Text = desc
    flavorLbl.TextColor3 = Color3.fromRGB(255, 235, 170)
    flavorLbl.Font = Enum.Font.GothamMedium
    flavorLbl.TextSize = 12
    flavorLbl.TextWrapped = true
    flavorLbl.TextXAlignment = Enum.TextXAlignment.Left
    flavorLbl.TextYAlignment = Enum.TextYAlignment.Top
    flavorLbl.ZIndex = 22
    flavorLbl.Parent = flavor

    -- Compressed CLOSE button (height 44 → 32, width unchanged).
    local infoClose = Instance.new("TextButton")
    infoClose.Size = UDim2.new(1, -24, 0, 32)
    infoClose.Position = UDim2.new(0, 12, 1, -38)
    infoClose.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
    infoClose.BorderSizePixel = 0
    infoClose.AutoButtonColor = false
    infoClose.Text = "CLOSE"
    infoClose.TextColor3 = Color3.fromRGB(255, 255, 255)
    infoClose.Font = Enum.Font.FredokaOne
    infoClose.TextSize = 16
    infoClose.ZIndex = 22
    infoClose.Parent = card
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.2, 0)
        c.Parent = infoClose
    end
    infoClose.MouseButton1Click:Connect(function()
        cardGui:Destroy()
    end)

    return cardGui
end

-- Toggle: clicking the (i) button when card is open closes it; when
-- closed, opens fresh. Existing card detected by name lookup on the
-- host (PlayerGui or whatever parentGui resolves to).
function TowerInfoCard.toggle(parentGui, towerId)
    -- Resolve the same host TowerInfoCard.show parents to so the
    -- toggle finds the card regardless of which surface called it.
    local host = parentGui
    if parentGui then
        if parentGui:IsA("ScreenGui") and parentGui.Parent then
            host = parentGui.Parent
        elseif parentGui:FindFirstAncestorOfClass("PlayerGui") then
            host = parentGui:FindFirstAncestorOfClass("PlayerGui")
        end
    end
    local existing = host and host:FindFirstChild("TowerInfoCardGui")
    if existing then
        existing:Destroy()
        return nil
    end
    return TowerInfoCard.show(parentGui, towerId)
end

return TowerInfoCard
