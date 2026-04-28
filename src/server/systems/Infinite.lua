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
    if ok and type(val) == "string"
       and (val == "Power" or val == "ControlCore" or val == "SupportCore") then
        return val
    end
    return "Power"
end
local function persistCorePreference(player: Player, coreId: string?)
    if not CORE_PREF_STORE_OK or not corePrefStore then return end
    if type(coreId) ~= "string" then return end
    if coreId ~= "Power" and coreId ~= "ControlCore" and coreId ~= "SupportCore" then
        return
    end
    pcall(function()
        corePrefStore:SetAsync("Player_" .. player.UserId, coreId)
    end)
end

local Infinite = {}

-- Cinematic timing
local ENTRY_FADE_OUT_SEC = 0.8
local EXIT_FADE_OUT_SEC  = 0.6

-- Lazy-wired return portal
local returnPortalSetup = false

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
local simulatedSweep = nil :: { any }?

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
-- buildSelectAutoQueue — sweep generator pinned to the player's
-- currently saved loadout. Per Matthew 2026-04-28 SIMULATE menu:
--   • 0 locked auxes: same as AUTO RUN (solos + duos), no trios
--   • 1 locked aux:  all duos containing that aux (Core+aux+other,
--                     iterate "other" over the remaining 13 auxes)
--   • 2 locked auxes: all triples containing both locked auxes
--                     (Core+a+b+third, iterate "third" over the
--                     remaining 12 auxes)
--   • 3+ locked:     returns empty queue (rejected upstream too)
-- The anchor (InfiniteStandard) is excluded from the iteration set
-- since it's a benchmark standardization tower — same rule as
-- buildAutoRunQueue.
------------------------------------------------------------
local function buildSelectAutoQueue(coreId: string?, lockedAuxIds: { string }?): { { auxIds: { string }, label: string } }
    coreId = coreId or "Power"
    lockedAuxIds = lockedAuxIds or {}

    if #lockedAuxIds == 0 then
        return buildAutoRunQueue(coreId)
    end
    if #lockedAuxIds >= 3 then
        return {}  -- caller should have greyed the button; defensive
    end

    -- Validate locked entries: must be known tower ids, not the anchor.
    local lockedSet = {}
    for _, id in ipairs(lockedAuxIds) do
        if type(id) ~= "string" or not TempTowers.Templates[id] or id == AUTO_RUN_ANCHOR then
            warn(("[Infinite] SELECT AUTO: skipping invalid locked aux %s"):format(tostring(id)))
        else
            lockedSet[id] = true
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

    local rng = Random.new(os.time() * 1000 + math.floor(os.clock() * 1000) % 1000)
    local function shuffle(list)
        for i = #list, 2, -1 do
            local j = rng:NextInteger(1, i)
            list[i], list[j] = list[j], list[i]
        end
    end

    local queue = {}
    for _, otherId in ipairs(iterSet) do
        local auxIds = {}
        for _, id in ipairs(lockedAuxIds) do table.insert(auxIds, id) end
        table.insert(auxIds, otherId)
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
-- printTierList — server-log readable dump of the tier list.
-- Emitted at AUTO RUN finish; persistent run history lands later,
-- so for now the server log IS the tier-list display surface.
------------------------------------------------------------
local function printTierList(byRole: { [string]: { any } })
    print("[Infinite] -------- AUTO RUN tier list --------")
    for _, role in ipairs({"DPS", "Control", "Support"}) do
        local list = byRole[role] or {}
        if #list == 0 then
            print(("[Infinite]   %s: (no towers)"):format(role))
        else
            print(("[Infinite]   %s:"):format(role))
            for _, e in ipairs(list) do
                print(("[Infinite]     %s  %-18s  avg wave %5.2f over %d run(s)"):format(
                    e.tier, e.towerId, e.avgWave, e.runs))
            end
        end
    end
    print("[Infinite] -------- end tier list --------")
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
local function grantLoadout(player: Player, auxIds: { string }?, coreId: string?)
    -- Build a set of which aux IDs are picked for this run so we can
    -- set Equipped + stock in lockstep below.
    local picked: { [string]: boolean } = {}
    if auxIds then
        for _, towerId in ipairs(auxIds) do
            picked[towerId] = true
        end
    end
    local grantAll = (auxIds == nil)  -- dev shortcut: nil → equip all

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
        else
            player:SetAttribute(towerId .. "Stock", 0)
            player:SetAttribute(towerId .. "Equipped", false)
        end
    end
    -- Core grant: ONE core per run (Power / ControlCore / SupportCore
    -- per Matthew 2026-04-27). Default Power. Other cores get stock=0
    -- so the hotbar only shows the picked core's slot.
    coreId = coreId or "Power"
    for _, id in ipairs({ "Power", "ControlCore", "SupportCore" }) do
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

    player:SetAttribute("DoTStock", 0)
    player:SetAttribute("CCStock", 0)
    player:SetAttribute("CarryingAmmo", 0)
    player:SetAttribute("RerollTokens", 5)
    -- Mark "stock granted" so the client unhides the hotbar via the
    -- standard plumbing (TreeOfLife_Hub watches HasBeenGrantedStock).
    player:SetAttribute("HasBeenGrantedStock", true)
