--[[
    InfiniteValidator.lua tests — pure-function coverage for the
    sim-vs-real delta harness. Per project_simulator_improvement.md
    Phase 1: every later sim phase needs a measurable success metric
    (did the median delta shrink?), so this harness is load-bearing.
    These tests pin its math.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Tests = require(script.Parent)
local Validator = require(ServerScriptService:WaitForChild("systems"):WaitForChild("InfiniteValidator"))

------------------------------------------------------------
-- Fixtures
------------------------------------------------------------

local function fixture()
    local roleByTowerId = {
        AcornSniper     = "DPS",
        ThornVine       = "DPS",
        FrostMelon      = "Control",
        RootSprout      = "Control",
        InfiniteStandard = "DPS",
    }

    -- Sim says solo AcornSniper goes to wave 16. Real has 3 runs
    -- averaging 14. Delta = +2 (sim overestimates by 2).
    -- Sim says duo Acorn+FrostMelon goes to wave 22. Real has 1
    -- run at 18. Delta = +4.
    -- Sim says trio (Acorn+Frost+Root+Anchor) goes to wave 9. Real
    -- has 0 runs (untracked).
    -- Sim says solo ThornVine goes to wave 12. Real has 2 runs
    -- averaging 13. Delta = -1 (sim underestimates).
    local sim = {
        { auxIds = {"AcornSniper"},                                finalWave = 16, label = "Power + AcornSniper" },
        { auxIds = {"AcornSniper", "FrostMelon"},                  finalWave = 22, label = "Power + AcornSniper + FrostMelon" },
        { auxIds = {"AcornSniper", "FrostMelon", "InfiniteStandard"},
                                                                    finalWave = 9, label = "Power + AcornSniper + FrostMelon + InfiniteStandard" },
        { auxIds = {"ThornVine"},                                  finalWave = 12, label = "Power + ThornVine" },
    }
    local real = {
        { auxIds = {"AcornSniper"}, finalWave = 13 },
        { auxIds = {"AcornSniper"}, finalWave = 14 },
        { auxIds = {"AcornSniper"}, finalWave = 15 },
        { auxIds = {"AcornSniper", "FrostMelon"}, finalWave = 18 },
        { auxIds = {"ThornVine"}, finalWave = 12 },
        { auxIds = {"ThornVine"}, finalWave = 14 },
    }
    return sim, real, roleByTowerId
end

------------------------------------------------------------
-- compare()
------------------------------------------------------------

Tests.test("Validator.compare: matches loadouts by sorted-aux key", function()
    local sim, real, roles = fixture()
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    Tests.assertEq(#report.perLoadout, 3, "3 of 4 sim loadouts have a real match")
    Tests.assertEq(report.untracked, 1, "1 sim loadout (the trio) had no real match")
end)

Tests.test("Validator.compare: delta = sim - realAvg", function()
    local sim, real, roles = fixture()
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    -- Find the AcornSniper solo entry
    local found = false
    for _, e in ipairs(report.perLoadout) do
        if e.label == "Power + AcornSniper" then
            Tests.assertNear(e.realAvgWave, 14.0, 0.001, "AcornSniper real avg = (13+14+15)/3 = 14")
            Tests.assertNear(e.delta, 2.0, 0.001, "AcornSniper delta = 16 - 14 = +2")
            Tests.assertEq(e.realRuns, 3, "3 real runs aggregated")
            Tests.assertEq(e.category, "Solo")
            Tests.assertEq(e.roleMix, "pureDPS")
            found = true
        end
    end
    Tests.assertTrue(found, "AcornSniper solo entry should exist")
end)

Tests.test("Validator.compare: trio anchor excluded from carries", function()
    local sim, real, roles = fixture()
    -- Add a real match for the trio so the sim entry isn't
    -- untracked. InfiniteStandard should still be excluded
    -- from byCarries because it's the constant trio anchor.
    table.insert(real, {
        auxIds = {"AcornSniper", "FrostMelon", "InfiniteStandard"}, finalWave = 8,
    })
    local report2 = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    Tests.assertNil(report2.buckets.byCarries.InfiniteStandard,
        "InfiniteStandard is the trio anchor — excluded from byCarries")
end)

Tests.test("Validator.compare: aggregates by category", function()
    local sim, real, roles = fixture()
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    -- 2 solos (AcornSniper +2, ThornVine -1), 1 duo (+4), 0 trio
    local solo = report.buckets.byCategory.Solo
    local duo  = report.buckets.byCategory.Duo
    Tests.assertEq(solo.count, 2, "2 solo deltas")
    Tests.assertNear(solo.signedMean, 0.5, 0.001, "(2 + -1) / 2 = 0.5")
    Tests.assertEq(duo.count, 1, "1 duo delta")
    Tests.assertNear(duo.signedMean, 4.0, 0.001, "single duo delta = +4")
    Tests.assertNil(report.buckets.byCategory.Trio, "no trio deltas (untracked)")
end)

Tests.test("Validator.compare: aggregates by role mix", function()
    local sim, real, roles = fixture()
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    -- pureDPS: AcornSniper solo (+2), ThornVine solo (-1)
    -- balanced: Acorn+Frost duo (+4) (DPS + Control)
    local pd = report.buckets.byRoleMix.pureDPS
    local bal = report.buckets.byRoleMix.balanced
    Tests.assertNotNil(pd, "pureDPS bucket should exist")
    Tests.assertEq(pd.count, 2, "2 pureDPS entries")
    Tests.assertNotNil(bal, "balanced bucket should exist")
    Tests.assertEq(bal.count, 1, "1 balanced entry")
end)

Tests.test("Validator.compare: empty input → zero overall", function()
    local report = Validator.compare({ sim = {}, real = {}, roleByTowerId = {} })
    Tests.assertEq(report.overall.count, 0)
    Tests.assertEq(#report.perLoadout, 0)
    Tests.assertEq(report.untracked, 0)
end)

Tests.test("Validator.compare: nil input falls back to empty", function()
    local report = Validator.compare(nil)
    Tests.assertEq(report.overall.count, 0)
    Tests.assertEq(report.untracked, 0)
end)

------------------------------------------------------------
-- minBalanceVersion filter (ea3-123) — scope real entries to a
-- single era so cross-era cumulative pools don't muddy deltas.
------------------------------------------------------------

Tests.test("Validator.compare: minBalanceVersion filters out pre-era real runs", function()
    local roles = { AcornSniper = "DPS" }
    local sim = {
        { auxIds = {"AcornSniper"}, finalWave = 16, label = "Power + AcornSniper" },
    }
    local real = {
        -- v16 era: avg 8 (would pull delta to +8 if included)
        { auxIds = {"AcornSniper"}, finalWave =  7, balanceVersion = 16 },
        { auxIds = {"AcornSniper"}, finalWave =  9, balanceVersion = 16 },
        -- v17 era: avg 14 (real signal)
        { auxIds = {"AcornSniper"}, finalWave = 13, balanceVersion = 17 },
        { auxIds = {"AcornSniper"}, finalWave = 14, balanceVersion = 17 },
        { auxIds = {"AcornSniper"}, finalWave = 15, balanceVersion = 17 },
    }
    -- WITHOUT filter: avg = (7+9+13+14+15)/5 = 11.6, delta = 16 - 11.6 = +4.4
    local unfiltered = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    Tests.assertNear(unfiltered.perLoadout[1].realAvgWave, 11.6, 0.01,
        "no filter → avg across all 5 real runs")
    Tests.assertNear(unfiltered.perLoadout[1].delta, 4.4, 0.01)

    -- WITH filter ≥17: only v17 runs counted, avg = 14, delta = +2
    local filtered = Validator.compare({
        sim = sim, real = real, roleByTowerId = roles,
        minBalanceVersion = 17,
    })
    Tests.assertNear(filtered.perLoadout[1].realAvgWave, 14.0, 0.01,
        "filter ≥17 → only v17 runs (avg 14)")
    Tests.assertNear(filtered.perLoadout[1].delta, 2.0, 0.01)
    Tests.assertEq(filtered.perLoadout[1].realRuns, 3, "3 v17 real runs")
end)

Tests.test("Validator.compare: skippedByEra reflects pre-filter count", function()
    local roles = { AcornSniper = "DPS" }
    local sim = { { auxIds = {"AcornSniper"}, finalWave = 16 } }
    local real = {
        { auxIds = {"AcornSniper"}, finalWave =  7, balanceVersion = 15 },
        { auxIds = {"AcornSniper"}, finalWave =  9, balanceVersion = 16 },
        { auxIds = {"AcornSniper"}, finalWave = 13, balanceVersion = 17 },
    }
    local r = Validator.compare({
        sim = sim, real = real, roleByTowerId = roles,
        minBalanceVersion = 17,
    })
    Tests.assertEq(r.skippedByEra, 2, "v15 + v16 skipped (2 entries)")
    Tests.assertEq(r.minBalanceVersion, 17, "filter echoed in report")
end)

Tests.test("Validator.compare: missing balanceVersion treated as pre-era when filter active", function()
    local roles = { AcornSniper = "DPS" }
    local sim = { { auxIds = {"AcornSniper"}, finalWave = 16 } }
    local real = {
        -- Legacy run with no balanceVersion stamp — predates the
        -- balance-version system. Should be excluded by any filter.
        { auxIds = {"AcornSniper"}, finalWave =  8 },
        { auxIds = {"AcornSniper"}, finalWave = 14, balanceVersion = 17 },
    }
    local r = Validator.compare({
        sim = sim, real = real, roleByTowerId = roles,
        minBalanceVersion = 17,
    })
    Tests.assertEq(r.skippedByEra, 1, "legacy run with no balanceVersion skipped")
    Tests.assertEq(r.perLoadout[1].realRuns, 1, "only the v17 run aggregated")
end)

Tests.test("Validator.compare: nil minBalanceVersion → no filter (all real data)", function()
    local roles = { AcornSniper = "DPS" }
    local sim = { { auxIds = {"AcornSniper"}, finalWave = 16 } }
    local real = {
        { auxIds = {"AcornSniper"}, finalWave =  7, balanceVersion = 16 },
        { auxIds = {"AcornSniper"}, finalWave = 14, balanceVersion = 17 },
    }
    local r = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    Tests.assertEq(r.skippedByEra, 0, "no filter, nothing skipped")
    Tests.assertEq(r.perLoadout[1].realRuns, 2, "both real runs aggregated")
    Tests.assertNil(r.minBalanceVersion, "no filter recorded in report")
end)

------------------------------------------------------------
-- topByDelta (ea3-125) — TARGETED's "highest information value"
-- combo selector. Pure helper; no Roblox deps.
------------------------------------------------------------

Tests.test("Validator.topByDelta: returns top-N by abs(delta)", function()
    local sim, real, roles = fixture()
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    -- Fixture deltas: AcornSniper +2, AcornSniper+FrostMelon +4, ThornVine -1.
    -- Top-2 by |delta|: duo (+4), AcornSniper (+2).
    local top2 = Validator.topByDelta(report, 2)
    Tests.assertEq(#top2, 2, "n=2 returns 2 entries")
    Tests.assertNear(math.abs(top2[1].delta), 4, 0.001, "first is duo (|delta|=4)")
    Tests.assertNear(math.abs(top2[2].delta), 2, 0.001, "second is AcornSniper solo (|delta|=2)")
end)

Tests.test("Validator.topByDelta: nil n returns all entries sorted", function()
    local sim, real, roles = fixture()
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    local all = Validator.topByDelta(report)
    Tests.assertEq(#all, 3, "all 3 perLoadout entries")
    -- Sorted by |delta| desc: 4, 2, 1
    Tests.assertNear(math.abs(all[1].delta), 4, 0.001)
    Tests.assertNear(math.abs(all[2].delta), 2, 0.001)
    Tests.assertNear(math.abs(all[3].delta), 1, 0.001)
end)

Tests.test("Validator.topByDelta: n > count returns all available", function()
    local sim, real, roles = fixture()
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    local big = Validator.topByDelta(report, 99)
    Tests.assertEq(#big, 3, "request more than available → all 3")
end)

Tests.test("Validator.topByDelta: empty report returns empty list", function()
    local empty = Validator.compare({ sim = {}, real = {}, roleByTowerId = {} })
    local out = Validator.topByDelta(empty, 5)
    Tests.assertEq(#out, 0, "empty perLoadout → empty result")
end)

Tests.test("Validator.topByDelta: nil/malformed input returns empty list", function()
    Tests.assertEq(#Validator.topByDelta(nil, 5), 0)
    Tests.assertEq(#Validator.topByDelta({}, 5), 0,
        "missing perLoadout treated as empty")
end)

Tests.test("Validator.topByDelta: negative deltas ranked by magnitude", function()
    local roles = { AcornSniper = "DPS", ThornVine = "DPS", RootSprout = "Control" }
    local sim = {
        { auxIds = {"AcornSniper"}, finalWave = 10 },  -- delta = +1
        { auxIds = {"ThornVine"},   finalWave =  5 },  -- delta = -8
        { auxIds = {"RootSprout"},  finalWave = 12 },  -- delta = +3
    }
    local real = {
        { auxIds = {"AcornSniper"}, finalWave =  9 },
        { auxIds = {"ThornVine"},   finalWave = 13 },
        { auxIds = {"RootSprout"},  finalWave =  9 },
    }
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    local top1 = Validator.topByDelta(report, 1)
    Tests.assertEq(#top1, 1)
    Tests.assertNear(top1[1].delta, -8, 0.001,
        "ThornVine's -8 wins on |delta| despite being negative")
end)

Tests.test("Validator.toCsv: header + one row per perLoadout entry", function()
    local sim, real, roles = fixture()
    local report = Validator.compare({ sim = sim, real = real, roleByTowerId = roles })
    local csv = Validator.toCsv(report)
    -- Header + 3 perLoadout rows = 4 lines
    local lines = {}
    for line in csv:gmatch("[^\n]+") do table.insert(lines, line) end
    Tests.assertEq(#lines, 4, "header + 3 data rows")
    Tests.assertTrue(lines[1]:find("category"), "header includes 'category'")
    Tests.assertTrue(lines[1]:find("delta"), "header includes 'delta'")
end)

return nil
