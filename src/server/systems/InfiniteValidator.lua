--[[
    InfiniteValidator.lua — Sim-vs-real delta dump for closed-form
    accuracy.

    Per project_simulator_improvement.md Phase 1: "Without a
    comparison tool we'd be optimizing blind. Before changing any
    sim math, build a side-by-side delta dump…" Every later phase
    has a measurable success metric: did the median delta shrink?

    USAGE
    -----
        local Validator = require(script.Parent.InfiniteValidator)
        local report = Validator.compare({
            sim  = simResults,                    -- list of {auxIds, finalWave}
            real = cumulativeResults,             -- list of {auxIds, finalWave, balanceVersion}
            roleByTowerId = TempTowers.RoleByTowerId,
            -- ea3-123 OPTIONAL: filter real entries by balance version.
            -- When the cumulative pool spans multiple eras (e.g. v16
            -- random-pick + v17 rarity-greedy mixed), pass the active
            -- balance version to compare ONLY against same-era data.
            -- Without the filter, sim-vs-real deltas average across
            -- eras and the signal pulls toward the larger era's data
            -- regardless of which era you're calibrating.
            minBalanceVersion = currentBalanceVersion,
        })
        Validator.printReport(report)             -- formatted F9 dump

    The `compare` function is pure (no Roblox / DataStore deps), so
    tests can hit it directly with synthetic input.

    REPORT SHAPE
    ------------
        report = {
            perLoadout = { ... },                 -- one entry per sim result
            buckets = {
                byCategory = {                     -- solo / duo / trio
                    Solo = { count = N, mean = …, median = …, worst = …, … },
                    Duo  = { … },
                    Trio = { … },
                },
                byRoleMix = {                      -- pureDPS / pureCtl / balanced
                    pureDPS     = { … },
                    pureControl = { … },
                    balanced    = { … },
                },
                byCarries = {                      -- per-tower membership delta
                    AcornSniper = { count = N, mean = …, … },
                    …
                },
            },
            overall = { count = N, mean = …, median = …, worst = …, … },
            untracked = N,                          -- sim loadouts with no real match
        }

    DELTA convention: delta = sim - real (positive = sim overestimates;
    negative = sim underestimates). Worst-case = entry with greatest
    |delta|.

    LOADOUT KEY: alphabetically-sorted comma-joined auxIds string.
    "Power" is implicit (always present); the trio anchor
    "InfiniteStandard" IS included in the key so trio rows match
    only against trio sweeps. Same convention as
    Infinite.lua:assembleTiers.
]]

local Validator = {}

------------------------------------------------------------
-- Internal helpers (pure)
------------------------------------------------------------

local function loadoutKey(auxIds)
    if type(auxIds) ~= "table" then return "" end
    local copy = table.clone(auxIds)
    table.sort(copy)
    return table.concat(copy, ",")
end

local function categoryFor(n)
    if n <= 1 then return "Solo"
    elseif n == 2 then return "Duo"
    else return "Trio" end
end

-- pureDPS / pureControl / balanced — judged by aux roles only
-- (Power is always present and is Core, not part of the mix).
-- Trio anchor InfiniteStandard is excluded since it's a constant.
local function roleMixFor(auxIds, roleByTowerId)
    if type(auxIds) ~= "table" or type(roleByTowerId) ~= "table" then
        return "balanced"
    end
    local roles = {}
    for _, id in ipairs(auxIds) do
        if id ~= "InfiniteStandard" then
            roles[roleByTowerId[id] or "?"] = true
        end
    end
    -- Solos with one tower fall into pureDPS / pureControl /
    -- pureSupport, no "balanced" possible.
    if roles.DPS and not roles.Control and not roles.Support then return "pureDPS" end
    if roles.Control and not roles.DPS and not roles.Support then return "pureControl" end
    if roles.Support and not roles.DPS and not roles.Control then return "pureSupport" end
    return "balanced"
end

-- median of an array of numbers (does not mutate input)
local function median(arr)
    if #arr == 0 then return 0 end
    local copy = table.clone(arr)
    table.sort(copy)
    local n = #copy
    if n % 2 == 1 then
        return copy[(n + 1) / 2]
    end
    return 0.5 * (copy[n / 2] + copy[n / 2 + 1])
end