end

------------------------------------------------------------
-- Return portal (built lazily on first entry).
------------------------------------------------------------
local function setupReturnPortal(map4Room: Model, spawnCF: CFrame, exitCallback: (Player) -> ())
    if returnPortalSetup then return end
    returnPortalSetup = true
    local pos = spawnCF.Position + Vector3.new(6, -3, 0)
    local outerRing = Instance.new("Part")
    outerRing.Name = "ReturnPortalOuterRing"
    outerRing.Shape = Enum.PartType.Cylinder
    outerRing.Anchored = true
    outerRing.CanCollide = false
    outerRing.Size = Vector3.new(0.3, 14, 14)
    outerRing.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
    outerRing.Material = Enum.Material.Neon
    outerRing.Color = Color3.fromRGB(80, 220, 100)
    outerRing.Transparency = 0.35
    outerRing.Parent = map4Room

    local disc = Instance.new("Part")
    disc.Name = "ReturnPortalDisc"
    disc.Shape = Enum.PartType.Cylinder
    disc.Anchored = true
    disc.CanCollide = false
    disc.Size = Vector3.new(0.4, 10, 10)
    disc.CFrame = CFrame.new(pos + Vector3.new(0, 0.1, 0))
              * CFrame.Angles(0, 0, math.rad(90))
    disc.Material = Enum.Material.Neon
    disc.Color = Color3.fromRGB(60, 255, 110)
    disc.Transparency = 0.15
    disc.Parent = map4Room

    local labelAnchor = Instance.new("Part")
    labelAnchor.Name = "ReturnLabelAnchor"
    labelAnchor.Anchored = true
    labelAnchor.CanCollide = false
    labelAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
    labelAnchor.Transparency = 1
    labelAnchor.CFrame = CFrame.new(pos + Vector3.new(0, 6, 0))
    labelAnchor.Parent = map4Room
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.fromOffset(220, 50)
    billboard.LightInfluence = 0
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 200
    billboard.Parent = labelAnchor
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "RETURN TO HUB"
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 28
    label.TextColor3 = Color3.fromRGB(220, 255, 230)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.4
    label.Parent = billboard

    local lastExitAt = {}
    disc.Touched:Connect(function(other)
        if not other or not other.Parent then return end
        if other.Name ~= "HumanoidRootPart" then return end
        local player = Players:GetPlayerFromCharacter(other.Parent)
        if not player then return end
        local now = os.clock()
        if now - (lastExitAt[player.UserId] or 0) < 1.0 then return end
        lastExitAt[player.UserId] = now
        exitCallback(player)
    end)
    print("[Infinite] return portal wired in pickle dimension")
