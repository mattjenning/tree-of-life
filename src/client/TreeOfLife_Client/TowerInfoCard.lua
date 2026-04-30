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
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local TempTowers = require(Shared:WaitForChild("TempTowers"))
local TowerTypes = require(Shared:WaitForChild("TowerTypes"))
local TowerCardData = require(Shared:WaitForChild("TowerCardData"))
-- TowerIcons is sibling client-side ModuleScript. Loaded at
-- module-require time (NOT inside a pcall — we WANT the error
-- to surface if the module is missing). Earlier 2026-04-28 the
-- pcall was swallowing a load-order error which left TowerIcons
-- nil → empty icon holder in every card. Direct require is fine
-- because TowerInfoCard.lua and TowerIcons.lua are siblings in
-- the same Rojo-managed folder; they replicate together.
local TowerIcons = require(script.Parent:WaitForChild("TowerIcons"))

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

-- 2026-04-28 dh: TowerInfoCard.show now serves BOTH the Balance
-- Studio (template Common-tier stats, the original use) AND
-- in-game story-mode (live tower attributes with upgrade parens
-- + Attachment row). One render path for both surfaces — the
-- old TowerCard.lua's 600-line duplicate render gets collapsed
-- into a thin delegating call. Per Matthew "i'd like have just
-- one tower info card."
--
-- opts (optional table):
--   towerModel   = live BasePart/Model — when present, the card
--                  shows live attribute values with green-parens
--                  base→modified annotations and an Attachment row.
--                  When nil, the card shows Common-tier baseline
--                  (the original Balance Studio behavior).
--   iconBuilder  = fn(holder) — story-mode passes findTowerDefById
--                  to render the Power core's red-gear icon. When
--                  nil, falls back to TowerIcons[towerId].
function TowerInfoCard.show(parentGui, towerId, opts)
    opts = opts or {}
    local liveTower = opts.towerModel
    local externalIconBuilder = opts.iconBuilder
    -- Resolve stats from BOTH TempTowers (aux) and TowerTypes (Cores).
    -- Cores live in TowerTypes; aux live in TempTowers. The picker
    -- and tier-list both pass towerId equal to the type name for
    -- both.
    local tpl = TempTowers.Templates[towerId]
    local stats
    if tpl then
        -- Aux: prefer live tower's rarity-resolved stats when in
        -- story-mode (so the displayed values match what's actually
        -- placed); else Common-tier per the Balance Studio convention.
        if liveTower then
            local liveRarity = liveTower:GetAttribute("Rarity") or "Common"
            stats = TempTowers.resolveStats(towerId, liveRarity)
                    or table.clone(tpl)
        else
            -- Common-tier per Matthew 2026-04-27: "tower info cards
            -- should show the common version of the tower". Falls back
            -- to the raw template if the resolver hits an unknown rarity.
            stats = TempTowers.resolveStats(towerId, "Common")
                    or table.clone(tpl)
        end
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

    -- 2026-04-28 dd redesign per Matthew. Issues with prior layout:
    --   1. Empty space inside body columns (BODY_HEIGHT fixed at
    --      130 but content often only 50px) → "red box dead space".
    --   2. Standalone description below header pushed body down +
    --      took its own row.
    --   3. Highlights content top-aligned, looked off-balance.
    --   4. Title used TextTruncate.AtEnd so long names showed as
    --      "Mushroom Mortar..."; should font-shrink instead.
    --   5. Card was non-movable.
    -- Fix: card becomes AutomaticSize.Y with a top-level UIListLayout
    -- (header / body / flavor / close stack with no fixed gaps).
    -- Description moves INTO the title column (left of header) with
    -- wordwrap. Highlights box centers content vertically. Title is
    -- TextScaled so it auto-shrinks. Drag handler attached to the
    -- card frame.
    local CARD_W = 480
    local CARD_PAD = 12
    local INNER_W = CARD_W - 2 * CARD_PAD       -- 456 usable
    local card = Instance.new("Frame")
    card.Name = "TowerInfoCard"
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.fromOffset(CARD_W, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
    card.BorderSizePixel = 0
    card.ZIndex = 20
    card.Active = true               -- swallow input for the drag handler
    card.Parent = cardGui
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.04, 0)
        c.Parent = card
    end
    do
        local p = Instance.new("UIPadding")
        p.PaddingTop = UDim.new(0, 8)
        p.PaddingBottom = UDim.new(0, 8)
        p.PaddingLeft = UDim.new(0, CARD_PAD)
        p.PaddingRight = UDim.new(0, CARD_PAD)
        p.Parent = card
    end
    do
        local cardLayout = Instance.new("UIListLayout")
        cardLayout.FillDirection = Enum.FillDirection.Vertical
        cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
        cardLayout.Padding = UDim.new(0, 8)
        -- 2026-04-28 di: Center alignment so the 1/3-width CLOSE
        -- button centers in its row. Header/body/flavor children
        -- have Size.X.Scale = 1 (full width) so the alignment is
        -- a no-op for them; only the smaller CLOSE button moves.
        cardLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        cardLayout.Parent = card
    end

    -- ── HEADER ROW (fixed 64px) ────────────────────────────────
    -- Three-section row: title+description column (left), cyan
    -- highlights box (middle), icon (right).
    local displayName = (tpl and tpl.displayName)
        or (TowerTypes[towerId] and TowerTypes[towerId].displayName)
        or (liveTower and "Power Tower")  -- story-mode fallback for vanilla Power
        or towerId
    -- Rarity comes from the live tower in story mode, "Common" baseline
    -- in Balance Studio. Drives the title color + icon stroke.
    local resolvedRarity = (liveTower and liveTower:GetAttribute("Rarity"))
        or "Common"
    local rc = TempTowers.RarityColors and TempTowers.RarityColors[resolvedRarity]

    local highlightRows, highlightConsumed = buildHighlightRows(stats)
    local hasHighlights = #highlightRows > 0
    -- 2026-04-28 di: highlightConsumed lets the SPECIAL EFFECTS
    -- column suppress fields the cyan box already shows. Per
    -- Matthew "don't show stats duplicative of the cyan box."
    highlightConsumed = highlightConsumed or {}

    local TITLE_W = 200
    local ICON_W  = 64
    local HEADER_H = 64
    local ICON_X = INNER_W - ICON_W
    -- 2026-04-28 di per Matthew:
    --   • "make box 15% wider" — was 120 (dg's 0.7× of the 172 max),
    --     now 138 (≈ 1.15× of 120).
    --   • "move box to be flush against icon" — anchor from the
    --     RIGHT edge (ICON_X) so the box ends exactly where the
    --     icon starts. The freed space ends up on the LEFT, between
    --     the title column and the highlights box, which reads as
    --     deliberate breathing room rather than the prior "title
    --     column → tight highlights → tight icon" cramped feel.
    local HIGHLIGHT_W = 138
    local HIGHLIGHT_X = ICON_X - HIGHLIGHT_W

    local headerRow = Instance.new("Frame")
    headerRow.LayoutOrder = 1
    headerRow.Size = UDim2.new(1, 0, 0, HEADER_H)
    headerRow.BackgroundTransparency = 1
    headerRow.ZIndex = 21
    headerRow.Parent = card

    -- LEFT: title + description column. Title takes top ~24px,
    -- description (wrapped) fills the remainder.
    local titleCol = Instance.new("Frame")
    titleCol.Size = UDim2.fromOffset(TITLE_W, HEADER_H)
    titleCol.Position = UDim2.fromOffset(0, 0)
    titleCol.BackgroundTransparency = 1
    titleCol.ZIndex = 21
    titleCol.Parent = headerRow

    local TITLE_H = 24
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, TITLE_H)
    title.Position = UDim2.fromOffset(0, 0)
    title.BackgroundTransparency = 1
    title.RichText = true
    if rc then
        -- 2026-04-28 di: (Rarity) tag restored per Matthew "add
        -- (Rarity) back to tower name." Combined with the rarity-
        -- color name + icon stroke, the rarity is now signaled by
        -- THREE channels (text suffix, name color, icon border).
        -- Redundant but the explicit text wins for readability —
        -- color alone was hard to distinguish at small TextScaled
        -- sizes. The (Rarity) tag uses a dim gray so it reads as
        -- secondary metadata, not competing with the name.
        local hex = string.format("#%02x%02x%02x",
            math.floor(rc.R * 255 + 0.5),
            math.floor(rc.G * 255 + 0.5),
            math.floor(rc.B * 255 + 0.5))
        title.Text = string.format(
            "<font color='%s'>%s</font>  <font color='#aaaaaa'>(%s)</font>",
            hex, displayName, resolvedRarity)
        title.TextColor3 = Color3.fromRGB(255, 255, 255)  -- fallback for non-RichText path
    else
        title.Text = displayName
        title.TextColor3 = Color3.fromRGB(255, 255, 255)  -- fallback when rarity unknown
    end
    title.Font = Enum.Font.FredokaOne
    title.TextSize = 20
    -- TextScaled shrinks the label content uniformly to fit the
    -- bounding box. Replaces the prior TextTruncate.AtEnd which
    -- cut "Mushroom Mortar" to "Mushroom Mortar...". RichText
    -- inline size tags scale proportionally.
    title.TextScaled = true
    title.TextWrapped = false
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 22
    title.Parent = titleCol

    -- Description sits below title in the SAME column and wraps.
    -- (Was a standalone full-width row below the header; moved
    -- into the title column 2026-04-28 dd.)
    local descLbl = Instance.new("TextLabel")
    descLbl.Size = UDim2.new(1, 0, 1, -(TITLE_H + 2))
    descLbl.Position = UDim2.fromOffset(0, TITLE_H + 2)
    descLbl.BackgroundTransparency = 1
    descLbl.Text = DESCRIPTIONS[towerId]
        or (tpl and tpl.description)
        or ""
    descLbl.TextColor3 = Color3.fromRGB(220, 230, 245)
    descLbl.Font = Enum.Font.Gotham
    descLbl.TextSize = 12
    descLbl.TextWrapped = true
    descLbl.TextXAlignment = Enum.TextXAlignment.Left
    descLbl.TextYAlignment = Enum.TextYAlignment.Top
    descLbl.ZIndex = 22
    descLbl.Parent = titleCol

    -- MIDDLE: cyan highlights box. Vertically centered content
    -- (was top-aligned with PaddingTop=4 — looked off-balance).
    if hasHighlights then
        local hi = Instance.new("Frame")
        hi.Size = UDim2.fromOffset(HIGHLIGHT_W, HEADER_H)
        hi.Position = UDim2.fromOffset(HIGHLIGHT_X, 0)
        hi.BackgroundColor3 = Color3.fromRGB(40, 130, 180)
        hi.BorderSizePixel = 0
        hi.ZIndex = 22
        hi.Parent = headerRow
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
        hl.VerticalAlignment = Enum.VerticalAlignment.Center
        hl.Padding = UDim.new(0, 1)
        hl.Parent = hi
        for i, row in ipairs(highlightRows) do
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, 0, 0, 14)
            l.BackgroundTransparency = 1
            l.RichText = true
            -- 2026-04-28 dg: 1-element rows are description headers
            -- (no colon, italicized). 2-element rows are stat rows.
            -- 2026-04-28 dk: TextWrapped + AutomaticSize.Y removed
            -- per Matthew "fix the space here ... move it up a little."
            -- Wrap was producing extra line-height pad even for short
            -- 1-2-word descs ("Stacking DOT", "Sticky Patches"),
            -- pushing the rest of the box down. All current di
            -- descriptions fit on one line; if a future longer
            -- description needs wrap, it can opt in per-row via a
            -- 3rd element instead of every row paying the height cost.
            if #row == 1 then
                l.Text = string.format("<i>%s</i>", row[1])
            else
                l.Text = string.format("<b>%s:</b> %s", row[1], row[2])
            end
            l.TextColor3 = Color3.fromRGB(255, 255, 255)
            l.Font = Enum.Font.Gotham
            l.TextSize = 12
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.LayoutOrder = i
            l.ZIndex = 23
            l.Parent = hi
        end
    end

    -- RIGHT: icon — 64×64 top-right of header row.
    local iconHolder = Instance.new("Frame")
    iconHolder.Size = UDim2.fromOffset(ICON_W, ICON_W)
    iconHolder.Position = UDim2.fromOffset(ICON_X, 0)
    iconHolder.BackgroundColor3 = Color3.fromRGB(20, 25, 36)
    iconHolder.BorderSizePixel = 0
    iconHolder.ZIndex = 22
    iconHolder.ClipsDescendants = false  -- defensive — child frames must show
    iconHolder.Parent = headerRow
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.12, 0)
        c.Parent = iconHolder
    end
    -- 2026-04-28 dg: rarity-color stroke around icon. Replaces the
    -- "(Common)" text tag in the title — same information, less
    -- text. Stroke 2px so it reads cleanly against the dark
    -- iconHolder background.
    if rc then
        local s = Instance.new("UIStroke")
        s.Color = rc
        s.Thickness = 2
        s.Parent = iconHolder
    end
    -- Icon builder selection. Story mode passes its own
    -- iconBuilder via opts (resolved through findTowerDefById which
    -- knows about the Power core's red-gear icon). Balance Studio
    -- uses the shared TowerIcons module by towerId. Either way the
    -- ZIndex normalization below ensures children render visibly.
    local iconBuilder = externalIconBuilder
        or (TowerIcons and TowerIcons[towerId])
    if iconBuilder then
        iconBuilder(iconHolder)
        -- 2026-04-28 dg: icon-render fix — TowerIcons builders
        -- create child frames at default ZIndex=1, but the dd
        -- refactor moved iconHolder under headerRow (ZIndex=21)
        -- with iconHolder at ZIndex=22. In Sibling ZIndexBehavior
        -- this should still draw correctly, but the screenshots
        -- show the icon area rendering as a flat dark square —
        -- children invisible. Force every descendant of iconHolder
        -- to a high ZIndex so they're guaranteed to render above
        -- the iconHolder background, regardless of the upstream
        -- ZIndexBehavior or Sibling-mode quirks.
        for _, desc in ipairs(iconHolder:GetDescendants()) do
            if desc:IsA("GuiObject") then
                desc.ZIndex = 23
            end
        end
    end

    -- ── BODY: STATS / SPECIAL EFFECTS columns ─────────────────
    -- AutomaticSize.Y on each column → no dead empty space. The
    -- bodyRow inherits the taller column's height. Card's top-
    -- level UIListLayout stacks header/body/flavor/close with no
    -- gaps beyond its 8px padding.
    local bodyRow = Instance.new("Frame")
    bodyRow.LayoutOrder = 2
    bodyRow.Size = UDim2.fromScale(1, 0)
    bodyRow.AutomaticSize = Enum.AutomaticSize.Y
    bodyRow.BackgroundTransparency = 1
    bodyRow.ZIndex = 21
    bodyRow.Parent = card

    local function makeColumn(xScale, xOffset, headerText)
        local col = Instance.new("Frame")
        col.Size = UDim2.new(0.5, -4, 0, 0)
        col.Position = UDim2.new(xScale, xOffset, 0, 0)
        col.AutomaticSize = Enum.AutomaticSize.Y
        col.BackgroundTransparency = 1
        col.ZIndex = 22
        col.Parent = bodyRow

        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.Padding = UDim.new(0, 0)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = col

        local header = Instance.new("TextLabel")
        header.LayoutOrder = 0
        header.Size = UDim2.new(1, 0, 0, 18)
        header.BackgroundTransparency = 1
        header.Text = headerText
        header.TextColor3 = Color3.fromRGB(180, 200, 230)
        header.Font = Enum.Font.GothamBold
        header.TextSize = 11
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.ZIndex = 23
        header.Parent = col

        return col
    end

    local statsCol   = makeColumn(0,   0, "STATS")
    local effectsCol = makeColumn(0.5, 4, "SPECIAL EFFECTS")

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

    -- STATS column. In Balance Studio (template), values come from
    -- the resolved-stats table. In story mode (liveTower set), values
    -- come from the live tower attributes — and if XBase differs from
    -- X (i.e. an upgrade or attachment is active), we annotate with
    -- a green-parens "(modified)" suffix so the player sees the
    -- delta from their build.
    local baseDmg, modDmg, baseRng, modRng, baseFr, modFr
    if liveTower then
        modDmg  = liveTower:GetAttribute("Damage")    or stats.damage   or 0
        baseDmg = liveTower:GetAttribute("DamageBase") or modDmg
        modRng  = liveTower:GetAttribute("Range")     or stats.range    or 0
        baseRng = liveTower:GetAttribute("RangeBase") or modRng
        modFr   = liveTower:GetAttribute("FireRate")  or stats.fireRate or 0
        baseFr  = liveTower:GetAttribute("FireRateBase") or modFr
        -- ea3-127: fold support-tower aura bonuses into the modified
        -- values so the card surfaces "buff active from a Support
        -- tower" as a green delta. Server applies aura mults at
        -- fire-time only (Towers.lua line 696/716/726) — the persistent
        -- Range/Damage/FireRate attributes stay at base+upgrades. Per
        -- Matthew "separate base range from modified range from support
        -- towers, like we do with upgrades."
        local auraDmgBoost = liveTower:GetAttribute("AuraDamageBoost")   or 0
        local auraFrBoost  = liveTower:GetAttribute("AuraFireRateBoost") or 0
        local auraRngBoost = liveTower:GetAttribute("AuraRangeBoost")    or 0
        if auraDmgBoost > 0 then modDmg = modDmg * (1 + auraDmgBoost / 100) end
        if auraFrBoost  > 0 then modFr  = modFr  * (1 + auraFrBoost  / 100) end
        if auraRngBoost > 0 then modRng = modRng * (1 + auraRngBoost / 100) end
    else
        baseDmg = stats.damage   or 0
        modDmg  = baseDmg
        baseRng = stats.range    or 0
        modRng  = baseRng
        baseFr  = stats.fireRate or 0
        modFr   = baseFr
    end
    local function fmtBaseMod(label, base, mod, suffix, fmt)
        fmt = fmt or "%d"
        suffix = suffix or ""
        -- %d in Luau truncates instead of rounds; pre-floor so
        -- "Range: 14.56" displays as 15 not 14 (matches the old
        -- TowerCard "%d on math.floor(+0.5)" behavior).
        if fmt == "%d" then
            base = math.floor(base + 0.5)
            mod  = math.floor(mod + 0.5)
        end
        if math.abs(mod - base) < 0.01 then
            addStat(label, string.format(fmt .. suffix, base))
        else
            addStat(label, string.format(
                "%s%s  <font color='%s'>(%s%s)</font>",
                string.format(fmt, base), suffix,
                BONUS_GREEN,
                string.format(fmt, mod), suffix))
        end
    end
    fmtBaseMod("Damage",    baseDmg, modDmg, "",       "%.1f")
    fmtBaseMod("Range",     baseRng, modRng, "",       "%d")
    fmtBaseMod("Fire Rate", baseFr,  modFr,  " /sec",  "%.2f")

    -- Max DPS uses MODIFIED stats so the displayed DPS reflects
    -- the player's current build. Theoretical (multi-target) ceiling
    -- still shown in green parens via computeTheoreticalDps.
    local maxDps = modDmg * modFr
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
        -- 2026-04-28 di: skip fields the cyan highlights box
        -- already rendered (avoid duplicate "Patch radius: 10"
        -- in both columns). highlightConsumed populated by
        -- buildHighlightRows.
        if highlightConsumed[f[1]] then v = nil end
        if v ~= nil then
            local valStr
            if f[3] == "pct" then
                valStr = string.format("%d%%", math.floor(v * 100 + 0.5))
            elseif f[3] == "sec" then
                valStr = string.format("%.1fs", v)
            elseif f[3] == "count" or f[3] == "studs" then
                -- 2026-04-28 di: "never say studs" per Matthew —
                -- drop the unit, render bare number. count + studs
                -- both render unit-less integers. Memory:
                -- feedback_no_studs_unit.md.
                valStr = tostring(math.floor(v + 0.5))
            else
                valStr = string.format("%d %s", math.floor(v + 0.5), f[3])
            end
            addEffect(f[2], valStr)
        end
    end

    -- Story-mode-only extras: live-tower-derived rows that don't
    -- exist on the template. AOE radius (Core upgrades), Stun and
    -- Knockback proc rolls (attachment-derived), and the Attachment
    -- row itself (TODO: clickable for attachment swap — see
    -- project_attachment_reconfig.md memory).
    if liveTower then
        if not tpl then
            -- Core only — aux's AOE is already surfaced via
            -- splashRadius/blastRadius rows from MECHANIC_FIELDS.
            local aoe = liveTower:GetAttribute("AoeRadius")
            if aoe and aoe > 0 then
                addEffect("AOE radius", string.format("%d studs", math.floor(aoe + 0.5)))
            end
        end
        local stunDur = liveTower:GetAttribute("StunDuration")
        if stunDur and stunDur > 0 then
            local stunPct = math.floor((liveTower:GetAttribute("StunChance") or 0.05) * 100 + 0.5)
            addEffect("Stun", string.format("%.1fs on %d%% of hits", stunDur, stunPct))
        end
        local knock = liveTower:GetAttribute("Knockback")
        if knock and knock > 0 then
            local kbPct = math.floor((liveTower:GetAttribute("KnockbackChance") or 0.05) * 100 + 0.5)
            addEffect("Knockback", string.format("%d studs on %d%%", math.floor(knock + 0.5), kbPct))
        end
        -- Attachment row: Core-only.
        --
        -- TODO 2026-04-28 dh — make this row INTERACTIVE per
        -- project_attachment_reconfig.md (memory). Replace this
        -- read-only addEffect with a clickable button that opens
        -- an attachment-picker subpanel. Server enforces cooldown
        -- or seedling cost (open question in the memory file).
        if not tpl then
            local equipType = liveTower:GetAttribute("EquippedType") or ""
            local equipRar = liveTower:GetAttribute("EquippedRarity")
            local RARITY_NAMES = { "Common", "Rare", "Exceptional", "Legendary", "Mythical" }
            if equipType ~= "" and equipRar then
                addEffect("Attachment", string.format("%s (%s)",
                    equipType, RARITY_NAMES[equipRar] or "?"))
            end
        end
    end

    if effectsOrder == 0 then
        addEffect(nil, "<i>None</i>")
    end

    -- Flavor text — italic + yellow, NO box / border / background.
    -- LayoutOrder=3 (between body and close in the card's vertical
    -- list). AutomaticSize.Y so wrapped lines size the label.
    --
    -- 2026-04-28 dg: trailing ellipsis appended per Matthew "add
    -- ellipses after flavor text." Reads as a quotation tail — the
    -- flavor is a fragment, not a complete sentence. If the source
    -- string already ends with punctuation we strip it first so we
    -- don't end up with "snaps backwards.…" — just "snaps backwards…".
    local desc = FLAVOR[towerId]
        or (tpl and tpl.description)
        or (TowerTypes[towerId] and ("Core tower (" .. (TowerTypes[towerId].displayName or towerId) .. ")."))
        or "Power Core (foundation tower)."
    -- Strip trailing . / ! / ? before appending ellipsis.
    desc = desc:gsub("[%.%!%?]+%s*$", "")
    desc = desc .. "…"

    local flavorLbl = Instance.new("TextLabel")
    flavorLbl.LayoutOrder = 3
    flavorLbl.Size = UDim2.fromScale(1, 0)
    flavorLbl.AutomaticSize = Enum.AutomaticSize.Y
    flavorLbl.BackgroundTransparency = 1
    flavorLbl.RichText = true
    flavorLbl.Text = "<i>" .. desc .. "</i>"
    flavorLbl.TextColor3 = Color3.fromRGB(255, 235, 170)
    flavorLbl.Font = Enum.Font.GothamMedium
    flavorLbl.TextSize = 13
    flavorLbl.TextWrapped = true
    flavorLbl.TextXAlignment = Enum.TextXAlignment.Left
    flavorLbl.TextYAlignment = Enum.TextYAlignment.Top
    flavorLbl.ZIndex = 22
    flavorLbl.Parent = card

    -- CLOSE button — LayoutOrder=4 (last in the stack).
    -- 2026-04-28 di: width 1/3 of card per Matthew "make close
    -- button just 1/3 screen width." Was full-width (1, 0); now
    -- 1/3 inner-width. Card's UIListLayout has HorizontalAlignment
    -- = Center so the smaller button centers in its row while
    -- header/body/flavor (all Size.X.Scale = 1) stay full-width.
    local infoClose = Instance.new("TextButton")
    infoClose.LayoutOrder = 4
    infoClose.Size = UDim2.fromOffset(math.floor(INNER_W / 3 + 0.5), 28)
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

    -- ── Drag-to-move (added 2026-04-28 dd) ─────────────────────
    -- Click-and-hold anywhere on the card body starts a drag;
    -- movement updates card.Position. The CLOSE button absorbs
    -- MouseButton1 (it's a TextButton with MouseButton1Click), so
    -- clicking it doesn't initiate a drag — clean separation.
    -- Both mouse and touch supported.
    local dragData = nil
    local moveConn  -- declared up here so the InputBegan closure can capture it
    card.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragData = {
                startMouse = UserInputService:GetMouseLocation(),
                startPos = card.Position,
            }
        end
    end)
    card.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragData = nil
        end
    end)
    moveConn = UserInputService.InputChanged:Connect(function(input)
        if not dragData then return end
        if not card.Parent then
            -- Card destroyed mid-drag (CLOSE clicked, run reset, etc.).
            -- Disconnect so we don't leak this signal across runs.
            if moveConn then moveConn:Disconnect() end
            return
        end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
           and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        local delta = UserInputService:GetMouseLocation() - dragData.startMouse
        local sp = dragData.startPos
        card.Position = UDim2.new(
            sp.X.Scale, sp.X.Offset + delta.X,
            sp.Y.Scale, sp.Y.Offset + delta.Y
        )
    end)
    -- Belt-and-braces cleanup: when the ScreenGui dies, drop the
    -- UIS connection regardless of where the destroy came from
    -- (CLOSE click, parent panel teardown, etc.).
    cardGui.Destroying:Connect(function()
        if moveConn then moveConn:Disconnect() end
    end)

    return cardGui
end

-- Toggle: clicking the (i) button when card is open closes it; when
-- closed, opens fresh. Existing card detected by name lookup on the
-- host (PlayerGui or whatever parentGui resolves to).
function TowerInfoCard.toggle(parentGui, towerId, opts)
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
    -- 2026-04-28 dh: opts forwarded to show() for the live-tower
    -- mode (story-mode in-arena (i) button passes towerModel +
    -- iconBuilder; Balance Studio passes nil and uses templated
    -- defaults).
    return TowerInfoCard.show(parentGui, towerId, opts)
end

return TowerInfoCard
