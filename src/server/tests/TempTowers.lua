--[[
    TempTowers.lua tests — the rarity-scaling math is load-bearing
    (stamps every aux tower's combat stats at placement) and silently
    drifts hard if a multiplier table's values change. These tests pin
    the contract: Common shrinks numbers, Mythical multiplies them,
    and discrete fields use additive steps not multipliers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests      = require(script.Parent)
local TempTowers = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TempTowers"))

------------------------------------------------------------
-- Templates exist for every aux tower the game ships with
------------------------------------------------------------

Tests.test("Templates.PepperCannon has expected base stats", function()
    local t = TempTowers.Templates.PepperCannon
    Tests.assertNotNil(t, "PepperCannon template missing")
    Tests.assertEq(t.id, "PepperCannon")
    Tests.assertEq(t.damage, 25)
    Tests.assertEq(t.fireRate, 0.9)
    Tests.assertEq(t.range, 32)
    Tests.assertEq(t.splashRadius, 10)  -- bumped 8 → 10 in this session
end)

Tests.test("Every Template has the 4 mandatory fields", function()
    -- footprintWidth/Depth + damage + range used by placement / firing.
    -- A template missing any of these would silently break the tower.
    local required = { "id", "name", "displayName", "footprintWidth",
                       "footprintDepth", "damage", "range", "fireRate", "stock" }
    for id, tpl in pairs(TempTowers.Templates) do
        for _, field in ipairs(required) do
            Tests.assertNotNil(tpl[field],
                "Template " .. id .. " missing field " .. field)
        end
    end
end)

------------------------------------------------------------
-- RarityMults shape — the table the math relies on
------------------------------------------------------------

Tests.test("RarityMults has dps + secondary entries for every rarity", function()
    local rarities = { "Common", "Rare", "Exceptional", "Legendary", "Mythical" }
    for _, r in ipairs(rarities) do
        local m = TempTowers.RarityMults[r]
        Tests.assertNotNil(m, "RarityMults[" .. r .. "]")
        Tests.assertType(m.dps, "number")
        Tests.assertType(m.secondary, "number")
    end
end)

Tests.test("RarityMults DPS climbs monotonically Common → Mythical", function()
    local order = { "Common", "Rare", "Exceptional", "Legendary", "Mythical" }
    local prev = 0
    for _, r in ipairs(order) do
        local dps = TempTowers.RarityMults[r].dps
        Tests.assertTrue(dps > prev,
            string.format("RarityMults.%s.dps (%s) should exceed previous (%s)",
                r, tostring(dps), tostring(prev)))
        prev = dps
    end
end)

------------------------------------------------------------
-- resolveStats — DPS scaling
------------------------------------------------------------

Tests.test("resolveStats Common reduces damage + fireRate by RarityMults.Common.dps", function()
    local stats = TempTowers.resolveStats("PepperCannon", "Common")
    Tests.assertNotNil(stats)
    local tpl = TempTowers.Templates.PepperCannon
    local mult = TempTowers.RarityMults.Common.dps
    Tests.assertNear(stats.damage,   tpl.damage * mult,   0.0001, "damage scaled")
    Tests.assertNear(stats.fireRate, tpl.fireRate * mult, 0.0001, "fireRate scaled")
end)

Tests.test("resolveStats Rare leaves damage + fireRate at base (mult = 1.0)", function()
    -- Rare is the "neutral" rarity per RarityMults design.
    local stats = TempTowers.resolveStats("PepperCannon", "Rare")
    local tpl = TempTowers.Templates.PepperCannon
    Tests.assertNear(stats.damage, tpl.damage, 0.0001)
    Tests.assertNear(stats.fireRate, tpl.fireRate, 0.0001)
end)

Tests.test("resolveStats Mythical scales damage + fireRate up", function()
    local stats = TempTowers.resolveStats("PepperCannon", "Mythical")
    local tpl = TempTowers.Templates.PepperCannon
    Tests.assertTrue(stats.damage > tpl.damage,
        "Mythical damage should exceed base")
    Tests.assertTrue(stats.fireRate > tpl.fireRate,
        "Mythical fireRate should exceed base")
end)

Tests.test("resolveStats does NOT scale range with rarity", function()
    -- Range is a placement-readability stat; scaling it would let high-rarity
    -- towers cover mismatched footprints. Range stays at template value.
    for _, r in ipairs({ "Common", "Rare", "Exceptional", "Legendary", "Mythical" }) do
        local stats = TempTowers.resolveStats("PepperCannon", r)
        Tests.assertEq(stats.range, TempTowers.Templates.PepperCannon.range,
            "range should stay at base for rarity " .. r)
    end
end)

------------------------------------------------------------
-- resolveStats — secondary fields scale with .secondary mult
------------------------------------------------------------

Tests.test("resolveStats scales splashRadius with secondary mult", function()
    local tpl = TempTowers.Templates.PepperCannon
    for _, r in ipairs({ "Common", "Rare", "Legendary", "Mythical" }) do
        local stats = TempTowers.resolveStats("PepperCannon", r)
        local expected = tpl.splashRadius * TempTowers.RarityMults[r].secondary
        Tests.assertNear(stats.splashRadius, expected, 0.0001,
            "splashRadius scaling for rarity " .. r)
    end
end)

Tests.test("resolveStats scales cloudRadius for SporePuffball", function()
    local tpl = TempTowers.Templates.SporePuffball
    Tests.assertNotNil(tpl.cloudRadius)
    local stats = TempTowers.resolveStats("SporePuffball", "Mythical")
    Tests.assertTrue(stats.cloudRadius > tpl.cloudRadius,
        "Mythical cloudRadius should exceed base")
end)

------------------------------------------------------------
-- resolveStats — discrete fields use ADDITIVE steps not multipliers
-- (per docstring: pierceCount + chainJumps get RarityStep[rarity] added)
------------------------------------------------------------

Tests.test("resolveStats adds RarityStep to pierceCount", function()
    local tpl = TempTowers.Templates.ThornVine
    Tests.assertNotNil(tpl.pierceCount, "ThornVine should have pierceCount")
    for _, r in ipairs({ "Common", "Rare", "Exceptional", "Legendary", "Mythical" }) do
        local stats = TempTowers.resolveStats("ThornVine", r)
        local step = TempTowers.RarityStep[r] or 0
        Tests.assertEq(stats.pierceCount, tpl.pierceCount + step,
            "pierceCount = base + step for " .. r)
    end
end)

Tests.test("resolveStats adds RarityStep to chainJumps", function()
    local tpl = TempTowers.Templates.LightningRadish
    Tests.assertNotNil(tpl.chainJumps, "LightningRadish should have chainJumps")
    local stats = TempTowers.resolveStats("LightningRadish", "Mythical")
    Tests.assertEq(stats.chainJumps,
        tpl.chainJumps + TempTowers.RarityStep.Mythical)
end)

------------------------------------------------------------
-- resolveStats — error / fallback handling
------------------------------------------------------------

Tests.test("resolveStats returns nil for unknown towerId", function()
    Tests.assertNil(TempTowers.resolveStats("NopeTower", "Common"))
end)

Tests.test("resolveStats returns nil for unknown rarity", function()
    Tests.assertNil(TempTowers.resolveStats("PepperCannon", "Bogus"))
end)

Tests.test("resolveStats stamps the rarity onto stats.rarity", function()
    local stats = TempTowers.resolveStats("PepperCannon", "Legendary")
    Tests.assertEq(stats.rarity, "Legendary",
        "downstream consumers (display, save state) read stats.rarity")
end)

------------------------------------------------------------
-- shouldReplaceOnDuplicate — duplicate-roll policy
------------------------------------------------------------

Tests.test("shouldReplaceOnDuplicate: higher new rarity replaces lower", function()
    Tests.assertTrue(TempTowers.shouldReplaceOnDuplicate("Common", "Rare"))
    Tests.assertTrue(TempTowers.shouldReplaceOnDuplicate("Common", "Mythical"))
    Tests.assertTrue(TempTowers.shouldReplaceOnDuplicate("Legendary", "Mythical"))
end)

Tests.test("shouldReplaceOnDuplicate: same or lower is no-op", function()
    Tests.assertFalse(TempTowers.shouldReplaceOnDuplicate("Rare", "Rare"))
    Tests.assertFalse(TempTowers.shouldReplaceOnDuplicate("Mythical", "Common"))
    Tests.assertFalse(TempTowers.shouldReplaceOnDuplicate("Mythical", "Legendary"))
end)

------------------------------------------------------------
-- rollRarity — pure RNG, but degenerate inputs are well-defined
------------------------------------------------------------

Tests.test("rollRarity returns 'Common' on empty weight table", function()
    Tests.assertEq(TempTowers.rollRarity({}), "Common")
end)

Tests.test("rollRarity returns 'Common' on all-zero weights", function()
    Tests.assertEq(TempTowers.rollRarity({Common = 0, Rare = 0}), "Common")
end)

Tests.test("rollRarity always returns the only nonzero entry", function()
    -- 100 trials; with all-Mythical weight, every roll should be Mythical.
    for _ = 1, 100 do
        Tests.assertEq(
            TempTowers.rollRarity({ Common = 0, Rare = 0, Mythical = 1 }),
            "Mythical")
    end
end)

return nil
