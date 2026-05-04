--[[
    InfiniteRunHistoryStore.lua — Persistent storage for completed
    AUTO RUN sweeps so the admin panel's LOAD RUN button can pull
    past data for analysis across server restarts.

    Per Matthew 2026-04-26: "let's start storing completed autorun
    data to data store. add a LOAD RUN button to admin to load past
    run data for analysis."

    SCHEMA:
    Single global key "history" stores a list of sweep records,
    newest first. Capped at MAX_SWEEPS so a long-running studio
    doesn't accumulate beyond DataStore's 4MB-per-key budget.

    Each sweep record:
        {
            completedAt = os.time(),
            total       = number (queue size at start),
            aborted     = boolean (true if RUN RESET / player left),
            results     = { { auxIds, label, finalWave, testType, luckAvg, luckCount }, ... },
            tiers       = { DPS = {...}, Control = {...}, Support = {...} },
        }
    luckAvg / luckCount (ea3-103): per-run avg rarity score of upgrade
    cards SHOWN during the run. luckAvg ≈ 2.71 = expected baseline given
    the 50/25/10/5/2/8 default rarity distribution. Higher = better
    rolls. Used by future tier-list views to filter / normalize for
    luck-band so loadout signal isn't drowned by upgrade RNG.

    USAGE:
        local Store = require(ServerScriptService.InfiniteRunHistoryStore)
        Store.append(sweep)               -- fire-and-forget; persists to DataStore async
        local list = Store.list()         -- → metadata-only list { {idx, completedAt, total, aborted}, ... }
        local sweep = Store.get(idx)      -- → full sweep record
        Store.clear()                     -- wipe history (admin TOTAL RESET)

    Designed to fail soft — DataStore errors are logged + caches
    stay in sync. Studio sessions with DataStore disabled (no API
    access) still get in-memory append/list/get; just nothing
    persists across server restarts.
]]

local DataStoreService = game:GetService("DataStoreService")

local Store = {}

local STORE_NAME = "TreeOfLife_InfiniteRunHistory_v1"
local STORE_KEY  = "history"
-- Separate key in the same DataStore for the cumulative-results
-- pool that the admin panel's default "ALL RUNS" tier-list view
-- aggregates over. Per Matthew 2026-04-26: "hook up the data store
-- so we can save autorun data." Without this, the cumulative pool
-- was wiped every server restart.
local CUMULATIVE_KEY = "cumulative_v1"
-- Sim-cache: persisted last-run-per-Core simulator output so a
-- mid-SUPER-AUTO crash doesn't lose the closed-form sim data
-- (Power / Control / Support tier predictions + validator buckets).
-- Per Matthew 2026-04-29: "save the sim runs to the export, so if
-- the run crashes like last night, it's still there."
-- Schema: { Power = {tiers,results,...}, ControlCore = {...}, SupportCore = {...} }
local SIM_CACHE_KEY = "sim_cache_v1"
-- Monotonic balance-version counter. Bumped each time BALANCE
-- RESET is hit so past sweeps can be grouped + loaded as one
-- "balance era" in the LOAD RUNS picker. Per Matthew 2026-04-27:
-- "every time balance reset is used increase the balance
-- version # and start a new row." Sweeps before this counter
-- existed are treated as version 1 on read.
local BALANCE_VERSION_KEY = "balance_version_v1"
local MAX_SWEEPS = 20  -- newest-first; older entries fall off the back
-- Cap the cumulative pool too — at ~30 sweeps × 73 runs = 2190 entries,
-- well under DataStore's 4MB-per-key budget given that each trimmed
-- result is ~100 bytes (auxIds + label + 2 numbers). Drops oldest
-- on overflow.
local MAX_CUMULATIVE_RESULTS = 2200
local MAX_RETRIES = 3

-- ea3-108: pcall the GetDataStore call so Studio sessions without
-- "Enable Studio Access to API Services" enabled still load the
-- module (just with DataStore unavailable). Pre-fix this threw at
-- module-scope and cascaded — RunTests / WaveSystem / Hub all
-- failed to load because they require chains lead here.
local store
do
    local ok, result = pcall(function()
        return DataStoreService:GetDataStore(STORE_NAME)
    end)
    if ok then
        store = result
    else
        warn(("[InfiniteRunHistoryStore] DataStore unavailable — running in-memory only. Reason: %s"):format(tostring(result)))
        store = nil
    end
