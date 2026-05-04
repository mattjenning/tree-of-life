--[[
    AutoPicker.lua tests — coverage for the three pick modes:
    random, fixed-index, fixed-sequence. Phase E-prep landed
    random + fixed-index; ea3-42 (Phase E-3) added fixed-sequence
    for CORE AUTO's "one of each option" condition.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Tests = require(script.Parent)
local AutoPicker = require(ServerScriptService
    :WaitForChild("systems")
    :WaitForChild("AutoPicker"))

------------------------------------------------------------
-- Idle defaults + lifecycle
------------------------------------------------------------

Tests.test("AutoPicker.isActive() false before beginAuto", function()
    AutoPicker.endAuto()  -- defensive — make sure no leftover state
    Tests.assertFalse(AutoPicker.isActive())
end)

Tests.test("AutoPicker.endAuto() is idempotent", function()
    AutoPicker.endAuto()
    AutoPicker.endAuto()  -- second call shouldn't throw
    Tests.assertFalse(AutoPicker.isActive())
end)

------------------------------------------------------------
-- random mode
------------------------------------------------------------

Tests.test("random mode returns indices in [1, N]", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({ mode = "random" })
    for _ = 1, 50 do
        local idx = AutoPicker.pickIndex(5, "anyKey")
        Tests.assertTrue(idx >= 1 and idx <= 5,
            "random idx out of [1, 5]: " .. tostring(idx))
    end
    AutoPicker.endAuto()
end)

Tests.test("random mode handles numOptions = 1", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({ mode = "random" })
    Tests.assertEq(AutoPicker.pickIndex(1, "k"), 1)
    AutoPicker.endAuto()
end)

------------------------------------------------------------
-- fixed-index mode
------------------------------------------------------------

Tests.test("fixed-index returns the configured index per pickerKey", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({
        mode = "fixed-index",
        choices = { coreUpgrade = 2, tempTower = 3 },
    })
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 2)
    Tests.assertEq(AutoPicker.pickIndex(5, "tempTower"), 3)
    AutoPicker.endAuto()
end)

Tests.test("fixed-index falls through to random for unknown keys", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({
        mode = "fixed-index",
        choices = { coreUpgrade = 2 },
    })
    -- 50 calls with unknown key — all should be in [1, 4].
    for _ = 1, 50 do
        local idx = AutoPicker.pickIndex(4, "unknownKey")
        Tests.assertTrue(idx >= 1 and idx <= 4)
    end
    AutoPicker.endAuto()
end)

Tests.test("fixed-index falls through if index > numOptions", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({
        mode = "fixed-index",
        choices = { coreUpgrade = 99 },
    })
    -- 99 > 3, so falls through to random; should be in [1, 3].
    for _ = 1, 20 do
        local idx = AutoPicker.pickIndex(3, "coreUpgrade")
        Tests.assertTrue(idx >= 1 and idx <= 3)
    end
    AutoPicker.endAuto()
end)

------------------------------------------------------------
-- fixed-sequence mode (NEW in ea3-42)
------------------------------------------------------------

Tests.test("fixed-sequence walks the configured list per call", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({
        mode = "fixed-sequence",
        choices = { coreUpgrade = { 1, 2, 3 } },
    })
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 1)
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 2)
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 3)
    AutoPicker.endAuto()
end)

Tests.test("fixed-sequence wraps after exhausting the list", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({
        mode = "fixed-sequence",
        choices = { coreUpgrade = { 2, 3 } },
    })
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 2)
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 3)
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 2)  -- wrapped
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 3)
    AutoPicker.endAuto()
end)

Tests.test("fixed-sequence cursor is per-pickerKey", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({
        mode = "fixed-sequence",
        choices = {
            coreUpgrade = { 1, 2 },
            tempTower   = { 3, 1 },
        },
    })
    -- Interleave keys; each cursor should advance independently.
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 1)  -- coreUpgrade cursor → 1
    Tests.assertEq(AutoPicker.pickIndex(3, "tempTower"),   3)  -- tempTower cursor → 1
    Tests.assertEq(AutoPicker.pickIndex(3, "coreUpgrade"), 2)  -- coreUpgrade cursor → 2
    Tests.assertEq(AutoPicker.pickIndex(3, "tempTower"),   1)  -- tempTower cursor → 2
    AutoPicker.endAuto()
end)

Tests.test("fixed-sequence falls through if seq value > numOptions", function()
    AutoPicker.endAuto()  -- defensive: prior test may have thrown
    AutoPicker.beginAuto({
        mode = "fixed-sequence",
        choices = { coreUpgrade = { 99 } },
    })
    -- seq[1] = 99 > 3, so falls through to random.
    for _ = 1, 20 do
        local idx = AutoPicker.pickIndex(3, "coreUpgrade")
        Tests.assertTrue(idx >= 1 and idx <= 3)
    end
    AutoPicker.endAuto()
end)

Tests.test("AutoPicker.describe() includes mode label", function()
    AutoPicker.beginAuto({ mode = "fixed-sequence", choices = { coreUpgrade = {1, 2, 3} } })
    local s = AutoPicker.describe()
    Tests.assertType(s, "string")
    -- Plain-text mode (4th arg = true) — Lua patterns treat `-` as a
    -- lazy quantifier, so `s:find("fixed-sequence")` without the
    -- plain flag matches "fixe" + "d-" lazy + "sequence" → fails on
    -- the actual literal "fixed-sequence" string.
    Tests.assertTrue(s:find("fixed-sequence", 1, true) ~= nil,
        "describe() should mention fixed-sequence")
    AutoPicker.endAuto()
end)

