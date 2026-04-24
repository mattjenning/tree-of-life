-- TreeOfLife_WaveSystem_SERVER.lua
-- Companion ServerScript to TreeOfLife_Hub. Owns: mob types, wave definitions,
-- mob spawning, mob pathing & status effects (stun/knockback/AOE), tower
-- firing, wave progression, win/lose detection, upgrade card generation
-- (rarity rolls, special bonuses), reroll handling.
--
-- Reads tagged infrastructure built by the hub:
--   EnemyWaypoint (path nodes), EnemySpawn (origin), EnemyEndPoint (heart),
--   Tower (placed towers).
--
-- ============================================================
-- ARCHITECTURE NOTES (read before editing)
-- ============================================================
--
-- Phase 3 refactor (Apr 2026) broke this file into focused modules
-- under src/server/systems/. The orchestrator (this file) now:
--   - Declares the ctx table + top-level config (WaveConfig, Stages,
--     WAVES, MOB_TYPES, StageState, gameSpeed)
--   - Declares world accessors (getHeart, getWaypoints, getSpawnPart,
--     activeMapId, partMapId, tdRoom) and publishes them on ctx
--   - Requires every systems/ module in dependency order, each
--     exposing one or more ctx.X closures (late-resolve everything)
--   - Owns wave orchestration (runWave, onWaveCleared, spawnNextWave)
--     and the remote-event handlers that drive the run
--   - Runs the single Heartbeat loop at the bottom which calls
--     ctx.updateMobs, ctx.updateTowers, ctx.tickPhoenixCooldowns
--
-- MODULE LOAD ORDER (enforced by require order below):
--   1. UpgradeCards     (reads ctx.WaveConfig, publishes upgrade helpers)
--   2. Targeting        (reads ctx.activeMobs — lazy; publishes findTarget)
--   3. Effects          (reads ctx.tdRoom, WaveConfig, activeMobs)
--   4. Towers           (reads ctx.findTarget, damageMob — lazy)
--   5. MobFactory       (reads ctx.MOB_TYPES, Stages; publishes activeMobs)
--   6. Phoenix          (reads activeMobs, WaveConfig)
--   7. FinalBoss        (reads WaveConfig; publishes checkPhaseTrigger)
--   8. MobUpdate        (reads everything above)
--   9. Damage           (reads Effects, FinalBossState, activeMobs)
--
-- EDITING RULES:
--   1. Reach across modules through ctx.X — NEVER capture a module
--      value as an upvalue at require time, since that freezes the
--      reference. Late-resolve at call time.
--   2. When adding a new system/X.lua, append its require after the
--      modules it reads from, and update the list above.
--   3. Wave orchestration + remote handlers stay here because they're
--      the "glue" — if a module needs something from an orchestration
--      handler, route it through ctx (add a helper to the module).
--
-- GAME-TIME vs WALL-CLOCK:
--   gameSpeed is 1/2/3 (player toggle). When the player picks 3x:
--     - mob movement, tower fire intervals, spawn intervals, and Phoenix
--       cooldown all SCALE — 3x faster
--     - knockback slide animation, damage-number float-up, AOE/Detonator
--       VFX durations, and the boss minigame tap window all stay at REAL
--       wallclock seconds (intentional — VFX shouldn't speed up; the boss
--       tap window would be unwinnable at 3x)
--   Anywhere we set "this expires in N seconds" using os.clock(), we must
--   decide which kind of time we mean:
--     - GAME time → use `os.clock() + (N / gameSpeed)` so the wallclock
--       interval shrinks at 2x/3x
--     - REAL time → use `os.clock() + N` (visual durations only)
--   Stun and BonusDamageUntil use game-time. Look there for the pattern.
--
-- ============================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- Shared modules. The file-local wave-tuning table (line ~120) is named
-- `WaveConfig`, not `Config`, so we can use the shared Config name here
-- without collision.
local ServerScriptService = game:GetService("ServerScriptService")

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local Remotes    = require(Shared:WaitForChild("Remotes"))
local Tags       = require(Shared:WaitForChild("Tags"))
local Config     = require(Shared:WaitForChild("Config"))
local TempTowers = require(Shared:WaitForChild("TempTowers"))

-- Used by SwitchMap for per-map permanent-tower stock grants. Kept at
-- module scope so the handler doesn't inline a require on every map
-- transition.
local PermanentTowerStore = require(ServerScriptService:WaitForChild("PermanentTowerStore"))

-- Phase 3 shared-state context. See src/server/WaveContext.lua for the
-- field-by-field contract. Created here so forward-declared upvalues
-- (gameOverFired) and module-local config tables (WaveConfig,
-- StageState, etc.) can be published onto ctx below after they're
-- declared, before each extracted module's setup(ctx) runs.
local WaveContext = require(script.Parent:WaitForChild("WaveContext"))
local ctx = WaveContext.new()
ctx.gameSpeed = 1  -- player-selectable speed (1/2/3/5/10); set by SetGameSpeed remote handler below

-- gameSpeed used to be a forward-declared local. Phase 3 moved it to
-- ctx.gameSpeed so extracted modules (Effects, Phoenix, MobUpdate,
-- Towers) can read the current value via ctx instead of capturing a
-- local that wouldn't survive extraction. The SetGameSpeed remote
-- handler (later in this file) sets ctx.gameSpeed; every reader
-- resolves through ctx at call time.

