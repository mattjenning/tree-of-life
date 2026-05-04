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
    --
    -- 2026-04-29 ea3-19 — stunSeconds 0.6 → 0.8 per Matthew "a".
    -- ea3-3 SUPER AUTO showed Root at 11.29 (-0.37 below slate,
    -- C-tier). +33% on the mechanic lever (stun duration) reinforces
    -- the stunner identity; uptime on stunned target rises 20% →
    -- 27%. Hits Boss waves hardest (single tank held longer = direct
    -- DPS amplifies). cooldown unchanged (3.0s) so stun cadence
    -- stays the same — just longer per stun. Predicted: 11.29 →
    -- ~11.7 (B-tier).
    -- 2026-05-03 ea3-229: stunCooldown 3.0 → 2.5 (-17%). SUPER
    -- FAILURE CURVE Phase A showed Root at D consistently (9.56 P /
    -- 9.02 C / 8.94 S). +20% stun frequency without touching damage
    -- or duration — pure mechanic lever. Stun uptime (per-target)
    -- rises 0.8/3.0 = 27% → 0.8/2.5 = 32%. Identity preserved.
    stunSeconds = 0.8, stunCooldown = 2.5,
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
    --   4 → 5 (2026-05-02 ea3-225) — D-tier buff. Power Core CURVE
    --           × 105 showed Frost at real 9.71 (D-tier). Self-DPS
    --           6 → 7.5 (+25%). Slow-stack identity preserved (cap
    --           still 0.15, ramp still 0.02/shot); the buff lands
    --           on direct contribution where Frost was thinnest.
    damage = 5, fireRate = 1.5, range = 25,
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
    -- ea3-106: slowSeconds 2.0 → 2.1 (+5%) per ea3-105 sim tier list:
    -- FrostMelon C-tier (10.03), 1.5 waves below A-tier HoneyHive (11.52).
    -- Smallest possible meaningful buff — extends slow-stack persistence
    -- so Power-DPS-on-slowed-mob synergy windows are slightly longer.
    -- Doesn't touch slowStackPct/Cap (the identity knobs); doesn't shift
    -- self-DPS. Target: lift FrostMelon from C → low-B without crowding
    -- HoneyHive's A. Revert is one digit if overshoot.
    --
    -- ea3-181: Frost dropped to F-tier (8.41 over 40 runs) on the
    -- balance v6 sweep — slow-stack mechanic isn't pulling weight.
    -- slowStackPct 0.01 → 0.02 (ramp 2× faster to cap). At fireRate
    -- 1.5 the cap is now reached in ~7-8 shots (~5s) instead of
    -- ~15 shots (~10s), so Power-on-slowed synergy windows open
    -- earlier in each engagement. Cap unchanged at 15% (identity
    -- preserved — Frost still asymptotes to 1.18× DPS multiplier).
    slowStackPct = 0.02, slowStackCap = 0.15, slowSeconds = 2.1, aoeRadius = 6,
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
    --
    -- 2026-04-29 ea3-14 — light cadence trim per Matthew. ea3-3
    -- SUPER AUTO showed Thorn at 12.15 (+0.49 above slate, A-tier,
    -- 285 runs). Indirect drops from Mortar/Spore/Radish nerfs were
    -- expected to pull Thorn ~0.2 wave on their own; user opted
    -- for an additional small direct nerf rather than wait for
    -- the next sweep. fireRate 1.3 → 1.2 (-7.7%): self-DPS 6.5 →
    -- 6.0 per pierce target; total DPS 19.5 → 18 (-7.7%).
    -- Predicted shift after combined indirect+direct: 12.15 →
    -- ~11.65, right at slate.
    --
    -- 2026-05-02 ea3-225 — F-tier buff. Power Core CURVE × 105
    -- (n=105, balance v21) showed Thorn dropped to F-tier (real
    -- avg 9.52, sim 9.93). damage 5 → 7 (+40%): self-DPS 6.0 → 8.4
    -- per pierce target; total DPS 18 → 25.2 (3 mobs hit per shot
    -- via pierceCount=2). Bigger bump than typical because (a)
    -- pierce multiplies the buff naturally, (b) Thorn was bottom-
    -- of-table and needs to climb to at least C/B-tier to be
    -- worth picking. Pierce identity (hits 2+1 mobs) unchanged.
    -- 2026-05-03 ea3-229 — second F-tier rescue. SUPER FAILURE
    -- CURVE Phase A (n=105 each Core) showed Thorn STILL F (9.41
    -- Power, 9.19 Control, 9.04 Support). The +40% damage barely
    -- moved real-game lift (~0.1 wave). damage 7 → 9 (+29%): self-
    -- DPS 8.4 → 10.8, total DPS 25.2 → 32.4 (× pierce=2 + 1 mob
    -- behind). Pierce identity preserved.
    damage = 9, fireRate = 1.2, range = 30,     -- ~10.8 DPS × 3 = 32.4 total (with pierce)
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
    -- 2026-05-03 ea3-229: damage 10 → 14 (+40%) per F-tier rescue
    -- (see patchTickDmg comment block below). Self-DPS 11 → 15.4.
    -- 2026-05-03 ea3-233: damage 14 → 18 (+29%). SUPER FAILURE
    -- CURVE × 495 showed Honey still D/F across all Cores (9.62 P /
    -- 9.25 C / 9.08 S) — the +40% from ea3-229 only lifted real
    -- ~0.10-0.24. The patch mechanic isn't the bottleneck; direct
    -- DPS is. Self-DPS 15.4 → 19.8 (matches PepperCannon's pre-nerf
    -- direct DPS to give Honey a real "carry" punch).
    -- 2026-05-03 ea3-234: range 20 → 30 (+50%). Two damage buffs
    -- (10→14→18, +80% across passes) only lifted Honey ~+0.3 wave —
    -- the bottleneck isn't damage per tick, it's engagement TIME.
    -- Honey at range 20 was the SHORTEST non-melee-control tower in
    -- the roster (Pace 28, Thorn 30, Pepper 32, Spy 32) and sat
    -- idle for the parts of waves where lead-mob position was
    -- outside its targeting bubble. Range 30 (matches ThornVine)
    -- gives Honey ~50% more wall-clock time firing per wave + more
    -- patch-position diversity (lead-mob target shifts across more
    -- of the path → patches stop stacking on one chokepoint).
    -- Damage knobs are now untouchable until we see what range
    -- alone does.
    damage = 18, fireRate = 1.1, range = 30,
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
    --
    -- 2026-04-29 ea3-21 — combined buff per Matthew "d". ea3-3
    -- SUPER AUTO showed Honey at 11.47 (-0.19 below slate); after
    -- indirect drops from the 5 nerfs, real gap widens to ~-0.5.
    --   • patchTickDmg 8 → 10 (+25%): patch DPS 16 → 20
    --   • patchSeconds 4.0 → 5.0 (+25%): patch lifetime extended
    -- Per-patch total damage 64 → 100 (+56%). Continues dq's
    -- single-target focus axis without touching radius (still 7)
    -- or slow (still 0.60). Boss-wave value lifted significantly;
    -- AOE-wave value lifted moderately (more overlap windows).
    -- Predicted: ~10.97 (post-indirect) → ~11.5 (B-tier in line
    -- with BloodlinkVine post-buff).
    -- ea3-181: patchTickDmg 10 → 14 (+40%). Per-patch total damage
    -- 100 → 140 (14 × 2/s × 5s). HoneyHive sat at REAL avg 8.74 on
    -- the balance v6 sweep (Power core, 14 runs) vs sim's 10.75 —
    -- bumping the per-tick DOT lifts boss-wave value materially
    -- without touching patch radius (still 7, single-target focus
    -- preserved) or slow (still 0.60, control identity preserved).
    patchRadius = 7, patchSeconds = 5.0, patchSlowPct = 0.60, patchTickDmg = 14, patchTickPerSec = 2,
    -- 2026-05-03 ea3-229 — F-tier rescue. SUPER FAILURE CURVE Phase A
    -- (n=105 per Core, balance v21) showed Honey at REAL 9.43 (P) /
    -- 9.01 (C) / 8.91 (S) — F-tier on Control + Support. The patch
    -- mechanic isn't reaching enough mobs in the failure-curve waves
    -- (mobs walk past the spot drop instead of clustering). Direct-
    -- DPS lever to lift floor: damage 10 → 14 (+40%). Self-DPS rises
    -- from 11 to 15.4. Patch identity (slow + DOT zone) preserved.
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
    -- 2026-05-03 ea3-233: 24 → 21 (-15%, ceil rounded). SUPER
    -- FAILURE CURVE × 495 carry-compression. Self-DPS 7.68 → 6.72.
    damage = 21, fireRate = 0.32, range = 70,   -- ~6.72 DPS × 2 = 13.44 total
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
    --
    -- 2026-04-29 ea3-13 — LightningRadish A-tier nerf. ea3-3 SUPER
    -- AUTO showed Radish at 12.62 (+0.96 above slate, A-tier, 229
    -- runs). Variant B picked: chainFalloff 0.45 → 0.35 (-22%).
    -- Hop1 45% → 35% of primary (5.4 → 4.2 DPS); hop2 20% → 12%
    -- of primary (2.4 → 1.4 DPS). Total chain DPS 7.8 → 5.6 (-28%).
    -- Solo waves unchanged (chain doesn't fire on a single mob);
    -- AOE/Combined chain-DPS cut ~28%, which is where the +0.96
    -- above slate comes from. Same lever-shape as the Mortar /
    -- Spore B picks (mechanic-preserving, surgical). Predicted
    -- real-game shift after indirect Mortar+Spore nerf drops:
    -- 12.47 → ~12.05, A-tier near slate.
    --
    -- 2026-05-02 ea3-225 — D-tier partial revert. Power Core CURVE
    -- × 105 (n=105, balance v21) showed Radish at real 9.76 (D-tier,
    -- below slate). chainFalloff 0.35 → 0.40 (+14%, halfway back
    -- to pre-ea3-13). Hop1 35% → 40% of primary (4.2 → 4.8 DPS);
    -- hop2 12% → 16% (1.4 → 1.9 DPS). Chain identity preserved;
    -- AOE-wave value lifted ~15%. Smaller-than-full-revert because
    -- Solo-wave performance is fine — we want the lift only on
    -- multi-mob waves where chain hops fire.
    chainJumps = 2, chainFalloff = 0.40, chainRange = 14,
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
    -- 2026-05-03 ea3-233: fireRate 1.2 → 1.5 (+25%). Per SUPER
    -- FAILURE CURVE × 495 (n=165 each Core, balance v22) Spore
    -- stuck at F-D across all Cores (9.44 P / 9.12 C / 8.87 S)
    -- despite ea3-225's cloudTickDmg revert. The cloud-DOT
    -- mechanic isn't reaching enough mobs — cadence increase
    -- spawns more clouds per second, lifting overlap-heat density
    -- without touching damage stats.
    -- 2026-05-03 ea3-234: fireRate 1.5 → 1.4 (-7%). At v23 SUPER
    -- FAILURE CURVE Spore tipped to F-tier on Power (9.57) — the
    -- 1.2→1.5 jump overshot. Splitting the difference at 1.4 keeps
    -- the cadence bump (vs original 1.2 = +17%) without bottoming
    -- Spore out. Self-DPS 12.0 → 11.2.
    damage = 8, fireRate = 1.4, range = 25,
    -- cloudTickDmg history: 3 → 4 → 6 → 5 (2026-04-27 paired with
    -- the new overlap-heat mechanic — base trim ensures Spore solo
    -- stays at ~12.5 while overlap density is the new lift lever).
    -- cloudRadius 8 → 7 (2026-04-27): smaller per-cloud area.
    -- Combined with heat overlap, encourages tight cloud clusters
    -- for max damage (smaller radius = harder to cover wide path
    -- with one cloud, easier to overlap multiple).
    --
    -- 2026-04-29 ea3-12 — Spore S-tier nerf. ea3-3 SUPER AUTO showed
    -- Spore at 12.74 (+1.08 above slate, S-tier, runs 228). Cloud
    -- DOT is the dominant lever (60 dmg per puff over 3s; with
    -- 1.2 shots/s the overlap-heat mechanic stacks 3-4 simultaneous
    -- clouds). Variant B picked: cloudTickDmg 5 → 4 (-20%). Each
    -- puff drops 48 dmg instead of 60; per-second cloud DPS 20 → 16.
    -- Same overlap-heat mechanic, same per-shell timing, same
    -- "lingering poison carpet" identity — just less dense damage
    -- per ticking cloud. Predicted: 12.74 → ~11.95, dropping Spore
    -- to A-tier near HoneyHive / BloodlinkVine. Per Matthew "B"
    -- pick after the 4-variant review.
    --
    -- 2026-05-02 ea3-225 — D-tier revert. Power Core CURVE × 105
    -- (n=105, balance v21) showed Spore at real 9.72 (D-tier),
    -- well BELOW slate. The ea3-12 nerf overshot once HoneyHive's
    -- patch + AOE-wave dynamics shifted around it. cloudTickDmg
    -- 4 → 5 (revert to pre-ea3-12 value). Per-puff total 48 → 60,
    -- per-second cloud DPS 16 → 20.
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
    -- 23 → 22 (2026-04-29 ea3-15): light damage trim per Matthew.
    -- ea3-3 SUPER AUTO showed Pepper at 12.09 (+0.43 above slate,
    -- the smallest nerf-list gap, A-tier). -4.3% DPS (20.7 → 19.8)
    -- combined with indirect drops from Mortar/Spore/Radish/Thorn
    -- nerfs predicts shift to ~11.7 — solid A near slate. Splash
    -- area + cadence + range unchanged so the "decisive single
    -- boom" identity stays.
    -- 2026-05-03 ea3-233: 22 → 19 (-15%, ceil rounded). Per SUPER
    -- FAILURE CURVE × 495 (n=165 each Core, balance v22) Pepper
    -- sat at A-B 10.13-10.85 across all Cores. Compressing the
    -- carry-tier alongside Mortar (32→28) + Acorn (24→21) so the
    -- buffed bottom (Honey/Spore/Power/Blink) can converge toward
    -- C/B without the carries pulling the field higher. Self-DPS
    -- 19.8 → 17.1.
    damage = 19, fireRate = 0.9, range = 32,
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
    footprintWidth = 14, footprintDepth = 14,   -- huge commitment; ea3-145 footprint nerf 12→14 (+36% area)
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
    -- 2026-05-03 ea3-233: 32 → 28 (-15%, ceil rounded). SUPER
    -- FAILURE CURVE × 495 (n=165 each Core) showed Mortar S-tier
    -- on every Core by 0.5-1.0 wave gap (11.31 P / 10.74 C / 11.00 S).
    -- Carry-compression nerf alongside Pepper (22→19) + Acorn
    -- (24→21) so the buffed bottom converges. Self-DPS 11.52 → 10.08.
    damage = 28, fireRate = 0.36, range = 60,
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
    --
    -- 2026-04-29 ea3-11 — 8th nerf pass. ea3-3 SUPER AUTO showed
    -- Mortar still S-tier at 13.21 (+1.55 above slate, +0.95 above
    -- next aux). Variant B (synergy-killer): blastRadius 10 → 8
    -- (-36% area: 100π → 64π = 64% of prior coverage). Damage,
    -- fireRate, range, lobSeconds all unchanged so the per-shell
    -- punch identity (decisive lob across the map) is preserved.
    -- The mechanic-level lever (splash AREA) was the one that
    -- actually moved Mortar last time per the bq + di nerf history;
    -- per-shell-damage trims (variant A from this review) only
    -- shifted Mortar ~0.5 wave per pass and didn't break the
    -- LightningRadish + Mortar pair (14.93 = +3.27 above slate),
    -- which is the actual problem — two overlapping AOE coverages
    -- stacking multiplicatively.
    --
    -- Predicted impact:
    --   • Solo: ~unchanged (single boss = single splash hit, not
    --                       cluster math)
    --   • AOE/Combined: -19% per-shell mob coverage on cluster
    --                   waves (area shrinks 36% but cluster density
    --                   compresses the loss to ~19% effective)
    --   • Real-game avg: 13.21 → ~11.7 (B-tier)
    --   • LightningRadish + Mortar pair: 14.93 → ~13.5 (-1.4)
    --   • FrostMelon + Mortar: 13.34 → ~12.3 (-1.0)
    --   • Mortar + RootSprout: 13.29 → ~12.3 (-1.0)
    -- Per Matthew "B" pick after the 3-variant review. Story-mode
    -- safety: footprint 12×12 unchanged; blast radius 8 still
    -- catches typical waves and feels boomy.
    --
    -- 2026-04-30 ea3-131 — 9th nerf pass. Power-only 240-run pool
    -- on ea3-128/129 showed Mortar STILL S-tier at avgWave 13.8,
    -- +3.8 wave gap to next DPS (AcornSniper 10.0). The ea3-11
    -- prediction (real ~11.7 from blastRadius 10→8) under-shot
    -- by ~2 waves — under-nerf has been the consistent failure
    -- mode across all 8 prior passes. Per Matthew, going broader
    -- this round: three-axis trim layering damage + splash + lob
    -- so no single mechanic carries the full cut.
    --   • damage      48 → 40  (-17% per-shell, hits all wave types)
    --   • blastRadius  8 → 7   (-23% area: 64π → 49π,
    --                           AOE/Combined cluster catch -16%)
    --   • lobSeconds 2.2 → 2.5 (+14% flight time, more whiff on
    --                           moving clusters paired with knock-
    --                           back / blink / slow towers)
    -- fireRate / range unchanged. Damage card display now reads 40
    -- (down from 48); per the prior history this lever moved Mortar
    -- only ~0.5/pass, but stacked with the splash + lob trims it
    -- spreads the cut across mechanics so solo waves take some hit
    -- (just damage) and AOE waves take the full brunt (all three).
    --
    -- Predicted impact:
    --   • Solo: -17% effective DPS (damage cut only matters here
    --                               since splash is moot on 1 mob)
    --   • AOE/Combined: ~-30% effective DPS (damage × area × lob-
    --                                        accuracy compounding)
    --   • Real-game avg: 13.8 → ~11.5-11.8 (top of field, no
    --                                       longer running away;
    --                                       AcornSniper 10.0 stays
    --                                       second; tier banding
    --                                       redistributes from
    --                                       "Mortar S + 12 D" to
    --                                       a real S/A/B/C spread)
    --   • LightningRadish + Mortar pair: should drop ~-2 (two
    --                                                     stacking
    --                                                     AOE
    --                                                     mechanics
    --                                                     each lose
    --                                                     coverage)
    -- If THIS still leaves Mortar S, next pass reaches for footprint
    -- (12×12 → 14×14, +36% area = bigger placement cost) before
    -- touching damage further.
    --
    -- 2026-05-01 ea3-145 — 10th nerf pass. SUPER CURVE × 495 on
    -- ea3-138 (Phase A 315 + 154 Phase B before Studio crash =
    -- 469 entries) showed ea3-131 only chipped Mortar -1.0 wave
    -- on average across the 3 Cores (Power 12.89, Control 12.21,
    -- Support 13.25). Still S-tier with +2.6+ wave gap to #2
    -- (PepperCannon ~9.6-10.3 across Cores). HALF the predicted
    -- drop yet again — 9th pass under-shot just like the first 8.
    -- Per Matthew "ship it" against the prior plan to reach for
    -- footprint + fireRate, now stacked:
    --   • fireRate     0.5  → 0.4  (-20% per-second damage,
    --                                hits all wave types
    --                                uniformly)
    --   • footprintW   12   → 14   (+17%)
    --     footprintD   12   → 14   (+17%) = +36% total area cost.
    --                                Mechanic-level lever per
    --                                Matthew's prior framing —
    --                                Mortar's defining trade-off
    --                                is "huge boom for huge cell
    --                                cost." Bigger footprint
    --                                forces a tighter placement
    --                                choice + reduces neighbor
    --                                density (less aura-from-
    --                                others contribution + worse
    --                                cluster-pair synergy with
    --                                LightningRadish / etc.).
    -- damage / range / blastRadius / lobSeconds unchanged from
    -- ea3-131. Card display: damage stays 40, fireRate now 0.4
    -- (down from 0.5).
    --
    -- Predicted impact (combined fireRate + footprint):
    --   • All wave types: -20% per-second damage (fireRate)
    --   • AOE/Combined extra hit: less neighbor support due to
    --     tighter placement = -10-15% effective on cluster waves
    --   • Real-game avg: ~12.9 → ~10.8-11.0 (top of field,
    --                                        Pepper ~9.8-10.3
    --                                        becomes new top of
    --                                        A-tier; Mortar
    --                                        sits B/A range)
    -- If THIS still leaves Mortar S by >1 wave gap, next pass
    -- reaches for damage (40 → 32) — but per the 9-pass history
    -- per-shell damage trims have shifted Mortar only ~0.5/pass.
    --
    -- 2026-05-01 ea3-146 — 11th nerf pass. ea3-145 only chipped
    -- Mortar -0.27 wave (12.89 → 12.62 on Power). Still S-tier
    -- with +2.47 wave gap to PepperCannon. The 10-pass history is
    -- now 10 consecutive under-shoots — fireRate / footprint /
    -- damage / splash / lob all trimmed, but RANGE has been
    -- untouched the entire time. Per Matthew "change range to 60":
    --   • range  90 → 60  (-33%)
    --                     For comparison: AcornSniper 70,
    --                     PepperCannon 32, LightningRadish 28,
    --                     FrostMelon 25. Mortar's 90 was 1.3-3.6×
    --                     the field — sat in a corner and lobbed
    --                     across the entire 80-100-cell Map 4
    --                     path. 60 reduces path coverage from
    --                     ~100% to ~67%, forcing engagement
    --                     placement decisions and making the lob
    --                     2.5s flight more punishing on closer
    --                     mobs that move fast relative to lob lead.
    -- All other axes unchanged from ea3-145 (damage 40, fireRate
    -- 0.4, blastRadius 7, lobSeconds 2.5, footprint 14×14).
    --
    -- Predicted impact: -1.5 to -2.0 wave (Mortar 12.62 → ~10.6-11.0,
    -- into A/B-tier territory; PepperCannon 10.15 becomes new top
    -- of A; field tightens up). If this still leaves Mortar S
    -- (under-shoot streak hits 11), next pass reaches for damage.
    --
    -- 2026-05-01 ea3-152 — 12th nerf pass. ea3-150 placement-fix
    -- sweep (105 runs) showed Mortar real STILL S-tier at 12.12,
    -- +1.5 wave gap to PepperCannon (10.65). The range-60 nerf
    -- chipped only ~0.81 wave (12.93 → 12.12 across full sweep).
    -- The placement-fix's footprint-edge aura check ALSO benefited
    -- Mortar disproportionately — 14×14 footprint reaches into
    -- nearby auras 78% farther than the prior center-only check,
    -- which masked some of the range nerf's impact. 11 consecutive
    -- under-shoots — every prior nerf landed half its predicted
    -- effect.
    --
    -- Two-axis trim doubling on the under-shoot pattern:
    --   • damage       40 → 32  (-20% per-shell, hits all wave
    --                            types uniformly. Solo waves
    --                            previously took only the damage
    --                            cut from prior nerfs since splash
    --                            is moot; this re-engages that
    --                            lever now that we're past the
    --                            "splash matters more" phase.)
    --   • blastRadius   7 → 6  (-26% area: 49π → 36π = 73% of
    --                           prior coverage. Continued mechanic-
    --                           area trim. AOE-wave cluster catch
    --                           drops another ~13% effective.)
    -- fireRate / range / lobSeconds / footprint unchanged — keeping
    -- the "decisive lob across the map" identity intact while
    -- crunching per-shell punch + cluster catch.
    --
    -- Predicted impact:
    --   • Solo: -20% effective DPS (damage axis only)
    --   • AOE/Combined: ~-30% effective DPS (damage × area,
    --                    multiplicative compounding)
    --   • Real-game avg: 12.12 → ~10.0-10.5 (top of B-tier; Pepper
    --                    10.65 becomes new top of A; field
    --                    tightens to 10.0-10.7 spread)
    -- If THIS still leaves Mortar S by >0.5 wave gap, next pass
    -- reaches for footprint AGAIN (14 → 12, -23% area cost) since
    -- the ea3-145 footprint expansion was meant to hurt Mortar via
    -- placement opportunity cost but the ea3-151 aura-edge fix
    -- inadvertently rewarded the larger footprint.
    --
    -- 2026-05-01 ea3-154 — 13th nerf pass. ea3-152 (damage 40→32 +
    -- blastRadius 7→6) chipped Mortar from 12.12 → 11.37 on Power
    -- (n=105 v20). Predicted -1.5 to -2.0 wave; actual -0.75 wave.
    -- 12 of 12 prior nerfs under-shot — the under-shoot streak is
    -- now in folklore territory.
    --
    -- Mortar still S-tier with +0.78 wave gap to PepperCannon
    -- (10.59). Sim NOW under-predicts Mortar by -0.70 (sim 10.67,
    -- real 11.37) — the sign flipped. Means Mortar's 14×14 footprint
    -- is grabbing aura coverage the simulator's per-tower aura
    -- model under-credits. The footprint advantage didn't go away
    -- with damage/splash trims because aura interaction is
    -- footprint-driven, not damage-driven.
    --
    -- Single-axis trim:
    --   fireRate  0.4 → 0.36  (-10% per-second damage, hits all
    --                          wave types uniformly)
    -- damage / range / blastRadius / lobSeconds / footprint unchanged.
    -- Per Matthew "let's trim mortar fire rate" — clean axis pick
    -- that closes the +0.78 gap without touching footprint (which
    -- would also undo the ea3-145 placement-cost intent).
    --
    -- Predicted impact:
    --   • All wave types: -10% effective DPS
    --   • Real-game avg: 11.37 → ~10.6-10.8 (top of A-tier alongside
    --                                        Pepper 10.59 / Acorn
    --                                        10.47; field merges
    --                                        into a 10.4-10.8 spread
    --                                        with Mortar/Pepper/Acorn
    --                                        co-leading)
    -- If THIS still leaves Mortar S by >0.3 wave gap, next pass
    -- reaches for footprint (14 → 12) accepting the placement-cost
    -- + aura-grab interaction.
    lobSeconds = 2.5, blastRadius = 6,
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
    -- 2026-05-03 ea3-233: damage 5 → 7 (+40%). SUPER FAILURE CURVE
    -- × 495 had Blink at D consistently (9.88 P / 9.27 C / 8.97 S).
    -- Pure direct DPS bump (5.5 → 7.7 self-DPS); blink mechanic
    -- identity (interval 7s, distance 10) preserved.
    damage = 7, fireRate = 1.1,
    range = 18,                       -- fire range (direct shot only — blink AOE is separate)
    -- Blink mechanic params (read by Towers.lua per-tower blink loop):
    --   blinkInterval = seconds between blinks (game-time)
    --   blinkDistance = studs to push mobs backwards on path
    --   blinkAoeRadius = radius around tower in which mobs get blinked.
    --                    DECOUPLED from `range` (2026-04-29 ea3-7) so
    --                    rarity can scale the AOE without inflating the
    --                    direct-shot range. Falls back to `range` if
    --                    unset (keeps backward-compat for any future
    --                    blink-tower variant that wants the old shape).
    blinkInterval = 7.0,              -- 5.0 → 8.0 → 7.0 (dn lift)
    -- 2026-04-28 dp: 10 → 14 per Matthew "increase blinkberry
    -- teleport distance." +40% setback, still loop-safe (mob
    -- speed 8 × interval 7 = 56 covered, setback 14 → 42 net
    -- forward per cycle; Frost-stacked slow 0.85× → 33 net,
    -- still positive). Buffs the Control mechanic without
    -- approaching the infinite-blink boundary.
    blinkDistance = 14,               -- 20 → 8 → 10 → 14
    -- 2026-04-29 ea3-7 — AOE-blink rarity scaling. Per Matthew "B,
    -- and implement the tier changes as well." Baseline 22 ≈ +22%
    -- over the prior implicit AOE (`range`=18). RarityMults.secondary
    -- scales per tier:
    --   Common      0.90 → 19.8  (effectively unchanged story-mode)
    --   Rare        1.00 → 22
    --   Exceptional 1.08 → 23.8
    --   Legendary   1.15 → 25.3
    --   Mythical    1.22 → 26.8  (~+50% over the previous baseline)
    -- Story-mode boss safety: Mold King / Web Weaver / Canopy Bird
    -- spawn alone or with sparse escorts; +5 stud radius Mythical
    -- catches a couple more spiderlings on Web Weaver but doesn't
    -- trivialize the fight. The buff scales primarily on AOE-/Combined-
    -- wave clusters where 30+ mobs are bunched along the path, which
    -- is where BlinkBerry was bottoming out (F-tier, 10.34 avg).
    blinkAoeRadius = 22,
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
    --
    -- 2026-04-29 ea3-18 — di's bump only got Pace to 10.97 (still
    -- C-tier, -0.69 vs slate). Per Matthew "a + fire rate 1.7" —
    -- combined damage + cadence bump:
    --   damage   3 → 5 (+67%)
    --   fireRate 1.5 → 1.7 (+13%)
    --   self-DPS 4.5 → 8.5 (+89%)
    -- Lands Pace between PowerSeed (8) and Spy (5.6) post-buffs.
    -- FAST cadence identity reinforced (1.5 → 1.7 doubles down on
    -- the flavor) plus a meaningful per-hit lift. Predicted:
    -- 10.97 → ~11.6 (B-tier).
    damage = 5, fireRate = 1.7,
    range = 18,
    -- Aura: same fields the SupportCore aura prepass reads.
    -- 2026-05-03 ea3-229: 18 → 22 (match SpyglassRoot). SUPER FAILURE
    -- CURVE Phase A showed Pace at F-tier 8.74 on SupportCore +
    -- D-tier on Power/Control. The 18-stud aura only reached ~3-4
    -- towers in the auto-place layout; bumping to 22 (Spy's radius)
    -- catches ~5-6, materially lifting the team-DPS contribution
    -- on Support combos. Identity preserved (still local aura, not
    -- global; SupportCore's 9999 still dominates per-axis when
    -- they coexist).
    auraRadius = 22,                  -- 16 → 18 → 22
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
    --
    -- 2026-04-29 ea3-16 — PowerSeed Support buff per Matthew "b
    -- bump to 8". ea3-3 SUPER AUTO showed PowerSeed at 10.70
    -- (-0.96 below slate, worst of the 3 Support buff towers).
    -- Variant B (self-DPS axis) picked but cranked higher than
    -- the proposed 5: damage 3 → 8 (+167%). Self-DPS 3 → 8 makes
    -- PowerSeed a non-trivial direct damage source on top of its
    -- +30% damage aura. NEUTRAL cadence (1.0 sps) preserved so
    -- the per-tower flavor stays distinct from PaceFlower's FAST
    -- and SpyglassRoot's LONG. Predicted: 10.70 → ~11.4 (B-tier).
    -- Aura unchanged so synergy pairs with strong DPS anchors
    -- (Power+Mortar etc.) only shift via the self-DPS contribution,
    -- not via aura math — keeps the buff focused on PowerSeed
    -- itself rather than over-amplifying every aux it pairs with.
    -- 2026-05-03 ea3-233: damage 8 → 11 (+38%). SUPER FAILURE CURVE
    -- × 495 showed the auraR 18→22 change barely moved PowerSeed
    -- (+0.06-0.09 across cores) — sim already credits +30% damage
    -- aura well so radius doesn't unlock new value. The lever
    -- real-game responds to is direct DPS. Self-DPS 8 → 11 (+38%).
    -- Lifts F-on-SupportCore (8.87) toward C; +30% damage aura
    -- identity preserved.
    damage = 11, fireRate = 1.0,
    range = 18,
    -- 2026-05-03 ea3-229: 18 → 22 (match SpyglassRoot). Same logic
    -- as PaceFlower — SUPER FAILURE CURVE showed PowerSeed at F on
    -- SupportCore (8.78). Bigger aura coverage lifts team damage
    -- on Support combos.
    auraRadius = 22,
    auraFireRateBonusPct = 0,
    -- 2026-05-03 ea3-234: 30 → 40 (+33%). At v23 SUPER FAILURE
    -- CURVE PowerSeed REGRESSED on Power (10.05 → 9.86) despite
    -- the ea3-233 +damage buff — its identity is "DPS aura
    -- amplifier," and the lever real-game responds to is the aura
    -- bonus pct itself, not the seed's own damage. Bumping
    -- amplification 30→40 makes the aura visible exactly where it
    -- should be visible: in the team's damage output, not in
    -- PowerSeed's solo numbers.
    auraDamageBonusPct = 40,
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
    --
    -- 2026-04-29 ea3-17 — SpyglassRoot Support buff per Matthew "b".
    -- ea3-3 SUPER AUTO showed SpyglassRoot at 10.91 (-0.75 below
    -- slate, C-tier). Variant B picked — mirrors PowerSeed's ea3-16
    -- buff pattern: damage 4 → 8 (+100%). Self-DPS 2.8 → 5.6.
    -- Slow LONG-range identity preserved (still fr=0.7, still
    -- range=26, still range aura). Heavier hits per shell give
    -- SpyglassRoot credible direct damage to match the post-ea3-16
    -- Support cluster (PaceFlower self-DPS 4.5 / PowerSeed 8 /
    -- SpyglassRoot now 5.6). Predicted: 10.91 → ~11.5 (B-tier in
    -- line with HoneyHive / BloodlinkVine).
    -- ea3-181: native range 26 → 32 (+23%), auraRadius 18 → 22 (+22%)
    -- per Matthew "increase attack/aura radius." SpyglassRoot sat at
    -- REAL avg 8.47 over 41 runs on balance v6 (Power core, dropped
    -- to D-tier from sim's predicted A 11.15). Bigger native range
    -- gives the tower more shots-per-mob along the path; bigger aura
    -- pulls more nearby towers into the +30% range buff radius.
    -- Identity preserved (still slow-cadence + range axis).
    damage = 8, fireRate = 0.7,
    range = 32,                       -- native long range, matches "spyglass" theme
    auraRadius = 22,
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
    --
    -- 2026-04-29 ea3-20 — combined moderate buff per Matthew "e".
    -- ea3-3 SUPER AUTO showed Vine at 11.47 (-0.19 below slate).
    -- After indirect nerf drops (Mortar/Spore/Radish/Thorn/Pepper
    -- all in Vine's pair list), real gap is ~-0.5 — needs a
    -- meaningful lift.
    --   damage         3 → 5 (+67%) — self-DPS 3 → 5
    --   linkEchoFrac   0.5 → 0.6 (+20%) — echoes hit harder
    -- Combined: Vine's per-shot contribution to a 5-mob cluster
    -- goes from 5 dmg × (1 + 4 × 0.5) = 15 → 7.5 × (1 + 4 × 0.6) =
    -- 25.5 (+70% effective AOE). Solo waves: just the +67% direct
    -- (5 dmg per shot, no echoes). Two-axis hedged buff so each
    -- lever can be backed out independently if it overshoots.
    -- Predicted: ~10.97 (post-nerf-indirect) → ~11.5 (B-tier).
    damage = 5, fireRate = 1.0,
    range = 24,
    linkRadius = 24,                  -- mobs within radius are linked (18 → 24, +1 mob nominal)
    linkEchoFrac = 0.6,               -- echoed damage is 60% of original (ea3-20: 0.5 → 0.6)
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
    -- 2026-04-29 ea3-7 — BlinkBerry rarity-scaled AOE.
    "blinkAoeRadius",
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
