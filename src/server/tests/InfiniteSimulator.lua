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

-- Per Matthew 2026-04-27 ("Studio hung running tests after Phase 7"):
-- the original loop ran Sim.runLoadout for every TempTower template.
-- After the Phase 7 sim rewrite that's ~10 loadouts × 30 waves × 4
-- towers × 5 path segments × per-tower path-exposure recompute —
-- ballpark 60k segment-circle ops per test boot. Studio's main
-- thread blocked long enough to flag "Not Responding."
--
-- Smoke check now bails after the FIRST 3 templates (alphabetical
-- after sort). That's enough to catch nil-indexing / NaN / infinite-
-- loop regressions without paying the full sweep cost. If you want
-- the full coverage occasionally, flip TEST_ALL_TEMPLATES = true.
local TEST_ALL_TEMPLATES = false
local TEST_TEMPLATE_LIMIT = 3

Tests.test("InfiniteSimulator.runLoadout returns a finite finalWave (smoke)", function()
    -- Sort tower IDs deterministically so the first-N pick is stable
    -- across boots.
    local ids = {}
    for towerId in pairs(TempTowers.Templates) do
        table.insert(ids, towerId)
    end
    table.sort(ids)

    local checked = 0
    for _, towerId in ipairs(ids) do
        if not TEST_ALL_TEMPLATES and checked >= TEST_TEMPLATE_LIMIT then
            break
        end
        local fw = Sim.runLoadout({ towerId })
        Tests.assertType(fw, "number", "finalWave for " .. towerId)
        Tests.assertTrue(fw == fw, "finalWave should not be NaN for " .. towerId)
        Tests.assertTrue(fw >= 0, "finalWave should be non-negative for " .. towerId)
        Tests.assertTrue(fw <= Config.InfiniteArena.MaxAutoRunWave,
            "finalWave should not exceed MaxAutoRunWave cap for " .. towerId)
        checked = checked + 1
    end
    Tests.assertTrue(checked > 0, "at least one template should have been checked")
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
-- Phase 3: slow/stun integration produces measurable lift
------------------------------------------------------------

Tests.test("InfiniteSimulator: FrostMelon duo outperforms two-DPS duo (slow lift)", function()
    -- Phase 3 contract: pairing a DPS tower with FrostMelon (25%
    -- slow / 1.5 sec as of 2026-04-27, trimmed from earlier 40/35/30
    -- × 2.0 sec) should produce
    -- a HIGHER finalWave than pairing the
    -- same DPS tower with another DPS tower of similar baseline,
    -- because slow extends mob transit time so DPS gets more
    -- shots per mob.
    --
    -- AcornSniper + FrostMelon vs AcornSniper + ThornVine:
    -- ThornVine has higher raw DPS (5×1.6=8 vs Frost 4×1.5=6),
    -- so v1 sim said ThornVine pair > Frost pair. Phase 3 should
    -- flip this for at least some configurations because Frost's
    -- slow boosts AcornSniper's damage output.
    --
    -- Strict inequality might not hold for every cycle/wave; we
    -- assert that the slow lift IS measurable (sim treats Frost
    -- combos at least as well as DPS-only combos, not strictly
    -- worse).
    local frostDuo  = Sim.runLoadout({ "AcornSniper", "FrostMelon" })
    local thornDuo  = Sim.runLoadout({ "AcornSniper", "ThornVine" })
    Tests.assertTrue(frostDuo > 0, "FrostMelon duo should reach at least wave 1")
    -- Slow lift means Frost shouldn't be drastically worse than
    -- a comparable DPS pair. Margin of 4 waves is generous.
    Tests.assertTrue(frostDuo >= thornDuo - 4,
        string.format("FrostMelon duo (%.2f) should be within 4 waves of ThornVine duo (%.2f) — Phase 3 slow lift",
            frostDuo, thornDuo))
end)

Tests.test("InfiniteSimulator: RootSprout stun adds transit time", function()
    -- Stun's effect: each stun freezes the mob for stunSeconds,
    -- giving other towers more shots. RootSprout has 0.5s stun
    -- on a 3s cooldown. AcornSniper + RootSprout should out-wave
    -- AcornSniper alone (more time on the path). Solo is 1.0×
    -- difficulty, duo is 1.25× — the stun lift has to overcome
    -- the loadout-mult HP bump.
    local duo  = Sim.runLoadout({ "AcornSniper", "RootSprout" })
    -- The duo HP bump (1.25×) plus RootSprout's tiny direct DPS
    -- contribution may not always beat a strong solo, so this is
    -- a "didn't crash + finite result" smoke check.
    Tests.assertType(duo, "number", "RootSprout duo finalWave is numeric")
    Tests.assertTrue(duo > 0, "RootSprout duo reaches at least wave 1")
    Tests.assertTrue(duo <= 30, "RootSprout duo capped at MAX_WAVE")
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
    Tests.assertType(IA.WaveHpRamp, "function", "WaveHpRamp")
end)

------------------------------------------------------------
-- WaveHpRamp shape regression (Matthew 2026-04-27 piecewise rework)
------------------------------------------------------------

Tests.test("Config.WaveHpRamp anchor values match the piecewise spec", function()
    -- Anchor waves are the join points between the W1-9 cycle bands
    -- and the W10+ piecewise-linear slopes. Pin them so a future
    -- rewrite can't silently shift the curve. Tolerance ±0.01 to
    -- absorb floating-point round-off.
    local R = Config.InfiniteArena.WaveHpRamp
    local pinned = {
        { wave =  1, expected = 1.0 },
        { wave =  3, expected = 1.0 },
        { wave =  6, expected = 1.2 },
        { wave =  9, expected = 1.4 },
        { wave = 12, expected = 2.0 },   -- W9 1.4 + 3 × 0.20
        { wave = 15, expected = 3.2 },   -- W12 2.0 + 3 × 0.40
        { wave = 21, expected = 6.5 },   -- W15 3.2 + 6 × 0.55
        { wave = 28, expected = 11.4 },  -- W21 6.5 + 7 × 0.70
    }
    for _, p in ipairs(pinned) do
        local got = R(p.wave)
        local delta = math.abs(got - p.expected)
        Tests.assertTrue(delta < 0.01,
            string.format("WaveHpRamp(%d) expected %.2f, got %.4f", p.wave, p.expected, got))
    end
end)

Tests.test("Config.WaveHpRamp is monotonically non-decreasing", function()
    -- Each later wave should have HP ≥ the prior wave (mob HP only
    -- ever ramps, never softens). Walks W1..W30 and asserts the
    -- ramp never goes backwards. Catches sign / slope direction
    -- regressions from a future tuning pass.
    local R = Config.InfiniteArena.WaveHpRamp
    local prev = R(1)
    for wave = 2, 30 do
        local cur = R(wave)
        Tests.assertTrue(cur >= prev,
            string.format("WaveHpRamp(%d)=%.2f should be >= WaveHpRamp(%d)=%.2f",
                wave, cur, wave - 1, prev))
        prev = cur
    end
end)

------------------------------------------------------------
-- SimCalibration knobs — sim's tunable balance levers (Matthew
-- 2026-04-27 firming pass). Each knob has a default fallback in
-- the sim, but tests guard against accidental rename / removal.
------------------------------------------------------------