-- Forward-declared for the same reason as gameSpeed: gameOverFired is read
-- by onWaveCleared, advanceStage, and the upgrade-picked handler — all of
-- which sit textually ABOVE the heart-death poll task that originally
-- declared it. Without this forward decl, those earlier references resolved
-- to a separate GLOBAL gameOverFired (always nil), and the LOCAL set true
-- by the poll task never propagated. Symptom: after a death+reset, wave 1
-- ran fine, but the gameOverFired check before runWave(2) was reading nil
-- from a different variable (so it didn't block wave 2 — that part worked),
-- BUT the DEFEATED state and other "is the game over?" checks across the
-- file were inconsistent. Forward-decl ensures one shared local.
local gameOverFired = false

------------------------------------------------------------
-- Remote events
------------------------------------------------------------
local function ensureRemote(name)
    local r = ReplicatedStorage:FindFirstChild(name)
    if not r then
        r = Instance.new("RemoteEvent")
        r.Name = name
        r.Parent = ReplicatedStorage
    end
    return r
end

local remoteWaveStart     = ensureRemote(Remotes.Names.WaveStart)      -- client → server: player pressed START
local remoteWaveState     = ensureRemote(Remotes.Names.WaveState)      -- server → client: wave number, mobs remaining, etc.
local remoteShowUpgrades  = ensureRemote(Remotes.Names.ShowUpgrades)   -- server → client: show the upgrade picker
local remoteUpgradePicked = ensureRemote(Remotes.Names.UpgradePicked)  -- client → server: player chose an upgrade
local remoteGameOver      = ensureRemote(Remotes.Names.GameOver)       -- server → client: heart died (or final wave cleared)
local remoteStageCleared  = ensureRemote(Remotes.Names.StageCleared)   -- server → client: stage finished, show modal
local remoteStageContinue = ensureRemote(Remotes.Names.StageContinue)  -- client → server: continue button tapped
local remoteStageReskin   = ensureRemote(Remotes.Names.StageReskin)    -- server → client: hub-side visual transition for new stage
-- BossPhase / BossTargetTap / BossWindup / BossWeb / BossPhaseMiss remotes
-- are created + wired by systems/FinalBoss.lua (it calls ReplicatedStorage
-- :WaitForChild on them; Remotes.lua seeds them into ReplicatedStorage at
-- server-start via a separate guard). No need to pre-create them here.
local remoteLeafMessage   = ensureRemote(Remotes.Names.LeafMessage)    -- server → client: show a falling-leaf narrative message with text + duration
local remoteDevAddStun    = ensureRemote(Remotes.Names.DevAddStun)     -- client → server: dev panel added a Stun stack to all owned towers
local remoteDevSkipToBoss    = ensureRemote(Remotes.Names.DevSkipToBoss)    -- client → server: dev panel skip to current stage's boss with simulated upgrades
local remoteDevSkipToMapBoss = ensureRemote(Remotes.Names.DevSkipToMapBoss) -- client → server: dev panel jump to map boss (stage 3) + auto-kill, triggers temp-tower picker
local remoteDevResetCd    = ensureRemote(Remotes.Names.DevResetCooldowns)  -- client → server: dev panel reset all per-tower cooldowns + bonus timers

------------------------------------------------------------
-- Config
------------------------------------------------------------

-- All tunable gameplay numbers in one place. Search this section first
-- when balancing. Named WaveConfig (not just Config) because the shared
-- Config module (grid, map2, phoenix) is also imported above — having
-- two locals called `Config` would collide.
local WaveConfig = {
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

    -- Final boss minigame: when boss HP crosses a threshold, spawn 4 tappable
    -- blobs. Tapping all in time grants a 5s "Damage Bonus" (×2 damage).
    -- Phase fires at each HP threshold (75%, 50%, 25%) provided the previous
    -- phase's blobs aren't still on screen. The "still on screen" check uses
    -- finalBossTargetWindow as the implicit cooldown — phases can't overlap.
    finalBossPhaseThresholds   = {0.75, 0.50, 0.25},
    finalBossTargetsPerPhase   = 4,
    finalBossTargetWindow      = 4,    -- seconds the targets remain tappable
    finalBossBonusDuration     = 5,    -- seconds of bonus damage on success
    finalBossBonusMultiplier   = 2.0,  -- damage multiplier during bonus
    finalBossWindupDuration    = 1.2,  -- boss stops + vibrates before launching spots
    finalBossWebDuration       = 3,    -- seconds the player is webbed on missed phase
}

-- Stage / map state. Updated as the player progresses through stages.
local StageState = {
    currentMapId   = 1,                              -- v3: which physical map. 1=Crook, 2=Climbing, 3=Canopy
    currentMapName = "Crook of the Tree (Morning)",
    currentStage   = 1,
    inTransition   = false,  -- true while between stages (prevents wave starts)
    finalBossActive = false, -- true during the final-final boss fight
    -- Run-wide wave counter across maps. currentStage + currentWave reset
    -- each SwitchMap, so without this the GameOver death banner would show
    -- "3 rounds" for someone who dies on map 2 stage 1 wave 4 (after 15
    -- completed map-1 waves). SwitchMap adds the prior map's full 15 waves
    -- here; live calc adds `completedStagesThisMap * 5 + currentWave - 1`.
    priorMapsWavesCompleted = 0,
}

-- Stage definitions. Stage hpMult multiplies the per-wave hpMult, so
-- a wave 5 (1.40 base) on stage 3 (2.0 stage mult) → 2.80× mob HP.
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
local Stages = {
    [1] = { name = "Crook of the Tree (Morning)", hpMult = 1.0,  speedMult = 1.0, bossHpMult = 1.333 },
    [2] = { name = "Crook of the Tree (Day)",     hpMult = 2.10, speedMult = 1.2, bossHpMult = 3.0 },
    [3] = { name = "Crook of the Tree (Dusk)",    hpMult = 3.40, speedMult = 1.3, bossHpMult = 7000/1500 },
}
-- Special name shown when the final boss spawns (after stage 3 waves cleared)
local FINAL_BOSS_MAP_NAME = "Crook of the Tree (Night)"
local TOTAL_STAGES = Config.Waves.TotalStages

-- FinalBossState lives in systems/FinalBoss.lua now (Phase 3 commit 7);
-- accessed via ctx.FinalBossState by the handlers in this file that mutate
-- it (runWave, onWaveCleared, DevSkipToBoss, RunReset, SwitchMap).

-- Wave definitions. Each wave is { hpMult, spawns }. Each spawn is
-- { count, interval, mobType, gap }. mobType "boss" spawns the giant
-- end-of-stage boss as the final entry.
-- Wave hpMult ramp was 1.00 / 1.10 / 1.20 / 1.30 / 1.40. Flattened to
-- 1.00 / 1.05 / 1.10 / 1.15 / 1.20 so waves 4-5 aren't a brick wall on
-- map 2 (which multiplies these on top of a 3.36x map-diff HP mult).
-- Map 1 stays easy (0.765 baseline already trims it further).
local WAVES = {
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

-- Mob type definitions. All speeds bumped +10% across the board (Apr 22
-- balance pass). Final boss HP bumped +80% to compensate for stronger
-- player towers (attachment system + additive upgrade math).
local MOB_TYPES = {
    basic     = {hp = 30,    speed = 8.8,  color = Color3.fromRGB(180, 80, 70),
                 size = 2.5, displayName = "Rotten Apple"},
    fast      = {hp = 18,    speed = 15.4, color = Color3.fromRGB(200, 200, 60),
                 size = 2.0, displayName = "Sour Lemon"},
    tank      = {hp = 90,    speed = 5.5,  color = Color3.fromRGB(90,  60, 40),
                 size = 3.5, displayName = "Moldy Bread"},
    boss      = {hp = 1500,  speed = 4.4,  color = Color3.fromRGB(60, 30, 50),
                 size = 9.0, displayName = "The Mold King"},
    -- Map 2 final boss: a big spider. `isFinal = true` flags it for the
    -- no-stage-scaling HP path in MobFactory (same as Pickle Lord) so the
    -- HP stays predictable at its base value — matters because the spider
    -- is spawned at stage 3 where a regular-mob scaling would be ~15×
    -- (3.4 stage × 2.2 map × 2.0 wave). The FinalBoss phase/web mechanics
    -- are keyed on ctx.FinalBossState.instance, which the spawner only
    -- sets for mobType=="finalboss" — so the spider gets the HP treatment
    -- without inheriting Pickle Lord's combat script.
    -- Map 2 final boss: The Web Weaver. Ambling spider that pauses
    -- every 15s to shoot clickable web projectiles at the player's
    -- towers. Missed webs lock that tower out of firing for 3 seconds.
    -- Web-attack mechanic lives in systems/CanopySpiderBoss.lua; it
    -- detects this mob via the `isCanopySpider` def flag (not the
    -- mob-type name), so renaming `spider` or adding a variant won't
    -- break the hookup. TODO: swap the primitive placeholder model
    -- for a free Roblox spider model once Lily picks one.
    spider    = {hp = 40000, speed = 3.0, color = Color3.fromRGB(40, 10, 30),
                 size = 15, displayName = "The Web Weaver",
                 isFinal = true, isCanopySpider = true},
    -- Spiderlings: 4 mini-spiders that spawn with the Web Weaver (2 ahead,
    -- 2 behind along the path). The Web Weaver fight's HP pool is split 50/50
    -- spider vs. spiderlings-collectively — 40k on the spider, 4×10k on the
    -- lings = 80k total. `isFinal = true` keeps them exempt from stage/map
    -- HP scaling (trash-mob mults would push them to 376k). The flag doesn't
    -- trigger FinalBossState (that's keyed on mobType=="finalboss").
    spiderling = {hp = 10000, speed = 3.0, color = Color3.fromRGB(60, 20, 50),
                 size = 6, displayName = "Spiderling", isFinal = true},
    -- Map 3 final boss: The Canopy Bird. Slow ambling flier that every
    -- ~12s ascends + hovers over a random tower, placing a clickable
    -- dive-target. Tapping cancels the dive (bonus damage to bird);
    -- missing lets the bird peck the tower, shaving 10 MaxShots from it.
    -- Distinct from the Web Weaver's stun-style web attack. Mechanic
    -- lives in systems/BirdBoss.lua, detected via isCanopyBird flag.
    bird      = {hp = 320000, speed = 3.4, color = Color3.fromRGB(170, 80, 60),
                 size = 14, displayName = "The Canopy Bird",
                 isFinal = true, isCanopyBird = true},
    -- NOTE: `finalboss` is the map-1 final-stage boss — it's the grown-up
    -- Mold King, NOT Pickle Lord. The entry name and `isFinal` flag stay
    -- because lots of engine plumbing keys on them (FinalBoss.lua phase
    -- mechanics, BossDefeated fire, Neon visual, etc.), but the in-world
    -- name is Mold King. The actual Pickle Lord is the RUN BOSS that will
    -- land as a separate mob type after map 3 is built.
    finalboss = {hp = 12600, speed = 3.3,  color = Color3.fromRGB(120, 30, 180),
                 size = 14,  displayName = "The Mold King", isFinal = true},
}

-- Publish top-level config onto ctx so every systems/ module can read
-- them through ctx instead of closing over these locals.
ctx.WaveConfig     = WaveConfig
ctx.StageState     = StageState
ctx.Stages         = Stages
ctx.WAVES          = WAVES
ctx.MOB_TYPES      = MOB_TYPES

-- Upgrade cards: rarity rolls, card generation, per-player upgrade
-- application. Publishes ctx.generateCardsForPlayer / applyUpgrade /
-- simulateOnePick / applyStunStackToOwnedTowers / rollRarity /
-- getTierColor / RARITY_TO_SCORE.
local UpgradeCards = require(script.Parent:WaitForChild("systems"):WaitForChild("UpgradeCards"))
UpgradeCards.setup(ctx)

------------------------------------------------------------
-- References
--
-- v3 multi-map: each map has its own Heart, EnemySpawn, and EnemyPath
-- folder, all coexisting in Workspace at different physical locations.
-- Tagged Parts get a MapId attribute (1, 2, 3...) and the active-map
-- accessors filter by StageState.currentMapId. Map 1 = Crook of the
-- Tree (existing). Map 2 = Climbing the Tree (new this session).
--
-- Backward-compat: if a tagged Part has NO MapId attribute, it's treated
-- as belonging to map 1 (so old hub builds without MapId still work).
------------------------------------------------------------
local tdRoom = Workspace:WaitForChild("TreeOfLifeTDRoom")

local function partMapId(part)
    return part:GetAttribute("MapId") or 1
end

local function activeMapId()
    return (StageState and StageState.currentMapId) or 1
end

local function getHeart()
    local id = activeMapId()
    for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        if partMapId(h) == id then return h end
    end
    return nil
end

local function getSpawnPart()
    local id = activeMapId()
    for _, s in ipairs(CollectionService:GetTagged(Tags.EnemySpawn)) do
        if partMapId(s) == id then return s end
    end
    return nil
end

local function getWaypoints()
    -- Find the EnemyPath folder belonging to the active map. Each map's
    -- folder is parented under its own Model (e.g. Map2Room) or under
    -- the tdRoom for map 1. We scan Workspace descendants for any folder
    -- named "EnemyPath" and pick the one whose MapId matches.
    local id = activeMapId()
    local chosenFolder = nil
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant:IsA("Folder") and descendant.Name == "EnemyPath" then
            local folderMapId = descendant:GetAttribute("MapId") or 1
            if folderMapId == id then
                chosenFolder = descendant
                break
            end
        end
    end
    if not chosenFolder then return {} end
    local wps = {}
    for i = 1, 50 do  -- bumped from 20 to 50 for longer map 2 path
        local wp = chosenFolder:FindFirstChild("Waypoint" .. i)
        if wp then
            table.insert(wps, wp)
        else
            break
        end
    end
    return wps
end

------------------------------------------------------------
-- Mob management
------------------------------------------------------------

-- Publish world accessors + ctx.tdRoom onto ctx so extracted modules can
-- late-resolve them. activeMobs, makeMob, countActiveMobs, clearAllMobs
-- are published by MobFactory.setup below.
ctx.getHeart     = getHeart
ctx.getSpawnPart = getSpawnPart
ctx.getWaypoints = getWaypoints
ctx.activeMapId  = activeMapId
ctx.partMapId    = partMapId
ctx.tdRoom       = tdRoom

-- Targeting: findTarget with four modes (First/Strongest/Center/Last).
-- Reads ctx.activeMobs / getWaypoints lazily.
local Targeting = require(script.Parent:WaitForChild("systems"):WaitForChild("Targeting"))
Targeting.setup(ctx)

-- Effects: damage-number billboards, fire bolts, AOE + Detonator bursts,
-- applyHitEffects (stun/knockback roll on hit).
local Effects = require(script.Parent:WaitForChild("systems"):WaitForChild("Effects"))
Effects.setup(ctx)

-- MobFactory: makeMob + activeMobs registry + countActiveMobs +
-- clearAllMobs. HP scaling invariant lives inside.
local MobFactory = require(script.Parent:WaitForChild("systems"):WaitForChild("MobFactory"))
MobFactory.setup(ctx)

-- Phoenix: death-save mechanic (AOE capture, burn-in-place, limbo
-- queue, staggered release). MobFactory.clearAllMobs reads
-- ctx.PhoenixGrace / PhoenixQueue lazily, so Phoenix.setup running
-- AFTER MobFactory.setup is fine (clearAllMobs doesn't run until a
-- wave-clear / reset / death event fires it).
local Phoenix = require(script.Parent:WaitForChild("systems"):WaitForChild("Phoenix"))
Phoenix.setup(ctx)

-- FinalBoss (Pickle Lord): HP-threshold windup → 4 tappable targets →
-- bonus damage or web penalty. Owns checkPhaseTrigger (called from
-- damageMob) and tickPhaseWindup (called from updateMobs).
local FinalBoss = require(script.Parent:WaitForChild("systems"):WaitForChild("FinalBoss"))
FinalBoss.setup(ctx)

-- MobUpdate: per-frame mob loop (path advance, knockback, stun-star
-- orbit, heart damage, Phoenix grace sweep, boss windup freeze). Depends
-- on everything above through ctx.
local MobUpdate = require(script.Parent:WaitForChild("systems"):WaitForChild("MobUpdate"))
MobUpdate.setup(ctx)

-- Damage: damageMob + Detonator chain-damage recursion. Depends on
-- Effects (spawnDamageNumber, spawnDetonatorBurst, applyHitEffects),
-- FinalBoss (checkPhaseTrigger, FinalBossState), and MobFactory
-- (activeMobs).
local Damage = require(script.Parent:WaitForChild("systems"):WaitForChild("Damage"))
Damage.setup(ctx)

-- Tower firing loop + per-tower caches + tower-removed cleanup.
-- Extracted to systems/Towers.lua. Publishes ctx.updateTowers,
-- ctx.towerLastFire, ctx.towerOwnerCache, ctx.getTowerOwner. The
-- Heartbeat loop calls ctx.updateTowers every frame.
local Towers = require(script.Parent:WaitForChild("systems"):WaitForChild("Towers"))
Towers.setup(ctx)

-- Zones: persistent ground patches / DOT clouds spawned by temp towers
-- (Honey Hive, Spore Puffball). Publishes ctx.spawnZone; depends on
-- ctx.activeMobs + ctx.damageMob from the setups above.
local Zones = require(script.Parent:WaitForChild("systems"):WaitForChild("Zones"))
Zones.setup(ctx)

-- CanopySpiderBoss: map-2 boss web-attack mechanic. Polls activeMobs for
-- isCanopySpider mobs and runs the 15s web-timer loop on spawn; handles
-- TapSpiderWeb remote for player tap-to-cancel.
local CanopySpiderBoss = require(script.Parent:WaitForChild("systems"):WaitForChild("CanopySpiderBoss"))
CanopySpiderBoss.setup(ctx)

-- BirdBoss: map-3 boss dive-strike mechanic. Polls activeMobs for
-- isCanopyBird mobs and runs the 12s dive-timer loop on spawn; handles
-- TapBirdDive remote for player tap-to-cancel.
local BirdBoss = require(script.Parent:WaitForChild("systems"):WaitForChild("BirdBoss"))
BirdBoss.setup(ctx)

------------------------------------------------------------
-- Wave orchestration
------------------------------------------------------------
local currentWave = 0  -- 0 = not started / between waves
local waveInProgress = false
-- Set true by DevSkipWave handler. The spawn loop checks this before
-- spawning each new mob and bails early; remaining mobs are cleared in the
-- handler so the wave-clear poll fires immediately afterward.
local skipRequested = false
local waveEndPending = false

-- Monotonically-increasing token identifying the current wave-run. Every
-- call to runWave increments it; every spawner coroutine captures its
-- token at start and bails if the global token has moved on. This catches
-- races where DevSkipToBoss (or a future similar dev action) starts a new
-- run while an old spawner coroutine is still alive inside a task.wait.
-- Without this, the old spawner would wake up after its sleep and happily
-- spawn the next mob in its sequence — producing "a group spawned with
-- the boss."
local waveRunToken = 0

-- Game speed multiplier (1, 2, or 3). Scales mob movement, tower fire rate,
-- spawn intervals, and Phoenix cooldown ticking. The final-boss minigame's
-- tap window stays at REAL seconds (otherwise unwinnable at 3x).
-- ctx.gameSpeed is initialized to 1 at the top of this file (where ctx
-- itself is created). This block just wires the remote handler that
-- lets the client toggle it.
local ALLOWED_SPEEDS = {[1] = true, [2] = true, [3] = true, [5] = true, [10] = true}
-- Pause is a SEPARATE state (ctx.paused) rather than gameSpeed = 0 because
-- several systems divide by gameSpeed (e.g. stun duration math); 0 would
-- make those go to infinity. The pause gate short-circuits the main mob
-- update + tower firing loops; pre-existing stuns / patches / cooldowns
-- tick in wallclock but that's acceptable for an MVP pause.
ctx.paused = false

local function ensureRemoteEvent(name)
    local r = ReplicatedStorage:FindFirstChild(name)
    if not r then
        r = Instance.new("RemoteEvent")
        r.Name = name
        r.Parent = ReplicatedStorage
    end
    return r
end

local setGameSpeedRemote      = ensureRemoteEvent("SetGameSpeed")       -- client → server
local gameSpeedChangedRemote  = ensureRemoteEvent("GameSpeedChanged")   -- server → all clients

setGameSpeedRemote.OnServerEvent:Connect(function(_player, requested)
    if type(requested) ~= "number" then return end
    requested = math.floor(requested)
    -- 0 = pause (separate state, preserves ctx.gameSpeed so unpause
    -- resumes at the same multiplier). 1/2/3/5/10 = normal speeds.
    if requested == 0 then
        if ctx.paused then return end
        ctx.paused = true
        gameSpeedChangedRemote:FireAllClients(0)
        print("[Waves] Game PAUSED")
        return
    end
    if not ALLOWED_SPEEDS[requested] then return end
    if requested == ctx.gameSpeed and not ctx.paused then return end
    ctx.paused = false
    ctx.gameSpeed = requested
    gameSpeedChangedRemote:FireAllClients(ctx.gameSpeed)
    print(("[Waves] Game speed → %dx"):format(ctx.gameSpeed))
end)

-- Hand the current speed to any client that joins or asks (via PlayerAdded)
Players.PlayerAdded:Connect(function(p)
    task.wait(1)  -- let the client's listener wire up
    gameSpeedChangedRemote:FireClient(p, ctx.gameSpeed)
end)

local function broadcastWaveState()
    local payload = {
        mapId = StageState.currentMapId,  -- client uses this to branch RESET behavior by map
        map = StageState.currentMapName,
        stage = StageState.currentStage,
        wave = currentWave,
        totalWaves = #WAVES,
        mobsAlive = ctx.countActiveMobs(),
        inProgress = waveInProgress,
        finalBossActive = StageState.finalBossActive,
    }
    remoteWaveState:FireAllClients(payload)
end

local function runWave(waveIndex)
    if waveInProgress then return end
    local wave = WAVES[waveIndex]
    if not wave then return end
    local spawns = wave.spawns
    local hpMult = wave.hpMult or 1.0
    waveInProgress = true
    skipRequested = false  -- fresh wave; clear any leftover skip flag
    currentWave = waveIndex
    waveRunToken = waveRunToken + 1
    local myToken = waveRunToken
    broadcastWaveState()

    local waypoints = getWaypoints()
    task.spawn(function()
        -- Per-stage mob-count skew (map 1 only; map 2+ runs the baseline
        -- composition on top of its own difficulty mults):
        --   Stage 2 = AOE-TEST LEVEL — bigger clusters of basic + fast so
        --             the player's AOE picks have meaningful targets.
        --   Stage 3 = SINGLE-TARGET / EXPLODING MOBS — more tanks (fewer
        --             but beefier targets), fewer fast-mob swarms. Exploder
        --             mechanic is TBD; tanks stand in until the exploder
        --             mob type ships.
        local stage = (StageState.currentStage or 1)
        local mapId = StageState.currentMapId or 1
        local function stageSkewForMobType(mobType)
            if mapId ~= 1 then return 1.0 end
            if stage == 2 then
                if mobType == "basic" or mobType == "fast" then return 1.5 end
            elseif stage == 3 then
                if mobType == "tank" then return 2.0 end
                if mobType == "fast" then return 0.5 end
            end
            return 1.0
        end

        for _, spawn in ipairs(spawns) do
            -- Map 2 difficulty: spawn more mobs per group. Only scales the
            -- regular mob spawns (boss counts are usually 1 anyway and we
            -- don't want to spawn multiple bosses). Rounded to nearest int.
            local countMult = 1.0
            if mapId == 2 and Config.Map2 and Config.Map2.Difficulty
               and spawn.mobType ~= "boss" and spawn.mobType ~= "finalboss" then
                countMult = Config.Map2.Difficulty.SpawnCountMult or 1.0
            end
            countMult = countMult * stageSkewForMobType(spawn.mobType)
            local scaledCount = math.max(1, math.floor(spawn.count * countMult + 0.5))

            -- Per-map boss substitution: the WAVES table spawns "finalboss"
            -- (Pickle Lord) at stage 3 wave 5 on every map. Each map should
            -- actually have its own distinct boss:
            --   map 1: Pickle Lord (legacy — will migrate to a dedicated
            --          map-1 boss later)
            --   map 2: The Pantry Spider (no phase mechanics, bigger tanky mob)
            --   map 3: bird (future)
            -- Only substitute when spawning the map boss, not for any
            -- lower-stage "boss" (which is the Mold King stage boss).
            local effectiveMobType = spawn.mobType
            if mapId == 2 and spawn.mobType == "finalboss" then
                effectiveMobType = "spider"
            end

            for i = 1, scaledCount do
                -- Token mismatch: another runWave or DevSkipToBoss started.
                -- Full abort — do NOT fall through to drain-loop + onWaveCleared.
                if waveRunToken ~= myToken then return end
                -- DevSkipWave: stop spawning, fall through to drain loop so
                -- onWaveCleared still fires.
                if skipRequested then break end
                local heart = getHeart()
                if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                    waveInProgress = false
                    broadcastWaveState()
                    return
                end
                local mob = ctx.makeMob(effectiveMobType, waypoints, hpMult)
                if effectiveMobType == "finalboss" and mob then
                    ctx.FinalBossState.instance = mob
                    ctx.FinalBossState.triggeredPhases = {}
                    StageState.finalBossActive = true
                end
                broadcastWaveState()
                task.wait(spawn.interval / ctx.gameSpeed)
            end
            if waveRunToken ~= myToken then return end
            if skipRequested then break end
            task.wait(spawn.gap / ctx.gameSpeed)
        end
        -- All spawns done (or skipped) — wait for remaining mobs to die or leak
        while ctx.countActiveMobs() > 0 do
            if waveRunToken ~= myToken then return end
            local heart = getHeart()
            if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                waveInProgress = false
                broadcastWaveState()
                return
            end
            task.wait(WaveConfig.waveClearedPollInterval)
            broadcastWaveState()
        end
        -- Wave cleared
        waveInProgress = false
        broadcastWaveState()
        onWaveCleared(waveIndex)
    end)
end


-- First-death tutorial fairy. Iterates all players and fires the
-- client-side fairy modal to any who meet BOTH conditions:
--   (1) haven't seen the fairy yet (pref `hasSeenFirstDeathFairy`), AND
--   (2) own zero attachments (proxy for "truly new player" — any
--       attachment they'd pick from the fairy sets both the flag and
--       the inventory, so a returning account that somehow doesn't have
--       the flag set also won't re-trigger if they've banked any
--       attachments at all).
-- Flag is set server-side when the player picks via the fairy modal.
-- The flag persists via DataStore so this only fires once per account.
local firstDeathFairyRemote = Remotes.getOrCreate(
    Remotes.Names.ShowFirstDeathFairy, "RemoteEvent")
local resurrectionNoticeRemote = Remotes.getOrCreate(
    Remotes.Names.ShowResurrectionNotice, "RemoteEvent")
local AttachmentStore = require(ServerScriptService:WaitForChild("AttachmentStore"))

-- Kill all player humanoids so they fall-over-and-ragdoll at the moment
-- the heart dies. Uses Roblox's native death: set Health = 0 → the
-- default Animate script plays the backward-fall animation and
-- BreakJointsOnDeath (on by default) detaches limbs. No custom anim
-- needed. Roblox's default 5s CharacterAutoLoads will respawn them at
-- SpawnLocation (the hub) shortly after — fine for the subsequent-death
-- case; for first-death the fairy cinematic descent is 8s, so the body
-- may respawn mid-descent. The fairy's target is captured at start, so
-- it still lands at the death spot even if the body pops back to hub.
local function ragdollAllPlayers()
    for _, p in ipairs(Players:GetPlayers()) do
        local char = p.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 then
            hum.Health = 0
        end
    end
end

local function maybeShowFirstDeathFairyToAll()
    -- Split the players into "gets the fairy" vs "waits for the picker".
    -- Fairy qualifier: no fairy pref set AND zero owned attachments.
    local fairyRecipients = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if not PermanentTowerStore.getPref(p, "hasSeenFirstDeathFairy") then
            local owned = AttachmentStore.getOwned(p) or {}
            if next(owned) == nil then
                table.insert(fairyRecipients, p)
            end
        end
    end
    if #fairyRecipients == 0 then return end
    -- Fire the picker modal to qualifying players; everyone else sees
    -- "someone is being resurrected!" so the room understands why the
    -- game has paused + will restart.
    local fairyByUserId = {}
    for _, fp in ipairs(fairyRecipients) do
        fairyByUserId[fp.UserId] = true
        firstDeathFairyRemote:FireClient(fp)
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if not fairyByUserId[p.UserId] then
            resurrectionNoticeRemote:FireClient(p)
        end
    end
end

-- Resurrect-after-first-death: fired by DevRemotes once the fairy-receiving
-- player picks an attachment. Heals the heart, clears mobs, unsets the
-- game-over lock, and restarts the wave (or map-boss fight) the team
-- was on when the heart died — giving everyone a do-over WITH the new
-- attachment equipped on the first-timer.
local resurrectBindable = Remotes.getOrCreate(
    Remotes.Names.ResurrectAfterFirstDeath, "BindableEvent")
resurrectBindable.Event:Connect(function()
    -- Bump the token so any stragglers from the pre-death wave die off.
    waveRunToken = waveRunToken + 1
    waveInProgress = false
    skipRequested = true
    ctx.clearAllMobs()
    ctx.FinalBossState.instance = nil
    ctx.FinalBossState.triggeredPhases = {}
    ctx.FinalBossState.windupUntil = 0
    ctx.FinalBossState.pendingPhase = nil
    gameOverFired = false
    local heart = getHeart()
    if heart then
        heart:SetAttribute("Health", heart:GetAttribute("MaxHealth") or 500)
    end
    broadcastWaveState()  -- unlocks client HUDs from DEFEATED
    -- Restart the encounter the team was on. Short delay so the
    -- fairy/resurrection modals on clients finish tearing down and
    -- the heal replicates before wave-1 mobs start spawning.
    task.delay(1.0, function()
        skipRequested = false
        if StageState.finalBossActive then
            -- Respawn the named map boss solo (same as the stage-3-cleared
            -- path in onWaveCleared).
            local mapId = StageState.currentMapId or 1
            local bossType = (mapId == 2) and "spider" or "finalboss"
            task.spawn(function()
                local waypoints = getWaypoints()
                local mob = ctx.makeMob(bossType, waypoints, 1.0)
                if mob and bossType == "finalboss" then
                    ctx.FinalBossState.instance = mob
                end
                broadcastWaveState()
                while mob and mob.Parent do
                    if not getHeart() or (getHeart():GetAttribute("Health") or 0) <= 0 then return end
                    task.wait(WaveConfig.waveClearedPollInterval)
                end
                waveInProgress = false
                broadcastWaveState()
                onWaveCleared(0)
            end)
        else
            runWave(math.max(1, currentWave or 1))
        end
    end)
    print("[Waves] RESURRECT — heart healed, mobs cleared, wave restarting.")
end)

function onWaveCleared(waveIndex)
    -- If the heart died on the same tick the last mob died, don't offer
    -- upgrades — the game is already lost.
    local heart = getHeart()
    if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
        gameOverFired = true
        local completedStages = math.max(0, StageState.currentStage - 1)
        local wavesSoFar = (StageState.priorMapsWavesCompleted or 0)
            + completedStages * #WAVES
            + math.max(0, (currentWave or 1) - 1)
        remoteGameOver:FireAllClients({
            result = "lose",
            finalWave = waveIndex,
            totalWavesDefeated = wavesSoFar,
        })
        ragdollAllPlayers()
        maybeShowFirstDeathFairyToAll()
        return
    end
    if gameOverFired then return end

    local isLastWaveOfStage = waveIndex >= #WAVES
    local isLastStage = StageState.currentStage >= TOTAL_STAGES
    local isFinalBossWave = waveIndex == 0  -- "wave 0" of the final fight (special)

    -- Map-1 final boss cleared (The Mold King — not Pickle Lord; Pickle
    -- Lord is the future run boss). Instead of ending the run with a
    -- VICTORY modal, we open the path to map 2:
    --   1. Fire BossDefeated so the east-wall portal activates + the rope
    --      ladder drops from the ceiling above it (see Map2.lua).
    --   2. Fire a falling-leaf flavor message to all players ("the path
    --      above opens") so they know to look for the ladder.
    --   3. Do NOT fire GameOver — the run continues on map 2 after the
    --      player interacts with the portal + picks a bonus tower.
    -- The final VICTORY modal now belongs to a later map's final boss
    -- (once map 2+ have their own final encounters). For now, this
    -- path leads into an ongoing map 2 run with no hard end-of-game.
    if isFinalBossWave then
        StageState.finalBossActive = false
        ctx.FinalBossState.instance = nil
        -- Award persistent attachment(s) (kept as-is — they unlock on
        -- Pickle-Lord defeat regardless of whether we gate on map 2).
        local bossDefeatedBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.BossDefeated)
        if bossDefeatedBindable then
            -- Pass mapId so the temp-tower reward system knows which rarity-
            -- weight pool to roll from (Map1 = low-bias, Map2 = mid, Map3 = high).
            bossDefeatedBindable:Fire({ mapId = StageState.currentMapId or 1 })
        end
        -- Ladder drop + "path above opens" leaf message fire from Map2.lua
        -- via BossRewardClaimed AFTER the player has claimed their temp-tower
        -- pick. Keeps those cinematic beats from happening behind the picker.
        print("[Waves] Map boss defeated — temp-tower picker up, ladder + leaf deferred to post-pick")
        return
    end

    if isLastWaveOfStage then
        -- Stage boss reward (all 3 stages): +1 Reroll Token per player.
        -- Stage 3's grant is silent here (the map-boss fight starts
        -- immediately, no banner space); stages 1/2 banner + grant are
        -- handled in the else-branch below which fires StageCleared.
        if isLastStage then
            for _, p in ipairs(Players:GetPlayers()) do
                local current = p:GetAttribute("RerollTokens") or 0
                p:SetAttribute("RerollTokens", current + 1)
            end
        end
        if isLastStage then
            -- Stage 3's wave 5 cleared → spawn the final boss
            -- (heart NOT healed here; carry-over HP into the final fight)
            StageState.finalBossActive = true
            StageState.currentMapName = FINAL_BOSS_MAP_NAME
            -- Tell the hub to do the night reskin (sun sets, torches lit)
            remoteStageReskin:FireAllClients({
                stage     = StageState.currentStage,
                stageName = FINAL_BOSS_MAP_NAME,
                isNight   = true,
            })
            local stageAdvancedBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.StageAdvanced)
            if stageAdvancedBindable then
                -- Use stage 4 sentinel to signal "night / final boss" to the hub
                stageAdvancedBindable:Fire({stage = 4, mapId = StageState.currentMapId or 1})
            end
            -- Run the boss as its own "wave" using waveIndex 0 sentinel.
            -- Boss identity depends on the map:
            --   map 1 → finalboss (Pickle Lord, legacy default)
            --   map 2 → spider (The Pantry Spider, map-specific)
            --   map 3 → TBD (bird when that map lands)
            -- FinalBossState.instance is only set for actual "finalboss" so
            -- the Pickle-Lord-only phase mechanics don't fire on map-2 spider.
            local mapId = StageState.currentMapId or 1
            local bossMobType = (mapId == 2) and "spider" or "finalboss"
            task.spawn(function()
                local waypoints = getWaypoints()
                local mob = ctx.makeMob(bossMobType, waypoints, 1.0)
                if mob and bossMobType == "finalboss" then
                    ctx.FinalBossState.instance = mob
                    ctx.FinalBossState.triggeredPhases = {}
                end
                broadcastWaveState()
                -- Wait for boss death OR heart death. Poll the actual spawned
                -- mob — FinalBossState.instance is only set for Pickle Lord,
                -- so checking it would cause the spider fight to end instantly.
                while mob and mob.Parent do
                    if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                        return  -- heart died; main loop's gameOver handler takes over
                    end
                    task.wait(WaveConfig.waveClearedPollInterval)
                end
                onWaveCleared(0)  -- map boss dead → fires BossDefeated → picker
            end)
        else
            -- Stages 1 and 2: fire StageCleared banner (heal + transition).
            -- Grant +1 Reroll Token to every player (stage-boss reward per
            -- the locked design: stage bosses → reroll tokens, map bosses →
            -- temp towers, run boss → seedlings).
            for _, p in ipairs(Players:GetPlayers()) do
                local current = p:GetAttribute("RerollTokens") or 0
                p:SetAttribute("RerollTokens", current + 1)
            end
            -- If this clear was dev-skipped, skip the UI fire so a dev can
            -- spam Skip Wave through waves without UI noise. The stage
            -- advance + token grant still run on the server — only the
            -- banner is skipped.
            StageState.inTransition = true
            local suppressUI = os.clock() < (ctx._devSkipSuppressUntil or 0)
            if not suppressUI then
                remoteStageCleared:FireAllClients({
                    stage           = StageState.currentStage,
                    nextStage       = StageState.currentStage + 1,
                    totalStages     = TOTAL_STAGES,
                    autoContinueIn  = WaveConfig.stageContinueAutoDelay,
                    rerollsAwarded  = 1,
                })
            end
            local scheduledToken = waveRunToken
            task.delay(WaveConfig.stageContinueAutoDelay, function()
                if waveRunToken ~= scheduledToken then return end
                if StageState.inTransition then
                    advanceStage()
                end
            end)
        end
        return
    end

    -- Mid-stage wave clear → offer upgrade picks
    for _, player in ipairs(Players:GetPlayers()) do
        remoteShowUpgrades:FireClient(player, ctx.generateCardsForPlayer(player, waveIndex))
    end
end

-- Advance from the current stage to the next: heal heart, broadcast reskin
-- to the hub server (which animates sun + grows trees), reset wave counter
-- to 0, restart wave 1 after a short countdown.
function advanceStage()
    if not StageState.inTransition then return end
    StageState.inTransition = false
    StageState.currentStage = StageState.currentStage + 1
    -- Heal heart to full (the only stage reward)
    local heart = getHeart()
    if heart then
        local maxHp = heart:GetAttribute("MaxHealth") or 500
        heart:SetAttribute("Health", maxHp)
    end
    -- Reset rerolls for the new stage
    for _, p in ipairs(Players:GetPlayers()) do
        p:SetAttribute("RerollsUsed", 0)
    end
    -- Update the map name for the HUD if the stage has its own name
    local cfg = Stages[StageState.currentStage]
    if cfg and cfg.name then
        StageState.currentMapName = cfg.name
    end
    -- Tell the hub to do the visual transition
    remoteStageReskin:FireAllClients({
        stage    = StageState.currentStage,
        stageName = (cfg and cfg.name) or "",
    })
    -- Also notify the hub's server-side handler (geometry changes, lighting)
    local stageAdvancedBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.StageAdvanced)
    if stageAdvancedBindable then
        stageAdvancedBindable:Fire({stage = StageState.currentStage, mapId = StageState.currentMapId or 1})
    end
    -- Reset wave counter and broadcast countdown to next wave. Countdown
    -- scales with ctx.gameSpeed so "2x speed" really does shorten the
    -- between-wave pause, matching mob spawn intervals which already use
    -- the same divisor (see `task.wait(spawn.interval / ctx.gameSpeed)`).
    currentWave = 0
    local stageCountdown = WaveConfig.upgradePickToNextWaveDelay / ctx.gameSpeed
    remoteWaveState:FireAllClients({
        map = StageState.currentMapName,
        stage = StageState.currentStage,
        wave = 0, totalWaves = #WAVES, mobsAlive = 0,
        inProgress = false,
        pendingCountdown = stageCountdown,
    })
    -- Capture the waveRunToken NOW; bumping it (via RunReset, DevSkipToBoss,
    -- SwitchMap, etc.) invalidates this scheduled auto-start so the timer
    -- can't spawn wave 1 into a post-reset/post-skip game and double up
    -- with whatever's been spawned since.
    local scheduledToken = waveRunToken
    task.delay(stageCountdown, function()
        if waveRunToken ~= scheduledToken then return end
        if not waveInProgress and not gameOverFired then
            runWave(1)
        end
    end)
    print(("[Waves] Advanced to stage %d (%s)"):format(StageState.currentStage, (cfg and cfg.name) or "?"))
end

-- Player tapped Continue on the stage clear modal. We allow any player to
-- advance; the others' modals will auto-dismiss when the next wave starts.
remoteStageContinue.OnServerEvent:Connect(function(player)
    if not StageState.inTransition then return end
    advanceStage()
end)

-- Reroll handler: a player asks for a fresh set of 3 cards. Two paths:
--   * useToken = false (default): consumes one of the per-stage free
--     rerolls (capped at WaveConfig.maxRerollsPerStage, cleared on
--     DevReset).
--   * useToken = true: consumes one RerollToken from the player's
--     persistent balance (earned from stage-boss clears).
local rerollRemote = ReplicatedStorage:WaitForChild(Remotes.Names.RerollUpgrades)
rerollRemote.OnServerEvent:Connect(function(player, waveIndex, useToken)
    if type(waveIndex) ~= "number" then return end
    if useToken then
        local tokens = player:GetAttribute("RerollTokens") or 0
        if tokens <= 0 then return end
        player:SetAttribute("RerollTokens", tokens - 1)
        print(("[Waves] %s rerolled upgrades via token (%d left)"):format(
            player.Name, tokens - 1))
    else
        local rerollsUsed = player:GetAttribute("RerollsUsed") or 0
        if rerollsUsed >= WaveConfig.maxRerollsPerStage then return end
        player:SetAttribute("RerollsUsed", rerollsUsed + 1)
        print(("[Waves] %s rerolled upgrades (%d/%d used)"):format(
            player.Name, rerollsUsed + 1, WaveConfig.maxRerollsPerStage))
    end
    remoteShowUpgrades:FireClient(player, ctx.generateCardsForPlayer(player, waveIndex))
end)

-- Free reward bindable: hub server fires this when a player places their first
-- tower of the run. Generates a normal card set and shows the picker.
local giveFreeRewardBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.GiveFreeReward)
if not giveFreeRewardBindable then
    giveFreeRewardBindable = Instance.new("BindableEvent")
    giveFreeRewardBindable.Name = Remotes.Names.GiveFreeReward
    giveFreeRewardBindable.Parent = ReplicatedStorage
