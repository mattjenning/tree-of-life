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
    range             = 30,
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
-- Power. Matches the existing `CCStock` player attribute.
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

    -- "Strongest" so the assassin prioritizes the biggest HP target on
    -- screen — the ideal single-target sniper behavior. Player can still
    -- override per-tower via the target-mode HUD.
    defaultTargetMode = "Strongest",
})

return table.freeze(TowerTypes)
