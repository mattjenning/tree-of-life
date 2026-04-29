--!strict
--[[
    TowerTypes.lua — Single source of truth for every tower type's
    type-defining data: base stats, footprint, ammo capacity, default
    targeting mode.

    WHY THIS MODULE EXISTS:
    Before this, adding a new tower type meant editing three files —
    the hub (builder fn + TOWER_DEFS + TOWER_BUILDERS), the client
    (picker UI), and occasionally the wave system. Type data was
    scattered: `{damage=18, range=30, fireRate=1.6}` in one hub table,
    then ALSO as `:SetAttribute("Damage", 18)` ... `:SetAttribute(
    "FireRate", 1.6)` literals in the builder fn. Changing damage meant
    editing two spots and hoping they stayed in sync.

    This module flips the polarity: TowerTypes.Power is the ONLY place
    Power's numbers live. The hub's build code and every downstream
    consumer read them here. Adding a new tower type becomes:
      1. Add a table entry here.
      2. Add a builder fn + register it in TOWER_BUILDERS in the hub.
      3. Wire the picker UI.

    TYPE-DEFINING VS RUNTIME STATE:
    Values here are IMMUTABLE per tower type. They're the "template"
    a tower is stamped from at placement. Runtime state (current
    `Shots`, equipped attachment, cooldowns, ammo pips) is per-tower
    and lives on the Instance's attributes, NOT here.

    ATTRIBUTE CONTRACT (for wave system + attachments readers):
    At placement, the hub stamps these attributes onto each Tower model:

      TowerType       : string    -- matches a key in this table
      Damage          : number    -- = TowerTypes.X.damage          (live, mutated by upgrades)
      Range           : number    -- = TowerTypes.X.range           (live)
      FireRate        : number    -- = TowerTypes.X.fireRate        (live; shots/second)
      DamageBase      : number    -- = TowerTypes.X.damage          (snapshot, never mutated)
      RangeBase       : number    -- = TowerTypes.X.range           (snapshot)
      FireRateBase    : number    -- = TowerTypes.X.fireRate        (snapshot)
      DamageBonusPct  : number    -- 0 at placement; grows per upgrade
      RangeBonusPct   : number    -- 0 at placement; grows per upgrade
      FireRateBonusPct: number    -- 0 at placement; grows per upgrade
      MaxShots        : number    -- = TowerTypes.X.maxShots
      Shots           : number    -- starts = MaxShots (fully loaded)
      MaxAmmo         : number    -- = TowerTypes.X.maxAmmo (pip count)
      Ammo            : number    -- starts = MaxAmmo
      FootprintW      : number    -- = TowerTypes.X.footprintWidth
      FootprintD      : number    -- = TowerTypes.X.footprintDepth
      AnchorCol/Row   : number    -- grid position (not from this table)
      Owner           : number    -- player UserId (not from this table)
      TargetMode      : string    -- = TowerTypes.X.defaultTargetMode (First/Strongest/Center/Last)

    Upgrade cards mutate `Damage` = `DamageBase * (1 + DamageBonusPct/100)`
    each time the player picks a stat card. The Base values stay fixed so
    additive bonuses never compound exponentially.

    Attachments (Phoenix, Detonator, PowerCore) are GENERIC — they apply
    to any tower type, not gated by this table.

    USAGE:
        local TowerTypes = require(ReplicatedStorage.Shared.TowerTypes)
        local t = TowerTypes.Power
        tower:SetAttribute("Damage", t.damage)
        tower:SetAttribute("FireRate", t.fireRate)
]]

local TowerTypes = {}

