--!strict
--[[
    Config.lua — Game-wide tuning values and dimensional constants.

    WHY THIS MODULE EXISTS:
    Values like "5 waves per stage", "3 stages per run", and "300 stud TD
    room" used to be duplicated across files. When we changed from 3 waves
    to 5 waves, we had to find every hardcoded `5` that meant "total waves"
    (not easy; 5 is also a common magic number). Centralizing tunables in
    one named table makes them greppable, documentable, and overrideable.

    USAGE:
        local Config = require(ReplicatedStorage.Shared.Config)
        for i = 1, Config.Waves.perStage do ... end

    CONVENTIONS:
      - Group related constants into sub-tables (Grid, Waves, Towers, Map2).
      - Constants are SCREAMING_SNAKE in old code but PascalCase here for
        consistency with Lua idiom — old code can keep its names, new code
        references via Config.Section.Name.
      - Everything is frozen so accidental writes fail loud.
]]

local Config = {}

-- ===========================================================================
-- GRID — shared coordinate system spanning map 1 and map 2
-- ===========================================================================
Config.Grid = {
    CellSize        = 2,      -- studs per grid cell
    Map1Cols        = 60,     -- TD room width in cells (cols 0..59)
    Map1Rows        = 44,     -- TD room depth in cells
    Map2Cols        = 75,     -- Map 2 width in cells
    Map2Rows        = 55,     -- Map 2 depth in cells
    Map2ColOffset   = 60,     -- Map 2 cols start here in the shared grid
    -- Total grid spans cols 0..134 (Map1Cols + Map2Cols = 135)
    PathWidthCells  = 4,      -- Path brush extends this many cells on each side of waypoint line
}
Config.Grid.TotalCols = Config.Grid.Map1Cols + Config.Grid.Map2Cols  -- 135

-- ===========================================================================
-- WAVES — wave pacing and count
-- ===========================================================================
Config.Waves = {
    PerStage                    = 5,      -- waves 1..5 per stage
    TotalStages                 = 3,      -- stage 1, 2, 3, then boss
    UpgradePickToNextWaveDelay  = 6,      -- seconds between picking upgrade and wave N+1
    StageContinueAutoDelay      = 6,      -- seconds before stage-clear modal auto-continues
    WaveClearedPollInterval     = 0.25,   -- how often to poll "are all mobs dead?"
    MaxRerollsPerStage          = 2,      -- free upgrade rerolls per stage
}

-- ===========================================================================
-- TOWERS — defaults and constraints
-- ===========================================================================
Config.Towers = {
    MaxPerPlayer     = 20,     -- hard cap on tower count per player
    PlacementRange   = 60,     -- studs from player when placing (prevents rooftop placement)
}

-- ===========================================================================
-- MAP 2 — climbing-the-tree specific constants
-- ===========================================================================
Config.Map2 = {
    -- Staircase
    StairOuterRadius   = 12,
    StairInnerRadius   = 3,
    StairStepCount     = 120,
    StairStepHeight    = 1.2,
    StairStepAngleDeg  = 12,
    StairStepDepth     = 4,
    StairCellRadius    = 7,    -- decor zone radius (no tower placement)

    -- Stage unlock fractions (what % of staircase is visible per stage)
    StageUnlockFractions = {
        [1] = 0.05,   -- barely above ground
        [2] = 0.25,   -- clearly rising
        [3] = 0.60,   -- majestic
        [4] = 1.00,   -- full height (boss / night)
    },

    -- Staircase rise animation
    BuriedDropStuds       = 60,    -- how far below floor parts start
    RiseDurationSeconds   = 1.5,
    RiseStaggerPerStep    = 0.015, -- seconds between each step's rise start

    -- Difficulty multipliers: applied ON TOP of per-stage multipliers when
    -- currentMapId == 2. The player is expected to have earned a temp tower
    -- from the map 1 boss by now, so they have more firepower — the mobs
    -- need to scale up to match. Tuned conservatively: playtesting will
    -- tighten from here. Boss HP is NOT scaled separately (stage multipliers
    -- already include bossHpMult, and stacking would make the map 2 boss
    -- unbeatable).
    Difficulty = {
        -- Map 2 multipliers. The player arriving on map 2 has a second
        -- placed Core tower (upgraded from map 1) PLUS a map-1 Aux tower
        -- doing ~80% of Core's DPS PLUS Aux effects (slow / chain /
        -- splash / etc.) that extend effective DPS against clustered mobs.
        -- Aggregate player firepower is ~2-2.5× what they had on map 1;
        -- regular-mob HP matches that with per-stage bumps on top of the
        -- 3.36 baseline. Stage multipliers are stacked multiplicatively:
        --   stage 1 = +30% (early map 2 is the hardest difficulty cliff)
        --   stage 2 = +25%
        --   stage 3 = +10% (player's build is peaking; the spider fight
        --               is the real test, not the trash)
        HpMult         = 3.36,  -- baseline; stacked with HpMultByStage
        HpMultByStage  = { [1] = 1.30, [2] = 1.25, [3] = 1.10 },
        SpeedMult      = 1.25,
        SpawnCountMult = 1.3,
        -- Bump from 2.16 → 11 so the map-2 stage-1 Mold King (1500 base × stage
        -- bossMult 1.333 × 11 ≈ 22,000 HP) is tankier than the map-1 final
        -- Mold King (17,000). Principle: bosses should monotonically increase
        -- in HP across a run. Stage-2 Mold King (base × 3 × 11 ≈ 49,500) and
        -- the Web Weaver at 80,000 (40k spider + 4×10k spiderlings) completes the ramp.
        BossHpMult     = 11,
    },

    -- The Web Weaver (map 2 final boss) web-shooting mechanic.
    -- Tunables for the `CanopySpiderBoss` system (internal file/class name
    -- kept; display name is Web Weaver). All durations are WALLCLOCK
    -- seconds (not game-time scaled — the attack is a tap minigame, its
    -- cadence should feel the same at any game speed).
    WebWeaver = {
        WebAttackIntervalSec = 15,   -- seconds between web attacks
        WebCountPerAttack    = 3,    -- webs spawned per attack
        WebFlightSec         = 2.5,  -- seconds from boss to target
        BossPauseSec         = 2.5,  -- seconds boss is frozen during the attack
        TowerWebbedSec       = 3,    -- seconds an un-tapped web locks the tower
    },
}

