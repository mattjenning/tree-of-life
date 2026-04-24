--[[
    Rarity.lua tests — palette structure + lookup helpers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests  = require(script.Parent)
local Rarity = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Rarity"))

------------------------------------------------------------
-- Names + Colors structure
------------------------------------------------------------

Tests.test("Rarity.Names has 6 entries (Common..Mythical + Special)", function()
    Tests.assertEq(#Rarity.Names, 6, "Names length")
    Tests.assertEq(Rarity.Names[1], "Common")
    Tests.assertEq(Rarity.Names[2], "Rare")
    Tests.assertEq(Rarity.Names[3], "Exceptional")
    Tests.assertEq(Rarity.Names[4], "Legendary")
    Tests.assertEq(Rarity.Names[5], "Mythical")
    Tests.assertEq(Rarity.Names[6], "Special")
end)

Tests.test("Rarity.Colors length matches Names length", function()
    Tests.assertEq(#Rarity.Colors, #Rarity.Names,
        "Colors and Names should be the same length")
end)

Tests.test("Rarity.Colors entries are Color3", function()
    for i, c in ipairs(Rarity.Colors) do
        Tests.assertType(c, "userdata", "Colors[" .. i .. "] not a Color3")
    end
end)

Tests.test("Rarity.IndexByName maps every name back to its 1-based index", function()
    for i, name in ipairs(Rarity.Names) do
        Tests.assertEq(Rarity.IndexByName[name], i,
            "IndexByName[" .. name .. "]")
    end
end)

------------------------------------------------------------
-- ColorFor() helper — string name → Color3 lookup with safe fallback
------------------------------------------------------------

Tests.test("Rarity.ColorFor('Common') returns Colors[1]", function()
    Tests.assertEq(Rarity.ColorFor("Common"), Rarity.Colors[1])
end)

Tests.test("Rarity.ColorFor('Mythical') returns Colors[5]", function()
    Tests.assertEq(Rarity.ColorFor("Mythical"), Rarity.Colors[5])
end)

Tests.test("Rarity.ColorFor('Special') returns Colors[6]", function()
    Tests.assertEq(Rarity.ColorFor("Special"), Rarity.Colors[6])
end)

Tests.test("Rarity.ColorFor unknown rarity falls back to Common gray", function()
    -- Unknown names should never crash; ColorFor returns Common's color.
    -- Documented contract — callers don't have to nil-check.
    Tests.assertEq(Rarity.ColorFor("WeirdoRarity"), Rarity.Colors[1])
    Tests.assertEq(Rarity.ColorFor(""), Rarity.Colors[1])
end)

------------------------------------------------------------
-- Frozen — accidental mutation should fail loud
------------------------------------------------------------

Tests.test("Rarity table itself is frozen", function()
    Tests.assertThrows(function()
        Rarity.SomeNewField = "uhoh"
    end, "expected frozen-table write to throw")
end)

Tests.test("Rarity.Names is frozen", function()
    Tests.assertThrows(function()
        Rarity.Names[7] = "NewTier"
    end)
end)

Tests.test("Rarity.Colors is frozen", function()
    Tests.assertThrows(function()
        Rarity.Colors[1] = nil
    end)
end)