local function summarize(deltas)
    local n = #deltas
    if n == 0 then
        return { count = 0, mean = 0, median = 0, worst = 0, signedMean = 0 }
    end
    local sumAbs, sumSigned = 0, 0
    local worst = 0
    for _, d in ipairs(deltas) do
        sumAbs = sumAbs + math.abs(d)
        sumSigned = sumSigned + d
        if math.abs(d) > math.abs(worst) then worst = d end
    end
    return {
        count      = n,
        mean       = sumAbs / n,
        signedMean = sumSigned / n,
        median     = median(deltas),
        worst      = worst,
    }
end

------------------------------------------------------------
-- Public: compare(opts) → report
------------------------------------------------------------

function Validator.compare(opts)
    opts = opts or {}
    local simResults  = opts.sim  or {}
    local realResults = opts.real or {}
    local roleByTowerId = opts.roleByTowerId or {}
    -- ea3-123: optional balance-version filter. When set, real
    -- entries with balanceVersion < minBalanceVersion are skipped
    -- (treated as a different era's data, not comparable). nil =
    -- no filter (all real data, regardless of era).
    local minBalanceVersion = opts.minBalanceVersion

    -- Aggregate real results by loadout key → average finalWave +
    -- run count. Multiple real runs of the same loadout are
    -- averaged (the cumulative pool can have N samples per combo).
    local realAgg = {}
    local skippedByEra = 0  -- count of real entries below filter, for the report
    for _, r in ipairs(realResults) do
        local rv = r.balanceVersion
        if minBalanceVersion and (type(rv) ~= "number" or rv < minBalanceVersion) then
            skippedByEra = skippedByEra + 1
        else
            local key = loadoutKey(r.auxIds)
            local entry = realAgg[key]
            if not entry then
                entry = { totalWave = 0, runs = 0 }
                realAgg[key] = entry
            end
            entry.totalWave = entry.totalWave + (r.finalWave or 0)
            entry.runs      = entry.runs + 1
        end
    end

    local report = {
        perLoadout = {},
        untracked  = 0,
        overall    = nil,
        buckets    = {
            byCategory = {},
            byRoleMix  = {},
            byCarries  = {},
        },
        -- ea3-123: era-filter telemetry — caller passes
        -- minBalanceVersion to scope the comparison; the report
        -- echoes back what was filtered so the F9 dump is honest
        -- about its sample.
        minBalanceVersion = minBalanceVersion,
        skippedByEra      = skippedByEra,
    }
    local allDeltas = {}
    local catDeltas = {}    -- "Solo" / "Duo" / "Trio" → list
    local mixDeltas = {}    -- "pureDPS" / etc → list
    local carryDeltas = {}  -- towerId → list

    for _, sim in ipairs(simResults) do
        local key = loadoutKey(sim.auxIds)
        local realEntry = realAgg[key]
        if realEntry and realEntry.runs > 0 then
            local realAvg = realEntry.totalWave / realEntry.runs
            local delta = (sim.finalWave or 0) - realAvg
            local n = (sim.auxIds and #sim.auxIds) or 0
            local category = categoryFor(n)
            local mix = roleMixFor(sim.auxIds, roleByTowerId)
            table.insert(report.perLoadout, {
                auxIds      = sim.auxIds,
                label       = sim.label,
                category    = category,
                roleMix     = mix,
                simWave     = sim.finalWave,
                realAvgWave = realAvg,
                realRuns    = realEntry.runs,
                delta       = delta,
            })
            table.insert(allDeltas, delta)
            catDeltas[category] = catDeltas[category] or {}
            table.insert(catDeltas[category], delta)
            mixDeltas[mix] = mixDeltas[mix] or {}
            table.insert(mixDeltas[mix], delta)
            for _, towerId in ipairs(sim.auxIds or {}) do
                if towerId ~= "InfiniteStandard" or n < 3 then
                    carryDeltas[towerId] = carryDeltas[towerId] or {}
                    table.insert(carryDeltas[towerId], delta)
                end
            end
        else
            report.untracked = report.untracked + 1
        end
    end

    report.overall = summarize(allDeltas)
    for cat, deltas in pairs(catDeltas) do
        report.buckets.byCategory[cat] = summarize(deltas)
    end
    for mix, deltas in pairs(mixDeltas) do
        report.buckets.byRoleMix[mix] = summarize(deltas)
    end
    for tower, deltas in pairs(carryDeltas) do
        report.buckets.byCarries[tower] = summarize(deltas)
    end

    return report
end

------------------------------------------------------------
-- Public: printReport(report) — F9 dump
------------------------------------------------------------

local function fmtSummary(s)
    return string.format(
        "n=%d  mean(|Δ|)=%.2f  signed=%+.2f  median=%+.2f  worst=%+.2f",
        s.count or 0, s.mean or 0, s.signedMean or 0, s.median or 0, s.worst or 0)
end

function Validator.printReport(report)
    if type(report) ~= "table" then return end
    print("[InfiniteValidator] -------- SIM vs REAL delta report --------")
    -- ea3-123: scope line — when an era filter is active, surface
    -- it in the header so the deltas aren't mistaken for cross-era
    -- numbers. Reads "(filter: balanceVersion >= 17, skipped 106
    -- pre-era real runs)" or similar.
    if report.minBalanceVersion then
        print(string.format(
            "[InfiniteValidator] scope:      balanceVersion >= %d  (skipped %d pre-era real run(s))",
            report.minBalanceVersion, report.skippedByEra or 0))
    end
    print(string.format("[InfiniteValidator] OVERALL:    %s",
        fmtSummary(report.overall or {})))
    print(string.format("[InfiniteValidator] untracked:  %d sim loadout(s) had no matching real run",
        report.untracked or 0))

    print("[InfiniteValidator] -- by category (solo/duo/trio):")
    for _, cat in ipairs({"Solo", "Duo", "Trio"}) do
        local s = report.buckets and report.buckets.byCategory and report.buckets.byCategory[cat]
        if s then
            print(string.format("[InfiniteValidator]   %-5s  %s", cat, fmtSummary(s)))
        end
    end

    print("[InfiniteValidator] -- by role mix:")
    for _, mix in ipairs({"pureDPS", "pureControl", "pureSupport", "balanced"}) do
        local s = report.buckets and report.buckets.byRoleMix and report.buckets.byRoleMix[mix]
        if s then
            print(string.format("[InfiniteValidator]   %-12s  %s", mix, fmtSummary(s)))
        end
    end

    print("[InfiniteValidator] -- by carries-tower (delta when this tower is in the loadout):")
    -- Sort towers by abs(signedMean) descending so the worst-fitting
    -- towers print first.
    local rows = {}
    for tower, s in pairs(report.buckets and report.buckets.byCarries or {}) do
        table.insert(rows, { tower = tower, summary = s })
    end
    table.sort(rows, function(a, b)
        return math.abs(a.summary.signedMean or 0) > math.abs(b.summary.signedMean or 0)
    end)
    for _, row in ipairs(rows) do
        print(string.format("[InfiniteValidator]   %-18s  %s", row.tower, fmtSummary(row.summary)))
    end

    print("[InfiniteValidator] -------- end report --------")
end

------------------------------------------------------------
-- Public: toCsv(report) — dumpable CSV string of perLoadout rows
------------------------------------------------------------

------------------------------------------------------------
-- Public: topByDelta(report, n) — top-N |delta| perLoadout entries
------------------------------------------------------------
--
-- Pure helper. Sorts report.perLoadout by abs(delta) descending and
-- returns the first `n` entries (or all of them if `n` is nil or
-- exceeds the count). Each returned entry is the same shape as
-- report.perLoadout entries: { auxIds, label, category, roleMix,
-- simWave, realAvgWave, realRuns, delta }.
--
-- Used by the TARGETED button handler (Infinite.lua) to pick the
-- "highest information value" combos for a shorter validator-feeding
-- sweep — the combos where the closed-form sim is most wrong are
-- the ones whose re-test moves the model the most.
--
-- Returns {} when report is nil/malformed or perLoadout is empty.
function Validator.topByDelta(report, n)
    if type(report) ~= "table" then return {} end
    local rows = report.perLoadout or {}
    if #rows == 0 then return {} end
    local sorted = {}
    for _, e in ipairs(rows) do
        table.insert(sorted, e)
    end
    table.sort(sorted, function(a, b)
        return math.abs(a.delta or 0) > math.abs(b.delta or 0)
    end)
    if type(n) == "number" and n > 0 and n < #sorted then
        local out = {}
        for i = 1, n do
            out[i] = sorted[i]
        end
        return out
    end
    return sorted
end

function Validator.toCsv(report)
    local lines = { "category,roleMix,realRuns,simWave,realAvgWave,delta,label" }
    for _, e in ipairs(report.perLoadout or {}) do
        table.insert(lines, string.format(
            "%s,%s,%d,%.3f,%.3f,%+.3f,%q",
            e.category, e.roleMix, e.realRuns or 0,
            e.simWave or 0, e.realAvgWave or 0, e.delta or 0,
            e.label or ""))
    end
    return table.concat(lines, "\n")
end

return Validator