end
giveFreeRewardBindable.Event:Connect(function(player)
    if not player or not player:IsA("Player") then return end
    -- Use waveIndex 0 since this is pre-wave; the picker just shows cards.
    remoteShowUpgrades:FireClient(player, ctx.generateCardsForPlayer(player, 0))
    print(("[Waves] Free reward granted to %s (first tower placed)"):format(player.Name))
end)

-- BossTargetTap + BossPhaseMiss handlers now live in systems/FinalBoss.lua.

remoteUpgradePicked.OnServerEvent:Connect(function(player, upgrade)
    ctx.applyUpgrade(player, upgrade)

    -- Auto-start the next wave 3 seconds after picking. Scales by
    -- ctx.gameSpeed so the pause shrinks on 2x/3x, matching spawn pacing.
    if currentWave < #WAVES and not waveInProgress and not gameOverFired then
        local nextWaveCountdown = WaveConfig.upgradePickToNextWaveDelay / ctx.gameSpeed
        remoteWaveState:FireAllClients({
            wave = currentWave, totalWaves = #WAVES, mobsAlive = 0,
            inProgress = false, pendingCountdown = nextWaveCountdown,
        })
        -- Guard the auto-start against stale fires: RunReset / DevSkipToBoss /
        -- SwitchMap bump waveRunToken, which invalidates this scheduled
        -- runWave so it can't double up with whatever's already in play.
        local scheduledToken = waveRunToken
        task.delay(nextWaveCountdown, function()
            if waveRunToken ~= scheduledToken then return end
            if not waveInProgress and not gameOverFired and currentWave < #WAVES then
                runWave(currentWave + 1)
            end
        end)
    end
end)

