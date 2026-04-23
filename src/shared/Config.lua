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
        -- regular-mob HP matches that with a 2.8× bump.
        HpMult         = 2.8,   -- +180% HP on regulars (was 1.8)
        SpeedMult      = 1.25,
        SpawnCountMult = 1.3,
        BossHpMult     = 1.8,   -- +80% HP on stage bosses (was 1.3); map-2
                                -- Mold King now noticeably meatier than map-1
    },

    -- The Canopy Weaver (map 2 final boss) web-shooting mechanic.
    -- Tunables for the `CanopySpiderBoss` system. All durations are
    -- WALLCLOCK seconds (not game-time scaled — the attack is a tap
    -- minigame, its cadence should feel the same at any game speed).
    CanopyWeaver = {
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
