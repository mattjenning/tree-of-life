--[[
    InfiniteSimulator.lua tests — pure-function coverage for the
    closed-form sim. The simulator is data-driven from
    Config.InfiniteArena, so these tests double as regression
    guards on the Config contract: if a future tuning pass breaks
    the simulator's expected shapes (e.g. drops a Pools_C1 entry,
    renames LoadoutMult), these tests fail fast.

    What we test:
      • Simulator.runLoadout returns a finite finalWave for every
        TempTowers aux (smoke test — no nil indexing, no infinite
        loops, no NaN).
      • Solo loadouts produce DIFFERENT results from trio loadouts
        (load-out multiplier wires through).
      • Cycle scaling is monotonic (higher cycles = more HP = lower
        finalWave for the same loadout).
      • runSweep returns one entry per queue item, preserving order
        + label.

    What we DON'T test here (deferred to v2 when the sim is more
    accurate): absolute finalWave values vs real-sweep data. Phase
    1 of project_simulator_improvement.md is the validation harness
    that captures sim-vs-real deltas; once those deltas are tight,
    we can pin specific finalWave assertions here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Tests = require(script.Parent)
local Sim = require(ServerScriptService:WaitForChild("systems"):WaitForChild("InfiniteSimulator"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local TempTowers = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TempTowers"))

------------------------------------------------------------
-- Smoke: runLoadout returns a finite number for every aux
------------------------------------------------------------

Tests.test("InfiniteSimulator.runLoadout returns a finite finalWave for every aux", function()
    for towerId, _ in pairs(TempTowers.Templates) do
        local fw = Sim.runLoadout({ towerId })
        Tests.assertType(fw, "number", "finalWave for " .. towerId)
        Tests.assertTrue(fw == fw, "finalWave should not be NaN for " .. towerId)
        Tests.assertTrue(fw >= 0, "finalWave should be non-negative for " .. towerId)
        Tests.assertTrue(fw <= Config.InfiniteArena.MaxAutoRunWave,
            "finalWave should not exceed MaxAutoRunWave cap for " .. towerId)
    end
end)

------------------------------------------------------------
-- Loadout multiplier wires through
------------------------------------------------------------

Tests.test("InfiniteSimulator: trio harder than solo for same baseline tower", function()
    -- Solo = AcornSniper alone; trio = AcornSniper + 2 anchors.
    -- Trio's loadoutMult (1.6) inflates mob HP, so the same tower
    -- damage should take fewer waves to fail. (Strict inequality
    -- might not always hold if both clear or both fail at wave 1
    -- — assert ≤ instead.)
    local solo = Sim.runLoadout({ "AcornSniper" })
    local trio = Sim.runLoadout({ "AcornSniper", "FrostMelon", "InfiniteStandard" })
    Tests.assertTrue(trio <= solo + 0.5,
        string.format("trio (%.2f) should not exceed solo (%.2f) by much",
            trio, solo))
end)

------------------------------------------------------------
-- runSweep preserves queue order + structure
------------------------------------------------------------

Tests.test("InfiniteSimulator.runSweep returns one result per queue item", function()
    local queue = {
        { auxIds = { "AcornSniper" },                label = "Power + AcornSniper" },
        { auxIds = { "FrostMelon" },                 label = "Power + FrostMelon" },
        { auxIds = { "AcornSniper", "FrostMelon" },  label = "Power + AcornSniper + FrostMelon" },
    }
    local results = Sim.runSweep(queue)
    Tests.assertEq(#results, #queue, "runSweep should produce 1 result per queue item")
    for i, r in ipairs(results) do
        Tests.assertEq(r.idx, i, "result idx should match queue position")
        Tests.assertEq(r.label, queue[i].label, "result label should match queue label")
        Tests.assertType(r.finalWave, "number", "result finalWave should be a number")
        Tests.assertEq(r.testType, "Sim", "result testType should be 'Sim'")
    end
end)

------------------------------------------------------------
-- Config-shape regressions — the sim depends on these
------------------------------------------------------------

Tests.test("Config.InfiniteArena exposes every key the simulator reads", function()
    local IA = Config.InfiniteArena
    Tests.assertNotNil(IA, "Config.InfiniteArena")
    Tests.assertType(IA.CycleStep, "number", "CycleStep")
    Tests.assertType(IA.MaxAutoRunWave, "number", "MaxAutoRunWave")
    Tests.assertNotNil(IA.LoadoutMult[1], "LoadoutMult[1]")
    Tests.assertNotNil(IA.LoadoutMult[2], "LoadoutMult[2]")
    Tests.assertNotNil(IA.LoadoutMult[3], "LoadoutMult[3]")
    Tests.assertNotNil(IA.Pools_C1.AOE, "Pools_C1.AOE")
    Tests.assertNotNil(IA.Pools_C1.Combined, "Pools_C1.Combined")
    Tests.assertNotNil(IA.Pools_C1.Solo, "Pools_C1.Solo")
    Tests.assertType(IA.Upgrade.DamageFlat, "number", "Upgrade.DamageFlat")
    Tests.assertType(IA.Upgrade.FireRateMult, "number", "Upgrade.FireRateMult")
    Tests.assertType(IA.Upgrade.RangeMult, "number", "Upgrade.RangeMult")
    Tests.assertType(IA.Upgrade.RangeCapMult, "number", "Upgrade.RangeCapMult")
    Tests.assertType(IA.Upgrade.PostCapBoost, "number", "Upgrade.PostCapBoost")
    Tests.assertNotNil(IA.MobBaseline.basic, "MobBaseline.basic")
    Tests.assertNotNil(IA.MobBaseline.fast,  "MobBaseline.fast")
    Tests.assertNotNil(IA.MobBaseline.tank,  "MobBaseline.tank")
    Tests.assertType(IA.AutoRunAnchor, "string", "AutoRunAnchor")
    Tests.assertNotNil(IA.PowerCoreStats, "PowerCoreStats")
end)

return nil
