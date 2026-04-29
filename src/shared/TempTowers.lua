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
--                                                    Story-mode default; per the
--                                                    feedback_default_target_mode
--                                                    memory, every tower ships
--                                                    with "First".
--   infiniteTargetMode (optional)                   — same enum, applied ONLY in
--                                                    Map 4 (Pickle Swamp /
--                                                    Infinite Arena) placements.
--                                                    When the tower's role calls
--                                                    for a different target
--                                                    selection in the auto-place
--                                                    Infinite flow vs the
--                                                    player-driven story flow,
--                                                    set this field. Currently
--                                                    used by BlinkBerry only
--                                                    ("Strongest" — push the
--                                                    dangerous mob, not the
--                                                    weak one). Read by
--                                                    TowerPlacement.lua.
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
    -- stunSeconds 0.5 → 0.6 per Matthew 2026-04-27: RootSprout
    -- F-tier in latest sweep; 20% longer stun extends control
    -- window without changing cooldown cadence.
    stunSeconds = 0.6, stunCooldown = 3.0,
    defaultTargetMode = "First",
})

TempTowers.Templates.FrostMelon = table.freeze({
    id = "FrostMelon",
    name = "FrostMelon",
    displayName = "Frost Melon",
    description = "Chills enemies in a small AOE; stacking slow per shot.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 4,
    maxShots = 40, maxAmmo = 4,
    -- Damage history:
    --   4 → 10 (2026-04-27 stacking-slow rework — Frost needed
    --           more self-DPS since slow synergy is now ramp-gated)
    --   10 → 5 → 6 → 9 → 6 (iteration in 2026-04-27)
    --   6 → 4 (2026-04-27 bq sweep): Frost A-tier 14.64 (+2.24
    --           vs au baseline 12.40). Cut self-DPS -33% — slow
    --           synergy stays the identity, direct contribution
    --           drops so Frost-as-Power-multiplier is more about
    --           the slow than the self-damage. Self-DPS now
    --           4 × 1.5 = 6 (was 9).
    damage = 4, fireRate = 1.5, range = 25,
    -- Frost trim history per Matthew 2026-04-27 (in order):
    --   slowPct: 0.40 → 0.35 → 0.30 → 0.25 → 0.18 → STACKING
    --   slowSeconds: 2.0 → 1.5 → 2.0
    --   slowStackCap: 0.20 → 0.15
    --
    -- 2026-04-27 STACKING REWORK — flat slowPct removed; Frost now
    -- applies +slowStackPct per shot, capped at slowStackCap. Each
    -- hit refreshes the stack timer (slowSeconds). Lapsed stacks
    -- reset to 1 on next hit.
    --
    -- 2026-04-27 cap trim: 0.20 → 0.15 per Matthew "change frostmelon
    -- speed cap to 15%." Power's DPS lift on slowed mobs at the cap
    -- drops from 1.25× (slowStackCap 0.20) to 1.18× (slowStackCap
    -- 0.15). With Frost's self-damage already pulled to 5, the
    -- combined trim should keep Frost+Power off the wave-30 cap
    -- without breaking Frost's role as a sustained-engagement
    -- support tower. Ramp time still ~15 shots × 0.67s = 10s.
    slowStackPct = 0.01, slowStackCap = 0.15, slowSeconds = 2.0, aoeRadius = 6,
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
    -- fireRate 1.6 → 1.3 (2026-04-27 bq sweep, Thorn B-tier 13.81
    -- — option B picked, -19% fire rate). Pierce identity
    -- preserved; tower fires less often. Self-DPS: 5 × 1.3 = 6.5
    -- (was 8). Pierce still hits 2+1 mobs per shot.
    damage = 5, fireRate = 1.3, range = 30,     -- ~6.5 DPS × 3 = 19.5 total (with pierce)
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
    -- Damage 2 → 10 (2026-04-27) — Matthew "give honey hive 10
    -- damage." 5× damage bump pulls Honey's self-DPS up to ~8 so
    -- it has a credible direct contribution while the patch slow
    -- still does the crowd-control work.
    --
    -- fireRate 0.8 → 1.0 → 1.1 (2026-04-27): bumped twice. First
    -- buff was sustained-DPS; second buff (+10%) on top per
    -- Matthew "fire rate 1.1" — 11 self-DPS now, plus more
    -- patches dropped per second for path coverage.
    damage = 10, fireRate = 1.1, range = 20,
    -- patchSlowPct history: 0.40 → 0.55 → 0.60.
    -- patchRadius history: 8 → 10 → 11 → 7 (dq, -36% area).
    -- patchTickDmg history: 4 → 6 → 8 (dq, +33%).
    --
    -- 2026-04-28 dq: per Matthew "decrease radius of honeyhive
    -- splash by 33% and increase damage tick by 2." Shifts Honey
    -- from cluster-AOE flavor toward single-target focus:
    --   • Patch radius 11 → 7 (-36% radius, -57% area). Catches
    --     fewer mobs per drop; the patch is now "lay a tile in
    --     the path" not "blanket the lane."
    --   • Patch tick dmg 6 → 8 (+33%). Stationary boss in patch
    --     now eats 16 DPS (8 × 2/sec) for the 4s lifetime = 64
    --     damage per patch, was 48. More boss-wave punch.
    patchRadius = 7, patchSeconds = 4.0, patchSlowPct = 0.60, patchTickDmg = 8, patchTickPerSec = 2,
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
    -- Range reverted to 70 baseline; fireRate cut 0.4 → 0.32
    -- (-20%) per Matthew 2026-04-27: "increase sniper range back
    -- to 70 baseline and decrease firing rate by 20%." Net DPS
    -- effect: 30 × 0.32 = 9.6 DPS per copy (was 12). The range
    -- is restored so AcornSniper keeps its long-reach identity;
    -- the cadence cut is the actual nerf lever now.
    --
    -- Damage history: 30 → 29 (early trim) → 24 (2026-04-27 bq
    -- sweep, Acorn C-tier 13.65 — option A, -17% direct damage).
    -- Identity intact: heavy single-hit at long range, just less
    -- heavy. DPS 29×0.32 = 9.28 → 24×0.32 = 7.68.
    damage = 24, fireRate = 0.32, range = 70,   -- ~7.68 DPS × 2 = 15.36 total
    -- All towers default to "First" per Matthew's rule. (Was Strongest.)
    defaultTargetMode = "First",
})

