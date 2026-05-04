--[[
    AutoPlaceStrategy.lua tests — placement scoring on a synthetic grid.

    The full live AutoPlaceStrategy reads Map 4's path geometry from
    InfinitePathGeometry, iterates over Config.Map4.PhaseBounds, and
    consults TowerPlacement's canPlaceAt closure. For unit tests we
    mock all of that with a small hand-built grid + a synthetic ctx.

    What we test:
      • findOptimalCell returns SOME valid placement for each role
        (Core / DPS / Control / Support) on a non-trivial grid
      • Core role picks the cell with max path coverage
      • avoidCell penalty excludes cells near the avoidance target

    What we DON'T test (deferred):
      • Per-role scoring tiebreaks (corner-proximity, aura-overlap)
        when multiple cells tie at max — those depend on internal
        ordering and can drift safely. Tier 2 follow-up.
      • computeInfinitePattern (boot-time precompute) — depends on
        live ctx + Config.Map4.PhaseBounds. Integration territory.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Tests = require(script.Parent)
local AutoPlace = require(ServerScriptService
    :WaitForChild("systems"):WaitForChild("AutoPlaceStrategy"))

------------------------------------------------------------
-- Synthetic grid setup. We build a 20-col × 10-row grid where:
--   • Cols 0-3:   "open" (placement candidates)
--   • Cols 4-15:  "path" (mob walking corridor, rows 4-5 only)
--   •             other rows in cols 4-15 are "open"
--   • Cols 16-19: "open"
--
-- Path is a 12-col × 2-row horizontal corridor. Tower placed at
-- the corridor's midpoint with a wide enough range catches the
-- entire path. Towers placed near the ends catch fewer cells.
------------------------------------------------------------

local function buildSyntheticGrid()
    local grid = {}
    for c = 0, 19 do
        grid[c] = {}
        for r = 0, 9 do
            grid[c][r] = "open"
        end
    end
    -- Path corridor: cols 4-15, rows 4-5
    for c = 4, 15 do
        grid[c][4] = "path"
        grid[c][5] = "path"
    end
    return grid
end

local function setupAutoPlaceWithGrid(grid)
    -- Set Map4ActivePhase to an undefined value so getMap4PhaseBounds
    -- falls back to the full-grid range (0..MAP4_TOTAL_COLS-OFFSET-1).
    Workspace:SetAttribute("Map4ActivePhase", 99)
    AutoPlace.setup({
        gridState        = grid,
        MAP4_COL_OFFSET  = 0,
        MAP4_TOTAL_COLS  = 20,
        MAP4_ROWS        = 10,
        CELL_SIZE        = 1,
        -- placeTowerForPlayer not used by findOptimalCell — left out.
    })
end

------------------------------------------------------------
-- findOptimalCell — basic API contract
------------------------------------------------------------

Tests.test("AutoPlace.findOptimalCell: Core role finds a placement on a path-bearing grid", function()
    setupAutoPlaceWithGrid(buildSyntheticGrid())
    local col, row = AutoPlace.findOptimalCell({
        role        = "Core",
        footprintW  = 4,
        footprintD  = 4,
        range       = 6,    -- 6-stud range on a CELL_SIZE=1 grid → 6-cell radius
        mapId       = 4,
        placedAllies = {},
    })
    Tests.assertType(col, "number", "Core placement should return a column")
    Tests.assertType(row, "number", "Core placement should return a row")
    -- Core should be placed somewhere whose footprint touches path
    -- coverage. With a 4×4 footprint + 6-cell range, the densest
    -- coverage area is around the middle of the cols 4-15 corridor.
    Tests.assertTrue(col >= 0 and col <= 16,
        ("Core col %d should be within iteration bounds [0, 16]"):format(col))
    Tests.assertTrue(row >= 0 and row <= 6,
        ("Core row %d should be within iteration bounds [0, 6]"):format(row))
end)

Tests.test("AutoPlace.findOptimalCell: Core picks high-path-coverage area, not far corner", function()
    setupAutoPlaceWithGrid(buildSyntheticGrid())
    local col, _row = AutoPlace.findOptimalCell({
        role        = "Core",
        footprintW  = 4,
        footprintD  = 4,
        range       = 6,
        mapId       = 4,
        placedAllies = {},
    })
    -- The path corridor is at cols 4-15. Core should be placed
    -- close to the corridor, not in the far corner (cols 0-3 or
    -- 16-19 with footprint 4×4 placing range outside the path).
    -- With centrality nudge, Core gravitates to the middle of the
    -- active bounds (col ~8, row ~3).
    Tests.assertTrue(col >= 2 and col <= 14,
        ("Core col %d should be near the path corridor (cols 4-15), got %d"):format(col, col))
end)

Tests.test("AutoPlace.findOptimalCell: DPS role finds a placement", function()
    setupAutoPlaceWithGrid(buildSyntheticGrid())
    local col, row = AutoPlace.findOptimalCell({
        role        = "DPS",
        footprintW  = 4,
        footprintD  = 4,
        range       = 6,
        mapId       = 4,
        placedAllies = {
            { role = "Core", anchorCol = 8, anchorRow = 0,
              centerC = 9.5, centerR = 1.5,
              footprintW = 4, footprintD = 4 },
        },
    })
    Tests.assertType(col, "number", "DPS placement should succeed alongside an existing Core")
    Tests.assertType(row, "number")
end)

Tests.test("AutoPlace.findOptimalCell: DPS prefers Core-overlap cells over far path-coverage peaks (ea3-149)", function()
    -- Grid: path runs cols 4-15, rows 4-5. Core at col 4 (near LEFT
    -- end of path). Two equally-good path-coverage cells exist for
    -- a small-range DPS:
    --   • near the Core (col ~5-7) — shares Core's coverage
    --   • far end of path  (col ~12-14) — no Core overlap
    -- Pre-fix (ea3-127 F): pathCoverage * 1000 + coreProximity tied
    -- on path coverage → far-end won on first-cell-wins iteration.
    -- ea3-149 first attempt used if/else fallback that re-introduced
    -- the bug (fallback path's pathCoverage*1000 = primary's
    -- sharedCoverage*1000, far corner won when its pathCoverage
    -- exceeded near-Core's sharedCoverage).
    -- ea3-150 unifies: sharedCoverage * 1000 + pathCoverage. Any
    -- cell with sharedCoverage ≥ 1 scores ≥ 1000, beats every
    -- sharedCoverage=0 cell (max ~80 from pathCoverage alone).
    setupAutoPlaceWithGrid(buildSyntheticGrid())
    local coreCol, coreRow = 4, 2
    local fw, fd = 4, 4
    local placedAllies = {
        {
            role        = "Core",
            anchorCol   = coreCol, anchorRow = coreRow,
            centerC     = coreCol + (fw - 1) / 2,
            centerR     = coreRow + (fd - 1) / 2,
            footprintW  = fw, footprintD = fd,
        },
    }
    local dpsCol = AutoPlace.findOptimalCell({
        role         = "DPS",
        footprintW   = 4, footprintD = 4,
        range        = 5,   -- small enough that "near Core" and "far path" are mutually exclusive
        mapId        = 4,
        placedAllies = placedAllies,
    })
    Tests.assertType(dpsCol, "number", "DPS should find a placement")
    -- Core occupies cols 4-7. DPS shouldn't overlap (canPlaceAt rejects).
    -- Near-Core valid cells: col 8-10 (Core overlap region with range 5).
    -- Far-from-Core: col 12+ (no Core overlap).
    -- Post-fix expectation: DPS picks col 8-11 (Core overlap region).
    Tests.assertTrue(dpsCol < 12,
        ("DPS should cluster near Core (col 4-7), got col %d (far end of path)"):format(dpsCol))
end)

Tests.test("AutoPlace.findOptimalCell: returns nil/nil on a grid with no placements possible", function()
    -- All-path grid: no "open" cells means _canPlaceAt returns false
    -- for every footprint. findOptimalCell should bail with nil/nil
    -- (caller handles the no-fit case via warn + skip-combo).
    local fullPath = {}
    for c = 0, 19 do
        fullPath[c] = {}
        for r = 0, 9 do
            fullPath[c][r] = "path"
        end
    end
    setupAutoPlaceWithGrid(fullPath)
    local col, row = AutoPlace.findOptimalCell({
        role        = "Core",
        footprintW  = 4,
        footprintD  = 4,
        range       = 6,
        mapId       = 4,
        placedAllies = {},
    })
    Tests.assertNil(col, "no-fit grid should return nil col")
    Tests.assertNil(row, "no-fit grid should return nil row")
end)

Tests.test("AutoPlace.findOptimalCell: avoidCell penalty steers placement away", function()
    setupAutoPlaceWithGrid(buildSyntheticGrid())
    -- Without avoidCell — Core lands somewhere central.
    local baselineCol = AutoPlace.findOptimalCell({
        role        = "Core",
        footprintW  = 4,
        footprintD  = 4,
        range       = 6,
        mapId       = 4,
        placedAllies = {},
    })
    -- With avoidCell at the baseline placement's spot — Core should
    -- move elsewhere (the avoid penalty is -1e9 per the model, so
    -- ANY out-of-avoid-radius cell wins).
    local avoidedCol = AutoPlace.findOptimalCell({
        role        = "Core",
        footprintW  = 4,
        footprintD  = 4,
        range       = 6,
        mapId       = 4,
        placedAllies = {},
        avoidCell   = { col = baselineCol or 8, row = 3 },
    })
    -- Avoided placement should differ — even small grids have enough
    -- spread for the avoid penalty to push placement away.
    Tests.assertTrue(avoidedCol ~= baselineCol or avoidedCol == nil,
        "avoidCell should steer Core away from the baseline spot")
end)

return nil