-- ===========================================================================
-- MAP 3 — the Canopy (top of the tree) — world not yet built, boss mechanic
-- usable via dev spawn until the map 3 arena geometry lands
-- ===========================================================================
Config.Map3 = {
    -- The Canopy Bird (map 3 final boss) dive mechanic. See
    -- `systems/BirdBoss.lua`. Wallclock seconds like the Weaver tunables.
    CanopyBird = {
        DiveIntervalSec  = 12,   -- seconds between dive attempts
        DiveTargetsCount = 1,    -- targets placed per attempt (1 = single-tower focus)
        HoverSec         = 2.0,  -- seconds the dive-target is tappable before the strike
        BossPauseSec     = 3.0,  -- seconds bird is frozen during the attack
        DiveBonusDamage  = 500,  -- bonus damage dealt to bird when player taps the dive-target
        TowerPeckLoss    = 10,   -- MaxShots reduction on an un-tapped peck
    },
}

-- ===========================================================================
-- BOSSES — manually-assigned HP per stage boss, per map.
-- Covers the nine stage bosses (Mold King variants on wave 5 of each stage).
-- Named map bosses (Mold King final, Web Weaver, Canopy Bird) and spiderlings
-- have their HP set via MOB_TYPES[*].hp in TreeOfLife_WaveSystem — they don't
-- fit the grid since they're isFinal and skip stage/map scaling entirely.
-- Invariant: HP ramps monotonically across the 12-boss sequence.
-- ===========================================================================
Config.BossHp = {
    StageByMap = {
        -- Map 1 got a 10% across-the-board HP cut (v5.11 playtest).
        -- 1500→1350, 3500→3150, 7000→6300.
        [1] = { [1] = 1350,  [2] = 3150,   [3] = 6300   },  -- Crook
        [2] = { [1] = 22000, [2] = 35000,  [3] = 55000  },  -- Climbing
        [3] = { [1] = 100000,[2] = 150000, [3] = 220000 },  -- Canopy
    },
}

-- ===========================================================================
-- PHOENIX — attachment AOE mechanic
-- ===========================================================================
Config.Phoenix = {
    AoeRadius        = 50,     -- studs around heart where effect triggers
    GraceSeconds     = 5,      -- player invulnerability after trigger
    BurnSeconds      = 10,     -- total burn duration
    BurnInPlaceSeconds = 0.5,  -- how long mobs are frozen+damageable before limbo
    Cooldowns = {
        Common      = 10 * 60,  -- 10 minutes
        Uncommon    = 9 * 60,
        Rare        = 8 * 60,
        Exceptional = 7 * 60,
        Special     = 6 * 60,
    },
}

-- Freeze recursively so nothing can accidentally mutate config at runtime
local function deepFreeze(t: {[any]: any}): {[any]: any}
    for _, v in pairs(t) do
        if type(v) == "table" then
            deepFreeze(v)
        end
    end
    return table.freeze(t)
end
deepFreeze(Config)

return Config
