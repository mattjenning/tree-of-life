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
--   - Declares the ctx table + runtime state (StageState, gameSpeed).
--     Balance-adjustable data (WaveConfig, Stages, WAVES, MOB_TYPES,
--     FINAL_BOSS_MAP_NAME) lives in src/server/WaveData.lua.
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
--   Stun and the final-boss bonus-damage stack expirations use game-time.
--   Look there for the pattern.
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
local Tags        = require(Shared:WaitForChild("Tags"))
local Config      = require(Shared:WaitForChild("Config"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))
local TempTowers = require(Shared:WaitForChild("TempTowers"))
local CoreTypes  = require(Shared:WaitForChild("CoreTypes"))

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
-- Publish initial value on Workspace for cross-context readers (see the
-- SetGameSpeed handler comment for why).
Workspace:SetAttribute("GameSpeed", ctx.gameSpeed)

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

-- 2026-04-29 ea3-33 Phase E-prep — forward declaration for
-- offerUpgradesOrAutoPick. Can't define here because the auto-pick
-- branch needs to call runWave + read currentWave/waveRunToken/
-- waveInProgress/gameOverFired, which are file-locals declared
-- below. Per CLAUDE.md convention #1 (Lua resolves free variables
-- at function-DEFINITION time), the function body must live AFTER
-- runWave's declaration. Forward-decl at file scope so call sites
-- above runWave still resolve to the eventual implementation.
local offerUpgradesOrAutoPick
local remoteGameOver      = ensureRemote(Remotes.Names.GameOver)       -- server → client: heart died (or final wave cleared)
local remoteStageCleared  = ensureRemote(Remotes.Names.StageCleared)   -- server → client: stage finished, show modal
local remoteStageContinue = ensureRemote(Remotes.Names.StageContinue)  -- client → server: continue button tapped
local remoteStageReskin   = ensureRemote(Remotes.Names.StageReskin)    -- server → client: hub-side visual transition for new stage
-- BossPhase / BossTargetTap / BossWindup / BossWeb / BossPhaseMiss remotes
-- are created + wired by systems/FinalBoss.lua (it calls ReplicatedStorage
-- :WaitForChild on them; Remotes.lua seeds them into ReplicatedStorage at
-- server-start via a separate guard). No need to pre-create them here.
ensureRemote(Remotes.Names.LeafMessage)    -- server → client: show a falling-leaf narrative message with text + duration
-- DevAddStun + DevResetCooldowns are handled by systems/DevTowerHandlers.lua;
-- created here so that module's WaitForChild resolves at setup time.
ensureRemote(Remotes.Names.DevAddStun)
ensureRemote(Remotes.Names.DevResetCooldowns)
local remoteDevSkipToBoss    = ensureRemote(Remotes.Names.DevSkipToBoss)    -- client → server: dev panel skip to current stage's boss with simulated upgrades
local remoteDevSkipToMapBoss = ensureRemote(Remotes.Names.DevSkipToMapBoss) -- client → server: dev panel jump to map boss (stage 3) + auto-kill, triggers temp-tower picker

------------------------------------------------------------
-- Config + runtime state
------------------------------------------------------------
-- Gameplay data tables (WaveConfig / Stages / WAVES / MOB_TYPES +
-- FINAL_BOSS_MAP_NAME) moved to src/server/WaveData.lua so this file
-- stays focused on logic. See that file when balancing numbers.
local WaveData = require(script.Parent:WaitForChild("WaveData"))
local WaveConfig           = WaveData.WaveConfig
local Stages               = WaveData.Stages
local WAVES                = WaveData.WAVES
local MOB_TYPES            = WaveData.MOB_TYPES

-- Time-of-day suffix per stage — unified across all maps per Matthew.
-- Each map's per-stage LIGHTING is interpreted differently (e.g. Map 3's
-- "Morning" reads as sunrise rather than mid-morning), but the HUD label
-- always says "Morning / Afternoon / Dusk / Night".
local TIME_SUFFIX = { [1] = "Morning", [2] = "Afternoon", [3] = "Dusk", final = "Night" }
local function buildMapNameWithSuffix(baseName, _mapId, stageOrFinal)
    local suffix
    -- Stage 4 (or "final") = Night. Stages 1/2/3 read from the map.
    if stageOrFinal == "final" or stageOrFinal == 4 then
        suffix = TIME_SUFFIX.final
    else
        suffix = TIME_SUFFIX[stageOrFinal] or TIME_SUFFIX[1]
    end
    if not suffix or suffix == "" then return baseName end
    return baseName .. " (" .. suffix .. ")"
end

-- Stage / map state. Runtime (lives here, not WaveData, because
-- SwitchMap / RunReset / DevReset all mutate these fields).
local StageState = {
    currentMapId   = 1,                              -- v3: which physical map. 1=Crook, 2=Climbing, 3=Canopy
    currentMapName = "Crook of the Tree (Morning)",
    -- Base name (no time-of-day suffix). SwitchMap sets this; stage-advance
    -- builds currentMapName as `baseMapName .. " (" .. timeOfDay .. ")"`.
    baseMapName    = "Crook of the Tree",
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

local TOTAL_STAGES = Config.Waves.TotalStages

-- FinalBossState lives in systems/FinalBoss.lua now;
-- accessed via ctx.FinalBossState by the handlers in this file that mutate
-- it (runWave, onWaveCleared, DevSkipToBoss, RunReset, SwitchMap).


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
-- Phase E-prep (ea3-33): AutoPicker bypass for upgrade picker.
-- When SUPER AUTO is sweeping, server-side picks a card directly
-- + applies it without firing the client modal.
local AutoPicker   = require(script.Parent:WaitForChild("systems"):WaitForChild("AutoPicker"))
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
-- ctx.getRunPosition is defined further down (after the currentWave
-- file-local is declared). Per CLAUDE.md convention #1 (Lua resolves
-- free vars at function-DEFINITION time) the body would capture nil
-- if defined here.

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

-- StatLedger: per-run tower stat capture for the Infinite sandbox.
-- Published on ctx so the run-end hook (RunReset) can print + reset.
-- Damage / TowerPlacement record into it directly via require — no
-- ctx route needed for the writers.
ctx.statLedger = require(script.Parent:WaitForChild("systems"):WaitForChild("StatLedger"))

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

-- DevTowerHandlers: the three dev-panel handlers that only touch tower
-- attributes (DevAddStun, DevResetCooldowns, DevUnlimitedAmmo). Boss-spawn
-- and skip-to-wave dev handlers stay in this file because they touch
-- orchestrator state (waveRunToken, currentWave, etc.).
local DevTowerHandlers = require(script.Parent:WaitForChild("systems"):WaitForChild("DevTowerHandlers"))
DevTowerHandlers.setup(ctx)

------------------------------------------------------------
-- Wave orchestration
------------------------------------------------------------
local currentWave = 0  -- 0 = not started / between waves
local waveInProgress = false
-- Set true by DevSkipWave handler. The spawn loop checks this before
-- spawning each new mob and bails early; remaining mobs are cleared in the
-- handler so the wave-clear poll fires immediately afterward.
local skipRequested = false

-- Monotonically-increasing token identifying the current wave-run. Every
-- call to runWave increments it; every spawner coroutine captures its
-- token at start and bails if the global token has moved on. This catches
-- races where DevSkipToBoss (or a future similar dev action) starts a new
-- run while an old spawner coroutine is still alive inside a task.wait.
-- Without this, the old spawner would wake up after its sleep and happily
-- spawn the next mob in its sequence — producing "a group spawned with
-- the boss."
local waveRunToken = 0

-- 2026-04-29 ea3-41 Phase E-4: run-position accessor for cross-script
-- consumers (StoryAutoDriver's heart-death poll captures this at the
-- moment of failure to get wave-grain detail like "died map 3 stage 3
-- wave 4" instead of just "died on map 3"). Defined HERE (after
-- currentWave is in scope) so the closure captures the live upvalue
-- per CLAUDE.md convention #1.
ctx.getRunPosition = function()
    return {
        mapId = StageState.currentMapId or 1,
        stage = StageState.currentStage or 1,
        wave  = currentWave or 0,
    }
end

