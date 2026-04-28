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
    Tests.assertEq(t.damage, 23)  -- 25 → 23 (2026-04-27 trim pass)
    Tests.assertEq(t.fireRate, 0.9)
    Tests.assertEq(t.range, 32)
    Tests.assertEq(t.splashRadius, 7)  -- 8 → 10 → 9 → 7 (bq sweep area cut)
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

------------------------------------------------------------
-- Recent balance regression guards (2026-04-27 bn-bq builds).
-- These pin specific stat values + role assignments so an
-- accidental edit / merge that reverts the tuning fails fast
-- instead of silently shifting the next sweep's tier list.
------------------------------------------------------------

Tests.test("FrostMelon stacking-slow shape + post-bq damage trim", function()
    -- Damage history: 4 → 10 → 5 → 6 → 9 → 6 → 4 (2026-04-27 bq
    -- post-sweep trim — option C, -33% self-DPS to push Frost off
    -- A-tier and emphasize slow synergy as the identity).
    local t = TempTowers.Templates.FrostMelon
    Tests.assertEq(t.damage, 4, "FrostMelon damage (post-bq trim)")
    Tests.assertEq(t.fireRate, 1.5, "FrostMelon fireRate")
    -- Stacking-slow mechanic shape: Frost uses slowStackPct +
    -- slowStackCap (NOT flat slowPct since the 2026-04-27 rework).
    Tests.assertNotNil(t.slowStackPct,  "FrostMelon slowStackPct")
    Tests.assertNotNil(t.slowStackCap,  "FrostMelon slowStackCap")
    Tests.assertEq(t.slowStackCap, 0.15, "FrostMelon slowStackCap")
end)

Tests.test("SporePuffball DPS role + post-heat-mechanic stats", function()
    -- Build bn moved Spore Control → DPS + buffed damage 3 → 8.
    -- 2026-04-27 (post-bv): cloud overlap-heat mechanic landed in
    -- Zones.lua; base cloudTickDmg trimmed 6 → 5 so single-cloud
    -- DPS stays at ~baseline. cloudRadius 8 → 7 to encourage
    -- tight cloud clusters (the heat mechanic rewards overlap).
    local t = TempTowers.Templates.SporePuffball
    Tests.assertEq(t.damage, 8, "SporePuffball damage")
    Tests.assertEq(t.cloudTickDmg, 5, "SporePuffball cloudTickDmg (post-heat trim)")
    Tests.assertEq(t.cloudRadius, 7, "SporePuffball cloudRadius (post-heat trim)")
    Tests.assertEq(TempTowers.RoleByTowerId.SporePuffball, "DPS",
        "SporePuffball role moved to DPS")
end)

Tests.test("HoneyHive bq tune-up combo + by patch tick bump", function()
    -- Build bq combo: patchSlowPct 0.55→0.60, fireRate 1.0→1.1,
    -- patchRadius 10→11.
    -- Build by (2026-04-28): patchTickDmg 4 → 6 to push Honey+CC
    -- pairings to 12+ waves (was 10.67 in bv).
    local t = TempTowers.Templates.HoneyHive
    Tests.assertEq(t.fireRate, 1.1, "HoneyHive fireRate")
    Tests.assertEq(t.patchSlowPct, 0.60, "HoneyHive patchSlowPct")
    Tests.assertEq(t.patchRadius, 11, "HoneyHive patchRadius")
    Tests.assertEq(t.damage, 10, "HoneyHive damage")
    Tests.assertEq(t.patchTickDmg, 6, "HoneyHive patchTickDmg (post-by bump)")
end)

return nil