end

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

        print(("[Infinite] EXPORT DATA — %d cumulative runs, %d towers, %d pairs, full %d chars, summary %d chars"):format(
            #cumulativeResults,
            (function() local n = 0; for _ in pairs(towerAgg) do n = n + 1 end; return n end)(),
            (function() local n = 0; for _ in pairs(pairAgg) do n = n + 1 end; return n end)(),
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
                for _, r in ipairs(autoRun.results) do
                    table.insert(cumulativeResults, r)
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
    simulateRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local startWall = os.clock()
        -- Mirror the player's saved Core archetype into the sim
        -- queue's labels so SIM_vs_REAL deltas pair up correctly
        -- when the Core variant is being tested.
        local simCoreId = State.preferredCoreId or "Power"
        local queue = buildAutoRunQueue(simCoreId)
        local results = InfiniteSimulator.runSweep(queue, simCoreId)
        local elapsed = os.clock() - startWall

        local tiers = assembleTiers(results)
        print(("[Infinite] SIMULATE complete in %.3f s — %d loadouts evaluated"):format(
            elapsed, #results))
        print("[Infinite] -------- SIMULATED tier list (closed-form math; not validated) --------")
        printTierList(tiers)
        print("[Infinite] -------- end SIMULATED tier list --------")

        -- Sim-vs-real delta report (only meaningful if the player
        -- has accumulated some real sweeps; if cumulativeResults
        -- is empty every loadout is "untracked").
        local validationReport = InfiniteValidator.compare({
            sim           = results,
            real          = cumulativeResults,
            roleByTowerId = TempTowers.RoleByTowerId,
        })
        InfiniteValidator.printReport(validationReport)

        simulatedSweep = {
            tiers       = tiers,
            results     = results,
            completedAt = os.time(),
            total       = #results,
            simulated   = true,
            validation  = validationReport,
        }
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

        local touched = 0
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local model = base.Parent
            if model and model:IsA("Model") then
                local owner = model:GetAttribute("Owner")
                local anchorCol = model:GetAttribute("AnchorCol") or -1
                if owner == player.UserId and anchorCol >= map4ColOffset then
                    local towerType = model:GetAttribute("TowerType")
                    local fx = (towerType == "Power") and coreFx or auxFx
                    -- Damage: flat add. FireRate: % bump. Range: %
                    -- bump unless this category is range-capped.
                    local d = model:GetAttribute("Damage")
                    if type(d) == "number" then
                        model:SetAttribute("Damage", d + fx.damageDelta)
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
            for _, r in ipairs(autoRun.results) do
                table.insert(cumulativeResults, r)
            end
            -- Persist cumulative pool to DataStore so the tier list
            -- survives server restarts. SaveCumulative trims heavy
            -- statSummary text + caps at MAX_CUMULATIVE_RESULTS.
            InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
            -- Persist this individual sweep to history so LOAD RUN
            -- can pull it back across server restarts. (Trims
            -- statSummary text + caps at MAX_SWEEPS internally.)
            InfiniteRunHistoryStore.append(lastSweep)
            autoRunDoneRemote:FireClient(player, {
                results     = autoRun.results,
                tiers       = tiers,
                completedAt = lastSweep.completedAt,
                total       = autoRun.total,
            })
            -- Continuous-sweep loop: if STOP RUN hasn't been hit,
            -- rebuild the queue and kick off another sweep right
            -- away. Stat recording stays on; cumulative pool keeps
            -- growing. Per Matthew 2026-04-27: "run autorun
            -- continuously."
            if autoRun.continuous then
                autoRun.sweepNum = (autoRun.sweepNum or 0) + 1
                local newCoreId = autoRun.coreId or "Power"
                local newQueue = buildAutoRunQueue(newCoreId)
                autoRun.active  = true
                autoRun.queue   = newQueue
                autoRun.results = {}
                autoRun.total   = #newQueue
                local firstLoadout = table.remove(newQueue, 1)
                autoRun.current = firstLoadout
                autoRunProgressRemote:FireClient(player, {
                    current  = 1,
                    total    = autoRun.total,
                    label    = firstLoadout.label,
                    sweepNum = autoRun.sweepNum,
                })
                print(("[Infinite] AUTO RUN sweep #%d → starting next continuous sweep (%d loadouts, core=%s)")
                    :format(autoRun.sweepNum, autoRun.total, newCoreId))
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

            StatLedger.setRecordingEnabled(false)
            autoRun.queue      = nil
            autoRun.current    = nil
            autoRun.results    = nil
            autoRun.total      = 0
            autoRun.continuous = false
            autoRun.sweepNum   = 0
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

        -- Lazy-build the return portal (first entry only).
        if ctx.map4Room then
            setupReturnPortal(ctx.map4Room, getMap4SpawnCF(), exit)
        end

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
            for _, coreId in ipairs({ "Power", "ControlCore", "SupportCore" }) do
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
    enterPrepare = function(player: Player, opts: { auxIds: { string }?, coreId: string? }?)
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
        -- Stash the picked Core for the eventual GO call (enter()
        -- reads State.coreId for the auto-place pattern). Same
        -- field enter() sets, just one phase earlier.
        State.coreId = coreId
        grantLoadout(player, auxIds, coreId)
        -- Mark the SAVE so the next GO (enter() call without
        -- AUTO RUN active) skips the re-grant and preserves any
        -- manually-placed towers. Cleared in enter() below.
        State.savePending = true
        print(("[Infinite] %s SAVED loadout (core=%s, aux=%d) — placement enabled, waves NOT started")
            :format(player.Name, coreId, auxIds and #auxIds or 0))
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
        local sliderValue = math.clamp(opts.slider or 3, 0, 4)
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
            grantLoadout(player, auxIds, coreId)
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
        if type(payload.coreId) == "string"
           and (payload.coreId == "Power"
                or payload.coreId == "ControlCore"
                or payload.coreId == "SupportCore") then
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
                    for _, r in ipairs(autoRun.results) do
                        table.insert(cumulativeResults, r)
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
        print(("[Infinite] %s TOTAL RESET — cleared %d cumulative run(s) + DataStore history (persisted)")
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
    -- as AUTO RUN; differs only in queue source. Continuous = false
    -- because FULL AUTO is a one-shot end-to-end pass.
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
        autoRun.continuous = false
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

    -- SELECT AUTO — sweeps pinned to the player's current saved
    -- loadout. Payload { coreId, lockedAuxIds }. Server validates +
    -- builds the appropriate queue (see buildSelectAutoQueue rules).
    -- Per Matthew 2026-04-28.
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

        -- Extract + validate payload. Defensive against missing
        -- fields and >2 locked auxes (which the client should have
        -- greyed out, but never trust the client).
        local sweepCoreId
        local lockedAuxIds = {}
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
        end
        sweepCoreId = sweepCoreId or State.preferredCoreId or "Power"
        if #lockedAuxIds > 2 then
            warn(("[Infinite] %s SELECT AUTO rejected — too many locked auxes (%d > 2)")
                :format(player.Name, #lockedAuxIds))
            return
        end

        player:SetAttribute("PreferredCoreId", sweepCoreId)
        persistCorePreference(player, sweepCoreId)
        local queue = buildSelectAutoQueue(sweepCoreId, lockedAuxIds)
        if #queue == 0 then
            warn(("[Infinite] %s requested SELECT AUTO but the queue is empty"):format(player.Name))
            return
        end
        autoRun.active     = true
        autoRun.queue      = queue
        autoRun.results    = {}
        autoRun.total      = #queue
        autoRun.continuous = false
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
        print(("[Infinite] %s wiped cumulative balance stats (%d run(s) cleared, persisted) — new balance version = %d"):format(
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

    print("[Infinite] system online (Workspace.InfiniteUnlocked = "
        .. tostring(Workspace:GetAttribute("InfiniteUnlocked")) .. ")")
end

return Infinite
