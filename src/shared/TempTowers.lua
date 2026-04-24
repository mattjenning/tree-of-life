--!strict
--[[
    TempTowers.lua — Templates and rarity scaling for the 9 temp towers
    you earn from map-boss defeats.

    ROLE IN THE SYSTEM:
    The three map bosses (maps 1/2/3) each let the player pick 1 of 3
    randomly-rolled temp towers. Each card rolls a tower id and a rarity
    independently; stock count is fixed per tower id (rarity does NOT
    change how many copies you get — that's a tactical footprint decision,
    not a rarity one). Beating the final run boss (Pickle Lord) drops a
    permanent tower from this same pool, persisted across runs.

    DESIGN BUDGET:
    Starter Power tower solo = 28.8 DPS (18 dmg × 1.6 shots/sec, 1 placed).
    Temp towers target ~80% of that total when fully placed:
        per-copy DPS × stock ≈ 23 DPS  (at Rare baseline)
    Rarity nudges this narrowly (±~15%) so no single roll defines a run.
    Secondary mechanics (slow%, AOE radius, stun duration, pierce count,
    chain jumps, DOT radius) scale slightly wider so rarity still *feels*
    different — Mythical is a notable upgrade, not a game-breaker.

    FOOTPRINT IS THE TACTICAL AXIS:
    Stock and footprint vary together. A 4×4-cell tower with stock 4
    (Frost Melon) covers more of the map but each copy is weak. A 12×12
    tower with stock 1 (Mushroom Mortar) is one decisive commitment that
    swallows a big chunk of the grid. Same DPS budget, different tactics.

    RARITY MODEL — rolled per drop (not fixed per tower):
    Every tower can drop at any rarity. Frost Melon Common vs Frost Melon
    Mythical are the same template, different RarityMults applied.

    DUPLICATES:
    If a boss rolls a tower type the player already owns, higher rarity
    replaces lower; lower is skipped. (See resolveReplacement below.)

    WHERE THIS IS USED:
    - Server reward flow calls rollThreeCards() when a map boss dies.
    - Client picker UI renders cards using displayName / description /
      RarityColors.
    - Tower builder code stamps stats from resolveStats(towerId, rarity)
      onto the placed Tower Instance (same Base/Bonus pattern TowerTypes
      uses — Base = resolveStats output, Bonus = 0 at placement).

    NAMING: RARITY COLORS are the same palette used by upgrade cards and
    attachments. DO NOT invent new rarity colors elsewhere.
--]]

local TempTowers = {}

-- ===========================================================================
-- RARITY MULTIPLIERS — tight spread so no rarity warps the run.
--   dps scales `damage` and `fireRate`.
--   secondary scales continuous mechanic fields (slow%, durations, radii).
--   Discrete counts (pierce, chain jumps) use RarityStep below instead.
-- Common→Mythical spread: 1.43× DPS, 1.36× secondary.
-- ===========================================================================
TempTowers.RarityMults = table.freeze({
    Common      = table.freeze({ dps = 0.91, secondary = 0.90 }),
    Rare        = table.freeze({ dps = 1.00, secondary = 1.00 }),
    Exceptional = table.freeze({ dps = 1.08, secondary = 1.08 }),
    Legendary   = table.freeze({ dps = 1.17, secondary = 1.15 }),
    Mythical    = table.freeze({ dps = 1.30, secondary = 1.22 }),
})

-- ===========================================================================
-- RARITY STEP — additive bumps for discrete integer mechanics.
-- Pierce / chain-jump counts are gameplay-meaningful as integers, so a
-- multiplicative mult on `2` → `2.44` doesn't make sense. Instead, apply
-- these additions to the base integer count.
-- ===========================================================================
TempTowers.RarityStep = table.freeze({
    Common      = 0,
    Rare        = 0,
    Exceptional = 1,
    Legendary   = 1,
    Mythical    = 2,
})

