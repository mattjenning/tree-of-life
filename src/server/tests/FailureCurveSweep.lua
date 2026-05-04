--[[
    FailureCurveSweep.lua tests — pure-function coverage for the
    failure-curve sweep helpers added in ea3-116.

    Covers:
      • buildFailureCurveWaveData — wave-type cycling (AOE / Combined /
        Solo every 3 waves); HP scaling per Config.InfiniteArena.WaveHpRamp
        × LoadoutMult; spawn count + ratio per wave type
      • Wave HP math identities — sim and live consume the same
        Pools_C1 baselines, so a wave-N solo's tank HP must match the
        formula `pool * WaveHpRamp(N) * LoadoutMult[#auxes] / 90`

    These are PURE-DATA tests that run against ArenaSweepRunner's
    exposed helper (._buildFailureCurveWaveData). No Roblox / Workspace
    deps; no real wave spawning.
]]

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Tests = require(script.Parent)
local ArenaSweepRunner = require(ServerScriptService
    :WaitForChild("systems"):WaitForChild("ArenaSweepRunner"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local buildFailureCurveWaveData = ArenaSweepRunner._buildFailureCurveWaveData

------------------------------------------------------------
-- Wave-type cycling
------------------------------------------------------------

Tests.test("FailureCurve.buildWaveData: wave 1 = AOE", function()
    local wd = buildFailureCurveWaveData(1, 1.0)
    Tests.assertEq(wd.waveType, "AOE", "wave 1 should be AOE")
    Tests.assertEq(#wd.spawns, 1, "AOE has one spawn group")
    Tests.assertEq(wd.spawns[1].mobType, "basic", "AOE mob type is basic")
    Tests.assertEq(wd.spawns[1].count, 6, "AOE spawns 6 basic mobs")
end)

Tests.test("FailureCurve.buildWaveData: wave 2 = Combined", function()
    local wd = buildFailureCurveWaveData(2, 1.0)
    Tests.assertEq(wd.waveType, "Combined", "wave 2 should be Combined")
    Tests.assertEq(#wd.spawns, 3, "Combined has three spawn groups")
    Tests.assertEq(wd.spawns[1].mobType, "basic", "first spawn is basic")
    Tests.assertEq(wd.spawns[2].mobType, "fast",  "second spawn is fast")
    Tests.assertEq(wd.spawns[3].mobType, "tank",  "third spawn is tank")
    Tests.assertEq(wd.spawns[1].count, 2, "2 basics")
    Tests.assertEq(wd.spawns[2].count, 2, "2 fasts")
    Tests.assertEq(wd.spawns[3].count, 1, "1 tank")
end)

Tests.test("FailureCurve.buildWaveData: wave 3 = Solo", function()
    local wd = buildFailureCurveWaveData(3, 1.0)
    Tests.assertEq(wd.waveType, "Solo", "wave 3 should be Solo")
    Tests.assertEq(#wd.spawns, 1, "Solo has one spawn group")
    Tests.assertEq(wd.spawns[1].mobType, "tank", "Solo mob type is tank")
    Tests.assertEq(wd.spawns[1].count, 1, "Solo spawns 1 tank")
end)

Tests.test("FailureCurve.buildWaveData: wave 4 = AOE (cycle wrap)", function()
    local wd = buildFailureCurveWaveData(4, 1.0)
    Tests.assertEq(wd.waveType, "AOE", "wave 4 wraps back to AOE")
end)

Tests.test("FailureCurve.buildWaveData: wave 28 = AOE (cycle 10)", function()
    -- wave 28 % 3 == 1 → AOE. Last wave at MaxAutoRunWave=28.
    local wd = buildFailureCurveWaveData(28, 1.0)
    Tests.assertEq(wd.waveType, "AOE", "wave 28 wraps to AOE (28 % 3 == 1)")
end)

------------------------------------------------------------
-- HP scaling identities (single source of truth checks)
------------------------------------------------------------

Tests.test("FailureCurve.buildWaveData: solo wave 3 tank HP = pool/90 (no ramp, no loadout)", function()
    local wd = buildFailureCurveWaveData(3, 1.0)
    local pool = Config.InfiniteArena.Pools_C1.Solo
    local tankDelta = (Config.InfiniteArena.Pools_C1_TankHpDelta
        and Config.InfiniteArena.Pools_C1_TankHpDelta.Solo) or 0
    local expectedHpMult = (pool + tankDelta) / 90
    -- Wave 3 has WaveHpRamp = 1.0 (W3 in 1-3 band) and loadoutMult 1.0
    -- (passed in as the second arg) — so the spawn's hpMult should
    -- equal the bare pool/90 ratio.
    local actualHpMult = wd.spawns[1].hpMult
    Tests.assertNear(actualHpMult, expectedHpMult, 0.01,
        ("solo wave 3 tank hpMult: expected %.3f, got %.3f"):format(
            expectedHpMult, actualHpMult))
end)

Tests.test("FailureCurve.buildWaveData: AOE wave 1 basic HP = pool/(6×30)", function()
    local wd = buildFailureCurveWaveData(1, 1.0)
    local pool = Config.InfiniteArena.Pools_C1.AOE
    local expected = pool / (6 * 30)  -- count=6, baseHp=30
    Tests.assertNear(wd.spawns[1].hpMult, expected, 0.01,
        "AOE basic hpMult identity")
end)

Tests.test("FailureCurve.buildWaveData: WaveHpRamp scaling at wave 12", function()
    local wd = buildFailureCurveWaveData(12, 1.0)
    -- Wave 12 = Solo (12 % 3 == 0). WaveHpRamp(12) = 2.00 per the
    -- Config.lua piecewise definition.
    local pool = Config.InfiniteArena.Pools_C1.Solo
    local tankDelta = (Config.InfiniteArena.Pools_C1_TankHpDelta
        and Config.InfiniteArena.Pools_C1_TankHpDelta.Solo) or 0
    local rampMult = Config.InfiniteArena.WaveHpRamp(12)
    local expected = ((pool + tankDelta) / 90) * rampMult * 1.0
    Tests.assertNear(wd.spawns[1].hpMult, expected, 0.01,
        ("wave 12 tank hpMult: expected %.3f, got %.3f"):format(
            expected, wd.spawns[1].hpMult))
end)

Tests.test("FailureCurve.buildWaveData: LoadoutMult scaling for duo (1.25×)", function()
    local wd = buildFailureCurveWaveData(3, 1.25)  -- duo: #auxIds=2 → mult 1.25
    local pool = Config.InfiniteArena.Pools_C1.Solo
    local tankDelta = (Config.InfiniteArena.Pools_C1_TankHpDelta
        and Config.InfiniteArena.Pools_C1_TankHpDelta.Solo) or 0
    local expected = ((pool + tankDelta) / 90) * 1.0 * 1.25
    Tests.assertNear(wd.spawns[1].hpMult, expected, 0.01,
        "duo loadoutMult applied to tank hpMult")
end)

------------------------------------------------------------
-- Wave-data shape (runOneWave consumer contract)
------------------------------------------------------------

Tests.test("FailureCurve.buildWaveData: hpMult field is 1.0 (per-spawn already scaled)", function()
    -- runOneWave multiplies spawn.hpMult × phaseHpMult; v2 builds the
    -- per-spawn hpMult with WaveHpRamp + LoadoutMult baked in, and
    -- passes phaseHpMult=1.0 to runOneWave. So waveData.hpMult must
    -- be 1.0 (else double-counting).
    for _, w in ipairs({ 1, 5, 12, 24 }) do
        local wd = buildFailureCurveWaveData(w, 1.0)
        Tests.assertNear(wd.hpMult, 1.0, 0.001,
            ("waveData.hpMult should be 1.0, got %.3f at wave %d"):format(wd.hpMult, w))
    end
end)

Tests.test("FailureCurve.buildWaveData: spawn.interval defaults present", function()
    local wd = buildFailureCurveWaveData(2, 1.0)
    for i, spawn in ipairs(wd.spawns) do
        Tests.assertTrue(spawn.interval ~= nil,
            ("Combined spawn[%d] missing interval"):format(i))
    end
end)

-- ea3-117 boot-test fix: explicit table return (was `return nil` which
-- somehow read as "did not return exactly one value" in Studio after
-- two clean boots in a row). Same shape as Tests module's own return.
return {}