------------------------------------------------------------
-- DEV: add a Stun stack to all of the calling player's towers. Mirrors
-- what picking a Stun special card does (uses SPECIAL_EFFECTS["Stun"]
-- base/increment), but bypasses the upgrade-picked path so it doesn't
-- inflate RUN LUCK or affect the wave-progression flow. Used from the
-- dev panel for testing the stun mechanic without waiting on RNG.
------------------------------------------------------------
remoteDevAddStun.OnServerEvent:Connect(function(player)
    local touched = ctx.applyStunStackToOwnedTowers(player)
    print(("[Waves] DEV: %s added Stun stack to %d tower(s)"):format(player.Name, touched))
end)

------------------------------------------------------------
-- DEV: reset all per-tower cooldowns AND timed buffs for the calling
-- player. Useful for testing Phoenix without waiting 12+ minutes between
-- triggers, and for clearing leftover BonusDamageUntil from boss minigame
-- testing. Iterates only towers owned by the caller.
------------------------------------------------------------
remoteDevResetCd.OnServerEvent:Connect(function(player)
    local touched = 0
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = towerBase.Parent
        if t and t:GetAttribute("Owner") == player.UserId then
            -- Phoenix: ready immediately, no cooldown, no active grace.
            -- Set the attributes regardless of EquippedType — cheap, and
            -- harmless on towers without Phoenix (they just get unused
            -- attributes set to 0/true, which they ignore).
            if t:GetAttribute("EquippedType") == "Phoenix" then
                t:SetAttribute("PhoenixReady", true)
                t:SetAttribute("PhoenixCdRemaining", 0)
                t:SetAttribute("PhoenixGraceRemaining", 0)
                ctx.phoenixDisplayCd[t]    = nil
                ctx.phoenixDisplayGrace[t] = nil
            end
            touched = touched + 1
        end
    end
    -- Server-side grace state (for the actual mob-teleport check) — clear it
    -- too so a "reset" really means everything is cold.
    ctx.PhoenixGrace.activeUntil = 0
    -- Final-boss bonus damage timer (set by completing the tap minigame).
    player:SetAttribute("BonusDamageUntil", 0)
    player:SetAttribute("BonusDamageExtraPct", 0)
    print(("[Waves] DEV: %s reset cooldowns on %d tower(s)"):format(player.Name, touched))
end)