-- ===========================================================================
-- RARITY ORDER — weakest → strongest. Used for iteration and ranking
-- (e.g. duplicate replace-if-higher).
-- ===========================================================================
TempTowers.RarityOrder = table.freeze({
    "Common", "Rare", "Exceptional", "Legendary", "Mythical",
})

-- ===========================================================================
-- RARITY RANK — constant-time rarity comparison. Higher = better.
-- Keep in sync with RarityOrder.
-- ===========================================================================
TempTowers.RarityRank = table.freeze({
    Common      = 1,
    Rare        = 2,
    Exceptional = 3,
    Legendary   = 4,
    Mythical    = 5,
})

-- ===========================================================================
-- RARITY COLORS — shared palette. Same RGB values as RARITY_TIERS in
-- src/server/systems/UpgradeCards.lua. Do NOT diverge. If these need to
-- change, change UpgradeCards in the same commit.
-- ===========================================================================
TempTowers.RarityColors = table.freeze({
    Common      = Color3.fromRGB(200, 200, 200),
    Rare        = Color3.fromRGB( 80, 150, 255),
    Exceptional = Color3.fromRGB(180,  80, 220),
    Legendary   = Color3.fromRGB(255, 170,  40),
    Mythical    = Color3.fromRGB(255,  60, 140),
})

-- ===========================================================================
-- BOSS DROP WEIGHTS — rarity weights per reward source.
-- Map bosses escalate; Pickle Lord (final run boss) uses the standard
-- upgrade-card distro since its reward is permanent (persistent value
-- matters more than peak rarity).
-- Sums are ~100 for readability but rollRarity normalizes by total.
-- ===========================================================================
TempTowers.BossWeights = table.freeze({
    Map1       = table.freeze({ Common = 60, Rare = 30, Exceptional =  8, Legendary =  2, Mythical =  0 }),
    Map2       = table.freeze({ Common = 30, Rare = 35, Exceptional = 25, Legendary =  8, Mythical =  2 }),
    Map3       = table.freeze({ Common = 10, Rare = 25, Exceptional = 35, Legendary = 22, Mythical =  8 }),
    PickleLord = table.freeze({ Common = 50, Rare = 25, Exceptional = 10, Legendary =  5, Mythical =  2 }),
})

-- ===========================================================================
-- TEMPLATES — the 9 temp towers. Budget per template: per-copy DPS × stock
-- ≈ 23 at Rare baseline. Footprint units are grid cells (Config.Grid.CellSize
-- = 2 studs, Power baseline is 4×4 cells = 8×8 studs).
--
-- Field conventions (match TowerTypes.lua where applicable):
--   damage, range, fireRate, maxShots, maxAmmo     — combat basics
--   footprintWidth, footprintDepth                 — cells (not studs)
--   defaultTargetMode                              — First/Strongest/Center/Last
-- Secondary fields are tower-specific and get scaled by RarityMults.secondary
-- (for continuous) or RarityStep (for discrete). See resolveStats below.
-- ===========================================================================
TempTowers.Templates = {}

TempTowers.Templates.RootSprout = table.freeze({
    id = "RootSprout",
    name = "RootSprout",
    displayName = "Root Sprout",
    description = "Short-range stunner. Briefly roots enemies in place.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 4,
    maxShots = 40, maxAmmo = 4,
    damage = 3, fireRate = 2.0, range = 24,     -- ~6 DPS × 4 = 24 total (range bumped 15→24 so it actually contests path mobs)
    stunSeconds = 0.5, stunCooldown = 3.0,
    defaultTargetMode = "First",
})

TempTowers.Templates.FrostMelon = table.freeze({
    id = "FrostMelon",
    name = "FrostMelon",
    displayName = "Frost Melon",
    description = "Chills enemies in a small AOE, slowing them.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 4,
    maxShots = 40, maxAmmo = 4,
    damage = 4, fireRate = 1.5, range = 25,     -- ~6 DPS × 4 = 24 total
    slowPct = 0.40, slowSeconds = 2.0, aoeRadius = 6,
    defaultTargetMode = "First",
})

