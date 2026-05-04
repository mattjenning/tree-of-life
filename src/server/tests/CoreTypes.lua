--[[
    CoreTypes.lua tests — canonical Core constants module structure +
    isCore() / roleFor() helper contracts. Locks the Power /
    ControlCore / SupportCore identity so future Core archetype adds
    can't quietly drop one (which is exactly the bug class CoreTypes
    was added to prevent — see ea3-1 commit).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests     = require(script.Parent)
local CoreTypes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CoreTypes"))

------------------------------------------------------------
-- Ids array — order + completeness
------------------------------------------------------------

Tests.test("CoreTypes.Ids has exactly 3 entries (Power / ControlCore / SupportCore)", function()
    Tests.assertEq(#CoreTypes.Ids, 3, "Ids length")
    Tests.assertEq(CoreTypes.Ids[1], "Power",       "first slot is Power (legacy default)")
    Tests.assertEq(CoreTypes.Ids[2], "ControlCore", "second slot is ControlCore")
    Tests.assertEq(CoreTypes.Ids[3], "SupportCore", "third slot is SupportCore")
end)

------------------------------------------------------------
-- Set hash — every Id in Ids has a true entry in Set
------------------------------------------------------------

Tests.test("CoreTypes.Set marks every Id as true", function()
    for _, id in ipairs(CoreTypes.Ids) do
        Tests.assertEq(CoreTypes.Set[id], true,
            "Set[" .. id .. "] should be true")
    end
end)

Tests.test("CoreTypes.Set has no extra entries beyond Ids", function()
    local count = 0
    for _ in pairs(CoreTypes.Set) do count = count + 1 end
    Tests.assertEq(count, #CoreTypes.Ids,
        "Set entry count should match Ids length")
end)

Tests.test("CoreTypes.Set returns nil for non-Cores", function()
    Tests.assertNil(CoreTypes.Set.AcornSniper, "aux tower not a Core")
    Tests.assertNil(CoreTypes.Set.FrostMelon,  "aux tower not a Core")
    Tests.assertNil(CoreTypes.Set.NotARealId)
end)

------------------------------------------------------------
-- isCore() — nil-safe membership check
------------------------------------------------------------

Tests.test("CoreTypes.isCore('Power') is true", function()
    Tests.assertEq(CoreTypes.isCore("Power"), true)
end)

Tests.test("CoreTypes.isCore('ControlCore') is true", function()
    Tests.assertEq(CoreTypes.isCore("ControlCore"), true)
end)

Tests.test("CoreTypes.isCore('SupportCore') is true", function()
    Tests.assertEq(CoreTypes.isCore("SupportCore"), true)
end)

Tests.test("CoreTypes.isCore('AcornSniper') is false (aux tower)", function()
    Tests.assertEq(CoreTypes.isCore("AcornSniper"), false)
end)

Tests.test("CoreTypes.isCore(nil) is false", function()
    Tests.assertEq(CoreTypes.isCore(nil), false)
end)

Tests.test("CoreTypes.isCore('') is false", function()
    Tests.assertEq(CoreTypes.isCore(""), false)
end)

Tests.test("CoreTypes.isCore(42) is false (non-string)", function()
    Tests.assertEq(CoreTypes.isCore(42), false)
end)

------------------------------------------------------------
-- Role table + roleFor() — DPS / Control / Support mapping
------------------------------------------------------------

Tests.test("CoreTypes.Role.Power = 'DPS'", function()
    Tests.assertEq(CoreTypes.Role.Power, "DPS")
end)

Tests.test("CoreTypes.Role.ControlCore = 'Control'", function()
    Tests.assertEq(CoreTypes.Role.ControlCore, "Control")
end)

Tests.test("CoreTypes.Role.SupportCore = 'Support'", function()
    Tests.assertEq(CoreTypes.Role.SupportCore, "Support")
end)

Tests.test("CoreTypes.roleFor('Power') = 'DPS'", function()
    Tests.assertEq(CoreTypes.roleFor("Power"), "DPS")
end)

Tests.test("CoreTypes.roleFor('ControlCore') = 'Control'", function()
    Tests.assertEq(CoreTypes.roleFor("ControlCore"), "Control")
end)

Tests.test("CoreTypes.roleFor('SupportCore') = 'Support'", function()
    Tests.assertEq(CoreTypes.roleFor("SupportCore"), "Support")
end)

Tests.test("CoreTypes.roleFor unknown id returns nil", function()
    Tests.assertNil(CoreTypes.roleFor("AcornSniper"),
        "non-Core id should return nil so callers can distinguish")
    Tests.assertNil(CoreTypes.roleFor(nil))
end)

------------------------------------------------------------
-- Frozen — accidental mutation must fail loud
------------------------------------------------------------

Tests.test("CoreTypes table itself is frozen", function()
    Tests.assertThrows(function()
        CoreTypes.SomeNewField = "uhoh"
    end)
end)

Tests.test("CoreTypes.Ids is frozen", function()
    Tests.assertThrows(function()
        CoreTypes.Ids[4] = "FourthCore"
    end)
end)

Tests.test("CoreTypes.Set is frozen", function()
    Tests.assertThrows(function()
        CoreTypes.Set.NewCore = true
    end)
end)

Tests.test("CoreTypes.Role is frozen", function()
    Tests.assertThrows(function()
        CoreTypes.Role.Power = "NotDPS"
    end)
end)

------------------------------------------------------------
-- Cross-module contract — TempTowers.RoleByTowerId mirrors
-- CoreTypes.Role for all 3 Cores. The duplication is
-- intentional (TempTowers' tier-list code already iterates
-- this single table; making it require CoreTypes adds noise
-- for no gain) but the rows MUST agree, or the simulator's
-- roleFor() lookup would silently disagree with CoreTypes.
------------------------------------------------------------

Tests.test("TempTowers.RoleByTowerId mirrors CoreTypes.Role for every Core", function()
    local TempTowers = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TempTowers"))
    for _, id in ipairs(CoreTypes.Ids) do
        Tests.assertEq(TempTowers.RoleByTowerId[id], CoreTypes.Role[id],
            "RoleByTowerId[" .. id .. "] should match CoreTypes.Role")
    end
end)

return nil
