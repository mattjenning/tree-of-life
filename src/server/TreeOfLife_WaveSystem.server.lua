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
local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Tags    = require(Shared:WaitForChild("Tags"))
local Config  = require(Shared:WaitForChild("Config"))

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
local remoteDevSkipToBoss = ensureRemote(Remotes.Names.DevSkipToBoss)  -- client → server: dev panel skip to current stage's boss with simulated upgrades
local remoteDevResetCd    = ensureRemote(Remotes.Names.DevResetCooldowns)  -- client → server: dev panel reset all per-tower cooldowns + bonus timers

------------------------------------------------------------
-- Config
------------------------------------------------------------

-- All tunable gameplay numbers in one place. Search this section first
-- when balancing. Named WaveConfig (not just Config) because the shared
-- Config module (grid, map2, phoenix) is also imported above — having
-- two locals called `Config` would collide.
local WaveConfig = {
    -- Status effect proc chances (per hit)
    stunTriggerChance      = 0.20,
    knockbackTriggerChance = 0.10,
    knockbackSlideTime     = 0.25,  -- seconds for the slide-back animation

    -- Reroll
    maxRerollsPerStage = 1,

    -- Pacing between waves
    upgradePickToNextWaveDelay = 3,    -- seconds after picking before next wave
    waveClearedPollInterval    = 0.3,  -- seconds between activeMobs polls

    -- Stage transitions
    stageContinueAutoDelay = 6,        -- seconds before stage clear modal auto-advances

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
    -- Wave 2: +10% HP, basic + fast mix
    {
        hpMult = 1.10,
        spawns = {
            {count = 5, interval = 0.6, mobType = "basic", gap = 1.8},
            {count = 5, interval = 0.4, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 0.5, mobType = "basic", gap = 1.5},
            {count = 5, interval = 0.4, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 0.4, mobType = "basic", gap = 0},
        },
    },
    -- Wave 3: +20% HP, tanks + mixed types
    {
        hpMult = 1.20,
        spawns = {
            {count = 5, interval = 0.7, mobType = "basic", gap = 2.0},
            {count = 5, interval = 1.0, mobType = "tank",  gap = 2.5},
            {count = 5, interval = 0.5, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 1.0, mobType = "tank",  gap = 2.0},
            {count = 5, interval = 0.3, mobType = "basic", gap = 0},
        },
    },
    -- Wave 4: +30% HP, denser mix, more tanks. AOE-test groups bumped +4.
    {
        hpMult = 1.30,
        spawns = {
            {count = 6,  interval = 0.5, mobType = "basic", gap = 1.5},
            {count = 5,  interval = 0.8, mobType = "tank",  gap = 2.0},
            {count = 12, interval = 0.3, mobType = "fast",  gap = 1.8},  -- AOE test: 8→12
            {count = 6,  interval = 0.7, mobType = "tank",  gap = 1.5},
            {count = 12, interval = 0.3, mobType = "basic", gap = 0},    -- AOE test: 8→12
        },
    },
    -- Wave 5: +40% HP, then a single GIANT BOSS at the end. AOE-test
    -- groups bumped +4 each.
    {
        hpMult = 1.40,
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
    finalboss = {hp = 17000, speed = 3.3,  color = Color3.fromRGB(120, 30, 180),
                 size = 14,  displayName = "The Pickle Lord", isFinal = true},
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
    if not ALLOWED_SPEEDS[requested] then return end
    if requested == ctx.gameSpeed then return end
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
        for _, spawn in ipairs(spawns) do
            for i = 1, spawn.count do
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
                local mob = ctx.makeMob(spawn.mobType, waypoints, hpMult)
                if spawn.mobType == "finalboss" and mob then
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


function onWaveCleared(waveIndex)
    -- If the heart died on the same tick the last mob died, don't offer
    -- upgrades — the game is already lost.
    local heart = getHeart()
    if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
        gameOverFired = true
        local completedStages = math.max(0, StageState.currentStage - 1)
        local wavesSoFar = completedStages * #WAVES + math.max(0, (currentWave or 1) - 1)
        remoteGameOver:FireAllClients({
            result = "lose",
            finalWave = waveIndex,
            totalWavesDefeated = wavesSoFar,
        })
        return
    end
    if gameOverFired then return end

    local isLastWaveOfStage = waveIndex >= #WAVES
    local isLastStage = StageState.currentStage >= TOTAL_STAGES
    local isFinalBossWave = waveIndex == 0  -- "wave 0" of the final fight (special)

    -- Map-1 final boss cleared (Pickle Lord). Instead of ending the run
    -- with a VICTORY modal, we open the path to map 2:
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
            bossDefeatedBindable:Fire()
        end
        -- Falling-leaf flavor message for all players. Broadcast via the
        -- LeafMessage remote (which is normally a single-player fire via
        -- ctx.fireLeafMessage, but we want everyone in the run to see it).
        local leafRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)
        if leafRemote then
            leafRemote:FireAllClients({
                text = "The path above opens... a ladder drops from the canopy",
                duration = 8,
            })
        end
        print("[Waves] Pickle Lord defeated — rope ladder drops, portal opens, run continues")
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
            task.spawn(function()
                local waypoints = getWaypoints()
                local mob = ctx.makeMob("finalboss", waypoints, 1.0)
                if mob then
                    ctx.FinalBossState.instance = mob
                    ctx.FinalBossState.triggeredPhases = {}
                end
                broadcastWaveState()
                -- Wait for boss death OR heart death
                while ctx.FinalBossState.instance and ctx.FinalBossState.instance.Parent do
                    if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                        return  -- heart died; main loop's gameOver handler takes over
                    end
                    task.wait(WaveConfig.waveClearedPollInterval)
                end
                onWaveCleared(0)  -- final boss dead → win
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
            task.delay(WaveConfig.stageContinueAutoDelay, function()
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
    -- Reset wave counter and broadcast countdown to next wave
    currentWave = 0
    remoteWaveState:FireAllClients({
        map = StageState.currentMapName,
        stage = StageState.currentStage,
        wave = 0, totalWaves = #WAVES, mobsAlive = 0,
        inProgress = false,
        pendingCountdown = WaveConfig.upgradePickToNextWaveDelay,
    })
    task.delay(WaveConfig.upgradePickToNextWaveDelay, function()
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

-- Reroll handler: a player asks for a fresh set of 3 cards. Capped at
-- WaveConfig.maxRerollsPerStage per stage (cleared on DevReset).
local rerollRemote = ReplicatedStorage:WaitForChild(Remotes.Names.RerollUpgrades)
rerollRemote.OnServerEvent:Connect(function(player, waveIndex)
    if type(waveIndex) ~= "number" then return end
    local rerollsUsed = player:GetAttribute("RerollsUsed") or 0
    if rerollsUsed >= WaveConfig.maxRerollsPerStage then return end
    player:SetAttribute("RerollsUsed", rerollsUsed + 1)
    remoteShowUpgrades:FireClient(player, ctx.generateCardsForPlayer(player, waveIndex))
    print(("[Waves] %s rerolled upgrades (%d/%d used)"):format(
        player.Name, rerollsUsed + 1, WaveConfig.maxRerollsPerStage))
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

    -- Auto-start the next wave 3 seconds after picking
    if currentWave < #WAVES and not waveInProgress and not gameOverFired then
        remoteWaveState:FireAllClients({
            wave = currentWave, totalWaves = #WAVES, mobsAlive = 0,
            inProgress = false, pendingCountdown = WaveConfig.upgradePickToNextWaveDelay,
        })
        task.delay(WaveConfig.upgradePickToNextWaveDelay, function()
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
    -- from prior stages and current stage waves 1-4.
    local targetPicks = StageState.currentStage * 4
    local currentPicks = player:GetAttribute("RunLuckCount") or 0
    local picksNeeded = math.max(0, targetPicks - currentPicks)

    -- Synthesize the picks.
    for _ = 1, picksNeeded do
        ctx.simulateOnePick(player)
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
        ctx.makeMob("boss", waypoints, 1.0)  -- waveMult ignored for bosses anyway
        broadcastWaveState()
        -- Wait for boss death OR heart death OR another token bump
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
                ctx.clearAllMobs()
                waveInProgress = false
                broadcastWaveState()
                -- Total waves cleared so far = (completed stages × #WAVES)
                -- plus current wave minus 1 (wave in progress wasn't cleared).
                local completedStages = math.max(0, StageState.currentStage - 1)
                local wavesSoFar = completedStages * #WAVES + math.max(0, (currentWave or 1) - 1)
                remoteGameOver:FireAllClients({
                    result = "lose",
                    finalWave = currentWave,
                    totalWavesDefeated = wavesSoFar,
                })
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
    ctx.FinalBossState.instance = nil
    ctx.FinalBossState.triggeredPhases = {}
    ctx.FinalBossState.lastPhaseFire = 0
    ctx.FinalBossState.windupUntil = 0
    ctx.FinalBossState.pendingPhase = nil
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

    StageState.currentMapId   = newId
    StageState.currentMapName = newName
    StageState.currentStage   = 1  -- new map starts at stage 1
    StageState.inTransition   = false
    StageState.finalBossActive = false
    currentWave = 0

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

    -- Auto-start wave 1 of the new map after a short pause to let the
    -- player look around / read the leaf message.
    task.delay(4.5, function()
        if StageState.currentMapId == newId and not waveInProgress then
            skipRequested = false
            runWave(1)
        end
    end)

    print(("[Waves] SwitchMap → mapId=%d (%s); wave 1 auto-starts in 4.5s"):format(newId, newName))
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