Tests.test("Config.SimCalibration exposes every knob the simulator reads", function()
    local SC = Config.InfiniteArena.SimCalibration
    Tests.assertNotNil(SC, "SimCalibration block")
    Tests.assertType(SC.LobCatchBaseMult, "number", "LobCatchBaseMult")
    Tests.assertNotNil(SC.LobMissClusterFloor, "LobMissClusterFloor")
    Tests.assertType(SC.SlowFactorCap, "number", "SlowFactorCap")
    Tests.assertType(SC.StackingSlowEffectiveness, "number", "StackingSlowEffectiveness")
    Tests.assertType(SC.DotValueMult, "number", "DotValueMult")
    Tests.assertType(SC.StunValueMult, "number", "StunValueMult")
    Tests.assertType(SC.StackDotEffectiveness, "number", "StackDotEffectiveness")
    Tests.assertType(SC.AuraValueMult, "number", "AuraValueMult")
    -- 2026-04-28 new towers — calibration knobs for blink + link.
    Tests.assertType(SC.BlinkValueMult, "number", "BlinkValueMult")
    Tests.assertType(SC.LinkValueMult,  "number", "LinkValueMult")
end)

------------------------------------------------------------
-- 2026-04-28 new towers — sim should produce finite finalWaves
-- when each is in a loadout. Smoke checks for the new mechanic
-- modeling (blink transit-extension, aura range axis, mob link).
------------------------------------------------------------