------------------------------------------------------------
-- DEV: skip to the current stage's boss, with the player's towers
-- upgraded as if they'd played to that wave with average luck (display = 5
-- on the luck meter, which corresponds to a "greedy best-of-3" pick
-- average score of 2.71 per pick).
--
-- Pick simulation rules (each iteration):
--   1. Call generateCardsForPlayer to roll 3 cards using normal RNG.
--   2. Sort cards by rarity score (high → low), break ties by index.
--   3. Walk the sorted list: skip Range stat cards if the player's
--      cumulative RangeBonusPct on any owned tower is already >= 60%.
--      This matches the user's playstyle: never overcap on Range.
--   4. Apply the first non-skipped card via applyUpgrade (which
--      handles tower attribute updates AND RUN LUCK tracking).
--
-- Then we stop any in-progress wave, clear active mobs, and spawn just
-- the boss (skipping the stage's wave-5 mob spawns). On boss death the
-- normal wave-5-cleared path runs (stage transition or final boss).
------------------------------------------------------------


remoteDevSkipToBoss.OnServerEvent:Connect(function(player)
    -- Cancel any in-progress wave, clear all mobs and stage-boss state.
    -- Bumping waveRunToken is the important part: it invalidates any
    -- still-alive spawner coroutine from the prior wave, so a mob group
    -- waking up from task.wait(spawn.interval) won't continue spawning
    -- alongside the boss.
    skipRequested = true
    waveInProgress = false
    waveRunToken = waveRunToken + 1
    local myToken = waveRunToken
    ctx.clearAllMobs()
    ctx.FinalBossState.instance = nil
    ctx.FinalBossState.triggeredPhases = {}
    ctx.FinalBossState.windupUntil = 0
    ctx.FinalBossState.pendingPhase = nil

    -- How many picks SHOULD the player have done by the start of this
    -- stage's wave 5? Each stage gives 4 pickers (after waves 1-4). So
    -- by the boss of stage S, the player has had (S-1)*4 + 4 = S*4 picks
    -- from prior stages and current stage waves 1-4. Uses MapPickCount
    -- (per-map counter) not RunLuckCount (run-wide), so map 2 doesn't
    -- see map 1's 12 picks and simulate zero.
    local targetPicks = StageState.currentStage * 4
    local currentPicks = player:GetAttribute("MapPickCount") or 0
    local picksNeeded = math.max(0, targetPicks - currentPicks)

    -- Synthesize the picks. Pass the absolute pick index so the simulator
    -- knows "this is pick 4 of stage 2" (wave-in-stage = 4) to apply the
    -- late-stage reroll-if-nothing-rare rule.
    for idx = currentPicks + 1, currentPicks + picksNeeded do
        ctx.simulateOnePick(player, idx)
    end

    print(("[Waves] DEV: %s skipping to stage %d boss; simulated %d pick(s)"):format(
        player.Name, StageState.currentStage, picksNeeded))

    -- Now spawn the boss as if the wave-5 mob spawns had completed.
    -- Reuses the wave-5-cleared path: when the boss dies, onWaveCleared(5)
    -- runs and triggers the appropriate next step (stage transition for
    -- stages 1-2, final boss spawn for stage 3).
    currentWave = #WAVES  -- = 5
    waveInProgress = true
    skipRequested = false
    broadcastWaveState()

    task.spawn(function()
        local waypoints = getWaypoints()
        -- Stage 1/2 = Mold King stage boss; stage 3 = the map's final boss.
        -- Substitute per map so map 2 gets a spider, not Mold King or Pickle Lord.
        local bossMobType = "boss"
        if StageState.currentStage >= 3 then
            local mapId = StageState.currentMapId or 1
            bossMobType = (mapId == 2) and "spider" or "finalboss"
        end
        ctx.makeMob(bossMobType, waypoints, 1.0)  -- waveMult ignored for bosses anyway
        broadcastWaveState()

        -- Drain loop: polls until the boss dies (by the player's towers or
        -- further dev input). When active mobs reach 0, onWaveCleared fires
        -- the normal stage-clear / boss-defeat path.
        -- NOTE: the previous auto-kill was removed now that K (SKIP WAVE)
        -- is a separate hotkey — BOSS just sets up the fight; K drops the
        -- boss if the player wants to fast-forward the reward.
        while ctx.countActiveMobs() > 0 do
            if waveRunToken ~= myToken then return end
            local heart = getHeart()
            if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                waveInProgress = false
                broadcastWaveState()
                return
            end
            task.wait(WaveConfig.waveClearedPollInterval)
            broadcastWaveState()
        end
        if waveRunToken ~= myToken then return end
        waveInProgress = false
        broadcastWaveState()
        onWaveCleared(#WAVES)
    end)
end)

------------------------------------------------------------
-- DEV SKIP TO MAP BOSS — dev speedrun straight to the end of the current
-- map. Jumps currentStage to 3 regardless of where the player is, simulates
-- all the picks they would have had by then, spawns the map boss, and
-- auto-kills it. Triggers the real boss-defeat path: onWaveCleared → fires
-- BossDefeated → temp-tower picker appears (the reward the player would
-- normally get for beating the map). One click from a fresh run.
--
-- Reuses the same mechanics as DevSkipToBoss but forces stage=3, so even
-- if the player just started, they get dropped straight at the map boss.
------------------------------------------------------------
remoteDevSkipToMapBoss.OnServerEvent:Connect(function(player)
    skipRequested = true
    waveInProgress = false
    waveRunToken = waveRunToken + 1
    local myToken = waveRunToken
    ctx.clearAllMobs()
    ctx.FinalBossState.instance = nil
    ctx.FinalBossState.triggeredPhases = {}
    ctx.FinalBossState.windupUntil = 0
    ctx.FinalBossState.pendingPhase = nil

    -- Force stage 3 so onWaveCleared's final-boss branch fires when the boss
    -- dies, which in turn fires BossDefeated → temp-tower picker.
    StageState.currentStage = 3

    -- Simulate picks for the full 3 stages (stages 1+2 = 8 picks, current
    -- stage waves 1-4 = 4 picks, total 12). Per-map counter, same as
    -- DevSkipToBoss above.
    local targetPicks = 3 * 4
    local currentPicks = player:GetAttribute("MapPickCount") or 0
    local picksNeeded = math.max(0, targetPicks - currentPicks)
    for _ = 1, picksNeeded do
        ctx.simulateOnePick(player)
    end

    print(("[Waves] DEV: %s skipping to MAP BOSS; forced stage=3, simulated %d pick(s)"):format(
        player.Name, picksNeeded))

    currentWave = #WAVES  -- = 5
    waveInProgress = true
    skipRequested = false
    broadcastWaveState()

    task.spawn(function()
        local waypoints = getWaypoints()
        ctx.makeMob("boss", waypoints, 1.0)
        broadcastWaveState()

        -- Auto-kill (same pattern as DevSkipToBoss).
        for mob, data in pairs(ctx.activeMobs) do
            if mob and mob.Parent then
                data.hp = 0
                if data.hpFill then data.hpFill:Destroy() end
                if data.hpText then data.hpText:Destroy() end
                if data.bbAnchor then data.bbAnchor:Destroy() end
                if mob == ctx.FinalBossState.instance then
                    ctx.FinalBossState.instance = nil
                end
                mob:Destroy()
                ctx.activeMobs[mob] = nil
            end
        end

        while ctx.countActiveMobs() > 0 do
            if waveRunToken ~= myToken then return end
            local heart = getHeart()
            if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                waveInProgress = false
                broadcastWaveState()
                return
            end
            task.wait(WaveConfig.waveClearedPollInterval)
            broadcastWaveState()
        end
        if waveRunToken ~= myToken then return end
        waveInProgress = false
        broadcastWaveState()
        onWaveCleared(#WAVES)
    end)
end)

------------------------------------------------------------
-- DEV SIMULATE MAP 1 PICKS — fired by the hub when a player places their
-- first Core tower after a dev teleport straight to map 2. Runs the full
-- 12-pick simulation (3 stages × 4 picks) against the freshly-placed
-- Core so they arrive at map 2 with the same upgrade state they would
-- have had by completing map 1 legitimately.
--
-- Deferred to placement time (rather than done at teleport time) because
-- simulateOnePick's ammo-forcing thresholds read live Core SPS — the
-- tower has to exist for AmmoCapacity picks to trigger correctly.
------------------------------------------------------------
local simMap1Bindable = Remotes.getOrCreate(Remotes.Names.DevSimulateMap1Picks, "BindableEvent")
simMap1Bindable.Event:Connect(function(payload)
    if type(payload) ~= "table" then return end
    local player = payload.player
    local pickCount = tonumber(payload.pickCount) or 12
    if not player or not player:IsDescendantOf(Players) then return end
    -- Consume the flag FIRST so a re-entrant placement (shouldn't happen,
    -- but be defensive) can't double-fire.
    player:SetAttribute("DevSimulateMap1OnNextCore", nil)
    -- Temporarily spoof currentMapId=1 so generateCardsForPlayer rolls
    -- map-1 cards (Core-only, no Aux). Without this, the simulation would
    -- target half the picks at Aux cards — but the player had no Aux tower
    -- on map 1, so those upgrades would be wasted stat bumps stored on a
    -- non-existent Aux baseline. Core deserves the full 12 picks.
    local savedMapId = StageState.currentMapId
    StageState.currentMapId = 1
    local ok, err = pcall(function()
        for idx = 1, pickCount do
            ctx.simulateOnePick(player, idx)
        end
    end)
    StageState.currentMapId = savedMapId
    if not ok then warn("[Waves] DEV: map-1 simulation errored: " .. tostring(err)) end

    -- Reset the PER-MAP counter back to 0 so DevSkipToBoss on map 2 still
    -- sees `stage*4 - 0` picks remaining. RunLuckCount/Sum are left alone:
    -- the simulated 12 picks legitimately contribute to the player's
    -- run-wide luck display (same as if they'd played map 1 for real).
    player:SetAttribute("MapPickCount", 0)
    print(("[Waves] DEV: %s simulated %d map-1 picks on first Core placement"):format(
        player.Name, pickCount))
end)

------------------------------------------------------------
-- Game over detection (heart dies). gameOverFired is forward-declared at
-- the top of the file so onWaveCleared, advanceStage, the upgrade-picked
-- handler, and this poll task all share the SAME local. This line is just
-- initialization, not a new local.
------------------------------------------------------------
gameOverFired = false
task.spawn(function()
    while true do
        task.wait(0.5)
        local heart = getHeart()
        if heart and not gameOverFired then
            local hp = heart:GetAttribute("Health") or 0
            if hp <= 0 then
                gameOverFired = true
                -- If a boss was alive at the moment the heart fell, surface
                -- its display name to the client so the defeat banner can
                -- read "The Mold King has defeated you" instead of the
                -- generic "held out for N waves" line.
                local killerBossName
                for mob, _ in pairs(ctx.activeMobs) do
                    local mobType = string.gsub(mob.Name, "^Mob_", "")
                    local def = MOB_TYPES[mobType]
                    if def and (def.isFinal or mobType == "boss") then
                        killerBossName = def.displayName or mobType
                        break
                    end
                end
                ctx.clearAllMobs()
                waveInProgress = false
                broadcastWaveState()
                local completedStages = math.max(0, StageState.currentStage - 1)
                local wavesSoFar = (StageState.priorMapsWavesCompleted or 0)
                    + completedStages * #WAVES
                    + math.max(0, (currentWave or 1) - 1)
                remoteGameOver:FireAllClients({
                    result = "lose",
                    finalWave = currentWave,
                    totalWavesDefeated = wavesSoFar,
                    killerBossName = killerBossName,
                })
                ragdollAllPlayers()
                maybeShowFirstDeathFairyToAll()
            end
        end
    end
end)

-- Reset gameOverFired when DevReset fires (so you can restart after losing)
local devResetRemote = ReplicatedStorage:WaitForChild(Remotes.Names.DevReset)
devResetRemote.OnServerEvent:Connect(function(player)
    gameOverFired = false
    ctx.clearAllMobs()
    currentWave = 0
    waveInProgress = false
    broadcastWaveState()
end)

-- DEV: Skip Wave — kill all active mobs so the natural wave-cleared logic
-- fires. Works during waves (skips the rest) and during the final boss
-- (instakills the boss → triggers victory). No-op if no mobs alive.
local devSkipWaveRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSkipWave)
if not devSkipWaveRemote then
    devSkipWaveRemote = Instance.new("RemoteEvent")
    devSkipWaveRemote.Name = Remotes.Names.DevSkipWave
    devSkipWaveRemote.Parent = ReplicatedStorage
end
devSkipWaveRemote.OnServerEvent:Connect(function(player)
    print(("[Dev] %s pressed Skip Wave"):format(player.Name))
    -- Tell the spawn loop to stop spawning new mobs THIS wave
    skipRequested = true
    -- Any blocking UI that would fire in response to this wave's end
    -- (stage-complete banner/modal, boss attachment reveal) should
    -- self-suppress. Window-based so multiple consumers can all check
    -- it — a plain boolean would be cleared by whichever fires first,
    -- leaving the other unsuppressed. 3 seconds is long enough to
    -- cover the onWaveCleared → StageCleared / BossDefeated chain
    -- even with the wave-clear poll delay.
    ctx._devSkipSuppressUntil = os.clock() + 3
    -- Wipe everything currently alive so the post-spawn drain loop completes
    -- immediately and onWaveCleared fires next poll.
    for mob, data in pairs(ctx.activeMobs) do
        if mob and mob.Parent then
            data.hp = 0
            if data.hpFill then data.hpFill:Destroy() end
            if data.hpText then data.hpText:Destroy() end
            if data.bbAnchor then data.bbAnchor:Destroy() end
            if mob == ctx.FinalBossState.instance then
                ctx.FinalBossState.instance = nil
            end
            mob:Destroy()
            ctx.activeMobs[mob] = nil
        end
    end
    broadcastWaveState()
end)

-- DEV: Spawn the Web Weaver — map 2 final boss shortcut. Forces
-- currentMapId=2 so BossDefeated fires with Map2 temp-tower weights, then
-- spawns the spider mob on the current map's path. CanopySpiderBoss system
-- picks it up via its activeMobs watcher and starts the 15s web timer.
local devSpawnCanopyRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSpawnCanopySpider)
if not devSpawnCanopyRemote then
    devSpawnCanopyRemote = Instance.new("RemoteEvent")
    devSpawnCanopyRemote.Name = Remotes.Names.DevSpawnCanopySpider
    devSpawnCanopyRemote.Parent = ReplicatedStorage
end
devSpawnCanopyRemote.OnServerEvent:Connect(function(player)
    print(("[Dev] %s spawned the Web Weaver"):format(player.Name))
    StageState.currentMapId = 2  -- boss death fires temp-tower picker with Map2 weights
    StageState.currentStage = 3
    StageState.finalBossActive = true
    waveRunToken = waveRunToken + 1
    local myToken = waveRunToken
    ctx.clearAllMobs()
    ctx.FinalBossState.instance = nil
    ctx.FinalBossState.triggeredPhases = {}
    currentWave = #WAVES
    waveInProgress = true
    skipRequested = false
    broadcastWaveState()
    task.spawn(function()
        local waypoints = getWaypoints()
        local mob = ctx.makeMob("spider", waypoints, 1.0)
        broadcastWaveState()
        while mob and mob.Parent do
            if waveRunToken ~= myToken then return end
            local heart = getHeart()
            if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                waveInProgress = false
                broadcastWaveState()
                return
            end
            task.wait(WaveConfig.waveClearedPollInterval)
        end
        if waveRunToken ~= myToken then return end
        waveInProgress = false
        broadcastWaveState()
        -- Fires BossDefeated with mapId=2 → TempTowerRewards picker (Map2 weights)
        onWaveCleared(0)
    end)
end)

-- DEV: Spawn the Canopy Bird — map 3 final boss shortcut. Forces
-- currentMapId=3 so BossDefeated fires with Map3 temp-tower weights,
-- then spawns the bird mob on the current map's path. BirdBoss system
-- picks it up via its activeMobs watcher and starts the 12s dive timer.
local devSpawnBirdRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSpawnCanopyBird)
if not devSpawnBirdRemote then
    devSpawnBirdRemote = Instance.new("RemoteEvent")
    devSpawnBirdRemote.Name = Remotes.Names.DevSpawnCanopyBird
    devSpawnBirdRemote.Parent = ReplicatedStorage
end
devSpawnBirdRemote.OnServerEvent:Connect(function(player)
    print(("[Dev] %s spawned the Canopy Bird"):format(player.Name))
    StageState.currentMapId = 3
    StageState.currentStage = 3
    StageState.finalBossActive = true
    waveRunToken = waveRunToken + 1
    local myToken = waveRunToken
    ctx.clearAllMobs()
    ctx.FinalBossState.instance = nil
    ctx.FinalBossState.triggeredPhases = {}
    currentWave = #WAVES
    waveInProgress = true
    skipRequested = false
    broadcastWaveState()
    task.spawn(function()
        local waypoints = getWaypoints()
        local mob = ctx.makeMob("bird", waypoints, 1.0)
        broadcastWaveState()
        while mob and mob.Parent do
            if waveRunToken ~= myToken then return end
            local heart = getHeart()
            if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                waveInProgress = false
                broadcastWaveState()
                return
            end
            task.wait(WaveConfig.waveClearedPollInterval)
        end
        if waveRunToken ~= myToken then return end
        waveInProgress = false
        broadcastWaveState()
        onWaveCleared(0)  -- fires BossDefeated(mapId=3) → Map 3 temp-tower picker
    end)
end)

-- DEV: Unlimited Ammo — toggle a per-player flag. updateTowers reads it
-- via the tower's owner and skips Shots decrement when set.
local devUnlimitedAmmoRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevUnlimitedAmmo)
if not devUnlimitedAmmoRemote then
    devUnlimitedAmmoRemote = Instance.new("RemoteEvent")
    devUnlimitedAmmoRemote.Name = Remotes.Names.DevUnlimitedAmmo
    devUnlimitedAmmoRemote.Parent = ReplicatedStorage
