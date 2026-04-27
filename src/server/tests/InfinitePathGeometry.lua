--[[
    InfinitePathGeometry.lua tests — pure-math coverage for the
    Phase-2 simulator's segment/circle intersection + auto-place
    slot assignment. Per project_simulator_improvement.md: this
    is the biggest single accuracy lever for the closed-form sim,
    so its math gets pinned by tests.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Tests = require(script.Parent)
local PG = require(ServerScriptService:WaitForChild("systems"):WaitForChild("InfinitePathGeometry"))

------------------------------------------------------------
-- segmentCircleIntersection — unit cases
------------------------------------------------------------

Tests.test("segmentCircleIntersection: segment fully outside circle returns 0", function()
    local len = PG.segmentCircleIntersection({0, 0}, {10, 0}, {0, 100}, 1)
    Tests.assertNear(len, 0, 0.001, "segment 100 cells away from center")
end)

Tests.test("segmentCircleIntersection: segment fully inside circle returns full length", function()
    -- Segment from (0,0) to (3,0), circle at (1.5, 0) with r=10.
    -- Whole segment is < r from center → return |segment| = 3.
    local len = PG.segmentCircleIntersection({0, 0}, {3, 0}, {1.5, 0}, 10)
    Tests.assertNear(len, 3.0, 0.001, "segment fully inside circle")
end)

Tests.test("segmentCircleIntersection: chord through circle perpendicular to radius", function()
    -- Segment along x-axis from (-10, 0) to (10, 0), circle at
    -- (0, 0) r = 5 → chord length is 10 (the diameter on x-axis,
    -- clamped to the [0,1] segment range maps to t=[0.25,0.75] →
    -- 0.5 * 20 = 10).
    local len = PG.segmentCircleIntersection({-10, 0}, {10, 0}, {0, 0}, 5)
    Tests.assertNear(len, 10.0, 0.001, "diameter chord = 2r")
end)

Tests.test("segmentCircleIntersection: tangent grazes (zero-length intersection)", function()
    -- Segment along y=5, circle at (0,0) r=5 — tangent line touches
    -- the circle at exactly one point → length = 0.
    local len = PG.segmentCircleIntersection({-10, 5}, {10, 5}, {0, 0}, 5)
    Tests.assertNear(len, 0, 0.001, "tangent → zero-length intersection")
end)

Tests.test("segmentCircleIntersection: segment partially overlaps", function()
    -- Segment (0,0)→(10,0), circle at (5,0) r=3 → intersection
    -- spans from x=2 to x=8, length = 6.
    local len = PG.segmentCircleIntersection({0, 0}, {10, 0}, {5, 0}, 3)
    Tests.assertNear(len, 6.0, 0.001, "chord covers 6 units of segment")
end)

Tests.test("segmentCircleIntersection: zero-length segment", function()
    -- p1 == p2 inside circle → segment has length 0; intersection
    -- length is also 0.
    local len = PG.segmentCircleIntersection({1, 1}, {1, 1}, {0, 0}, 5)
    Tests.assertEq(len, 0, "zero-length segment → zero intersection")
end)

------------------------------------------------------------
-- pathLengthCells / pathExposureCells
------------------------------------------------------------

Tests.test("pathLengthCells: total Map 4 path length", function()
    -- Sum of segment Manhattan-style lengths for the 6-waypoint
    -- path: (5→38, 58)=33 + (38, 58→32)=26 + (38→2, 32)=36 +
    -- (2, 32→8)=24 + (2→80, 8)=78 → 197 cells.
    local len = PG.pathLengthCells()
    Tests.assertNear(len, 197, 0.5, "default Map4 path = 197 cells")
end)

Tests.test("pathExposureCells: tower far from path covers nothing", function()
    -- Tower at (200, 200) with range 5 — way off the Map 4 path.
    local exposure = PG.pathExposureCells(200, 200, 5)
    Tests.assertNear(exposure, 0, 0.001, "tower 200+ cells off-path → no exposure")
end)

Tests.test("pathExposureCells: tower with massive range covers entire path", function()
    -- Range 1000 cells will engulf the whole path — exposure
    -- should equal the path length.
    local exposure = PG.pathExposureCells(40, 30, 1000)
    local pathLen = PG.pathLengthCells()
    Tests.assertNear(exposure, pathLen, 0.5,
        "huge range covers full path length")
end)

Tests.test("pathExposureCells: tower next to first segment covers a portion", function()
    -- Tower at (20, 58) with range 10 — sits ON the first segment
    -- (5,58)→(38,58). Should see ~20 cells of exposure (tower's
    -- 10-cell radius cuts a 20-cell chord through the horizontal
    -- segment), but the segment ends at col 38 so the upper bound
    -- caps lower than 20. Should be 20 cells given the segment
    -- spans cols 5-38 (33 long) and the tower at col 20 with r=10
    -- catches cols 10-30 → 20-cell chord, ALL within segment.
    local exposure = PG.pathExposureCells(20, 58, 10)
    Tests.assertNear(exposure, 20.0, 0.5,
        "tower at (20,58) r=10 catches 20 cells of segment 1")
end)

------------------------------------------------------------
-- assignSlots — Power forced to slot 1; aux to first matching role
------------------------------------------------------------

Tests.test("assignSlots: Power always lands in slot 1 (DPS anchor)", function()
    local slots = PG.assignSlots({"DPS"})  -- just Power
    Tests.assertEq(#slots, 1, "1 tower → 1 slot")
    Tests.assertEq(slots[1].co, PG.INFINITE_PATTERN[1].co)
    Tests.assertEq(slots[1].ro, PG.INFINITE_PATTERN[1].ro)
end)

Tests.test("assignSlots: solo loadout uses slots 1+2", function()
    local slots = PG.assignSlots({"DPS", "DPS"})  -- Power + 1 aux
    Tests.assertEq(#slots, 2)
    -- Slot 1 = Power anchor, slot 2 = next DPS slot in pattern.
    Tests.assertEq(slots[1].co, 6, "slot 1 = Power anchor (col 6)")
    Tests.assertEq(slots[1].ro, 12)
    Tests.assertEq(slots[2].co, 6, "slot 2 = next DPS (col 6 row 17)")
    Tests.assertEq(slots[2].ro, 17)
end)

Tests.test("assignSlots: Control tower lands in first Control slot", function()
    -- Power (slot 1) + Control aux. The Control aux should pick
    -- the first Control-tagged pattern slot, NOT slot 2 (which
    -- is DPS).
    local slots = PG.assignSlots({"DPS", "Control"})
    Tests.assertEq(#slots, 2)
    Tests.assertEq(slots[2].role, "Control",
        "Control aux should land in a Control-tagged slot")
end)

Tests.test("assignSlots: trio assigns 4 slots", function()
    local slots = PG.assignSlots({"DPS", "DPS", "Control", "DPS"})
    Tests.assertEq(#slots, 4)
end)

Tests.test("assignSlots: empty loadout returns empty", function()
    Tests.assertEq(#PG.assignSlots({}), 0)
    Tests.assertEq(#PG.assignSlots(nil), 0)
end)

------------------------------------------------------------
-- exposureSecondsForTower — wraps cells → studs / mobSpeed
------------------------------------------------------------

Tests.test("exposureSecondsForTower: nil slot returns 0", function()
    Tests.assertEq(PG.exposureSecondsForTower(nil, 70, 8.8), 0)
end)

Tests.test("exposureSecondsForTower: zero mob speed returns 0", function()
    local slot = { co = 20, ro = 58, role = "DPS" }
    Tests.assertEq(PG.exposureSecondsForTower(slot, 70, 0), 0)
end)

Tests.test("exposureSecondsForTower: positive exposure for tower near path", function()
    local slot = { co = 20, ro = 58, role = "DPS" }
    -- Tower with range 70 studs (35 cells) at (20, 58) catches the
    -- whole bottom segment (cells 5-38 along row 58 = 33 cells).
    -- exposure_studs = 33 cells × 2 studs/cell = 66 studs (cells
    -- 5-38 spanned by the radius). At basic mob speed 8.8 stud/s,
    -- exposure = ~7.5 sec. Loose bound check.
    local secs = PG.exposureSecondsForTower(slot, 70, 8.8)
    Tests.assertTrue(secs > 5, "tower near path should have >5 sec exposure")
    Tests.assertTrue(secs < 30, "exposure should be reasonable (<30 sec)")
end)

return nil
