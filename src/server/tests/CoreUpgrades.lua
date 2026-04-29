--[[
    CoreUpgrades.lua tests — pin the per-Core upgrade options data
    + helpers. Phase B (ea3-25) ships the data module + UI shell;
    these tests guard the structure so adding/renaming options
    later doesn't accidentally break the picker UI shape.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests        = require(script.Parent)
local CoreUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CoreUpgrades"))
local CoreTypes    = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CoreTypes"))

------------------------------------------------------------
-- Structure: 3 Cores × 3 options = 9 total
------------------------------------------------------------

Tests.test("CoreUpgrades.Options has 3 entries per Core", function()
    for _, coreId in ipairs(CoreTypes.Ids) do
        local opts = CoreUpgrades.Options[coreId]
        Tests.assertNotNil(opts, "options missing for Core " .. coreId)
        Tests.assertEq(#opts, 3, coreId .. " should have 3 options, got " .. #opts)
    end
end)

Tests.test("CoreUpgrades total = 9 unique upgrade ids", function()
    local seen = {}
    for _, coreId in ipairs(CoreTypes.Ids) do
        for _, opt in ipairs(CoreUpgrades.Options[coreId]) do
            Tests.assertFalse(seen[opt.id],
                "duplicate upgrade id across Cores: " .. tostring(opt.id))
            seen[opt.id] = true
        end
    end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    Tests.assertEq(count, 9, "expected 9 unique upgrade ids, got " .. count)
end)

Tests.test("Every upgrade has id / title / description", function()
    for _, coreId in ipairs(CoreTypes.Ids) do
        for _, opt in ipairs(CoreUpgrades.Options[coreId]) do
            Tests.assertType(opt.id, "string", coreId .. " upgrade missing string id")
            Tests.assertType(opt.title, "string", coreId .. ":" .. opt.id .. " missing title")
            Tests.assertType(opt.description, "string", coreId .. ":" .. opt.id .. " missing description")
            Tests.assertTrue(#opt.id > 0, "empty id")
            Tests.assertTrue(#opt.title > 0, "empty title")
            Tests.assertTrue(#opt.description > 0, "empty description")
        end
    end
end)

------------------------------------------------------------
-- optionsFor() / byId() / belongsToCore() helpers
------------------------------------------------------------

Tests.test("optionsFor returns the right Core's options", function()
    local power = CoreUpgrades.optionsFor("Power")
    Tests.assertNotNil(power)
    Tests.assertEq(#power, 3)
    -- Power-specific: includes the +1 base damage entry (id pinned).
    local hasBaseDamage = false
    for _, opt in ipairs(power) do
        if opt.id == "PowerBaseDamage" then hasBaseDamage = true; break end
    end
    Tests.assertTrue(hasBaseDamage, "Power options should include PowerBaseDamage")
end)

Tests.test("optionsFor returns nil for unknown Core", function()
    Tests.assertNil(CoreUpgrades.optionsFor("NotACore"))
    Tests.assertNil(CoreUpgrades.optionsFor(nil))
    Tests.assertNil(CoreUpgrades.optionsFor(42))
end)

Tests.test("byId locates upgrades regardless of which Core they belong to", function()
    local opt = CoreUpgrades.byId("ControlAddSlow")
    Tests.assertNotNil(opt)
    Tests.assertEq(opt.id, "ControlAddSlow")
    Tests.assertNotNil(opt.title)
end)

Tests.test("byId returns nil for unknown / nil id", function()
    Tests.assertNil(CoreUpgrades.byId("NotARealUpgrade"))
    Tests.assertNil(CoreUpgrades.byId(nil))
end)

Tests.test("belongsToCore matches the right pairing", function()
    Tests.assertTrue(CoreUpgrades.belongsToCore("PowerBaseDamage", "Power"))
    Tests.assertFalse(CoreUpgrades.belongsToCore("PowerBaseDamage", "ControlCore"),
        "Power upgrade should NOT belong to ControlCore")
    Tests.assertTrue(CoreUpgrades.belongsToCore("ControlAddSlow", "ControlCore"))
    Tests.assertTrue(CoreUpgrades.belongsToCore("SupportHeartRegen", "SupportCore"))
end)

Tests.test("belongsToCore false on nil / unknown args", function()
    Tests.assertFalse(CoreUpgrades.belongsToCore(nil, "Power"))
    Tests.assertFalse(CoreUpgrades.belongsToCore("PowerBaseDamage", nil))
    Tests.assertFalse(CoreUpgrades.belongsToCore("NotRealUpgrade", "Power"))
end)

------------------------------------------------------------
-- Frozen — accidental mutation must fail loud
------------------------------------------------------------

Tests.test("CoreUpgrades top-level table is frozen", function()
    Tests.assertThrows(function()
        CoreUpgrades.NewField = "uhoh"
    end)
end)

Tests.test("CoreUpgrades.Options is frozen", function()
    Tests.assertThrows(function()
        CoreUpgrades.Options.NewCore = {}
    end)
end)

Tests.test("Per-Core options array is frozen", function()
    Tests.assertThrows(function()
        table.insert(CoreUpgrades.Options.Power, { id = "X" })
    end)
end)

Tests.test("Individual upgrade entries are frozen", function()
    Tests.assertThrows(function()
        CoreUpgrades.Options.Power[1].title = "MUTATED"
    end)
end)

return nil