end
devUnlimitedAmmoRemote.OnServerEvent:Connect(function(player, enabled)
    player:SetAttribute("DevUnlimitedAmmo", enabled and true or false)
    print(("[Dev] %s toggled Unlimited Ammo: %s"):format(
        player.Name, tostring(enabled and true or false)))
end)

------------------------------------------------------------
-- Wave start request from client
------------------------------------------------------------
remoteWaveStart.OnServerEvent:Connect(function(player)
    if waveInProgress then return end
    if gameOverFired then return end
    local nextWave = currentWave + 1
    if nextWave > #WAVES then return end
    print(("[Waves] %s started wave %d"):format(player.Name, nextWave))
    runWave(nextWave)
end)

-- Auto-start listener: hub server fires this when a player places their first
-- tower, with a 5 second delay. Triggers wave 1 just like manual start.
local autoStartBindable = ReplicatedStorage:WaitForChild(Remotes.Names.WaveAutoStart)
autoStartBindable.Event:Connect(function(player)
    if waveInProgress then return end
    if gameOverFired then return end
    if currentWave ~= 0 then return end  -- only auto-start the VERY first wave
    print(("[Waves] Auto-starting wave 1 (triggered by %s)"):format(player.Name))
    runWave(1)
end)

-- RunReset listener: hub fires this on DevReset so wave system fully resets
-- its run/stage state in addition to the hub's tower/grid/heart resets.
local runResetBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.RunReset)
if not runResetBindable then
    runResetBindable = Instance.new("BindableEvent")
    runResetBindable.Name = Remotes.Names.RunReset
    runResetBindable.Parent = ReplicatedStorage