-- ===========================================================================
-- POWER — the red-gem cylinder tower, fires straight bolts. Currently the
-- only tower type wired up end-to-end (picker UI, builder, attachment
-- support). Stats balanced for the original Phase 1 gameplay loop.
-- ===========================================================================
TowerTypes.Power = table.freeze({
    name              = "Power",
    displayName       = "Power Tower",

    -- Combat base stats. Live `Damage`/`Range`/`FireRate` attributes at
    -- runtime are derived as Base * (1 + BonusPct/100); upgrade cards
    -- mutate BonusPct, not Base.
    damage            = 18,
    range             = 24,    -- 20% tighter than legacy 30; map 1 mob HP -10% to compensate
    fireRate          = 1.6,   -- shots per second

    -- Ammo model: Shots is the real count, Ammo is the pip count
    -- displayed on the HUD (1 pip = 10 shots). A pile pickup loads +10
    -- shots = +1 pip into a non-full tower.
    maxShots          = 50,
    maxAmmo           = 5,

    -- Placement footprint in grid cells. Grid cell size comes from
    -- Config.Grid.CellSize; at 2 studs per cell this is 8×8 studs.
    footprintWidth    = 4,
    footprintDepth    = 4,

    -- Default target-priority mode when first placed. Player can change
    -- this per-tower via the target-mode HUD; this value is just the
    -- starting choice.
    defaultTargetMode = "First",   -- First | Strongest | Center | Last
})

-- ===========================================================================
-- ============================================================================
-- STUB ENTRIES BELOW — data only, not yet wired to builders or the picker UI.
-- ============================================================================
--
-- The entries below exist to prove TowerTypes supports multiple tower types
-- cleanly. They're pure data: no builder fn is registered in TOWER_BUILDERS,
-- no picker UI option shows them, no upgrade cards reference them yet.
--
-- When a future phase brings one of these online, that phase will need to:
--   1. Write a builder fn in the hub (or register a shared one).
--   2. Add the builder to TOWER_BUILDERS = { Power = ..., Slow = ..., ... }.
--   3. Add a picker-UI option (ShowTowerSelect flow + client-side hotbar).
--   4. Implement the gameplay effect (slow → mob speed multiplier; assassin →
--      crit or headshot bonus) in the wave system's firing code.
--
-- Balancing numbers below are first-pass guesses to illustrate how different
-- roles trade off. They'll almost certainly change during playtest.

-- ===========================================================================
-- SLOW — crowd-control tower. Applies a speed debuff to hit mobs rather than
-- dealing heavy damage. Goal: buy time for your heavier towers to kill
-- bunched-up mobs. Lower damage, medium range, slower fire cadence than
-- Power.
--
-- 2026-04-28 di: comment cleanup. The `CCStock` attribute reference was
-- legacy from when "CC" was a Core archetype card in the picker. The
-- 3 active Cores now are Power / ControlCore / SupportCore; the Slow
-- tower template below isn't currently spawned by any builder (the
-- Control axis is covered by ControlCore + Frost/Honey/Root/Blink aux).
-- Kept the table for future reuse (could become a temp tower or a
-- Map3 Cold variant); just no longer claimed to map to CCStock.
-- ===========================================================================
TowerTypes.Slow = table.freeze({
    name              = "Slow",
    displayName       = "Slow Tower",

    damage            = 6,
    range             = 32,
    fireRate          = 0.8,   -- shots per second (slower than Power)

    maxShots          = 60,    -- more shots than Power since each hit matters less
    maxAmmo           = 6,

    footprintWidth    = 4,
    footprintDepth    = 4,

    -- "First" so the slow fires early in the mob wave's path, giving
    -- downstream towers more dwell time to kill slowed mobs.
    defaultTargetMode = "First",
})

-- ===========================================================================
-- ASSASSIN — single-target sniper. Very high damage, long range, slow fire
-- rate. Intended for one-shotting big threats (tank mobs, mini-bosses)
-- rather than clearing waves. Few shots per load (one miss hurts).
-- ===========================================================================
TowerTypes.Assassin = table.freeze({
    name              = "Assassin",
    displayName       = "Assassin Tower",

    damage            = 60,    -- ~3.3× Power — one-shots most non-tank mobs
    range             = 50,    -- longest range in the roster
    fireRate          = 0.5,   -- one big hit every 2 seconds

    maxShots          = 20,    -- low capacity; each shot expensive
    maxAmmo           = 2,     -- 2 pips × 10 shots/pip

    footprintWidth    = 4,
    footprintDepth    = 4,

    -- All towers default to "First" (FRONT) per Matthew's rule —
    -- consistent default, player flips to Strongest/Center/etc. via the
    -- target-mode HUD if they want this tower to behave differently.
    defaultTargetMode = "First",
})