end

-- In-memory mirror of the DataStore. Loaded lazily on first access;
-- subsequent reads/writes hit cache without a DataStore round-trip.
local cache = nil  -- list of sweep records
local loadAttempted = false

-- Cumulative-results cache (separate key, separate lazy-load).
local cumulativeCache: { any }? = nil
local cumulativeLoadAttempted = false

local function pcallRetry(fn)
    -- ea3-108: short-circuit if DataStore was unavailable at module
    -- load. All call sites already handle (false, err) correctly by
    -- falling back to in-memory cache; without this guard each call
    -- would throw "attempt to index nil with 'GetAsync'" instead of
    -- returning a clean failure.
    if not store then
        return false, "datastore offline (Studio API services disabled?)"
    end
    local lastErr
    for attempt = 1, MAX_RETRIES do
        local ok, result = pcall(fn)
        if ok then return true, result end
        lastErr = result
        task.wait(0.5 * attempt)
    end
    return false, lastErr
end

local function loadFromStore()
    if loadAttempted then return cache end
    loadAttempted = true
    local ok, data = pcallRetry(function() return store:GetAsync(STORE_KEY) end)
    if not ok then
        warn(("[InfiniteRunHistoryStore] load failed: %s — starting empty in-memory cache"):format(tostring(data)))
        cache = {}
    elseif type(data) ~= "table" then
        cache = {}
    else
        cache = data
    end
    print(("[InfiniteRunHistoryStore] loaded %d past sweep(s)"):format(#cache))
    return cache
end

-- Persist current cache. Async via task.spawn so the caller (AUTO
-- RUN finalize) doesn't block on the DataStore round-trip.
local function persistAsync()
    local snapshot = cache  -- alias; cache isn't mutated during the spawned write
    task.spawn(function()
        local ok, err = pcallRetry(function() store:SetAsync(STORE_KEY, snapshot) end)
        if not ok then
            warn(("[InfiniteRunHistoryStore] save failed: %s"):format(tostring(err)))
        else
            print(("[InfiniteRunHistoryStore] persisted %d sweep(s)"):format(#snapshot))
        end
    end)
end

-- Strip the heavy statSummary text to keep individual sweep size
-- under control. Per-run details are kept structured (auxIds /
-- label / finalWave / testType); the StatLedger string is verbose
-- for log display but not needed for offline analysis.
local function trimSweepForStorage(sweep)
    local trimmed = {
        completedAt    = sweep.completedAt or os.time(),
        total          = sweep.total or 0,
        aborted        = sweep.aborted == true or nil,
        balanceVersion = sweep.balanceVersion or 1,
        results        = {},
        tiers          = sweep.tiers,
    }
    if sweep.results then
        for _, r in ipairs(sweep.results) do
            table.insert(trimmed.results, {
                auxIds         = r.auxIds,
                label          = r.label,
                finalWave      = r.finalWave,
                testType       = r.testType,
                balanceVersion = r.balanceVersion or trimmed.balanceVersion,
                -- ea3-103: luckAvg = avg rarity score of cards SHOWN
                -- this run (1=Common…5=Mythical, 2.71=expected baseline).
                -- Used for normalizing tier-list views — runs with
                -- outlier high/low luck can be filtered or weighted.
                luckAvg        = r.luckAvg,
                luckCount      = r.luckCount,
                -- statSummary intentionally dropped for storage size
            })
        end
    end
    return trimmed
end

function Store.append(sweep)
    if type(sweep) ~= "table" then return end
    loadFromStore()
    table.insert(cache, 1, trimSweepForStorage(sweep))
    -- Trim to MAX_SWEEPS — drop oldest.
    while #cache > MAX_SWEEPS do
        table.remove(cache)
    end
    persistAsync()
end

function Store.list()
    loadFromStore()
    local out = {}
    for idx, s in ipairs(cache) do
        table.insert(out, {
            idx            = idx,
            completedAt    = s.completedAt,
            total          = s.total,
            aborted        = s.aborted,
            resultCount    = (s.results and #s.results) or 0,
            balanceVersion = s.balanceVersion or 1,
        })
    end
    return out
end

-- Pure helper: group a list of sweep records by balanceVersion.
-- Extracted from listByBalanceVersion() so tests can exercise the
-- grouping math directly with a synthetic cache (no DataStore).
-- Each entry shape:
--   {
--     balanceVersion = number,
--     sweepCount     = number,    -- how many sweeps in this era
--     totalRuns      = number,    -- sum of resultCount across sweeps
--     newestAt       = os.time,   -- max completedAt
--     oldestAt       = os.time,   -- min completedAt
--     anyAborted     = boolean,
--     sweepIdxs      = { number, ... },  -- positions in `sweeps`
--   }
function Store.groupByBalanceVersion(sweeps)
    if type(sweeps) ~= "table" then return {} end
    local groups = {}  -- version → entry
    local order = {}   -- version order of first sighting
    for idx, s in ipairs(sweeps) do
        local v = (type(s) == "table" and s.balanceVersion) or 1
        local g = groups[v]
        if not g then
            g = {
                balanceVersion = v,
                sweepCount     = 0,
                totalRuns      = 0,
                newestAt       = 0,
                oldestAt       = math.huge,
                anyAborted     = false,
                sweepIdxs      = {},
            }
            groups[v] = g
            table.insert(order, v)
        end
        g.sweepCount = g.sweepCount + 1
        g.totalRuns  = g.totalRuns + ((s.results and #s.results) or 0)
        local t = s.completedAt or 0
        if t > g.newestAt then g.newestAt = t end
        if t < g.oldestAt then g.oldestAt = t end
        if s.aborted then g.anyAborted = true end
        table.insert(g.sweepIdxs, idx)
    end
    -- Sort by version DESC (newest era first).
    local out = {}
    for _, v in ipairs(order) do
        table.insert(out, groups[v])
    end
    table.sort(out, function(a, b)
        return (a.balanceVersion or 0) > (b.balanceVersion or 0)
    end)
    return out
end

-- Pure helper: merge every sweep belonging to `balanceVersion`
-- into ONE merged sweep payload (results concat, completedAt =
-- newest). Returns nil if no sweep matches. Same extraction as
-- groupByBalanceVersion — tests pass synthetic data, the live
-- store wraps with the cache.
function Store.mergeByBalanceVersion(sweeps, balanceVersion)
    if type(sweeps) ~= "table" then return nil end
    if type(balanceVersion) ~= "number" then return nil end
    local merged = {
        balanceVersion = balanceVersion,
        completedAt    = 0,
        total          = 0,
        aborted        = false,
        results        = {},
        sweepCount     = 0,
    }
    local found = false
    for _, s in ipairs(sweeps) do
        if (s.balanceVersion or 1) == balanceVersion then
            found = true
            merged.sweepCount = merged.sweepCount + 1
            merged.total = merged.total + (s.total or 0)
            local t = s.completedAt or 0
            if t > merged.completedAt then
                merged.completedAt = t
            end
            if s.aborted then merged.aborted = true end
            if s.results then
                for _, r in ipairs(s.results) do
                    table.insert(merged.results, r)
                end
            end
        end
    end
    if not found then return nil end
    return merged
end

-- Public store API — wraps the pure helpers around the cached
-- DataStore-backed sweep list. Per Matthew 2026-04-27 LOAD RUNS.
function Store.listByBalanceVersion()
    loadFromStore()
    return Store.groupByBalanceVersion(cache)
end

function Store.getByBalanceVersion(balanceVersion)
    loadFromStore()
    return Store.mergeByBalanceVersion(cache, balanceVersion)
end

function Store.get(idx)
    loadFromStore()
    if type(idx) ~= "number" then return nil end
    return cache[idx]
end

function Store.clear()
    cache = {}
    persistAsync()
end

------------------------------------------------------------
-- Cumulative-results pool (separate DataStore key).
--
-- Stores a flat list of every individual run result across all
-- saved sweeps since the last BALANCE / TOTAL reset, so the
-- admin panel's default "ALL RUNS" tier list survives server
-- restarts. Per Matthew 2026-04-26: "hook up the data store so
-- we can save autorun data."
------------------------------------------------------------

-- Drop heavy fields (statSummary text) before persisting. Mirror
-- of trimSweepForStorage's behavior, applied to single results.
local function trimResultForCumulative(r)
    return {
        auxIds         = r.auxIds,
        label          = r.label,
        finalWave      = r.finalWave,
        testType       = r.testType,
        balanceVersion = r.balanceVersion,  -- 2026-04-27 LOAD RUNS grouping
        luckAvg        = r.luckAvg,         -- ea3-103 — see trimSweepForStorage
        luckCount      = r.luckCount,
    }
end

local function loadCumulativeFromStore()
    if cumulativeLoadAttempted then return cumulativeCache end
    cumulativeLoadAttempted = true
    local ok, data = pcallRetry(function() return store:GetAsync(CUMULATIVE_KEY) end)
    if not ok then
        warn(("[InfiniteRunHistoryStore] cumulative load failed: %s — starting empty in-memory cache"):format(tostring(data)))
        cumulativeCache = {}
    elseif type(data) ~= "table" then
        cumulativeCache = {}
    else
        cumulativeCache = data
    end
    print(("[InfiniteRunHistoryStore] loaded %d cumulative result(s)"):format(#cumulativeCache))
    return cumulativeCache
end

local function persistCumulativeAsync()
    local snapshot = cumulativeCache
    task.spawn(function()
        local ok, err = pcallRetry(function() store:SetAsync(CUMULATIVE_KEY, snapshot) end)
        if not ok then
            warn(("[InfiniteRunHistoryStore] cumulative save failed: %s"):format(tostring(err)))
        else
            print(("[InfiniteRunHistoryStore] persisted %d cumulative result(s)"):format(#snapshot))
        end
    end)
end

-- Returns a fresh copy of the cumulative results array. Caller
-- can mutate freely without affecting the DataStore cache; pass
-- back through Store.saveCumulative when ready to persist.
--
-- table.clone is shallow; that's intentional — we want callers
-- to be able to push new result tables without mutating the
-- DataStore-cached array, but the per-result tables are
-- treated as read-only by every consumer (Infinite.lua only
-- ever pushes new results, never edits existing ones), so a
-- shallow copy is sufficient and cheaper than a deep walk.
function Store.loadCumulative()
    local loaded = loadCumulativeFromStore()
    return table.clone(loaded)
end

-- Replace the cumulative cache with `results` (in full) and
-- persist asynchronously. Trims oldest if over MAX_CUMULATIVE_RESULTS.
-- Caller passes the FULL list; this overwrites the cache instead of
-- appending so callers don't accidentally double-add by mixing
-- append patterns.
function Store.saveCumulative(results)
    if type(results) ~= "table" then return end
    -- Trim heavy statSummary fields + cap length (drop oldest).
    local trimmed = {}
    local startIdx = math.max(1, #results - MAX_CUMULATIVE_RESULTS + 1)
    for i = startIdx, #results do
        table.insert(trimmed, trimResultForCumulative(results[i]))
    end
    cumulativeCache = trimmed
    cumulativeLoadAttempted = true  -- skip lazy-load on subsequent reads
    persistCumulativeAsync()
end

function Store.clearCumulative()
    cumulativeCache = {}
    cumulativeLoadAttempted = true
    persistCumulativeAsync()
end

------------------------------------------------------------
-- Sim-cache (separate DataStore key).
--
-- Persists the most recent closed-form simulator output PER
-- Core archetype, so a server crash mid-SUPER-AUTO doesn't drop
-- the predictions. The export payload + admin VALIDATE view both
-- read from this — without persistence, a crash forced a re-run
-- of all 3 sims (cheap individually but wasted analysis time).
-- Per Matthew 2026-04-29: "can you save the sim runs to the
-- export, so if the run crashes like last night, it's still
-- there?"
--
-- Schema:
--   { Power = simRecord, ControlCore = simRecord, SupportCore = simRecord }
-- where each simRecord is the runSimForCore() return value:
--   { tiers, results, completedAt, total, simulated, validation, coreId }
--
-- Bound: 3 Cores × ~105 sim results each, validation report
-- ~3 KB per Core. ~30-60 KB total — well under the 4MB-per-key
-- DataStore budget.
------------------------------------------------------------

local simCache: { [string]: any }? = nil
local simLoadAttempted = false

local function loadSimFromStore()
    if simLoadAttempted then return simCache end
    simLoadAttempted = true
    local ok, data = pcallRetry(function() return store:GetAsync(SIM_CACHE_KEY) end)
    if not ok then
        warn(("[InfiniteRunHistoryStore] sim-cache load failed: %s — starting empty"):format(tostring(data)))
        simCache = {}
    elseif type(data) ~= "table" then
        simCache = {}
    else
        simCache = data
    end
    local n = 0
    for _ in pairs(simCache or {}) do n = n + 1 end
    print(("[InfiniteRunHistoryStore] loaded sim cache for %d Core(s)"):format(n))
    return simCache
end

local function persistSimAsync()
    local snapshot = simCache
    task.spawn(function()
        local ok, err = pcallRetry(function() store:SetAsync(SIM_CACHE_KEY, snapshot) end)
        if not ok then
            warn(("[InfiniteRunHistoryStore] sim-cache save failed: %s"):format(tostring(err)))
        else
            local n = 0
            for _ in pairs(snapshot or {}) do n = n + 1 end
            print(("[InfiniteRunHistoryStore] persisted sim cache (%d Core(s))"):format(n))
        end
    end)
end

-- Returns a fresh shallow copy of the per-Core sim cache.
-- Same shallow-copy rationale as loadCumulative — callers add
-- new Core entries without mutating the DataStore-cached dict,
-- and individual sim records are treated as read-only.
function Store.loadSim(): { [string]: any }
    local loaded = loadSimFromStore() or {}
    return table.clone(loaded)
end

-- Replace cache with `simByCore` (full dict) and persist async.
-- Caller passes the FULL dict; this overwrites the cache instead
-- of merging so callers don't accidentally retain stale Cores.
function Store.saveSim(simByCore: { [string]: any })
    if type(simByCore) ~= "table" then return end
    simCache = simByCore
    simLoadAttempted = true  -- skip lazy-load on subsequent reads
    persistSimAsync()
end

function Store.clearSim()
    simCache = {}
    simLoadAttempted = true
    persistSimAsync()
end

------------------------------------------------------------
-- Balance-version counter (separate DataStore key).
--
-- Persists the monotonic balance-version number so it survives
-- server restarts. BALANCE RESET bumps this and Infinite.lua
-- stamps every newly-saved sweep + cumulative-result with the
-- current value. Per Matthew 2026-04-27: "every time balance
-- reset is used increase the balance version # and start a
-- new row."
------------------------------------------------------------

local balanceVersionCache: number? = nil
local balanceVersionLoadAttempted = false

local function loadBalanceVersionFromStore(): number
    if balanceVersionLoadAttempted then
        return balanceVersionCache or 1
    end
    balanceVersionLoadAttempted = true
    local ok, data = pcallRetry(function() return store:GetAsync(BALANCE_VERSION_KEY) end)
    if not ok then
        warn(("[InfiniteRunHistoryStore] balance-version load failed: %s — defaulting to 1"):format(tostring(data)))
        balanceVersionCache = 1
    elseif type(data) == "number" and data >= 1 then
        balanceVersionCache = math.floor(data)
    elseif type(data) == "table" and type(data.version) == "number" and data.version >= 1 then
        -- Defensive: if a future schema change wraps it in a table.
        balanceVersionCache = math.floor(data.version)
    else
        balanceVersionCache = 1
    end
    print(("[InfiniteRunHistoryStore] balance version = %d"):format(balanceVersionCache))
    return balanceVersionCache
end

local function persistBalanceVersionAsync()
    local snapshot = balanceVersionCache
    task.spawn(function()
        local ok, err = pcallRetry(function() store:SetAsync(BALANCE_VERSION_KEY, snapshot) end)
        if not ok then
            warn(("[InfiniteRunHistoryStore] balance-version save failed: %s"):format(tostring(err)))
        else
            print(("[InfiniteRunHistoryStore] persisted balance version = %d"):format(snapshot))
        end
    end)
end

-- Returns the currently-active balance version (≥1). Lazy-loads
-- from DataStore on first call.
function Store.getBalanceVersion(): number
    return loadBalanceVersionFromStore()
end

-- Increment the balance version, persist, return the new value.
-- Called by Infinite.lua's BALANCE RESET handler. The new version
-- is stamped onto subsequently-saved sweeps + cumulative results.
function Store.bumpBalanceVersion(): number
    loadBalanceVersionFromStore()  -- ensure cache populated
    balanceVersionCache = (balanceVersionCache or 1) + 1
    persistBalanceVersionAsync()
    return balanceVersionCache
end

-- TOTAL RESET helper — wipe the version back to 1. (Optional; if
-- not called, history stays grouped by old versions even after a
-- TOTAL RESET. Calling resets the era counter so a fresh studio
-- session starts at v1.)
function Store.resetBalanceVersion()
    balanceVersionCache = 1
    balanceVersionLoadAttempted = true
    persistBalanceVersionAsync()
end

------------------------------------------------------------
-- Timing calibration (separate DataStore key).
--
-- Persisted observed-average per-combo wall time for sweeps, so
-- the next sweep's countdown bar starts on a calibrated seed
-- instead of a hardcoded 60s/combo. Per Matthew 2026-05-01: "can
-- we use elapsed time from logs to improve time left estimates?
-- or does the estimate auto update itself? that would be the
-- best." Schema is a table so we have room for sibling
-- calibrations later (e.g. greedy / full-coverage averages).
------------------------------------------------------------

local TIMING_CALIBRATION_KEY = "timing_calibration_v1"
local timingCache: { [string]: number }? = nil
local timingLoadAttempted = false

local function loadTimingFromStore(): { [string]: number }
    if timingLoadAttempted then return timingCache or {} end
    timingLoadAttempted = true
    if not store then
        timingCache = {}
        return timingCache
    end
    local ok, data = pcallRetry(function() return store:GetAsync(TIMING_CALIBRATION_KEY) end)
    if not ok then
        warn(("[InfiniteRunHistoryStore] timing-calibration load failed: %s — starting empty"):format(tostring(data)))
        timingCache = {}
    elseif type(data) ~= "table" then
        timingCache = {}
    else
        timingCache = {}
        -- Strict: only copy positive numbers. Defensive against schema drift.
        for k, v in pairs(data) do
            if type(k) == "string" and type(v) == "number" and v > 0 then
                timingCache[k] = v
            end
        end
    end
    return timingCache
end

local function persistTimingAsync()
    local snapshot = timingCache
    task.spawn(function()
        if not store then return end
        local ok, err = pcallRetry(function() store:SetAsync(TIMING_CALIBRATION_KEY, snapshot) end)
        if not ok then
            warn(("[InfiniteRunHistoryStore] timing-calibration save failed: %s"):format(tostring(err)))
        end
    end)
end

-- Read the calibrated per-combo seconds for a named sweep type
-- (e.g. "failureCurve"). Returns nil if no calibration is on file
-- yet — caller should fall back to a hardcoded default.
function Store.loadTimingHint(sweepType: string): number?
    local t = loadTimingFromStore()
    return t[sweepType]
end

-- Save the observed average (seconds per combo) for a named sweep
-- type. Caller should only invoke this on completed sweeps with
-- enough combos to be statistically meaningful (≥5 recommended).
-- Persists async; returns immediately.
function Store.saveTimingHint(sweepType: string, perComboSec: number)
    if type(sweepType) ~= "string" or sweepType == "" then return end
    if type(perComboSec) ~= "number" or perComboSec <= 0 then return end
    loadTimingFromStore()  -- ensure cache populated
    timingCache = timingCache or {}
    timingCache[sweepType] = perComboSec
    persistTimingAsync()
end

return Store