-- InfiniteStandard — functional copy of AcornSniper used as the
-- AUTO RUN trio anchor (was AcornSniper itself). Per Matthew
-- 2026-04-27: "create a tower that's a copy of the acornsniper
-- and call it infinitestandard, and use that for the trio
-- baseline. otherwise acorntower is overrepresented in other
-- towers." With AcornSniper as the anchor, AcornSniper appeared
-- in all 28 trios + 1 solo + 8 pairs = 37 runs, vs 16 for every
-- other tower. Now AcornSniper is just a regular test tower (1
-- solo + 8 duos + 8 trios = 17 runs, same as every other tower)
-- and InfiniteStandard takes the anchor slot — its trio
-- appearances are excluded from the tier list since it's a
-- standardization tool, not a tested loadout.
--
-- Hidden from the loadout picker (auto_run_only flag) so players
-- never see it in the manual-pick UI; only AUTO RUN spawns it.
TempTowers.Templates.InfiniteStandard = table.freeze({
    id = "InfiniteStandard",
    name = "InfiniteStandard",
    displayName = "Infinite Standard",
    description = "AUTO RUN trio standardization anchor (functional clone of AcornSniper).",
    footprintWidth = 4, footprintDepth = 4,
    stock = 2,
    maxShots = 20, maxAmmo = 2,
    -- Damage 30 → 32 (+2) per Matthew 2026-04-27 to keep the
    -- standardization anchor's contribution stable as test-pool
    -- towers iterate. Range and fireRate stay aligned with
    -- AcornSniper baseline.
    damage = 32, fireRate = 0.32, range = 70,
    defaultTargetMode = "First",
    auto_run_only = true,  -- hide from manual loadout picker
    infiniteOnly = true,   -- hide from story-mode boss reward picker
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
    -- chainFalloff 0.60 → 0.45 (2026-04-27 bq sweep, Lightning
    -- B-tier 14.05 — option B picked to trim chain-AOE value
    -- without touching primary-target DPS). Hop1 damage 60% → 45%
    -- of primary; hop2 damage 36% → 20% of primary. Chain identity
    -- intact; AOE-wave multi-mob value cut ~30%.
    chainJumps = 2, chainFalloff = 0.45, chainRange = 14,
    -- All towers default to "First" per Matthew's rule. (Was Center —
    -- player can still flip to Center via target-mode HUD if they want
    -- the cluster-killer behavior.)
    defaultTargetMode = "First",
})

