--[[
    Infinite.lua tests — pure-helper coverage for the few testable
    surfaces the orchestrator module exposes. Most of Infinite.lua
    is Roblox-runtime-bound (Remotes, Workspace, DataStore,
    WaveCtxBridge, etc) and not unit-testable, but a handful of
    pure helpers ARE — those carry the testable contract.

    What we test:
      • Infinite._filterResultsForCoreAndEra — the per-Core / per-
        balance-version filter used by printRealTierForCore (ea3-132)
        + the SUPER CURVE × 495 Phase B validator-refresh loop
        (ea3-134). Wrong filter → tier list shows mixed-era data
        and the validator picks pre-nerf loadouts as "worst-|delta|"
        targets, polluting the calibration loop.

    What we DON'T test here:
      • The print path itself (`printRealTierForCore`) — that's a
        log-formatting wrapper around the filter + assembleTiers +
        printTierList. Pure-function logic lives in the helper now.
      • runSimForCore / runFailureCurveForCore / etc — they depend
        on the DataStore + ArenaSweepRunner runtime; integration-
        tested via live sweeps.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Tests = require(script.Parent)
local Infinite = require(ServerScriptService:WaitForChild("systems"):WaitForChild("Infinite"))

------------------------------------------------------------
-- _filterResultsForCoreAndEra
------------------------------------------------------------

Tests.test("_filterResultsForCoreAndEra: empty pool returns empty list", function()
    local out = Infinite._filterResultsForCoreAndEra({}, "Power", 1)
    Tests.assertEq(#out, 0, "empty pool → empty result")
end)

Tests.test("_filterResultsForCoreAndEra: filters by coreId match", function()
    local pool = {
        { coreId = "Power",       balanceVersion = 5, finalWave = 10 },
        { coreId = "ControlCore", balanceVersion = 5, finalWave = 11 },
        { coreId = "SupportCore", balanceVersion = 5, finalWave = 12 },
        { coreId = "Power",       balanceVersion = 5, finalWave = 13 },
    }
    local powerOnly = Infinite._filterResultsForCoreAndEra(pool, "Power", 1)
    Tests.assertEq(#powerOnly, 2, "two Power entries kept")
    -- Order preserved (filter is stable).
    Tests.assertEq(powerOnly[1].finalWave, 10, "first Power entry first")
    Tests.assertEq(powerOnly[2].finalWave, 13, "second Power entry second")
end)

Tests.test("_filterResultsForCoreAndEra: filters by balanceVersion >= active", function()
    local pool = {
        { coreId = "Power", balanceVersion = 16, finalWave = 10 },  -- pre-era
        { coreId = "Power", balanceVersion = 17, finalWave = 11 },  -- pre-era
        { coreId = "Power", balanceVersion = 18, finalWave = 12 },  -- active era
        { coreId = "Power", balanceVersion = 19, finalWave = 13 },  -- newer era
    }
    local activeEra = Infinite._filterResultsForCoreAndEra(pool, "Power", 18)
    Tests.assertEq(#activeEra, 2, "v18 + v19 kept; v16 + v17 dropped")
    Tests.assertEq(activeEra[1].balanceVersion, 18, "v18 first")
    Tests.assertEq(activeEra[2].balanceVersion, 19, "v19 second")
end)

Tests.test("_filterResultsForCoreAndEra: missing balanceVersion treated as 0", function()
    -- Defensive: pre-ea3-12 entries lack balanceVersion. Treat as
    -- ancient era 0 → always older than any positive activeBalanceVersion.
    local pool = {
        { coreId = "Power",                            finalWave = 10 },  -- nil version → 0
        { coreId = "Power", balanceVersion = 0,        finalWave = 11 },  -- explicit 0
        { coreId = "Power", balanceVersion = 5,        finalWave = 12 },  -- in scope
    }
    local out = Infinite._filterResultsForCoreAndEra(pool, "Power", 5)
    Tests.assertEq(#out, 1, "only v=5 entry kept; nil + 0 versions dropped")
    Tests.assertEq(out[1].finalWave, 12, "right entry")
end)

Tests.test("_filterResultsForCoreAndEra: combined coreId + era gating", function()
    local pool = {
        { coreId = "Power",       balanceVersion = 18, finalWave = 10 },  -- match
        { coreId = "ControlCore", balanceVersion = 18, finalWave = 11 },  -- wrong core
        { coreId = "Power",       balanceVersion = 17, finalWave = 12 },  -- pre-era
        { coreId = "Power",       balanceVersion = 19, finalWave = 13 },  -- match
        { coreId = "ControlCore", balanceVersion = 19, finalWave = 14 },  -- wrong core
    }
    local out = Infinite._filterResultsForCoreAndEra(pool, "Power", 18)
    Tests.assertEq(#out, 2, "Power core + era >= 18 entries kept")
    Tests.assertEq(out[1].finalWave, 10, "first match")
    Tests.assertEq(out[2].finalWave, 13, "second match")
end)

Tests.test("_filterResultsForCoreAndEra: era=0 admits everything in core", function()
    -- Edge case: balanceVersion=0 as the active version → all entries
    -- (including those with missing/zero version) for the core pass.
    local pool = {
        { coreId = "Power",                  finalWave = 10 },
        { coreId = "Power", balanceVersion = 0,  finalWave = 11 },
        { coreId = "Power", balanceVersion = 5,  finalWave = 12 },
        { coreId = "Power", balanceVersion = 99, finalWave = 13 },
    }
    local out = Infinite._filterResultsForCoreAndEra(pool, "Power", 0)
    Tests.assertEq(#out, 4, "all Power entries pass when activeVersion=0")
end)

return nil