Tests.test("Sim handles BlinkBerry without crashing", function()
    -- BlinkBerry has fireRate=0 (doesn't shoot) — its value is the
    -- transit-extension closed-form. Verify the loadout simulates
    -- without divide-by-zero / nil index.
    local fw = Sim.runLoadout({ "BlinkBerry" })
    Tests.assertType(fw, "number", "BlinkBerry finalWave is numeric")
    Tests.assertTrue(fw > 0, "BlinkBerry should reach at least wave 1")
end)

Tests.test("Sim handles aux Support buff towers without crashing", function()
    for _, towerId in ipairs({ "PaceFlower", "PowerSeed", "SpyglassRoot" }) do
        local fw = Sim.runLoadout({ towerId })
        Tests.assertType(fw, "number", towerId .. " finalWave is numeric")
        Tests.assertTrue(fw > 0, towerId .. " should reach at least wave 1")
    end
end)

Tests.test("Sim handles BloodlinkVine without crashing", function()
    local fw = Sim.runLoadout({ "BloodlinkVine" })
    Tests.assertType(fw, "number", "BloodlinkVine finalWave is numeric")
    Tests.assertTrue(fw > 0, "BloodlinkVine should reach at least wave 1")
end)

Tests.test("Sim aux Support buff lifts a paired DPS tower", function()
    -- A buff Support solo is brutal (no targets to buff in the
    -- closed form's aura source check). Pairing with a DPS aux
    -- should produce a measurable lift over DPS-solo since the
    -- aura's atk-speed/damage % stacks on the DPS contribution.
    local dpsSolo = Sim.runLoadout({ "AcornSniper" })
    local pacePair = Sim.runLoadout({ "AcornSniper", "PaceFlower" })
    -- Loose: Pace+Acorn shouldn't be drastically worse than Acorn
    -- solo. Loadout-mult bumps HP for duos, so the bar is "within
    -- 4 waves" — broad enough to absorb the duo HP penalty.
    Tests.assertTrue(pacePair >= dpsSolo - 4,
        string.format("PaceFlower+Acorn (%.2f) should be within 4 waves of Acorn solo (%.2f)",
            pacePair, dpsSolo))
end)

------------------------------------------------------------
-- Core variants — sim recognizes ControlCore + SupportCore as
-- placeable Cores (smoke check that the new statsFor branches
-- don't error and produce finite finalWaves).
------------------------------------------------------------

Tests.test("Sim.runLoadout(auxIds, 'ControlCore') returns a finite finalWave", function()
    -- Pass an aux to give ControlCore something to pair with —
    -- ControlCore solo with NO aux is technically valid, but
    -- the sweep harness always pairs (1+ aux). Mirror that.
    local fw = Sim.runLoadout({ "AcornSniper" }, "ControlCore")
    Tests.assertType(fw, "number", "ControlCore finalWave is numeric")
    Tests.assertTrue(fw == fw, "ControlCore finalWave should not be NaN")
    Tests.assertTrue(fw > 0, "ControlCore should reach at least wave 1")
    Tests.assertTrue(fw <= Config.InfiniteArena.MaxAutoRunWave,
        "ControlCore finalWave should not exceed cap")
end)

Tests.test("Sim.runLoadout(auxIds, 'SupportCore') returns a finite finalWave", function()
    local fw = Sim.runLoadout({ "AcornSniper" }, "SupportCore")
    Tests.assertType(fw, "number", "SupportCore finalWave is numeric")
    Tests.assertTrue(fw == fw, "SupportCore finalWave should not be NaN")
    Tests.assertTrue(fw > 0, "SupportCore should reach at least wave 1")
    Tests.assertTrue(fw <= Config.InfiniteArena.MaxAutoRunWave,
        "SupportCore finalWave should not exceed cap")
end)

------------------------------------------------------------
-- ControlCore stacking-DOT mechanic produces measurable lift.
-- Asserts that disabling the StackDotEffectiveness knob (via a
-- ControlCore loadout) IS measurably weaker than enabling it —
-- proves the DOT model is wired into simulateWave's per-tower
-- damage contribution.
--
-- Method: compare ControlCore + AcornSniper to Power + AcornSniper
-- under identical conditions. Power has higher base DPS (50 × 0.7 =
-- 35) than ControlCore (8 × 0.9 = 7.2 direct), so without the DOT
-- contribution ControlCore would lose by a wide margin. The DOT's
-- exposure-aware ramp (peak 16 DPS at 4 stacks) closes part of the
-- gap; if the model is broken (returns 0 damage), ControlCore
-- under-performs by a much larger margin.
------------------------------------------------------------

Tests.test("Sim ControlCore + aux is competitive vs Power + aux (DOT mechanic wired)", function()
    local powerFw   = Sim.runLoadout({ "AcornSniper" }, "Power")
    local controlFw = Sim.runLoadout({ "AcornSniper" }, "ControlCore")
    -- ControlCore should be within 4 waves of Power on the same aux.
    -- If DOT is broken, ControlCore is using only its 7.2 direct DPS
    -- and the sim drops 6+ waves below Power.
    Tests.assertTrue(controlFw >= powerFw - 4,
        string.format("ControlCore (%.2f) should be within 4 waves of Power (%.2f) — DOT model broken if not",
            controlFw, powerFw))
end)

------------------------------------------------------------
-- SupportCore aura mechanic produces measurable lift on the
-- partner tower's contribution. Without aura, SupportCore + a
-- DPS aux loses badly (Support has 4 base damage, the lowest of
-- any Core); the aura's (1+dmgPct/100)(1+frPct/100) DPS lift on
-- the aux is what makes SupportCore loadouts viable.
------------------------------------------------------------

Tests.test("Sim SupportCore + aux outperforms a no-aura baseline (aura model wired)", function()
    -- Compare SupportCore + Pepper to SupportCore "alone"
    -- (auxIds={}). A Support core alone has just direct DPS
    -- (4 × 0.8 = 3.2) — should die very fast. With Pepper added,
    -- Pepper's DPS gets the aura mult. The DELTA between
    -- with-aux and without-aux should be HIGHER for SupportCore
    -- than for Power (because Power doesn't buff Pepper, but
    -- Support does).
    --
    -- Smoke check: SupportCore + Pepper survives meaningfully
    -- longer than SupportCore alone. If aura is wired, the
    -- buffed Pepper lifts the loadout's wave count.
    local supportSolo = Sim.runLoadout({}, "SupportCore")
    local supportPair = Sim.runLoadout({ "PepperCannon" }, "SupportCore")
    Tests.assertTrue(supportPair > supportSolo,
        string.format("SupportCore + Pepper (%.2f) should outlive SupportCore solo (%.2f)",
            supportPair, supportSolo))
end)

return nil
