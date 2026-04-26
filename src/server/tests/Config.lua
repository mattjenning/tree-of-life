--[[
    Config.lua tests — structure + invariants for the global tuning
    table. Catches typos / accidental mutation, plus a few hand-checked
    sanity asserts on the boss HP ramp (monotonic across the 12-boss
    sequence is a load-bearing invariant per CLAUDE.md).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests  = require(script.Parent)
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

------------------------------------------------------------
-- Top-level sections present
------------------------------------------------------------

Tests.test("Config has expected top-level sections", function()
    Tests.assertNotNil(Config.Grid, "Config.Grid")
    Tests.assertNotNil(Config.Waves, "Config.Waves")
    Tests.assertNotNil(Config.Towers, "Config.Towers")
    Tests.assertNotNil(Config.Map2, "Config.Map2")
    Tests.assertNotNil(Config.Map3, "Config.Map3")
    Tests.assertNotNil(Config.BossHp, "Config.BossHp")
    Tests.assertNotNil(Config.Phoenix, "Config.Phoenix")
end)

------------------------------------------------------------
-- Grid invariants
------------------------------------------------------------

Tests.test("Grid TotalCols equals sum of all four maps' Cols", function()
    Tests.assertEq(Config.Grid.TotalCols,
        Config.Grid.Map1Cols + Config.Grid.Map2Cols
            + Config.Grid.Map3Cols + Config.Grid.Map4Cols,
        "Grid.TotalCols")
end)

Tests.test("Map4 cols start where Map3 ends", function()
    Tests.assertEq(Config.Grid.Map4ColOffset,
        Config.Grid.Map1Cols + Config.Grid.Map2Cols + Config.Grid.Map3Cols,
        "Map4ColOffset should equal Map1Cols + Map2Cols + Map3Cols")
end)

Tests.test("Map2 cols start where Map1 ends", function()
    Tests.assertEq(Config.Grid.Map2ColOffset, Config.Grid.Map1Cols,
        "Map2ColOffset should equal Map1Cols")
end)

Tests.test("Map3 cols start where Map2 ends", function()
    Tests.assertEq(Config.Grid.Map3ColOffset,
        Config.Grid.Map1Cols + Config.Grid.Map2Cols,
        "Map3ColOffset should equal Map1Cols + Map2Cols")
end)

Tests.test("Map3 is 20% larger than Map2 (within rounding)", function()
    -- Map2 has 75 cols × 55 rows; map 3 should be 20% bigger (90 × 66).
    Tests.assertEq(Config.Grid.Map3Cols, math.floor(Config.Grid.Map2Cols * 1.20),
        "Map3Cols should be Map2Cols * 1.20")
    Tests.assertEq(Config.Grid.Map3Rows, math.floor(Config.Grid.Map2Rows * 1.20),
        "Map3Rows should be Map2Rows * 1.20")
end)

Tests.test("Grid CellSize is positive", function()
    Tests.assertTrue(Config.Grid.CellSize > 0)
end)

------------------------------------------------------------
-- Waves invariants
------------------------------------------------------------

Tests.test("Waves PerStage and TotalStages are positive integers", function()
    Tests.assertTrue(Config.Waves.PerStage >= 1)
    Tests.assertTrue(Config.Waves.TotalStages >= 1)
end)

------------------------------------------------------------
-- Boss HP ramp — load-bearing invariant per memory project_boss_names.md
-- 9 stage bosses (3 maps × 3 stages) — HP must climb monotonically
-- across the sequence so each fight feels harder than the last.
------------------------------------------------------------

Tests.test("Boss HP ramps monotonically across the 9 stage bosses", function()
    local prev = 0
    for mapId = 1, 3 do
        local mapTbl = Config.BossHp.StageByMap[mapId]
        Tests.assertNotNil(mapTbl, "BossHp.StageByMap[" .. mapId .. "]")
        for stage = 1, 3 do
            local hp = mapTbl[stage]
            Tests.assertNotNil(hp, string.format("Boss HP for map %d stage %d", mapId, stage))
            Tests.assertTrue(hp > prev,
                string.format("Boss HP at map %d stage %d (%d) should exceed previous (%d)",
                    mapId, stage, hp, prev))
            prev = hp
        end
    end
end)

------------------------------------------------------------
-- Map 2 staircase fractions — must be sorted ascending and end at 1.0
------------------------------------------------------------

Tests.test("Map2 StageUnlockFractions sorted ascending and within (0,1]", function()
    local prev = 0
    for stage = 1, 4 do
        local frac = Config.Map2.StageUnlockFractions[stage]
        Tests.assertNotNil(frac, "fraction for stage " .. stage)
        Tests.assertTrue(frac > prev,
            "stage " .. stage .. " fraction should exceed prior")
        Tests.assertTrue(frac <= 1.0,
            "stage " .. stage .. " fraction should be <= 1.0")
        prev = frac
    end
end)

------------------------------------------------------------
-- Phoenix cooldowns — higher rarity = shorter cooldown
------------------------------------------------------------

Tests.test("Phoenix cooldowns shorten with rarity", function()
    local order = { "Common", "Uncommon", "Rare", "Exceptional", "Special" }
    local prev = math.huge
    for _, name in ipairs(order) do
        local cd = Config.Phoenix.Cooldowns[name]
        Tests.assertNotNil(cd, "Phoenix.Cooldowns[" .. name .. "]")
        Tests.assertTrue(cd < prev,
            "rarity " .. name .. " cooldown should be < previous")
        prev = cd
    end
end)

------------------------------------------------------------
-- Frozen — every nested table should reject mutation
------------------------------------------------------------

Tests.test("Config is deeply frozen", function()
    Tests.assertThrows(function() Config.Grid.CellSize = 999 end,
        "Config.Grid should be frozen")
    Tests.assertThrows(function() Config.NewSection = {} end,
        "Config root should be frozen")
    Tests.assertThrows(function()
        Config.BossHp.StageByMap[1][1] = 0
    end, "Config.BossHp.StageByMap[1] should be frozen")
end)

return nil
