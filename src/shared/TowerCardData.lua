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
-- returns an ordered list of {label, value} pairs the caller renders
-- inside the cyan highlights box at the top-right of the card.
--
-- Priority cascade — first non-empty match wins. The box should
-- read as ONE feature, not a kitchen sink:
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
function TowerCardData.buildHighlightRows(stats: {[string]: any}): { { string } }
    local rows: { { string } } = {}
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

return TowerCardData
