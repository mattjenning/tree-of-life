--[[
    Infinite.lua — Phase 1 of the Infinite Arena (balance/benchmark
    sandbox per project_infinite_arena.md).

    OWNS:
    - Hub-portal entry handler (called from HubWorld.Touched): teleports
      into Map4, fires SwitchMap (noAutoWaves=true) so the wave system
      knows we're on map 4 without kicking off WAVES[1], grants the
      default tower stock, starts the spawner.
    - Return-portal lazy build inside Map4 (touch → exit + summary).
    - 3-wave loop spawner: every run cycles AOE / Combined / Solo by
      wave % 3, with RunDifficultyMult ramping geometrically per wave.
    - Heart-death listener: on Health <= 0, prints
        "failed at wave N (testType)" + StatLedger.summary(),
      then auto-returns the player to the hub.
    - AUTO RUN orchestrator: builds a 73-loadout queue (9 solos + 36
      pairs + 28 triples-with-anchor), runs each until heart-death or
      wave-30 cap, captures finalWave per loadout, assembles a per-role
      S/A/B/C/D/F tier list at the end. Fired from the admin panel's
      AUTO RUN button; result tier list prints to the server log.

    NOT YET:
    - Full UI for tweaking ramp constants live (today: read from
      Config.Map4.Difficulty)
    - Per-scenario damage / status separators in StatLedger summary
    - Multi-player Infinite (today assumes one player at a time)
    - Persistent run-history DataStore (AUTO RUN tier list lives in
      memory only — re-running the sweep starts from zero)

    setup(ctx) reads from HUB-ctx:
      ctx.MAP4_PLAYER_SPAWN_CF / ctx.HUB_SPAWN_CF
      ctx.map4Heart, ctx.map4Room

    Reads via WaveCtxBridge.ctx (cross-script, late-resolved):
      makeMob, getWaypoints, clearAllMobs   (MobFactory in WaveSystem)

    Reads via direct require:
      shared/Remotes, shared/Config, shared/GameTime, systems/StatLedger

    Publishes:
      ctx.enterInfinite(player, scenarioName)
      ctx.exitInfinite(player)
]]

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Players             = game:GetService("Players")
local Workspace           = game:GetService("Workspace")
local CollectionService   = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local Config      = require(Shared:WaitForChild("Config"))
local GameTime    = require(Shared:WaitForChild("GameTime"))
local Tags        = require(Shared:WaitForChild("Tags"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))
local CoreTypes   = require(Shared:WaitForChild("CoreTypes"))

-- Cross-script bridge: WaveSystem-ctx (in a separate Server script)
-- publishes itself to WaveCtxBridge.ctx after its setup completes.
-- Infinite lives in Hub's ecosystem but needs WaveSystem-side
-- functions (makeMob, getWaypoints, activeMobs, clearAllMobs) and
-- the StatLedger reference. Read via waveCtx() at call time so we
-- get the freshest reference if WaveSystem reboots.
local WaveCtxBridge = require(ServerScriptService:WaitForChild("WaveCtxBridge"))
local function waveCtx()
    return WaveCtxBridge.ctx
end
local StatLedger = require(script.Parent:WaitForChild("StatLedger"))
local InfiniteRunHistoryStore = require(ServerScriptService:WaitForChild("InfiniteRunHistoryStore"))
local InfiniteSimulator = require(script.Parent:WaitForChild("InfiniteSimulator"))
local InfiniteValidator = require(script.Parent:WaitForChild("InfiniteValidator"))
-- Path geometry — used for the partial-wave-clear time formula
-- (waveDuration = pathLength / slowest-mob-speed). Same module the
-- simulator uses, so MAP4_PATH_CELLS stays single-source-of-truth.
local InfinitePathGeometry = require(script.Parent:WaitForChild("InfinitePathGeometry"))

-- Per-player Core preference DataStore. Saves the last-picked Core
-- archetype so on Studio shift+F5 / next session the player ports
-- in with their last Core auto-equipped + auto-selected. Per
-- Matthew 2026-04-28: "auto equip and select last core tower used
-- on porting to infinte? and store it on starting auto run since i
-- shift f5 sometimes."
--
-- Tiny DataStore (single string per player). Falls back to
-- "Power" if read fails / no prior preference. Wrapped in pcall so
-- DataStore outages don't block player entry.
local DataStoreService = game:GetService("DataStoreService")
local CORE_PREF_STORE_OK, corePrefStore = pcall(function()
    return DataStoreService:GetDataStore("InfiniteCorePreference_v1")
end)
local function loadCorePreference(player: Player): string
    if not CORE_PREF_STORE_OK or not corePrefStore then return "Power" end
    local ok, val = pcall(function()
        return corePrefStore:GetAsync("Player_" .. player.UserId)
    end)
    if not ok then
        warn(("[Infinite] loadCorePreference GetAsync failed for %s: %s"):format(
            player.Name, tostring(val)))
        return "Power"
    end
    if type(val) == "string" and CoreTypes.isCore(val) then
        return val
    end
    return "Power"
end
local function persistCorePreference(player: Player, coreId: string?)
    if not CORE_PREF_STORE_OK or not corePrefStore then return end
    if not CoreTypes.isCore(coreId) then return end
    -- 2026-04-29 ea3: surface DataStore write failures. Silent
    -- swallowing made it impossible to tell if shift+F5'd Core
    -- preference loss was a code bug or DataStore outage. Failures
    -- here are non-critical (the in-memory PreferredCoreId attribute
    -- is still correct for this session), but worth logging.
    local ok, err = pcall(function()
        corePrefStore:SetAsync("Player_" .. player.UserId, coreId)
    end)
    if not ok then
        warn(("[Infinite] persistCorePreference SetAsync failed for %s coreId=%s: %s"):format(
            player.Name, tostring(coreId), tostring(err)))
    end
end

local Infinite = {}

-- Cinematic timing
local ENTRY_FADE_OUT_SEC = 0.8
local EXIT_FADE_OUT_SEC  = 0.6

-- Lazy-wired return portal
-- ea3-117: returnPortalSetup gate retired alongside setupReturnPortal
-- removal (the in-world "RETURN TO HUB" billboard label was creating
-- confusion vs the GameOverBanner modal — see project_failure_curve
-- _v2.md aside). Players exit via DevReset / RUN RESET / SIMULATE
-- menu paths; no in-world portal needed in the Infinite arena.

------------------------------------------------------------
-- Run state. Single-player at a time; multi-player Infinite is
-- a future expansion (would require per-player StageState).
------------------------------------------------------------
local State = {
    active        = false,
    activePlayer  = nil :: Player?,
    -- Wave counter: ramps continuously across the 3-test loop. Wave 1
    -- is AOE-easy; by wave 30 we're in late-stage SoloTarget hell.
    -- Last reached + last test type land in the run-end summary
    -- ("failed at wave 12 (AOE)").
    wave          = 0,
    spawnerToken  = 0,    -- bumped on stop() so live coroutines can detect abort
    heartConn     = nil :: RBXScriptConnection?,
    -- Set by client clicking the countdown overlay; spawner loop's
    -- pre-wave countdown predicate aborts on this and wave 1 starts
    -- immediately. Reset to false on each enter().
    skipCountdown = false,
    -- Most-recently-picked Core archetype. Tracked across the whole
    -- session (NOT cleared on exit) so AUTO RUN reads the player's
    -- last loadout choice as the sweep anchor. Per Matthew 2026-04-27:
    -- "if you start autorun it uses the saved core tower from the
    -- loadout." Default Power; pickRemote handler updates on every
    -- loadout commit (SAVE or GO).
    preferredCoreId = "Power",
}

------------------------------------------------------------
-- AUTO RUN orchestrator state. When .active, exit() captures the
-- finalWave + dequeues the next loadout instead of returning to
-- hub. Builds a tier list from finalWave averages once the queue
-- drains. See buildAutoRunQueue / assembleTiers below.
------------------------------------------------------------
local autoRun = {
    active     = false,
    queue      = nil,    -- list of pending { auxIds, label } loadouts
    current    = nil,    -- the loadout currently running
    results    = nil,    -- list of completed { auxIds, label, finalWave, testType }
    total      = 0,      -- queue size at start (for "12/73" progress display)
    continuous = false,  -- when true, finalize() rebuilds the queue + restarts
                         -- a fresh sweep instead of going idle. Per Matthew
                         -- 2026-04-27: "run autorun continuously." Cleared by
                         -- InfiniteStopRun remote / TOTAL RESET / player exit.
    sweepNum   = 0,      -- count of sweeps completed since AUTO RUN started
                         -- (just for the log line / monitor display).
}

-- All sweep tuning lives in Config.InfiniteArena (single source of
-- truth shared with InfiniteSimulator.lua). Module-locals below are
-- aliases so the rest of this file reads naturally; any tuning
-- change goes in Config.lua and BOTH the live spawner and the
-- closed-form sim see it. Per Matthew 2026-04-27: keep these in
-- lockstep so validation deltas reflect actual model gaps, not
-- forgotten tuning copy-paste.
local _IA = Config.InfiniteArena
local MAX_AUTO_RUN_WAVE       = _IA.MaxAutoRunWave
local COMMON_DAMAGE_FLAT      = _IA.Upgrade.DamageFlat
local COMMON_FIRERATE_DELTA   = _IA.Upgrade.FireRateMult
local COMMON_RANGE_DELTA      = _IA.Upgrade.RangeMult
local RANGE_CAP_MULT          = _IA.Upgrade.RangeCapMult
local POST_CAP_EFFECT_BOOST   = _IA.Upgrade.PostCapBoost
local CYCLE_STEP              = _IA.CycleStep
local AUTO_RUN_ANCHOR         = _IA.AutoRunAnchor

------------------------------------------------------------
-- In-session cache. Persistent DataStore-backed history is a
-- future step (project_infinite_arena.md step 3); until then the
-- admin panel reads this cache to re-display the most recent
-- sweep without scrolling the server log.
--
-- Survives until the server restarts. Per Matthew (2026-04-26):
-- "just in session store now, same for tower statistics, no data
-- store yet."
--
-- Shape:
--   lastSweep = {
--     tiers          = { DPS = {...}, Control = {...}, Support = {...} },
--     results        = { { auxIds, label, finalWave, testType, statSummary }, ... },
--     completedAt    = os.time(),
--     total          = number,    -- queue size at start
--   }
--   lastRunStats = string         -- last StatLedger.summary() text
------------------------------------------------------------
local lastSweep = nil :: { any }?
local lastRunStats: string = ""

-- Separate cache for SIMULATE results (pure-math closed-form).
-- Kept distinct from `lastSweep` and `cumulativeResults` per Matthew
-- 2026-04-27: "keep this data separate until I can validate it."
-- Same shape as lastSweep so the admin panel could opt in to
-- displaying it later.
--
-- Two views of the same data:
--   simulatedSweep        — most-recent fire (any Core); used by the
--                           legacy export field + simulateDataRemote
--                           round-trip to the requesting client.
--   simulatedSweepByCore  — { Power=..., ControlCore=..., SupportCore=... }
--                           dict updated alongside simulatedSweep.
--                           Persisted to DataStore (sim_cache_v1) so a
--                           SUPER AUTO crash mid-loop doesn't lose the
--                           pre-sweep sims. Per Matthew 2026-04-29:
--                           "save the sim runs to the export, so if the
--                           run crashes like last night, it's still there."
local simulatedSweep = nil :: { any }?
local simulatedSweepByCore: { [string]: any } = {}

-- Cumulative results pool — every run from every sweep since the
-- last BALANCE RESET appends here. Default tier-list view (admin
-- panel + LastSweepData channel) shows cumulative aggregate across
-- all sweeps so multi-sweep tuning doesn't lose statistical power.
-- Wiped by the InfiniteBalanceReset remote. Per Matthew 2026-04-26:
-- "the run stats + tier lists should be across every run unless
-- balance reset is hit."
--
-- DataStore-backed via InfiniteRunHistoryStore.loadCumulative /
-- saveCumulative — survives server restarts so the cumulative tier
-- list builds up across multiple Studio sessions. Per Matthew
-- 2026-04-26: "hook up the data store so we can save autorun data."
-- Hydrated in setup() (lazy DataStore load) so the file's top-level
-- still initializes to {} for the no-DataStore case.
local cumulativeResults: { any } = {}

-- Monotonic balance-era counter. Hydrated from DataStore on setup;
-- bumped each time BALANCE RESET fires. Stamped onto every sweep
-- + cumulative result so LOAD RUNS can group sweeps by balance
-- era. Per Matthew 2026-04-27: "every time balance reset is used
-- increase the balance version # and start a new row."
local currentBalanceVersion: number = 1