-- ===========================================================================
-- INFINITE CORE VARIANTS (Matthew 2026-04-27) — three Core archetypes
-- the player can select in the Infinite Arena loadout picker:
--   • Power     — DPS Core (this is the existing TowerTypes.Power)
--   • Control   — applies stacking DOT (DPS via debuff stack)
--   • Support   — aura buffs nearby towers (atk-speed + damage %)
--
-- Each entry below is data-only. Mechanics implementation:
--   • Power      → existing Towers.lua firing path (no new code)
--   • Control    → STAGE 2 — Towers.lua DOT-stack proc
--   • Support    → STAGE 2 — Towers.lua aura buff loop
--
-- Stats are first-pass placeholders; balance pass after mechanics
-- land. The Infinite spawner reads `coreId` from the loadout payload
-- and grants stock for the selected variant only.
-- ===========================================================================

-- Control Core — slow-paced single-target hits that apply a stacking
-- DOT debuff. Damage builds as stacks accumulate; great vs single
-- tanks (boss waves) where you can pile stacks on one target.
--
-- DESIGN INTENT (Matthew 2026-04-27, locked):
--   ControlCore is INTENTIONALLY single-target. It picks one mob via
--   TargetMode (default "First") per shot — no AOE, no chain, no
--   splash-stack. The DOT mechanic over-rewards solo-boss waves and
--   under-rewards multi-mob waves BY DESIGN. ControlCore players are
--   expected to PAIR with an AOE tower (PepperCannon / MushroomMortar
--   / SporePuffball) to handle wave-clear; ControlCore handles the
--   boss + tank kill power.
--
--   DO NOT add splash-stack / chain-stack / AOE proc behaviors to
--   ControlCore without an explicit design pivot. The asymmetry is
--   the gameplay hook — ControlCore is the answer to "what carries
--   me through Solo waves?", not "what's a one-tower clear?".
TowerTypes.ControlCore = table.freeze({
    name              = "ControlCore",
    displayName       = "Control Core",

    -- Lower base damage than Power; the DOT stack is where most of
    -- its DPS comes from once stacks build (Stage 2).
    --
    -- 2026-04-27: tried 8 → 7.2 (-10%) trim, then reverted back
    -- to 8 per Matthew "keep damage at 8 and change dot to 7
    -- damage ticks every second." DOT mechanic doing the lifting
    -- now (see stackDotTickDmg below — 4→7 per tick at 2→1 tps).
    --
    -- fireRate history (2026-04-27):
    --   1.4 → 1.2 (v6): Matthew "and fire rate to 1.2 shots per
    --                   second." Direct-DPS 11.2 → 9.6 (-14%);
    --                   stack-ramp 2.86s → 3.33s.
    --   1.2 → 0.9 (v7, current): Matthew "take controlcore shot
    --                   speed down to .9." Build bf 10× sweep
    --                   showed Frost+ControlCore at 18.67 solo
    --                   (+2.75 over Power+Frost) — slow-DOT
    --                   synergy compounding. Slower fireRate
    --                   reduces stack-application rate during
    --                   the slow window, capping how fast DOT
    --                   ramps even when target is held in range.
    --   Direct DPS 9.6 → 7.2 (-25%); stack-ramp 3.33s → 4.44s
    --   (interval × maxStacks). Note: stack-ramp now > 4.0s
    --   stackDotSeconds, but expiresAt refreshes per hit so the
    --   entry stays alive under sustained fire — math is fine.
    damage            = 8,
    range             = 24,
    fireRate          = 0.9,

    maxShots          = 50,
    maxAmmo           = 5,

    footprintWidth    = 4,
    footprintDepth    = 4,
    defaultTargetMode = "First",

    -- Stage 2 mechanic params (read by Towers.lua DOT-stack proc):
    --   stackDotTickDmg     = damage per tick per active stack
    --   stackDotTickPerSec  = ticks per second
    --   stackDotSeconds     = ENTRY lifetime (refreshed on every
    --                         hit — NOT per-stack expiry). Under
    --                         sustained fire this never matters
    --                         because every shot bumps expiresAt
    --                         back to gameNow + stackSec; only
    --                         relevant when ControlCore stops
    --                         firing on a target (target dies +
    --                         we move on, ControlCore is webbed,
    --                         out-of-range). NOT a tuning lever
    --                         for steady-state engagement DPS.
    --   maxStacks           = stack cap per mob
    --
    -- Tuning history per Matthew 2026-04-27:
    --   v1: tickDmg 4, tickPerSec 2, maxStacks 8
    --       → 8 DPS/stack, peak 64 DPS at full stacks. Build ay
    --       sweep showed ControlCore solos averaging +2.72 waves
    --       (+22%) over Power equivalents — overpowered.
    --   v2: tickDmg 4 → 7, tickPerSec 2 → 1, maxStacks 8
    --       → 7 DPS/stack, peak 56 DPS. -12.5% per-stack trim.
    --   v3: maxStacks 8 → 6. Peak DPS 56 → 42 (-25% from v2).
    --   v4: tickDmg 7 → 5. Peak DPS 42 → 30 (-29% from v3).
    --   v5: tickDmg 5 → 4. Peak DPS 30 → 24 (-20% from v4).
    --       Build bc 2-solo sample showed ControlCore still +15%
    --       over Power.
    --   v6: maxStacks 6 → 4 (current). Peak DPS 24 → 16
    --       (-33% from v5). Cumulative cuts from v1: -75% peak
    --       DPS (64 → 16). Stack-ramp time at fireRate 1.4 drops
    --       from 4.3s to 2.9s (4 stacks × 0.71s/shot). Burst-y
    --       per-tick chunks intact (4 dmg every second per
    --       stack); just a much lower ceiling.
    stackDotTickDmg    = 4,
    stackDotTickPerSec = 1,
    stackDotSeconds    = 4.0,
    maxStacks          = 4,
})

