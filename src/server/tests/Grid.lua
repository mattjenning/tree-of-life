--[[
    Grid.lua tests — verify cellToWorld dispatches to the right map by
    col range, plus the boundary cases (col = MAP2_COL_OFFSET - 1 stays
    in map 1; col = MAP3_COL_OFFSET - 1 stays in map 2). The shared-grid
    per-col dispatch was historically the source of multi-month bugs
    (memory: feedback_shared_grid_dispatch.md), so these tests pin the
    invariant down at server boot.
]]

local Tests = require(script.Parent)
local Grid = require(script.Parent.Parent:WaitForChild("systems"):WaitForChild("Grid"))

------------------------------------------------------------
-- Mock ctx fixture matching the live server's grid dimensions
-- (taken from src/shared/Config.lua Grid section).
------------------------------------------------------------

local function makeCtx()
    local ctx = {
        CELL_SIZE             = 8,
        GRID_COLS             = 60,
        GRID_ROWS             = 44,
        PATH_WIDTH_CELLS      = 4,
        HEART_EXCLUSION_CELLS = 3,
        MAP2_CENTER           = Vector3.new(1000, 500, 0),
        MAP2_WIDTH            = 600,
        MAP2_DEPTH            = 440,
        MAP2_ROWS             = 55,
        MAP2_COL_OFFSET       = 60,
        MAP2_TOTAL_COLS       = 135,
        MAP3_CENTER           = Vector3.new(2000, 1000, 0),
        MAP3_WIDTH            = 720,
        MAP3_DEPTH            = 528,
        MAP3_ROWS             = 66,
        MAP3_COL_OFFSET       = 135,
        MAP4_CENTER           = Vector3.new(8000, 100, 0),
        MAP4_WIDTH            = 720,
        MAP4_DEPTH            = 528,
        MAP4_ROWS             = 66,
        MAP4_COL_OFFSET       = 225,
        MAP4_TOTAL_COLS       = 315,
        -- TdRoom-published fields. Map 1 origin = rc.X-halfW, rc.Z-halfD.
        rc    = Vector3.new(0, 0, 0),
        halfW = 240,   -- 60 cols × 8 stud / 2
        halfD = 176,   -- 44 rows × 8 stud / 2
    }
    Grid.setup(ctx)
    return ctx
end

------------------------------------------------------------
-- Tests
------------------------------------------------------------

Tests.test("Grid.cellToWorld — col 0 lands on map 1", function()
    local ctx = makeCtx()
    local p = ctx.cellToWorld(0, 0)
    -- Map 1 origin = rc.X - halfW = -240; first cell center = -240 + 4 = -236.
    Tests.assertNear(p.X, -236, 0.01, "map 1 col 0 X")
    Tests.assertNear(p.Z, -172, 0.01, "map 1 row 0 Z (rc.Z - halfD + 0.5*CELL = -172)")
end)

Tests.test("Grid.cellToWorld — col MAP2_COL_OFFSET lands on map 2", function()
    local ctx = makeCtx()
    local p = ctx.cellToWorld(60, 0)  -- MAP2_COL_OFFSET = 60
    -- Map 2 first cell center X = 1000 - 300 + 4 = 704.
    Tests.assertNear(p.X, 704, 0.01, "map 2 col 0 X")
    Tests.assertEq(p.Y, 500, "map 2 inherits MAP2_CENTER.Y")
end)

Tests.test("Grid.cellToWorld — col MAP3_COL_OFFSET lands on map 3", function()
    local ctx = makeCtx()
    local p = ctx.cellToWorld(135, 0)  -- MAP3_COL_OFFSET = 135
    -- Map 3 first cell center X = 2000 - 360 + 4 = 1644.
    Tests.assertNear(p.X, 1644, 0.01, "map 3 col 0 X")
    Tests.assertEq(p.Y, 1000, "map 3 inherits MAP3_CENTER.Y")
end)

Tests.test("Grid.cellToWorld — col MAP2_COL_OFFSET-1 still on map 1", function()
    local ctx = makeCtx()
    local p = ctx.cellToWorld(59, 0)
    -- Last col on map 1: -240 + (59 + 0.5) * 8 = 236.
    Tests.assertNear(p.X, 236, 0.01, "map 1 col 59 X")
    Tests.assertEq(p.Y, 0, "still on map 1's Y plane")
end)

Tests.test("Grid.cellToWorld — col MAP3_COL_OFFSET-1 still on map 2", function()
    local ctx = makeCtx()
    local p = ctx.cellToWorld(134, 0)  -- last map 2 col
    -- Local col = 134 - 60 = 74; X = 1000 - 300 + (74 + 0.5) * 8 = 1296.
    Tests.assertNear(p.X, 1296, 0.01, "map 2 last col X")
    Tests.assertEq(p.Y, 500, "still on map 2's Y plane")
end)

Tests.test("Grid.cellToWorld — col + 1 advances X by CELL_SIZE", function()
    local ctx = makeCtx()
    local p1 = ctx.cellToWorld(0, 0)
    local p2 = ctx.cellToWorld(1, 0)
    Tests.assertNear(p2.X - p1.X, 8, 0.01, "col delta of 1 = +8 stud X")
end)

Tests.test("Grid.cellToWorld — row + 1 advances Z by CELL_SIZE", function()
    local ctx = makeCtx()
    local p1 = ctx.cellToWorld(0, 0)
    local p2 = ctx.cellToWorld(0, 1)
    Tests.assertNear(p2.Z - p1.Z, 8, 0.01, "row delta of 1 = +8 stud Z")
end)

Tests.test("Grid.gridState covers all 4 maps' col range", function()
    local ctx = makeCtx()
    Tests.assertNotNil(ctx.gridState[0], "map 1 col 0 should exist")
    Tests.assertNotNil(ctx.gridState[60], "map 2 col 0 should exist")
    Tests.assertNotNil(ctx.gridState[135], "map 3 col 0 should exist")
    Tests.assertNotNil(ctx.gridState[225], "map 4 col 0 should exist")
    Tests.assertNotNil(ctx.gridState[314], "map 4 last col should exist")
end)

Tests.test("Grid.cellToWorld — col MAP4_COL_OFFSET lands on map 4", function()
    local ctx = makeCtx()
    local p = ctx.cellToWorld(225, 0)
    -- Map 4 first cell center X = 8000 - 360 + 4 = 7644.
    Tests.assertNear(p.X, 7644, 0.01, "map 4 col 0 X")
    Tests.assertEq(p.Y, 100, "map 4 inherits MAP4_CENTER.Y")
end)

Tests.test("Grid.cellToWorld — col MAP4_COL_OFFSET-1 still on map 3", function()
    local ctx = makeCtx()
    local p = ctx.cellToWorld(224, 0)
    Tests.assertEq(p.Y, 1000, "still on map 3's Y plane")
end)

return nil