-- ea3-125: in-memory history of VALIDATE runs this session. Keyed
-- by sorted-comma-joined auxIds, value is a list of {finalPhase,
-- balanceVersion, completedAt} entries newest-last. Used to surface
-- variance across repeated VALIDATE presses on the same combo
-- ("this combo has been VALIDATE'd 3 times this era; finalPhase
-- 3.0/3.5/3.5"). NOT persisted across server restarts — too low
-- signal-to-cost for DataStore. Wiped by BALANCE RESET so the
-- history doesn't span calibration eras.
local validateHistory: { [string]: { any } } = {}
local VALIDATE_HISTORY_CAP = 8  -- keep last 8 finalPhase observations per combo

------------------------------------------------------------
-- buildAutoRunQueue — generate every loadout the AUTO RUN sweep
-- runs through. TWO sweep types as of 2026-04-27 (trios dropped):
--
--   1. Solo:    Power + 1 aux              → 9 runs   (one per aux)
--   2. Pair:    Power + 2 aux              → C(9,2) = 36 runs
--
-- Total = 9 + 36 = 45 runs.
--
-- Trios (Power + 2 aux + InfiniteStandard) used to add 36 more
-- runs but were dropped 2026-04-27 after sweep analysis showed:
--   • The anchor was the SAME tower in every trio → trios tested
--     "is this duo OK at +28% mob HP" not "is this 3-tower combo
--     synergistic"
--   • 28/36 trios saturated at the wave-9 floor — tier orderings
--     unchanged from duo-only data
--   • Median duo→trio diff (2.29 waves) was almost exactly the
--     LoadoutMult artifact (1.25 → 1.60) — no signal beyond duos
-- 40% sweep time saved. AUTO_RUN_ANCHOR config + the isTrio
-- guards in assembleTiers / observation code stay (defensive — if
-- we re-enable trios later, those still skip anchor double-count).
--
-- Test pool = all 9 regular aux towers (excludes InfiniteStandard,
-- which is the anchor-only standardization tool). Each tower
-- appears in 1 solo + 8 duos = 9 stat runs.
--
-- ── ORDERING ──
-- Per Matthew 2026-04-27: "for solo, duo, ..., within those
-- buckets, can you randomize tower selection so if I have to stop
-- during a partial run multiple times, eventually each tower gets
-- tested the same amount, or close?"
--
-- Each bucket gets a fresh Fisher-Yates shuffle PER queue build:
--   1. Bucket order preserved (solos before duos) — STOP RUN with
--      N completed gives "at least N/2 of each category" lower bound.
--   2. Within a bucket, order is uniform random. LLN convergence
--      across multiple partial sweeps.
--   3. Fresh Random per call (no module-level seeded state).
------------------------------------------------------------
local function buildAutoRunQueue(coreId: string?): { { auxIds: { string }, label: string } }
    -- coreId is the Core archetype this sweep tests against — controls
    -- both the label prefix ("Power + ..." / "ControlCore + ..." /
    -- "SupportCore + ...") AND, downstream, the actual Core that gets
    -- equipped during each loadout's enter() call. Defaults to "Power"
    -- for backwards compat. Per Matthew 2026-04-27: "if you start
    -- autorun it uses the saved core tower from the loadout."
    coreId = coreId or "Power"
    -- Test pool: every TempTower except the anchor. The anchor
    -- (InfiniteStandard) appears only in the trio loop below.
    local testPool = {}
    for id in pairs(TempTowers.Templates) do
        if id ~= AUTO_RUN_ANCHOR then
            table.insert(testPool, id)
        end
    end
    table.sort(testPool)  -- deterministic base order; shuffle below

    -- Fresh Random per call so consecutive sweeps differ. os.time()
    -- + tick() seed gives sub-second resolution for back-to-back
    -- continuous sweeps.
    local rng = Random.new(os.time() * 1000 + math.floor(os.clock() * 1000) % 1000)

    -- Fisher-Yates shuffle in place.
    local function shuffle(list)
        for i = #list, 2, -1 do
            local j = rng:NextInteger(1, i)
            list[i], list[j] = list[j], list[i]
        end
    end

    -- 1. Solos (9 — one per test-pool tower).
    local solos = {}
    for _, id in ipairs(testPool) do
        table.insert(solos, {
            auxIds = { id },
            label  = ("%s + %s"):format(coreId, id),
        })
    end
    shuffle(solos)

    -- 2. Duos (C(9, 2) = 36 — all unordered pairs of test-pool
    -- towers; AcornSniper is in 8 of these like every other tower).
    local duos = {}
    for i = 1, #testPool do
        for j = i + 1, #testPool do
            local a, b = testPool[i], testPool[j]
            table.insert(duos, {
                auxIds = { a, b },
                label  = ("%s + %s + %s"):format(coreId, a, b),
            })
        end
    end
    shuffle(duos)

    -- (Trios removed 2026-04-27 — see header comment for rationale.)

    -- Concat: solos → duos. Bucket boundaries preserved so STOP RUN
    -- N runs in always covers at least floor(N/2) of each category.
    local queue = {}
    for _, e in ipairs(solos) do table.insert(queue, e) end
    for _, e in ipairs(duos)  do table.insert(queue, e) end

    return queue
end

------------------------------------------------------------
-- buildLongAutoQueue — synergy-analysis sweep using a CURATED
-- 3-aux trio list from Config.InfiniteArena.LongAutoTrios. Smaller
-- than the C(9,3)=84 full-triple sweep; trios are hand-picked at
-- "ambiguous" regions of the 2-tower data — pairings where the
-- 2-tower averages don't clearly indicate whether a tower carries
-- or rides along.
--
-- Per Matthew 2026-04-27: "switch to option B with a curated
-- 3-aux list."
--
-- Same per-call shuffle as buildAutoRunQueue so partial-sweep
-- aborts don't always hit the same trios first.
------------------------------------------------------------
local function buildLongAutoQueue(coreId: string?): { { auxIds: { string }, label: string } }
    coreId = coreId or "Power"
    local trios = (_IA and _IA.LongAutoTrios) or {}
    local rng = Random.new(os.time() * 1000 + math.floor(os.clock() * 1000) % 1000)
    local function shuffle(list)
        for i = #list, 2, -1 do
            local j = rng:NextInteger(1, i)
            list[i], list[j] = list[j], list[i]
        end
    end
    local queue = {}
    for _, trio in ipairs(trios) do
        -- Validate trio shape: must be 3 strings, each a known aux.
        if type(trio) == "table" and #trio == 3 then
            local valid = true
            for _, id in ipairs(trio) do
                if type(id) ~= "string" or not TempTowers.Templates[id] then
                    valid = false
                    break
                end
            end
            if valid then
                table.insert(queue, {
                    auxIds = { trio[1], trio[2], trio[3] },
                    label  = ("%s + %s + %s + %s"):format(coreId, trio[1], trio[2], trio[3]),
                })
            else
                warn(("[Infinite] LongAutoTrios entry skipped (invalid): %s"):format(
                    table.concat(trio, ",")))
            end
        end
    end
    shuffle(queue)
    return queue
end

------------------------------------------------------------
-- buildFullAutoQueue — one-shot combo of AUTO RUN (solos + duos)
-- AND the curated trios. Used by the new SIMULATE → FULL AUTO
-- menu item per Matthew 2026-04-28. Replaces the old
-- "press AUTO RUN, wait, press AUX AUTO" two-step flow.
------------------------------------------------------------
local function buildFullAutoQueue(coreId: string?): { { auxIds: { string }, label: string } }
    local queue = buildAutoRunQueue(coreId)
    for _, e in ipairs(buildLongAutoQueue(coreId)) do
        table.insert(queue, e)
    end
    return queue
end

------------------------------------------------------------
-- buildTowerSuperQueue — TOWER SUPER zoom-in sweep filtered to
-- combos containing a single focus aux. Per Matthew 2026-04-29:
-- "add a new TOWER SUPER button at the top of simulate to allow
-- zooming in on one tower. it will run the super auto method,
-- but just for one aux tower (all 3 cores, all 5 rarities)."
--
-- Implementation: build the FULL AUTO queue (solos + duos + curated
-- trios) for the given coreId, then filter to only entries whose
-- auxIds list contains the focus aux. Solos that don't include the
-- focus aux drop out; duos lose the half that don't pair with
-- focus; trios drop unless focus is one of the 3.
--
-- NOTE: this builds ONE queue for ONE (coreId, rarity) tuple. The
-- handler calls this 15× (3 cores × 5 rarities) to assemble the
-- full TOWER SUPER sweep. Rarity isn't a queue field — it's
-- applied at grant-time via grantLoadout's `<id>Rarity` stamping
-- (ea3-8). This function ignores rarity; the caller passes
-- rarity through opts.rarity on the enter() call.
------------------------------------------------------------
local function buildTowerSuperQueue(
    coreId: string?,
    focusAuxId: string
): { { auxIds: { string }, label: string } }
    -- Pure data function — returns empty queue on invalid input
    -- without warning. The remote handler (towerSuperRemote.OnServerEvent)
    -- is the security boundary that warns on bad client payloads.
    -- Splitting these means tests can exercise the defensive paths
    -- without polluting the boot log with phantom warns from
    -- intentional probes.
    if type(focusAuxId) ~= "string" or not TempTowers.Templates[focusAuxId] then
        return {}
    end
    if focusAuxId == AUTO_RUN_ANCHOR then
        return {}
    end
    local fullQueue = buildFullAutoQueue(coreId)
    local filtered = {}
    for _, entry in ipairs(fullQueue) do
        local hasFocus = false
        for _, id in ipairs(entry.auxIds or {}) do
            if id == focusAuxId then hasFocus = true; break end
        end
        if hasFocus then
            table.insert(filtered, entry)
        end
    end
    return filtered
end

------------------------------------------------------------
-- combinations — return all k-tuples of `items` (order-independent,
-- no repeats). Tail-recursion via index so a 14-item / 4-tuple
-- request (C(14,4)=1001) doesn't blow the stack. Items are kept in
-- their input order inside each combo so labels stay deterministic.
------------------------------------------------------------
local function combinations(items: { string }, k: number): { { string } }
    if k <= 0 then return { {} } end
    if k > #items then return {} end
    local result = {}
    local n = #items
    local function helper(start: number, current: { string })
        if #current == k then
            local copy = {}
            for _, v in ipairs(current) do table.insert(copy, v) end
            table.insert(result, copy)
            return
        end
        local remaining = k - #current
        for i = start, n - remaining + 1 do
            table.insert(current, items[i])
            helper(i + 1, current)
            table.remove(current)
        end
    end
    helper(1, {})
    return result
end

------------------------------------------------------------
-- buildSelectAutoQueue — sweep generator pinned to the player's
-- currently saved loadout.
--
-- 2026-04-29 ea3-9 rework — every-combo at any (K, N). Per Matthew
-- 2026-04-29: "if you choose 3 towers, run those 3 with every
-- other aux; if you choose 1, run that with every possible combo
-- of aux, if you choose 2, do the same (every possible aux
-- combo) ... add a 5 difficulty, lets you select four towers,
-- run those 4 + every aux combo."
--
-- Inputs:
--   coreId        — Core archetype anchoring the sweep
--   lockedAuxIds  — auxes the player has chosen in the loadout
--                   (K of them). These are pinned in every queue
--                   entry; the rotated slot(s) come from the
--                   remaining-aux pool.
--   sliderValue   — total aux slot count N (loadout-picker slider).
--                   N - K = number of slots to rotate.
--
-- Behavior:
--   • K = 0:        falls through to buildAutoRunQueue (broad sweep)
--   • K > 0:        generates ALL C(remaining, N-K) combinations of
--                   the unlocked aux pool, paired with the K locked.
--                   When N == K (every slot is locked), produces a
--                   single entry — useful for "run THIS exact
--                   loadout repeatedly."
--   • K > N:        defensive empty return; the picker shouldn't
--                   produce this (you can't lock more than the slot
--                   count) but be defensive.
--
-- The anchor (InfiniteStandard) is excluded from the iteration set
-- since it's a benchmark standardization tower — same rule as
-- buildAutoRunQueue. Output queue is shuffled so SELECT AUTO doesn't
-- spend its first hour entirely on alphabetical-A combos.
------------------------------------------------------------
local function buildSelectAutoQueue(
    coreId: string?,
    lockedAuxIds: { string }?,
    sliderValue: number?
): { { auxIds: { string }, label: string } }
    coreId = coreId or "Power"
    lockedAuxIds = lockedAuxIds or {}
    -- Default slot count: K + 1 (rotate exactly one extra aux). Mirrors
    -- the prior buildSelectAutoQueue contract for K∈{1,2}.
    sliderValue = sliderValue or (#lockedAuxIds + 1)

    if #lockedAuxIds == 0 then
        return buildAutoRunQueue(coreId)
    end
    if #lockedAuxIds > sliderValue then
        -- Pure data function — silent reject. Remote handler warns
        -- on bad client payloads (boundary security). See
        -- buildTowerSuperQueue for the same split rationale.
        return {}
    end

    -- Validate locked entries: must be known tower ids, not the anchor.
    local lockedSet = {}
    local lockedClean = {}
    for _, id in ipairs(lockedAuxIds) do
        if type(id) ~= "string" or not TempTowers.Templates[id] or id == AUTO_RUN_ANCHOR then
            -- Silent skip; remote handler validates client payloads.
        else
            lockedSet[id] = true
            table.insert(lockedClean, id)
        end
    end

    -- Iteration set = all aux towers EXCEPT the locked ones and the
    -- standardization anchor. Sorted for deterministic ordering.
    local iterSet = {}
    for id in pairs(TempTowers.Templates) do
        if id ~= AUTO_RUN_ANCHOR and not lockedSet[id] then
            table.insert(iterSet, id)
        end
    end
    table.sort(iterSet)

    local rotateCount = sliderValue - #lockedClean

    local rng = Random.new(os.time() * 1000 + math.floor(os.clock() * 1000) % 1000)
    local function shuffle(list)
        for i = #list, 2, -1 do
            local j = rng:NextInteger(1, i)
            list[i], list[j] = list[j], list[i]
        end
    end

    -- Enumerate every (rotateCount)-combo of the iteration set.
    -- rotateCount = 0 → single combo {} → one queue entry with just
    --                   the locked auxes (run THIS loadout once).
    local combos = combinations(iterSet, rotateCount)
    local queue = {}
    for _, combo in ipairs(combos) do
        local auxIds = {}
        for _, id in ipairs(lockedClean) do table.insert(auxIds, id) end
        for _, id in ipairs(combo)        do table.insert(auxIds, id) end
        local labelParts = { coreId }
        for _, id in ipairs(auxIds) do table.insert(labelParts, id) end
        table.insert(queue, {
            auxIds = auxIds,
            label  = table.concat(labelParts, " + "),
        })
    end
    shuffle(queue)
    return queue
end

------------------------------------------------------------
-- buildTopCombosQueue — input: coreId + cumulativeResults pool +
-- optional topN. Output: queue list of the highest-finalWave
-- loadouts in DESCENDING order, deduplicated by aux signature.
--
-- Used by the CONTINUOUS auto-run loop after the first FULL AUTO
-- sweep completes — instead of running the same broad
-- solos+duos+curated-trios queue again, subsequent continuous
-- sweeps focus on the loadouts that performed best, in
-- descending order. Per Matthew 2026-04-28: "change auto run
-- monitor > auto mode to run the most high-value combinations
-- in descending order when the full auto run completes."
--
-- Aggregation: results with the SAME aux signature (sorted-by-id
-- joined) get their finalWaves averaged. Each unique signature
-- contributes ONE entry to the output queue. With 117 results
-- from a FULL AUTO this typically yields ~117 unique loadouts
-- (each loadout sampled once); top 30 covers the meaningful tail.
--
-- Falls back gracefully: if results is empty, returns an empty
-- queue (caller should fall through to buildAutoRunQueue).
------------------------------------------------------------
local function buildTopCombosQueue(
    coreId: string?,
    results: { any },
    topN: number?
): { { auxIds: { string }, label: string } }
    coreId = coreId or "Power"
    topN = topN or 30
    if not results or #results == 0 then return {} end

    -- Aggregate by canonical aux signature.
    local byLoadout = {}
    for _, r in ipairs(results) do
        local aux = r.auxIds or {}
        if #aux > 0 then
            -- Sort a copy of auxIds for canonical signature; the
            -- original list ordering is preserved when we
            -- re-emit the queue entry below.
            local sorted = {}
            for _, id in ipairs(aux) do table.insert(sorted, id) end
            table.sort(sorted)
            local sig = table.concat(sorted, "+")

            local b = byLoadout[sig]
            if not b then
                b = {
                    auxIds    = sorted,
                    runs      = 0,
                    totalWave = 0,
                }
                byLoadout[sig] = b
            end
            b.runs      = b.runs + 1
            b.totalWave = b.totalWave + (r.finalWave or 0)
        end
    end

    -- Sort all unique loadouts by avgWave descending.
    local list = {}
    for _, b in pairs(byLoadout) do
        b.avgWave = b.totalWave / b.runs
        table.insert(list, b)
    end
    table.sort(list, function(a, b) return a.avgWave > b.avgWave end)

    -- Take top N. Each entry gets a fresh label using the supplied
    -- coreId (so a sweep retargeting the same loadouts at a new
    -- Core archetype reads correctly).
    local queue = {}
    local cap = math.min(topN, #list)
    for i = 1, cap do
        local b = list[i]
        local labelParts = { coreId }
        for _, id in ipairs(b.auxIds) do
            table.insert(labelParts, id)
        end
        table.insert(queue, {
            auxIds = b.auxIds,
            label  = table.concat(labelParts, " + "),
        })
    end
    return queue
end

------------------------------------------------------------
-- assembleTiers — bucket every aux tower into S/A/B/C/D/F per
-- role based on the average wave reached across runs the tower
-- participated in.
--
-- Algorithm:
--   1. For each tower id, sum every finalWave from runs whose
--      auxIds includes it. avgWave = totalWaves / runCount.
--   2. Group towers by role (DPS / Control / Support).
--   3. Sort each role group by avgWave descending.
--   4. Slice each sorted group into 6 buckets (S=top, F=bottom).
--      With 5 DPS / 4 Control / 0 Support, ranks become:
--        DPS:     S A B C D     (rank 1..5 → top..bottom)
--        Control: S A B C       (rank 1..4 → top..bottom)
--      Buckets sit unevenly until we have ≥6 towers per role —
--      good enough for a first read; revisit when more aux land.
--
-- Returns: { DPS = {...}, Control = {...}, Support = {...} }
-- where each entry = { towerId, avgWave, runs, role, tier }
------------------------------------------------------------
local function assembleTiers(results: { any }): { [string]: { any } }
    local perTower = {}
    for _, r in ipairs(results) do
        local isTrio = (#r.auxIds) >= 3
        for _, id in ipairs(r.auxIds) do
            -- The trio anchor (InfiniteStandard) is in every
            -- trio just to standardize the third-aux slot.
            -- Counting those toward its own avgWave would inflate
            -- its run count and pollute its tier with runs that
            -- aren't testing it. Skip the bump when the anchor
            -- appears in a trio. Other towers count normally.
            if id == AUTO_RUN_ANCHOR and isTrio then
                continue
            end
            if not perTower[id] then
                perTower[id] = { runs = 0, totalWaves = 0 }
            end
            perTower[id].runs = perTower[id].runs + 1
            perTower[id].totalWaves = perTower[id].totalWaves + r.finalWave
        end
    end

    -- Build a FLAT list across all roles for global tier ranking.
    -- Per Matthew 2026-04-27: "tiering logic should apply across all
    -- towers." A C-tier Control tower should read worse than a
    -- B-tier DPS tower if its avgWave is lower, regardless of role.
    -- Per-role tiering hid that signal — a single Control tower
    -- always read as S even if it was the bottom performer overall.
    local flat = {}
    for id, agg in pairs(perTower) do
        local role = TempTowers.RoleByTowerId[id] or "DPS"
        table.insert(flat, {
            towerId = id,
            avgWave = agg.totalWaves / math.max(1, agg.runs),
            runs    = agg.runs,
            role    = role,
        })
    end

    -- VALUE-BASED TIER BREAKPOINTS (Matthew 2026-04-27):
    --   "only the top tower can be S and only the bottom tower can be F.
    --    then set the tier distribution wave breakpoints and place
    --    the other towers in it."
    --
    -- Algorithm:
    --   1. Sort towers descending by avgWave.
    --   2. Top → S. Bottom → F. (Always exactly one of each.)
    --   3. Middle towers: normalize their avgWave to [0, 1] where
    --      0 = bottom_avg, 1 = top_avg. Place into A/B/C/D bands
    --      by quartile of the normalized value:
    --        norm ≥ 0.75 → A
    --        norm ≥ 0.50 → B
    --        norm ≥ 0.25 → C
    --        norm <  0.25 → D
    --
    -- This means tier letters reflect ACTUAL performance gaps, not
    -- just rank position. If 4 towers cluster tightly near the
    -- bottom and one is way ahead, the top-cluster is A and the
    -- bunched 3 are all D — accurate representation that "middle"
    -- doesn't always mean evenly spread.
    --
    -- Edge cases:
    --   • n=1: S only
    --   • n=2: S, F
    --   • n=3: S, middle (A/B/C/D by value), F
    --   • range = 0 (all tied): middle towers fall to "C" baseline.
    table.sort(flat, function(a, b) return a.avgWave > b.avgWave end)
    local n = #flat
    local function bandForNorm(norm)
        if norm >= 0.75 then return "A" end
        if norm >= 0.50 then return "B" end
        if norm >= 0.25 then return "C" end
        return "D"
    end
    for i, e in ipairs(flat) do
        if i == 1 then
            e.tier = "S"
        elseif n > 1 and i == n then
            e.tier = "F"
        else
            local topAvg = flat[1].avgWave or 0
            local botAvg = flat[n].avgWave or 0
            local range = topAvg - botAvg
            if range <= 0 then
                e.tier = "C"  -- all tied; arbitrary middle bucket
            else
                local norm = ((e.avgWave or 0) - botAvg) / range
                e.tier = bandForNorm(norm)
            end
        end
    end

    -- Group back into role buckets for display. Each role list is
    -- already in descending-avgWave order (because we walk `flat`
    -- which was sorted descending and preserve insertion order).
    local byRole = { DPS = {}, Control = {}, Support = {} }
    for _, e in ipairs(flat) do
        local bucket = byRole[e.role] or byRole.DPS
        table.insert(bucket, e)
    end

    return byRole
end

------------------------------------------------------------
-- formatTowerStatsLine — compact one-liner of a tower's salient
-- stats. Read by the end-of-sweep tier dump so Matthew can inspect
-- a tier ranking + the stats driving it without bouncing between
-- the server log and the in-game tower-info card.
--
-- Always prints damage / fireRate / range. Appends mechanic-
-- specific fields (blastRadius, slowPct, lobSeconds, auraRadius,
-- linkRadius, etc.) only when present, so a plain DPS tower's
-- line stays readable while a quirk-heavy aura tower gets its
-- full mechanic surface area inline.
--
-- Lookup priority: TempTowers.Templates first (auxiliary towers,
-- the only entries that appear in the tier list — Cores are slot 1
-- and don't get tiered).
------------------------------------------------------------
local function formatTowerStatsLine(towerId: string): string
    local stats = TempTowers.Templates and TempTowers.Templates[towerId]
    if not stats then return "(no template)" end

    local parts = {
        string.format("dmg=%g",  stats.damage   or 0),
        string.format("fr=%g",   stats.fireRate or 0),
        string.format("rng=%g",  stats.range    or 0),
    }
    -- AOE / splash / blast / chain
    if (stats.blastRadius or 0) > 0 then
        table.insert(parts, string.format("blast=%g", stats.blastRadius))
    end
    if (stats.aoeRadius or 0) > 0 then
        table.insert(parts, string.format("aoe=%g", stats.aoeRadius))
    end
    if (stats.splashRadius or 0) > 0 then
        table.insert(parts, string.format("splash=%g", stats.splashRadius))
    end
    if (stats.chainJumps or 0) > 0 then
        table.insert(parts, string.format("chain=%g(%g)",
            stats.chainJumps, stats.chainFalloff or 0))
    end
    if (stats.pierceCount or 0) > 0 then
        table.insert(parts, string.format("pierce=%g", stats.pierceCount))
    end
    if (stats.lobSeconds or 0) > 0 then
        table.insert(parts, string.format("lob=%gs", stats.lobSeconds))
    end
    -- Slow / stun / DOT
    if (stats.slowPct or 0) > 0 then
        table.insert(parts, string.format("slow=%g%%/%gs",
            stats.slowPct * 100, stats.slowSeconds or 0))
    end
    if (stats.slowStackPct or 0) > 0 then
        table.insert(parts, string.format("slowStack=%g%%×%g",
            stats.slowStackPct * 100, stats.slowStackCap or 0))
    end
    if (stats.patchSlowPct or 0) > 0 then
        table.insert(parts, string.format("patchSlow=%g%%/%gs(r=%g)",
            stats.patchSlowPct * 100,
            stats.patchSeconds or 0,
            stats.patchRadius or 0))
    end
    if (stats.stunSeconds or 0) > 0 then
        table.insert(parts, string.format("stun=%gs/cd=%gs",
            stats.stunSeconds, stats.stunCooldown or 0))
    end
    -- DOT clouds / patches (SporePuffball / HoneyHive)
    if (stats.cloudTickDmg or 0) > 0 then
        table.insert(parts, string.format("cloud=%g/%g/s×%gs(r=%g)",
            stats.cloudTickDmg, stats.cloudTickPerSec or 0,
            stats.cloudSeconds or 0, stats.cloudRadius or 0))
    elseif (stats.patchTickDmg or 0) > 0 then
        table.insert(parts, string.format("patch=%g/%g/s×%gs(r=%g)",
            stats.patchTickDmg, stats.patchTickPerSec or 0,
            stats.patchSeconds or 0, stats.patchRadius or 0))
    end
    -- Blink / link
    if (stats.blinkInterval or 0) > 0 then
        table.insert(parts, string.format("blink=%g/%gs",
            stats.blinkDistance or 0, stats.blinkInterval))
    end
    if (stats.linkRadius or 0) > 0 then
        table.insert(parts, string.format("link=r%g/echo%g",
            stats.linkRadius, stats.linkEchoFrac or 0))
    end
    -- Aura
    if (stats.auraRadius or 0) > 0 then
        local axes = {}
        if (stats.auraDamageBonusPct or 0) > 0 then
            table.insert(axes, string.format("dmg+%g%%", stats.auraDamageBonusPct))
        end
        if (stats.auraFireRateBonusPct or 0) > 0 then
            table.insert(axes, string.format("fr+%g%%", stats.auraFireRateBonusPct))
        end
        if (stats.auraRangeBonusPct or 0) > 0 then
            table.insert(axes, string.format("rng+%g%%", stats.auraRangeBonusPct))
        end
        if #axes > 0 then
            table.insert(parts, string.format("aura(r=%g %s)",
                stats.auraRadius, table.concat(axes, " ")))
        else
            table.insert(parts, string.format("aura(r=%g)", stats.auraRadius))
        end
    end
    return table.concat(parts, " ")
end

------------------------------------------------------------
-- printTierList — server-log readable dump of the tier list.
-- Emitted at AUTO RUN / FAILURE CURVE / TARGETED finish; persistent
-- run history lands in DataStore but the server log IS the
-- copy-pasteable tier-list display surface.
--
-- ea3-132: opts argument added.
--   opts.title    = section header (default "AUTO RUN tier list")
--   opts.withStats = inline tower stats per row (for end-of-sweep
--                    summary only; mid-run incremental dumps stay
--                    compact).
------------------------------------------------------------
local function printTierList(byRole: { [string]: { any } }, opts: { title: string?, withStats: boolean? }?)
    opts = opts or {}
    local title = opts.title or "AUTO RUN tier list"
    local withStats = opts.withStats == true
    print(("[Infinite] -------- %s --------"):format(title))
    for _, role in ipairs({"DPS", "Control", "Support"}) do
        local list = byRole[role] or {}
        if #list == 0 then
            print(("[Infinite]   %s: (no towers)"):format(role))
        else
            print(("[Infinite]   %s:"):format(role))
            for _, e in ipairs(list) do
                if withStats then
                    print(("[Infinite]     %s  %-18s  avg wave %5.2f over %d run(s)  |  %s"):format(
                        e.tier, e.towerId, e.avgWave, e.runs,
                        formatTowerStatsLine(e.towerId)))
                else
                    print(("[Infinite]     %s  %-18s  avg wave %5.2f over %d run(s)"):format(
                        e.tier, e.towerId, e.avgWave, e.runs))
                end
            end
        end
    end
    print(("[Infinite] -------- end %s --------"):format(title))
end

------------------------------------------------------------
-- printRealTierForCore — filter the cumulative pool to one Core,
-- assemble tiers from REAL run finalWaves, print with stats.
-- ea3-132: the existing per-Core printout from runSimForCore is
-- SIM data (closed-form predictions); this companion print shows
-- what actually happened in the live spawner per Core. End-of-
-- sweep dumps fire BOTH so the SIM-vs-REAL comparison is one
-- scroll instead of a UI tab-switch.
--
-- Only entries whose coreId matches simCoreId AND whose
-- balanceVersion >= activeBalanceVersion are counted (matches the
-- validator's scope so the tier numbers align with the delta
-- report above).
------------------------------------------------------------
local function printRealTierForCore(
    cumulativeResults: { any },
    coreId: string,
    activeBalanceVersion: number
)
    local filtered = {}
    for _, r in ipairs(cumulativeResults) do
        if r.coreId == coreId
            and (r.balanceVersion or 0) >= activeBalanceVersion
        then
            table.insert(filtered, r)
        end
    end
    local title = string.format(
        "REAL tier list (core=%s; cumulative pool n=%d, balanceVersion>=%d)",
        coreId, #filtered, activeBalanceVersion)
    if #filtered == 0 then
        print(("[Infinite] -------- %s --------"):format(title))
        print("[Infinite]   (no real runs in scope yet)")
        print(("[Infinite] -------- end %s --------"):format(title))
        return
    end
    local tiers = assembleTiers(filtered)
    printTierList(tiers, { title = title, withStats = true })
end

------------------------------------------------------------
-- 3-wave loop. Every run cycles through these test types in order;
-- the wave counter ramps continuously so wave 1 is AOE-easy and wave
-- 30 is Solo-target-very-hard.
--
--   waveIndex % 3 == 1 → AOE      — many basic mobs in tight clumps.
--                                    Exercises splash, Detonator
--                                    chains, knockback.
--   waveIndex % 3 == 2 → Combined — basic + fast + tank mixed.
--                                    Exercises target-priority +
--                                    overall DPS.
--   waveIndex % 3 == 0 → Solo     — one big tank-type mob, HP-scaled
--                                    by RunDifficultyMult. Exercises
--                                    sustained DPS + stun value.
--
-- Each test function returns a list of {mobType, count} pairs.
------------------------------------------------------------
-- Cycle-1 baseline pools come from Config.InfiniteArena.Pools_C1
-- (single source of truth — InfiniteSimulator reads the same).
-- Pool ratios:
--   AOE      — N basic mobs sharing the pool
--   Combined — basic:fast:tank = 4:3:10 ratio, counts 2:2:1
--                                (24x = pool → x = pool/24)
--   Solo     — 1 tank with the full pool
-- All other waves scale via cycleMult (= 1 + (cycle-1) × CycleStep,
-- applied per-Heartbeat in startSpawnerLoop) and loadoutMult
-- (Config.InfiniteArena.LoadoutMult).
--
-- hpMult values back-derive from base mob HPs in WaveData.MOB_TYPES:
--   basic baseHp = 30, fast baseHp = 18, tank baseHp = 90
local TEST_TYPES = {
    AOE = function(_wave)
        local pool = _IA.Pools_C1.AOE
        local count = 6
        return {
            { mobType = "basic", count = count, hpMult = pool / (count * 30) },
        }
    end,

    Combined = function(_wave)
        -- Pool split 4:3:10 across basic:fast:tank, counts 2:2:1.
        -- Per-mob HP = pool × (ratio / 24): basic 4/24, fast 3/24,
        -- tank 10/24. Tank HP additionally adjusted by
        -- Pools_C1_TankHpDelta.Combined (e.g. -250 per Matthew
        -- 2026-04-27 "remove 250 hp from wave 2 tanks").
        local pool = _IA.Pools_C1.Combined
        local basicHp = pool * (4 / 24)
        local fastHp  = pool * (3 / 24)
        local tankHp  = pool * (10 / 24)
            + ((_IA.Pools_C1_TankHpDelta and _IA.Pools_C1_TankHpDelta.Combined) or 0)
        return {
            { mobType = "basic", count = 2, hpMult = basicHp / 30 },
            { mobType = "fast",  count = 2, hpMult = fastHp  / 18 },
            { mobType = "tank",  count = 1, hpMult = tankHp  / 90 },
        }
    end,

    Solo = function(_wave)
        -- Tank HP = pool + Pools_C1_TankHpDelta.Solo (e.g. -500 per
        -- Matthew 2026-04-27 "500hp from wave 3 tank").
        local pool = _IA.Pools_C1.Solo
            + ((_IA.Pools_C1_TankHpDelta and _IA.Pools_C1_TankHpDelta.Solo) or 0)
        return {
            { mobType = "tank", count = 1, hpMult = pool / 90 },
        }
    end,
}

-- Wave-mod → test-type name, as a frozen lookup so the spawner is
-- a single dispatch and the heart-death summary can name the test
-- the player failed on (e.g. "failed at wave 12 (AOE)").
local TEST_BY_MOD = { [1] = "AOE", [2] = "Combined", [0] = "Solo" }
local function testTypeForWave(wave: number): string
    return TEST_BY_MOD[wave % 3] or "Combined"
end

-- Display alias for testType. Per Matthew 2026-04-27: "wave 10-14:
-- change solo to boss to disambiguate from solo runs." Internal
-- TEST_TYPES key + simulator branch logic stays "Solo" (renaming
-- everywhere is invasive — the simulator + several dispatch
-- branches all key on it). Display label = "Boss" so server log +
-- persisted result + monitor UI all read clearly:
--   "AUTO RUN  3/81  Power + AcornSniper  →  failed at wave 12.41 (Boss)"
-- Solo LOADOUT (1-aux) is a separate concept — the wave-type rename
-- means "solo-loadout failed on Solo wave" no longer reads ambiguously.
local function displayTestType(t: string): string
    if t == "Solo" then return "Boss" end
    return t
end

------------------------------------------------------------
-- Wave duration (game-seconds) — used for the partial-wave-clear
-- time fraction in exit(). Defined as the time it takes the
-- SLOWEST mob in the wave to traverse the full path with no tower
-- resistance — i.e. the natural upper bound on wave lifetime.
--
--   AOE    = 6 basics  → basic speed (8.8 studs/s)
--   Combined / Solo    → tank speed (5.5 studs/s)
--
-- timeFrac = (now - waveStartedAt) / waveDuration, clamped to
-- [0, 1]. A wave that the heart died on near the end (timeFrac
-- ≈ 0.9) scores higher than one that died near the spawn (≈ 0.2).
-- Solo waves benefit most from this — HP ratio used to be binary
-- (1 tank alive = 0%, 1 tank dead = 100%) so the score snapped;
-- time gives a clean continuous gradient.
--
-- Path length comes from InfinitePathGeometry.pathLengthCells()
-- × Config.Grid.CellSize → studs. Mob speeds from MobBaseline.
------------------------------------------------------------
local PATH_LENGTH_STUDS =
    InfinitePathGeometry.pathLengthCells() * (Config.Grid and Config.Grid.CellSize or 2)
local function waveExpectedDuration(testType: string): number
    local mb = (_IA.MobBaseline or {})
    if testType == "AOE" then
        local s = (mb.basic and mb.basic.speed) or 8.8
        return PATH_LENGTH_STUDS / s
    else
        -- Combined and Solo both have a tank as their slowest mob.
        local s = (mb.tank and mb.tank.speed) or 5.5
        return PATH_LENGTH_STUDS / s
    end
end

------------------------------------------------------------
-- Default tower loadout when no payload is provided (dev quick-
-- entry / fallback). When the loadout panel commits, granLoadout
-- is called with `auxIds` instead and ONLY those towers receive
-- stock. Power Core is always granted regardless.
------------------------------------------------------------
local function grantLoadout(player: Player, auxIds: { string }?, coreId: string?, rarity: string?)
    -- Build a set of which aux IDs are picked for this run so we can
    -- set Equipped + stock in lockstep below.
    local picked: { [string]: boolean } = {}
    if auxIds then
        for _, towerId in ipairs(auxIds) do
            picked[towerId] = true
        end
    end
    local grantAll = (auxIds == nil)  -- dev shortcut: nil → equip all

    -- 2026-04-29 ea3-8: rarity selectable in the Infinite loadout
    -- picker. Stamps `<id>Rarity` for every aux template so the
    -- builder's `(player and player:GetAttribute(id.."Rarity")) or "Rare"`
    -- read picks up the loadout-selected tier instead of the per-
    -- player default. Defaults to "Common" (the F-spread baseline)
    -- so the prior cumulative pool runs (all defaulted to "Rare"-ish)
    -- aren't comparable to the new pool — bump balance version on
    -- the first ea3-8 sweep if you care about clean separation.
    local sweepRarity = rarity or "Common"

    -- Aux towers: stock + Equipped flag together. Picked = template
    -- stock + Equipped=true. Un-picked = stock 0 + Equipped=false.
    -- The Equipped attribute drives hotbar visibility now (see
    -- init.client.lua's buildHotbar revision 2026-04-26): once set,
    -- the slot stays visible even after the tower is placed (stock
    -- → 0). When the loadout changes (re-pick / AUTO RUN round),
    -- Equipped flips and the hotbar rebuilds.
    for towerId, tpl in pairs(TempTowers.Templates) do
        local isEquipped = grantAll or picked[towerId] == true
        if isEquipped then
            player:SetAttribute(towerId .. "Stock", tpl.stock)
            player:SetAttribute(towerId .. "Equipped", true)
            player:SetAttribute(towerId .. "Rarity", sweepRarity)
        else
            player:SetAttribute(towerId .. "Stock", 0)
            player:SetAttribute(towerId .. "Equipped", false)
        end
    end
    -- Core grant: ONE core per run (Power / ControlCore / SupportCore
    -- per Matthew 2026-04-27). Default Power. Other cores get stock=0
    -- so the hotbar only shows the picked core's slot.
    coreId = coreId or "Power"
    for _, id in ipairs(CoreTypes.Ids) do
        if id == coreId then
            player:SetAttribute(id .. "Stock", 1)
            player:SetAttribute(id .. "Equipped", true)
        else
            player:SetAttribute(id .. "Stock", 0)
            player:SetAttribute(id .. "Equipped", false)
        end
    end

    -- Power Core gets starting Special, Stun, and AOE upgrade
    -- cards on Infinite-mode entry per Matthew 2026-04-26:
    -- "give the core tower the starting special, stun, and aoe
    -- cards on autorun start." These player-attributes get
    -- stamped onto the Core at placement time (see
    -- TowerPlacement / TowerBuilders Power path). Base values
    -- match SPECIAL_EFFECTS in UpgradeCards.lua so a Core with
    -- these starting cards behaves identically to one that
    -- picked the cards organically on Map 1.
    player:SetAttribute("CoreAoeRadius",       4)
    player:SetAttribute("CoreStunDuration",    0.5)
    player:SetAttribute("CoreStunChance",      0.05)
    player:SetAttribute("CoreKnockback",       3)
    player:SetAttribute("CoreKnockbackChance", 0.05)

    -- 2026-04-28 di: legacy DoTStock/CCStock zeroing dropped — those
    -- archetype cards are gone from the picker.
    player:SetAttribute("CarryingAmmo", 0)
    player:SetAttribute("RerollTokens", 5)
    -- Mark "stock granted" so the client unhides the hotbar via the
    -- standard plumbing (TreeOfLife_Hub watches HasBeenGrantedStock).
    player:SetAttribute("HasBeenGrantedStock", true)
end

-- ea3-117: setupReturnPortal removed per Matthew 2026-04-30. The in-
-- world "RETURN TO HUB" billboard label was creating confusion vs the
-- GameOverBanner modal (which I'd been chasing all session as the
-- "ghost banner" — wrong source). Players exit via DevReset / RUN
-- RESET / SIMULATE menu paths; no in-world portal needed in the
-- Infinite arena. Function definition + the lazy-init call site
-- (formerly Infinite.lua:2744) both deleted in the same commit.

-- Public exposure of the queue builders so tests + future tools
-- can fire them without re-implementing the queue composition.
-- All four are PURE functions (input → queue list, no side
-- effects, no upvalue capture of mutable state) so exposing them
-- is safe.
Infinite.buildAutoRunQueue    = buildAutoRunQueue
Infinite.buildLongAutoQueue   = buildLongAutoQueue
Infinite.buildFullAutoQueue   = buildFullAutoQueue
Infinite.buildSelectAutoQueue = buildSelectAutoQueue
Infinite.buildTopCombosQueue  = buildTopCombosQueue
Infinite.buildTowerSuperQueue = buildTowerSuperQueue

function Infinite.setup(ctx)
    -- Hydrate cumulative pool from DataStore on server boot.
    -- Lazy-loaded; falls back to an empty list if DataStore is
    -- unavailable (Studio without API access). Per Matthew
    -- 2026-04-26: "hook up the data store so we can save autorun
    -- data."
    do
        local loaded = InfiniteRunHistoryStore.loadCumulative()
        if loaded and #loaded > 0 then
            cumulativeResults = loaded
            print(("[Infinite] cumulative pool hydrated from DataStore — %d run(s)"):format(
                #cumulativeResults))
        end
        currentBalanceVersion = InfiniteRunHistoryStore.getBalanceVersion()
        print(("[Infinite] active balance version = %d"):format(currentBalanceVersion))
        -- ea3-121 one-time migration: live changed to rarity-greedy
        -- upgrade picks (was uniform random index). Bump balance era
        -- once so old random-pick cumulative results stay grouped
        -- separately in LOAD RUNS. Idempotent: subsequent boots see
        -- version >= MIN_VERSION_FOR_RARITY_GREEDY and no-op.
        do
            local MIN_VERSION_FOR_RARITY_GREEDY = 17
            if currentBalanceVersion < MIN_VERSION_FOR_RARITY_GREEDY then
                local oldVer = currentBalanceVersion
                currentBalanceVersion = InfiniteRunHistoryStore.bumpBalanceVersion()
                print(("[Infinite] ea3-121 migration: balance era bumped %d → %d (rarity-greedy live picks; old era's runs preserved separately)"):format(
                    oldVer, currentBalanceVersion))
            end
        end
        -- 2026-04-29 ea3-5: hydrate per-Core sim cache so a
        -- mid-SUPER-AUTO crash doesn't drop the pre-sweep sims.
        -- Most-recent simulatedSweep populated from whichever Core
        -- has the latest completedAt (export's legacy field).
        local loadedSim = InfiniteRunHistoryStore.loadSim()
        if loadedSim then
            simulatedSweepByCore = loadedSim
            local mostRecent, mostRecentTs = nil, 0
            local n = 0
            for _, rec in pairs(loadedSim) do
                n = n + 1
                local ts = (type(rec) == "table" and rec.completedAt) or 0
                if ts > mostRecentTs then
                    mostRecentTs = ts
                    mostRecent = rec
                end
            end
            simulatedSweep = mostRecent
            if n > 0 then
                print(("[Infinite] sim cache hydrated from DataStore — %d Core(s)"):format(n))
            end
        end
    end

    local function getHubSpawnCF(): CFrame
        return ctx.HUB_SPAWN_CF or CFrame.new(0, 5, 5)
    end
    local function getMap4SpawnCF(): CFrame
        return ctx.MAP4_PLAYER_SPAWN_CF or CFrame.new(8000, 105, 0)
    end

    local enterRemote = Remotes.getOrCreate(Remotes.Names.EnterInfinite, "RemoteEvent")
    local exitRemote  = Remotes.getOrCreate(Remotes.Names.ExitInfinite, "RemoteEvent")
    local pickRemote  = Remotes.getOrCreate(Remotes.Names.PickInfiniteScenario, "RemoteEvent")
    local roundRemote = Remotes.getOrCreate(Remotes.Names.InfiniteRoundUpdate, "RemoteEvent")
    local autoPlaceRemote = Remotes.getOrCreate(Remotes.Names.InfiniteAutoPlace, "RemoteEvent")
    local countdownRemote = Remotes.getOrCreate(Remotes.Names.InfiniteCountdown, "RemoteEvent")
    local skipRemote      = Remotes.getOrCreate(Remotes.Names.InfiniteSkipCountdown, "RemoteEvent")
    local forceExitRemote = Remotes.getOrCreate(Remotes.Names.InfiniteForceExit, "RemoteEvent")
    local totalResetRemote = Remotes.getOrCreate(Remotes.Names.InfiniteTotalReset, "RemoteEvent")
    local autoRunRemote        = Remotes.getOrCreate(Remotes.Names.InfiniteAutoRun, "RemoteEvent")
    local longAutoRemote       = Remotes.getOrCreate(Remotes.Names.InfiniteLongAutoRun, "RemoteEvent")
    local fullAutoRemote       = Remotes.getOrCreate(Remotes.Names.InfiniteFullAutoRun, "RemoteEvent")
    local superAutoRemote      = Remotes.getOrCreate(Remotes.Names.InfiniteSuperAutoRun, "RemoteEvent")
    local towerSuperRemote     = Remotes.getOrCreate(Remotes.Names.InfiniteTowerSuperRun, "RemoteEvent")
    local selectAutoRemote     = Remotes.getOrCreate(Remotes.Names.InfiniteSelectAutoRun, "RemoteEvent")
    local autoRunProgressRemote = Remotes.getOrCreate(Remotes.Names.InfiniteAutoRunProgress, "RemoteEvent")
    local autoRunDoneRemote    = Remotes.getOrCreate(Remotes.Names.InfiniteAutoRunDone, "RemoteEvent")
    local runCompletedRemote   = Remotes.getOrCreate(Remotes.Names.InfiniteRunCompleted, "RemoteEvent")
    local lastSweepReqRemote   = Remotes.getOrCreate(Remotes.Names.InfiniteRequestLastSweep, "RemoteEvent")
    local lastSweepDataRemote  = Remotes.getOrCreate(Remotes.Names.InfiniteLastSweepData, "RemoteEvent")
    local sweepHistoryReqRemote  = Remotes.getOrCreate(Remotes.Names.InfiniteRequestSweepHistory, "RemoteEvent")
    local sweepHistoryDataRemote = Remotes.getOrCreate(Remotes.Names.InfiniteSweepHistoryData, "RemoteEvent")
    local loadSweepByIdxRemote   = Remotes.getOrCreate(Remotes.Names.InfiniteLoadSweepByIndex, "RemoteEvent")
    local loadByVersionRemote    = Remotes.getOrCreate(Remotes.Names.InfiniteLoadByBalanceVersion, "RemoteEvent")
    local balanceResetRemote     = Remotes.getOrCreate(Remotes.Names.InfiniteBalanceReset, "RemoteEvent")
    local visualsToggleRemote    = Remotes.getOrCreate(Remotes.Names.InfiniteVisualsToggle, "RemoteEvent")
    local simulateRemote         = Remotes.getOrCreate(Remotes.Names.InfiniteSimulate, "RemoteEvent")
    local simulateDataRemote     = Remotes.getOrCreate(Remotes.Names.InfiniteSimulateData, "RemoteEvent")
    local stopRunRemote          = Remotes.getOrCreate(Remotes.Names.InfiniteStopRun, "RemoteEvent")
    local exportDataRemote       = Remotes.getOrCreate(Remotes.Names.InfiniteExportData, "RemoteEvent")
    local exportDataReadyRemote  = Remotes.getOrCreate(Remotes.Names.InfiniteExportDataReady, "RemoteEvent")

    -- Forward-decl: STOP RUN / forceExit handlers below need to call
    -- exit() (the canonical run-teardown path), but its assignment
    -- lives ~900 lines later because it depends on enter / enterIdle
    -- / startSpawnerLoop. Hoisted here per CLAUDE.md "Lua resolves
    -- free variables at function-DEFINITION time" — without this
    -- hoist the STOP RUN handler captured the global `exit` (nil)
    -- and crashed at click time: 02:45:13 [Infinite] line 779:
    -- attempt to call a nil value. Re-declared at the original
    -- site below as a `do nothing` to keep the existing assignment
    -- pattern; this hoisted forward-decl is the canonical local.
    local enter, exit, enterIdle, enterPrepare
    -- Forward-decl: STOP NOW handler (registered below) calls these
    -- helpers, which are defined ~700 lines later. Hoisted so the
    -- handler closure captures the upvalue rather than the global.
    local stopSpawner, destroyMap4Towers

    -- EXPORT DATA: assembles the cumulative pool + per-tower
    -- aggregates + per-pair stats + last sweep tiers into a single
    -- JSON string for offline analysis. Per Matthew 2026-04-27.
    -- Computed server-side because cumulativeResults lives here;
    -- client receives the encoded string via InfiniteExportDataReady
    -- and dumps it to F9 + a copyable modal.
    exportDataRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local HttpService = game:GetService("HttpService")

        -- Per-tower aggregate over cumulativeResults.
        local towerAgg = {}
        for _, r in ipairs(cumulativeResults) do
            local n = (r.auxIds and #r.auxIds) or 0
            local isTrio = n >= 3
            for _, id in ipairs(r.auxIds or {}) do
                if not (id == AUTO_RUN_ANCHOR and isTrio) then
                    towerAgg[id] = towerAgg[id] or { runs = 0, totalWave = 0, byCategory = { Solo = 0, Duo = 0, Trio = 0 } }
                    towerAgg[id].runs = towerAgg[id].runs + 1
                    towerAgg[id].totalWave = towerAgg[id].totalWave + (r.finalWave or 0)
                    if n == 1 then towerAgg[id].byCategory.Solo = towerAgg[id].byCategory.Solo + 1
                    elseif n == 2 then towerAgg[id].byCategory.Duo = towerAgg[id].byCategory.Duo + 1
                    elseif n >= 3 then towerAgg[id].byCategory.Trio = towerAgg[id].byCategory.Trio + 1
                    end
                end
            end
        end
        for _, agg in pairs(towerAgg) do
            agg.avgWave = agg.totalWave / math.max(1, agg.runs)
        end

        -- Per-unordered-pair (combo) aggregate over duo/trio results.
        local pairAgg = {}
        local function pairKey(a, b)
            if a > b then a, b = b, a end
            return a .. "+" .. b
        end
        for _, r in ipairs(cumulativeResults) do
            local aux = r.auxIds or {}
            local n = #aux
            if n >= 2 then
                local realAux = {}
                for _, id in ipairs(aux) do
                    if not (id == AUTO_RUN_ANCHOR and n >= 3) then
                        table.insert(realAux, id)
                    end
                end
                for i = 1, #realAux do
                    for j = i + 1, #realAux do
                        local key = pairKey(realAux[i], realAux[j])
                        pairAgg[key] = pairAgg[key] or { runs = 0, totalWave = 0 }
                        pairAgg[key].runs = pairAgg[key].runs + 1
                        pairAgg[key].totalWave = pairAgg[key].totalWave + (r.finalWave or 0)
                    end
                end
            end
        end
        for _, agg in pairs(pairAgg) do
            agg.avgWave = agg.totalWave / math.max(1, agg.runs)
        end

        local config = {
            cycleStep       = CYCLE_STEP,
            loadoutMults    = {
                ["1"] = _IA.LoadoutMult[1],
                ["2"] = _IA.LoadoutMult[2],
                ["3"] = _IA.LoadoutMult[3],
            },
            anchor          = AUTO_RUN_ANCHOR,
            pools_C1        = _IA.Pools_C1,
            heartHp         = (Config.Map4 and Config.Map4.HeartMaxHp) or 50000,
            maxAutoRunWave  = MAX_AUTO_RUN_WAVE,
        }

        -- Full payload — printed to F9 (no length cap there). Includes
        -- the bulky cumulativeResults pool which can run 200k+ chars
        -- once you've accumulated 1k+ runs.
        local fullPayload = {
            schemaVersion = 1,
            exportedAt    = os.time(),
            config = config,
            cumulativeCount = #cumulativeResults,
            cumulativeResults = cumulativeResults,
            towerAggregate  = towerAgg,
            pairAggregate   = pairAgg,
            lastSweep       = lastSweep,
            simulatedSweep  = simulatedSweep,
            -- 2026-04-29 ea3-5: per-Core sim cache. simulatedSweep
            -- (above) only carries the most-recent fire — for SUPER
            -- AUTO + crash recovery the analyst wants all 3 Cores'
            -- predictions side-by-side. DataStore-backed via
            -- InfiniteRunHistoryStore.saveSim so a server crash
            -- doesn't lose them. Keys = "Power" / "ControlCore" /
            -- "SupportCore"; values = same simRecord shape as
            -- simulatedSweep.
            simulatedSweepByCore = simulatedSweepByCore,
            lastRunStats    = lastRunStats,
        }

        -- Summary payload — small enough to fit in the Roblox TextBox
        -- 200k-char limit (tower + pair aggregates only; no per-run
        -- pool). Per Matthew 2026-04-27 bug report: the modal crashed
        -- on 234k-char strings because Roblox capped at 200k. F9 keeps
        -- the full JSON; modal copy-friendly view shows the summary.
        local summaryPayload = {
            schemaVersion = 1,
            exportedAt    = os.time(),
            config = config,
            cumulativeCount = #cumulativeResults,
            -- cumulativeResults intentionally OMITTED — see F9 for full
            towerAggregate  = towerAgg,
            pairAggregate   = pairAgg,
            lastSweep       = lastSweep and {
                tiers       = lastSweep.tiers,
                completedAt = lastSweep.completedAt,
                total       = lastSweep.total,
                aborted     = lastSweep.aborted,
                -- results omitted (also large)
            } or nil,
            -- 2026-04-29 ea3-5: per-Core sim summary — tier lists
            -- + validator overall numbers only, no per-loadout
            -- results array. Keeps the modal-copy summary readable
            -- while still showing all 3 Cores' predictions.
            simulatedSweepByCore = (function()
                local out = {}
                for coreId, rec in pairs(simulatedSweepByCore) do
                    if type(rec) == "table" then
                        out[coreId] = {
                            tiers       = rec.tiers,
                            completedAt = rec.completedAt,
                            total       = rec.total,
                            simulated   = rec.simulated,
                            coreId      = rec.coreId,
                            validation  = rec.validation and {
                                overall = rec.validation.overall,
                                -- per-bucket / per-tower omitted (large)
                            } or nil,
                        }
                    end
                end
                return out
            end)(),
            lastRunStats    = lastRunStats,
        }

        local okFull, fullJson = pcall(HttpService.JSONEncode, HttpService, fullPayload)
        if not okFull then
            warn(("[Infinite] EXPORT DATA encode failed: %s"):format(tostring(fullJson)))
            return
        end
        local okSum, summaryJson = pcall(HttpService.JSONEncode, HttpService, summaryPayload)
        if not okSum then
            warn(("[Infinite] EXPORT DATA summary encode failed: %s"):format(tostring(summaryJson)))
            summaryJson = nil
        end

        local simCount = 0
        for _ in pairs(simulatedSweepByCore) do simCount = simCount + 1 end
        print(("[Infinite] EXPORT DATA — %d cumulative runs, %d towers, %d pairs, %d sim Core(s), full %d chars, summary %d chars"):format(
            #cumulativeResults,
            (function() local n = 0; for _ in pairs(towerAgg) do n = n + 1 end; return n end)(),
            (function() local n = 0; for _ in pairs(pairAgg) do n = n + 1 end; return n end)(),
            simCount,
            #fullJson, summaryJson and #summaryJson or 0))
        exportDataReadyRemote:FireClient(player, {
            json    = fullJson,      -- F9 dump; can be huge
            summary = summaryJson,    -- modal display; <200k
        })
    end)

    -- STOP RUN: two-mode handler per Matthew 2026-04-27 "STOP AT END"
    -- vs "STOP NOW" UX:
    --   payload.mode = "atEnd" — clear the continuous flag so the
    --     CURRENT sweep finishes naturally (queue drains, finalize
    --     fires, no new sweep starts). The user keeps the run rolling
    --     to capture all the stat-ledger data, then auto-stops.
    --   payload.mode = "now"   — abort the in-flight run immediately
    --     (legacy behavior). Partial-sweep tier list still gets
    --     captured + persisted for whatever the player has so far.
    -- Default = "now" (backwards-compat for any existing callers).
    stopRunRemote.OnServerEvent:Connect(function(player, payload)
        if not player or not player.Parent then return end
        local mode = (type(payload) == "table" and payload.mode) or "now"

        -- MANUAL ABORT — STOP button on the InfiniteButtonBar after
        -- a GO-started manual run. Per Matthew 2026-04-27: "STOP
        -- prompts are you sure? and no data is processed."
        -- Tears down the spawner + clears towers + restores heart,
        -- WITHOUT recording a result entry to autoRun.results /
        -- cumulativeResults. Player stays in arena (idle) so they
        -- can re-pick a loadout and try again.
        if mode == "manualAbort" then
            if autoRun.active then return end  -- AUTO RUN uses its own paths
            if not State.active or State.activePlayer ~= player then return end
            print(("[Infinite] %s STOP — manual run aborted, no stats recorded"):format(player.Name))
            stopSpawner()
            destroyMap4Towers(player)
            State.activePlayer = nil
            State.wave = 0
            State.heartOverkill = 0
            State.killingMobWave          = nil
            State.killingMobWaveStartedAt = nil
            State.killingMobWaveDuration  = nil
            -- Restore heart so a follow-up loadout pick has a fresh
            -- target. (stopSpawner already cleared the manual-run
            -- attribute via the SetAttribute path inside it.)
            if ctx.map4Heart then
                local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
                ctx.map4Heart:SetAttribute("Health", maxHp)
            end
            -- StatLedger is already off for manual runs (only
            -- AUTO RUN flips it on). No reset needed.
            return
        end

        -- AUTO RUN STOP modes from here on — gate on autoRun.active.
        if not autoRun.active then return end

        if mode == "continuous" then
            -- Re-enable continuous sweep loop (toggle mode in the
            -- monitor's 3-state picker). Per Matthew 2026-04-28:
            -- "left and right button on STOP NOW [...] to switch
            -- between continuous, stop at end, and then stop now."
            autoRun.continuous = true
            print(("[Infinite] %s set CONTINUOUS — sweep #%d will auto-loop after queue drains")
                :format(player.Name, autoRun.sweepNum or 0))
            return
        end

        if mode == "atEnd" then
            autoRun.continuous = false  -- finalize() will go idle when queue drains
            print(("[Infinite] %s requested STOP AT END — current sweep #%d (%d/%d) will finish, no next sweep")
                :format(player.Name, autoRun.sweepNum or 0,
                    #(autoRun.results or {}), autoRun.total or 0))
            return
        end

        -- mode == "now": full abort — clear continuous AND
        -- forceExit-style teardown of the in-flight run, BUT
        -- keep the player in the swamp arena (don't teleport
        -- back to hub spawn). Per Matthew 2026-04-27: "dont
        -- port back to start when you stop autorun."
        autoRun.continuous = false
        print(("[Infinite] %s requested STOP NOW — aborting after %d sweep(s) + %d run(s) of current sweep")
            :format(player.Name, autoRun.sweepNum or 0, #(autoRun.results or {})))
        if State.activePlayer == player then
            if autoRun.results and #autoRun.results > 0 then
                local tiers = assembleTiers(autoRun.results)
                printTierList(tiers)
                lastSweep = {
                    tiers          = tiers,
                    results        = autoRun.results,
                    completedAt    = os.time(),
                    total          = autoRun.total,
                    aborted        = true,
                    balanceVersion = currentBalanceVersion,
                }
                -- 2026-04-29 ea: skip results already flushed by the
                -- SUPER AUTO checkpointer so we don't double-count
                -- them in the cumulative pool on STOP NOW.
                local stopStartIdx = (autoRun.cumulativeFlushedIdx or 0) + 1
                for i = stopStartIdx, #autoRun.results do
                    table.insert(cumulativeResults, autoRun.results[i])
                end
                InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
                InfiniteRunHistoryStore.append(lastSweep)
            end
            autoRun.active   = false
            autoRun.queue    = nil
            autoRun.current  = nil
            autoRun.results  = nil
            autoRun.total    = 0
            autoRun.sweepNum = 0
            autoRun.superAutoCoreQueue = nil  -- 2026-04-29 ea: clear SUPER AUTO queue on STOP NOW
            autoRun.isSuperAuto          = nil
            autoRun.isTowerSuper         = nil  -- 2026-04-29 ea3-24: clear TOWER SUPER state
            autoRun.towerSuperRarityCoreQueue = nil
            autoRun.towerSuperFocusAux   = nil
            autoRun.cumulativeFlushedIdx = nil
            StatLedger.setRecordingEnabled(false)
            -- In-place teardown: stop the spawner + clear mobs +
            -- destroy the auto-placed towers. Keep the player in
            -- swamp idle (no exit() call → no hub teleport, no
            -- map switch). The autoRunDone broadcast tells the
            -- monitor window to flip back to the post-sweep view.
            stopSpawner()
            destroyMap4Towers(player)
            State.activePlayer = nil
            State.wave = 0
            State.heartOverkill = 0
            State.killingMobWave          = nil
            State.killingMobWaveStartedAt = nil
            State.killingMobWaveDuration  = nil
            -- Restore the heart so a follow-up loadout pick has
            -- a fresh target.
            if ctx.map4Heart then
                local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
                ctx.map4Heart:SetAttribute("Health", maxHp)
            end
            -- Tell the monitor window the sweep is over so its
            -- STOP-button / run-list views update.
            autoRunDoneRemote:FireClient(player, {
                results     = lastSweep and lastSweep.results or {},
                tiers       = lastSweep and lastSweep.tiers,
                completedAt = lastSweep and lastSweep.completedAt or os.time(),
                total       = lastSweep and lastSweep.total or 0,
                aborted     = true,
            })
        end
    end)

    -- SIMULATE: pure-math closed-form sweep over the AUTO RUN
    -- queue. Results stored in `simulatedSweep` (parallel cache,
    -- DOES NOT touch cumulativeResults / lastSweep). Per Matthew
    -- 2026-04-27: "keep this data separate until I can validate
    -- it." Server prints the sim tier list to the log + fires
    -- the data back to the client for optional display.
    --
    -- Phase 1 of project_simulator_improvement.md: extended to
    -- compare each sim result against the matching real-sweep
    -- entries in cumulativeResults via InfiniteValidator. The F9
    -- log now shows BOTH the sim tier list AND the sim-vs-real
    -- delta breakdown by category / role-mix / carries-tower so
    -- every later phase has a measurable success metric (did the
    -- median |delta| shrink?). The full per-loadout table + buckets
    -- ride along on the simulateDataRemote payload so the admin
    -- panel's VALIDATE section can render them.
    -- Helper: run one closed-form sim for a given Core archetype,
    -- print the tier list + validator delta, return the simulatedSweep
    -- payload. Extracted so SuperAutoRun can call this 3× (one per
    -- Core) without duplicating the print+validator boilerplate.
    -- skipPersist=true updates the in-memory simulatedSweepByCore dict
    -- without flushing to DataStore. Batch callers (e.g.
    -- autoFireRunSimAllCores, the FAILURE CURVE post-sweep loop) skip
    -- per-call saves and call InfiniteRunHistoryStore.saveSim once at
    -- the end — collapses 3 DataStore writes into 1. ea3-118 fix:
    -- previously the 3-call burst at sweep start hit Studio's
    -- DataStore request queue and printed two "request queue" warnings
    -- per sweep.
    local function runSimForCore(simCoreId, skipPersist)
        local startWall = os.clock()
        local queue = buildAutoRunQueue(simCoreId)
        local results = InfiniteSimulator.runSweep(queue, simCoreId)
        local elapsed = os.clock() - startWall
        local tiers = assembleTiers(results)
        print(("[Infinite] SIMULATE complete in %.3f s — %d loadouts evaluated (core=%s)"):format(
            elapsed, #results, simCoreId))
        printTierList(tiers, {
            title = string.format(
                "SIM tier list (core=%s; closed-form math; not validated)",
                simCoreId),
        })
        -- ea3-123: scope the validator to current-era real data only.
        -- The cumulative pool spans all eras (v16 random-pick, v17
        -- rarity-greedy, etc.) but we're only ever calibrating
        -- against the active era's behavior. Without the filter,
        -- old-era data biases the deltas — cleaner to compare like
        -- with like. Telemetry: report includes skippedByEra count.
        local validationReport = InfiniteValidator.compare({
            sim               = results,
            real              = cumulativeResults,
            roleByTowerId     = TempTowers.RoleByTowerId,
            minBalanceVersion = currentBalanceVersion,
        })
        InfiniteValidator.printReport(validationReport)
        -- ea3-132: REAL per-Core tier dump with inline stats. Every
        -- tier-listed tower's salient mechanic stats (damage, fr,
        -- range, blast, lob, aura axes, slow/stun/dot, etc.) print
        -- alongside its avgWave so the balance pass after a sweep
        -- doesn't need to bounce between the log and the in-game
        -- tower-info card. This is what the user actually wants
        -- inspecting after a sweep — SIM tier above is calibration
        -- data; this is the ground truth.
        printRealTierForCore(cumulativeResults, simCoreId, currentBalanceVersion)
        local simRecord = {
            tiers       = tiers,
            results     = results,
            completedAt = os.time(),
            total       = #results,
            simulated   = true,
            validation  = validationReport,
            coreId      = simCoreId,
            balanceVersion = currentBalanceVersion,
        }
        -- 2026-04-29 ea3-5: persist per-Core sim cache so a server
        -- crash mid-SUPER-AUTO doesn't drop already-computed sims.
        -- saveSim writes the FULL dict, so we update the entry first.
        simulatedSweepByCore[simCoreId] = simRecord
        if not skipPersist then
            InfiniteRunHistoryStore.saveSim(simulatedSweepByCore)
        end
        return simRecord
    end

    simulateRemote.OnServerEvent:Connect(function(player, payload)
        if not player or not player.Parent then return end
        -- 2026-04-29 ea: payload.coreId optional override; falls
        -- back to preferredCoreId. Used by SuperAutoRun to fire
        -- per-Core sims at start.
        local simCoreId
        if type(payload) == "table" and type(payload.coreId) == "string" then
            simCoreId = payload.coreId
        else
            simCoreId = State.preferredCoreId or "Power"
        end
        simulatedSweep = runSimForCore(simCoreId)
        simulateDataRemote:FireClient(player, simulatedSweep)
    end)

    -- VISUALS toggle: flips Workspace.InfiniteVisuals on each
    -- client fire. Default off. Per Matthew 2026-04-27.
    if Workspace:GetAttribute("InfiniteVisuals") == nil then
        Workspace:SetAttribute("InfiniteVisuals", false)
    end
    visualsToggleRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local cur = Workspace:GetAttribute("InfiniteVisuals") == true
        Workspace:SetAttribute("InfiniteVisuals", not cur)
        print(("[Infinite] %s toggled VISUALS → %s"):format(
            player.Name, (not cur) and "ON" or "OFF"))
    end)

    -- Apply the VISUALS attribute to all currently-spawned mobs
    -- whenever it changes. Without this, toggling the button only
    -- affects FUTURE mobs (MobFactory.makeMob reads the attribute
    -- at spawn time) — existing mobs would keep their original
    -- transparency.
    Workspace:GetAttributeChangedSignal("InfiniteVisuals"):Connect(function()
        local visible = Workspace:GetAttribute("InfiniteVisuals") == true
        local Tags = require(Shared:WaitForChild("Tags"))
        for _, mob in ipairs(CollectionService:GetTagged(Tags.Mob)) do
            if mob:IsA("BasePart") then
                mob.Transparency = visible and 0 or 1
            end
        end
    end)

    -- Auto-toggle VISUALS based on game speed per Matthew
    -- 2026-04-27: "turn visuals on at 20x and lower, turn them
    -- off at 50x and higher automatically." Speeds in the ladder
    -- are {1, 2, 3, 5, 10, 20, 50, 100, 200, 400}; the threshold
    -- between low-speed-visible and high-speed-hidden sits at the
    -- 20→50 jump. Manual button still works as a one-off override
    -- but a subsequent speed change re-applies the rule.
    local function applyVisualsForSpeed()
        local speed = Workspace:GetAttribute("GameSpeed") or 1
        local shouldShow = speed <= 20
        if Workspace:GetAttribute("InfiniteVisuals") ~= shouldShow then
            Workspace:SetAttribute("InfiniteVisuals", shouldShow)
        end
    end
    Workspace:GetAttributeChangedSignal("GameSpeed"):Connect(applyVisualsForSpeed)
    -- Apply current state on boot so a player entering Map 4 at
    -- 1× starts with VISUALS = true without needing to bump speed.
    applyVisualsForSpeed()
    skipRemote.OnServerEvent:Connect(function(player)
        if State.activePlayer ~= player then return end
        State.skipCountdown = true
    end)
    -- Pre-create the picker remote so HubWorld can FireClient on it.
    Remotes.getOrCreate(Remotes.Names.ShowInfiniteScenarioPicker, "RemoteEvent")

    local function teleportTo(player: Player, cf: CFrame)
        local character = player.Character
        if not character then return end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        hrp.CFrame = cf
    end

    -- Forward decls so functions defined earlier can reference
    -- functions defined later. Lua's local-binding rule is: the
    -- reference must point to a local declared BEFORE the closure,
    -- otherwise it falls through to globals (and becomes nil).
    -- (enter / exit / enterIdle are forward-declared near the top
    -- of setup() so the STOP RUN / forceExit / EXPORT DATA remote
    -- handlers above can call exit() — they're defined in this
    -- order:
    --   - startSpawnerLoop references `exit` (AUTO RUN wave cap)
    --   - exit references `enter` (AUTO RUN dequeue → restart)
    --   - enter references `enterIdle` (auto-route if not in arena)
    -- Re-declaring here would shadow the hoisted local, so the
    -- assignments below land on the SAME upvalues the handlers
    -- already captured. Per CLAUDE.md "Lua resolves free variables
    -- at function-DEFINITION time".)

    ------------------------------------------------------------
    -- applyWaveCycleUpgrades — fired after every Boss wave (wave %
    -- 3 == 0). Walks every Map 4 tower owned by `player` and stamps
    -- a common-mean upgrade onto its Damage / FireRate / Range
    -- attributes.
    --
    -- State (per-run; reset on enter()):
    --   State.auxRangeMult / State.coreRangeMult — cumulative
    --     range multipliers. Cards stop applying range once these
    --     hit RANGE_CAP_MULT (2.0).
    --   State.auxRangeCapped / State.coreRangeCapped — once these
    --     flip true, damage + firerate cards apply at 1.5× effect.
    ------------------------------------------------------------
    local function applyWaveCycleUpgrades(player: Player)
        if not player or not player.Parent then return end
        local map4ColOffset = ctx.MAP4_COL_OFFSET or 225

        -- Compute current effects per category. If range is capped,
        -- damage + firerate get the 1.5× boost.
        local function effectsFor(capped: boolean)
            local boost = capped and POST_CAP_EFFECT_BOOST or 1.0
            return {
                damageDelta   = COMMON_DAMAGE_FLAT * boost,
                fireRateDelta = COMMON_FIRERATE_DELTA * boost,
                rangeDelta    = (not capped) and COMMON_RANGE_DELTA or 0,
            }
        end
        local auxFx  = effectsFor(State.auxRangeCapped == true)
        local coreFx = effectsFor(State.coreRangeCapped == true)

        -- 2026-04-29 ea: classify all 3 Cores (Power/ControlCore/
        -- SupportCore) as Core for fx selection — was hardcoded to
        -- Power only, leaving ControlCore + SupportCore reading the
        -- aux range-cap state. Per Matthew 2026-04-29: "changes in
        -- infinite and story should always be synced." 2026-04-29
        -- ea3: replaced inline { Power=true, ... } literal with
        -- CoreTypes.Set so the Core list lives in one place.
        local touched = 0
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local model = base.Parent
            if model and model:IsA("Model") then
                local owner = model:GetAttribute("Owner")
                local anchorCol = model:GetAttribute("AnchorCol") or -1
                if owner == player.UserId and anchorCol >= map4ColOffset then
                    local towerType = model:GetAttribute("TowerType")
                    local fx = CoreTypes.Set[towerType] and coreFx or auxFx
                    -- Damage: flat add. FireRate: % bump. Range: %
                    -- bump unless this category is range-capped.
                    --
                    -- 2026-04-29 ea: ControlCore mirrors the story-mode
                    -- 80/20 split — 80% of damageDelta lands on Damage,
                    -- 20% lands on StackDotTickDmg. Without this the
                    -- Infinite per-cycle damage upgrade dumps the full
                    -- delta onto the direct-hit slot, leaving the DOT
                    -- proc fixed at template baseline (4) for the whole
                    -- run. Story mode applies the same split inside
                    -- UpgradeCards / TowerPlacement so the two paths
                    -- now agree (Matthew 2026-04-29: "changes in
                    -- infinite and story should always be synced").
                    local d = model:GetAttribute("Damage")
                    if type(d) == "number" then
                        if towerType == "ControlCore" then
                            local damageShare = math.floor(fx.damageDelta * 0.8 + 0.5)
                            local dotShare = fx.damageDelta - damageShare
                            model:SetAttribute("Damage", d + damageShare)
                            if dotShare > 0 then
                                local dot = model:GetAttribute("StackDotTickDmg") or 0
                                model:SetAttribute("StackDotTickDmg", dot + dotShare)
                            end
                        else
                            model:SetAttribute("Damage", d + fx.damageDelta)
                        end
                    end
                    local fr = model:GetAttribute("FireRate")
                    if type(fr) == "number" then
                        model:SetAttribute("FireRate", fr * (1 + fx.fireRateDelta))
                    end
                    if fx.rangeDelta > 0 then
                        local rg = model:GetAttribute("Range")
                        if type(rg) == "number" then
                            model:SetAttribute("Range", rg * (1 + fx.rangeDelta))
                        end
                    end
                    touched = touched + 1
                end
            end
        end

        -- Bump cumulative range multipliers (only if not yet capped).
        -- Once they cross RANGE_CAP_MULT, flip the capped flag so
        -- next cycle's effectsFor() returns boosted damage/firerate.
        if not State.auxRangeCapped then
            State.auxRangeMult = (State.auxRangeMult or 1.0) * (1 + COMMON_RANGE_DELTA)
            if State.auxRangeMult >= RANGE_CAP_MULT then
                State.auxRangeCapped = true
            end
        end
        if not State.coreRangeCapped then
            State.coreRangeMult = (State.coreRangeMult or 1.0) * (1 + COMMON_RANGE_DELTA)
            if State.coreRangeMult >= RANGE_CAP_MULT then
                State.coreRangeCapped = true
            end
        end

        -- (silenced wave-cycle upgrade trace — was 10× per run × 81 runs of log spam)
        local _ = touched
    end

    ------------------------------------------------------------
    -- Spawner loop. Cycles through the 3 test types every 3 waves,
    -- ramping RunDifficultyMult each wave. Stops when State.active
    -- flips false (heart death / manual exit).
    ------------------------------------------------------------
    local function spawnWave(testType: string, wave: number)
        local fn = TEST_TYPES[testType]
        if not fn then return end
        local wctx = waveCtx()
        if not wctx then
            warn("[Infinite] WaveCtxBridge.ctx is nil — wave system not ready?")
            return
        end
        local groups = fn(wave)
        local waypoints = wctx.getWaypoints()
        if not waypoints or #waypoints == 0 then
            warn("[Infinite] no waypoints — map 4 not active?")
            return
        end
        -- Track the SET of mobs spawned this wave with their starting
        -- HP. Used to be the input to exit()'s damage-pool ratio
        -- formula; that's gone (timeFrac × overkillMult now). Kept
        -- around for potential future diagnostics — costs ~5 KB
        -- per wave and is cheap insurance.
        State.waveMobs = {}
        for _, group in ipairs(groups) do
            local hpMult = group.hpMult or 1.0
            for _ = 1, group.count do
                if not State.active then return end
                local mob = wctx.makeMob(group.mobType, waypoints, hpMult)
                if mob then
                    mob:SetAttribute("MapId", 4)
                    -- Wave-attribution tags. exit() reads these to
                    -- score deaths against the KILLING MOB's wave
                    -- (not State.wave, which can be a wave ahead if
                    -- a previous-wave straggler reaches the heart
                    -- after the next wave already spawned). Per
                    -- Matthew 2026-04-27: "tag every mob with
                    -- InfiniteWave + WaveStartedAt at spawn." Avoids
                    -- the 6.00-6.05 cluster bug where Combined-tank
                    -- stragglers killed the heart at start of Solo
                    -- and got attributed to Solo with timeFrac ≈ 0.
                    mob:SetAttribute("InfiniteWave", State.wave)
                    mob:SetAttribute("InfiniteWaveStartedAt", State.waveStartedAt or os.clock())
                    mob:SetAttribute("InfiniteWaveDuration", State.waveExpectedDuration or 1)
                    State.mobsSpawnedThisWave = (State.mobsSpawnedThisWave or 0) + 1
                    State.waveMobs[mob] = mob:GetAttribute("Health") or 1
                end
                -- Tiny stagger between mobs in a group so they don't
                -- spawn in the exact same frame. SCALED BY gameSpeed
                -- per Matthew 2026-04-27: at 400× the wallclock 0.08 s
                -- gap was 32 game-seconds between spawns, giving
                -- towers a huge per-mob clear window — loadouts
                -- inflated to wave 23 vs the expected ~13. Now the
                -- gap stays at 0.08 game-seconds regardless of speed,
                -- so spawn cadence matches what real-time players
                -- would experience.
                local speed = math.max(1, Workspace:GetAttribute("GameSpeed") or 1)
                task.wait(0.08 / speed)
            end
        end
    end

    local function startSpawnerLoop(myToken: number)
        task.spawn(function()
            local diff = (Config.Map4 and Config.Map4.Difficulty) or {}
            local intervalSec = diff.IntervalSec or 8
            -- AUTO RUN: skip the 5s pre-wave countdown so the sweep
            -- doesn't spend ~6 minutes on countdowns alone (5s × 73
            -- runs). Setting skipCountdown=true makes the loop below
            -- break immediately on first iteration.
            if autoRun.active then
                State.skipCountdown = true
            end
            -- AUTO RUN placement-detect: poll the Map 4 tower count
            -- until it stops increasing (placement burst settled),
            -- then proceed. Per Matthew 2026-04-26: "lower the time
            -- between auto run sections... just wait until all
            -- towers are placed then start." Replaces the prior
            -- wall-clock pause that scaled with speed.
            --
            -- Stable-for window = 0.3s (auto-place fires PlaceTower
            -- in tight burst client-side; once count stops climbing
            -- for 300ms the burst is done). Hard cap = 4s in case
            -- something blocks placement, so the sweep doesn't hang.
            if autoRun.active then
                local map4ColOffset = ctx.MAP4_COL_OFFSET or 225
                local function countMap4Towers()
                    local n = 0
                    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                        local model = base.Parent
                        if model and (model:GetAttribute("AnchorCol") or -1) >= map4ColOffset then
                            n = n + 1
                        end
                    end
                    return n
                end
                local lastCount, stableSince = 0, os.clock()
                local hardCap = os.clock() + 4
                while State.active and State.spawnerToken == myToken do
                    if os.clock() > hardCap then break end
                    local n = countMap4Towers()
                    if n > lastCount then
                        lastCount = n
                        stableSince = os.clock()
                    elseif n > 0 and (os.clock() - stableSince) > 0.3 then
                        break  -- placements stable; proceed
                    end
                    task.wait(0.1)
                end
                if not State.active or State.spawnerToken ~= myToken then return end
            end
            -- 5-second pre-wave countdown so the player has time to read
            -- the auto-place layout + pause if they want to inspect a
            -- tower before mobs start hitting. Click the countdown
            -- overlay to skip (sets State.skipCountdown via remote).
            for n = 5, 1, -1 do
                if not State.active or State.spawnerToken ~= myToken then return end
                if State.skipCountdown then break end
                if State.activePlayer then
                    countdownRemote:FireClient(State.activePlayer, { countdown = n })
                end
                GameTime.adaptiveWait(1, function()
                    return State.active and State.spawnerToken == myToken
                       and not State.skipCountdown
                end)
            end
            -- Fire 0 to clear the countdown overlay client-side just before wave 1.
            if State.activePlayer then
                countdownRemote:FireClient(State.activePlayer, { countdown = 0 })
            end
            while State.active and State.spawnerToken == myToken do
                -- (HP-pool rolling window removed 2026-04-27 — exit()
                -- now uses timeFrac × overkillMult instead. State.waveMobs
                -- is still populated by spawnWave for any future
                -- diagnostics but is no longer read at run-end.)

                State.wave = State.wave + 1
                State.waveStartedAt = os.clock()
                State.mobsSpawnedThisWave = 0
                -- AUTO RUN cap: if a loadout survives MAX_AUTO_RUN_WAVE
                -- waves it's strong enough to S-tier; cap the result
                -- and let exit() advance the queue. Without this, a
                -- broken combo could stall the sweep indefinitely.
                if autoRun.active and State.wave > MAX_AUTO_RUN_WAVE then
                    print(("[Infinite] AUTO RUN: loadout exceeded wave %d cap — capping + advancing")
                        :format(MAX_AUTO_RUN_WAVE))
                    State.wave = MAX_AUTO_RUN_WAVE
                    if State.activePlayer then
                        -- exit() runs in this coroutine's context; it
                        -- bumps spawnerToken so this while loop ends
                        -- naturally on the next predicate check.
                        task.spawn(function()
                            local p = State.activePlayer
                            if p then exit(p) end
                        end)
                    end
                    return
                end
                local testType = testTypeForWave(State.wave)
                -- Stash the expected duration of THIS wave so exit()
                -- can compute timeFrac = elapsed / expected. Captured
                -- AFTER testType resolves (Solo/Combined have a tank
                -- → tank-speed denom; AOE has basics only → basic-
                -- speed denom).
                State.waveExpectedDuration = waveExpectedDuration(testType)
                -- Set the run-difficulty multiplier BEFORE spawning so
                -- MobFactory.makeMob picks it up (mob HP ramps per wave).
                -- Compounds:
                --   1. slider's starting difficulty
                --   2. per-wave geometric ramp (hpPerRound)
                --   3. per-sequence step bonus — every completed
                --      AOE/Mixed/Boss trio adds a SEQUENCE_HP_BONUS
                --      multiplier on top, so sequence transitions
                --      feel like meaningful difficulty steps. Per
                --      Matthew 2026-04-26: "increase hp ramp in
                --      between the sequences for mobs."
                -- Cycle-based scaling. Step softened from 0.4 → 0.2
                -- per Matthew 2026-04-26: "the hp numbers are way
                -- too high." At step 0.4 a strong solo loadout
                -- reached W19-20 with mob HPs ≈ 2,267-7,083, which
                -- read as trio-tier numbers visually. Step 0.2
                -- halves the ramp:
                --   C1 (W1-3)   = 1.0
                --   C2 (W4-6)   = 1.2
                --   C3 (W7-9)   = 1.4
                --   C4 (W10-12) = 1.6
                --   C5 (W13-15) = 1.8
                --   C6 (W16-18) = 2.0
                --   C7 (W19-21) = 2.2
                --
                -- loadoutMult bakes solo/duo/trio difficulty into a
                -- flat multiplier on top:
                --   solo (1 aux)  = 1.00
                --   duo  (2 aux)  = 1.25
                --   trio (3 aux)  = 1.60
                -- (Set in enter() as State.startingDifficulty.)
                --
                -- Final HP per mob = baseHp × hpMult × cycleMult ×
                --   loadoutMult.
                --
                -- 2026-04-27: cycleMult now resolves through
                -- _IA.WaveHpRamp (piecewise function in Config)
                -- instead of the legacy `1 + (cycle-1) × CycleStep`
                -- formula. Same single-source-of-truth applies in
                -- the simulator. CYCLE_STEP is retained only as a
                -- legacy constant for the simulator's upgrade
                -- counter (cycle = ceil(wave/3), upgrades = cycle-1).
                local cycleMult   = _IA.WaveHpRamp(State.wave)
                local loadoutMult = State.startingDifficulty or 1.0
                Workspace:SetAttribute("RunDifficultyMult", cycleMult * loadoutMult)
                if State.activePlayer then
                    roundRemote:FireClient(State.activePlayer, {
                        wave     = State.wave,
                        testType = testType,
                    })
                end
                -- (silenced per-wave trace — was 30 × 81 = 2400+ lines per sweep)
                spawnWave(testType, State.wave)
                if not State.active or State.spawnerToken ~= myToken then break end
                -- Smart inter-wave wait. Default cap = intervalSec, but
                -- BOSS waves (wave % 3 == 0 = Solo single tank) get an
                -- effectively unbounded wait — the next wave is AOE,
                -- and the user doesn't want a fresh AOE swarm spawning
                -- while the boss is still alive. Per Matthew 2026-04-26:
                -- "when auto running, do not start the next aoe wave
                -- until the boss wave is cleared." 600s is a sentinel
                -- for "wait until they're all dead" — if a boss takes
                -- 10 minutes the run is broken anyway and the heart-
                -- death listener / wave cap will end it cleanly.
                --
                -- For non-boss waves we keep the intervalSec cap so a
                -- weak loadout doesn't get an unfair grace period; the
                -- cap matches the original cadence used for AOE→Combined
                -- and Combined→Boss transitions.
                local isBossWave = (State.wave % 3 == 0)
                local waitCap = isBossWave and 600 or intervalSec
                local waveEndMin = os.clock() + 1
                GameTime.adaptiveWait(waitCap, function()
                    if not State.active or State.spawnerToken ~= myToken then
                        return false  -- abort
                    end
                    if os.clock() < waveEndMin then return true end  -- below min gap, keep waiting
                    local wctx = waveCtx()
                    if not wctx or not wctx.activeMobs then return true end
                    -- If activeMobs has any entry, keep waiting; once
                    -- it's empty, abort the wait and proceed to next wave.
                    for _ in pairs(wctx.activeMobs) do
                        return true  -- at least one mob alive
                    end
                    return false  -- all dead, advance
                end)
                -- Auto-upgrade after every Boss wave (wave % 3 == 0).
                -- The 3-wave sequence ran cleanly (mobs cleared above);
                -- now stamp 6 common-mean cards onto every tower
                -- (damage / firerate / range × aux + core). Range
                -- caps at 2× base, then damage + firerate get a 1.5×
                -- effect boost. See applyWaveCycleUpgrades for the
                -- exact math.
                if State.active and State.spawnerToken == myToken
                   and State.wave % 3 == 0 and State.activePlayer then
                    applyWaveCycleUpgrades(State.activePlayer)
                end
                -- Per-transition extra waits, layered on top of
                -- IntervalSec / mob-clear wait. Per Matthew 2026-04-27:
                -- "add 3 more seconds between aoe and combined wave
                -- and 5 more seconds between combined and boss wave."
                --   AOE → Combined  : Config.PreCombinedExtraSec (3s)
                --   Combined → Boss : Config.PreBossExtraSec     (13s)
                -- Wave numbering: wave % 3 → 1=AOE, 2=Combined, 0=Solo/Boss.
                -- So next wave = (State.wave + 1) and we key on
                -- (next % 3): 2 = Combined, 0 = Boss.
                local nextWave = State.wave + 1
                local nextMod  = nextWave % 3
                local extra = 0
                if nextMod == 2 then        -- next is Combined
                    extra = (diff and diff.PreCombinedExtraSec) or 0
                elseif nextMod == 0 then    -- next is Solo/Boss
                    extra = (diff and diff.PreBossExtraSec) or 0
                end
                if State.active and State.spawnerToken == myToken
                   and extra > 0 then
                    GameTime.adaptiveWait(extra, function()
                        return State.active and State.spawnerToken == myToken
                    end)
                end
            end
        end)
    end

    -- Tear down every tower the player placed on Map 4. Identified by
    -- AnchorCol >= MAP4_COL_OFFSET (everything map-4-side; Map4 cols
    -- start at 225 = ctx.MAP4_COL_OFFSET). Without this, exiting and
    -- re-entering the dimension stacks towers from prior runs on top
    -- of the auto-place pattern, which is bad for stat capture and
    -- visual sanity.
    -- Assigned to forward-declared local at the top of setup() so
    -- the STOP NOW remote handler (registered earlier in setup)
    -- can reach this via captured upvalue.
    function destroyMap4Towers(player: Player)
        local map4ColOffset = ctx.MAP4_COL_OFFSET or 225
        local gridState = ctx.gridState
        local destroyed = 0
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local model = base.Parent
            if model and model:IsA("Model") then
                local owner = model:GetAttribute("Owner")
                local anchorCol = model:GetAttribute("AnchorCol") or -1
                if owner == player.UserId and anchorCol >= map4ColOffset then
                    -- Free the grid cells this tower occupied BEFORE
                    -- destroying the model. Without this, gridState
                    -- stays marked "occupied" and the next round's
                    -- auto-place can't reuse the cells (root cause
                    -- of "AUTO RUN auto-place stops working after
                    -- round 1" — Matthew 2026-04-26 playtest). Same
                    -- pattern as the SellTower path in
                    -- TowerPlacement.lua.
                    if gridState then
                        local anchorRow = model:GetAttribute("AnchorRow") or 0
                        local fw = model:GetAttribute("FootprintW") or 0
                        local fd = model:GetAttribute("FootprintD") or 0
                        for dc = 0, fw - 1 do
                            for dr = 0, fd - 1 do
                                local c, r = anchorCol + dc, anchorRow + dr
                                if gridState[c] and gridState[c][r] == "occupied" then
                                    gridState[c][r] = "open"
                                end
                            end
                        end
                    end
                    model:Destroy()
                    destroyed = destroyed + 1
                end
            end
        end
        -- Broadcast the freshly-cleared grid so the client's localGrid
        -- matches server reality before the next auto-place fits()
        -- check runs (otherwise client sees old "occupied" state and
        -- auto-place's fits() returns false).
        if destroyed > 0 and ctx.broadcastGrid then
            ctx.broadcastGrid()
        end
        -- (silenced destroyMap4Towers trace — fires per-loadout
        -- transition during AUTO RUN, log spam.)
        local _ = destroyed
    end

    -- Assigned to forward-declared local at the top of setup() so
    -- the STOP NOW remote handler can reach it.
    function stopSpawner()
        State.active = false
        State.spawnerToken = State.spawnerToken + 1
        -- Clear the manual-run signal so the InfiniteButtonBar can
        -- morph STOP back to LOADOUT. Safe to clear even on AUTO
        -- RUN paths — the attribute was only set true for manual.
        if Workspace:GetAttribute("InfiniteManualRunActive") then
            Workspace:SetAttribute("InfiniteManualRunActive", false)
        end
        if State.heartConn then
            State.heartConn:Disconnect()
            State.heartConn = nil
        end
        Workspace:SetAttribute("RunDifficultyMult", 1.0)
        local wctx = waveCtx()
        if wctx and wctx.clearAllMobs then wctx.clearAllMobs() end
    end

    -- exit() is the canonical run-end path. Called from:
    --   - heart-death listener (hookHeartDeath)
    --   - return portal Touched
    --   - admin RUN RESET (forceExitRemote)
    --   - PlayerRemoving (only does the teardown half)
    --   - AUTO RUN wave cap (when a loadout exceeds MAX_AUTO_RUN_WAVE)
    --
    -- AUTO RUN flow: when autoRun.active, this captures the run's
    -- finalWave instead of returning to hub, then either dequeues
    -- the next loadout (recursive enter()) or finalizes the sweep.
    -- Assigned to the forward-declared local `exit` so other
    -- functions defined earlier (startSpawnerLoop) can reference it.
    exit = function(player: Player)
        if not player or not player.Parent then return end

        -- Capture this run's outcome BEFORE teardown. AUTO RUN path
        -- stores the finalWave + label + per-tower stat summary so
        -- assembleTiers can rank towers afterward AND the admin
        -- panel's per-run drilldown has data. Standard runs print
        -- the StatLedger summary to the server log.
        --
        -- finalWave is FRACTIONAL: integer wave + timeFrac ×
        -- overkillMult (full formula below). The fraction part is
        -- clamped to [0, 1]. Per Matthew 2026-04-26: "add fractional
        -- round completion depending on time alive past wave spawn."
        local statSummary = StatLedger.summary()
        -- Structured snapshot — used by Balance Studio admin panel
        -- to bucket per-tower damage by mob type across runs. Per
        -- Matthew 2026-04-27: "what % of overall damage to aoe
        -- mobs does it do? what about boss mobs? tank? fast?"
        -- snapshot.towers[id].damageByMobType is the raw bucket;
        -- snapshot.towers[id].type is the tower-type name we key
        -- by when aggregating across runs.
        local statSnapshot = StatLedger.snapshot()
        lastRunStats = statSummary  -- in-session cache for admin panel
        -- Partial-wave-clear formula (Matthew 2026-04-27, current):
        --   fractionalWave = wave + timeFrac × overkillMult
        --
        --   timeFrac     = clamp((now - waveStartedAt) / waveDuration, 0, 1)
        --   overkillMult = heartMaxHp / (heartMaxHp + overkill)
        --
        -- Replaces the earlier HP-ratio rolling-3-wave window
        -- (damage/pool over last 3 waves). Rationale:
        --   • Solo waves used to score binary (1 tank alive = 0,
        --     1 tank dead = 100%) — timeFrac gives clean gradient.
        --   • Overkill becomes a multiplier: a near-tie death scores
        --     close to its raw timeFrac, a wildly-overscaled boss
        --     death gets its fraction shrunk proportionally.
        --   • heartMaxHp normalizes the overkill term so 10k overkill
        --     on a 50k heart = 0.833 mult (~17% haircut); 50k overkill
        --     = 0.5 mult. Asymptotes toward 0, never negative.
        --
        -- REMAINING-WAVE THREAT (Matthew 2026-04-27): when the heart
        -- dies, ANY mobs still alive on the path represent un-absorbed
        -- threat. A small fast-mob killing the heart while the tank
        -- (boss) is still walking is a much WORSE outcome than the
        -- killing-blow's overkill alone would suggest — the tank has
        -- thousands of HP that the towers never had to deal with.
        -- Sum every active mob's current HP into the overkill term so
        -- the denominator reflects total un-absorbed wave threat,
        -- not just the killing blow's overshoot.
        -- Wave-attribution: use the KILLING MOB's wave-of-origin
        -- instead of State.wave when available. Per Matthew 2026-04-27:
        -- at the inter-wave cap (12 game-sec) Combined-wave tanks
        -- often straggle into the next Solo wave and finish off the
        -- heart there → State.wave reads "6" but the killing mob is
        -- from wave 5. Without this, every Combined→Solo straggler
        -- death clustered at wave 6.0X with timeFrac ≈ 0 (boss only
        -- spawned ~3 game-sec earlier). Now the failure scores
        -- against wave 5's expected duration → the straggler tank
        -- is correctly read as "wave 5 lasted ~71 game-seconds (full
        -- duration), then the heart fell."
        local effectiveWave     = State.killingMobWave or State.wave
        local effectiveStart    = State.killingMobWaveStartedAt or State.waveStartedAt
        local effectiveDuration = State.killingMobWaveDuration or State.waveExpectedDuration
        local fractionalWave    = effectiveWave or State.wave
        if (effectiveWave or 0) > 0 then
            -- elapsed is WALLCLOCK seconds since the (effective) wave
            -- started; convert to GAME-SECONDS by multiplying by
            -- current GameSpeed. Speed is locked across an auto-run
            -- sweep so wallclock × current-speed = accurate elapsed.
            local elapsedWall = math.max(0, os.clock() - (effectiveStart or os.clock()))
            local elapsed     = elapsedWall * GameTime.speed()
            local duration    = effectiveDuration or 1
            if duration <= 0 then duration = 1 end
            local timeFrac = math.clamp(elapsed / duration, 0, 1)
            local heartMaxHp = (ctx.map4Heart and ctx.map4Heart:GetAttribute("MaxHealth"))
                or (Config.Map4 and Config.Map4.HeartMaxHp) or 50000
            local overkill = math.max(0, State.heartOverkill or 0)
            -- Add HP of every mob still alive — they represent threat
            -- the towers never absorbed (the killing-blow mob is
            -- already destroyed in MobUpdate before exit() runs, so
            -- it won't double-count here).
            do
                local wctxForMobs = waveCtx()
                if wctxForMobs and wctxForMobs.activeMobs then
                    for mob in pairs(wctxForMobs.activeMobs) do
                        if mob and mob.Parent then
                            local hp = mob:GetAttribute("Health") or 0
                            if type(hp) == "number" and hp > 0 then
                                overkill = overkill + hp
                            end
                        end
                    end
                end
            end
            local overkillMult = heartMaxHp / (heartMaxHp + overkill)
            fractionalWave = effectiveWave + timeFrac * overkillMult
        end
        -- Use effectiveWave (killing mob's wave-of-origin) for the
        -- testType label so the log + persisted result match the
        -- score's actual attribution. State.wave can be one wave
        -- ahead when a previous-wave straggler finishes the heart.
        local logWave = effectiveWave or State.wave
        local logTestType = displayTestType(testTypeForWave(logWave))
        if autoRun.active and autoRun.current then
            local result = {
                auxIds         = autoRun.current.auxIds,
                label          = autoRun.current.label,
                finalWave      = fractionalWave,
                testType       = logTestType,  -- "Boss" for Solo waves
                statSummary    = statSummary,
                -- Structured per-tower snapshot for damage-by-mob-type
                -- aggregation in the Balance Studio admin panel. Old
                -- cumulative-pool entries (pre-2026-04-27) won't have
                -- this — admin panel handles nil gracefully.
                statSnapshot   = statSnapshot,
                -- Stamp the active balance era so LOAD RUNS can
                -- group sweeps + cumulative results by version.
                balanceVersion = currentBalanceVersion,
                -- Stamp the Core archetype this loadout used so the
                -- admin panel's Core-filter toggles can include /
                -- exclude runs by Core. Older results without this
                -- field can fall back to parsing label prefix
                -- ("Power + ..." → coreId="Power"). Per Matthew
                -- 2026-04-27.
                coreId         = autoRun.coreId or State.coreId or "Power",
            }
            table.insert(autoRun.results, result)
            print(("[Infinite] AUTO RUN  %d/%d  %s  →  failed at wave %.2f (%s)"):format(
                #autoRun.results, autoRun.total,
                autoRun.current.label, fractionalWave, logTestType))
            -- 2026-04-29 ea: SUPER AUTO crash-recovery checkpoint.
            -- Every 50 completed runs, flush the unflushed window to
            -- the cumulative pool and persist to DataStore so a server
            -- crash mid-sweep doesn't lose hours of stats. Per Matthew
            -- 2026-04-29: "have super autorun write results every 50
            -- waves in case of crash." (NB: in this branch each
            -- "result" is one full Infinite run that climbs up to
            -- MaxAutoRunWave waves; checkpointing per-50 runs is the
            -- right granularity — within-run wave-by-wave persistence
            -- would thrash DataStore.) finalize()'s cumulative append
            -- below uses cumulativeFlushedIdx to skip already-flushed
            -- entries so we never double-count.
            local CHECKPOINT_EVERY = 50
            if autoRun.isSuperAuto or autoRun.isTowerSuper then
                local flushed = autoRun.cumulativeFlushedIdx or 0
                if #autoRun.results - flushed >= CHECKPOINT_EVERY then
                    for i = flushed + 1, #autoRun.results do
                        table.insert(cumulativeResults, autoRun.results[i])
                    end
                    autoRun.cumulativeFlushedIdx = #autoRun.results
                    InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
                    local mode = autoRun.isTowerSuper and "TOWER SUPER" or "SUPER AUTO"
                    print(("[Infinite] %s checkpoint — flushed %d new results to cumulative pool (%d total) at run %d/%d"):format(
                        mode, #autoRun.results - flushed, #cumulativeResults,
                        #autoRun.results, autoRun.total))
                end
            end
            -- Fire per-run completion to the client so the Monitor
            -- window can update live tower stats + prospective tier
            -- placement after each loadout finishes (rather than
            -- only at sweep end).
            runCompletedRemote:FireClient(player, {
                idx       = #autoRun.results,
                auxIds    = result.auxIds,
                label     = result.label,
                finalWave = result.finalWave,
                testType  = result.testType,
            })
        else
            if (logWave or 0) > 0 then
                print(("[Infinite] -------- run summary -------- failed at wave %.2f (%s)"):format(
                    fractionalWave, logTestType))
            else
                print("[Infinite] -------- run summary -------- (no waves run)")
            end
            print(statSummary)
        end
        StatLedger.reset()
        stopSpawner()
        destroyMap4Towers(player)
        State.activePlayer = nil
        State.wave = 0

        -- AUTO RUN dequeue path: pop next loadout, fire progress to
        -- client HUD, restart in-place WITHOUT the hub teleport.
        -- Player stays in Map 4; spawner gets a fresh spawnerToken
        -- via enter() → State.spawnerToken += 1.
        if autoRun.active and autoRun.queue and #autoRun.queue > 0 then
            local nextLoadout = table.remove(autoRun.queue, 1)
            autoRun.current = nextLoadout
            local progIdx = #autoRun.results + 1
            autoRunProgressRemote:FireClient(player, {
                current = progIdx,
                total   = autoRun.total,
                label   = nextLoadout.label,
            })
            -- Brief gap so the heart-death log + progress message
            -- land before the next run starts; also gives the auto-
            -- place pattern's prior-run state a frame or two to
            -- finish unwinding.
            -- Inter-round delay removed (Matthew 2026-04-26: "lower
            -- the time between auto run sections... just wait until
            -- all towers are placed then start"). The placement
            -- pause inside enter() (1-3s scaled by speed) already
            -- gives towers time to land before wave 1 spawns; the
            -- prior 1.0s was just a "let prior log lines flush"
            -- buffer that adds 73s of dead time per sweep.
            task.spawn(function()
                if not player.Parent then return end
                -- Slider tracks aux count — same lockstep as the
                -- loadout picker (more towers = more difficulty).
                -- 1 aux → 1.25×, 2 aux → 1.5×, 3 aux → 1.75×.
                -- coreId carries the sweep's anchor archetype so
                -- ControlCore / SupportCore sweeps don't silently
                -- fall back to Power inside enter().
                enter(player, {
                    auxIds = nextLoadout.auxIds,
                    slider = #nextLoadout.auxIds,
                    coreId = autoRun.coreId,
                })
            end)
            return
        end

        -- AUTO RUN finalize: queue empty → assemble + emit tier list,
        -- stash the in-session cache, then STAY IN ARENA so the
        -- player can review the live MONITOR window + open the
        -- admin panel for tier-list details. They return to hub
        -- explicitly via the return portal or admin RUN RESET.
        -- Per Matthew 2026-04-26: "it teleported me out at the end
        -- of the auto run. are the stats gone?" — stats are kept
        -- in lastSweep + the autoRunDone payload, but the surprise
        -- teleport meant the player had to walk back to see them.
        if autoRun.active then
            autoRun.active = false
            local tiers = assembleTiers(autoRun.results or {})
            printTierList(tiers)
            -- In-session cache for the admin panel's RUN STATS
            -- section. Survives until server restart (no DataStore
            -- yet — see project_infinite_arena.md step 3 for the
            -- planned persistent layer).
            lastSweep = {
                tiers          = tiers,
                results        = autoRun.results,
                completedAt    = os.time(),
                total          = autoRun.total,
                balanceVersion = currentBalanceVersion,
            }
            -- Append every result to the cumulative pool so the
            -- default admin-panel tier list spans all sweeps since
            -- the last BALANCE RESET. Per Matthew 2026-04-26: "the
            -- run stats + tier lists should be across every run
            -- unless balance reset is hit."
            --
            -- 2026-04-29 ea: SUPER AUTO checkpoints every 50 results
            -- via cumulativeFlushedIdx (see per-result block above).
            -- Skip already-flushed entries here so we don't
            -- double-count them in cumulativeResults.
            local startIdx = (autoRun.cumulativeFlushedIdx or 0) + 1
            for i = startIdx, #autoRun.results do
                table.insert(cumulativeResults, autoRun.results[i])
            end
            -- Persist cumulative pool to DataStore so the tier list
            -- survives server restarts. SaveCumulative trims heavy
            -- statSummary text + caps at MAX_CUMULATIVE_RESULTS.
            InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
            -- Persist this individual sweep to history so LOAD RUN
            -- can pull it back across server restarts. (Trims
            -- statSummary text + caps at MAX_SWEEPS internally.)
            InfiniteRunHistoryStore.append(lastSweep)
            -- autoRunDoneRemote fires ONLY when the sweep is TRULY
            -- terminating (continuous=false). Was firing here on
            -- every sweep finalize regardless — which made the
            -- client's restoreSpeed handler kick in between
            -- sweep #1 and sweep #2 in continuous mode, dropping
            -- 20× back to 1× mid-loop. Per Matthew 2026-04-28 df:
            -- "keep speed at 20x when switching into extended
            -- testing in continuous toggle." Done event moved into
            -- the non-continuous branch below; continuous transition
            -- only fires autoRunProgressRemote so the monitor
            -- updates without the speed restore being triggered.
            -- Continuous-sweep loop: if STOP RUN hasn't been hit,
            -- rebuild the queue and kick off another sweep right
            -- away. Stat recording stays on; cumulative pool keeps
            -- growing.
            --
            -- Sweep #1 (just completed): the broad initial queue
            -- (FULL AUTO / AUTO RUN / SELECT AUTO).
            -- Sweep #2+ (continuous loops): switch to top-combos-
            -- descending mode — focuses the next sweep on the
            -- highest-performing loadouts from the cumulative pool
            -- so we get more samples on what's working instead of
            -- re-grinding the same broad solos+duos. Per Matthew
            -- 2026-04-28 "change auto run monitor > auto mode to
            -- run the most high-value combinations in descending
            -- order when the full auto run completes."
            --
            -- Falls back to the standard AUTO RUN queue if the
            -- cumulative pool is empty (defensive — shouldn't
            -- happen because the just-completed sweep added to it).
            --
            -- 2026-04-29 ea3-24: TOWER SUPER (Core, rarity) queue
            -- progression. Each entry is { coreId, rarity }. Pops
            -- the next tuple, builds a queue filtered to combos
            -- containing autoRun.towerSuperFocusAux at that
            -- (Core, rarity) combination. 15 sub-sweeps total
            -- (3 cores × 5 rarities). When the queue empties, we
            -- fall through to the standard sweep finalize (no
            -- continuous mode for TOWER SUPER — it's a bounded
            -- analysis pass).
            if autoRun.towerSuperRarityCoreQueue and #autoRun.towerSuperRarityCoreQueue > 0 then
                local nextTuple = table.remove(autoRun.towerSuperRarityCoreQueue, 1)
                local nextCore   = nextTuple.coreId
                local nextRarity = nextTuple.rarity
                local focusAux   = autoRun.towerSuperFocusAux
                autoRun.sweepNum = (autoRun.sweepNum or 0) + 1
                autoRun.coreId   = nextCore
                State.preferredRarity = nextRarity  -- so enter() picks it up
                autoRun.active   = true
                autoRun.queue    = buildTowerSuperQueue(nextCore, focusAux)
                autoRun.results  = {}
                autoRun.total    = #autoRun.queue
                autoRun.cumulativeFlushedIdx = 0
                if autoRun.total == 0 then
                    -- Defensive: focus aux missing from the FULL AUTO
                    -- pool for this Core (shouldn't happen). Skip
                    -- this tuple by re-firing finalize — but instead
                    -- of recursing, just print + continue past this
                    -- by rebuilding the autoRun state to drain.
                    warn(("[Infinite] TOWER SUPER skipped %s+%s — no combos for focus aux %s"):format(
                        nextCore, nextRarity, tostring(focusAux)))
                    autoRun.active = false
                    -- Re-enter the same finalize path next tick to pop
                    -- the following tuple. Cheap recursion via task.spawn.
                    task.spawn(function()
                        if not player.Parent then return end
                        -- Trigger another finalize cycle by faking a
                        -- zero-loadout completion. Simplest: directly
                        -- re-pop here by jumping back into the queue
                        -- check. Implementing as an explicit re-entry
                        -- would require restructuring; for the rare
                        -- empty-queue case the user re-fires manually.
                        print("[Infinite] TOWER SUPER: empty queue at this tuple — please re-fire if more sub-sweeps were expected")
                    end)
                    return
                end
                local firstLoadout = table.remove(autoRun.queue, 1)
                autoRun.current = firstLoadout
                autoRunProgressRemote:FireClient(player, {
                    current  = 1,
                    total    = autoRun.total,
                    label    = firstLoadout.label,
                    sweepNum = autoRun.sweepNum,
                })
                print(("[Infinite] TOWER SUPER sweep #%d → %s + %s + focus %s (%d loadouts, %d tuples left)")
                    :format(autoRun.sweepNum, nextCore, nextRarity, focusAux,
                        autoRun.total, #autoRun.towerSuperRarityCoreQueue))
                task.spawn(function()
                    if not player.Parent then return end
                    enter(player, {
                        auxIds = firstLoadout.auxIds,
                        slider = #firstLoadout.auxIds,
                        coreId = nextCore,
                        rarity = nextRarity,
                    })
                end)
                return
            end

            -- 2026-04-29 ea: SUPER AUTO Core-queue progression. If
            -- superAutoCoreQueue has entries, pop the next Core and
            -- start its broad FULL AUTO sweep. After all 3 Cores
            -- are exhausted, fall through to the continuous top-
            -- combos block below (mixed-Core data, top performers
            -- across all 3 anchors).
            if autoRun.superAutoCoreQueue and #autoRun.superAutoCoreQueue > 0 then
                local nextCore = table.remove(autoRun.superAutoCoreQueue, 1)
                autoRun.sweepNum = (autoRun.sweepNum or 0) + 1
                autoRun.coreId = nextCore
                autoRun.active = true
                autoRun.queue = buildAutoRunQueue(nextCore)
                autoRun.results = {}
                autoRun.total = #autoRun.queue
                autoRun.cumulativeFlushedIdx = 0  -- 2026-04-29 ea: reset crash-recovery checkpoint counter for the new sweep
                local firstLoadout = table.remove(autoRun.queue, 1)
                autoRun.current = firstLoadout
                autoRunProgressRemote:FireClient(player, {
                    current  = 1,
                    total    = autoRun.total,
                    label    = firstLoadout.label,
                    sweepNum = autoRun.sweepNum,
                })
                print(("[Infinite] SUPER AUTO sweep #%d → next Core %s (%d loadouts, %d cores left in queue)")
                    :format(autoRun.sweepNum, nextCore, autoRun.total, #autoRun.superAutoCoreQueue))
                task.spawn(function()
                    if not player.Parent then return end
                    enter(player, {
                        auxIds = firstLoadout.auxIds,
                        slider = #firstLoadout.auxIds,
                        coreId = nextCore,
                    })
                end)
                return
            end
            if autoRun.continuous then
                autoRun.sweepNum = (autoRun.sweepNum or 0) + 1
                local newCoreId = autoRun.coreId or "Power"
                local newQueue
                local TOP_COMBOS_PER_LOOP = 100
                if autoRun.sweepNum > 1 and #cumulativeResults > 0 then
                    newQueue = buildTopCombosQueue(newCoreId,
                        cumulativeResults, TOP_COMBOS_PER_LOOP)
                end
                if not newQueue or #newQueue == 0 then
                    newQueue = buildAutoRunQueue(newCoreId)
                end
                autoRun.active  = true
                autoRun.queue   = newQueue
                autoRun.results = {}
                autoRun.total   = #newQueue
                autoRun.cumulativeFlushedIdx = 0  -- 2026-04-29 ea: reset crash-recovery checkpoint counter for the next continuous sweep
                local firstLoadout = table.remove(newQueue, 1)
                autoRun.current = firstLoadout
                autoRunProgressRemote:FireClient(player, {
                    current  = 1,
                    total    = autoRun.total,
                    label    = firstLoadout.label,
                    sweepNum = autoRun.sweepNum,
                })
                local mode = (autoRun.sweepNum > 1 and #cumulativeResults > 0)
                    and "TOP-COMBOS DESC" or "FULL"
                print(("[Infinite] AUTO RUN sweep #%d → starting next continuous sweep (%d loadouts, core=%s, mode=%s)")
                    :format(autoRun.sweepNum, autoRun.total, newCoreId, mode))
                task.spawn(function()
                    if not player.Parent then return end
                    enter(player, {
                        auxIds = firstLoadout.auxIds,
                        slider = #firstLoadout.auxIds,
                        coreId = newCoreId,
                    })
                end)
                return
            end

            -- True termination path: continuous was false (or got
            -- cleared by STOP AT END). Now we fire autoRunDoneRemote
            -- so the client restores speed, hides the STOP toggle,
            -- and the HUD subtitle clears.
            autoRunDoneRemote:FireClient(player, {
                results     = autoRun.results,
                tiers       = tiers,
                completedAt = lastSweep.completedAt,
                total       = autoRun.total,
            })
            StatLedger.setRecordingEnabled(false)
            autoRun.queue      = nil
            autoRun.current    = nil
            autoRun.results    = nil
            autoRun.total      = 0
            autoRun.continuous = false
            autoRun.sweepNum   = 0
            autoRun.superAutoCoreQueue = nil  -- 2026-04-29 ea: clear SUPER AUTO queue
            autoRun.isSuperAuto          = nil
            autoRun.isTowerSuper         = nil  -- 2026-04-29 ea3-24: clear TOWER SUPER state
            autoRun.towerSuperRarityCoreQueue = nil
            autoRun.towerSuperFocusAux   = nil
            autoRun.cumulativeFlushedIdx = nil
            print(("[Infinite] AUTO RUN sweep complete — %s remains in swamp idle to review stats"):format(player.Name))
            return  -- skip hub-return; player stays in arena idle
        end

        -- Restore StageState to map 1 (hub default) so the wave system's
        -- getHeart / getWaypoints stop resolving to Map4. Fire SwitchMap
        -- with noAutoWaves so we don't kick off a wave on map 1 either.
        local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        if switchMapBindable then
            switchMapBindable:Fire({
                mapId = 1,
                mapName = "Crook of the Tree",
                noAutoWaves = true,
            })
        end
        exitRemote:FireClient(player, {
            fadeOutSec = EXIT_FADE_OUT_SEC,
            holdSec    = 0.3,
            fadeInSec  = 0.6,
        })
        task.delay(EXIT_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getHubSpawnCF())
            player:SetAttribute("InfiniteInArena", false)
            -- Clear Equipped flags on hub return so the regular
            -- Map 1-3 hotbar logic takes over (legacy fallback in
            -- buildHotbar). Without this, every aux tower would
            -- stay marked Equipped=false and stay hidden during
            -- regular runs even after a boss-reward grant.
            for towerId in pairs(TempTowers.Templates) do
                player:SetAttribute(towerId .. "Equipped", nil)
            end
            player:SetAttribute("PowerEquipped", nil)
        end)
        print(("[Infinite] %s returned to hub"):format(player.Name))
    end

    local function hookHeartDeath()
        if State.heartConn then State.heartConn:Disconnect() end
        local heart = ctx.map4Heart
        if not heart then return end
        State.heartConn = heart:GetAttributeChangedSignal("Health"):Connect(function()
            if not State.active then return end
            local hp = heart:GetAttribute("Health") or 0
            if hp <= 0 and State.activePlayer then
                exit(State.activePlayer)
            end
        end)
    end

    -- enterIdle — drop the player into Map 4 with NO countdown / NO
    -- spawner / NO loadout grant. Used by the hub portal Touched +
    -- ProximityPrompt + dev-teleport "infinite" target. Player
    -- arrives in the swamp and can roam freely; the LOADOUT or AUTO
    -- RUN buttons trigger the actual run. Per Matthew 2026-04-26:
    -- "don't start the countdown until a loadout is selected or
    -- autorun is started".
    enterIdle = function(player: Player)
        if not player or not player.Parent then return end
        -- Position-check: if the InfiniteInArena attribute claims
        -- the player is in the swamp BUT they're actually back in
        -- the hub (DevReset respawned them, character died and
        -- respawned at SpawnLocation, etc.), the attribute is stale.
        -- Force the teleport instead of no-op'ing. Without this,
        -- post-reset portal touches were silent — see Matthew
        -- 2026-04-26: "after reset port to swamp is broken".
        if player:GetAttribute("InfiniteInArena") == true then
            local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            local mapCenterX = (ctx.MAP4_CENTER and ctx.MAP4_CENTER.X) or 8000
            if hrp and math.abs(hrp.Position.X - mapCenterX) < 200 then
                -- Truly in the arena — no-op so re-touching the
                -- disc doesn't replay the cinematic over an
                -- existing presence.
                return
            end
            -- Stale attribute; clear and fall through to re-entry.
            print(("[Infinite] %s has stale InfiniteInArena flag — clearing + re-entering"):format(player.Name))
            player:SetAttribute("InfiniteInArena", false)
        end

        -- Switch wave system to Map 4 stage state (no auto waves).
        local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        if switchMapBindable then
            switchMapBindable:Fire({
                mapId = 4,
                mapName = "Pickle Swamp",
                noAutoWaves = true,
            })
        else
            warn("[Infinite] SwitchMap bindable missing — wave system not booted yet?")
        end

        -- Heart full HP (prior runs may have damaged it).
        if ctx.map4Heart then
            local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
            ctx.map4Heart:SetAttribute("Health", maxHp)
        end

        -- ea3-117: return portal removed per Matthew 2026-04-30. The
        -- in-world "RETURN TO HUB" billboard had been showing during
        -- every Pickle Swamp visit (story + sweep + idle) and was the
        -- ghost text I'd misattributed to GameOverBanner all session.
        -- Players exit via DevReset / RUN RESET / SIMULATE menu paths
        -- now; no in-world portal needed in the Infinite arena.
        -- setupReturnPortal function kept (unused) until a follow-up
        -- cleanup pass — selene allow_unused_function isn't enabled
        -- so the function will start emitting warnings; remove the
        -- function block in the next commit if no other caller picks
        -- it up.

        enterRemote:FireClient(player, {
            fadeOutSec = ENTRY_FADE_OUT_SEC,
            holdSec    = 0.4,
            fadeInSec  = 0.8,
        })
        task.delay(ENTRY_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getMap4SpawnCF())
            player:SetAttribute("InfiniteInArena", true)
            -- Idle state: zero stocks AND mark every tower
            -- Equipped=false so the hotbar is empty until a loadout
            -- is selected. The wave system's SwitchMap handler
            -- grants PowerStock=1 on map switch (carry-over logic
            -- meant for Map 1→2/3); the Equipped=false override
            -- keeps Power off the hotbar until the player explicitly
            -- picks a loadout via the LOADOUT button or AUTO RUN.
            for towerId in pairs(TempTowers.Templates) do
                player:SetAttribute(towerId .. "Stock", 0)
                player:SetAttribute(towerId .. "Equipped", false)
            end
            for _, coreId in ipairs(CoreTypes.Ids) do
                player:SetAttribute(coreId .. "Stock", 0)
                player:SetAttribute(coreId .. "Equipped", false)
            end
            -- Auto-equip the player's saved Core (Matthew 2026-04-28:
            -- "auto equip and select last core tower used on porting
            -- to infinite"). Hotbar shows just the Core slot until
            -- the player picks a loadout / hits AUTO RUN. State.
            -- preferredCoreId is hydrated from DataStore on PlayerAdded.
            local prefCore = State.preferredCoreId
                             or player:GetAttribute("PreferredCoreId")
                             or "Power"
            player:SetAttribute(prefCore .. "Stock", 1)
            player:SetAttribute(prefCore .. "Equipped", true)
            player:SetAttribute("HasBeenGrantedStock", true)
        end)
        print(("[Infinite] %s entered the pickle dimension (idle — pick LOADOUT or AUTO RUN to start)")
            :format(player.Name))
    end

    -- enterPrepare — SAVE flow. Routes the player into the arena
    -- (if needed), grants stock for the picked loadout, and STOPS
    -- THERE: no spawner start, no auto-place. The player can then
    -- manually place towers; pressing GO from the picker fires a
    -- second pickRemote with phase="go" which lands in enter()
    -- below.
    --
    -- Per Matthew 2026-04-27: "SAVE on LOADOUT should not start.
    -- it saves the loadout and allows placement. GO starts the
    -- waves and autoplaces any towers not place."
    --
    -- Mid-run SAVE: if a run is active, stop the spawner + clear
    -- towers in-place (mirror of enter's mid-run-restart branch)
    -- so the player can re-pick a loadout, place fresh, then GO.
    enterPrepare = function(player: Player, opts: { auxIds: { string }?, coreId: string?, rarity: string? }?)
        if not player or not player.Parent then return end
        opts = opts or {}
        if player:GetAttribute("InfiniteInArena") ~= true then
            enterIdle(player)
            task.wait(ENTRY_FADE_OUT_SEC * 0.6 + 0.2)
            if not player.Parent then return end
        end
        -- Mid-run re-prepare: tear down active run cleanly so the
        -- new loadout's grants land on a fresh slate. Heart goes
        -- back to full so the placement test can use the heart's
        -- HP as a placement-feedback signal if needed.
        if State.active and State.activePlayer == player then
            print(("[Infinite] %s SAVE during active run — stopping spawner + clearing towers")
                :format(player.Name))
            stopSpawner()
            destroyMap4Towers(player)
            State.active        = false
            State.activePlayer  = nil
            State.wave          = 0
            State.heartOverkill = 0
            State.killingMobWave          = nil
            State.killingMobWaveStartedAt = nil
            State.killingMobWaveDuration  = nil
            if ctx.map4Heart then
                local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
                ctx.map4Heart:SetAttribute("Health", maxHp)
            end
        end
        local auxIds = opts.auxIds  -- may be nil
        local coreId = opts.coreId or "Power"
        local rarity = opts.rarity  -- 2026-04-29 ea3-8 (loadout-picker rarity tier)
        -- Stash the picked Core for the eventual GO call (enter()
        -- reads State.coreId for the auto-place pattern). Same
        -- field enter() sets, just one phase earlier.
        State.coreId = coreId
        State.rarity = rarity
        grantLoadout(player, auxIds, coreId, rarity)
        -- Mark the SAVE so the next GO (enter() call without
        -- AUTO RUN active) skips the re-grant and preserves any
        -- manually-placed towers. Cleared in enter() below.
        State.savePending = true
        print(("[Infinite] %s SAVED loadout (core=%s, aux=%d, rarity=%s) — placement enabled, waves NOT started")
            :format(player.Name, coreId, auxIds and #auxIds or 0, tostring(rarity or "Common")))
    end

    -- enter — assigned to the forward-declared local `enter` so
    -- exit() can recurse into the next AUTO RUN loadout. Assumes
    -- the player is already in Map 4 (via enterIdle); this just
    -- starts the run state + spawner. If somehow called when the
    -- player isn't in the arena, auto-routes through enterIdle
    -- and waits a beat for the cinematic to settle.
    enter = function(player: Player, opts: { auxIds: { string }?, slider: number?, coreId: string? }?)
        -- opts comes from the loadout panel's PickInfiniteScenario
        -- payload OR is nil for dev-quick-entry / fallback paths.
        --   auxIds = list of TempTowers IDs to grant stock for; nil
        --            means "grant ALL aux at template stock counts"
        --            (dev shortcut so the auto-place pattern fills
        --            every role slot for visual debugging).
        --   slider = 0..4, sets RunDifficultyMult start value via
        --            (1.0 + slider × 0.25) so slider 0 = 1.0×,
        --            slider 4 = 2.0×. Spawner ramp compounds on top.
        if not player or not player.Parent then return end

        -- Auto-route through enterIdle if not yet in the arena.
        -- Then wait for the cinematic teleport to settle so the
        -- run-start grant + spawner doesn't race the fade.
        if player:GetAttribute("InfiniteInArena") ~= true then
            enterIdle(player)
            task.wait(ENTRY_FADE_OUT_SEC * 0.6 + 0.2)
            if not player.Parent then return end
        end

        if State.active then
            -- Mid-run re-pick (loadout button → START while a run is
            -- active): stop the current spawner + clear towers/mobs
            -- in-place, then fall through to start a fresh run with
            -- the new loadout. Player stays in Map4 — no cinematic.
            if State.activePlayer == player then
                print(("[Infinite] %s re-picked loadout mid-run — restarting"):format(player.Name))
                stopSpawner()
                destroyMap4Towers(player)
                State.activePlayer = nil
                State.wave = 0
            else
                warn(("[Infinite] %s tried to enter while another run was active"):format(player.Name))
                return
            end
        end
        opts = opts or {}
        local auxIds = opts.auxIds  -- may be nil
        local coreId = opts.coreId or "Power"  -- Stage 1 default: DPS core
        -- 2026-04-29 ea3-8 rarity tier — fall back to the player's last
        -- saved preference (or "Common" if never set) so AUTO RUN sweep
        -- dequeues that don't carry a rarity in their opts inherit the
        -- loadout-picker selection.
        opts.rarity = opts.rarity
                      or State.preferredRarity
                      or (player and player:GetAttribute("PreferredRarity"))
                      or "Common"
        -- 2026-04-29 ea3-8: slot range expanded 0..4 → 0..5 to support
        -- the new 4-tower-lock + every-aux-rotation SELECT AUTO mode.
        local sliderValue = math.clamp(opts.slider or 3, 0, 5)
        -- Slider → starting-difficulty (loadoutMult). Pulls from
        -- Config.InfiniteArena.LoadoutMult[N]; out-of-range slider
        -- values fall through to the linear-extrapolation formula
        -- (1.0 + slider × 0.25) that the dev-only sliders 0/4 use.
        local startingDifficulty = _IA.LoadoutMult[sliderValue]
        if not startingDifficulty then
            startingDifficulty = 1.0 + sliderValue * 0.25
        end

        State.active        = true
        State.activePlayer  = player
        State.wave          = 0
        State.spawnerToken  = State.spawnerToken + 1
        State.skipCountdown = false
        -- Workspace signal for the InfiniteButtonBar's STOP morph.
        -- True only for MANUAL runs (not AUTO RUN sweeps); the
        -- autoRun.active branch sets its own monitor instead.
        -- Per Matthew 2026-04-27 STOP button spec.
        Workspace:SetAttribute("InfiniteManualRunActive", not autoRun.active)
        -- Reset heart-overkill accumulator. exit() multiplies the
        -- timeFrac by overkillMult = heartMaxHp / (heartMaxHp + overkill)
        -- — a run killed by a wildly-overscaled mob gets its fraction
        -- shrunk; a near-tie death scores ~equal to its raw timeFrac.
        -- Per Matthew 2026-04-27: 10k overkill on 50k heart = 0.833
        -- mult (~17% haircut), 50k overkill = 0.5 mult.
        State.heartOverkill = 0
        -- Reset wave-attribution capture (set by MobUpdate's
        -- onHeartOverkill callback when a mob lands the killing
        -- blow). exit() reads these to attribute the run failure
        -- to the killing mob's wave-of-origin instead of State.wave.
        State.killingMobWave          = nil
        State.killingMobWaveStartedAt = nil
        State.killingMobWaveDuration  = nil
        -- Install the overkill capture hook on the WaveSystem ctx
        -- via the bridge. MobUpdate fires ctx.onHeartOverkill
        -- whenever a mob lands a killing blow with HP > heart's
        -- remaining HP. Set BEFORE startSpawnerLoop so the first
        -- mob can't beat the hook into place. Only the active
        -- spawner-token's run accumulates (myToken check) so a
        -- straggler from a previous loadout can't pollute the
        -- new run's score.
        do
            local wctxForHook = waveCtx()
            if wctxForHook then
                local hookToken = State.spawnerToken -- already bumped above
                wctxForHook.onHeartOverkill = function(overkill, _dmg, _heartHpBefore, mob)
                    if not State.active then return end
                    if State.spawnerToken ~= hookToken then return end
                    State.heartOverkill = (State.heartOverkill or 0) + overkill
                    -- Wave-attribution capture: the killing mob's
                    -- spawn-wave + start-time + expected duration
                    -- get used by exit() instead of State.wave.
                    -- Last-write-wins on multi-overkill runs but in
                    -- practice the heart dies on the first 0-HP
                    -- transition so this fires once per run.
                    if mob and not State.killingMobWave then
                        State.killingMobWave =
                            mob:GetAttribute("InfiniteWave")
                        State.killingMobWaveStartedAt =
                            mob:GetAttribute("InfiniteWaveStartedAt")
                        State.killingMobWaveDuration =
                            mob:GetAttribute("InfiniteWaveDuration")
                    end
                end
            end
        end
        -- auxCount drives the spawner's solo +1 wave-shift (so solo
        -- skips wave 1's softball HP and starts on what would be
        -- duo/trio's wave 2). Was unset before — the spawner read
        -- State.auxCount and got nil, so the shift never fired and
        -- solo loadouts were dying around wave 6-7. Per Matthew
        -- 2026-04-26: "remove wave 1 from solo" (i.e. start solo
        -- on what is currently wave 2's HP). Trio always = 3 (anchor
        -- counted), duo = 2, solo = 1, dev (auxIds=nil) = #templates
        -- which is plenty.
        if auxIds then
            State.auxCount = #auxIds
        else
            -- Dev shortcut path (grant-all): not "solo" by any
            -- meaningful definition, leave at 0 so the shift skips.
            State.auxCount = 0
        end
        -- Reset cumulative upgrade trackers per run. Each Solo wave
        -- triggers applyWaveCycleUpgrades which bumps these; once
        -- they hit RANGE_CAP_MULT (2×), the capped flag flips and
        -- subsequent cycles boost damage + firerate by 1.5× instead
        -- of applying range.
        State.auxRangeMult   = 1.0
        State.coreRangeMult  = 1.0
        State.auxRangeCapped = false
        State.coreRangeCapped = false
        local myToken = State.spawnerToken

        -- Reset the stat ledger so this run's stats start clean.
        StatLedger.reset()

        -- Heart full HP at run start (covers AUTO RUN loop case
        -- where heart was killed in the previous loadout's run).
        if ctx.map4Heart then
            local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
            ctx.map4Heart:SetAttribute("Health", maxHp)
        end

        -- Stash the slider's starting difficulty on State so the
        -- spawner loop's per-wave RunDifficultyMult ramp compounds
        -- on top of it (`starting × hpPerRound^(wave-1)`).
        State.startingDifficulty = startingDifficulty

        -- No teleport / no cinematic — player is already in arena.
        -- Grant loadout immediately, then auto-place after a delay
        -- so the gridUpdate paint has settled. Extended from 0.5s
        -- → 1.0s after Matthew 2026-04-26 reported "auto run place
        -- towers seems to not be working" — the shorter delay was
        -- racing the gridUpdate broadcast, especially during AUTO
        -- RUN looping where exit() destroys + re-broadcasts the
        -- grid back-to-back.
        State.coreId = coreId  -- stash for auto-place / future readers
        -- SAVE→GO bridge per Matthew 2026-04-27: "GO starts the
        -- waves and autoplaces any towers not place." If the
        -- player just SAVE'd this loadout (enterPrepare set
        -- State.savePending=true), their stock has already been
        -- granted AND they may have manually placed some — so
        -- skip the re-grant here. The auto-place client-side
        -- iterates remaining stock per slot, naturally filling
        -- only the spots NOT manually placed (placed towers
        -- consumed stock; auto-place skips zero-stock slots).
        --
        -- AUTO RUN bypasses this — sweep dequeues set fresh
        -- loadouts, so we always want the full grant there.
        local skipGrant = State.savePending and not autoRun.active
        if not skipGrant then
            -- Rarity propagated from prior SAVE phase or fresh GO.
            grantLoadout(player, auxIds, coreId, opts.rarity or State.rarity)
        else
            print(("[Infinite] %s GO after SAVE — keeping placed towers, auto-place will fill remaining stock")
                :format(player.Name))
        end
        State.savePending = false
        hookHeartDeath()
        task.delay(1.0, function()
            if State.active and State.spawnerToken == myToken then
                autoPlaceRemote:FireClient(player)
            end
        end)
        startSpawnerLoop(myToken)
        -- (silenced run-start / auto-place / autoPlaceRemote-fired
        -- traces — used to fire 3 lines per loadout × 81 loadouts.)
    end

    -- Loadout-panel handler. Payload from the client picker:
    --   { auxIds = {string,...}, slider = number 0..4 }
    -- auxIds may be a sparse list (only the towers the player picked);
    -- slider sets the starting RunDifficultyMult. Sanitize both before
    -- handing to enter().
    pickRemote.OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= "table" then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s submitted loadout but Infinite is locked"):format(player.Name))
            return
        end
        local opts = {}
        if type(payload.auxIds) == "table" then
            local clean = {}
            for _, id in ipairs(payload.auxIds) do
                if type(id) == "string" and TempTowers.Templates[id] then
                    table.insert(clean, id)
                end
            end
            opts.auxIds = clean
        end
        if type(payload.slider) == "number" then
            opts.slider = payload.slider
        end
        -- coreId: which Core archetype the player picked. Defaults
        -- to "Power" (DPS Core, the existing behavior). Whitelist
        -- to known core IDs so a malformed payload can't stamp an
        -- arbitrary attribute. Per Matthew 2026-04-27 Stage 1.
        if type(payload.coreId) == "string" and CoreTypes.isCore(payload.coreId) then
            opts.coreId = payload.coreId
            -- Persist on State so AUTO RUN (which doesn't carry a
            -- payload) picks up the player's last-saved Core choice
            -- as the sweep anchor. Per Matthew 2026-04-27.
            State.preferredCoreId = payload.coreId
            -- Stamp a player attribute too so the loadout picker
            -- can pre-select on next open. Per Matthew 2026-04-28.
            player:SetAttribute("PreferredCoreId", payload.coreId)
            -- Persist to DataStore so the choice survives Studio
            -- shift+F5 / next-session. Wrapped in pcall internally.
            persistCorePreference(player, payload.coreId)
        end
        -- 2026-04-29 ea3-8: rarity tier (Common / Rare / Exceptional /
        -- Legendary / Mythical). Whitelist against TempTowers.RarityMults
        -- so malformed payloads can't stamp arbitrary strings.
        if type(payload.rarity) == "string"
           and TempTowers.RarityMults[payload.rarity] then
            opts.rarity = payload.rarity
            -- Persist on State so AUTO RUN sweeps inherit the
            -- player's last-picked rarity as the sweep tier. Same
            -- pattern as preferredCoreId.
            State.preferredRarity = payload.rarity
            player:SetAttribute("PreferredRarity", payload.rarity)
        end
        -- Phase routing per Matthew 2026-04-27. SAVE = grant stock
        -- + allow placement, no waves. GO = full enter() with
        -- spawner start. Default "go" so legacy callers (anything
        -- without phase) keep their existing behavior.
        local phase = (type(payload.phase) == "string") and payload.phase or "go"
        if phase == "save" then
            enterPrepare(player, opts)
        else
            enter(player, opts)
        end
    end)

    -- Admin "RUN RESET" — same path as exit() (return to hub, stop
    -- spawner, clear towers). If an AUTO RUN sweep is in progress
    -- this also aborts the queue + prints partial tier list so the
    -- player can bail out mid-sweep.
    forceExitRemote.OnServerEvent:Connect(function(player)
        if State.activePlayer == player then
            if autoRun.active then
                print(("[Infinite] AUTO RUN aborted by %s after %d/%d run(s)"):format(
                    player.Name, #(autoRun.results or {}), autoRun.total))
                if autoRun.results and #autoRun.results > 0 then
                    local tiers = assembleTiers(autoRun.results)
                    printTierList(tiers)
                    -- Cache the partial tier list — incomplete sweep
                    -- is still useful for spot-checks. Clearer than
                    -- losing all data when the user bails early.
                    lastSweep = {
                        tiers          = tiers,
                        results        = autoRun.results,
                        completedAt    = os.time(),
                        total          = autoRun.total,
                        aborted        = true,
                        balanceVersion = currentBalanceVersion,
                    }

                    -- Aborted partials still feed cumulative — every
                    -- finished run is a real datapoint regardless of
                    -- whether the SWEEP completed.
                    -- 2026-04-29 ea: skip results already flushed by the
                    -- SUPER AUTO checkpointer so we don't double-count
                    -- them in the cumulative pool on RUN RESET abort.
                    local resetStartIdx = (autoRun.cumulativeFlushedIdx or 0) + 1
                    for i = resetStartIdx, #autoRun.results do
                        table.insert(cumulativeResults, autoRun.results[i])
                    end
                    -- Persist cumulative + the aborted sweep itself.
                    InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
                    InfiniteRunHistoryStore.append(lastSweep)
                end
                autoRun.active  = false
                autoRun.queue   = nil
                autoRun.current = nil
                autoRun.results = nil
                autoRun.total   = 0
                autoRun.isSuperAuto          = nil
                autoRun.isTowerSuper         = nil  -- 2026-04-29 ea3-24
                autoRun.towerSuperRarityCoreQueue = nil
                autoRun.towerSuperFocusAux   = nil
                autoRun.cumulativeFlushedIdx = nil
                StatLedger.setRecordingEnabled(false)
            end
            print(("[Infinite] %s forced exit via admin RUN RESET"):format(player.Name))
            exit(player)
        end
    end)

    -- Admin "TOTAL RESET" — placeholder until persistent run history
    -- lands. Once that's in, this clears the DataStore-backed history
    -- the tier-rating algorithm reads from.
    totalResetRemote.OnServerEvent:Connect(function(player)
        if not player then return end
        -- TOTAL RESET = "Erase ALL Balance Studio stats from
        -- inception." Clears the in-session cumulative pool, the
        -- persisted cumulative DataStore key, AND the DataStore
        -- sweep history (so LOAD RUN starts fresh too). Per the
        -- admin panel's confirm-modal copy: "Wipes BOTH the
        -- in-session cumulative pool AND every saved sweep."
        local cleared = #cumulativeResults
        cumulativeResults = {}
        InfiniteRunHistoryStore.clearCumulative()
        InfiniteRunHistoryStore.clear()
        -- 2026-04-29 ea3-5: also drop the persisted sim cache —
        -- those predictions were calibrated against the old
        -- cumulative pool and would mis-align with a fresh slate.
        simulatedSweep = nil
        simulatedSweepByCore = {}
        InfiniteRunHistoryStore.clearSim()
        -- ea3-125: drop VALIDATE history alongside the rest.
        validateHistory = {}
        print(("[Infinite] %s TOTAL RESET — cleared %d cumulative run(s) + DataStore history + sim cache (persisted)")
            :format(player.Name, cleared))
        lastSweepDataRemote:FireClient(player, {
            empty        = true,
            cumulative   = true,
            lastRunStats = "",
        })
    end)

    -- Admin "AUTO RUN" — kick off the full benchmark sweep. Builds
    -- the queue (9 solos + 36 pairs + 28 triples-with-anchor = 73
    -- runs), turns on stat recording, fires the first loadout via
    -- enter(). exit() handles the dequeue + finalize after each run.
    -- Refuses if a run is already active (player must RUN RESET
    -- first) — protects against accidentally clobbering a manual run.
    autoRunRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested AUTO RUN but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested AUTO RUN but a sweep is already in progress (%d/%d)")
                :format(player.Name, #(autoRun.results or {}), autoRun.total))
            return
        end
        -- ea3-115: when the SIMULATE→FAILURE SWEEP row was added, this
        -- handler became user-reachable again. Match the arena handlers'
        -- guard set so legacy auto-run can't fire on top of an active
        -- (or leaking) ArenaSweepRunner combo. Without this, the legacy
        -- enter() would set up a fresh full-Infinite arena while phase 4
        -- mini-pickles + HP labels + Pickle Lord boss model from the
        -- prior arena combo were still around — the screenshot Matthew
        -- captured (heart 647/40000, a mob bar showing 12373/10650, a
        -- ghost RETURN TO HUB) was that exact state collision.
        if ctx.isArenaSweepActive and ctx.isArenaSweepActive() then
            warn(("[Infinite] %s requested AUTO RUN but an arena combo is already running"):format(player.Name))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested AUTO RUN but another player is in a run"):format(player.Name))
            return
        end

        -- Use the player's last-saved Core archetype as the sweep
        -- anchor. Default Power if no SAVE/GO has happened this
        -- session.
        local sweepCoreId = State.preferredCoreId or "Power"
        -- Persist on AUTO RUN start too (Matthew 2026-04-28: "store
        -- it on starting auto run since i shift f5 sometimes").
        -- Mirrors the SAVE/GO persist path so a sweep-with-no-pick
        -- still saves the implicit Power default.
        player:SetAttribute("PreferredCoreId", sweepCoreId)
        persistCorePreference(player, sweepCoreId)
        local queue = buildAutoRunQueue(sweepCoreId)
        autoRun.active     = true
        autoRun.queue      = queue
        autoRun.results    = {}
        autoRun.total      = #queue
        autoRun.continuous = true   -- loop sweeps until STOP RUN
        autoRun.sweepNum   = 1
        -- Cache the sweep's coreId for the dequeue paths to inject
        -- into each enter() call (enter() defaults to "Power"
        -- otherwise — would silently override the saved choice).
        autoRun.coreId     = sweepCoreId

        -- Stat recording is disabled by default ("get it working
        -- first" decision). AUTO RUN is the first place we WANT
        -- per-tower DPS / stun-sec / slow-value capture, since
        -- the tier list will eventually weight by these too. Flip
        -- on for the duration of the sweep; exit() flips off when
        -- the queue drains (or RUN RESET aborts).
        StatLedger.setRecordingEnabled(true)
        StatLedger.reset()

        -- Pop the first loadout + start. If a manual run is already
        -- active for THIS player, enter()'s mid-run-restart branch
        -- handles the cleanup; otherwise it's a fresh entry.
        local firstLoadout = table.remove(queue, 1)
        autoRun.current = firstLoadout

        autoRunProgressRemote:FireClient(player, {
            current = 1,
            total   = autoRun.total,
            label   = firstLoadout.label,
        })
        print(("[Infinite] AUTO RUN starting — %d loadouts queued (core=%s, anchor=%s, cap=wave %d)")
            :format(autoRun.total, sweepCoreId, AUTO_RUN_ANCHOR, MAX_AUTO_RUN_WAVE))
        -- Slider tracks aux count — same lockstep as the loadout
        -- picker (more towers = more difficulty). 1 aux → 1.25×,
        -- 2 aux → 1.5×, 3 aux → 1.75×.
        enter(player, {
            auxIds = firstLoadout.auxIds,
            slider = #firstLoadout.auxIds,
            coreId = sweepCoreId,
        })
    end)

    -- LONG AUTO — curated 3-aux trio sweep. NO LONGER USER-FACING
    -- as of 2026-04-28: the SIMULATE → FULL AUTO menu item
    -- bundles solos + duos + curated trios into one run via
    -- buildFullAutoQueue, so the standalone LONG AUTO button was
    -- removed from the admin panel. The remote handler is kept
    -- intact for two reasons:
    --   1. buildLongAutoQueue still ships its trio list (consumed
    --      by buildFullAutoQueue).
    --   2. A future tool (e.g. a "trios only" sweep button) can
    --      fire longAutoRemote without re-implementing this path.
    -- Identical control flow to AUTO RUN (same autoRun state /
    -- dequeue / tier-list pool); only the queue source differs.
    -- Continuous = false since this is a one-shot synergy pass.
    longAutoRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested LONG AUTO but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested LONG AUTO but a sweep is already in progress (%d/%d)")
                :format(player.Name, #(autoRun.results or {}), autoRun.total))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested LONG AUTO but another player is in a run"):format(player.Name))
            return
        end

        local sweepCoreId = State.preferredCoreId or "Power"
        -- Persist Core preference whenever the player kicks a
        -- sweep — mirror of AUTO RUN / FULL AUTO / SELECT AUTO.
        player:SetAttribute("PreferredCoreId", sweepCoreId)
        persistCorePreference(player, sweepCoreId)
        local queue = buildLongAutoQueue(sweepCoreId)
        if #queue == 0 then
            warn(("[Infinite] %s requested LONG AUTO but Config.LongAutoTrios is empty / all invalid"):format(
                player.Name))
            return
        end
        autoRun.active     = true
        autoRun.queue      = queue
        autoRun.results    = {}
        autoRun.total      = #queue
        autoRun.continuous = false   -- one-shot synergy pass; user re-triggers
        autoRun.sweepNum   = 1
        autoRun.coreId     = sweepCoreId

        StatLedger.setRecordingEnabled(true)
        StatLedger.reset()

        local firstLoadout = table.remove(queue, 1)
        autoRun.current = firstLoadout

        autoRunProgressRemote:FireClient(player, {
            current = 1,
            total   = autoRun.total,
            label   = firstLoadout.label,
        })
        print(("[Infinite] LONG AUTO starting — %d trio loadouts queued (core=%s, cap=wave %d)")
            :format(autoRun.total, sweepCoreId, MAX_AUTO_RUN_WAVE))
        enter(player, {
            auxIds = firstLoadout.auxIds,
            slider = #firstLoadout.auxIds,
            coreId = sweepCoreId,
        })
    end)

    -- FULL AUTO — solos + duos + curated trios in one queue. Per
    -- Matthew 2026-04-28 SIMULATE menu redesign. Same control flow
    -- as AUTO RUN; differs only in queue source.
    --
    -- continuous = true (was false until 2026-04-28 dd). The
    -- monitor's STOP toggle defaults to "CONTINUOUS" on every
    -- sweep start, but the server flag was hardcoded false here —
    -- mismatch meant FULL AUTO would drop out after sweep #1
    -- instead of flowing into the top-combos-descending tier sweep
    -- that finalize() rebuilds for sweep #2+. Now matches AUTO
    -- RUN: sweep #1 = broad initial queue, sweep #2+ = top 100
    -- combos descending, loops until user flips toggle to STOP AT
    -- END or STOP NOW.
    fullAutoRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested FULL AUTO but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested FULL AUTO but a sweep is already in progress (%d/%d)")
                :format(player.Name, #(autoRun.results or {}), autoRun.total))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested FULL AUTO but another player is in a run"):format(player.Name))
            return
        end

        local sweepCoreId = State.preferredCoreId or "Power"
        player:SetAttribute("PreferredCoreId", sweepCoreId)
        persistCorePreference(player, sweepCoreId)
        local queue = buildFullAutoQueue(sweepCoreId)
        if #queue == 0 then
            warn(("[Infinite] %s requested FULL AUTO but the queue is empty"):format(player.Name))
            return
        end
        autoRun.active     = true
        autoRun.queue      = queue
        autoRun.results    = {}
        autoRun.total      = #queue
        autoRun.continuous = true   -- matches monitor toggle's CONTINUOUS default (was false until dd)
        autoRun.sweepNum   = 1
        autoRun.coreId     = sweepCoreId

        StatLedger.setRecordingEnabled(true)
        StatLedger.reset()

        local firstLoadout = table.remove(queue, 1)
        autoRun.current = firstLoadout
        autoRunProgressRemote:FireClient(player, {
            current = 1,
            total   = autoRun.total,
            label   = firstLoadout.label,
        })
        print(("[Infinite] FULL AUTO starting — %d loadouts queued (core=%s, cap=wave %d)")
            :format(autoRun.total, sweepCoreId, MAX_AUTO_RUN_WAVE))
        enter(player, {
            auxIds = firstLoadout.auxIds,
            slider = #firstLoadout.auxIds,
            coreId = sweepCoreId,
        })
    end)

    -- SUPER AUTO — runs FULL AUTO sweep sequentially for all 3
    -- Cores (Power → Control → Support), then continuous top-combos
    -- across the mixed-Core cumulative pool. RUN SIM fires per-Core
    -- at start so the server log has closed-form predictions to
    -- compare against the 3 real sweeps. Per Matthew 2026-04-29
    -- "make a super auto run off the simulate menu that does a full
    -- sweep for all 3 cores then goes into extra tiered testing.
    -- and run the sim for every core when starting."
    superAutoRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested SUPER AUTO but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested SUPER AUTO but a sweep is already in progress (%d/%d)")
                :format(player.Name, #(autoRun.results or {}), autoRun.total))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested SUPER AUTO but another player is in a run"):format(player.Name))
            return
        end

        -- Phase 1: RUN SIM for all 3 Cores. Server-side runSimForCore
        -- prints tier list + validator delta to the log per Core.
        -- Cumulative pool stays untouched (sim doesn't write to it).
        -- skipPersist=true; flush once at the end (ea3-118).
        print(("[Infinite] SUPER AUTO — running pre-sweep sims for all 3 Cores"):format(player.Name))
        for _, coreId in ipairs(CoreTypes.Ids) do
            simulatedSweep = runSimForCore(coreId, true)
            -- Fire each sim payload to the requesting client so
            -- their monitor's RUN SIM display reflects the most-
            -- recent (last fire wins; Support's tier list will be
            -- the visible one client-side, but all 3 are in the log).
            simulateDataRemote:FireClient(player, simulatedSweep)
        end
        InfiniteRunHistoryStore.saveSim(simulatedSweepByCore)

        -- Phase 2: kick off Power's broad FULL AUTO sweep.
        -- superAutoCoreQueue holds the Cores to run after Power.
        -- finalize() pops the next Core when each sweep drains.
        local firstCore = "Power"
        local queue = buildAutoRunQueue(firstCore)
        player:SetAttribute("PreferredCoreId", firstCore)
        persistCorePreference(player, firstCore)
        autoRun.active     = true
        autoRun.queue      = queue
        autoRun.results    = {}
        autoRun.total      = #queue
        autoRun.continuous = true   -- after all 3 Cores done, continuous top-combos kicks in
        autoRun.sweepNum   = 1
        autoRun.coreId     = firstCore
        autoRun.superAutoCoreQueue = { "ControlCore", "SupportCore" }
        -- 2026-04-29 ea: crash-recovery checkpoint state — every 50
        -- completed runs the per-result block flushes the unflushed
        -- window to cumulativeResults + DataStore. Reset each time
        -- autoRun.results becomes a new {} (Core-queue progression +
        -- continuous sweep blocks above).
        autoRun.isSuperAuto          = true
        autoRun.cumulativeFlushedIdx = 0

        StatLedger.setRecordingEnabled(true)
        StatLedger.reset()

        local firstLoadout = table.remove(queue, 1)
        autoRun.current = firstLoadout
        autoRunProgressRemote:FireClient(player, {
            current = 1,
            total   = autoRun.total,
            label   = firstLoadout.label,
        })
        print(("[Infinite] SUPER AUTO starting — Core 1/3 (%s), %d loadouts queued, queue=[%s]")
            :format(firstCore, autoRun.total,
                table.concat(autoRun.superAutoCoreQueue, ", ")))
        enter(player, {
            auxIds = firstLoadout.auxIds,
            slider = #firstLoadout.auxIds,
            coreId = firstCore,
        })
    end)

    -- STORY SUPER — Phase E-2 (2026-04-29 ea3-35). Replaces the
    -- broad-sweep behavior of SUPER AUTO with a story-progression-
    -- mirror sweep: per Core, a full map 1 → 2 → 3 run with auto-
    -- picked upgrades. See systems/StorySuperAuto.lua + memory
    -- project_core_upgrade_picker.md → "SUPER AUTO redesign".
    --
    -- E-2 ships orchestration only — tower auto-placement is
    -- deferred to E-2.5. Without placement, every Core's run dies
    -- on wave 1 with the heart at 0 HP, but the orchestration
    -- breadcrumbs (server log) prove the StoryAutoDriver state
    -- machine + AutoPicker bypass + SwitchMap programmatic fire
    -- all wire correctly end-to-end.
    --
    -- The existing SUPER AUTO (broad-sweep across all combos) keeps
    -- working unchanged — STORY SUPER is a NEW menu item. After
    -- E-2.5 lands placement, Matthew will decide whether STORY
    -- SUPER replaces SUPER AUTO outright (per the design dump's
    -- "Replace" call) or stays parallel.
    local storySuperRemote = Remotes.getOrCreate(Remotes.Names.InfiniteStorySuperRun, "RemoteEvent")
    local StorySuperAuto = require(script.Parent:WaitForChild("StorySuperAuto"))
    storySuperRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested STORY SUPER but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested STORY SUPER but a sweep is already in progress"):format(player.Name))
            return
        end
        if StorySuperAuto.isActive() then
            warn(("[Infinite] %s requested STORY SUPER but a story-sweep is already active"):format(player.Name))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested STORY SUPER but another player is in a run"):format(player.Name))
            return
        end

        -- 2026-04-29 ea3-36/37 Phase E-2.5: pass placement helpers from
        -- ctx (set by TowerPlacement.lua during Hub setup):
        --   placeTowerForPlayer — programmatic placement (Core + auxes)
        --   findOpenCellForMap  — first open cell of the requested
        --                         footprint, used per-aux to handle the
        --                         variable footprints across the roster.
        -- Without these the run dies on wave 1 every Core; with them
        -- each Core+aux defends through whatever the kit can survive.
        local placeTowerForPlayer = ctx.placeTowerForPlayer
        local findOpenCellForMap  = ctx.findOpenCellForMap
        if not placeTowerForPlayer or not findOpenCellForMap then
            warn("[Infinite] STORY SUPER — ctx placement helpers not set; sweep will run without placement")
        end
        print(("[Infinite] %s starting STORY SUPER (placement=%s)"):format(
            player.Name,
            (placeTowerForPlayer and findOpenCellForMap) and "wired" or "missing"))
        StorySuperAuto.start(player, {
            placeTower   = placeTowerForPlayer,
            findOpenCell = findOpenCellForMap,
            onComplete   = function(summary)
                print(("[Infinite] STORY SUPER complete — %d cores swept in %.1fs"):format(
                    #(summary.perCore or {}), summary.elapsedSeconds or 0))
                for _, perCore in ipairs(summary.perCore or {}) do
                    print(("  %s: phase=%s, %.1fs, reason=%s"):format(
                        perCore.coreId,
                        perCore.finalPhase,
                        perCore.elapsedSeconds,
                        tostring(perCore.failureReason)))
                end
            end,
        })
    end)

    -- CORE AUTO — 2026-04-29 ea3-42 Phase E-3. Tests how each Core
    -- upgrade option affects survival, all other vars held constant.
    -- 12 conditions (3 Cores × 4 upgrade-paths) → per-condition
    -- summary at end. Reuses StoryAutoDriver + AutoPicker fixed-
    -- index/sequence modes. See systems/CoreAutoRunner.lua + memory
    -- project_core_upgrade_picker.md → "CORE AUTO" section.
    local coreAutoRemote = Remotes.getOrCreate(Remotes.Names.InfiniteCoreAutoRun, "RemoteEvent")
    local CoreAutoRunner = require(script.Parent:WaitForChild("CoreAutoRunner"))
    coreAutoRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested CORE AUTO but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested CORE AUTO but a sweep is already in progress"):format(player.Name))
            return
        end
        if StorySuperAuto.isActive() or CoreAutoRunner.isActive() then
            warn(("[Infinite] %s requested CORE AUTO but a story-sweep is already active"):format(player.Name))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested CORE AUTO but another player is in a run"):format(player.Name))
            return
        end

        local placeTowerForPlayer = ctx.placeTowerForPlayer
        local findOpenCellForMap  = ctx.findOpenCellForMap
        if not placeTowerForPlayer or not findOpenCellForMap then
            warn("[Infinite] CORE AUTO — ctx placement helpers not set; sweep will run without placement")
        end
        print(("[Infinite] %s starting CORE AUTO (placement=%s)"):format(
            player.Name,
            (placeTowerForPlayer and findOpenCellForMap) and "wired" or "missing"))
        CoreAutoRunner.start(player, {
            placeTower   = placeTowerForPlayer,
            findOpenCell = findOpenCellForMap,
            onComplete   = function(summary)
                print(("[Infinite] CORE AUTO complete — %d conditions in %.1fs"):format(
                    #(summary.perCondition or {}), summary.elapsedSeconds or 0))
            end,
        })
    end)

    -- ea3-52 Phase F — bounds-shrinking arena sweep modes.
    -- AUTORUN = greedy combo search (42 sub-runs). SUPER AUTORUN =
    -- full coverage (1092 sub-runs). Both run on Map 4 with phase
    -- bounds shrinking from Map 1 size → Map 2 → Map 3 → Pickle Lord.
    -- Bosses are skipped (player tests those in real story mode).
    -- Auto-fires RUN SIM at sweep start so the closed-form
    -- prediction is in the log alongside the live results.
    local arenaAutorun       = Remotes.getOrCreate(Remotes.Names.InfiniteArenaAutorun, "RemoteEvent")
    local arenaSuperAutorun  = Remotes.getOrCreate(Remotes.Names.InfiniteArenaSuperAutorun, "RemoteEvent")

    local function arenaGuards(player, label)
        if not player or not player.Parent then return false end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested %s but Infinite is locked"):format(player.Name, label))
            return false
        end
        if autoRun.active then
            warn(("[Infinite] %s requested %s but a sweep is already in progress"):format(player.Name, label))
            return false
        end
        if ctx.isArenaSweepActive and ctx.isArenaSweepActive() then
            warn(("[Infinite] %s requested %s but an arena combo is already running"):format(player.Name, label))
            return false
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested %s but another player is in a run"):format(player.Name, label))
            return false
        end
        return true
    end

    -- Auto-fire RUN SIM for all 3 Cores at the start of any arena
    -- sweep. Predictions land in the log so the analyst can compare
    -- closed-form to live results. simulatedSweep is module-level
    -- (Infinite.lua); reusing the existing runSimForCore path.
    local function autoFireRunSimAllCores(player)
        -- Skip per-call DataStore writes; flush once at the end.
        -- See runSimForCore's skipPersist comment for the queue-warning
        -- rationale (ea3-118).
        for _, coreId in ipairs(CoreTypes.Ids) do
            simulatedSweep = runSimForCore(coreId, true)
            simulateDataRemote:FireClient(player, simulatedSweep)
        end
        InfiniteRunHistoryStore.saveSim(simulatedSweepByCore)
    end

    -- AUTORUN — greedy 42-combo search.
    arenaAutorun.OnServerEvent:Connect(function(player)
        if not arenaGuards(player, "ARENA AUTORUN") then return end
        print(("[Infinite] %s starting ARENA AUTORUN (greedy 42-combo search)"):format(player.Name))
        autoFireRunSimAllCores(player)
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))
        task.spawn(function()
            local summary = ArenaSweepRunner.runGreedySweep(player, {
                autoPickerOpts = { mode = "random" },
            }, {})
            print(("[Infinite] ARENA AUTORUN complete — best: %s + %s + %s + %s, phase %d"):format(
                tostring(summary.bestCore),
                tostring(summary.bestAux1),
                tostring(summary.bestAux2),
                tostring(summary.bestAux3),
                summary.bestFinalPhase or 0))
        end)
    end)

    -- VALIDATE — single-combo smoke test. Reads the player's saved
    -- loadout (LOADOUT picker → coreId + first 3 locked auxes); falls
    -- back to the validator report's largest-|delta| combo (or a
    -- known-strong static combo if no validator report is on file).
    -- ~3-5 min at 20× speed. ea3-53; expanded ea3-125 with predicted-
    -- vs-observed delta printout, in-memory history append, and
    -- worst-delta fallback.
    local arenaValidate = Remotes.getOrCreate(Remotes.Names.InfiniteArenaValidate, "RemoteEvent")
    arenaValidate.OnServerEvent:Connect(function(player)
        if not arenaGuards(player, "ARENA VALIDATE") then return end
        -- Read saved loadout. PreferredCoreId / PreferredRarity are
        -- hydrated by Infinite.lua on PlayerAdded; locked auxes come
        -- from the LOADOUT picker's last commit. We read the
        -- player attributes directly here for simplicity.
        local coreId = player:GetAttribute("PreferredCoreId") or "Power"
        local auxIds = {}
        -- Iterate aux templates in deterministic order so the same
        -- saved-loadout produces the same VALIDATE result.
        local templateIds = {}
        for id in pairs(TempTowers.Templates) do table.insert(templateIds, id) end
        table.sort(templateIds)
        for _, id in ipairs(templateIds) do
            if #auxIds >= 3 then break end
            -- Player has aux as locked-in-loadout if Equipped=true.
            -- If no Equipped flags found, fall through.
            if player:GetAttribute(id .. "Equipped") == true then
                table.insert(auxIds, id)
            end
        end
        -- ea3-125 fallback chain when no 3-aux loadout is saved:
        --   1. Worst-|delta| combo from the latest validator report
        --      (the most informative re-test — same combo we'd pick
        --      for TARGETED's #1 slot)
        --   2. Static fallback PepperCannon+HoneyHive+PaceFlower
        --      (top closed-form sim result for Power as of the last
        --      balance pass — kept as last-resort so a fresh slate
        --      with no validator report still has a known-strong combo)
        local fallbackSource: string? = nil
        if #auxIds < 3 then
            local simRecord = simulatedSweepByCore[coreId]
            local validation = simRecord and simRecord.validation
            if validation and type(validation.perLoadout) == "table"
                and #validation.perLoadout > 0
            then
                local topRow = InfiniteValidator.topByDelta(validation, 1)[1]
                if topRow and type(topRow.auxIds) == "table" and #topRow.auxIds >= 1 then
                    auxIds = topRow.auxIds
                    fallbackSource = ("worst-delta combo (sim=%.2f real=%.2f delta=%+.2f)"):format(
                        topRow.simWave or 0,
                        topRow.realAvgWave or 0,
                        topRow.delta or 0)
                end
            end
            if #auxIds < 3 then
                -- Pad to 3 if validator picked a solo/duo, OR fall through
                -- to static fallback if no validator report at all.
                if fallbackSource then
                    -- Pad with static known-strong picks while preserving
                    -- the worst-delta entry. Order matters less than the
                    -- presence of the worst-delta tower.
                    local pad = { "PepperCannon", "HoneyHive", "PaceFlower" }
                    local seen = {}
                    for _, id in ipairs(auxIds) do seen[id] = true end
                    for _, id in ipairs(pad) do
                        if #auxIds >= 3 then break end
                        if not seen[id] then
                            table.insert(auxIds, id)
                            seen[id] = true
                        end
                    end
                else
                    auxIds = { "PepperCannon", "HoneyHive", "PaceFlower" }
                    fallbackSource = "static fallback (no validator report on file)"
                end
            end
        end
        if fallbackSource then
            print(("[Infinite] VALIDATE: no 3-aux saved loadout; using %s — %s + %s + %s + %s"):format(
                fallbackSource, coreId, auxIds[1], auxIds[2], auxIds[3]))
        end
        print(("[Infinite] %s starting ARENA VALIDATE (single combo: %s + %s + %s + %s)"):format(
            player.Name, coreId, auxIds[1], auxIds[2], auxIds[3]))

        -- ea3-125 upgrade #1 (pre-run): print sim's wave-1..28
        -- prediction + recent real avg + delta from validator's
        -- perLoadout, scoped to this combo. Answers "where does the
        -- closed-form model think this combo is wrong" before the
        -- 4-phase scripted run starts. Skipped silently when no
        -- validator entry exists for this combo (common on a fresh
        -- slate or first VALIDATE press after BALANCE RESET).
        do
            local simRecord = simulatedSweepByCore[coreId]
            local validation = simRecord and simRecord.validation
            if validation and type(validation.perLoadout) == "table" then
                local key = (function()
                    local copy = table.clone(auxIds)
                    table.sort(copy)
                    return table.concat(copy, ",")
                end)()
                for _, e in ipairs(validation.perLoadout) do
                    local ek = (function()
                        local copy = table.clone(e.auxIds or {})
                        table.sort(copy)
                        return table.concat(copy, ",")
                    end)()
                    if ek == key then
                        print(("[Infinite] VALIDATE reference: closed-form sim says wave-1..28 finalWave=%.2f, real avg=%.2f over %d run(s), delta=%+.2f")
                            :format(e.simWave or 0, e.realAvgWave or 0,
                                e.realRuns or 0, e.delta or 0))
                        break
                    end
                end
            end
        end

        autoFireRunSimAllCores(player)
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))
        task.spawn(function()
            local result = ArenaSweepRunner.runOneCombo(player, {
                coreId = coreId,
                auxIds = auxIds,
                autoPickerOpts = { mode = "random" },
            }, {
                onPhaseStart = function(phase)
                    print(("[Infinite] VALIDATE phase %d START"):format(phase))
                end,
                onPhaseEnd = function(phase, phaseResult)
                    print(("[Infinite] VALIDATE phase %d END — cleared=%s, heartHp=%d"):format(
                        phase,
                        tostring(phaseResult and phaseResult.cleared),
                        phaseResult and phaseResult.heartHp or 0))
                end,
            })
            print(("[Infinite] ARENA VALIDATE complete — finalPhase=%s, %.1fs"):format(
                tostring(result and result.finalPhase),
                result and result.elapsedSeconds or 0))
            if result and result.phaseResults and result.phaseResults[4] then
                local p4 = result.phaseResults[4]
                print(("[Infinite]   Phase 4 boss damage: %d / %d (%d%%)"):format(
                    p4.bossDamageDealt or 0,
                    p4.bossInitialHp or 0,
                    (p4.bossDamageDealt and p4.bossInitialHp and p4.bossInitialHp > 0)
                        and math.floor(p4.bossDamageDealt / p4.bossInitialHp * 100 + 0.5)
                        or 0))
            end

            -- ea3-125 upgrade #2: append finalPhase observation to
            -- the in-memory VALIDATE history for this combo, then
            -- dump the per-combo phase trail so the analyst sees
            -- variance across repeated presses on the same loadout.
            -- Capped at VALIDATE_HISTORY_CAP entries (oldest drops).
            if result and result.finalPhase then
                local key = (function()
                    local copy = table.clone(auxIds)
                    table.sort(copy)
                    return coreId .. "/" .. table.concat(copy, ",")
                end)()
                local entries = validateHistory[key]
                if not entries then
                    entries = {}
                    validateHistory[key] = entries
                end
                table.insert(entries, {
                    finalPhase     = result.finalPhase,
                    balanceVersion = currentBalanceVersion,
                    completedAt    = os.time(),
                })
                while #entries > VALIDATE_HISTORY_CAP do
                    table.remove(entries, 1)
                end
                local trail = {}
                for _, e in ipairs(entries) do
                    table.insert(trail, string.format("%.2f", e.finalPhase))
                end
                local sum = 0
                for _, e in ipairs(entries) do sum = sum + (e.finalPhase or 0) end
                local mean = sum / #entries
                print(("[Infinite]   VALIDATE history (%d run(s) this era): finalPhase trail=[%s] mean=%.2f"):format(
                    #entries, table.concat(trail, ", "), mean))
            end
        end)
    end)

    -- ea3-74 STOP — abort the active arena sweep at the next safe
    -- point. Client's SIMULATE button text-swaps to STOP whenever
    -- Workspace.Map4ArenaSweepActive is true, and clicking it fires
    -- this remote instead of opening the menu.
    local arenaStop = Remotes.getOrCreate(Remotes.Names.InfiniteArenaStop, "RemoteEvent")
    arenaStop.OnServerEvent:Connect(function(player)
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))
        if ArenaSweepRunner.requestAbort() then
            print(("[Infinite] %s requested STOP — abort flag set, sweep will exit at next safe point"):format(
                player.Name))
        else
            print(("[Infinite] %s requested STOP but no sweep is running"):format(player.Name))
        end
    end)

    -- ea3-71 LONG VALIDATE — replays the saved VALIDATE combo 8
    -- times back-to-back (~30 min total) so the analyst gets variance
    -- across runs on a single loadout. Same loadout-resolution path as
    -- VALIDATE (saved 3-aux loadout or fallback).
    local arenaLongValidate = Remotes.getOrCreate(Remotes.Names.InfiniteArenaLongValidate, "RemoteEvent")
    arenaLongValidate.OnServerEvent:Connect(function(player)
        if not arenaGuards(player, "ARENA LONG VALIDATE") then return end
        local coreId = player:GetAttribute("PreferredCoreId") or "Power"
        local auxIds = {}
        local templateIds = {}
        for id in pairs(TempTowers.Templates) do table.insert(templateIds, id) end
        table.sort(templateIds)
        for _, id in ipairs(templateIds) do
            if #auxIds >= 3 then break end
            if player:GetAttribute(id .. "Equipped") == true then
                table.insert(auxIds, id)
            end
        end
        if #auxIds < 3 then
            auxIds = { "PepperCannon", "HoneyHive", "PaceFlower" }
            print("[Infinite] LONG VALIDATE: no 3-aux saved loadout; using fallback (Power/Pepper/Honey/Pace)")
        end
        local LONG_RUNS = 8  -- ~3.7 min/combo × 8 ≈ 30 min wall time at 20× game speed
        print(("[Infinite] %s starting ARENA LONG VALIDATE — %d combos: %s + %s + %s + %s"):format(
            player.Name, LONG_RUNS, coreId, auxIds[1], auxIds[2], auxIds[3]))
        autoFireRunSimAllCores(player)
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))
        task.spawn(function()
            local results = {}
            -- ea3-113: was 220 (≈3.7 min/combo) which over-estimated by
            -- 4× — observed wall at 20× game speed is ~50s per 4-phase
            -- combo. 60 gives a small safety margin so the HUD ETA bar
            -- doesn't go negative. Same constant in SPOT CHECK + the
            -- greedy/full coverage sweeps in ArenaSweepRunner.
            local PER_COMBO_SEC = 60
            local totalSec = PER_COMBO_SEC * LONG_RUNS
            -- ea3-106: capture sweep-wide start timestamp so the ETA bar
            -- decrements monotonically across all 8 combos. Without this,
            -- runOneCombo's local sweepStartedAt resets each combo and
            -- the bar jumps "29m → 26m → reset to 29m → 26m → ..." at
            -- every boundary. Passed via opts.sweepStartedAt below.
            local sweepStartedAt = os.clock()
            for i = 1, LONG_RUNS do
                -- ea3-102: every other combo (even index = 2, 4, 6, 8)
                -- locks ALL towers on the Pickle Lord — not just Core —
                -- so we can see whether full-team focus actually burns
                -- the boss down. Odd combos (1, 3, 5, 7) keep the
                -- Core-only lock so we have a paired comparison.
                local lockAll = (i % 2 == 0)
                print(("[Infinite] LONG VALIDATE combo %d / %d START%s"):format(
                    i, LONG_RUNS, lockAll and " (ALL-TOWER lock)" or " (Core-only lock)"))
                local r = ArenaSweepRunner.runOneCombo(player, {
                    coreId = coreId,
                    auxIds = auxIds,
                    autoPickerOpts = { mode = "random" },
                    progressLabel    = ("LONG %d/%d"):format(i, LONG_RUNS),
                    totalEstimateSec = totalSec,
                    sweepStartedAt   = sweepStartedAt,
                    lockAllTowersOnBoss = lockAll,
                }, {})
                table.insert(results, r)
                local lockTag = lockAll and "ALL" or "Core"
                local p4Dmg   = r and r.phaseResults and r.phaseResults[4] and r.phaseResults[4].bossDamageDealt
                local luckAvg = r and r.luckAvg
                print(("[Infinite] LONG VALIDATE combo %d / %d END — finalPhase=%s lock=%s bossDmg=%s luckAvg=%.2f (n=%d)"):format(
                    i, LONG_RUNS, tostring(r and r.finalPhase), lockTag,
                    p4Dmg and tostring(math.floor(p4Dmg + 0.5)) or "—",
                    luckAvg or 0, (r and r.luckCount) or 0))
                -- ea3-74: bail out of the multi-combo loop if STOP
                -- was hit (runOneCombo surfaces the abort on result).
                if r and r.aborted then
                    print(("[Infinite] LONG VALIDATE aborted at combo %d / %d"):format(i, LONG_RUNS))
                    break
                end
            end
            -- Aggregate.
            local clearedToPhase = { 0, 0, 0, 0 }  -- count of runs that REACHED phase N
            local bossDamageSum, bossDamageCount = 0, 0
            local luckAvgSum, luckAvgCount = 0, 0
            local luckMin, luckMax = math.huge, -math.huge
            for _, r in ipairs(results) do
                local fp = (r and r.finalPhase) or 0
                for p = 1, math.max(0, fp) do
                    clearedToPhase[p] = clearedToPhase[p] + 1
                end
                local p4 = r and r.phaseResults and r.phaseResults[4]
                if p4 and p4.bossDamageDealt then
                    bossDamageSum = bossDamageSum + p4.bossDamageDealt
                    bossDamageCount = bossDamageCount + 1
                end
                -- ea3-103: luck stats for the sweep summary. Per-combo
                -- luckAvg comes from runOneCombo result (RunLuckSum /
                -- RunLuckCount snapshot at combo end). Reporting
                -- min/avg/max gives the analyst a sense of how much
                -- of the boss-damage spread is RNG vs loadout signal.
                if r and r.luckAvg and r.luckCount and r.luckCount > 0 then
                    luckAvgSum = luckAvgSum + r.luckAvg
                    luckAvgCount = luckAvgCount + 1
                    if r.luckAvg < luckMin then luckMin = r.luckAvg end
                    if r.luckAvg > luckMax then luckMax = r.luckAvg end
                end
            end
            local avgBossDmg = (bossDamageCount > 0)
                and (bossDamageSum / bossDamageCount)
                or 0
            local sweepAvgLuck = (luckAvgCount > 0)
                and (luckAvgSum / luckAvgCount)
                or 0
            print("[Infinite] -------- LONG VALIDATE summary --------")
            print(("[Infinite]   loadout: %s + %s + %s + %s"):format(
                coreId, auxIds[1], auxIds[2], auxIds[3]))
            print(("[Infinite]   runs reaching phase 1 / 2 / 3 / 4 : %d / %d / %d / %d  (of %d)"):format(
                clearedToPhase[1], clearedToPhase[2], clearedToPhase[3], clearedToPhase[4], LONG_RUNS))
            print(("[Infinite]   phase-4 boss damage avg: %.0f over %d run(s)"):format(
                avgBossDmg, bossDamageCount))
            if luckAvgCount > 0 then
                print(("[Infinite]   luck avg: %.2f  (min %.2f / max %.2f)  — 2.71 = expected baseline; >2.71 = high-rarity rolls"):format(
                    sweepAvgLuck, luckMin, luckMax))
            end
            print("[Infinite] -------- end LONG VALIDATE --------")
        end)
    end)

    -- ea3-110 SPOT CHECK — runs a small fixed slate of 3-aux loadouts
    -- through paired Core-only / ALL-TOWER combos at the current
    -- Pickle Lord HP. Purpose: verify the 50%-Core-only-kill target
    -- isn't Pepper+Honey+Pace specific.
    --
    -- Slate (4 loadouts × 3 combos = 12 combos ≈ 45 min wall at 20×):
    --   1. Meta baseline           — Pepper + Honey + Pace
    --   2. AOE-heavy / no-Pepper   — Spore + Bloodlink + Spyglass
    --   3. Alt DPS + alt Control   — Lightning + Frost + PowerSeed
    --   4. Chaff focus             — Thorn + Root + Mortar
    -- Per loadout: 3 combos with lock policy CORE / ALL / CORE so each
    -- loadout has 2 Core-only samples (the canonical mode) + 1 ALL
    -- sample. Total Core-only samples = 8 (across 4 loadouts) — same
    -- count as LONG VALIDATE × 8 had, just spread across builds.
    local SPOT_CHECK_LOADOUTS = {
        { core = "Power", aux = { "PepperCannon",    "HoneyHive",     "PaceFlower"     }, label = "meta (Pepper+Honey+Pace)" },
        { core = "Power", aux = { "SporePuffball",   "BloodlinkVine", "SpyglassRoot"   }, label = "AOE+support (no Pepper)"  },
        { core = "Power", aux = { "LightningRadish", "FrostMelon",    "PowerSeed"      }, label = "alt DPS + alt Control"    },
        { core = "Power", aux = { "ThornVine",       "RootSprout",    "MushroomMortar" }, label = "chaff focus (3× D-tier)"  },
    }
    local SPOT_CHECK_COMBOS_PER_LOADOUT = 3
    local SPOT_CHECK_LOCK_PATTERN = { false, true, false }  -- Core / ALL / Core

    local arenaSpotCheck = Remotes.getOrCreate(Remotes.Names.InfiniteArenaSpotCheck, "RemoteEvent")
    arenaSpotCheck.OnServerEvent:Connect(function(player)
        if not arenaGuards(player, "ARENA SPOT CHECK") then return end
        local totalCombos = #SPOT_CHECK_LOADOUTS * SPOT_CHECK_COMBOS_PER_LOADOUT
        print(("[Infinite] %s starting ARENA SPOT CHECK — %d loadouts × %d combos = %d combos"):format(
            player.Name, #SPOT_CHECK_LOADOUTS, SPOT_CHECK_COMBOS_PER_LOADOUT, totalCombos))
        autoFireRunSimAllCores(player)
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))
        task.spawn(function()
            -- ea3-113: tightened from 220 to match the observed ~50s wall
            -- per 4-phase combo at 20× game speed (was over-estimating by
            -- ~4×). See LONG VALIDATE block for the reasoning.
            local PER_COMBO_SEC = 60
            local totalSec = PER_COMBO_SEC * totalCombos
            local sweepStartedAt = os.clock()
            -- Per-loadout result accumulator: { [li] = { results = {...} } }
            local perLoadout = {}
            for li = 1, #SPOT_CHECK_LOADOUTS do perLoadout[li] = { results = {} } end
            local aborted = false
            local comboIdx = 0
            for li, lo in ipairs(SPOT_CHECK_LOADOUTS) do
                if aborted then break end
                print(("[Infinite] SPOT CHECK loadout %d / %d: %s + %s + %s + %s  (%s)"):format(
                    li, #SPOT_CHECK_LOADOUTS, lo.core, lo.aux[1], lo.aux[2], lo.aux[3], lo.label))
                for ci = 1, SPOT_CHECK_COMBOS_PER_LOADOUT do
                    comboIdx += 1
                    local lockAll = SPOT_CHECK_LOCK_PATTERN[ci] == true
                    print(("[Infinite] SPOT CHECK combo %d / %d START%s  (loadout %d/%d run %d/%d)"):format(
                        comboIdx, totalCombos,
                        lockAll and " (ALL-TOWER lock)" or " (Core-only lock)",
                        li, #SPOT_CHECK_LOADOUTS, ci, SPOT_CHECK_COMBOS_PER_LOADOUT))
                    local r = ArenaSweepRunner.runOneCombo(player, {
                        coreId = lo.core,
                        auxIds = lo.aux,
                        autoPickerOpts = { mode = "random" },
                        progressLabel    = ("SPOT %d/%d"):format(comboIdx, totalCombos),
                        totalEstimateSec = totalSec,
                        sweepStartedAt   = sweepStartedAt,
                        lockAllTowersOnBoss = lockAll,
                    }, {})
                    table.insert(perLoadout[li].results, { r = r, lockAll = lockAll })
                    local lockTag = lockAll and "ALL" or "Core"
                    local p4Dmg   = r and r.phaseResults and r.phaseResults[4] and r.phaseResults[4].bossDamageDealt
                    local luckAvg = r and r.luckAvg
                    print(("[Infinite] SPOT CHECK combo %d / %d END — finalPhase=%s lock=%s bossDmg=%s luckAvg=%.2f (n=%d)"):format(
                        comboIdx, totalCombos, tostring(r and r.finalPhase), lockTag,
                        p4Dmg and tostring(math.floor(p4Dmg + 0.5)) or "—",
                        luckAvg or 0, (r and r.luckCount) or 0))
                    if r and r.aborted then
                        print(("[Infinite] SPOT CHECK aborted at combo %d / %d"):format(comboIdx, totalCombos))
                        aborted = true
                        break
                    end
                end
            end
            -- Summary: per-loadout breakdown so the analyst can compare
            -- Core-only kill rate across the slate at a glance.
            local pl = Config.Map3 and Config.Map3.PickleLord
            local bossHp = (pl and pl.Hp) or 0
            print(("[Infinite] -------- SPOT CHECK summary (Pickle Lord HP = %d) --------"):format(bossHp))
            for li, lo in ipairs(SPOT_CHECK_LOADOUTS) do
                local entries = perLoadout[li].results
                if #entries == 0 then
                    print(("[Infinite]   loadout %d (%s): no runs (aborted before start)"):format(li, lo.label))
                else
                    local coreKills, coreCount = 0, 0
                    local allKills,  allCount  = 0, 0
                    local coreDmgSum, allDmgSum = 0, 0
                    for _, e in ipairs(entries) do
                        local r = e.r
                        local p4 = r and r.phaseResults and r.phaseResults[4]
                        local dmg = (p4 and p4.bossDamageDealt) or 0
                        local killed = (bossHp > 0) and (dmg >= bossHp)
                        if e.lockAll then
                            allCount += 1; allDmgSum += dmg
                            if killed then allKills += 1 end
                        else
                            coreCount += 1; coreDmgSum += dmg
                            if killed then coreKills += 1 end
                        end
                    end
                    local coreAvg = (coreCount > 0) and (coreDmgSum / coreCount) or 0
                    local allAvg  = (allCount  > 0) and (allDmgSum  / allCount)  or 0
                    print(("[Infinite]   loadout %d (%s):"):format(li, lo.label))
                    print(("[Infinite]     %s + %s + %s + %s"):format(
                        lo.core, lo.aux[1], lo.aux[2], lo.aux[3]))
                    print(("[Infinite]     Core-only:  %d/%d kills  avg dmg %.0f / %d (%.0f%%)"):format(
                        coreKills, coreCount, coreAvg, bossHp,
                        bossHp > 0 and (coreAvg / bossHp * 100) or 0))
                    print(("[Infinite]     ALL-TOWER:  %d/%d kills  avg dmg %.0f / %d (%.0f%%)"):format(
                        allKills, allCount, allAvg, bossHp,
                        bossHp > 0 and (allAvg / bossHp * 100) or 0))
                end
            end
            print("[Infinite] -------- end SPOT CHECK --------")
        end)
    end)

    -- ea3-116 FAILURE CURVE × 105 — wave-1..28 ramping failure-curve
    -- sweep using AutoPlaceStrategy for placement. Replaces the legacy
    -- autoRunRemote-based FAILURE SWEEP × 105 stopgap (which used the
    -- hand-tuned INFINITE_PATTERN slot table that was demonstrably
    -- worse — see memory project_failure_curve_v2.md and the
    -- 2026-04-30 cyan-circle-vs-red-square screenshot).
    --
    -- Same queue as buildAutoRunQueue: 14 solos + C(14,2) = 91 duos =
    -- 105. Each loadout climbs waves 1..MaxAutoRunWave with HP scaling
    -- per Config.InfiniteArena.WaveHpRamp until heart-death; captures
    -- fractional finalWave; flushes into cumulativeResults so the
    -- existing runSimForCore validator hookup digests the data
    -- automatically.
    --
    -- Per Matthew 2026-04-30: "I always prefer a longer term solution"
    -- — ditched the legacy auto-run port in favor of this rebuild that
    -- shares ArenaSweepRunner's lifecycle (Map4ArenaSweepActive flag,
    -- cooperative abort, env-cull, banner-suppress, ETA bar).
    -- ea3-133: per-Core failure-curve helper extracted from the
    -- FAILURE CURVE × 105 handler so SUPER FAILURE CURVE × 315 can
    -- reuse the same flush-and-checkpoint logic per Core. Returns
    -- summary { results, observedPerComboSec, completedCombos }.
    --
    -- Per-combo checkpointing: the onResult hook stamps each entry
    -- with currentBalanceVersion + appends to cumulativeResults +
    -- calls saveCumulative every CHECKPOINT_EVERY combos. Studio
    -- crashes mid-sweep now preserve completed work (was: lose all
    -- 315 results if Studio drops at combo 200). Cost: extra
    -- DataStore writes (every 10 combos × 50s = ~8 min apart, well
    -- inside the 60s SetAsync throttle). Per Matthew 2026-04-30:
    -- "add saves in case of failure too" alongside the SUPER
    -- FAILURE CURVE rebuild ask.
    local CHECKPOINT_EVERY = 10
    local function runFailureCurveForCore(player, coreId, timingHint)
        local queue = buildAutoRunQueue(coreId)
        print(("[Infinite] %s starting FAILURE CURVE (core=%s) — %d loadouts"):format(
            player.Name, coreId, #queue))
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))

        -- Track how many results we've already pushed to
        -- cumulativeResults so on-finalize we don't double-append.
        local checkpointedCount = 0
        local function onResult(entry, idx, total)
            entry.balanceVersion = currentBalanceVersion
            table.insert(cumulativeResults, entry)
            checkpointedCount = checkpointedCount + 1
            -- Periodic flush to DataStore. Floor on idx so the FINAL
            -- combo always triggers a save even if not aligned with
            -- the modulo (caught by the after-loop saveCumulative
            -- below as a belt-and-suspenders).
            if (checkpointedCount % CHECKPOINT_EVERY) == 0 then
                InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
                print(("[Infinite] FAILURE CURVE checkpoint %d/%d (core=%s) — pool=%d"):format(
                    idx, total, coreId, #cumulativeResults))
            end
        end

        local summary = ArenaSweepRunner.runFailureCurveSweep(player, {
            coreId           = coreId,
            queue            = queue,
            autoPickerOpts   = { mode = "random" },
            perComboSecHint  = timingHint,
        }, {
            shouldAbort = ArenaSweepRunner.isAborted,
            onResult    = onResult,
        })

        local results = (summary and summary.allResults) or {}
        print(("[Infinite] FAILURE CURVE complete (core=%s) — %d / %d combos"):format(
            coreId, #results, #queue))

        -- Final flush guarantees the last partial-batch lands in
        -- DataStore even if it didn't trigger a checkpoint mod-hit.
        if checkpointedCount > 0 then
            InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
        end

        return summary
    end

    -- ea3-133: shared post-sweep finalize for both FAILURE CURVE and
    -- SUPER FAILURE CURVE. Persists timing hint, fires sim/validator
    -- per Core (which prints SIM tier + REAL tier with stats — see
    -- runSimForCore in this file). Caller passes the LAST Core's
    -- summary for timing-hint persistence and the player for the
    -- sim broadcast.
    local function finalizeFailureCurveRun(player, lastSummary)
        if lastSummary and lastSummary.observedPerComboSec
            and (lastSummary.completedCombos or 0) >= 5
        then
            InfiniteRunHistoryStore.saveTimingHint(
                "failureCurve", lastSummary.observedPerComboSec)
            print(("[Infinite] FAILURE CURVE timing calibrated: %.1f s/combo (over %d combos)"):format(
                lastSummary.observedPerComboSec, lastSummary.completedCombos))
        end
        for _, coreId in ipairs(CoreTypes.Ids) do
            simulatedSweep = runSimForCore(coreId, true)
            simulateDataRemote:FireClient(player, simulatedSweep)
        end
        InfiniteRunHistoryStore.saveSim(simulatedSweepByCore)
    end

    local arenaFailureCurve = Remotes.getOrCreate(
        Remotes.Names.InfiniteArenaFailureCurve, "RemoteEvent")
    arenaFailureCurve.OnServerEvent:Connect(function(player)
        if not arenaGuards(player, "ARENA FAILURE CURVE") then return end
        local sweepCoreId = State.preferredCoreId or "Power"
        player:SetAttribute("PreferredCoreId", sweepCoreId)
        persistCorePreference(player, sweepCoreId)
        -- ea3-119: seed the ETA bar from the persisted observed
        -- average of the prior completed sweep. First-ever boot has
        -- no hint on file → ArenaSweepRunner falls back to 60s.
        local timingHint = InfiniteRunHistoryStore.loadTimingHint("failureCurve")
        if timingHint then
            print(("[Infinite] FAILURE CURVE seed: using persisted avg %.1f s/combo"):format(timingHint))
        else
            print("[Infinite] FAILURE CURVE seed: no calibration on file (first sweep) — using 60 s/combo default")
        end
        autoFireRunSimAllCores(player)
        task.spawn(function()
            local summary = runFailureCurveForCore(player, sweepCoreId, timingHint)
            if not summary or (summary.completedCombos or 0) == 0 then return end
            finalizeFailureCurveRun(player, summary)
        end)
    end)

    -- ea3-133: SUPER FAILURE CURVE × 315 — three FAILURE CURVE × 105
    -- sweeps back-to-back (Power → ControlCore → SupportCore). Same
    -- wave-1..28 force-failure pipeline as the single-Core sweep,
    -- so every loadout produces a clean fractional finalWave (no
    -- wave-30-cap saturation hiding top-end dominance — the actual
    -- gap was the original SUPER AUTO mode). Designed for overnight
    -- balance-validation: ~4.4 hours runtime, per-combo checkpoint
    -- preserves work on Studio drop, all 3 Cores covered in one go.
    --
    -- Cooperative abort: ArenaSweepRunner.isAborted is checked at
    -- the start of each Core, so STOP between Cores aborts the
    -- run cleanly. Mid-Core STOP is handled by the existing
    -- runFailureCurveSweep abort path.
    local arenaSuperFailureCurve = Remotes.getOrCreate(
        Remotes.Names.InfiniteArenaSuperFailureCurve, "RemoteEvent")
    arenaSuperFailureCurve.OnServerEvent:Connect(function(player)
        if not arenaGuards(player, "ARENA SUPER FAILURE CURVE") then return end
        -- Honor preferred Core for ordering: start with the player's
        -- preferred Core so they get the most-relevant data first
        -- if the run aborts mid-loop. Other Cores follow.
        local preferred = State.preferredCoreId or "Power"
        player:SetAttribute("PreferredCoreId", preferred)
        persistCorePreference(player, preferred)
        local coreOrder = { preferred }
        for _, c in ipairs(CoreTypes.Ids) do
            if c ~= preferred then table.insert(coreOrder, c) end
        end
        local timingHint = InfiniteRunHistoryStore.loadTimingHint("failureCurve")
        if timingHint then
            print(("[Infinite] SUPER FAILURE CURVE seed: using persisted avg %.1f s/combo"):format(timingHint))
        else
            print("[Infinite] SUPER FAILURE CURVE seed: no calibration on file — using 60 s/combo default")
        end
        print(("[Infinite] %s starting SUPER FAILURE CURVE — 3 cores × 105 = 315 loadouts (order: %s → %s → %s)"):format(
            player.Name, coreOrder[1], coreOrder[2], coreOrder[3]))
        autoFireRunSimAllCores(player)
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))
        task.spawn(function()
            local lastSummary = nil
            for i, coreId in ipairs(coreOrder) do
                if ArenaSweepRunner.isAborted() then
                    print(("[Infinite] SUPER FAILURE CURVE aborted before core %d/%d (%s)"):format(
                        i, #coreOrder, coreId))
                    break
                end
                print(("[Infinite] SUPER FAILURE CURVE — starting Core %d/3 (%s)"):format(i, coreId))
                lastSummary = runFailureCurveForCore(player, coreId, timingHint)
                -- Refresh timingHint from this Core's actual observed
                -- average so the NEXT Core's ETA bar starts calibrated
                -- (subsequent Cores share the same per-combo cost).
                if lastSummary and lastSummary.observedPerComboSec then
                    timingHint = lastSummary.observedPerComboSec
                end
            end
            print(("[Infinite] SUPER FAILURE CURVE complete — pool=%d"):format(#cumulativeResults))
            if lastSummary and (lastSummary.completedCombos or 0) > 0 then
                finalizeFailureCurveRun(player, lastSummary)
            end
        end)
    end)

    -- ea3-125 TARGETED × 15 — variance-driven shorter sweep. Reads
    -- the latest validator report's perLoadout entries, sorts by
    -- |delta| descending, queues the top 15 combos through the same
    -- wave-1..28 ramp pipeline as FAILURE CURVE × 105.
    --
    -- The "highest information value" combos are the ones where the
    -- closed-form sim is most wrong about a tower's contribution —
    -- re-testing them moves the model the most when calibration
    -- knobs change. Compared to FAILURE CURVE × 105 (45-60 min), this
    -- runs ~10-12 min so the "tune → re-test → see if delta closed"
    -- loop tightens dramatically.
    --
    -- No-ops if no validator report is on file (first boot, or
    -- post-BALANCE RESET before any sweep). Caller (client) always
    -- enables the row; server warns + bails so the analyst sees why
    -- nothing happened. Per Matthew "yellow TARGETED button [...]
    -- highest information value combinations".
    local TARGETED_TOP_N = 15
    local arenaTargeted = Remotes.getOrCreate(
        Remotes.Names.InfiniteArenaTargeted, "RemoteEvent")
    arenaTargeted.OnServerEvent:Connect(function(player)
        if not arenaGuards(player, "ARENA TARGETED") then return end
        local sweepCoreId = State.preferredCoreId or "Power"
        player:SetAttribute("PreferredCoreId", sweepCoreId)
        persistCorePreference(player, sweepCoreId)

        -- Read validator perLoadout from the most recent sim record
        -- for the active Core. If runSimForCore hasn't been called
        -- this session (or post-BALANCE RESET), simulatedSweepByCore
        -- is empty; warn + bail so the analyst sees what's missing.
        local simRecord = simulatedSweepByCore[sweepCoreId]
        local validation = simRecord and simRecord.validation
        if not validation or type(validation.perLoadout) ~= "table"
            or #validation.perLoadout == 0
        then
            warn(("[Infinite] TARGETED rejected — no validator report on file for core=%s. Run RUN SIM (or any sweep) first to populate the perLoadout deltas."):format(sweepCoreId))
            return
        end

        local topRows = InfiniteValidator.topByDelta(validation, TARGETED_TOP_N)
        if #topRows == 0 then
            warn("[Infinite] TARGETED rejected — validator report had perLoadout entries but topByDelta returned empty (likely all entries had no real backing). Run FAILURE CURVE × 105 first.")
            return
        end

        -- Build a FAILURE CURVE-shaped queue: { { auxIds, label }, ... }.
        local queue = {}
        for _, row in ipairs(topRows) do
            table.insert(queue, {
                auxIds = row.auxIds,
                label  = row.label or ("%s + %s"):format(
                    sweepCoreId, table.concat(row.auxIds, " + ")),
            })
        end

        -- Seed ETA from the FAILURE CURVE timing hint — TARGETED
        -- shares its per-combo wall-time profile (same pipeline,
        -- same setup/teardown). Saves us a separate calibration key.
        local timingHint = InfiniteRunHistoryStore.loadTimingHint("failureCurve")
        if timingHint then
            print(("[Infinite] TARGETED seed: using failureCurve avg %.1f s/combo"):format(timingHint))
        else
            print("[Infinite] TARGETED seed: no calibration on file — using 60 s/combo default")
        end

        -- Print the selected combos so the analyst can see WHY each
        -- was picked (sim/real/delta) — same idea as FAILURE CURVE's
        -- start-of-sweep loadout dump but with delta context.
        print(("[Infinite] %s starting ARENA TARGETED — top %d worst-|delta| combos (core=%s):"):format(
            player.Name, #queue, sweepCoreId))
        for i, row in ipairs(topRows) do
            print(("[Infinite]   %2d. %-40s  sim=%.2f  real=%.2f  delta=%+.2f  (n=%d)"):format(
                i,
                row.label or table.concat(row.auxIds, "+"),
                row.simWave or 0,
                row.realAvgWave or 0,
                row.delta or 0,
                row.realRuns or 0))
        end

        autoFireRunSimAllCores(player)
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))
        task.spawn(function()
            local summary = ArenaSweepRunner.runFailureCurveSweep(player, {
                coreId           = sweepCoreId,
                queue            = queue,
                autoPickerOpts   = { mode = "random" },
                perComboSecHint  = timingHint,
            }, {
                shouldAbort = ArenaSweepRunner.isAborted,
            })
            local results = (summary and summary.allResults) or {}
            print(("[Infinite] ARENA TARGETED complete — %d / %d combos"):format(
                #results, #queue))

            if #results == 0 then return end

            -- Stamp + flush to cumulative pool, mirror of FAILURE CURVE.
            for _, r in ipairs(results) do
                r.balanceVersion = currentBalanceVersion
            end
            for _, r in ipairs(results) do
                table.insert(cumulativeResults, r)
            end
            InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
            print(("[Infinite] TARGETED flushed %d results to cumulative pool (%d total)"):format(
                #results, #cumulativeResults))

            -- Re-fire sim per Core so the F9 dump shows the freshly
            -- recomputed deltas. Same skipPersist=true + final flush
            -- pattern as FAILURE CURVE.
            for _, coreId in ipairs(CoreTypes.Ids) do
                simulatedSweep = runSimForCore(coreId, true)
                simulateDataRemote:FireClient(player, simulatedSweep)
            end
            InfiniteRunHistoryStore.saveSim(simulatedSweepByCore)
        end)
    end)

    -- SUPER AUTORUN — full coverage 1092-combo sweep.
    arenaSuperAutorun.OnServerEvent:Connect(function(player)
        if not arenaGuards(player, "ARENA SUPER AUTORUN") then return end
        print(("[Infinite] %s starting ARENA SUPER AUTORUN (full coverage)"):format(player.Name))
        autoFireRunSimAllCores(player)
        local ArenaSweepRunner = require(script.Parent:WaitForChild("ArenaSweepRunner"))
        task.spawn(function()
            local summary = ArenaSweepRunner.runFullCoverageSweep(player, {
                autoPickerOpts = { mode = "random" },
            }, {})
            print(("[Infinite] ARENA SUPER AUTORUN complete — %d combos done"):format(
                #(summary.allResults or {})))
        end)
    end)

    -- TOWER SUPER — zoom-in sweep on a single focus aux across
    -- 3 Cores × 5 rarities = 15 sub-sweeps. Each sub-sweep runs
    -- the SUPER AUTO sweep shape (solos + duos + curated trios)
    -- filtered to combos containing the focus aux.
    -- Per Matthew 2026-04-29 ea3-24: "add a new TOWER SUPER button
    -- at the top of simulate to allow zooming in on one tower."
    --
    -- Payload: { focusAuxId = "BlinkBerry" }
    --
    -- Use case: per-tower deep-dive after a balance change. Drops
    -- one consolidated stat-pool covering every (Core, rarity)
    -- combination for the chosen aux without the analyst manually
    -- re-firing SELECT AUTO 15 times.
    towerSuperRemote.OnServerEvent:Connect(function(player, payload)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested TOWER SUPER but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested TOWER SUPER but a sweep is already in progress (%d/%d)")
                :format(player.Name, #(autoRun.results or {}), autoRun.total))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested TOWER SUPER but another player is in a run"):format(player.Name))
            return
        end

        -- Validate focus aux. Must be a real aux template id and
        -- not the standardization anchor (which is sweep-internal).
        local focusAuxId
        if type(payload) == "table" and type(payload.focusAuxId) == "string" then
            focusAuxId = payload.focusAuxId
        end
        if not focusAuxId or not TempTowers.Templates[focusAuxId] then
            warn(("[Infinite] TOWER SUPER rejected — invalid focus aux: %s"):format(tostring(focusAuxId)))
            return
        end
        if focusAuxId == AUTO_RUN_ANCHOR then
            warn(("[Infinite] TOWER SUPER rejected — focus aux can't be the standardization anchor"))
            return
        end

        -- Build the 15-tuple Core × rarity queue. Order: each Core
        -- in CoreTypes.Ids order, each rarity in TempTowers.RarityOrder
        -- order. So Power runs Common→Mythical first, then Control,
        -- then Support — gives the analyst all 5 rarity datapoints
        -- per Core before moving on.
        local rarityCoreQueue = {}
        for _, coreId in ipairs(CoreTypes.Ids) do
            for _, rarity in ipairs(TempTowers.RarityOrder) do
                table.insert(rarityCoreQueue, {
                    coreId = coreId,
                    rarity = rarity,
                })
            end
        end

        -- Pop the first tuple to bootstrap the sweep. The remaining
        -- 14 tuples drain via the finalize() TOWER SUPER block.
        local firstTuple = table.remove(rarityCoreQueue, 1)
        local firstCore   = firstTuple.coreId
        local firstRarity = firstTuple.rarity
        local firstQueue  = buildTowerSuperQueue(firstCore, focusAuxId)
        if #firstQueue == 0 then
            warn(("[Infinite] TOWER SUPER rejected — no combos contain focus aux %s for Core %s"):format(
                focusAuxId, firstCore))
            return
        end

        -- Persist the player's first-tuple Core+rarity so subsequent
        -- enter() defaults pick them up.
        player:SetAttribute("PreferredCoreId", firstCore)
        persistCorePreference(player, firstCore)
        State.preferredRarity = firstRarity
        player:SetAttribute("PreferredRarity", firstRarity)

        autoRun.active     = true
        autoRun.queue      = firstQueue
        autoRun.results    = {}
        autoRun.total      = #firstQueue
        autoRun.continuous = false   -- TOWER SUPER is bounded; no continuous loop
        autoRun.sweepNum   = 1
        autoRun.coreId     = firstCore
        autoRun.isSuperAuto = nil    -- distinct from SUPER AUTO state
        autoRun.isTowerSuper = true
        autoRun.cumulativeFlushedIdx = 0
        autoRun.towerSuperFocusAux = focusAuxId
        autoRun.towerSuperRarityCoreQueue = rarityCoreQueue  -- 14 remaining tuples

        StatLedger.setRecordingEnabled(true)
        StatLedger.reset()

        local firstLoadout = table.remove(firstQueue, 1)
        autoRun.current = firstLoadout
        autoRunProgressRemote:FireClient(player, {
            current = 1,
            total   = autoRun.total,
            label   = firstLoadout.label,
        })
        print(("[Infinite] TOWER SUPER starting — focus=%s, sub-sweep 1/15 (%s + %s, %d loadouts)"):format(
            focusAuxId, firstCore, firstRarity, autoRun.total))
        enter(player, {
            auxIds = firstLoadout.auxIds,
            slider = #firstLoadout.auxIds,
            coreId = firstCore,
            rarity = firstRarity,
        })
    end)

    -- SELECT AUTO — sweeps pinned to the player's current saved
    -- loadout. Payload { coreId, lockedAuxIds }. Server validates +
    -- builds the appropriate queue (see buildSelectAutoQueue rules).
    -- Per Matthew 2026-04-28.
    --
    -- continuous = true (was false until 2026-04-28 dd). Same fix
    -- as FULL AUTO — monitor toggle defaults to CONTINUOUS, server
    -- flag must match. Sweep #1 = the SELECT-pinned narrow queue;
    -- sweep #2+ = top combos from cumulative pool descending. The
    -- pinned-aux runs from sweep #1 land in cumulative, so sweep
    -- #2 naturally re-sweeps the high performers among them
    -- (validates that the pinned anchor is genuinely strong, not
    -- just the third-slot variance).
    selectAutoRemote.OnServerEvent:Connect(function(player, payload)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested SELECT AUTO but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested SELECT AUTO but a sweep is already in progress (%d/%d)")
                :format(player.Name, #(autoRun.results or {}), autoRun.total))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested SELECT AUTO but another player is in a run"):format(player.Name))
            return
        end

        -- Extract + validate payload. 2026-04-29 ea3-9: K-locked cap
        -- raised 2 → 4 (slot 5 + 4 locked = single rotated aux per
        -- queue entry). Slot count comes through payload.slider so
        -- the every-combo math has both axes.
        local sweepCoreId
        local lockedAuxIds = {}
        local sliderValue
        if type(payload) == "table" then
            if type(payload.coreId) == "string" then
                sweepCoreId = payload.coreId
            end
            if type(payload.lockedAuxIds) == "table" then
                for _, id in ipairs(payload.lockedAuxIds) do
                    if type(id) == "string" then
                        table.insert(lockedAuxIds, id)
                    end
                end
            end
            if type(payload.slider) == "number" then
                sliderValue = math.clamp(math.floor(payload.slider), 0, 5)
            end
        end
        sweepCoreId = sweepCoreId or State.preferredCoreId or "Power"
        sliderValue = sliderValue or (#lockedAuxIds + 1)
        if #lockedAuxIds > 5 then
            warn(("[Infinite] %s SELECT AUTO rejected — too many locked auxes (%d > 5)")
                :format(player.Name, #lockedAuxIds))
            return
        end
        if #lockedAuxIds > sliderValue then
            warn(("[Infinite] %s SELECT AUTO rejected — locked count %d > slot count %d")
                :format(player.Name, #lockedAuxIds, sliderValue))
            return
        end

        player:SetAttribute("PreferredCoreId", sweepCoreId)
        persistCorePreference(player, sweepCoreId)
        local queue = buildSelectAutoQueue(sweepCoreId, lockedAuxIds, sliderValue)
        if #queue == 0 then
            warn(("[Infinite] %s requested SELECT AUTO but the queue is empty"):format(player.Name))
            return
        end
        autoRun.active     = true
        autoRun.queue      = queue
        autoRun.results    = {}
        autoRun.total      = #queue
        autoRun.continuous = true   -- matches monitor toggle's CONTINUOUS default (was false until dd)
        autoRun.sweepNum   = 1
        autoRun.coreId     = sweepCoreId

        StatLedger.setRecordingEnabled(true)
        StatLedger.reset()

        local firstLoadout = table.remove(queue, 1)
        autoRun.current = firstLoadout
        autoRunProgressRemote:FireClient(player, {
            current = 1,
            total   = autoRun.total,
            label   = firstLoadout.label,
        })
        print(("[Infinite] SELECT AUTO starting — %d loadouts queued (core=%s, locked=%s)")
            :format(autoRun.total, sweepCoreId, table.concat(lockedAuxIds, "+")))
        enter(player, {
            auxIds = firstLoadout.auxIds,
            slider = #firstLoadout.auxIds,
            coreId = sweepCoreId,
        })
    end)

    -- Admin panel default view: ALL RUNS cumulative aggregate
    -- across every sweep since BALANCE RESET. Per Matthew
    -- 2026-04-26: "the run stats + tier lists should be across
    -- every run unless balance reset is hit." Falls back to a
    -- single most-recent sweep if cumulative is empty (covers the
    -- fresh-server case where no sweep has run yet but lastSweep
    -- might have something the client wants to see).
    --
    -- Empty-state payload is { empty = true } so the client knows
    -- to show "no sweep yet" instead of "loading...".
    lastSweepReqRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if #cumulativeResults > 0 then
            local tiers = assembleTiers(cumulativeResults)
            lastSweepDataRemote:FireClient(player, {
                tiers        = tiers,
                results      = cumulativeResults,
                completedAt  = lastSweep and lastSweep.completedAt or os.time(),
                total        = #cumulativeResults,
                cumulative   = true,
                lastRunStats = lastRunStats,
            })
        elseif lastSweep then
            lastSweepDataRemote:FireClient(player, {
                tiers        = lastSweep.tiers,
                results      = lastSweep.results,
                completedAt  = lastSweep.completedAt,
                total        = lastSweep.total,
                aborted      = lastSweep.aborted,
                lastRunStats = lastRunStats,
            })
        else
            lastSweepDataRemote:FireClient(player, {
                empty        = true,
                lastRunStats = lastRunStats,  -- might still have manual-run stats
            })
        end
    end)

    -- BALANCE RESET: wipe the cumulative aggregate so the next
    -- sweep starts the tier list from zero. Doesn't touch the
    -- DataStore-backed sweep history (LOAD RUNS can still pull
    -- older sweeps individually). Persists the wipe so it sticks
    -- across server restarts. Bumps the balance-version counter
    -- so subsequent sweeps form a NEW era — past sweeps stay
    -- grouped under their old version in the LOAD RUNS picker.
    -- Per Matthew 2026-04-27: "every time balance reset is used
    -- increase the balance version # and start a new row."
    balanceResetRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local cleared = #cumulativeResults
        cumulativeResults = {}
        InfiniteRunHistoryStore.clearCumulative()
        currentBalanceVersion = InfiniteRunHistoryStore.bumpBalanceVersion()
        -- 2026-04-29 ea3-5: drop the per-Core sim cache too. The
        -- old sims compared against the old cumulative pool's
        -- balance — keeping them after a BALANCE RESET means the
        -- validator delta below is meaningless until the player
        -- re-runs SIMULATE. Cheaper to wipe + re-fire.
        simulatedSweep = nil
        simulatedSweepByCore = {}
        InfiniteRunHistoryStore.clearSim()
        -- ea3-125: drop in-memory VALIDATE history. The finalPhase
        -- observations were collected against the old balance — keeping
        -- them across a BALANCE RESET would mix eras in the variance
        -- printout.
        validateHistory = {}
        print(("[Infinite] %s wiped cumulative balance stats (%d run(s) cleared, persisted) + sim cache — new balance version = %d"):format(
            player.Name, cleared, currentBalanceVersion))
        lastSweepDataRemote:FireClient(player, {
            empty        = true,
            cumulative   = true,
            lastRunStats = lastRunStats,
        })
    end)

    -- Admin panel "LOAD RUNS" section: list past balance ERAS
    -- (one row per balanceVersion, regardless of how many sweeps
    -- ran in that era) from the DataStore-backed history. Per
    -- Matthew 2026-04-27: "change LOAD RUN to LOAD RUNS and have
    -- it load all runs from a given balance change. every time
    -- balance reset is used increase the balance version # and
    -- start a new row." Returns version-grouped metadata; full
    -- aggregated payload comes via InfiniteLoadByBalanceVersion
    -- when the user picks an era. Per-sweep `sweeps` field kept
    -- for legacy LOAD-by-idx callers (currently unused but the
    -- remote handler below still works).
    sweepHistoryReqRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local versionGroups = InfiniteRunHistoryStore.listByBalanceVersion()
        local sweeps        = InfiniteRunHistoryStore.list()
        sweepHistoryDataRemote:FireClient(player, {
            versionGroups         = versionGroups,
            currentBalanceVersion = currentBalanceVersion,
            -- Legacy compat — old client builds still read this.
            sweeps                = sweeps,
        })
    end)

    -- Legacy single-sweep loader (kept so older client builds
    -- don't break mid-rollout). New LOAD RUNS UI uses the
    -- balance-version path below.
    loadSweepByIdxRemote.OnServerEvent:Connect(function(player, payload)
        if not player or not player.Parent then return end
        if type(payload) ~= "table" or type(payload.idx) ~= "number" then return end
        local sweep = InfiniteRunHistoryStore.get(payload.idx)
        if not sweep then
            warn(("[Infinite] LOAD RUN: idx %d not found"):format(payload.idx))
            lastSweepDataRemote:FireClient(player, { empty = true })
            return
        end
        lastSweepDataRemote:FireClient(player, {
            tiers          = sweep.tiers,
            results        = sweep.results,
            completedAt    = sweep.completedAt,
            total          = sweep.total,
            aborted        = sweep.aborted,
            balanceVersion = sweep.balanceVersion,
            lastRunStats   = "(loaded from past sweep — StatLedger snapshot wasn't persisted)",
        })
        print(("[Infinite] LOAD RUN: %s loaded sweep idx %d (%d run(s))"):format(
            player.Name, payload.idx, (sweep.results and #sweep.results) or 0))
    end)

    -- LOAD RUNS pick: hydrate every sweep belonging to a single
    -- balance era into the existing tier-list display via the
    -- InfiniteLastSweepData channel. Server merges the era's
    -- sweeps (results concat, completedAt = newest) and runs
    -- assembleTiers over the combined result pool — that's what
    -- the picker row's count corresponds to.
    loadByVersionRemote.OnServerEvent:Connect(function(player, payload)
        if not player or not player.Parent then return end
        if type(payload) ~= "table" or type(payload.balanceVersion) ~= "number" then return end
        local merged = InfiniteRunHistoryStore.getByBalanceVersion(payload.balanceVersion)
        if not merged then
            warn(("[Infinite] LOAD RUNS: balance v%d has no sweeps"):format(payload.balanceVersion))
            lastSweepDataRemote:FireClient(player, { empty = true })
            return
        end
        local tiers = assembleTiers(merged.results)
        lastSweepDataRemote:FireClient(player, {
            tiers          = tiers,
            results        = merged.results,
            completedAt    = merged.completedAt,
            total          = #merged.results,
            aborted        = merged.aborted,
            balanceVersion = merged.balanceVersion,
            sweepCount     = merged.sweepCount,
            -- Reuse `cumulative=true` so the client's renderSweep
            -- treats this as an aggregate (drives the "ALL RUNS"
            -- morph + the prefix label).
            cumulative     = true,
            lastRunStats   = ("(loaded balance v%d — %d sweep(s), %d run(s) — StatLedger snapshot not persisted)")
                :format(merged.balanceVersion, merged.sweepCount, #merged.results),
        })
        print(("[Infinite] LOAD RUNS: %s loaded balance v%d (%d sweep(s), %d run(s))"):format(
            player.Name, merged.balanceVersion, merged.sweepCount, #merged.results))
    end)

    -- Player leaving mid-run cleanup: stop the spawner, clear mobs,
    -- print summary. Otherwise the spawner keeps spawning into an
    -- empty map4 with no audience until the heart eventually dies.
    -- If an AUTO RUN sweep is in progress, also abort the queue +
    -- print partial tier list so the run isn't wasted entirely.
    Players.PlayerRemoving:Connect(function(player)
        if State.activePlayer == player then
            print(("[Infinite] %s left mid-run — tearing down"):format(player.Name))
            if autoRun.active then
                print(("[Infinite] AUTO RUN aborted (player left) after %d/%d run(s)"):format(
                    #(autoRun.results or {}), autoRun.total))
                if autoRun.results and #autoRun.results > 0 then
                    local tiers = assembleTiers(autoRun.results)
                    printTierList(tiers)
                    lastSweep = {
                        tiers          = tiers,
                        results        = autoRun.results,
                        completedAt    = os.time(),
                        total          = autoRun.total,
                        aborted        = true,
                        balanceVersion = currentBalanceVersion,
                    }
                end
                autoRun.active  = false
                autoRun.queue   = nil
                autoRun.current = nil
                autoRun.results = nil
                autoRun.total   = 0
                autoRun.isSuperAuto          = nil
                autoRun.isTowerSuper         = nil  -- 2026-04-29 ea3-24
                autoRun.towerSuperRarityCoreQueue = nil
                autoRun.towerSuperFocusAux   = nil
                autoRun.cumulativeFlushedIdx = nil
                StatLedger.setRecordingEnabled(false)
            elseif State.wave > 0 then
                print(("[Infinite] -------- run summary -------- "
                    .. "(player left at wave %d / %s)"):format(
                    State.wave, testTypeForWave(State.wave)))
                print(StatLedger.summary())
                StatLedger.reset()
            end
            stopSpawner()
            destroyMap4Towers(player)
            State.activePlayer = nil
            State.wave = 0
        end
    end)

    -- Idle entry is the canonical hub-portal target — dropping the
    -- player into Map 4 with no countdown / no spawner. The actual
    -- run starts via the in-arena LOADOUT button or AUTO RUN.
    -- ctx.enterInfinite is kept as an alias for back-compat with
    -- the dev ProximityPrompt path; it now points at idle entry.
    ctx.enterIdleInfinite = enterIdle
    ctx.enterInfinite     = enterIdle
    ctx.exitInfinite      = exit

    -- Character respawn → clear InfiniteInArena. DevReset, death,
    -- or any generic respawn fires CharacterAdded; the new character
    -- spawns at SpawnLocation in the hub, NOT inside Map 4. Without
    -- this hook the attribute would stay true and the next portal
    -- touch would no-op. Also stop any in-flight spawner so it
    -- doesn't keep spawning into an empty arena. (Matthew
    -- 2026-04-26: "after reset port to swamp is broken".)
    -- hydrateCorePreference — load the player's last-saved Core
    -- archetype from DataStore + stamp it on State + a player
    -- attribute the loadout picker reads to pre-select. Per Matthew
    -- 2026-04-28. Spawned in a task so the DataStore round-trip
    -- doesn't block PlayerAdded handlers downstream.
    local function hydrateCorePreference(player)
        task.spawn(function()
            local saved = loadCorePreference(player)
            State.preferredCoreId = saved
            player:SetAttribute("PreferredCoreId", saved)
            print(("[Infinite] %s preferred Core hydrated: %s"):format(player.Name, saved))
        end)
    end

    Players.PlayerAdded:Connect(function(player)
        hydrateCorePreference(player)
        player.CharacterAdded:Connect(function()
            if player:GetAttribute("InfiniteInArena") then
                player:SetAttribute("InfiniteInArena", false)
                if State.activePlayer == player then
                    print(("[Infinite] %s respawned mid-run — tearing down"):format(player.Name))
                    if autoRun.active then
                        autoRun.active  = false
                        autoRun.queue   = nil
                        autoRun.current = nil
                        autoRun.results = nil
                        autoRun.total   = 0
                    end
                    stopSpawner()
                    State.activePlayer = nil
                    State.wave = 0
                end
            end
        end)
    end)
    -- Also cover players already in-game when this script reloads
    -- (Studio sync-on-save reuses existing Player objects).
    for _, player in ipairs(Players:GetPlayers()) do
        hydrateCorePreference(player)
        if player.Character then
            -- If they already have a character and the attribute is
            -- somehow set, treat as "respawned" to clear cleanly.
            if player:GetAttribute("InfiniteInArena") then
                player:SetAttribute("InfiniteInArena", false)
            end
        end
        player.CharacterAdded:Connect(function()
            if player:GetAttribute("InfiniteInArena") then
                player:SetAttribute("InfiniteInArena", false)
            end
        end)
    end

    -- ea3-115 LEGACY-AUTORUN cleanup hookup (still needed in ea3-116).
    -- Map4ArenaSweepActive drives three downstream systems that were
    -- originally only wired into the ArenaSweepRunner code path: (1)
    -- Map4 environment culling (Map4.lua:1003 — hides steam clouds,
    -- pickle trees, etc), (2) GameOverBanner suppression + auto-clear
    -- (GameOverBanner.lua — kills the "RETURN TO HUB" ghost), (3)
    -- WaveSystem pause-on-zero guard (WaveSystem:502).
    --
    -- v2 (ea3-116 FAILURE CURVE) sets the flag itself via the
    -- ArenaSweepRunner pattern, so this watcher is mostly dormant for
    -- v2. But the LEGACY autoRun.active flag is still set by other
    -- still-user-facing paths — TOWER SUPER, CORE AUTO, and the
    -- handful of admin / dev re-entry handlers in the 2496..4192
    -- range — that don't go through ArenaSweepRunner. The watcher
    -- keeps env-cull / banner-suppress engaged across all of them.
    --
    -- Implementation: a single task.spawn watcher polls autoRun.active
    -- every 0.4s and syncs the workspace flag. Defensive against
    -- ArenaSweepRunner ALSO setting the flag — we only set TRUE when
    -- legacy is the source of the change (so we never stomp arena's
    -- true→false on its own teardown), and we only set FALSE when
    -- arena is also inactive. Net: flag is TRUE if either sweeper is
    -- running, FALSE only when both are idle.
    task.spawn(function()
        while true do
            local legacyActive = autoRun.active == true
            local arenaActive = ctx.isArenaSweepActive
                and ctx.isArenaSweepActive() or false
            local desired = legacyActive or arenaActive
            local current = Workspace:GetAttribute("Map4ArenaSweepActive") == true
            if desired ~= current then
                -- Only flip when WE own the flag — i.e. when legacy is
                -- the source of the flip. If arena owns the change
                -- (arenaActive matches current), don't touch it.
                if legacyActive ~= current then
                    Workspace:SetAttribute("Map4ArenaSweepActive", desired)
                end
            end
            task.wait(0.4)
        end
    end)

    print("[Infinite] system online (Workspace.InfiniteUnlocked = "
        .. tostring(Workspace:GetAttribute("InfiniteUnlocked")) .. ")")
end

return Infinite
