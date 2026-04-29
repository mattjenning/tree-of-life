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
-- BUILD TAG — bumped per substantive code edit, not per Studio sync.
-- Format: YYYY-MM-DD<letter>. Bump the letter each session-edit so log
-- dumps the user pastes are unambiguously tagged to a specific build.
-- Without this, "your sweep dump shows X but my code does Y" can mean
-- the dump is from one Rojo-sync ago and the actual change hadn't
-- landed yet. Printed at server + client boot.
-- ===========================================================================
Config.BuildTag = "2026-04-29ea3-34"

-- ===========================================================================
-- VFX — visual-effect quality tiers. Read by Effects / Zones / future
-- VFX modules to scale per-effect detail down on slower devices
-- (Lily's iPad in particular). Pairs with the existing
-- `Workspace.InfiniteVisuals` toggle (which is on/off only).
--
-- USAGE:
--     local tier = Config.Vfx.tierFor()  -- "off" / "low" / "med" / "high"
--     if tier == "off" then return end
--     local detail = Config.Vfx.Tiers[tier]
--     local segments = detail.zoneOutlineSegments
--
-- DEFAULT POLICY:
--   • Workspace.VfxQuality attribute, when set, wins.
--   • Else falls back to "high" — server-side calls and PC clients
--     get full detail. Mobile clients should set
--     Workspace.VfxQuality = "low" early in init.client.lua based
--     on UserInputService.TouchEnabled.
-- ===========================================================================
Config.Vfx = {
    -- Per-tier multipliers / counts. Add new fields as new VFX modules
    -- need them; consumers default any missing field to a safe value.
    Tiers = table.freeze({
        off = table.freeze({
            damagePopups = false,
            zoneOutlineSegments = 0,    -- skip outline ring entirely
            aoeBurstScale = 0.0,        -- skip AOE burst part
            boltsEnabled = false,
        }),
        low = table.freeze({
            damagePopups = false,       -- iPad: skip popups (high alloc cost)
            zoneOutlineSegments = 12,   -- coarser ring than full
            aoeBurstScale = 0.7,
            boltsEnabled = true,
        }),
        med = table.freeze({
            damagePopups = true,
            zoneOutlineSegments = 20,
            aoeBurstScale = 1.0,
            boltsEnabled = true,
        }),
        high = table.freeze({
            damagePopups = true,
            zoneOutlineSegments = 32,   -- full-detail ring
            aoeBurstScale = 1.0,
            boltsEnabled = true,
        }),
    }),
    -- Default tier when Workspace.VfxQuality isn't set. "high" so PC /
    -- existing setups behave identically to before this module landed.
    DefaultTier = "high",
}

-- Resolve the active tier. Reads Workspace.VfxQuality with a defensive
-- string-validation step (any non-recognized value falls back to
-- DefaultTier so a typo doesn't silently disable VFX).
function Config.Vfx.tierFor(): string
    local Workspace = game:GetService("Workspace")
    local raw = Workspace:GetAttribute("VfxQuality")
    if type(raw) == "string" and Config.Vfx.Tiers[raw] then
        return raw
    end
    return Config.Vfx.DefaultTier
end

-- Convenience accessor: returns the active tier's table.
function Config.Vfx.detail(): {[string]: any}
    return Config.Vfx.Tiers[Config.Vfx.tierFor()] or Config.Vfx.Tiers.high
end

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
    Map3Cols        = 90,     -- Map 3 width in cells (20% bigger than map 2: 75 * 1.20 = 90)
    Map3Rows        = 66,     -- Map 3 depth in cells (20% bigger than map 2: 55 * 1.20 = 66)
    Map3ColOffset   = 135,    -- Map 3 cols start where map 2 ends (Map1Cols + Map2Cols)
    -- Map 4 = Pickle Swamp (Infinite Arena) — same size as map 3.
    Map4Cols        = 90,
    Map4Rows        = 66,
    Map4ColOffset   = 225,    -- map 4 starts where map 3 ends
    -- Total grid spans cols 0..314 across all four maps.
    PathWidthCells  = 4,      -- Path brush extends this many cells on each side of waypoint line
}
Config.Grid.TotalCols = Config.Grid.Map1Cols + Config.Grid.Map2Cols + Config.Grid.Map3Cols + Config.Grid.Map4Cols  -- 315

-- ===========================================================================
-- DEV — flags that gate dev-conveniences. Flip to false before shipping
-- to production so the auto-enable codepaths don't bypass real progression.
-- ===========================================================================
-- ⚠️ Currently UNUSED at runtime. Kept as scaffolding for the
--    "require real boss defeats for portal unlock" workflow — wire
--    the gating up in HubWorld portal setup if you bring it back.
Config.Dev = {
    -- All inter-map portals (map 1→2, map 2→3) auto-enable a couple seconds
    -- after server boot so the dev panel + teleport flow can reach later
    -- maps without killing each map boss first. Disable to require real
    -- boss defeats — useful for playtesting end-to-end progression.
    AutoEnablePortals = true,
}

-- ===========================================================================
-- WAVES — wave pacing and count
-- ===========================================================================
Config.Waves = {
    PerStage                    = 5,      -- waves 1..5 per stage
    TotalStages                 = 3,      -- stage 1, 2, 3, then boss
    UpgradePickToNextWaveDelay  = 10,     -- max seconds the upgrade picker stays open before wave N+1 auto-starts; picking starts the wave immediately
    StageContinueAutoDelay      = 6,      -- seconds before stage-clear modal auto-continues
    WaveClearedPollInterval     = 0.25,   -- how often to poll "are all mobs dead?"
    MaxRerollsPerStage          = 2,      -- free upgrade rerolls per stage
}

-- ===========================================================================
-- TOWERS — defaults and constraints
-- ⚠️ Currently UNUSED at runtime. Kept as a future hook for
--    explicit per-player tower-count + placement-range gating; today
--    those limits are inherent to the auto-place algorithm (max
--    slots in INFINITE_PATTERN) and the click-raycast distance
--    instead. Wire if you ever need a hard cap.
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

    -- Stage unlock fractions. Halved per Matthew's "doesn't get out of
    -- view too fast" feedback (was 0.05/0.25/0.60/1.00).
    StageUnlockFractions = {
        [1] = 0.025,
        [2] = 0.125,
        [3] = 0.30,
        [4] = 0.50,
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
        WebAttackIntervalSec = 20,   -- seconds between web attacks
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
    -- The Canopy Bird (map 3 final boss). See systems/Map3BirdBoss.lua.
    -- All `*Sec` fields are GAME-time seconds (advance with gameSpeed via
    -- GameTime.adaptiveWait); `*StudsPerSec` are per-second movement speeds
    -- that the flight loop scales by gameSpeed on tick. Wallclock-only fields
    -- are explicitly suffixed Wallclock.
    CanopyBird = {
        -- Combat / lifecycle
        BirdMaxHp           = 120000,  -- bird body Health (and MaxHealth) at spawn (2026-04-29 ea: 150000 → 120000)
        SwoopIntervalSec    = 30,      -- game-seconds between swoop attempts
        ClicksToRelease     = 10,      -- per-grab tap count to escape carry
        DazeGameSec         = 3,       -- post-drop "stun" window where bird is vulnerable
        PhaseHardCapWallclockSec = 5 * 60, -- absolute wallclock ceiling so eggs can't run forever
        -- Flight speeds (studs/sec at 1× game speed; flight loop multiplies by gs)
        DiveStudsPerSec     = 17.6,    -- 10% faster than default Humanoid.WalkSpeed
        CarryStudsPerSec    = 8,       -- slow ascent so player has time to tap-out
        HoverStudsPerSec    = 12,      -- patrol drift speed
        -- Hover positioning
        HoverHeightOffsetY  = 30,      -- studs above arena floor
        HoverPatrolRadius   = 60,      -- studs around arena center
        HoverPatrolRepickGameSec = 6,  -- how often hover picks a new drift target

        -- Eggs (path mobs spawned during the bird phase)
        EggIntervalGameSec  = 2.5,     -- spawn one egg every N game-seconds
        EggBaseHp           = 27,      -- HP at phase start
        EggFinalHp          = 90000,   -- HP at PhaseHardCap (linear ramp) (2026-04-29 ea: 100000 → 90000, -10%)
        EggBaseSize         = 1.2,     -- studs at phase start (tiny)
        EggFinalSize        = 12.0,    -- studs at PhaseHardCap (10× ramp)
        EggSafetyDestroyWallclockSec = 300, -- hard-destroy any egg older than this (path-stuck guard)
    },
    -- Map 3 heart HP (map 3 has its own heart, sized to absorb 3 partially-
    -- damaged late-game egg hits — see Map3.lua).
    HeartMaxHp = 50000,
    -- The Pickle Lord — RUN BOSS that follows the Canopy Bird on map 3.
    -- Triggered by BossRewardClaimed mapId=3 (i.e. AFTER the player picks
    -- their map-3 temp-tower reward). On HP=0 the chain hands off to the
    -- permanent-tower picker, which on claim ends the run with VICTORY.
    -- Lives on map 3 — no map switch. He's so tall ("as tall as the entire
    -- tree") that only the head + shoulders are visible above the platform
    -- edge. See systems/PickleLordBoss.lua and docs/pickle-lord-spec.md.
    PickleLord = {
        Hp                          = 500000,
        SmashIntervalGameSec        = 20,    -- game-seconds between smash attempts
        SmashRadiusStuds            = 22,    -- ~10% smaller than 24 per playtest (was 32, before that 40); shrinks the danger footprint
        -- Per playtest 2026-04-26: towers temporarily invulnerable
        -- to smash so the rest of the fight can be tuned without
        -- losing range / damage every time the smash lands. Smash
        -- visuals still play (disc + outline + aurora + green
        -- flames on the towers) but the actual destruction +
        -- stock-restore is short-circuited. Flip to false once the
        -- fight pacing is locked in.
        TowerInvulnerableToSmash    = true,
        -- Per playtest: smash window 2.0s (was 1.5s — extra 0.5s of
        -- grace before the disc explodes). SmashReactionSec is a noop
        -- in code (only used in a debug payload field).
        SmashTotalSec               = 2.0,
        SmashReactionSec            = 2.0,
        RangeDecayIntervalGameSec   = 30,    -- game-seconds between RangeDecayMultiplier ticks
        RangeDecayFirstTickGameSec  = 60,    -- delay before the FIRST decay (player gets a clean 1-min window before range starts shrinking)
        RangeDecayMultiplier        = 0.95,  -- 5% per tick (was 10%) — gentler ramp; multiplicative, NO floor
        EntranceCinematicWallclockSec = 5,   -- wallclock for the entrance lighting tween (moonlit + foggy)
        -- Smash sequence pacing (post-rise). The boss does NOT smash
        -- instantly — he ramps his eye glow up over EyeGlowRampSec while
        -- slowly rotating to face the target at SmashRotationRadPerSec
        -- (very slow per the 2026-04-25 spec). Cones + smash circle
        -- spawn ONLY when the body finishes rotating; if the rotation
        -- needed is small, beams come out early; if the body's already
        -- facing the target, beams come out immediately. After beams
        -- appear, the standard SmashTotalSec resolve-clock runs.
        SmashRotationRadPerSec      = 0.35,  -- ~20 deg/sec — slow turret pivot
        EyeGlowRampSec              = 3.0,   -- wallclock for PointLight Brightness 0 → 3
        -- Visual tuning — pickle palette
        BodyColor                   = Color3.fromRGB(60, 110, 50),
        ShardColor                  = Color3.fromRGB(120, 230, 80),
        SmashCircleColor            = Color3.fromRGB(120, 230, 80),
        MoonlightAmbient            = Color3.fromRGB(70, 90, 130),
        FogEnd                      = 200,
        -- Geometry — tall green block positioned just OFF the platform edge so
        -- only the upper portion (head + shoulders) is visible from the
        -- player's vantage. Body sits below the platform; the visible upper
        -- chunk is BodyVisibleHeight tall. Per playtest 2026-04-25: original
        -- (visible 30, offset 90) put the head BURIED in the canopy leaves
        -- AND pushed the boss far past the back edge (24 stud past Map3's
        -- 132-deep arena, half-hidden in dark void). New values raise the
        -- head well above the canopy (canopy tops out around +45 above
        -- platform Y) and pull him closer to the edge so the silhouette
        -- reads from anywhere on the platform.
        BodyWidth                   = 62,    -- 2× the previous size per playtest — gigantic looming pickle
        BodyDepth                   = 52,
        BodyTotalHeight             = 440,
        BodyVisibleHeight           = 95,    -- portion above the platform edge — 5 stud taller per playtest
        BodyOffsetFromCenter        = 100,   -- studs back from arena center — pulled 5 further from the platform per playtest
        -- Slow-rise entrance: body starts BELOW its final Y by RiseDistance
        -- and tweens up over RiseSec wallclock so the boss appears to
        -- emerge slowly from below the platform / void. RiseSec matches
        -- CinematicWallclockSec so the boss is STILL RISING during the
        -- entire camera sequence (every boss-closeup shot catches him
        -- in motion).
        RiseDistance                = 95,    -- studs of vertical travel during the entrance rise
        RiseSec                     = 24.5,  -- wallclock seconds for the rise — matches cinematic length
        -- Cinematic phase schedule (client-side; see init.client.lua's
        -- PlayPickleLordEntrance handler for the per-phase shot
        -- definitions). Total = 24.5 wallclock seconds; click to skip.
        -- Phase boundaries: 0/9/12/16/17.5/20/22.5/24.5 — zoom-in
        -- shortened 1s, every closeup +0.5s, zoom-out +1s.
        CinematicWallclockSec       = 24.5,
        -- Underlight: green SpotLight aimed up from below the boss's
        -- feet — illuminates the body / face from underneath. (Was
        -- "ClubLight" briefly when an in-hand club concept was in
        -- play; the club was scrapped in favor of the eye-cone smash
        -- telegraph, the underlight stayed.)
        UnderlightBrightness        = 25,    -- punchy enough to read at distance through foliage
        UnderlightRange             = 160,   -- generous so the cone reaches the top of the (now-doubled-height) visible body
        -- Mini pickle adds. Spawn from EnemySpawnMap3 and walk the
        -- standard EnemyPath toward the heart, same as Canopy Bird's
        -- eggs — but bespoke (model + walker) since they need
        -- animated legs. ALL minis share the same HP regardless of
        -- when they spawn — the danger comes from the shrinking
        -- tower-range decay, not from minis ramping in HP.
        MiniHp                      = 7000,   -- shared across every mini, no ramping; tuned through 800 → 3200 → 32000 → 15000 → 11000 → 8000 → 7000 across playtests
        MiniBodyHeight              = 5,      -- studs — visible pickle silhouette
        MiniBodyWidth               = 3,      -- studs — slightly thinner than tall
        MiniLegLengthStuds          = 1.6,    -- length of each box leg below the body
        MiniLegThicknessStuds       = 0.6,    -- leg thickness (square cross-section)
        MiniLegSwingDeg             = 35,     -- ± peak angle for the walking-legs sine swing
        MiniLegSwingHz              = 2.6,    -- swing oscillations per second
        MiniMoveSpeedStud           = 7,      -- stud/s along the path
        MiniSpawnIntervalGameSec    = 4.0,    -- game-seconds between spawns
        MiniFirstSpawnDelayGameSec  = 5.0,    -- delay after rise so player has a beat to take stock before the first mini arrives (was 2.0)
        MiniSafetyDestroyWallclockSec = 240,  -- self-destruct guard if path walk hangs
        -- Cinematic environment crumble: radius (XZ-cylinder) within which
        -- decorative Map3* parts get unanchored + tumbled + Destroyed
        -- as the boss arrives. Tight enough to not strip his half of the
        -- arena; wide enough to clear bushes nestled at his base.
        CrumbleRadius             = 50,
    },
    -- Difficulty multipliers — same shape as Config.Map2.Difficulty. Map 3
    -- is the late-run map: by the time the player arrives they've collected
    -- TWO aux towers (one from map 1 boss, one from map 2 boss) and have
    -- accumulated ~24 picks across Core + aux baselines. Their firepower
    -- is meaningfully higher than at any point in map 2, so HP needs to
    -- jump in step.
    --
    -- Sizing: stage 1 wave 1 basic HP must be >= map 2 stage 3 wave 5
    -- (currently 452) plus ~+50% to compensate for the second aux tower.
    -- HpMult 18 × stage-bump 1.30 = 23.4 effective on stage 1 → basic at
    -- W1 = 702 (~1.55× map 2's S3W5). Stage curve mirrors map 2 (1.30 /
    -- 1.25 / 1.10) — the early-stage cliff is where the new map feels
    -- hardest; by stage 3 the player's build has caught up.
    Difficulty = {
        HpMult         = 18.0,  -- baseline; stacked with HpMultByStage
        HpMultByStage  = { [1] = 1.30, [2] = 1.25, [3] = 1.10 },
        SpeedMult      = 1.30,
        SpawnCountMult = 1.40,
        -- Stage bosses on map 3 use the explicit Config.BossHp.StageByMap[3]
        -- override table (100k / 150k / 220k), so BossHpMult here is
        -- effectively unused — left in for parity with map 2's struct.
        BossHpMult     = 12,
        -- Per-stage-per-wave HP adjustments. Applied as a multiplier
        -- on top of the existing waveMult × stageMult × HpMult chain
        -- in TreeOfLife_WaveSystem's runWave. Per Matthew 2026-04-28
        -- dv playtest:
        --   Stage 2 (Afternoon, web/spider): waves 4-5 too hard
        --   Stage 3 (Dusk): waves 3-5 lean too hard
        --   Stage 4 (Night, bird boss): waves 4-5 same shape
        -- Mults below = (1 - reduction). 0.97 = -3% HP.
        WaveHpAdjust = {
            [2] = { [4] = 0.97, [5] = 0.95 },
            [3] = { [3] = 0.97, [4] = 0.95, [5] = 0.92 },
            [4] = { [4] = 0.97, [5] = 0.95 },
        },
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
        -- Map 1 ANOTHER 10% cut on top of the v5.11 playtest cut
        -- (2026-04-27): 850→765, 3150→2835, 6300→5670. Map 1 felt
        -- too tanky for the early-run pacing.
        [1] = { [1] = 765,   [2] = 2835,   [3] = 5670   },  -- Crook
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

-- ===========================================================================
-- MAP 4 — Pickle Swamp (Infinite Arena, Phase 1 balance/benchmark
-- sandbox per project_infinite_arena.md). Swamp terrain with a green
-- slime river, rickety bridges, a mini volcano oozing slime, drifting
-- steam clouds, and pickle-fruit trees that light the map. Not part
-- of the main run loop — entered via the hub's swirling green portal.
-- ===========================================================================
Config.Map4 = {
    -- Heart HP — sized to absorb many waves of mob damage during
    -- balance testing. Trimmed 2026-04-27: 80k → 50k → 40k. Lower
    -- pool tightens the failure window — partial wave-clear scores
    -- are more sensitive to leaks now (smaller heart = fewer leaks
    -- before death).
    HeartMaxHp = 40000,
    -- Difficulty mults for the custom infinite-wave spawner. Each
    -- "round" the spawner ramps these against the previous round so
    -- benchmark scenarios scale until failure. See systems/Infinite.lua
    -- (B2d follow-up) for how these get applied.
    Difficulty = {
        -- Initial multipliers (round 1 = 1.0; the spawner re-reads
        -- these per round and applies its own ramp on top).
        -- Static baseline applied alongside HpPerRound. Tuned per
        -- Matthew 2026-04-26: "tighten the window though. so wave
        -- 5 should be 10 wave 30 should be 100". Solving the
        -- geometric ramp:
        --   wave-5 hpMult  = HpMult × HpPerRound^4  = 10
        --   wave-30 hpMult = HpMult × HpPerRound^29 = 100
        -- Ratio gives HpPerRound^25 = 10 → HpPerRound = 10^(1/25)
        -- ≈ 1.0959. Static multiplier HpMult = 10 / 1.0959^4 ≈ 7.
        -- SequenceBonus disabled (= 1.0) so the ramp shape is
        -- pure geometric.
        -- Linear HP ramp: hpMult = HpMult + wave × HpRampSlope.
        --
        -- Tuning (2026-04-26): "duo failing way too late. remove 9
        -- waves." Bumped HpMult 21.5 → 35 — wave 1 now starts where
        -- old wave 17 was. Total shift from baseline: 16 waves cut
        -- off the front so duos / trios face a meaningful curve from
        -- wave 1 instead of cruising for ~15 rounds.
        --   Wave 1  hpMult = 35 + 1×1.5  = 36.5
        --   Wave 5  hpMult = 35 + 5×1.5  = 42.5
        --   Wave 10 hpMult = 35 + 10×1.5 = 50.0
        --   Wave 15 hpMult = 35 + 15×1.5 = 57.5
        --   Wave 30 hpMult = 35 + 30×1.5 = 80.0
        -- Slider × baseline: solo 1.25, duo 1.5, trio 1.75 — so
        -- wave-10 hpMult per loadout: solo 62.5, duo 75.0, trio 87.5.
        HpMult         = 35.0,
        HpRampSlope    = 1.5,
        SpeedMult      = 1.0,
        SpawnCountMult = 1.0,
        CountPerRound  = 1.05,
        IntervalSec    = 12,  -- inter-wave gap; bumped 8 → 12 per Matthew 2026-04-27 ("a little more time between the waves")
        -- EXTRA pause inserted between specific wave-type transitions.
        -- Layered ON TOP of IntervalSec / mob-clear wait — the gap is
        -- at minimum IntervalSec + this.
        --
        -- PreCombinedExtraSec: extra wait when the NEXT wave is
        -- Combined (i.e. between AOE and Combined). +3s per Matthew
        -- 2026-04-27. Lets towers recover ammo before the harder
        -- mixed wave.
        --
        -- PreBossExtraSec: extra wait when the NEXT wave is Boss
        -- (Solo). 8 → 13 per Matthew 2026-04-27 (+5s). Combined→Boss
        -- is the harshest cycle transition; players need the longest
        -- breather to brace for the tank.
        PreCombinedExtraSec = 3,
        PreBossExtraSec     = 13,
        -- Legacy geometric-ramp fields kept for back-compat (some
        -- tests may read them) but no longer used by the live
        -- spawner formula.
        HpPerRound     = 1.0,
        SequenceBonus  = 1.0,
        HpRampOffset   = 0,
    },
    Volcano = {
        -- Visual + lazy-VFX tunables for the mini slime volcano.
        OozeIntervalSec  = 1.2,    -- gap between slime-drip particle bursts
        SmokeRate        = 12,     -- particles/sec
    },
    SteamClouds = {
        Count            = 36,     -- how many drifting steam puffs to spawn
        BobAmplitudeStud = 1.5,    -- vertical bob distance
        BobPeriodSec     = 4.0,    -- bob cycle
    },
    PickleTrees = {
        Count            = 14,     -- how many pickle-fruit trees around the perimeter
        FruitsPerTree    = 4,      -- pickle-fruit lights per tree
        FruitLightRange  = 22,     -- studs of point-light reach per fruit
    },
}

-- ===========================================================================
-- INFINITE ARENA — Balance-studio sweep tuning (Map 4)
--
-- Single source of truth for every tunable that BOTH the live
-- spawner (server/systems/Infinite.lua) AND the closed-form
-- simulator (server/systems/InfiniteSimulator.lua) consume. Per
-- Matthew 2026-04-27: keeping these duplicated as literals across
-- two files was THE source of sim/real divergence — every tuning
-- pass had to be applied twice and forgetting one half silently
-- shifted the validation deltas.
-- ===========================================================================
Config.InfiniteArena = {
    -- Sweep cap: a loadout that survives this many waves auto-
    -- promotes to S-tier. Cap exists so a broken combo doesn't
    -- stall the queue indefinitely.
    --
    -- 30 → 28 (2026-04-27 Matthew "Stop after 28") — concurrent
    -- with the steeper WaveHpRamp landing in this same edit; W28
    -- HP mult is now 11.70× (was 2.8× under the legacy cycle
    -- formula at W28-30), so any loadout that survives W28 has
    -- earned an S regardless of where the cap sits.
    MaxAutoRunWave = 28,

    -- LEGACY cycle-step constant. Used by the simulator's
    -- per-wave upgrade counter (cycle = ceil(wave/3); upgrades =
    -- cycle - 1). HP scaling is no longer driven by this — see
    -- WaveHpRamp below.
    CycleStep = 0.2,

    -- WAVE HP RAMP — piecewise function mapping wave number → HP
    -- multiplier on the per-mob baseline. Applied as
    --   finalHp = baseHp × hpMult × WaveHpRamp(wave) × loadoutMult
    -- by both the live spawner (Infinite.lua wave loop) AND the
    -- closed-form simulator (InfiniteSimulator.simulateWave). DO
    -- NOT add a duplicate ramp constant in either consumer (per
    -- CLAUDE.md convention 7 — single source of truth for sweep
    -- tuning). Tuning here propagates to both sides automatically.
    --
    -- Per Matthew 2026-04-27: "increase hp ramp rate for waves
    -- 10,11,12; again for 13,14,15, then again for 16-21, then
    -- again 22-28. Stop after 28."
    --
    -- W1-9 keep the legacy piecewise-CONSTANT cycle bands so
    -- early-game softball stays the same:
    --     W1-3: 1.0    W4-6: 1.2    W7-9: 1.4
    -- W10+ switches to piecewise-LINEAR with steeper slopes per
    -- band — each plateau ramps faster than the prior.
    --
    -- W10-12 SLOPE 0.30 → 0.20 (2026-04-27 follow-up): first
    -- sweep on build au with slope 0.30 saw ~28 of 45 loadouts
    -- cluster on the W12 boss (12.8-12.97) — too narrow a spread
    -- to compare bottom-of-slate combos. Softening W10-12 to
    -- 0.20/wave (= same step the legacy formula used for
    -- W4-9) lets weaker combos die at W11/W12 boss while
    -- stronger combos punch through to W13-15. Downstream
    -- anchors (W12, W15, W21, W28) all shifted accordingly.
    --
    --     W10-12: slope 0.20/wave  (anchored at W9 = 1.40)
    --       W10=1.60  W11=1.80  W12=2.00
    --     W13-15: slope 0.40/wave  (anchored at W12 = 2.00)
    --       W13=2.40  W14=2.80  W15=3.20
    --     W16-21: slope 0.55/wave  (anchored at W15 = 3.20)
    --       W16=3.75  W17=4.30  W18=4.85  W19=5.40  W20=5.95  W21=6.50
    --     W22-28: slope 0.70/wave  (anchored at W21 = 6.50)
    --       W22=7.20  W23=7.90  W24=8.60  W25=9.30  W26=10.00  W27=10.70  W28=11.40
    -- W29+ pinned at the W28 value so any out-of-bounds query
    -- (defensive caller, sim, dev tools) doesn't return nil.
    WaveHpRamp = function(wave: number): number
        if wave <= 3  then return 1.0
        elseif wave <= 6  then return 1.2
        elseif wave <= 9  then return 1.4
        elseif wave <= 12 then return 1.40 + (wave -  9) * 0.20
        elseif wave <= 15 then return 2.00 + (wave - 12) * 0.40
        elseif wave <= 21 then return 3.20 + (wave - 15) * 0.55
        elseif wave <= 28 then return 6.50 + (wave - 21) * 0.70
        else                  return 11.40
        end
    end,

    -- Loadout difficulty multipliers — applied as a flat scalar on
    -- top of cycleMult. Indexed by aux count (1=solo, 2=duo, 3=trio).
    --
    -- 2026-04-28 dm: trio mult 1.60 → 1.45 per Matthew "triple is
    -- overtuned." dl ControlCore sweep showed all 12 top trios
    -- clustering at 9.28-9.93 wave (vs duo top 15.78), a 5.8-wave
    -- cliff from best-duo to best-trio. The wave-9-Boss wall was
    -- too steep — every trio ate the same HP scaling regardless
    -- of composition. Drops trio HP penalty by ~9%; should let the
    -- best trios push to ~11-12 wave, narrowing the gap to duo
    -- without inverting it (trio still harder than duo, just not
    -- catastrophically so).
    LoadoutMult = {
        [1] = 1.0,
        [2] = 1.25,
        [3] = 1.45,
    },

    -- Cycle-1 HP pools per wave type. Mobs split the pool by their
    -- count + type-mix ratio (basic:fast:tank = 4:3:10). Subsequent
    -- cycles scale via cycleMult × loadoutMult.
    --
    -- Tuning history per Matthew 2026-04-27:
    --   1. Solo W3 7000 → 6500 (early-cycle softener)
    --   2. -10/-10/-5% cut attempted → reverted (Frost+Power runaway)
    --   3. +5% across all three (current): 4000 → 4200, 5000 → 5250,
    --      6500 → 6825 — propagates via cycleMult to all later cycles
    --      of each type. Tightens the bottom-tier loadout's runway.
    Pools_C1 = {
        AOE      = 4200,
        Combined = 5250,
        Solo     = 6825,
    },

    -- Per-mob HP overrides that subtract from the default pool-split.
    -- These are subtracted from the cycle-1 BASE HP for the mob in
    -- that wave and then propagated through cycleMult × loadoutMult
    -- automatically (since the spawner just multiplies the base HP).
    --
    -- Per Matthew 2026-04-27: "remove 250 hp from both wave 2 tanks
    -- and 500hp from wave 3 tank and propogate the change with the
    -- multipliers." Combined wave's tank: 2083.33 → 1833.33 base.
    -- Solo wave's tank: 6500 → 6000 base. Subsequent cycles still
    -- scale: cycle 5 trio Solo tank = 6000 × 1.8 × 1.6 = 17280.
    Pools_C1_TankHpDelta = {
        Combined = -250,
        Solo     = -500,
    },

    -- Per-cycle upgrade deltas applied after every Solo wave (every
    -- 3rd wave). Range caps at 2× original; once capped, damage and
    -- firerate effects boost by PostCapBoost instead.
    Upgrade = {
        DamageFlat   = 3,
        FireRateMult = 0.15,    -- multiplied by (1 + this) per cycle
        RangeMult    = 0.15,    -- multiplied by (1 + this) per cycle until cap
        RangeCapMult = 2.0,     -- range stops growing at base × this
        PostCapBoost = 1.5,     -- post-cap, dmg/fr deltas multiplied by this
    },

    -- Mob baselines (mirrors WaveData.MOB_TYPES). Used by the
    -- simulator's path-traversal math; the live spawner reads from
    -- the real WaveData on the server.
    MobBaseline = {
        basic = { speed = 8.8,  baseHp = 30 },
        fast  = { speed = 15.4, baseHp = 18 },
        tank  = { speed = 5.5,  baseHp = 90 },
    },

    -- Anchor for trio queue items — the standardization tower that
    -- holds the third slot so the test pair is what's varied.
    AutoRunAnchor = "InfiniteStandard",

    -- LONG AUTO curated trio list — 3-aux combinations the LONG
    -- AUTO button sweeps. Per Matthew 2026-04-27: "switch to option
    -- B with a curated 3-aux list (don't need all 84 — pick the
    -- ones where 2-tower data shows ambiguity)."
    --
    -- Curation principles:
    --   • Pair B-tier DPS (Acorn / Lightning / Thorn) with strong
    --     Control (Frost / Root) + AOE anchor (Pepper / Mushroom)
    --     to test if synergy unlocks them past their 2-tower band.
    --   • Pair lower-tier Control (Spore / Honey) with two strong
    --     DPS to test "is the Control adding value or dragging?"
    --   • Test multi-Control combos (Frost + Root + AOE) for
    --     stack-overlap behavior.
    --   • Test pure-DPS triple (Acorn + Lightning + Thorn) as a
    --     control case — no Control synergy, just additive damage.
    --
    -- Edit / extend freely — the LONG AUTO sweep just iterates
    -- this list. Default 12 trios = ~10-30 min sweep at 10×.
    LongAutoTrios = {
        { "AcornSniper",     "FrostMelon",      "PepperCannon"   },
        { "AcornSniper",     "FrostMelon",      "MushroomMortar" },
        { "LightningRadish", "FrostMelon",      "PepperCannon"   },
        { "LightningRadish", "RootSprout",      "PepperCannon"   },
        { "ThornVine",       "FrostMelon",      "PepperCannon"   },
        { "ThornVine",       "RootSprout",      "MushroomMortar" },
        { "SporePuffball",   "PepperCannon",    "MushroomMortar" },
        { "SporePuffball",   "FrostMelon",      "PepperCannon"   },
        { "HoneyHive",       "PepperCannon",    "MushroomMortar" },
        { "HoneyHive",       "RootSprout",      "PepperCannon"   },
        { "RootSprout",      "FrostMelon",      "MushroomMortar" },
        { "AcornSniper",     "LightningRadish", "ThornVine"      },
    },

    -- Default Power Core stats used by the simulator when computing
    -- baseline DPS (the real Power tower lives in TowerTypes; this
    -- mirror is intentional since the simulator doesn't load Roblox
    -- TowerType definitions).
    PowerCoreStats = { damage = 50, fireRate = 0.7, range = 24 },

    -- Sim-side calibration knobs (InfiniteSimulator.lua reads these).
    -- Tweak from one place per CLAUDE.md convention 7 ("single source
    -- of truth for sweep tuning") — both sim and live spawner pick
    -- up changes here without touching either source file.
    SimCalibration = {
        -- LOB CATCH MULT: when a lob's math says "catches target"
        -- (mob_move < splash), apply this mult to account for real-
        -- game misses the closed-form sim can't model (target re-aim,
        -- mob waypoint turn mid-flight, mob already-dead, lob spread
        -- variance). Tuning history per Matthew 2026-04-27:
        --   v1: 0.5 — brought Mushroom sim solo from wave 26 to ~17
        --             vs real ~9.0 (+8 still too high)
        --   v2: 0.3 — Matthew "in real gameplay, a lot of the
        --             mushroom mortar shots miss" — sim must model
        --             that. Cuts Mushroom catch damage another 40%
        --             toward closing the +8 wave gap. Should bring
        --             Mushroom sim closer to ~10-11 (real 9.0).
        --   v3: 0.5 (2026-04-28 di) — v2's calibration was tuned
        --             to real Mushroom ~9.0, but real has since
        --             climbed to ~12.26 after iterative tuning,
        --             leaving sim under-predicting by 4.5 wave
        --             (the worst residual in the validator report).
        --             Bumping back to 0.5 lifts sim toward real;
        --             paired with the di lobSeconds 2.0→2.2 +
        --             blastRadius 11→10 template trim that drops
        --             real Mushroom to ~11.0-11.5 estimate. Both
        --             changes converge sim and real toward the
        --             middle.
        --   v4: 0.85 (2026-04-29 ea3-6) — ea3 SUPER AUTO validator
        --             still showed Mortar with the worst per-tower
        --             residual across all 3 Cores: signed −3.96
        --             (Power), −4.33 (Control), −4.76 (Support).
        --             Other splash towers (PepperCannon −0.25 to
        --             −0.40) calibrate cleanly, so this is
        --             specifically lob-catch math under-crediting
        --             the live game's catch rate. +70% mult should
        --             lift Mortar's sim contribution from
        --             ~9.0-9.4 to ~12-13, closing the gap toward
        --             real ~13.21 cumulative.
        LobCatchBaseMult = 0.85,
        -- LOB MISS CLUSTER FLOOR: when lob misses primary
        -- (mob_move >= splash), the splash MIGHT catch trailing
        -- cluster mobs. Floors by wave type — AOE has tight cluster,
        -- Combined moderate, Solo single-target → no cluster.
        -- Tightened in same pass as LobCatchBaseMult v2 since real
        -- Mushroom misses also fail to catch trailing mobs as
        -- reliably as sim assumed.
        LobMissClusterFloor = { AOE = 0.20, Combined = 0.10, Solo = 0.0 },
        -- SLOW FACTOR CAP: max effective slow factor in the sim's
        -- closed-form transit-multiplier formula. With per-source
        -- slow now max ~0.55 (Honey patch), 0.7 cap is mostly
        -- defensive — leftover from the 0.40+ slowPct era.
        SlowFactorCap = 0.7,
        -- STACKING SLOW CAP HEURISTIC: when a tower uses stacking
        -- slow (FrostMelon's slowStackPct/slowStackCap) the sim
        -- approximates the time-averaged slow as
        --   effective_slowPct = slowStackCap × StackingSlowEffectiveness
        -- Tuning history per Matthew 2026-04-27:
        --   v1: 0.5 — first heuristic. Frost sim signed Δ = -1.73.
        --   v2: 0.65 → -1.89.
        --   v3: 0.85 → -2.20.
        --   v4: 0.95 → mid-sweep partial showed Frost+CC at +4.59
        --              vs sim. The slow-DOT compounding with CC
        --              still under-modeled.
        --   v5: 1.15 — over-corrected. Pepper sim flipped to
        --              over-predict (+0.68 signed, was -0.15)
        --              suggesting 1.15 was past the calibrated
        --              band for slow-anchored DPS combos.
        --   v6: 0.95 — pulled back. Mid-bz sweep showed
        --              Pepper +0.68, Mushroom +0.11, both over.
        --              0.95 should land Pepper closer to ±0 while
        --              keeping Frost calibration intact.
        --   v7: 1.05 (2026-04-28 dl) — di sweep showed Frost
        --              residual -0.95/-0.76 (sim under-predicts by
        --              ~0.8 wave). +10% lift to close the gap.
        --              Pepper's recent residual was small enough
        --              that the slight side-effect on
        --              slow-anchored DPS combos is acceptable.
        StackingSlowEffectiveness = 1.05,
        -- DOT VALUE MULT: SporePuffball/HoneyHive cloud-DOT
        -- contribution multiplier. Real game's cloud is dropped on
        -- a SPOT — mob walks through, cloud doesn't follow. Sim's
        -- closed-form `dotTickDmg × tickPerSec × dotSeconds`
        -- assumes full mob-in-cloud time which over-predicts when
        -- the mob walks past the drop point. Spore signed Δ went
        -- from +0.78 (cloudTickDmg=4) to +1.66 (cloudTickDmg=6,
        -- 20× sweep) — sim picks up the buff too generously.
        -- 0.7 = ~30% discount on the closed-form DOT damage.
        DotValueMult = 0.7,
        -- STUN VALUE MULT: lift the sim's stun contribution to
        -- account for compounding effects the closed-form misses
        -- (mob freezes in range so subsequent ticks see it longer,
        -- focus-fire damage during stun, etc.).
        -- Tuning history per Matthew 2026-04-27:
        --   v1: 1.5 — closed ~60% of the original RootSprout gap.
        --   v2: 2.2 — bv mid-sweep showed Root+CC at
        --              +4.08 vs sim. CC's DOT stacks during stun
        --              freeze (mob can't escape, eats both DOT and
        --              direct fire continuously) — compounding
        --              effect was under-counted. 2.2× should close
        --              most of the residual gap.
        --   v3: 2.4 (2026-04-28 dl) — di sweep showed RootSprout
        --              residual -0.98/-0.95 (sim still
        --              under-predicting stun by ~1 wave). +9% bump
        --              to lift Root toward parity. Conservative
        --              vs other Control knobs since stun's compound
        --              effect already at 2.2× is the largest mult.
        StunValueMult = 2.4,
        -- STACK DOT EFFECTIVENESS: mult on the closed-form
        -- stacking-DOT contribution (ControlCore mechanic). The
        -- exposure-aware ramp model already captures the Solo /
        -- Combined / AOE asymmetry via per-mob exposure; this
        -- knob is the single-axis calibration for any remaining
        -- gap (e.g. "real game targets ALWAYS swap to a fresh
        -- mob mid-fight, restarting stacks" effects the sim
        -- assumes only happen at mob death).
        --
        -- Tuning history per Matthew 2026-04-27:
        --   v1: 1.0 — first calibration with the new model. 10×
        --             ControlCore sweep showed sim still
        --             under-predicting overall by ~1.4 waves.
        --   v2: 1.2 (current) — bump to close the residual gap.
        --             Real game's targeting-priority and mob-death
        --             stack-carryover effects deliver more DOT
        --             damage than the closed-form's "fresh mob
        --             starts at stack 1" assumption predicts.
        StackDotEffectiveness = 1.2,
        -- AURA VALUE MULT: mult on the closed-form aura buff
        -- contribution (SupportCore mechanic). 1.0 = trust the
        -- model; the sim applies a flat (1 + dmgPct/100) ×
        -- (1 + frPct/100) DPS lift to every non-Support tower
        -- in the loadout. Tunable if real game's aura activation
        -- timing or tower-placement-radius bias makes the flat
        -- multiplier too generous / stingy.
        --
        -- Tuning history:
        --   v1: 1.0 — first calibration. SupportCore-anchored
        --             117-run sweep (2026-04-28) showed median |Δ|
        --             1.66 with sim PESSIMISTIC (signed -1.66) on
        --             Support combos. Closed-form's flat dpsLift
        --             under-counts the compound effect of range
        --             buff propagation through per-tower exposure
        --             time on path.
        --   v2: 1.15 — +15% to close the SupportCore gap. Target:
        --             pull median |Δ| to ~1.3 on Support anchor
        --             without over-inflating PowerCore (where median
        --             already lands at 0.21 — buffer in the model is
        --             small, so 1.15 is conservative).
        --   v3: 1.45 (2026-04-29 ea3-6) — Build ea bumped Support's
        --             aura 10/10 → 15/15 plus stat buffs (damage
        --             4→6, range 18→24, fireRate 0.8→1.0); v2's 1.15
        --             was calibrated against the OLD aura. Post-buff
        --             validator showed SupportCore-anchored signed
        --             −2.71 / median −2.72 — sim under-predicting
        --             Support runs by ~2.7 waves. PepperCannon's
        --             tight residual (−0.28 across all 3 Cores)
        --             confirms the gap is in aura math, not per-
        --             tower DPS. 1.15 → 1.45 (+26%) lifts the
        --             aura's per-tower DPS contribution to match
        --             the new 15/15 buff (1.32× combined uplift on
        --             aux towers vs 1.21× pre-ea). Iterate to ~1.6
        --             if sim still under-predicts Support by >1
        --             wave on the next sweep.
        AuraValueMult = 1.45,
        -- PER-CORE DPS MULT: surgical knob applied to the Core
        -- tower's effective DPS contribution per loadout. Closes
        -- the gap between sim and real on Control / Support
        -- anchors WITHOUT touching aux-tower modeling. The 117-run
        -- 2026-04-28 cross-Core sweep showed:
        --   PowerCore   median |Δ| 0.21 → coefficient 1.00 (no fix)
        --   SupportCore median |Δ| 1.66 → AuraValueMult bump
        --                 (handled above) plus residual 1.05× lift
        --                 on Core's own self-damage contribution
        --   ControlCore median |Δ| 1.46 → 1.13× lift on Core's
        --                 own contribution (covers under-modeled
        --                 stack-DOT carryover physics + multi-mob
        --                 retarget benefit not in closed-form)
        -- Applied in InfiniteSimulator.simulateWave's per-tower
        -- damage loop, ONLY when i == 1 (the Core slot). Aux
        -- towers in slot 2+ ignore this — the model handles them
        -- correctly.
        --
        -- 2026-04-28 dm: ControlCore 1.13 → 1.45. dl ControlCore-
        -- anchored sweep validator showed signed=-3.14 / median=-2.84
        -- — sim under-predicting ControlCore loadouts by ~3 wave
        -- across the board. Per-tower residuals were all -2 to -5
        -- when ControlCore was the Core. Root cause: stacking-DOT
        -- compound effect (DOT softens HP → aux finishers kill faster
        -- than baseline DPS predicts) wasn't captured in the closed
        -- form. Bump from +13% to +45% on Core's contribution should
        -- close the gap. Iterate to ~1.55 if dm sweep still shows
        -- > -1.5 wave residual on Control anchor.
        PerCoreDpsMult = {
            Power       = 1.00,
            SupportCore = 1.05,
            ControlCore = 1.45,
        },
        -- BLINK VALUE MULT: mult on BlinkBerry's transit-extension
        -- contribution (Control mechanic, 2026-04-28). The sim
        -- treats each blink as adding `blinkDistance / mobSpeed`
        -- seconds of transit per blink event.
        -- Tuning history:
        --   v1: 1.0 — first calibration (trust the closed form)
        --   v2: 1.15 (2026-04-28 dl) — di sweep showed BlinkBerry
        --              residual -1.08/-1.17 (sim under-predicts by
        --              ~1.1 wave). +15% bump to lift Blink toward
        --              parity. Real game blinks deliver more
        --              transit value than the closed-form predicts
        --              (de-prioritized mobs eat extra fire-thrower
        --              shots from front-of-path towers; closed-form
        --              treats every shot as same-priority).
        BlinkValueMult = 1.15,
        -- BLINK TRANSIT CAP: ceiling on the BlinkBerry transit
        -- extension as a FRACTION of the base wave transit, so a
        -- trio with multiple Blinks doesn't compound to a runaway
        -- wave-window. 0.5 = a single mob can be slowed by at most
        -- +50% transit time regardless of how many Blinks fire.
        -- Lower = less aggressive ceiling; raise toward 1.0 if
        -- real-game blinks visibly stack longer than the sim
        -- predicts. Was a hardcoded 0.5 magic number in
        -- InfiniteSimulator.lua before 2026-04-28 cleanup.
        BlinkTransitCap = 0.5,
        -- LINK VALUE MULT: mult on BloodlinkVine's effective-DPS
        -- multiplier (Support mechanic, 2026-04-28). The sim's
        -- closed form is `1 + (mobCount - 1) × echoFrac × LINK_VALUE_MULT`,
        -- capped at 2.5×. 1.0 = trust the model; bump if real
        -- game's link compounds more (e.g. echo chains via DOT
        -- ticks producing more echoes than direct hits do).
        LinkValueMult = 1.0,
    },
}

-- ===========================================================================
-- TARGETING — tower target-selection knobs
-- ===========================================================================
Config.Targeting = {
    ClusterRadius = 8,    -- studs; "Center" mode counts mob neighbors within this
}

-- ===========================================================================
-- UPGRADE CARDS — rolling + reroll behavior
-- ===========================================================================
Config.UpgradeCards = {
    -- Baseline range for the auto-pick simulator's "is this tower close to
    -- the per-target range floor?" question when no real towers exist yet.
    BaselineBaseRange = 30,
    -- Max attempts the dev simulator makes per pick to find a non-Common card
    -- before giving up and accepting whatever rolled.
    MaxRerollTries    = 3,
    -- Per-target range floor the simulator aims for. Below this it prefers
    -- range cards over damage on the next pick.
    TargetMinRange    = 50,
}

-- ===========================================================================
-- AMMO — pile pickup mechanics (ammo system currently dormant; constants
-- kept for the "ammo returns" code path).
-- ===========================================================================
Config.Ammo = {
    DefaultMaxCarry        = 15,    -- max ammo packs in inventory
    NearestPickupDistance  = 12,    -- studs; "nearest pile" picks any pile within this
}

-- ===========================================================================
-- EFFECTS — projectile + AOE visual constants
-- ===========================================================================
Config.Effects = {
    ShrapnelCount = 8,    -- shrapnel particles per Detonator burst
}

-- ===========================================================================
-- DIFFICULTY — run-level multiplier hook for future difficulty tiers
-- (roadmap: project_difficulty_levels.md). Currently 1.0 across the
-- board so behavior is unchanged. The future tier UI sets
-- Workspace.RunDifficultyMult at run start; mob HP / spawn count / heart
-- HP read it via GameTime-style helpers and scale accordingly.
-- ===========================================================================
Config.Difficulty = {
    Default = { hp = 1.0, count = 1.0, heartHp = 1.0 },
    -- Future tier table — placeholder values; not yet wired.
    -- Tiers = {
    --     Standard = { hp = 1.0,  count = 1.0,  heartHp = 1.0  },
    --     Hard     = { hp = 1.5,  count = 1.25, heartHp = 0.85 },
    --     Insane   = { hp = 2.5,  count = 1.5,  heartHp = 0.7  },
    -- },
}

-- Freeze recursively so nothing can accidentally mutate config at runtime.
-- Skips tables that are ALREADY frozen — Luau's table.freeze errors on
-- a re-freeze (raised at boot 2026-04-28 when Config.Vfx.Tiers landed
-- with its own table.freeze in the same module). The isfrozen guard
-- makes deepFreeze idempotent so any sub-table can pre-freeze itself
-- without breaking the bottom-of-module sweep.
local function deepFreeze(t: {[any]: any}): {[any]: any}
    if table.isfrozen(t) then return t end
    for _, v in pairs(t) do
        if type(v) == "table" then
            deepFreeze(v)
        end
    end
    return table.freeze(t)
end
deepFreeze(Config)

return Config