TempTowers.Templates.ThornVine = table.freeze({
    id = "ThornVine",
    name = "ThornVine",
    displayName = "Thorn Vine",
    description = "Shots pierce through lined-up enemies.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 3,
    maxShots = 30, maxAmmo = 3,
    damage = 5, fireRate = 1.6, range = 30,     -- ~8 DPS × 3 = 24 total
    pierceCount = 2,                             -- +RarityStep
    defaultTargetMode = "First",
})

TempTowers.Templates.HoneyHive = table.freeze({
    id = "HoneyHive",
    name = "HoneyHive",
    displayName = "Honey Hive",
    description = "Drops sticky patches that slow and tick damage.",
    footprintWidth = 4, footprintDepth = 6,     -- elongated patch-dropper
    stock = 3,
    maxShots = 30, maxAmmo = 3,
    damage = 2, fireRate = 0.8, range = 20,     -- direct hit weak; patch does the work
    patchRadius = 8, patchSeconds = 4.0, patchSlowPct = 0.40, patchTickDmg = 4, patchTickPerSec = 2,
    defaultTargetMode = "First",
})

TempTowers.Templates.AcornSniper = table.freeze({
    id = "AcornSniper",
    name = "AcornSniper",
    displayName = "Acorn Sniper",
    description = "Long range, slow cadence, one heavy shot.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 2,
    maxShots = 20, maxAmmo = 2,
    damage = 30, fireRate = 0.4, range = 70,    -- ~12 DPS × 2 = 24 total
    defaultTargetMode = "Strongest",
})

TempTowers.Templates.LightningRadish = table.freeze({
    id = "LightningRadish",
    name = "LightningRadish",
    displayName = "Lightning Radish",
    description = "Chains lightning to nearby enemies.",
    footprintWidth = 6, footprintDepth = 6,
    stock = 2,
    maxShots = 30, maxAmmo = 3,
    damage = 8, fireRate = 1.5, range = 28,     -- ~12 DPS × 2 = 24 total
    chainJumps = 2, chainFalloff = 0.60, chainRange = 14,
    defaultTargetMode = "Center",                -- cluster-killer; center targeting packs jumps
})

TempTowers.Templates.SporePuffball = table.freeze({
    id = "SporePuffball",
    name = "SporePuffball",
    displayName = "Spore Puffball",
    description = "Impact releases a lingering poison cloud.",
    footprintWidth = 6, footprintDepth = 6,
    stock = 2,
    maxShots = 30, maxAmmo = 3,
    damage = 3, fireRate = 1.2, range = 25,     -- direct hit weak; cloud does the work
    cloudRadius = 8, cloudSeconds = 3.0, cloudTickDmg = 3, cloudTickPerSec = 4,
    defaultTargetMode = "First",
})

TempTowers.Templates.PepperCannon = table.freeze({
    id = "PepperCannon",
    name = "PepperCannon",
    displayName = "Pepper Cannon",
    description = "One slow, heavy splash. A decisive anchor.",
    footprintWidth = 8, footprintDepth = 8,
    stock = 1,
    maxShots = 20, maxAmmo = 2,
    damage = 25, fireRate = 0.9, range = 32,    -- ~23 DPS × 1 = 23 total
    splashRadius = 10,
    defaultTargetMode = "First",
})

TempTowers.Templates.MushroomMortar = table.freeze({
    id = "MushroomMortar",
    name = "MushroomMortar",
    displayName = "Mushroom Mortar",
    description = "Lobs a massive blast across the map.",
    footprintWidth = 12, footprintDepth = 12,   -- huge commitment, especially tight on map 1
    stock = 1,
    maxShots = 20, maxAmmo = 2,
    damage = 40, fireRate = 0.6, range = 90,    -- ~24 DPS × 1 = 24 total
    lobSeconds = 2.0, blastRadius = 12,
    defaultTargetMode = "First",
})

table.freeze(TempTowers.Templates)

-- ===========================================================================
-- HELPERS
-- ===========================================================================

