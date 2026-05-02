--[[
    InfiniteSlotPattern.lua tests — structural invariants for the
    36-slot Map 4 auto-place pattern at src/shared/InfiniteSlotPattern.lua.

    Locks down:
      • Slot count + role mix (16 DPS / 12 Control / 8 Support)
      • Slot 1 = canonical Power Core anchor (col 6 row 12 DPS)
      • All entries have valid role enum
      • Frozen — accidental mutation throws

    Why these exact tests: the pattern is consumed by both the live
    spawner (server) and the auto-place click handler (client). If a
    future edit shifts slot 1 or changes the slot count, both sides
    silently use the new shape — but downstream code (StatLedger
    role tagging, AutoPlaceStrategy fallback, validator's expected-
    placement) bakes in the 16/12/8 mix. Drift here = subtle balance
    skew, not a crash.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests   = require(script.Parent)
local Pattern = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("InfiniteSlotPattern"))

Tests.test("InfiniteSlotPattern has exactly 36 slots", function()
    Tests.assertEq(#Pattern, 36, "slot count")
end)

Tests.test("InfiniteSlotPattern slot 1 is canonical Power Core anchor", function()
    local s = Pattern[1]
    Tests.assertEq(s.co, 6, "slot 1 col")
    Tests.assertEq(s.ro, 12, "slot 1 row")
    Tests.assertEq(s.role, "DPS", "slot 1 role")
end)

Tests.test("InfiniteSlotPattern role mix is 16 DPS / 12 Control / 8 Support", function()
    local counts = { DPS = 0, Control = 0, Support = 0 }
    for _, slot in ipairs(Pattern) do
        Tests.assertNotNil(counts[slot.role],
            "unknown role: " .. tostring(slot.role))
        counts[slot.role] = counts[slot.role] + 1
    end
    Tests.assertEq(counts.DPS,     16, "DPS slot count")
    Tests.assertEq(counts.Control, 12, "Control slot count")
    Tests.assertEq(counts.Support,  8, "Support slot count")
end)

Tests.test("InfiniteSlotPattern entries all have co / ro / role fields", function()
    for i, slot in ipairs(Pattern) do
        Tests.assertEq(type(slot.co),   "number", "slot " .. i .. " .co")
        Tests.assertEq(type(slot.ro),   "number", "slot " .. i .. " .ro")
        Tests.assertEq(type(slot.role), "string", "slot " .. i .. " .role")
    end
end)

Tests.test("InfiniteSlotPattern is deeply frozen", function()
    Tests.assertThrows(function() Pattern[1].co = 999 end,
        "slot entries should be frozen")
    Tests.assertThrows(function() Pattern[37] = { co = 0, ro = 0, role = "DPS" } end,
        "outer table should be frozen")
end)

return nil