------------------------------------------------------------
-- pickFromCards (ea3-121) — rarity-greedy upgradeCard pick
------------------------------------------------------------

Tests.test("pickFromCards: returns the highest-rarity index", function()
    AutoPicker.endAuto()  -- defensive
    AutoPicker.beginAuto({ mode = "random" })
    -- Exceptional at index 1 — the user's reported scenario from
    -- 2026-05-01 sweep log: Exceptional/Common/Common, picker
    -- randomly picked Common. New behavior: always picks index 1.
    local cards = {
        { rarity = "Exceptional" },
        { rarity = "Common" },
        { rarity = "Common" },
    }
    Tests.assertEq(AutoPicker.pickFromCards(cards, "upgradeCard"), 1)
    AutoPicker.endAuto()
end)

Tests.test("pickFromCards: picks the max even when not at index 1", function()
    AutoPicker.endAuto()
    AutoPicker.beginAuto({ mode = "random" })
    Tests.assertEq(AutoPicker.pickFromCards(
        { { rarity = "Common" }, { rarity = "Common" }, { rarity = "Mythical" } },
        "upgradeCard"), 3)
    Tests.assertEq(AutoPicker.pickFromCards(
        { { rarity = "Rare" }, { rarity = "Legendary" }, { rarity = "Common" } },
        "upgradeCard"), 2)
    AutoPicker.endAuto()
end)

Tests.test("pickFromCards: rarity-score ordering matches DEV_PICK_SCORE", function()
    AutoPicker.endAuto()
    AutoPicker.beginAuto({ mode = "random" })
    -- Special (5) > Legendary (4); pick Special.
    Tests.assertEq(AutoPicker.pickFromCards(
        { { rarity = "Legendary" }, { rarity = "Special" } }, "upgradeCard"), 2)
    -- Mythical (6) > Special (5); pick Mythical.
    Tests.assertEq(AutoPicker.pickFromCards(
        { { rarity = "Special" }, { rarity = "Mythical" } }, "upgradeCard"), 2)
    -- Exceptional (3) > Rare (2); pick Exceptional.
    Tests.assertEq(AutoPicker.pickFromCards(
        { { rarity = "Rare" }, { rarity = "Exceptional" } }, "upgradeCard"), 2)
    AutoPicker.endAuto()
end)

Tests.test("pickFromCards: random tiebreak among equal-rarity cards", function()
    AutoPicker.endAuto()
    AutoPicker.beginAuto({ mode = "random" })
    local cards = {
        { rarity = "Common" }, { rarity = "Common" }, { rarity = "Common" },
    }
    -- 50 calls; should hit each index at least once with random tiebreak.
    local seen = { false, false, false }
    for _ = 1, 50 do
        local idx = AutoPicker.pickFromCards(cards, "upgradeCard")
        Tests.assertTrue(idx >= 1 and idx <= 3, "idx in [1,3]")
        seen[idx] = true
    end
    Tests.assertTrue(seen[1] and seen[2] and seen[3],
        "random tiebreak should hit all 3 indices over 50 trials")
    AutoPicker.endAuto()
end)

Tests.test("pickFromCards: empty / nil card list returns 1 (defensive)", function()
    AutoPicker.endAuto()
    AutoPicker.beginAuto({ mode = "random" })
    Tests.assertEq(AutoPicker.pickFromCards({}, "upgradeCard"), 1)
    Tests.assertEq(AutoPicker.pickFromCards(nil :: any, "upgradeCard"), 1)
    AutoPicker.endAuto()
end)

Tests.test("pickFromCards: missing/unknown rarity treated as score 0", function()
    AutoPicker.endAuto()
    AutoPicker.beginAuto({ mode = "random" })
    -- Index 2 (Common, score 1) wins over index 1 (no rarity, score 0).
    Tests.assertEq(AutoPicker.pickFromCards(
        { { rarity = nil }, { rarity = "Common" } }, "upgradeCard"), 2)
    -- Unknown rarity treated like missing.
    Tests.assertEq(AutoPicker.pickFromCards(
        { { rarity = "Bogus" }, { rarity = "Rare" } }, "upgradeCard"), 2)
    AutoPicker.endAuto()
end)

Tests.test("pickFromCards: rarity-greedy regardless of AutoPicker mode", function()
    AutoPicker.endAuto()
    -- Even in fixed-index mode (which constrains pickIndex), rarity
    -- pick should still go for the max — this picker has a clear
    -- "best" answer that fixed-index doesn't override.
    AutoPicker.beginAuto({
        mode = "fixed-index",
        choices = { upgradeCard = 1 },
    })
    local cards = {
        { rarity = "Common" }, { rarity = "Mythical" }, { rarity = "Common" },
    }
    Tests.assertEq(AutoPicker.pickFromCards(cards, "upgradeCard"), 2,
        "rarity-greedy ignores fixed-index mode")
    AutoPicker.endAuto()
end)

return nil
