--!strict
--[[
    TowerCardData.lua — Shared per-tower text + signature-mechanic
    helper for the two tower-info-card surfaces.

    WHY THIS MODULE EXISTS:
    Story-mode `TowerCard.lua` and Balance-Studio `TowerInfoCard.lua`
    both render the same per-tower content (mechanical description,
    flavor quote, top-of-card signature highlights). Before this
    module the data lived as duplicated literals in BOTH files —
    every text edit had to be applied twice and any drift quietly
    showed different strings on the two surfaces.

    THIS MODULE IS THE ONLY PLACE TO EDIT:
      • DESCRIPTIONS[towerId]   — mechanical 1-2 sentence blurb
      • FLAVOR[towerId]         — evocative one-liner (yellow box)
      • buildHighlightRows(stats) — picks the tower's signature
        mechanic (aura / link / blink / DOT / splash / chain /
        pierce / patch / cloud / stun / slow), returns ordered
        {label, value} list. Empty list = hide the highlights box.

    USAGE:
        local Card = require(ReplicatedStorage.Shared.TowerCardData)
        local desc = Card.DESCRIPTIONS[towerId] or fallback
        local flavor = Card.FLAVOR[towerId] or fallback
        local rows = Card.buildHighlightRows(stats)
        if #rows > 0 then ... end

    Pure data + one pure function. No Roblox Instance creation.
    Safe to require from server-side test code (the tests folder
    already uses shared modules this way).
]]

local TowerCardData = {}

-- ===========================================================================
-- DESCRIPTIONS — mechanical, 1-2 sentences. Different in tone and
-- intent from FLAVOR (the yellow box). DESCRIPTIONS explain WHAT
-- the tower does; FLAVOR communicates how it FEELS.
--
-- Add a new entry here whenever a tower lands in TempTowers.Templates
-- or TowerTypes. The card fallback chain is:
--   DESCRIPTIONS[towerId]
--     → tpl.description (TempTowers/TowerTypes mechanical text)
--     → ""
-- so missing entries don't crash; they just show the slightly
-- terser template description.
-- ===========================================================================
TowerCardData.DESCRIPTIONS = {
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
    PepperCannon   = "Slow, heavy splash bomb. A decisive AOE anchor for big clusters.",
    MushroomMortar  = "Lobs a slow shell across the map for a massive blast on impact.",
    BlinkBerry      = "Every 8s, teleports nearby enemies back along the path. Also fires light shots.",
    PaceFlower      = "Aura. Nearby towers fire faster. Doesn't fire shots itself.",
    PowerSeed       = "Aura. Nearby towers deal more damage. Doesn't fire shots itself.",
    SpyglassRoot    = "Aura. Nearby towers see further. Doesn't fire shots itself.",
    BloodlinkVine   = "Aura. Damage to any linked enemy mirrors to every other linked enemy.",
}

