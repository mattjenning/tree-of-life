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
            results     = { { auxIds, label, finalWave, testType, statSummary }, ... },
            tiers       = { DPS = {...}, Control = {...}, Support = {...} },
        }

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

local store = DataStoreService:GetDataStore(STORE_NAME)

-- In-memory mirror of the DataStore. Loaded lazily on first access;
-- subsequent reads/writes hit cache without a DataStore round-trip.
local cache = nil  -- list of sweep records
local loadAttempted = false

-- Cumulative-results cache (separate key, separate lazy-load).
local cumulativeCache: { any }? = nil
local cumulativeLoadAttempted = false

local function pcallRetry(fn)
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

return Store