TempTowers.Templates.SporePuffball = table.freeze({
    id = "SporePuffball",
    name = "SporePuffball",
    displayName = "Spore Puffball",
    description = "Impact releases a lingering poison cloud.",
    footprintWidth = 6, footprintDepth = 6,
    stock = 2,
    maxShots = 30, maxAmmo = 3,
    -- Damage 3 → 8 (2026-04-27 — "sporepuffball needs tuned up
    -- and moved to dps towers"). Spore consistently bottom-of-
    -- table at 9.5 ranges across Power and ControlCore sweeps
    -- because the cloud's spot-drop nature meant most clouds
    -- never reached mobs. Bumping direct-hit damage 3 → 8 gives
    -- Spore a credible self-DPS (8 × 1.2 = 9.6) while the cloud
    -- mechanic stays as a bonus rather than the primary lever.
    -- Role moved Control → DPS in RoleByTowerId below — Spore is
    -- now a DOT-flavored DPS tower, not a Control tower.
    damage = 8, fireRate = 1.2, range = 25,
    -- cloudTickDmg history: 3 → 4 → 6 → 5 (2026-04-27 paired with
    -- the new overlap-heat mechanic — base trim ensures Spore solo
    -- stays at ~12.5 while overlap density is the new lift lever).
    -- cloudRadius 8 → 7 (2026-04-27): smaller per-cloud area.
    -- Combined with heat overlap, encourages tight cloud clusters
    -- for max damage (smaller radius = harder to cover wide path
    -- with one cloud, easier to overlap multiple).
    cloudRadius = 7, cloudSeconds = 3.0, cloudTickDmg = 5, cloudTickPerSec = 4,
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
    -- Damage 25 → 23 (2026-04-27): raw-damage lever trim.
    damage = 23, fireRate = 0.9, range = 32,
    -- splashRadius history: 8 → 10 → 9 → 7 (2026-04-27 bq sweep
    -- showed Pepper still S-tier 14.71 — area-cut option B picked
    -- to nerf AOE-wave multi-mob hits without touching damage or
    -- fireRate). 9 → 7 = -40% area (49π → 49π × 49/81 = 60% of
    -- prior). Splash identity preserved; AOE-wave value trimmed.
    splashRadius = 7,
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
    -- Damage history per Matthew 2026-04-27 (in order):
    --   40 → 55 (+38%): "buff Mushroom to lift it off the floor"
    --   55 → 65 (+18%): first buff was canceled by the lob-floor
    --     trim 0.5 → 0.3 landing in the same window; net real-game
    --     change was +0.23 waves (10.72 → 10.95 — still F-tier).
    --     Stacking another +10 dmg + bumping lob floor 0.3 → 0.4
    --     (sim) finally gives Mushroom enough lift to compete.
    -- DPS at 65 × 0.6 = 39 base. Solo lob mult ~0.735 → 28.7
    -- effective. AOE lob mult 0.5 × aoeMult 3.0 = 1.5 effective
    -- per shot → 58.5 effective on AOE waves.
    --
    -- 65 → 55 (2026-04-27 bq sweep, Mushroom B-tier 14.04 —
    -- option A picked, -15% per-shell damage). Splash identity
    -- preserved; just smaller boom. Solo effective DPS: 28.7 →
    -- 24.3; AOE effective: 58.5 → 49.5.
    --
    -- 55 → 48 (2026-04-28 cross-Core sweep): Mushroom S-tier on
    -- ALL three Cores (PowerCore 13.24 / SupportCore 14.47 /
    -- ControlCore 14.01) by 2-3 waves over the next aux. -13%
    -- damage pulls AOE-wave effective DPS from ~50 to ~43,
    -- targeting the B-tier cluster (Spore 11.7 / Pepper 10.7).
    -- Splash radius 15 + lob mechanic unchanged so the
    -- "decisive boom" identity stays.
    damage = 48, fireRate = 0.5, range = 90,
    -- Lob time 2.0 → 1.67 (= 2 / 1.2) per Matthew 2026-04-26:
    -- "increase mushroom mortar projectile speed by 20%". Same
    -- blast radius — just the projectile arrives 20%
    -- sooner so the splash hits less of a moving target offset.
    --
    -- blastRadius 12 → 15 (2026-04-27): Mushroom was D-tier real
    -- (lots of lob misses). Bigger splash compensated for lob
    -- inaccuracy — more cluster catches when target moved out of
    -- original splash zone.
    --
    -- 15 → 12 (2026-04-28 cross-Core sweep validation): the -7
    -- damage trim alone left Mushroom S-tier on every Core
    -- (PowerCore 13.24 → 13.71, ControlCore 14.01 → 12.47). The
    -- damage lever was wrong — the mechanic-level lever is splash
    -- AREA, not per-shell damage. -36% area (49π → 36π = 73%
    -- of prior coverage) directly throttles cluster-catch on
    -- AOE/Combined waves. Identity ("decisive lob across the
    -- map") preserved; the boom is just a bit smaller.
    --
    -- 12 → 11 + lobSeconds 1.67 → 2.0 (2026-04-28 hybrid nerf
    -- after partial 15-run cu sweep showed Mushroom STILL S
    -- (15.80 PowerCore solo, ~1 wave above next-best). Two-axis
    -- trim:
    --   • blastRadius 12 → 11 (-16% area: 144π → 121π)
    --   • lobSeconds  1.67 → 2.0 (+20% flight time)
    -- Reverts the 2026-04-26 "+20% projectile speed" buff on the
    -- lob axis. Slower projectile = moving clusters outpace it
    -- = more whiff on AOE/Combined waves. Damage + range + cadence
    -- all unchanged so the per-shell punch identity is preserved
    -- across both nerf passes.
    --
    -- fireRate 0.6 → 0.5 (2026-04-28 db, paired with Towers.lua
    -- inverted-homing taper H2). Cadence trim -17% per-second
    -- damage on top of the homing nerf. The homing change makes
    -- Mushroom MISS more on corners + when paired with knockback/
    -- blink towers; the fireRate cut narrows raw output before
    -- accuracy effects so the two levers compose. Re-test target
    -- after this pass: Mushroom drops from S → A on PowerCore
    -- solo, opens up genuine map-weakness contracts (corners hurt
    -- it, stun/slow combos help it).
    --
    -- 2026-04-28 di — 7th nerf pass. df sweep showed Mushroom STILL
    -- S-tier at 12.26 (cx 12.65 → df 12.26 = -0.39 wave, insufficient).
    -- Two-axis trim doubling down on the H2 homing strategy:
    --   • lobSeconds  2.0 → 2.2 (+10% flight time on top of the
    --     prior 1.67 → 2.0 bump). Slower projectile = more whiff
    --     on moving Combined-wave clusters since H2 homing only
    --     kicks in late, AND the late-phase target has more time
    --     to be moved by stun/slow/kb.
    --   • blastRadius 11 → 10 (-17% area: 121π → 100π). Continued
    --     mechanic-area trim — splash catches less of any cluster
    --     that wasn't perfectly centered.
    -- Damage + range + cadence unchanged. Identity (decisive lob
    -- across the map) preserved; just less reach + slower travel.
    -- Paired with LobCatchBaseMult 0.3 → 0.5 sim recalibration
    -- (Config.SimCalibration) since the prior 0.3 was tuned to
    -- real ~9.0 — current real ~12.26 means sim under-predicts by
    -- 4.5 wave, the largest residual in the validator report.
    lobSeconds = 2.2, blastRadius = 10,
    defaultTargetMode = "First",
})

-- ===========================================================================
-- 2026-04-28 — five new towers per Matthew. Per project_tower_role_philosophy
-- memory: Control = controls movement/environment; Support = amplifies damage.
-- ===========================================================================

-- BlinkBerry — Control. Periodic AOE teleport: every blinkInterval
-- seconds, every mob in range gets pushed `blinkDistance` studs
-- BACKWARDS along the waypoint path. Floor at the spawn waypoint
-- — no further-back than where the wave originated. Mechanic
-- read in Towers.lua updateTowers loop (per-tower last-blink
-- timer + waypoint-walk-back).
--
-- 2026-04-28 HARD NERF (post first-sweep infinite-loop abort).
-- First sweep at stock=2, range=25, blinkInterval=5, blinkDistance=20
-- hung at run 3/105 because mobs got blinked back, walked forward,
-- got blinked back, repeat — wave never ended. Stat tightening:
--     range:         25 → 15  (-40% AOE radius)
--     blinkInterval:  5 → 8   (mob walks past in one blink interval)
--     blinkDistance: 20 → 8   (-60% setback per blink)
-- An earlier per-mob MAX_BLINKS_PER_MOB cap was tried + reverted
-- per Matthew 2026-04-28 ("take off max blinks per mob for
-- blinkberry"). Loop prevention now relies entirely on the stat
-- tuning above: at speed 8 studs/s + interval 8s, mobs cover 64
-- studs between blinks but only get pushed 8 studs back, so
-- forward progress is guaranteed.
TempTowers.Templates.BlinkBerry = table.freeze({
    id = "BlinkBerry",
    name = "BlinkBerry",
    displayName = "Blink Berry",
    description = "Every 8s, teleports nearby mobs 8 studs back on the path. Also fires light shots between blinks.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 2,
    maxShots = 999, maxAmmo = 1,
    -- 2026-04-28: BlinkBerry now fires shots between blinks per
    -- Matthew "give blink berry a fire rate". 4 dmg × 1.0 /sec =
    -- 4 self-DPS. Combined with the blink mechanic this gives the
    -- tower a credible direct-damage floor on AOE/wave-clear waves
    -- where blinks are wasted on the mob being kited anyway.
    --
    -- 2026-04-28 dn — multi-axis tune-up. dl ControlCore sweep had
    -- BlinkBerry F-tier at 9.40 wave, ~1 wave behind RootSprout.
    -- Per Matthew "tune blinkberry up" with custom Option C mix:
    --   • damage 4 → 5 (+25%)
    --   • fireRate 1.0 → 1.1 (+10%)
    --   • range 15 → 18 (+20%, matches other Control towers)
    --   • blinkInterval 8.0s → 7.0s (-12.5%, more frequent blinks)
    --   • blinkDistance 8 → 10 (+25%, bigger setback)
    -- Self-DPS 4 → 5.5 (+38%). Blink mechanic ~25% stronger.
    -- Loop math: mobSpeed 8 × interval 7 = 56 studs covered between
    -- blinks; setback 10 → 46 stud net forward progress per cycle.
    -- Still safely above the loop boundary (any positive net
    -- prevents the infinite-blink bug fixed in 2026-04-28 cs).
    damage = 5, fireRate = 1.1,
    range = 18,                       -- AOE pickup radius + fire range
    -- Blink mechanic params (read by Towers.lua per-tower blink loop):
    --   blinkInterval = seconds between blinks (game-time)
    --   blinkDistance = studs to push mobs backwards on path
    blinkInterval = 7.0,              -- 5.0 → 8.0 → 7.0 (dn lift)
    -- 2026-04-28 dp: 10 → 14 per Matthew "increase blinkberry
    -- teleport distance." +40% setback, still loop-safe (mob
    -- speed 8 × interval 7 = 56 covered, setback 14 → 42 net
    -- forward per cycle; Frost-stacked slow 0.85× → 33 net,
    -- still positive). Buffs the Control mechanic without
    -- approaching the infinite-blink boundary.
    blinkDistance = 14,               -- 20 → 8 → 10 → 14
    defaultTargetMode = "First",
    -- 2026-04-28 do: Infinite-arena target preference per Matthew
    -- "in infinite, automatically set blinkberry to target
    -- strongest. remember which towers have aiming preference."
    -- BlinkBerry's blink push wastes on weak mobs but huge value
    -- on tanks/bosses (push back the dangerous one) — Strongest
    -- maps to that intent. Map 4 placement reads this field;
    -- story-mode placement still uses defaultTargetMode = First
    -- per the established convention (feedback_default_target_mode
    -- memory). Other towers can opt in by adding this field.
    infiniteTargetMode = "Strongest",
})

-- ─── 2026-04-28 SUPPORT BUFF TOWERS — STRUCTURAL CHANGE ───
-- Cross-Core sweep validation (3 sweeps × ~117 runs each)
-- showed the 4 buff towers' wave outcomes cluster within
-- 0.15-0.32 waves of each other regardless of Core archetype.
-- Bumping aura % from 25 → 30 (post-cm) didn't break the cluster
-- because Power Core already does the bulk of the damage and a
-- 30% buff vs 25% buff is invisible against per-wave HP scaling.
--
-- Fix is STRUCTURAL: give each buff tower its own small self-DPS
-- so they physically do different things, not just slap a
-- different buff on the Core. Same total ~3 self-DPS across the
-- three towers but with distinct cadence flavors that match the
-- tower's identity:
--   PaceFlower: damage 2 / fireRate 1.5 → 3 DPS, FAST cadence
--   PowerSeed:  damage 3 / fireRate 1.0 → 3 DPS, NEUTRAL cadence
--   SpyglassRoot: damage 4 / fireRate 0.7 → 2.8 DPS, LONG range
-- All gain a `range` value (was 0; non-firing) so they engage
-- path mobs. SpyglassRoot's native range matches its theme since
-- towers don't apply their own aura to themselves.
-- ───────────────────────────────────────────────────────────

-- PaceFlower — Support. Fast-cadence + fire-rate aura.
TempTowers.Templates.PaceFlower = table.freeze({
    id = "PaceFlower",
    name = "PaceFlower",
    displayName = "Pace Flower",
    description = "Fast light shots. Aura: nearby towers fire faster.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 2,
    maxShots = 999, maxAmmo = 1,
    -- 2026-04-28 self-DPS: 2 dmg × 1.5 fr = 3 effective DPS,
    -- FAST cadence flavor.
    -- 2026-04-28 di: damage 2 → 3 per Matthew "give paceflower a
    -- little more tower damage." Self-DPS now 3 × 1.5 = 4.5
    -- effective. Pace was C-tier 10.54 in df sweep (Power/Spy were
    -- 11.42/10.76); the bump nudges it toward parity with the rest
    -- of the Support category. FAST cadence identity preserved
    -- (still 1.5/sec), just hits harder per tick.
    damage = 3, fireRate = 1.5,
    range = 18,
    -- Aura: same fields the SupportCore aura prepass reads.
    auraRadius = 18,                  -- 16 → 18 per 2026-04-28
    -- 2026-04-28 di: 30 → 40 per Matthew "bump pace flower aura."
    -- The damage 2→3 self-DPS bump (earlier this build) lifted Pace
    -- only +0.56 wave in the di sweep — not enough to escape C-tier
    -- (Pace 11.10 vs Spy 11.74, PowerSeed 11.94, Vine 12.23). The
    -- aura bonus axis compounds with the anchor's DPS, so a +33%
    -- aura lift (30 → 40) is higher leverage than another flat self-
    -- DPS bump. Intent: Pace+anchor combos pull within ±0.3 wave of
    -- the other Support buff towers.
    auraFireRateBonusPct = 40,        -- 25 → 30 → 40
    auraDamageBonusPct = 0,
    auraRangeBonusPct = 0,
    defaultTargetMode = "First",
})

-- PowerSeed — Support. Neutral-cadence + damage aura.
TempTowers.Templates.PowerSeed = table.freeze({
    id = "PowerSeed",
    name = "PowerSeed",
    displayName = "Power Seed",
    description = "Neutral-cadence shots. Aura: nearby towers do more damage.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 2,
    maxShots = 999, maxAmmo = 1,
    -- 2026-04-28 self-DPS: 3 dmg × 1.0 fr = 3 effective DPS,
    -- NEUTRAL cadence flavor.
    damage = 3, fireRate = 1.0,
    range = 18,
    auraRadius = 18,
    auraFireRateBonusPct = 0,
    auraDamageBonusPct = 30,
    auraRangeBonusPct = 0,
    defaultTargetMode = "First",
})

-- SpyglassRoot — Support. Slow-cadence heavy + range aura.
-- The aura prepass in Towers.lua reads auraRangeBonusPct and
-- multiplies effective range by (1 + bonusPct/100) for nearby
-- towers (NOT applied to itself; SpyglassRoot's own native range
-- is set wider here to match its theme).
TempTowers.Templates.SpyglassRoot = table.freeze({
    id = "SpyglassRoot",
    name = "SpyglassRoot",
    displayName = "Spyglass Root",
    description = "Long-range heavy shots. Aura: nearby towers see further.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 2,
    maxShots = 999, maxAmmo = 1,
    -- 2026-04-28 self-DPS: 4 dmg × 0.7 fr = 2.8 effective DPS,
    -- LONG range cadence flavor (heavy + slow).
    damage = 4, fireRate = 0.7,
    range = 26,                       -- native long range, matches "spyglass" theme
    auraRadius = 18,
    auraFireRateBonusPct = 0,
    auraDamageBonusPct = 0,
    auraRangeBonusPct = 30,
    defaultTargetMode = "First",
})

-- BloodlinkVine — Support. Mob-link mechanic: any mob within
-- `linkRadius` is treated as part of a damage-shared cluster.
-- When ctx.damageMob lands on a linked mob, the link broadcast
-- helper deals the same damage to every OTHER linked mob in the
-- same cluster. Recursion-guarded so echoes don't multiply.
--
-- 2026-04-28 dc — linkRadius 18 → 24 (+33% radius, +78% area).
-- Picks up roughly one extra mob along path-aligned waves where
-- mobs are spaced by spawnStaggerSec × moveSpeed. Paired with
-- the new mob-to-vine purple chain VFX so the link is visible
-- in-game (each linked mob shows a glowing tether back to the
-- vine stem; visualizes both range AND cluster size at a glance).
TempTowers.Templates.BloodlinkVine = table.freeze({
    id = "BloodlinkVine",
    name = "BloodlinkVine",
    displayName = "Bloodlink Vine",
    description = "Aura: damage to any linked mob mirrors to all linked mobs.",
    footprintWidth = 4, footprintDepth = 4,
    stock = 1,                        -- 1 per run — strong unique mechanic
    maxShots = 999, maxAmmo = 1,
    -- 2026-04-28 df — Vine gets self-DPS (was damage=0, fireRate=0,
    -- range=0). Per Matthew "give bloodlinkvine some tower damage.
    -- make sure all towers have some damage." Vine was the only
    -- aux template with damage=0; every other tower fires at least
    -- a little. Self-DPS = 3.0 (3 dmg × 1.0 fr) — same total as
    -- PowerSeed but distinct mechanics: PowerSeed amplifies others'
    -- damage, Vine echoes any damage to linked mobs. Range=24
    -- matches the linkRadius so visual range circle + link
    -- territory match. Tower will target the strongest in-range mob
    -- (defaultTargetMode = "First") and the bonus is its hits also
    -- echo via the link mechanic to every other clustered mob.
    damage = 3, fireRate = 1.0,
    range = 24,
    linkRadius = 24,                  -- mobs within radius are linked (18 → 24, +1 mob nominal)
    linkEchoFrac = 0.5,               -- echoed damage is 50% of original
    defaultTargetMode = "First",
})

table.freeze(TempTowers.Templates)

-- Role classification — one of "DPS" / "Control" / "Support" (per
-- project_tower_categories.md, 2026-04-27 revision; updated
-- 2026-04-28 with new philosophy in
-- project_tower_role_philosophy.md). Drives the Infinite Studio
-- tier list (per-role) and the Map 4 auto-place pattern
-- (per-role cell allocation). Rules:
--   controls movement/environment    → Control (slow, stun,
--                                       blink, knockback, terrain)
--   amplifies damage of OTHER towers → Support (auras, mob-link)
--   pure damage (incl. AOE / DOT)    → DPS
TempTowers.Roles = table.freeze({
    DPS = "DPS",
    Control = "Control",
    Support = "Support",
})
TempTowers.RoleByTowerId = table.freeze({
    RootSprout       = "Control",  -- stunSeconds
    FrostMelon       = "Control",  -- slowPct
    ThornVine        = "DPS",      -- pierce, pure damage
    HoneyHive        = "Control",  -- patch slow + tick
    AcornSniper      = "DPS",      -- single heavy hit
    LightningRadish  = "DPS",      -- chain damage
    -- 2026-04-27: Spore moved Control → DPS per Matthew
    -- "moved to dps towers." Cloud DOT mechanic stays but
    -- the +damage buff (3 → 8) makes Spore a DPS tower with
    -- a lingering-AOE flavor, not a Control tower.
    SporePuffball    = "DPS",      -- direct hit + lingering cloud DOT
    PepperCannon     = "DPS",      -- splash damage
    MushroomMortar   = "DPS",      -- lob splash
    InfiniteStandard = "DPS",      -- AUTO RUN trio anchor (clone of AcornSniper)
    -- 2026-04-28: 5 new towers per Matthew + tower role
    -- philosophy. Control = movement/environment, Support =
    -- damage amplification.
    BlinkBerry       = "Control",  -- blink-teleport mobs back on path
    PaceFlower       = "Support",  -- aura: +fire rate
    PowerSeed        = "Support",  -- aura: +damage
    SpyglassRoot     = "Support",  -- aura: +range
    BloodlinkVine    = "Support",  -- aura: mob-link damage echo
    -- The 3 Core archetypes. Mirrors shared/CoreTypes.Role exactly —
    -- duplication is intentional so tier-list code that ALREADY iterates
    -- this single table doesn't need a second module require. Any
    -- update here MUST also update CoreTypes.Role (see comment in
    -- CoreTypes.lua about the duplication contract).
    --
    -- 2026-04-29 ea3: ControlCore + SupportCore added per audit —
    -- before this entry, `roleFor("ControlCore")` in
    -- InfiniteSimulator fell through to "DPS", which mis-placed
    -- Control/Support cores in the path-slot assignment used by
    -- the closed-form sweep (Control was getting the DPS slot
    -- instead of the Control slot). Live-game placement was fine
    -- because that flow stamps role from the template, not this
    -- table; this entry only matters for the simulator + any
    -- future tier-list-by-role consumer.
    Power            = "DPS",
    ControlCore      = "Control",
    SupportCore      = "Support",
})

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
-- Tower ids are drawn without replacement so you never see the same tower
-- twice in one picker.
--
-- excludeIds (optional): set of {[towerId] = true} the player ALREADY OWNS.
-- When supplied, the roll prefers UN-owned types — if at least 3 un-owned
-- types exist, all 3 cards come from the un-owned pool, so the player walks
-- away with a NEW aux instead of an upgrade-or-dud. If fewer than 3 un-owned
-- types remain, fills the rest from the full pool (excluded IDs back in)
-- so the picker is never under-stocked. With 9 total templates and
-- typically 0-2 owned, this almost always offers 3 fresh types.
-- Fixes the "I dev-ported to map 3, got bird-boss reward, but ended up
-- with only 2 distinct aux" case (2026-04-26 playtest).
function TempTowers.rollThreeCards(
    weights: {[string]: number},
    excludeIds: {[string]: boolean}?
): { { towerId: string, rarity: string } }
    local allIds = {}
    for id, tpl in pairs(TempTowers.Templates) do
        -- 2026-04-28 dt: skip Infinite-only templates (InfiniteStandard
        -- exists as the AUTO RUN trio anchor — a clone of AcornSniper
        -- — not a player-pickable reward). Per Matthew "take infinite
        -- standard out of story mode."
        if not tpl.infiniteOnly then
            table.insert(allIds, id)
        end
    end
    table.sort(allIds)  -- deterministic order before the random pick (repro under fixed seeds)

    local primaryIds = {}
    if excludeIds then
        for _, id in ipairs(allIds) do
            if not excludeIds[id] then
                table.insert(primaryIds, id)
            end
        end
    else
        for _, id in ipairs(allIds) do table.insert(primaryIds, id) end
    end

    local cards = {}
    -- First pass: roll from un-owned types.
    while #cards < 3 and #primaryIds > 0 do
        local idx = math.random(1, #primaryIds)
        local towerId = primaryIds[idx]
        table.remove(primaryIds, idx)
        table.insert(cards, {
            towerId = towerId,
            rarity  = TempTowers.rollRarity(weights),
        })
    end
    -- Second pass: if still short (player owns 7+ of the 9 types),
    -- backfill from the previously-excluded pool. Each picked card
    -- here will likely flag dud=true downstream, but the picker
    -- needs 3 cards to render correctly.
    if #cards < 3 and excludeIds then
        local fallbackIds = {}
        local pickedSet = {}
        for _, c in ipairs(cards) do pickedSet[c.towerId] = true end
        for _, id in ipairs(allIds) do
            if not pickedSet[id] then
                table.insert(fallbackIds, id)
            end
        end
        while #cards < 3 and #fallbackIds > 0 do
            local idx = math.random(1, #fallbackIds)
            local towerId = fallbackIds[idx]
            table.remove(fallbackIds, idx)
            table.insert(cards, {
                towerId = towerId,
                rarity  = TempTowers.rollRarity(weights),
            })
        end
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

    local stats: {[string]: any} = table.clone(tpl)

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