-- Support Core — buff aura. Doesn't shoot mobs directly (or does
-- minimal damage); instead grants a percentage attack-speed AND
-- damage bonus to towers within `auraRadius` studs. Best paired
-- with high-DPS aux towers.
TowerTypes.SupportCore = table.freeze({
    name              = "SupportCore",
    displayName       = "Support Core",

    -- Minimal direct combat — Support's value is the aura.
    damage            = 4,
    range             = 18,    -- only fires at nearby targets
    fireRate          = 0.8,

    maxShots          = 30,
    maxAmmo           = 3,

    footprintWidth    = 4,
    footprintDepth    = 4,
    defaultTargetMode = "First",

    -- Stage 2 aura params (read by Towers.lua aura buff loop):
    --   auraRadius          = studs around the core where buff applies
    --                         (9999 = "global" per Matthew 2026-04-27 —
    --                         hits every tower on the map regardless of
    --                         owner, since towerList includes all
    --                         tagged towers across all players)
    --   auraDamageBonusPct  = +N% damage to towers in radius
    --   auraFireRateBonusPct = +N% firerate to towers in radius
    -- Smaller per-tower lift than v1 (25%/25%) since the buff now
    -- covers EVERY tower, not just nearby ones — total network lift
    -- scales with placed-tower count, so per-tower needs to come
    -- down to keep total in line.
    auraRadius           = 9999,
    auraDamageBonusPct   = 10,
    auraFireRateBonusPct = 10,
})

return table.freeze(TowerTypes)
