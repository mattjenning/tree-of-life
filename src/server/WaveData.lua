--[[
    WaveData.lua — Pure data module. Holds every balance-adjustable
    gameplay number for the wave loop in one place:

      - WaveConfig: status-effect chances, rerolls, pacing, final-boss
                    minigame thresholds / durations. "Search first when
                    balancing."
      - Stages: per-stage hpMult / speedMult / bossHpMult.
      - WAVES: wave 1-5 definitions (mob spawn groups, per-wave hpMult).
      - MOB_TYPES: HP / speed / color / display-name for every mob the
                   game spawns, including the 3 map bosses (Mold King,
                   Web Weaver, Canopy Bird) and the spiderling.
      - FINAL_BOSS_MAP_NAME: banner text when the map-1 boss spawns.

    WHY THIS MODULE EXISTS:
    These five tables were 205 lines of pure data sitting in the middle
    of TreeOfLife_WaveSystem. Moving them here keeps the orchestrator
    focused on logic (runWave, spawn loop, handlers) and leaves this
    file as the one place to edit when Matthew / Lily want to tune a
    number. Nothing here imports anything gameplay-related; it's just a
    table of frozen configuration.

    USAGE:
      local WaveData = require(script.Parent:WaitForChild("WaveData"))
      local WAVES = WaveData.WAVES
      -- etc.

    All tables are returned as-is (not table.freeze'd) so the orchestrator
    can still publish them onto ctx and systems/ modules can mutate if
    they ever need to. (Today they're read-only by convention.)
]]

local WaveData = {}

------------------------------------------------------------
-- WAVE CONFIG
------------------------------------------------------------
-- All tunable gameplay numbers in one place. Search this section first
-- when balancing. Named WaveConfig (not just Config) because the shared
-- Config module (grid, map2, phoenix) covers its own domain.
WaveData.WaveConfig = {
    -- Fallback status-effect proc chances (per hit). Only used for towers
    -- that predate the per-tower KnockbackChance/StunChance attributes
    -- (baseline chance comes from SPECIAL_EFFECTS.*.chanceBase = 0.05 now).
    stunTriggerChance      = 0.05,
    knockbackTriggerChance = 0.05,
    knockbackSlideTime     = 0.25,  -- seconds for the slide-back animation

    -- Reroll
    maxRerollsPerStage = 1,

    -- Pacing between waves
    upgradePickToNextWaveDelay = 3,    -- seconds after picking before next wave
    waveClearedPollInterval    = 0.3,  -- seconds between activeMobs polls

    -- Stage transitions
    stageContinueAutoDelay = 2.5,      -- seconds before stage clear banner auto-advances (was 6 — 6s was a guess; real playtest showed the banner overstays its welcome)

    -- Final boss minigame: when boss HP crosses a threshold (80/50/25%),
    -- spawn 4 tappable blobs. Tapping all in time PUSHES a new entry to
    -- the player's rolling bonus-damage stack — base ×2 plus per-tap
    -- speed bonus, with each tap's contribution expiring on its own clock.
    -- Phases fire IMMEDIATELY on threshold cross — they overlap freely;
    -- multiple sets of dots can be on screen at once. (Was a queue-and-
    -- drain model; that lost the back-to-back firing race at 10× DPS,
    -- producing 80/30/0% phase fires instead of 80/50/25%.) See
    -- FinalBoss.lua's module header for the full rolling-stack semantics.
    finalBossPhaseThresholds   = {0.80, 0.50, 0.25},
    finalBossTargetsPerPhase   = 4,
    finalBossTargetWindow      = 4,    -- seconds the targets remain tappable
    finalBossBonusDuration     = 5,    -- seconds of bonus damage on success
    finalBossBonusMultiplier   = 2.0,  -- damage multiplier during bonus
    finalBossWindupDuration    = 1.2,  -- boss stops + vibrates before launching spots
    finalBossWebDuration       = 3,    -- seconds the player is webbed on missed phase
}

------------------------------------------------------------
-- STAGES
------------------------------------------------------------
-- Stage hpMult multiplies the per-wave hpMult, so a wave 5 (1.20 base)
-- on stage 3 (3.40 stage mult) → 4.08× mob HP.
-- After clearing stages 1 + 2, the heart heals back to full.
-- After clearing stage 3's regular waves, the FINAL FINAL BOSS spawns
-- (stage 3 boss flag is in the "extra spawn" list below).
-- Stage hpMult and speedMult both scale REGULAR mobs (basic, fast, tank).
-- Stage bosses (Mold King) scale by bossHpMult instead. The final boss
-- (Pickle Lord) ignores all stage mults and has its own hardcoded stats.
--
-- Apr 22 balance pass — wave HP doubled at Day, tripled at Dusk so that
-- a player without attachments can't trivially clear past stage 1.
-- Stage boss HP: Morning = 2000 (×1.333), Day = 4500 (×3.0), Dusk = 7000 (×4.667).
-- Day's bossHpMult is 3.0 exactly = 4500. Dusk uses ratio 7000/1500 to land
-- on exactly 7000.
WaveData.Stages = {
    [1] = { name = "Crook of the Tree (Morning)", hpMult = 1.0,  speedMult = 1.0, bossHpMult = 1.333 },
    [2] = { name = "Crook of the Tree (Day)",     hpMult = 2.10, speedMult = 1.2, bossHpMult = 3.0 },
    [3] = { name = "Crook of the Tree (Dusk)",    hpMult = 3.40, speedMult = 1.3, bossHpMult = 7000/1500 },
}

-- Special name shown when the final boss spawns (after stage 3 waves cleared)
WaveData.FINAL_BOSS_MAP_NAME = "Crook of the Tree (Night)"

------------------------------------------------------------
-- WAVES
------------------------------------------------------------
-- Wave definitions. Each wave is { hpMult, spawns }. Each spawn is
-- { count, interval, mobType, gap }. mobType "boss" spawns the giant
-- end-of-stage boss as the final entry.
-- Wave hpMult ramp was 1.00 / 1.10 / 1.20 / 1.30 / 1.40. Flattened to
-- 1.00 / 1.05 / 1.10 / 1.15 / 1.20 so waves 4-5 aren't a brick wall on
-- map 2 (which multiplies these on top of a 3.36x map-diff HP mult).
-- Map 1 stays easy (0.765 baseline already trims it further).
WaveData.WAVES = {
    -- Wave 1: gentle intro, baseline difficulty
    {
        hpMult = 1.00,
        spawns = {
            {count = 5, interval = 0.8, mobType = "basic", gap = 2.0},
            {count = 5, interval = 0.7, mobType = "basic", gap = 2.0},
            {count = 5, interval = 0.6, mobType = "basic", gap = 2.0},
            {count = 5, interval = 0.5, mobType = "basic", gap = 2.0},
            {count = 5, interval = 0.5, mobType = "basic", gap = 0},
        },
    },
    -- Wave 2: +5% HP, basic + fast mix
    {
        hpMult = 1.05,
        spawns = {
            {count = 5, interval = 0.6, mobType = "basic", gap = 1.8},
            {count = 5, interval = 0.4, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 0.5, mobType = "basic", gap = 1.5},
            {count = 5, interval = 0.4, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 0.4, mobType = "basic", gap = 0},
        },
    },
    -- Wave 3: +10% HP, tanks + mixed types
    {
        hpMult = 1.10,
        spawns = {
            {count = 5, interval = 0.7, mobType = "basic", gap = 2.0},
            {count = 5, interval = 1.0, mobType = "tank",  gap = 2.5},
            {count = 5, interval = 0.5, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 1.0, mobType = "tank",  gap = 2.0},
            {count = 5, interval = 0.3, mobType = "basic", gap = 0},
        },
    },
    -- Wave 4: +15% HP, denser mix, more tanks. AOE-test groups bumped +4.
    {
        hpMult = 1.15,
        spawns = {
            {count = 6,  interval = 0.5, mobType = "basic", gap = 1.5},
            {count = 5,  interval = 0.8, mobType = "tank",  gap = 2.0},
            {count = 12, interval = 0.3, mobType = "fast",  gap = 1.8},  -- AOE test: 8→12
            {count = 6,  interval = 0.7, mobType = "tank",  gap = 1.5},
            {count = 12, interval = 0.3, mobType = "basic", gap = 0},    -- AOE test: 8→12
        },
    },
    -- Wave 5: +20% HP, then a single GIANT BOSS at the end. AOE-test
    -- groups bumped +4 each.
    {
        hpMult = 1.20,
        spawns = {
            {count = 12, interval = 0.4, mobType = "basic", gap = 1.5},  -- AOE test: 8→12
            {count = 6,  interval = 0.7, mobType = "tank",  gap = 1.8},
            {count = 14, interval = 0.3, mobType = "fast",  gap = 1.5},  -- AOE test: 10→14
            {count = 6,  interval = 0.6, mobType = "tank",  gap = 2.0},
            {count = 14, interval = 0.3, mobType = "basic", gap = 3.0},  -- AOE test: 10→14
            -- The boss: one giant rambling mob.
            {count = 1, interval = 0, mobType = "boss",   gap = 0},
        },
    },
}

------------------------------------------------------------
-- MOB TYPES
------------------------------------------------------------
-- Mob type definitions. All speeds bumped +10% across the board (Apr 22
-- balance pass). Final boss HP bumped +80% to compensate for stronger
-- player towers (attachment system + additive upgrade math).
WaveData.MOB_TYPES = {
    basic     = {hp = 30,    speed = 8.8,  color = Color3.fromRGB(180, 80, 70),
                 size = 2.5, displayName = "Rotten Apple"},
    fast      = {hp = 18,    speed = 15.4, color = Color3.fromRGB(200, 200, 60),
                 size = 2.0, displayName = "Sour Lemon"},
    tank      = {hp = 90,    speed = 5.5,  color = Color3.fromRGB(90,  60, 40),
                 size = 3.5, displayName = "Moldy Bread"},
    boss      = {hp = 1500,  speed = 4.4,  color = Color3.fromRGB(60, 30, 50),
                 size = 9.0, displayName = "The Mold King"},
    -- Map 2 final boss: The Web Weaver. Ambling spider that pauses every
    -- 15s to shoot clickable web projectiles at the player's towers.
    -- Missed webs lock that tower out of firing for 3 seconds. Web-attack
    -- mechanic lives in systems/CanopySpiderBoss.lua; it detects this mob
    -- via the `isCanopySpider` def flag (not the mob-type name), so
    -- renaming `spider` or adding a variant won't break the hookup.
    -- `isFinal = true` flags it for the no-stage-scaling HP path in
    -- MobFactory (same as Pickle Lord) so the HP stays predictable at its
    -- base value — matters because the spider is spawned at stage 3 where
    -- a regular-mob scaling would be ~15× (3.4 stage × 2.2 map × 2.0 wave).
    -- The FinalBoss phase mechanics are keyed on ctx.FinalBossState.instance,
    -- which the spawner only sets for mobType=="finalboss" — so the spider
    -- gets the HP treatment without inheriting Pickle Lord's combat script.
    -- TODO: swap the primitive placeholder model for a free Roblox spider
    -- model once Lily picks one.
    -- 2026-04-29 dx: 35000 → 31500 (-10%) per Matthew "reduce
    -- spider boss hp by 10%." Spiderling pool unchanged.
    spider    = {hp = 31500, speed = 3.0, color = Color3.fromRGB(40, 10, 30),
                 size = 15, displayName = "The Web Weaver",
                 isFinal = true, isCanopySpider = true},
    -- Spiderlings: 4 mini-spiders that spawn with the Web Weaver (2 ahead,
    -- 2 behind along the path). HP pool split ~50/50 spider vs.
    -- spiderlings-collectively — 35k on the spider, 4×9k on the lings
    -- = 71k total (was 40k + 40k = 80k pre-2026-04 retune). `isFinal = true`
    -- keeps them exempt from stage/map HP scaling (trash-mob mults would
    -- push them to 376k). The flag doesn't trigger FinalBossState (that's
    -- keyed on mobType=="finalboss").
    spiderling = {hp = 9000, speed = 3.0, color = Color3.fromRGB(60, 20, 50),
                 size = 6, displayName = "Spiderling", isFinal = true, isEscort = true},
    -- Map 3 final boss: The Canopy Bird. Hovers above the arena and
    -- every 30 game-seconds dives at a player, grabs them by the head,
    -- and carries them upward — 10 taps to escape, or you get carried
    -- off and die. Eggs spawn continuously through the phase (path
    -- mobs that ramp from tiny + 27 HP to giant + 100k HP over 5min).
    -- Mechanic lives in systems/Map3BirdBoss.lua. The legacy dive-and-
    -- peck mechanic (isCanopyBird flag + systems/BirdBoss.lua) was
    -- retired in the 2026-04 cleanup pass.
    bird      = {hp = 320000, speed = 3.4, color = Color3.fromRGB(170, 80, 60),
                 size = 14, displayName = "The Canopy Bird",
                 isFinal = true, isCanopyBird = true},
    -- NOTE: `finalboss` is the map-1 final-stage boss — it's the grown-up
    -- Mold King, NOT Pickle Lord. The entry name and `isFinal` flag stay
    -- because lots of engine plumbing keys on them (FinalBoss.lua phase
    -- mechanics, BossDefeated fire, Neon visual, etc.), but the in-world
    -- name is Mold King. The actual Pickle Lord is the RUN BOSS that will
    -- land as a separate mob type after map 3 is built.
    finalboss = {hp = 15000, speed = 3.3,  color = Color3.fromRGB(120, 30, 180),
                 size = 14,  displayName = "The Mold King", isFinal = true},
}

return WaveData
