--[[
    InfiniteRunHistoryStore.lua tests — pure-function coverage for
    groupByBalanceVersion + mergeByBalanceVersion. We don't touch
    the live cache or DataStore; tests pass synthetic sweep arrays
    and assert on the math.

    Why these tests matter:
      LOAD RUNS in the admin panel renders one row per balance
      version, with sweep counts, run totals, newest timestamp, etc.
      A bug in the grouping math = wrong eras shown / wrong runs
      loaded. These tests pin every field's contract.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Tests = require(script.Parent)
local Store = require(ServerScriptService:WaitForChild("InfiniteRunHistoryStore"))

------------------------------------------------------------
-- Fixtures: synthetic sweeps spanning two balance eras.
------------------------------------------------------------

local function fixture()
    return {
        -- v2 era — 2 sweeps, 5 + 8 runs
        {
            balanceVersion = 2,
            completedAt    = 200,
            total          = 5,
            results        = { {}, {}, {}, {}, {} },
        },
        {
            balanceVersion = 2,
            completedAt    = 250,
            total          = 8,
            aborted        = true,
            results        = { {}, {}, {}, {}, {}, {}, {}, {} },
        },
        -- v1 era — 1 sweep, 81 runs
        {
            balanceVersion = 1,
            completedAt    = 100,
            total          = 81,
            results = (function()
                local t = {}
                for i = 1, 81 do t[i] = { idx = i } end
                return t
            end)(),
        },
        -- legacy sweep with no balanceVersion (treated as v1)
        {
            completedAt = 50,
            total       = 9,
            results     = { {}, {}, {}, {}, {}, {}, {}, {}, {} },
        },
    }
end

------------------------------------------------------------
-- groupByBalanceVersion
------------------------------------------------------------

Tests.test("groupByBalanceVersion: groups sweeps into eras correctly", function()
    local groups = Store.groupByBalanceVersion(fixture())
    Tests.assertEq(#groups, 2, "two eras: v2 and v1")
    -- Sorted DESC, so v2 first.
    Tests.assertEq(groups[1].balanceVersion, 2, "first group should be v2")
    Tests.assertEq(groups[2].balanceVersion, 1, "second group should be v1")
end)

Tests.test("groupByBalanceVersion: counts sweeps + runs per era", function()
    local groups = Store.groupByBalanceVersion(fixture())
    local v2, v1 = groups[1], groups[2]
    Tests.assertEq(v2.sweepCount, 2, "v2 has 2 sweeps")
    Tests.assertEq(v2.totalRuns, 13, "v2 has 5 + 8 = 13 runs")
    Tests.assertEq(v1.sweepCount, 2, "v1 has 2 sweeps (one explicit + one legacy)")
    Tests.assertEq(v1.totalRuns, 90, "v1 has 81 + 9 = 90 runs")
end)

Tests.test("groupByBalanceVersion: tracks newest/oldest timestamps", function()
    local groups = Store.groupByBalanceVersion(fixture())
    local v2, v1 = groups[1], groups[2]
    Tests.assertEq(v2.newestAt, 250, "v2 newest = 250")
    Tests.assertEq(v2.oldestAt, 200, "v2 oldest = 200")
    Tests.assertEq(v1.newestAt, 100, "v1 newest = 100")
    Tests.assertEq(v1.oldestAt, 50, "v1 oldest = 50 (legacy sweep)")
end)

Tests.test("groupByBalanceVersion: anyAborted flag set when any sweep aborted", function()
    local groups = Store.groupByBalanceVersion(fixture())
    Tests.assertTrue(groups[1].anyAborted, "v2 has an aborted sweep")
    Tests.assertFalse(groups[2].anyAborted, "v1 has no aborted sweeps")
end)

Tests.test("groupByBalanceVersion: empty input returns empty list", function()
    Tests.assertEq(#Store.groupByBalanceVersion({}), 0, "empty sweeps → empty groups")
end)

Tests.test("groupByBalanceVersion: bad input returns empty list", function()
    Tests.assertEq(#Store.groupByBalanceVersion(nil), 0, "nil sweeps → empty groups")
    Tests.assertEq(#Store.groupByBalanceVersion("oops"), 0, "string sweeps → empty groups")
end)

------------------------------------------------------------
-- mergeByBalanceVersion
------------------------------------------------------------

Tests.test("mergeByBalanceVersion: concats results from matching era", function()
    local merged = Store.mergeByBalanceVersion(fixture(), 2)
    Tests.assertNotNil(merged, "v2 era should exist")
    Tests.assertEq(merged.sweepCount, 2, "v2 has 2 sweeps")
    Tests.assertEq(#merged.results, 13, "merged results = 5 + 8 = 13")
    Tests.assertEq(merged.completedAt, 250, "completedAt = newest sweep")
    Tests.assertTrue(merged.aborted, "aborted flag inherited from any sweep")
end)

Tests.test("mergeByBalanceVersion: legacy sweeps treated as v1", function()
    local merged = Store.mergeByBalanceVersion(fixture(), 1)
    Tests.assertNotNil(merged, "v1 era should include legacy sweep")
    Tests.assertEq(merged.sweepCount, 2, "1 explicit-v1 + 1 legacy = 2")
    Tests.assertEq(#merged.results, 90, "81 + 9 = 90 runs")
    Tests.assertEq(merged.completedAt, 100, "newest = 100 (explicit v1 sweep)")
end)

Tests.test("mergeByBalanceVersion: unknown era returns nil", function()
    Tests.assertNil(Store.mergeByBalanceVersion(fixture(), 99), "no v99 sweeps")
    Tests.assertNil(Store.mergeByBalanceVersion(fixture(), 0), "no v0 sweeps")
end)

Tests.test("mergeByBalanceVersion: bad input returns nil", function()
    Tests.assertNil(Store.mergeByBalanceVersion(nil, 1), "nil sweeps → nil")
    Tests.assertNil(Store.mergeByBalanceVersion(fixture(), nil), "nil version → nil")
    Tests.assertNil(Store.mergeByBalanceVersion(fixture(), "v2"), "string version → nil")
end)

------------------------------------------------------------
-- saveTimingHint / loadTimingHint round-trip (ea3-119).
-- These hit the live in-memory cache — DataStore writes are async-
-- pcall'd so they're safe in tests with no API access. We don't
-- assert on persistence, just on the in-process round-trip
-- contract.
------------------------------------------------------------

Tests.test("saveTimingHint / loadTimingHint: round-trips a positive number", function()
    Store.saveTimingHint("failureCurve", 47.5)
    Tests.assertNear(Store.loadTimingHint("failureCurve"), 47.5, 0.001)
end)

Tests.test("saveTimingHint: ignores invalid input", function()
    Store.saveTimingHint("failureCurve", 50)  -- known-good baseline
    Store.saveTimingHint("failureCurve", -3)
    Tests.assertNear(Store.loadTimingHint("failureCurve"), 50, 0.001,
        "negative input should not overwrite the baseline")
    Store.saveTimingHint("failureCurve", 0)
    Tests.assertNear(Store.loadTimingHint("failureCurve"), 50, 0.001,
        "zero input should not overwrite either")
    Store.saveTimingHint("", 99)
    Store.saveTimingHint(nil :: any, 99)
    Tests.assertNear(Store.loadTimingHint("failureCurve"), 50, 0.001,
        "empty/nil sweepType should not write anything")
end)

Tests.test("loadTimingHint: returns nil for unknown sweep type", function()
    Tests.assertNil(Store.loadTimingHint("nonExistentSweepType_xyz"))
end)

return nil