end
runResetBindable.Event:Connect(function()
    StageState.currentStage = 1
    StageState.currentMapId   = 1
    StageState.currentMapName = (Stages[1] and Stages[1].name) or "Crook of the Tree (Morning)"
    StageState.inTransition = false
    StageState.finalBossActive = false
    StageState.priorMapsWavesCompleted = 0
    ctx.FinalBossState.instance = nil
    ctx.FinalBossState.triggeredPhases = {}
    ctx.FinalBossState.lastPhaseFire = 0
    ctx.FinalBossState.windupUntil = 0
    ctx.FinalBossState.pendingPhase = nil
    -- CRITICAL: clear paused state. If the player left the game paused
    -- and then hit reset, ctx.paused would remain true → MobUpdate and
    -- Towers early-exit forever → mobs don't move + reset looks broken.
    -- Also broadcast so the speed-bar UI un-highlights the pause button.
    if ctx.paused then
        ctx.paused = false
        gameSpeedChangedRemote:FireAllClients(ctx.gameSpeed)
    end
    currentWave = 0
    waveInProgress = false
    gameOverFired = false
    -- Bump the token so any in-flight wave spawner sees it's been replaced
    -- and aborts on its next iteration. Prevents a mob group from a
    -- pre-reset wave spawning into the post-reset game.
    waveRunToken = waveRunToken + 1
    -- Clear any active mobs (hub will have already destroyed towers)
    ctx.clearAllMobs()
    -- Reset per-player RUN LUCK tracking so each new run starts fresh
    for _, p in ipairs(Players:GetPlayers()) do
        p:SetAttribute("RunLuckSum", 0)
        p:SetAttribute("RunLuckCount", 0)
    end
    print("[Waves] RunReset: stage→1, mobs cleared, state cleared, run luck reset")
end)