-- ===========================================================================
-- FLAVOR — evocative one-liner shown in the yellow box at the
-- bottom of the card. Keep short (one sentence), poetic where
-- possible, and DO NOT duplicate mechanical info already in
-- DESCRIPTIONS / STATS / SPECIAL EFFECTS / highlights.
-- ===========================================================================
TowerCardData.FLAVOR = {
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

-- ===========================================================================
-- buildHighlightRows — picks the tower's SIGNATURE mechanic and
-- returns an ordered list of rows the caller renders inside the
-- cyan highlights box at the top-right of the card.
--
-- 2026-04-28 dg row format change per Matthew "if there are only
-- two lines, add a 3rd line up top that describes the ability.
-- if you need four lines, think of a way to consolidate to 3."
--
-- ROW SHAPES — two forms:
--   Description row: { "<text>" }            (length 1 — italic, no colon)
--   Stat row:        { "<label>", "<value>" } (length 2 — bold label + value)
-- Renderers detect by `#row == 1`.
--
-- Each branch returns 1-3 rows total. First row is ALWAYS a
-- description (sets the "what does this do" context); remaining
-- rows are ≤2 stat rows. For aura with multiple bonus axes the
-- bonuses get consolidated into one combined stat row (e.g.
-- "+10% dmg, +10% fr") so the cap of 3 rows holds.
--
-- Priority cascade — first non-empty match wins:
--   aura → link → blink → stack-DOT → splash → blast → chain →
--   pierce → patch → cloud → stun → slow.
--
-- Returns an EMPTY list when the tower has no signature mechanic
-- (e.g. vanilla Power without upgrades) — caller hides the box
-- entirely so the description gets the full row width.
--
-- Stats argument: a flat table of mechanic fields. Both consumers
-- pass a merged snapshot — story mode merges live attributes
-- (DamageBase, AuraRadius, etc.) with the template; balance studio
-- passes the Common-tier resolved stats. Either shape is supported.
-- ===========================================================================
function TowerCardData.buildHighlightRows(stats: {[string]: any}): ({ { string } }, { [string]: boolean }?)
    -- 2026-04-28 di edits per Matthew:
    --   • "never say studs" — drop the suffix from every distance
    --     value. Memory: feedback_no_studs_unit.md
    --   • Italic descriptions shortened to ONE LINE — they'd
    --     wrap to a second row in the box and add visual clutter.
    --     Tower DESCRIPTIONS (in the title column) already cover
    --     the mechanic detail, so the highlights description only
    --     needs to label the SHAPE of the mechanic. Example:
    --     "Sticky patch slows and ticks damage" → "Sticky Patches".
    --
    -- Returns:
    --   rows     — list of { label, value } / { description }
    --              entries to render in the cyan highlights box.
    --   consumed — set of stat field names that this branch ALREADY
    --              rendered in the highlights box. Caller's
    --              SPECIAL EFFECTS column should skip these to
    --              avoid showing duplicate values. Per Matthew
    --              2026-04-28 di "don't show stats duplicative of
    --              the cyan box like radius and slow in this case."
    --              Only RAW field names whose values match exactly;
    --              derived rows (e.g. Cloud DOT = tick × ticks/sec)
    --              don't mark the underlying tick fields consumed
    --              since the SPECIAL EFFECTS column shows them
    --              individually for tuning visibility.
    local rows: { { string } } = {}
    local consumed: { [string]: boolean } = {}
    if stats.auraRadius and stats.auraRadius > 0 then
        consumed.auraRadius = true
        consumed.auraFireRateBonusPct = true
        consumed.auraDamageBonusPct = true
        consumed.auraRangeBonusPct = true
        local rangeStr = (stats.auraRadius >= 9999)
            and "unlimited"
            or tostring(math.floor(stats.auraRadius + 0.5))
        local bonusRows = {}
        if stats.auraFireRateBonusPct and stats.auraFireRateBonusPct > 0 then
            table.insert(bonusRows, { "+Fire rate", string.format("%d%%", stats.auraFireRateBonusPct) })
        end
        if stats.auraDamageBonusPct and stats.auraDamageBonusPct > 0 then
            table.insert(bonusRows, { "+Damage", string.format("%d%%", stats.auraDamageBonusPct) })
        end
        if stats.auraRangeBonusPct and stats.auraRangeBonusPct > 0 then
            table.insert(bonusRows, { "+Range", string.format("%d%%", stats.auraRangeBonusPct) })
        end
        if #bonusRows >= 2 then
            for _, br in ipairs(bonusRows) do table.insert(rows, br) end
            table.insert(rows, { "Range", rangeStr })
        else
            local desc = (stats.auraRadius >= 9999) and "Global Aura" or "Aura Buff"
            table.insert(rows, { desc })
            table.insert(rows, { "Range", rangeStr })
            for _, br in ipairs(bonusRows) do table.insert(rows, br) end
        end
        return rows, consumed
    end
    if stats.linkRadius and stats.linkRadius > 0 then
        consumed.linkRadius = true
        consumed.linkEchoFrac = true
        table.insert(rows, { "Linked Damage" })
        table.insert(rows, { "Link radius", tostring(math.floor(stats.linkRadius + 0.5)) })
        local echo = stats.linkEchoFrac or 0.5
        table.insert(rows, { "Echo", string.format("%d%%", math.floor(echo * 100 + 0.5)) })
        return rows, consumed
    end
    if stats.blinkInterval and stats.blinkInterval > 0 then
        consumed.blinkInterval = true
        consumed.blinkDistance = true
        table.insert(rows, { "Teleport Pulse" })
        table.insert(rows, { "Interval", string.format("%.1fs", stats.blinkInterval) })
        local d = stats.blinkDistance or 0
        table.insert(rows, { "Setback", tostring(math.floor(d + 0.5)) })
        return rows, consumed
    end
    if stats.stackDotTickDmg and stats.stackDotTickDmg > 0 then
        consumed.stackDotTickDmg = true
        consumed.maxStacks = true
        table.insert(rows, { "Stacking DOT" })
        table.insert(rows, { "DOT tick", string.format("%d dmg/s", math.floor(stats.stackDotTickDmg + 0.5)) })
        table.insert(rows, { "Max stacks", tostring(stats.maxStacks or 0) })
        return rows, consumed
    end
    if stats.splashRadius and stats.splashRadius > 0 then
        consumed.splashRadius = true
        table.insert(rows, { "Splash AOE" })
        table.insert(rows, { "Splash radius", tostring(math.floor(stats.splashRadius + 0.5)) })
        return rows, consumed
    end
    if stats.blastRadius and stats.blastRadius > 0 then
        consumed.blastRadius = true
        consumed.lobSeconds = true
        table.insert(rows, { "Lobbed Blast" })
        table.insert(rows, { "Blast radius", tostring(math.floor(stats.blastRadius + 0.5)) })
        if stats.lobSeconds then
            table.insert(rows, { "Lob time", string.format("%.1fs", stats.lobSeconds) })
        end
        return rows, consumed
    end
    if stats.chainJumps and stats.chainJumps > 0 then
        consumed.chainJumps = true
        consumed.chainFalloff = true
        table.insert(rows, { "Lightning Chain" })
        table.insert(rows, { "Chain jumps", tostring(stats.chainJumps) })
        if stats.chainFalloff then
            table.insert(rows, { "Falloff", string.format("%d%%", math.floor(stats.chainFalloff * 100 + 0.5)) })
        end
        return rows, consumed
    end
    if stats.pierceCount and stats.pierceCount > 0 then
        consumed.pierceCount = true
        table.insert(rows, { "Pierce Shot" })
        table.insert(rows, { "Pierce", tostring(stats.pierceCount) })
        return rows, consumed
    end
    if stats.patchTickDmg and stats.patchTickDmg > 0 then
        consumed.patchRadius = true
        consumed.patchSlowPct = true
        table.insert(rows, { "Sticky Patches" })
        table.insert(rows, { "Patch radius", tostring(math.floor((stats.patchRadius or 0) + 0.5)) })
        table.insert(rows, { "Patch slow", string.format("%d%%", math.floor((stats.patchSlowPct or 0) * 100 + 0.5)) })
        return rows, consumed
    end
    if stats.cloudTickDmg and stats.cloudTickDmg > 0 then
        consumed.cloudRadius = true
        -- Cloud DOT is DERIVED (cloudTickDmg × cloudTickPerSec); leave
        -- the raw tick fields visible in SPECIAL EFFECTS for tuning.
        table.insert(rows, { "Poison Cloud" })
        table.insert(rows, { "Cloud radius", tostring(math.floor((stats.cloudRadius or 0) + 0.5)) })
        table.insert(rows, { "Cloud DOT", string.format("%d/s", math.floor(stats.cloudTickDmg * (stats.cloudTickPerSec or 1) + 0.5)) })
        return rows, consumed
    end
    if stats.stunSeconds and stats.stunSeconds > 0 then
        consumed.stunSeconds = true
        consumed.stunCooldown = true
        table.insert(rows, { "Stun Hit" })
        table.insert(rows, { "Stun", string.format("%.1fs", stats.stunSeconds) })
        if stats.stunCooldown then
            table.insert(rows, { "Cooldown", string.format("%.1fs", stats.stunCooldown) })
        end
        return rows, consumed
    end
    if stats.slowStackPct or stats.slowPct then
        table.insert(rows, { "Stacking Slow" })
        if stats.slowStackCap then
            consumed.slowStackCap = true
            table.insert(rows, { "Slow cap", string.format("%d%%", math.floor(stats.slowStackCap * 100 + 0.5)) })
        elseif stats.slowPct then
            consumed.slowPct = true
            table.insert(rows, { "Slow", string.format("%d%%", math.floor(stats.slowPct * 100 + 0.5)) })
        end
        if stats.slowSeconds then
            consumed.slowSeconds = true
            table.insert(rows, { "Duration", string.format("%.1fs", stats.slowSeconds) })
        end
        return rows, consumed
    end
    return rows, consumed
end

return TowerCardData