-- Continuous secondary fields that scale with RarityMults.secondary.
-- If a template introduces a new continuous secondary field, add it here.
local SECONDARY_FIELDS = table.freeze({
    "slowPct", "slowSeconds",
    "stunSeconds", "stunCooldown",
    "aoeRadius", "splashRadius", "blastRadius",
    "patchRadius", "patchSeconds", "patchSlowPct", "patchTickDmg",
    "cloudRadius", "cloudSeconds", "cloudTickDmg",
    "chainRange", "chainFalloff",
})

-- Discrete integer fields that use RarityStep (additive bumps).
local DISCRETE_FIELDS = table.freeze({ "pierceCount", "chainJumps" })

-- rollRarity — pick a rarity name using the given weight map.
-- weights: { Common=60, Rare=30, ... }; missing rarities treated as weight 0.
-- Returns "Common" on degenerate input (sum <= 0).
function TempTowers.rollRarity(weights: {[string]: number}): string
    local total = 0
    for _, w in pairs(weights) do total += w end
    if total <= 0 then return "Common" end
    local r = math.random() * total
    local acc = 0
    for _, rarity in ipairs(TempTowers.RarityOrder) do
        acc += (weights[rarity] or 0)
        if r <= acc then return rarity end
    end
    return "Common"
end

-- rollThreeCards — roll 3 distinct (towerId, rarity) cards for a boss picker.
-- Each card's rarity is rolled independently from the boss weights.
-- Tower ids are drawn without replacement so you never see the same tower twice
-- in one picker. If the template pool had <3 entries this would need padding,
-- but we always have 9.
function TempTowers.rollThreeCards(
    weights: {[string]: number}
): { { towerId: string, rarity: string } }
    local ids = {}
    for id in pairs(TempTowers.Templates) do table.insert(ids, id) end
    table.sort(ids)  -- deterministic order before the random pick (repro under fixed seeds)

    local cards = {}
    for _ = 1, 3 do
        if #ids == 0 then break end
        local idx = math.random(1, #ids)
        local towerId = ids[idx]
        table.remove(ids, idx)
        table.insert(cards, {
            towerId = towerId,
            rarity  = TempTowers.rollRarity(weights),
        })
    end
    return cards
end

-- resolveStats — compute effective per-copy stats for (towerId, rarity).
-- Returns a plain (non-frozen) table the caller can further mutate if needed
-- (e.g. to stamp attributes onto a placed Tower Instance).
-- Returns nil if the towerId or rarity is unknown.
function TempTowers.resolveStats(towerId: string, rarity: string): {[string]: any}?
    local tpl = TempTowers.Templates[towerId]
    if not tpl then return nil end
    local mult = TempTowers.RarityMults[rarity]
    if not mult then return nil end

    local stats: {[string]: any} = {}
    for k, v in pairs(tpl) do stats[k] = v end

    -- DPS-contributing fields scale with dps mult.
    if stats.damage   then stats.damage   = stats.damage   * mult.dps end
    if stats.fireRate then stats.fireRate = stats.fireRate * mult.dps end

    -- Continuous secondary mechanics scale with secondary mult.
    for _, field in ipairs(SECONDARY_FIELDS) do
        if stats[field] then
            stats[field] = stats[field] * mult.secondary
        end
    end

    -- Discrete integer fields get additive rarity bumps.
    local step = TempTowers.RarityStep[rarity] or 0
    for _, field in ipairs(DISCRETE_FIELDS) do
        if stats[field] then
            stats[field] = stats[field] + step
        end
    end

    -- Snapshot the rarity onto the stats for downstream consumers
    -- (builder fns, display, save state).
    stats.rarity = rarity
    return stats
end

-- shouldReplaceOnDuplicate — duplicate-roll policy: higher rarity replaces
-- lower; same-or-lower is a no-op (caller should either skip the grant or
-- present it as a dud/reroll).
function TempTowers.shouldReplaceOnDuplicate(currentRarity: string, newRarity: string): boolean
    local cur = TempTowers.RarityRank[currentRarity] or 0
    local new = TempTowers.RarityRank[newRarity] or 0
    return new > cur
end

return table.freeze(TempTowers)