------------------------------------------------------------
-- SwitchMap listener: hub fires this when the player walks through a
-- map portal. Sets the active map id, broadcasts wave state so client
-- HUDs update, clears active mobs and stage state for the new map's
-- wave 1 to start fresh. Heart HP is owned per-map (set at map build
-- time in the hub) so we don't touch it here.
--
-- Payload: {mapId = 2, mapName = "Climbing the Tree"}
------------------------------------------------------------
local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
if not switchMapBindable then
    switchMapBindable = Instance.new("BindableEvent")
    switchMapBindable.Name = Remotes.Names.SwitchMap
    switchMapBindable.Parent = ReplicatedStorage
end
switchMapBindable.Event:Connect(function(payload)
    if not payload or not payload.mapId then return end
    local newId = payload.mapId
    local newName = payload.mapName or ("Map " .. tostring(newId))

    -- Bump the wave run token so any in-flight spawner from the prior map
    -- bails on its next iteration and doesn't keep spawning into map 2.
    waveRunToken = waveRunToken + 1
    waveInProgress = false
    skipRequested = true
    gameOverFired = false  -- reset — switching maps is a clean slate (also covers dev-teleporting-after-death)
    ctx.clearAllMobs()
    ctx.FinalBossState.instance = nil
    ctx.FinalBossState.triggeredPhases = {}
    ctx.FinalBossState.windupUntil = 0
    ctx.FinalBossState.pendingPhase = nil

    -- Roll over completed waves to the run-wide counter BEFORE resetting
    -- currentStage/currentWave. Assumes the outgoing map was fully cleared
    -- (SwitchMap only fires after a map-boss defeat claim or a dev teleport;
    -- in dev cases the counter may over-count slightly, which is fine for
    -- the GameOver banner's purposes — it's a flavor number, not a stat).
    if StageState.currentMapId and StageState.currentMapId ~= newId then
        StageState.priorMapsWavesCompleted = (StageState.priorMapsWavesCompleted or 0) + (#WAVES * TOTAL_STAGES)
    end

    StageState.currentMapId   = newId
    StageState.currentMapName = newName
    StageState.currentStage   = 1  -- new map starts at stage 1
    StageState.inTransition   = false
    StageState.finalBossActive = false
    currentWave = 0

    -- Reset PER-MAP pick counter so each map starts DevSkipToBoss math at 0.
    -- RunLuckSum / RunLuckCount stay cumulative across the whole run — they
    -- drive the client's run-luck display and should reflect ALL picks the
    -- player has seen this run (real + dev-simulated), not just this map.
    for _, p in ipairs(Players:GetPlayers()) do
        p:SetAttribute("MapPickCount", 0)
    end

    -- Grant 1× Core stock on entry to any map after map 1. The player's
    -- map-1 Core tower is stuck on map 1 (it still sits on the grid there),
    -- so without a fresh stock they'd reach map 2 with nothing to place.
    -- Cumulative upgrades (Core<Stat>Pct / Core specials) stamp onto the
    -- new tower at placement time via the hub's placement handler, so the
    -- freshly-placed Core arrives with all prior upgrades intact.
    --
    -- Permanent tower gets the same treatment: if the player has one
    -- equipped (from a prior run's Pickle Lord kill), grant 1× more stock
    -- of it so Aux permanents stay in lockstep with Core across maps.
    if newId >= 2 then
        -- Stock semantics: at-most N per map entry (max(N, current)) —
        -- never overwrite leftover stock downward (generous) and never
        -- accumulate above N (bug: +1 each map could hand the player 2+
        -- Cores if they skipped placing on map 1).
        for _, p in ipairs(Players:GetPlayers()) do
            local curCore = p:GetAttribute("PowerStock") or 0
            p:SetAttribute("PowerStock", math.max(1, curCore))
            local equipped = PermanentTowerStore.getEquipped(p)
            if equipped then
                local tpl = TempTowers.Templates[equipped.type]
                if tpl then
                    p:SetAttribute(equipped.type .. "Rarity", equipped.rarity)
                    local curAux = p:GetAttribute(equipped.type .. "Stock") or 0
                    p:SetAttribute(equipped.type .. "Stock", math.max(tpl.stock, curAux))
                end
            end
        end
        -- Ping the hotbar so the new slot appears immediately.
        local showHotbarRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.ShowHotbar)
        if showHotbarRemote then
            for _, p in ipairs(Players:GetPlayers()) do
                showHotbarRemote:FireClient(p)
            end
        end
    end

    -- Broadcast cleared wave state. Client HUDs will see Wave 0 and the
    -- new map name.
    remoteWaveState:FireAllClients({
        wave = 0,
        totalWaves = #WAVES,
        mobsAlive = 0,
        inProgress = false,
        map = newName,
        stage = 1,
        pendingCountdown = nil,
    })

    -- Auto-start wave 1 of the new map after a pause (6.5s) so the
    -- player has time to look around, read the leaf message, and place
    -- their Core tower without wave 1 spawning on top of them. Token-
    -- guarded so a reset / DevSkipToBoss between SwitchMap and the
    -- delayed fire doesn't double-spawn.
    local scheduledToken = waveRunToken
    task.delay(6.5, function()
        if waveRunToken ~= scheduledToken then return end
        if StageState.currentMapId == newId and not waveInProgress then
            skipRequested = false
            runWave(1)
        end
    end)

    print(("[Waves] SwitchMap → mapId=%d (%s); wave 1 auto-starts in 6.5s"):format(newId, newName))
end)

------------------------------------------------------------
-- Main update loop: move mobs, fire towers, tick Phoenix cooldowns.
-- The tower list is fetched once per Heartbeat and shared by both
-- updateTowers and tickPhoenixCooldowns — they previously each called
-- CollectionService:GetTagged(Tags.Tower) independently every frame, doing
-- the same allocation work twice.
------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
    if dt > 0.1 then dt = 0.1 end  -- clamp to avoid teleports on lag spikes
    local towerList = CollectionService:GetTagged(Tags.Tower)
    ctx.updateMobs(dt)
    ctx.updateTowers(towerList)
    ctx.tickPhoenixCooldowns(dt, towerList)
end)

print("[Waves] Wave system v1.83 ready.")