-- Game speed multiplier (1, 2, or 3). Scales mob movement, tower fire rate,
-- spawn intervals, and Phoenix cooldown ticking. The final-boss minigame's
-- tap window stays at REAL seconds (otherwise unwinnable at 3x).
-- ctx.gameSpeed is initialized to 1 at the top of this file (where ctx
-- itself is created). This block just wires the remote handler that
-- lets the client toggle it.
-- Player-facing 1×/2×/3×/5× plus 10× regular speed, plus balance-
-- studio benchmark speeds 20×/30× (Phase 1 of project_infinite_arena.md).
-- 20× / 30× / 50× / 100× are gated client-side to Infinite mode
-- only — server accepts them universally so a future tier-test
-- mode in regular play wouldn't need a server change. 50× and
-- 100× are "math-only" tier: visual fidelity drops sharply (mob
-- model billboards may stutter, projectiles may visually skip),
-- but the server-side simulation (HP, damage, fire timing) keeps
-- pace because the per-frame work scales linearly with dt.
-- 200× and 400× removed per Matthew 2026-04-27 ("they are
-- broken"). At those tiers the substep batching biased outcomes
-- toward the towers (see the wallclock-vs-game-time stun fix +
-- the spawn-stagger fix from earlier the same day). Even with
-- those repaired, 200×/400× was producing inflated finalWave
-- numbers vs real-time runs. Cap stays at 100× until we can
-- validate higher tiers (likely via the closed-form
-- InfiniteSimulator instead of substep-scaling).
local ALLOWED_SPEEDS = {
    [1] = true, [2] = true, [3] = true, [5] = true,
    [10] = true, [20] = true,
    [50] = true, [100] = true,
}
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

local setGameSpeedRemote      = ensureRemoteEvent(Remotes.Names.SetGameSpeed)      -- client → server
local gameSpeedChangedRemote  = ensureRemoteEvent(Remotes.Names.GameSpeedChanged)  -- server → all clients

setGameSpeedRemote.OnServerEvent:Connect(function(_player, requested)
    if type(requested) ~= "number" then return end
    requested = math.floor(requested)
    -- Lock speed to 1x during the game-over sequence (ragdoll → defeat
    -- banner → fairy cinematic / RESET button). Ignore any client
    -- requests until gameOverFired clears (RunReset on DevReset, or the
    -- ResurrectAfterFirstDeath bindable). Keeps the death beat from
    -- being fast-forwarded if the player was at 10x when the heart fell.
    if gameOverFired then return end
    -- ea3-73: drop pause requests while an arena sweep is running.
    -- Pause stalls the sweep's runOneWave countActiveMobs wait loop
    -- indefinitely (mobs gated on ctx.paused → they don't move,
    -- don't die, don't reach the heart) — every combo after the
    -- pause moment never finishes, the LONG VALIDATE coroutine
    -- locks, and a follow-up VALIDATE click is rejected by
    -- arenaGuards because _state never clears. Per Matthew
    -- 2026-04-29 long-validate dump showing combo 4 stuck after
    -- a pause click. Map4ArenaSweepActive attribute is set by
    -- ArenaSweepRunner.runOneCombo (ea3-68); also covers any
    -- sweep that runs through ArenaSweepRunner since they all
    -- share that toggle.
    if requested == 0 and Workspace:GetAttribute("Map4ArenaSweepActive") == true then
        warn("[Waves] pause request ignored — arena sweep is running (use STOP RUN or character-reset to abort)")
        return
    end
    -- 0 = pause (separate state, preserves ctx.gameSpeed so unpause
    -- resumes at the same multiplier). 1/2/3/5/10 = normal speeds.
    if requested == 0 then
        if ctx.paused then return end
        ctx.paused = true
        -- Publish pause state on Workspace so cross-context systems
        -- (PickleLordBoss, Map3BirdBoss, anything outside WaveContext)
        -- can honor it via GameTime.adaptiveWait / GameTime.scaled
        -- without each one needing its own pause hookup. The wave
        -- system's main mob/tower loops still gate on ctx.paused
        -- directly; this flag is for time-based loops elsewhere.
        Workspace:SetAttribute("GamePaused", true)
        gameSpeedChangedRemote:FireAllClients(0)
        print("[Waves] Game PAUSED")
        return
    end
    if not ALLOWED_SPEEDS[requested] then return end
    if requested == ctx.gameSpeed and not ctx.paused then return end
    ctx.paused = false
    Workspace:SetAttribute("GamePaused", false)
    -- If a boss-phase speed lock is currently held, the player's choice
    -- becomes the value to RESTORE on unlock — but the active gs stays
    -- at 1× so the tap minigame still has its reaction window. Without
    -- this, picking 10× mid-attack overwrites Workspace.GameSpeed and
    -- the spider's adaptive wait suddenly thinks 10× game-time is
    -- elapsing each frame even though the player's still in the lock
    -- window. Result: cadence collapses, webs fly faster than the
    -- player can react.
    if (ctx.bossPhaseLockCount or 0) > 0 then
        ctx.bossPhasePrevSpeed = requested
        gameSpeedChangedRemote:FireAllClients(1)
        print(("[Waves] Game speed pending → %dx (held at 1x by boss phase lock)"):format(requested))
        return
    end
    ctx.gameSpeed = requested
    -- Publish on Workspace so cross-context systems (Map3BirdBoss in
    -- HubContext, anything else outside WaveContext) can scale their
    -- own time-loops without needing a remote.
    Workspace:SetAttribute("GameSpeed", ctx.gameSpeed)
    gameSpeedChangedRemote:FireAllClients(ctx.gameSpeed)
    print(("[Waves] Game speed → %dx"):format(ctx.gameSpeed))
end)

-- Force game speed back to 1x and clear any pause. Called at game-over
-- so the defeat sequence plays at wallclock speed regardless of what
-- multiplier the player had set.
local function lockSpeedTo1x()
    Workspace:SetAttribute("GameSpeed", 1)
    Workspace:SetAttribute("GamePaused", false)
    ctx.paused = false
    if ctx.gameSpeed ~= 1 then
        ctx.gameSpeed = 1
    end
    gameSpeedChangedRemote:FireAllClients(1)
end

-- Boss-phase speed lock: any system handling an interactive boss phase
-- (final-boss tap minigame, spider web attack, bird grab) fires this
-- bindable to FORCE 1× speed for the duration. Nested locks count via a
-- stack so two overlapping phases don't trip each other's release.
-- Player's chosen speed is restored on full unlock.
ctx.bossPhaseLockCount = 0
ctx.bossPhasePrevSpeed = nil
local bossPhaseSpeedLockBindable = Remotes.getOrCreate(
    Remotes.Names.BossPhaseSpeedLock, "BindableEvent")
bossPhaseSpeedLockBindable.Event:Connect(function(payload)
    -- Wrap in pcall so a malformed payload or a SetAttribute / FireAllClients
    -- failure can't corrupt the lock count. If the body errors mid-update,
    -- we still want callers (release closures, mid-flight cleanup) to
    -- complete normally; an uncaught error here would propagate up through
    -- BindableEvent.Fire and leave the lock holder unable to release.
    local ok, err = pcall(function()
        local action = type(payload) == "table" and payload.action or payload
        if action == "lock" then
            ctx.bossPhaseLockCount = ctx.bossPhaseLockCount + 1
            if ctx.bossPhaseLockCount == 1 then
                -- First lock — remember what speed the player had so we can
                -- restore on full unlock. ALSO fire 1× to all systems.
                ctx.bossPhasePrevSpeed = ctx.gameSpeed
                if ctx.gameSpeed ~= 1 then
                    ctx.gameSpeed = 1
                    Workspace:SetAttribute("GameSpeed", 1)
                    gameSpeedChangedRemote:FireAllClients(1)
                end
            end
        elseif action == "unlock" then
            ctx.bossPhaseLockCount = math.max(0, ctx.bossPhaseLockCount - 1)
            if ctx.bossPhaseLockCount == 0 and ctx.bossPhasePrevSpeed then
                local restore = ctx.bossPhasePrevSpeed
                ctx.bossPhasePrevSpeed = nil
                if ctx.gameSpeed ~= restore then
                    ctx.gameSpeed = restore
                    Workspace:SetAttribute("GameSpeed", restore)
                    gameSpeedChangedRemote:FireAllClients(restore)
                end
            end
        end
    end)
    if not ok then
        warn("[BossPhaseSpeedLock] handler error: " .. tostring(err))
    end
end)
-- Helper for in-WaveContext systems (saves the require + bindable lookup
-- repeated per call site).
ctx.lockBossPhaseSpeed   = function() bossPhaseSpeedLockBindable:Fire({action = "lock"})   end
ctx.unlockBossPhaseSpeed = function() bossPhaseSpeedLockBindable:Fire({action = "unlock"}) end

-- Hand the current speed to any client that joins or asks (via PlayerAdded)
Players.PlayerAdded:Connect(function(p)
    task.wait(1)  -- let the client's listener wire up
    gameSpeedChangedRemote:FireClient(p, ctx.gameSpeed)
end)

-- Track which boss part we last hooked a Health-attribute listener to,
-- so each new boss spawn rebinds (and the prior listener falls off when
-- the part is destroyed and the connection is collected).
local _bossHpHookedPart = nil
local _bossHpHookConn = nil

-- React to NEW boss spawns (any Tags.FinalBoss-tagged Part appearing).
-- Triggers a fresh broadcast so the HUD HP-bar lookup catches it
-- immediately — without this, custom-built bosses (Map3 bird) only got
-- picked up if a wave event happened to broadcast AFTER they spawned,
-- which the map-3 stage-4 path didn't do.
-- broadcastWaveState is defined immediately below; we forward-declare so
-- the listener body can name it directly without an indirection through
-- _G or ctx. Connection is made AFTER the function is defined, just below.
local broadcastWaveState

local _bossAddedConn = CollectionService:GetInstanceAddedSignal(
    Tags.FinalBoss or "FinalBoss"):Connect(function(_part)
    -- task.defer so the new boss has a frame to finish initializing
    -- (Health/MaxHealth attributes set, parented into Workspace) before
    -- broadcastWaveState's lookup runs. Wrap in pcall so a transient
    -- error during a tear-down doesn't leak to CollectionService.
    task.defer(function()
        pcall(function()
            if broadcastWaveState then broadcastWaveState() end
        end)
    end)
end)
-- Mark used so selene doesn't flag the unused local. The connection is
-- intentionally kept alive for the server's lifetime — there's no run
-- where we'd want to STOP listening for new bosses.
_ = _bossAddedConn

broadcastWaveState = function()
    -- Final-boss HP for the HUD's mini boss bar (when finalBossActive).
    -- Source order: explicit FinalBossState.instance (set for Pickle Lord
    -- /Mold King) → any Tags.FinalBoss-tagged mob (covers map-2 spider,
    -- map-3 future variants). Without the tagged-fallback the spider
    -- showed 0/0 → bar appeared full while the spider was actually
    -- mid-fight.
    local bossHp, bossMaxHp = nil, nil
    local bossInst = ctx.FinalBossState and ctx.FinalBossState.instance
    if not (bossInst and bossInst.Parent) then
        for _, p in ipairs(CollectionService:GetTagged(Tags.FinalBoss or "FinalBoss")) do
            if p.Parent then bossInst = p; break end
        end
    end
    if bossInst and bossInst.Parent then
        local hpPart = bossInst:IsA("BasePart") and bossInst
                    or (bossInst:IsA("Model") and bossInst.PrimaryPart)
                    or bossInst:FindFirstChildWhichIsA("BasePart")
        if hpPart then
            bossHp    = hpPart:GetAttribute("Health")
            bossMaxHp = hpPart:GetAttribute("MaxHealth")
            -- Re-broadcast whenever the boss takes a hit so the screen
            -- HUD bar tracks live HP instead of stuttering between the
            -- coarse-grained event-driven broadcasts (which fire on
            -- wave events, not per damage hit). Hooked once per boss
            -- part — when a new boss spawns, the old hook is replaced.
            if hpPart ~= _bossHpHookedPart then
                if _bossHpHookConn then _bossHpHookConn:Disconnect() end
                _bossHpHookedPart = hpPart
                _bossHpHookConn = hpPart:GetAttributeChangedSignal("Health"):Connect(function()
                    broadcastWaveState()
                end)
            end
        end
    elseif _bossHpHookConn then
        -- Boss gone — drop the listener so it doesn't dangle.
        _bossHpHookConn:Disconnect()
        _bossHpHookConn = nil
        _bossHpHookedPart = nil
    end
    -- stageBossActive: true if a stage-boss mob (mobType "boss", non-final)
    -- is currently in activeMobs. Drives the dev panel's BOSS-button morph
    -- to KILL BOSS, mirroring how finalBossActive drives MAP-BOSS's morph.
    local stageBossActive = false
    if ctx.activeMobs then
        for mob, _ in pairs(ctx.activeMobs) do
            if mob and mob.Parent and mob.Name == "Mob_boss" then
                stageBossActive = true
                break
            end
        end
    end
    local payload = {
        mapId = StageState.currentMapId,  -- client uses this to branch RESET behavior by map
        map = StageState.currentMapName,
        stage = StageState.currentStage,
        wave = currentWave,
        totalWaves = #WAVES,
        mobsAlive = ctx.countActiveMobs(),
        inProgress = waveInProgress,
        finalBossActive = StageState.finalBossActive,
        stageBossActive = stageBossActive,
        bossCleared = StageState.bossCleared,  -- one-shot: just-killed signal
        bossHealth = bossHp,
        bossMaxHealth = bossMaxHp,
    }
    remoteWaveState:FireAllClients(payload)
end

-- Expose broadcastWaveState on ctx so external boss systems (Pickle
-- Lord — see systems/PickleLordBoss.lua) can force a re-broadcast
-- the moment they spawn / set FinalBossState.instance. Without this,
-- their HP bar stays stale at 0/0 until the wave system's next
-- internal broadcast trigger fires (which may be never if no waves
-- are running during the boss phase).
ctx.broadcastWaveState = broadcastWaveState

-- Map 3 Night = bird boss + custom egg waypoint walker (Map3BirdBoss owns
-- spawning). The wave system MUST NOT spawn its own mobs during that
-- phase or they leak onto the path alongside eggs.
local function isBirdBossPhase()
    return StageState.currentMapId == 3 and StageState.currentStage == 4
end

local function runWave(waveIndex)
    if waveInProgress then return end
    if isBirdBossPhase() then return end
    -- Map 4 (Pickle Swamp / Infinite) has its own custom spawner
    -- in systems/Infinite.lua. Regular WAVES table runs (basic →
    -- finalboss progression) MUST NEVER fire on Map 4 — they'd
    -- spawn the Mold King in the swamp. Per Matthew 2026-04-26:
    -- "starting the autorun spawned the map 1 boss for some reason."
    -- Defensive gate: even if some path (auto-start bindable
    -- scheduled before SwitchMap, dev shortcut, etc.) calls
    -- runWave() on Map 4, we no-op.
    if (StageState.currentMapId or 1) == 4 then
        print(("[Waves] runWave(%d) blocked — on Map 4, Infinite owns the spawner"):format(waveIndex))
        return
    end
    local wave = WAVES[waveIndex]
    if not wave then return end
    local spawns = wave.spawns
    local hpMult = wave.hpMult or 1.0
    -- Map 1 stage 3 wave 5 mob nerf (-20%): the round was overtuned
    -- compared to the rest of map 1 — the regular mobs stacked stage-3
    -- bumps + wave-5 (1.20×) bumps on top of map-1 baselines and chewed
    -- the player's HP faster than the difficulty curve called for. Boss
    -- HP stays untouched (boss path uses bossHpMult, not the wave mult
    -- — see MobFactory's isStageBoss branch).
    if (StageState.currentMapId or 1) == 1
       and (StageState.currentStage or 1) == 3
       and waveIndex == 5 then
        hpMult = hpMult * 0.80
    end
    -- Map 3 per-stage-per-wave HP adjustments (Config.Map3.Difficulty
    -- .WaveHpAdjust). Applied as a multiplier on top of waveMult ×
    -- stageMult × mapMult. Per Matthew 2026-04-28 dv: stages 2/3/4
    -- waves 3-5 leaned too hard. Boss HP unaffected (same as Map 1
    -- branch above — boss path uses bossHpMult).
    if (StageState.currentMapId or 1) == 3 then
        local stageAdj = Config.Map3 and Config.Map3.Difficulty
                         and Config.Map3.Difficulty.WaveHpAdjust
                         and Config.Map3.Difficulty.WaveHpAdjust[StageState.currentStage or 1]
        local waveAdj = stageAdj and stageAdj[waveIndex]
        if waveAdj then
            hpMult = hpMult * waveAdj
        end
    end
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
            if spawn.mobType ~= "boss" and spawn.mobType ~= "finalboss" then
                local entry = MapRegistry.get(mapId)
                local diffSection = entry and entry.difficultySection
                if diffSection then
                    local mapCfg = Config[diffSection]
                    local diff = mapCfg and mapCfg.Difficulty
                    if diff and diff.SpawnCountMult then
                        countMult = diff.SpawnCountMult
                    end
                end
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
            if spawn.mobType == "finalboss" then
                local entry = MapRegistry.get(mapId)
                if entry then effectiveMobType = entry.bossType end
            end

            for _ = 1, scaledCount do
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

-- 2026-04-29 ea3-33 Phase E-prep — offerUpgradesOrAutoPick body.
-- Forward-declared near remote-decl block above; assigned here so
-- runWave + currentWave + waveRunToken + waveInProgress + gameOverFired
-- are all in scope (Lua resolves free vars at function-definition
-- time per CLAUDE.md convention #1). When AutoPicker.isActive() (the
-- SUPER AUTO sweep flips it on), we bypass the client picker entirely:
-- pick a card via AutoPicker.pickFromCards (rarity-greedy as of
-- ea3-121), apply it server-side via ctx.applyUpgrade, then mirror
-- remoteUpgradePicked.OnServerEvent's "advance to next wave" logic
-- so the sweep keeps progressing without a player click. Otherwise
-- we fire the picker to the client as before — story play is unchanged.
offerUpgradesOrAutoPick = function(player, cards)
    if AutoPicker.isActive() and type(cards) == "table" and #cards > 0 then
        local idx = AutoPicker.pickFromCards(cards, "upgradeCard")
        local picked = cards[idx]
        if picked then
            ctx.applyUpgrade(player, picked)
        end
        -- Mirror remoteUpgradePicked.OnServerEvent: advance the wave
        -- if we're between waves and the run isn't over. AutoPicker
        -- mode is the only path that auto-progresses without a click.
        if currentWave < #WAVES and not waveInProgress and not gameOverFired then
            waveRunToken = waveRunToken + 1
            runWave(currentWave + 1)
        end
        return
    end
    remoteShowUpgrades:FireClient(player, cards)
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
local respawnAtMapSpawnBindable = Remotes.getOrCreate(
    Remotes.Names.RespawnPlayerAtMapSpawn, "BindableEvent")
resurrectBindable.Event:Connect(function()
    -- Bump the token so any stragglers from the pre-death wave die off.
    waveRunToken = waveRunToken + 1
    waveInProgress = false
    skipRequested = true
    ctx.clearAllMobs()
    -- Canonical reset (also pops any held phase speed-lock so a mid-tap
    -- RunReset / SwitchMap / DevReset can't pin gs at 1× indefinitely).
    if ctx.resetFinalBossState then ctx.resetFinalBossState() end
    gameOverFired = false
    local heart = getHeart()
    if heart then
        heart:SetAttribute("Health", heart:GetAttribute("MaxHealth") or 500)
    end
    -- Respawn any ragdolled players into the map they died in. The
    -- RespawnTime = 60 at hub-boot means natural respawn won't have
    -- kicked in yet, so we drive it explicitly.
    local mapIdForSpawn = StageState.currentMapId or 1
    for _, p in ipairs(Players:GetPlayers()) do
        respawnAtMapSpawnBindable:Fire(p, mapIdForSpawn)
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
            local entry = MapRegistry.get(mapId)
            local bossType = (entry and entry.bossType) or "finalboss"
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
    -- Map 4 defensive gate (same reasoning as runWave): the
    -- regular onWaveCleared path spawns map-bosses + finalbosses
    -- + temp-tower pickers. None of those should fire on Map 4
    -- — Infinite handles its own run-end via heart-death listener.
    if (StageState.currentMapId or 1) == 4 then
        print(("[Waves] onWaveCleared(%d) blocked — on Map 4, Infinite owns run-end"):format(waveIndex))
        return
    end
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
        lockSpeedTo1x()
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
        -- Canonical reset: clears instance + queue + pendingPhase +
        -- speed lock all at once. Without this, a queued phase whose
        -- windup was already running would still fire AFTER the boss
        -- died — purple dots appearing on screen behind the temp-tower
        -- picker (the user reported "purple spots still hit after the
        -- tower UI screen was up"). resetFinalBossState short-circuits
        -- that by nulling pendingPhase before tickPhaseWindup's next tick.
        if ctx.resetFinalBossState then ctx.resetFinalBossState() end
        -- Re-broadcast so the screen HUD's boss bar gets the
        -- finalBossActive=false flip + transitions to "CLEARED" copy.
        -- Without this, the bar lingered in red after the boss died.
        StageState.bossCleared = true
        broadcastWaveState()
        StageState.bossCleared = false  -- one-shot signal; client latches
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
            -- 2026-04-29 ea: drop game speed to 1× whenever a map-boss
            -- stage starts. Mold King / Web Weaver / Canopy Bird all
            -- reach this branch. Player can re-bump via the speed
            -- button if they want; this is just so a 20× sweep doesn't
            -- skip the boss intro (Matthew 2026-04-29: "turn speed to
            -- 1x whenever a map boss stage starts").
            if ctx.gameSpeed ~= 1 then
                ctx.gameSpeed = 1
                Workspace:SetAttribute("GameSpeed", 1)
                gameSpeedChangedRemote:FireAllClients(1)
            end
            -- Final-boss name uses per-map "final" suffix table (Night /
            -- Twilight / Sunset for maps 1-3 respectively).
            local finalName = buildMapNameWithSuffix(
                StageState.baseMapName or "Crook of the Tree",
                StageState.currentMapId or 1, "final")
            StageState.currentMapName = finalName
            -- Tell the hub to do the night reskin (sun sets, torches lit)
            remoteStageReskin:FireAllClients({
                stage     = StageState.currentStage,
                stageName = finalName,
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
            -- Map 3's "named map boss" is the Canopy Bird, started by the
            -- StageAdvanced handler in the hub via ctx.startBirdBoss(). It
            -- doesn't go through ctx.makeMob — spawning a Mold King here
            -- on map 3 was a bug (purple boss showed up alongside the
            -- bird). Instead of returning silently, spawn a death watcher
            -- that polls for the bird's existence + Health=0 and calls
            -- onWaveCleared(0) when it dies — same pattern as the
            -- mapId-1/2 branches below + the dev-spawn path. Without
            -- this, killing the bird via natural flow leaves
            -- StageState.finalBossActive stuck at true and the boss-bar
            -- HUD never flips to CLEARED. Map3BirdBoss.stopBirdBoss
            -- separately fires BossDefeated for the temp-tower picker;
            -- our onWaveCleared(0) call is idempotent on the
            -- gameOverFired/bossCleared guards inside it.
            if mapId == 3 then
                broadcastWaveState()
                local myToken = waveRunToken
                task.spawn(function()
                    -- Wait for the bird to actually exist (startBirdBoss
                    -- builds the model from Map3BirdBoss after stage
                    -- advance fires; small race possible).
                    local birdBody = nil
                    while waveRunToken == myToken and not birdBody do
                        local model = workspace:FindFirstChild("Map3CanopyBird")
                        birdBody = model and model:FindFirstChild("Body")
                        if not birdBody then task.wait(0.2) end
                    end
                    if waveRunToken ~= myToken then return end
                    -- Now poll for death (mob.Parent goes nil OR Health
                    -- <= 0). Map3BirdBoss's own AttributeChangedSignal
                    -- listener destroys the model on death; either signal
                    -- works for our purposes.
                    while birdBody and birdBody.Parent
                       and (birdBody:GetAttribute("Health") or 0) > 0 do
                        if waveRunToken ~= myToken then return end
                        if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                            return  -- heart died first; gameOver path takes over
                        end
                        task.wait(WaveConfig.waveClearedPollInterval)
                    end
                    if waveRunToken ~= myToken then return end
                    -- Bird dead. Run the wave-system's STATE cleanup —
                    -- mirrors the inline `isFinalBossWave` block in
                    -- onWaveCleared, but DOESN'T fire BossDefeated.
                    -- That was already fired by Map3BirdBoss.stopBirdBoss
                    -- (true); double-firing would re-open the temp picker
                    -- and clobber the pending pick state. Effects:
                    --   - flip finalBossActive=false (boss bar HUD goes
                    --     to CLEARED)
                    --   - one-shot bossCleared signal (boss bar tween)
                    --   - canonical reset (releases any held phase
                    --     speed-locks; bird doesn't use them, but staying
                    --     parallel with map 1/2 paths is cheap insurance)
                    StageState.finalBossActive = false
                    if ctx.resetFinalBossState then ctx.resetFinalBossState() end
                    StageState.bossCleared = true
                    broadcastWaveState()
                    StageState.bossCleared = false
                    print("[Waves] Map 3 bird defeated — wave-system state cleared (BossDefeated already fired by Map3BirdBoss)")
                end)
                return
            end
            local bossMobType = (mapId == 2) and "spider" or "finalboss"
            task.spawn(function()
                local waypoints = getWaypoints()
                local mob = ctx.makeMob(bossMobType, waypoints, 1.0)
                if mob and bossMobType == "finalboss" then
                    -- Canonical reset clears triggeredPhases + queue + any
                    -- held speed-lock so the new fight starts clean.
                    if ctx.resetFinalBossState then ctx.resetFinalBossState() end
                    ctx.FinalBossState.instance = mob
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

    -- Mid-stage wave clear → offer upgrade picks. Show the picker
    -- and broadcast a "wave waiting" state. The next wave only
    -- starts when the player picks a card (see remoteUpgradePicked
    -- handler).
    --
    -- 2026-04-28 dk: hard-cap auto-start removed per Matthew "dont
    -- start the waves while the upgrade picker is open." Was a
    -- task.delay(autoStartIn, runWave) safety net that fired the
    -- next wave even if the player didn't pick — combined with
    -- dk's "picker stays open after countdown" change, this
    -- previously produced waves spawning behind the still-visible
    -- picker. Now strictly pick-driven: player MUST click a card
    -- to proceed. Trade-off: a player who AFKs during the picker
    -- stalls the run indefinitely; acceptable since the picker
    -- doesn't consume resources and they can resume any time.
    for _, player in ipairs(Players:GetPlayers()) do
        offerUpgradesOrAutoPick(player, ctx.generateCardsForPlayer(player, waveIndex))
    end
    if currentWave < #WAVES and not waveInProgress and not gameOverFired then
        remoteWaveState:FireAllClients({
            mapId = StageState.currentMapId,
            map   = StageState.currentMapName,
            stage = StageState.currentStage,
            wave = currentWave, totalWaves = #WAVES, mobsAlive = 0,
            inProgress = false,
            -- pendingCountdown intentionally omitted — no timer,
            -- HUD shouldn't display "Wave N+1 in X…".
        })
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
    -- Update the map name for the HUD: base name + per-(map, stage)
    -- time-of-day suffix. Maps 2 and 3 get their own suffix tables, so
    -- e.g. map 3 stage 1 reads "Canopy Nest (Sunrise)" instead of the
    -- generic "Crook of the Tree (Morning)".
    local cfg = Stages[StageState.currentStage]
    StageState.currentMapName = buildMapNameWithSuffix(
        StageState.baseMapName or "Crook of the Tree",
        StageState.currentMapId or 1,
        StageState.currentStage)
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
remoteStageContinue.OnServerEvent:Connect(function(_player)
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
    offerUpgradesOrAutoPick(player, ctx.generateCardsForPlayer(player, 0))
    print(("[Waves] Free reward granted to %s (first tower placed)"):format(player.Name))
end)

-- BossTargetTap + BossPhaseMiss handlers now live in systems/FinalBoss.lua.

remoteUpgradePicked.OnServerEvent:Connect(function(player, upgrade)
    ctx.applyUpgrade(player, upgrade)

    -- Start the next wave on pick. As of 2026-04-28 dk this is the
    -- ONLY trigger that starts mid-stage waves — the hard-cap
    -- task.delay safety net was removed from onWaveCleared so the
    -- next wave doesn't fire while the picker is open. Player MUST
    -- click a card to proceed.
    if currentWave < #WAVES and not waveInProgress and not gameOverFired then
        waveRunToken = waveRunToken + 1  -- invalidate any leftover scheduled tokens
        runWave(currentWave + 1)
    end
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
    -- Tear down any in-flight wave; runWave below bumps waveRunToken
    -- itself when it starts, so the prior spawner aborts on its next
    -- token check.
    skipRequested = true
    waveInProgress = false
    ctx.clearAllMobs()
    -- Canonical reset (also pops any held phase speed-lock so a mid-tap
    -- RunReset / SwitchMap / DevReset can't pin gs at 1× indefinitely).
    if ctx.resetFinalBossState then ctx.resetFinalBossState() end

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

    -- Run the FULL wave 5 (mobs + stage boss) via the standard spawn path.
    -- On stage 1/2 this gives the player a stage-boss-with-escorts fight;
    -- on stage 3 it gives them the wave-5 mob mix + stage 3 boss, then
    -- onWaveCleared(5) → final-map-boss spawn (separate from MAP BOSS
    -- button which goes straight to the map boss). User: "if you're on
    -- stage 3 of any map and you hit the boss from dev panel, it should
    -- go to wave 5, not map boss."
    runWave(#WAVES)  -- = 5
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
    -- Canonical reset (also pops any held phase speed-lock so a mid-tap
    -- RunReset / SwitchMap / DevReset can't pin gs at 1× indefinitely).
    if ctx.resetFinalBossState then ctx.resetFinalBossState() end

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
        local mapId = StageState.currentMapId or 1
        -- Map 3's "map boss" is the Canopy Bird, started by the
        -- StageAdvanced handler in the hub when stage flips to 4. Skip the
        -- Mold King intermediary that other maps use — spawning + auto-
        -- killing it just flashes a purple blob on the path and adds a
        -- BossMinigame error path. Jump straight to the stage-cleared
        -- transition so the bird boss starts directly.
        if mapId == 3 then
            if waveRunToken ~= myToken then return end
            waveInProgress = false
            broadcastWaveState()
            onWaveCleared(#WAVES)
            return
        end

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
    -- Picks split across "phases" of 12, one phase per simulated map:
    --   pickCount 12 (map 2 dev port)  → 12 picks rolled as map 1 (Core-only)
    --   pickCount 24 (map 3 dev port)  → 12 picks as map 1 (Core-only),
    --                                    then 12 as map 2 (Core + Aux mix)
    -- Map 2 picks include Aux upgrades because by map 3 the player would
    -- have collected aux-tower drops on map 2 — those upgrades belong to
    -- the existing aux baseline, not Core. The dev teleport granted 2 aux
    -- towers up front so the Aux baseline exists when these picks land.
    local savedMapId = StageState.currentMapId
    local ok, err = pcall(function()
        for idx = 1, pickCount do
            -- First 12 picks → map 1 cards; picks 13-24 → map 2 cards.
            local phaseMapId = (idx <= 12) and 1 or 2
            StageState.currentMapId = phaseMapId
            ctx.simulateOnePick(player, idx)
        end
    end)
    StageState.currentMapId = savedMapId
    if not ok then warn("[Waves] DEV: upgrade-path simulation errored: " .. tostring(err)) end

    -- Reset the PER-MAP counter back to 0 so DevSkipToBoss on the actual
    -- map still sees `stage*4 - 0` picks remaining. RunLuckCount/Sum are
    -- left alone: the simulated picks legitimately contribute to the
    -- player's run-wide luck display (same as if they'd played for real).
    player:SetAttribute("MapPickCount", 0)
    -- Reset reroll resources too. The 24-pick simulation can chew through
    -- both per-stage rerolls AND reroll tokens (each pick may burn up to
    -- MAX_REROLL_TRIES) — without a reset the player arrives on the live
    -- map with REROLL USED + NO TOKENS, defeating the dev-teleport-to-map-3
    -- "land in a comparable state" goal. Restore to: 0 used per stage,
    -- minimum 3 tokens (matches the global RerollTokens starting floor).
    player:SetAttribute("RerollsUsed", 0)
    if (player:GetAttribute("RerollTokens") or 0) < 3 then
        player:SetAttribute("RerollTokens", 3)
    end

    -- 2026-04-29 dz: forced extra picks per Matthew "give one extra
    -- tower upgrade card when porting to map 2 and one extra core
    -- tower range and aux tower range card when porting to map 3."
    -- payload.forcedPicks = list of { stat, target, rarity } specs.
    -- Each gets minted via rollStatCard + applyUpgrade after the
    -- regular sim loop, so the cards land on the player's stamped
    -- baselines (rarity-scaled values + Core/Aux split + RUN LUCK).
    local forcedPicks = payload.forcedPicks
    if type(forcedPicks) == "table" and ctx.rollStatCard and ctx.applyUpgrade then
        for _, spec in ipairs(forcedPicks) do
            if type(spec) == "table" and spec.stat and spec.rarity then
                local card = ctx.rollStatCard(spec.rarity, spec.stat)
                if card then
                    card.target = spec.target or "Core"
                    ctx.applyUpgrade(player, card)
                    print(("[Waves] DEV: forced %s %s %s pick applied (%s)")
                        :format(spec.target or "Core", spec.rarity, spec.stat,
                                card.description or "?"))
                end
            end
        end
    end
    print(("[Waves] DEV: %s simulated %d picks on first Core placement (%d map-1 + %d map-2)")
        :format(player.Name, pickCount,
            math.min(12, pickCount), math.max(0, pickCount - 12)))
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
        -- Map 4 (Pickle Swamp / Infinite) is owned by the Infinite
        -- system; its hookHeartDeath listener handles heart-death
        -- (captures finalWave, advances AUTO RUN queue or returns
        -- to hub). The regular game-over flow ragdolls the player
        -- + fires the DEFEAT banner — both wrong for the benchmark
        -- sandbox. Skip the poll entirely on Map 4.
        -- Per Matthew 2026-04-26: "after failing in auto run it
        -- kills the player instead of moving to the next combination".
        if StageState.currentMapId == 4 then
            continue
        end
        -- ea3-112: skip the heart-death lose-firing path when Pickle
        -- Lord has just been defeated. Mini pickles can damage the
        -- heart all the way to 0 during the fight; if the boss dies
        -- on the same tick the heart does, this poller used to fire
        -- GameOver(lose) before the boss-defeat reward chain could
        -- run. The PickleLordBoss flips this flag in stopPickleLord
        -- (killed=true) BEFORE firing the bindable, so by the next
        -- 0.5s poll we know the run is a win and skip lose-firing.
        if Workspace:GetAttribute("PickleLordDefeated") then
            continue
        end
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
                lockSpeedTo1x()
                ragdollAllPlayers()
                maybeShowFirstDeathFairyToAll()
            end
        end
    end
end)

-- Reset gameOverFired when DevReset fires (so you can restart after losing)
local devResetRemote = ReplicatedStorage:WaitForChild(Remotes.Names.DevReset)
devResetRemote.OnServerEvent:Connect(function(_player)
    gameOverFired = false
    -- ea3-112: clear the Pickle Lord defeat flag too so a fresh run
    -- starts with the watcher live. Without this, after a victorious
    -- run + DevReset, the heart-death poller would stay muted and
    -- the next run's actual heart-fall wouldn't fire GameOver(lose).
    Workspace:SetAttribute("PickleLordDefeated", false)
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
    -- Pre-spawn cleanup: full reset is safer than the prior partial wipe
    -- (instance + triggeredPhases only) because if the dev button is hit
    -- mid-phase the held speed lock also needs to release.
    if ctx.resetFinalBossState then ctx.resetFinalBossState() end
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
-- then spawns the bird via Map3BirdBoss.startBirdBoss() (which builds
-- the procedural rig + runs the swoop / grab / egg loops).
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
    -- Pre-spawn cleanup: full reset is safer than the prior partial wipe
    -- (instance + triggeredPhases only) because if the dev button is hit
    -- mid-phase the held speed lock also needs to release.
    if ctx.resetFinalBossState then ctx.resetFinalBossState() end
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

-- DEV: Kill the currently-active map boss. Walks Tags.FinalBoss-tagged
-- parts and routes through whichever death path the boss type uses:
--   - In activeMobs (Mold King, Web Weaver) → ctx.damageMob with overkill
--     so Damage.lua's standard hp ≤ 0 destroy path runs (HP popup, drops,
--     onWaveCleared(0) → BossDefeated → temp-tower picker).
--   - Standalone (Map 3 Canopy Bird body) → Health attribute = 0; the
--     bird's own attribute-changed listener fires stopBirdBoss(true)
--     which fires BossDefeated(mapId=3) → temp-tower picker.
-- Used by the dev panel's MAP BOSS button when it morphs to KILL BOSS.
local devKillBossRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevKillActiveBoss)
if not devKillBossRemote then
    devKillBossRemote = Instance.new("RemoteEvent")
    devKillBossRemote.Name = Remotes.Names.DevKillActiveBoss
    devKillBossRemote.Parent = ReplicatedStorage
end
devKillBossRemote.OnServerEvent:Connect(function(player)
    -- Step 1a: kill the FINAL boss (the only FinalBoss-tagged mob —
    -- escorts like spiderlings have isEscort=true so they're skipped
    -- by the tag).
    local killedAny = false
    for _, p in ipairs(CollectionService:GetTagged(Tags.FinalBoss or "FinalBoss")) do
        if p.Parent then
            local hp = p:GetAttribute("Health") or 0
            if hp > 0 then
                if ctx.damageMob and ctx.activeMobs[p] then
                    ctx.damageMob(p, hp + 1)  -- overkill via standard mob path
                else
                    p:SetAttribute("Health", 0)  -- bird body's listener handles death
                end
                killedAny = true
                print(("[Dev] %s killed boss (%s)"):format(player.Name, p.Name))
            end
        end
    end
    -- Step 1b: ALSO kill any STAGE-boss mob ("Mob_boss" — wave-5 boss of
    -- stages 1/2/3, distinct from final). Drives the BOSS button's
    -- KILL-BOSS morph, mirroring how MAP BOSS handles final bosses.
    if not killedAny and ctx.activeMobs then
        for mob, _data in pairs(ctx.activeMobs) do
            if mob and mob.Parent and mob.Name == "Mob_boss" then
                local hp = mob:GetAttribute("Health") or 0
                if hp > 0 and ctx.damageMob then
                    ctx.damageMob(mob, hp + 1)
                    killedAny = true
                    print(("[Dev] %s killed stage boss (%s)"):format(player.Name, mob.Name))
                end
            end
        end
    end
    -- Step 2: also wipe escort mobs (Web Weaver's spiderlings) and any
    -- in-flight wave mobs so the fight ENDS, not just the boss. Without
    -- this, killing the spider leaves 4 spiderlings still walking the
    -- path and whittling the heart even after the temp-tower picker has
    -- fired. clearAllMobs is the canonical "wipe everything in
    -- ctx.activeMobs" helper used by RunReset / SwitchMap.
    --
    -- We ALSO bump waveRunToken + skipRequested so any wave spawner
    -- that's mid-emit (from a fresh dev-port that auto-started wave 1
    -- before the user dev-cycled to the boss) aborts on its next tick.
    -- Without this, clearAllMobs wipes everything but the spawner just
    -- emits new mobs the next frame, and the user sees mobs "respawn".
    if killedAny then
        waveRunToken = waveRunToken + 1
        waveInProgress = false
        skipRequested = true
        if ctx.clearAllMobs then ctx.clearAllMobs() end
    end
    if not killedAny then
        print(("[Dev] %s pressed KILL BOSS but no active boss found"):format(player.Name))
    end
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
-- Dev: set wave-system stage state from outside (Portal.lua's stage-cycle
-- button). Updates currentStage + currentMapName via the per-map suffix
-- table and rebroadcasts WaveState so the HUD label flips to match.
local devSetWaveStage = Remotes.getOrCreate(Remotes.Names.DevSetWaveStage, "BindableEvent")
devSetWaveStage.Event:Connect(function(stage)
    stage = tonumber(stage)
    if not stage then return end
    if stage < 1 then stage = 1 elseif stage > 4 then stage = 4 end
    -- Dev advance: simulate upgrade picks COMMENSURATE with what the
    -- player would have earned if they'd actually played through the
    -- skipped stages. Each stage normally hands out 4 picks (one per wave
    -- 1–4 cleared). The CURRENT stage only owes whatever picks the player
    -- hasn't already taken from it — i.e. the missing waves between
    -- currentWave and 5. Per Matthew: "only a stage worth if you're on
    -- the first wave" — full 4 picks on wave 1, fewer if mid-stage.
    local prevStage = StageState.currentStage or 1
    local stagesAdvanced = math.max(0, stage - prevStage)
    StageState.currentStage = stage
    StageState.finalBossActive = (stage == 4)
    if stagesAdvanced > 0 and ctx.simulateOnePick then
        -- Picks owed by the stage we're LEAVING: 4 minus picks already
        -- received this stage. currentWave==1 (haven't cleared any waves
        -- yet) → 4 picks. currentWave==N → max(0, 5-N) remaining.
        local cw = currentWave or 1
        if cw < 1 then cw = 1 end
        local firstStagePicks = math.max(0, 5 - cw)
        local additionalPicks = (stagesAdvanced - 1) * 4
        local total = firstStagePicks + additionalPicks
        for _, p in ipairs(Players:GetPlayers()) do
            for _ = 1, total do
                ctx.simulateOnePick(p)
            end
        end
    end
    -- Stage 4 (boss) on ANY map: abort any in-flight wave spawner so a
    -- wave-1 spawner running from a fresh dev-port doesn't keep emitting
    -- regular path mobs alongside the boss. Without this, dev-cycling
    -- to stage 4 on map 2 mid-wave-1 left ~101-HP mobs walking the path
    -- next to the spider, and KILL BOSS would clear them only for the
    -- spawner to immediately produce more. Token bump + waveInProgress
    -- flip is the standard "halt the spawn loop" pattern used by RunReset.
    if stage == 4 then
        waveRunToken = waveRunToken + 1
        waveInProgress = false
        skipRequested = true  -- belt-and-suspenders: spawn loop checks both
        ctx.clearAllMobs()
    end
    -- Dev advance into a regular gameplay stage (1/2/3): clear lingering
    -- mobs from the prior stage and start the new stage's wave 1 fresh.
    -- Per Matthew: "when i use dev teleport to advance a stage, clear the
    -- mobs and start the mobs for that wave/stage." Skips stage 4 — its
    -- boss flow is handled by the dedicated branches below (named map
    -- boss for maps 1/2, bird boss for map 3).
    if stagesAdvanced > 0 and stage <= 3 then
        ctx.clearAllMobs()
        if ctx.resetFinalBossState then ctx.resetFinalBossState() end
        waveRunToken = waveRunToken + 1  -- abort any in-flight spawner
        waveInProgress = false
        currentWave = 0
        skipRequested = false
        local startedToken = waveRunToken
        task.defer(function()
            -- Defer one frame so the broadcastWaveState below registers
            -- the new stage state on clients before wave 1's HUD update
            -- chases it. Token-guarded so a second cycle doesn't double
            -- up.
            if waveRunToken ~= startedToken then return end
            if waveInProgress then return end
            runWave(1)
        end)
    end
    local stageKey
    if stage >= 4 then stageKey = "final" else stageKey = stage end
    StageState.currentMapName = buildMapNameWithSuffix(
        StageState.baseMapName or "Crook of the Tree",
        StageState.currentMapId or 1,
        stageKey)
    -- When dev-cycling INTO stage 4 on map 1 or 2, actually spawn the
    -- named final boss (Mold King / Web Weaver) so the HUD's HP bar has a
    -- real instance to track. Map 3 handles its own boss via Map3BirdBoss.
    -- Per-map mob type matches the natural-flow spawner at line 837:
    --   map 1 → "finalboss" (Mold King)
    --   map 2 → "spider"    (Web Weaver) — was incorrectly spawning the
    --                        Mold King because both maps used "finalboss"
    if stage == 4
       and (StageState.currentMapId == 1 or StageState.currentMapId == 2) then
        if not (ctx.FinalBossState.instance and ctx.FinalBossState.instance.Parent) then
            task.spawn(function()
                ctx.clearAllMobs()
                local waypoints = getWaypoints()
                if ctx.makeMob and waypoints then
                    local bossMobType = (StageState.currentMapId == 2)
                        and "spider" or "finalboss"
                    local mob = nil
                    pcall(function() mob = ctx.makeMob(bossMobType, waypoints, 1.0) end)
                    if not mob then
                        -- Last-ditch fallback if the requested type doesn't
                        -- resolve (would be a MOB_TYPES entry gap).
                        pcall(function() mob = ctx.makeMob("boss", waypoints, 1.0) end)
                    end
                    -- FinalBossState.instance is the trigger for the
                    -- Pickle-Lord-only phase mechanics. Only set it for
                    -- "finalboss" so the spider fight doesn't inherit
                    -- those windups. Canonical reset clears the queue +
                    -- triggeredPhases from any prior fight (e.g. user
                    -- dev-cycled stage 4 → killed boss → cycled again).
                    if mob and bossMobType == "finalboss" then
                        if ctx.resetFinalBossState then ctx.resetFinalBossState() end
                        ctx.FinalBossState.instance = mob
                    end
                    broadcastWaveState()
                    -- Death watcher: mirrors the natural-flow stage-3
                    -- final-boss path (around line 988). Without this,
                    -- the dev-spawned boss could be killed (KILL BOSS,
                    -- tower DPS, etc.) but onWaveCleared(0) would never
                    -- fire — leaving finalBossActive stuck at true, no
                    -- BossDefeated, no temp-tower picker, no portal
                    -- descent. Polls until the mob's Parent goes nil
                    -- (Damage.lua's destroy path), then signals victory.
                    if mob then
                        task.spawn(function()
                            while mob and mob.Parent do
                                local heart = getHeart()
                                if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                                    return  -- heart died; gameOver flow takes over
                                end
                                task.wait(WaveConfig.waveClearedPollInterval)
                            end
                            onWaveCleared(0)
                        end)
                    end
                else
                    broadcastWaveState()
                end
            end)
        end
    end
    broadcastWaveState()
end)

runResetBindable.Event:Connect(function()
    -- Print + clear the per-run stat ledger BEFORE reset — gives the
    -- runtime log a snapshot of what towers did during the run-just-
    -- ended (visible in the Studio log right next to the reset event).
    -- Phase 1 of Infinite sandbox infrastructure (roadmap:
    -- project_infinite_arena.md). Not yet consumed by any UI.
    if ctx.statLedger then
        print(ctx.statLedger.summary())
        ctx.statLedger.reset()
    end
    StageState.currentStage = 1
    StageState.currentMapId   = 1
    StageState.baseMapName    = "Crook of the Tree"
    StageState.currentMapName = buildMapNameWithSuffix(StageState.baseMapName, 1, 1)
    StageState.inTransition = false
    StageState.finalBossActive = false
    StageState.priorMapsWavesCompleted = 0
    -- Canonical reset (also pops any held phase speed-lock).
    if ctx.resetFinalBossState then ctx.resetFinalBossState() end
    -- CRITICAL: clear paused state. If the player left the game paused
    -- and then hit reset, ctx.paused would remain true → MobUpdate and
    -- Towers early-exit forever → mobs don't move + reset looks broken.
    -- Also broadcast so the speed-bar UI un-highlights the pause button.
    if ctx.paused then
        ctx.paused = false
        Workspace:SetAttribute("GamePaused", false)
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
    -- Canonical reset (also pops any held phase speed-lock so a mid-tap
    -- RunReset / SwitchMap / DevReset can't pin gs at 1× indefinitely).
    if ctx.resetFinalBossState then ctx.resetFinalBossState() end

    -- Roll over completed waves to the run-wide counter BEFORE resetting
    -- currentStage/currentWave. Assumes the outgoing map was fully cleared
    -- (SwitchMap only fires after a map-boss defeat claim or a dev teleport;
    -- in dev cases the counter may over-count slightly, which is fine for
    -- the GameOver banner's purposes — it's a flavor number, not a stat).
    if StageState.currentMapId and StageState.currentMapId ~= newId then
        StageState.priorMapsWavesCompleted = (StageState.priorMapsWavesCompleted or 0) + (#WAVES * TOTAL_STAGES)
    end

    StageState.currentMapId   = newId
    -- newName from SwitchMap is the BASE name (e.g. "Canopy Nest"); we
    -- store it and append the (mapId, stage 1) time-of-day suffix.
    StageState.baseMapName    = newName or "Crook of the Tree"
    StageState.currentMapName = buildMapNameWithSuffix(
        StageState.baseMapName, newId, 1)
    StageState.currentStage   = 1  -- new map starts at stage 1
    StageState.inTransition   = false
    StageState.finalBossActive = false
    currentWave = 0

    -- Reset PER-MAP pick counter so each map starts DevSkipToBoss math at 0.
    -- RunLuckSum / RunLuckCount stay cumulative across the whole run — they
    -- drive the client's run-luck display and should reflect ALL picks the
    -- player has seen this run (real + dev-simulated), not just this map.
    -- Also restore the per-stage free-reroll counter (the "free reroll
    -- per stage" is a per-stage resource, not a per-run one — fresh map
    -- means fresh free reroll). RerollTokens are NOT reset: the
    -- accumulated paid-currency carries across maps, only refreshed by
    -- stage-boss kills + dud picks within the run.
    for _, p in ipairs(Players:GetPlayers()) do
        p:SetAttribute("MapPickCount", 0)
        p:SetAttribute("RerollsUsed", 0)
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
    -- Carry-over grant for Map 1→2/3 transitions: Core + permanent
    -- tower stocks come along on map switch since the previous
    -- map's Core/Aux are stuck on that grid. Skip for Infinite
    -- (noAutoWaves=true): the Pickle Swamp is a benchmark sandbox
    -- where loadouts come exclusively from the picker / AUTO RUN,
    -- and an auto-granted PowerStock=1 leaks Power into the idle
    -- state (showing Power on the hotbar before the player picks).
    if newId >= 2 and not payload.noAutoWaves then
        -- Stock semantics: at-most N per map entry (max(N, current)) —
        -- never overwrite leftover stock downward (generous) and never
        -- accumulate above N (bug: +1 each map could hand the player 2+
        -- Cores if they skipped placing on map 1).
        --
        -- 2026-04-28 dq: stock grant follows the player's PICKED Core
        -- (Power / ControlCore / SupportCore), not hardcoded Power.
        -- Was: granting PowerStock=1 only, so a player who picked
        -- ControlCore on Map 1 arrived on Map 2 with no Core stock
        -- to place (their picked Core was 0, and Power was 0 too).
        -- Per Matthew "if you beat map 1 on non powercore tower, you
        -- don't have core stock on map2 ... fix these bugs for all
        -- story mode if you can." The picked Core is read from the
        -- `<id>Equipped` attribute set by TowerPlacement.lua's
        -- TowerPicked handler in 2026-04-28 dk.
        for _, p in ipairs(Players:GetPlayers()) do
            local pickedCore = "Power"  -- fallback if no flag set
            for _, c in ipairs(CoreTypes.Ids) do
                if p:GetAttribute(c .. "Equipped") == true then
                    pickedCore = c
                    break
                end
            end
            local curCore = p:GetAttribute(pickedCore .. "Stock") or 0
            p:SetAttribute(pickedCore .. "Stock", math.max(1, curCore))

            -- 2026-04-29 ea3-45: refresh EVERY owned aux's stock to its
            -- template default on map entry. Pairs with the change in
            -- TempTowerRewards.grantTowerPick where stock is granted
            -- as 0 — boss-reward auxes are visible-but-greyed on the
            -- post-boss hotbar; this step makes them placeable on the
            -- next map. Per Matthew "give aux 0 stock too, but
            -- refresh both when you arrive on map 2". An aux is
            -- considered owned when its `<id>Rarity` attribute exists
            -- (set by grantTowerPick at boss-pick time). This loop
            -- iterates ALL aux templates so any future picker grant
            -- is covered without per-tower wiring.
            for towerId, tpl in pairs(TempTowers.Templates) do
                if p:GetAttribute(towerId .. "Rarity") then
                    p:SetAttribute(towerId .. "Stock", tpl.stock)
                end
            end

            -- Permanent tower (Pickle Lord drop) stays handled below —
            -- it has its own rarity / stock semantics from the
            -- DataStore-backed equip slot, not the temp-tower picker.
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
        mapId = newId,
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
    --
    -- payload.noAutoWaves opt-out: the Infinite system fires SwitchMap
    -- to set StageState.currentMapId=4 (so getHeart / getWaypoints
    -- resolve to Map4), but it OWNS its own custom wave spawner — we
    -- must NOT auto-start regular waves on top of it.
    if payload.noAutoWaves then
        print(("[Waves] SwitchMap → mapId=%d (%s); auto-wave start SKIPPED"):format(newId, newName))
        return
    end
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
    -- High-speed substep loop on Map 4 (Pickle Swamp / Infinite).
    -- At 30×+ the per-Heartbeat game-time advance is large enough
    -- that mobs tunnel past tower fire ranges and tower fire
    -- intervals (1 / (fireRate × gameSpeed)) compress below the
    -- Heartbeat tick — meaning the tower can only fire once per
    -- frame regardless of how many shots the math says it owes.
    -- Subdividing the update into N smaller calls solves both:
    -- mobs move in finer steps (no tunneling) and towers re-check
    -- their interval gate N times per frame (correct shot count).
    --
    -- Gated to Map 4 + speed >= 20× — N = ceil(gameSpeed / 12):
    --   20× → 2 substeps    30× → 3 substeps    50× → 5 substeps    100× → 9 substeps.
    --
    -- HISTORY (Matthew 2026-04-27 → 2026-04-28):
    --   v1 (> 20):    1×-20× byte-identical, substeps active at 30×+.
    --   v2 (>= 20):   tried briefly, rolled back. Issue: os.clock()
    --                 didn't advance between substeps so towers
    --                 (using wallclock-based lastFire) never got
    --                 extra fire opportunities, but ctx.gameTime
    --                 DID advance per substep — stun/slow timers
    --                 expired faster than firing could refresh.
    --   v3 (>= 20, current): RE-ENABLED after the lastFire→gameTime
    --                 refactor (build br). Towers now ALSO track
    --                 fire intervals in gameTime, so substeps
    --                 correctly multiply both fire opportunities
    --                 AND timer ticks. Stack-mechanic towers
    --                 (Frost slow, Root stun, CC DOT) at 20×
    --                 should now ≈ 10× behavior.
    --
    -- Per Matthew 2026-04-26: math-only architecture for Infinite,
    -- visual fidelity acceptable to lose at high speeds.
    local subSteps = 1
    -- Math-only mode flag — set whenever we're on Map 4 at 20×+.
    -- Visual-only update paths (HP-bar billboard CFrame tracking,
    -- stun-star orbits, etc.) check this flag and skip themselves
    -- during AUTO RUN benchmarks. Saves 30-40% of per-Heartbeat
    -- allocation cost when the swamp is full of mobs at high speed.
    -- Gameplay-affecting updates (mob movement, tower fire,
    -- hit detection, HP attribute writes) ignore the flag.
    if StageState.currentMapId == 4 and ctx.gameSpeed and ctx.gameSpeed >= 20 then
        -- Divisor settled at 12 (per Matthew 2026-04-27). The 20-
        -- divisor produced 0.333 s sim-dt — too coarse, caused
        -- timing bias. The 5-divisor (0.083 s sim-dt) was 4× finer
        -- but at 400× ran 80 substeps per Heartbeat which lagged
        -- the server. 12 splits the difference: ~0.139 s sim-dt
        -- per substep, 33 substeps at 400× / 17 at 200× — keeps
        -- timer accuracy (stuns are 0.5+ s, slows 1-2 s) without
        -- the CPU pressure.
        subSteps = math.ceil(ctx.gameSpeed / 12)
        ctx.mathOnlyMode = true
    else
        ctx.mathOnlyMode = false
    end
    -- Mirror the flag to a Workspace attribute so cross-script
    -- consumers (Map4.lua decorations, client-side effects) can
    -- watch a single source of truth. Per Matthew 2026-04-26:
    -- "remove ground effects above 20x".
    if Workspace:GetAttribute("InfiniteMathOnly") ~= ctx.mathOnlyMode then
        Workspace:SetAttribute("InfiniteMathOnly", ctx.mathOnlyMode)
    end
    if subSteps == 1 then
        ctx.gameTime = (ctx.gameTime or 0) + dt * ctx.gameSpeed
        ctx.updateMobs(dt)
        ctx.updateTowers(towerList)
        ctx.tickPhoenixCooldowns(dt, towerList)
    else
        local subDt = dt / subSteps
        for _ = 1, subSteps do
            -- Advance the simulated game-clock by the substep's
            -- game-seconds. ctx.gameTime is what stun/slow timers
            -- check against — using wallclock os.clock() inside
            -- substeps caused stun/slow to "freeze" across all
            -- substeps within a Heartbeat (since wallclock barely
            -- moves between substeps), inflating effective stun /
            -- slow durations by 10-20× at 200×/400× speed and
            -- biasing outcomes toward the towers. Per Matthew
            -- 2026-04-27 (Option B audit).
            ctx.gameTime = (ctx.gameTime or 0) + subDt * ctx.gameSpeed
            ctx.updateMobs(subDt)
            ctx.updateTowers(towerList)
            ctx.tickPhoenixCooldowns(subDt, towerList)
        end
    end
end)

-- Publish the fully-populated wave context onto the cross-script bridge.
-- Consumers in OTHER server scripts (e.g. systems/Infinite.lua, which
-- runs in Hub but needs makeMob / getWaypoints / activeMobs etc.) read
-- it via require + Bridge.ctx. See WaveCtxBridge.lua docstring.
local WaveCtxBridge = require(script.Parent:WaitForChild("WaveCtxBridge"))
WaveCtxBridge.ctx = ctx

print("[Waves] Wave system v1.83 ready.")
