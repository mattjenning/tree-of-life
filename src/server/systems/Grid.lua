--[[
    Grid.lua — Shared multi-map grid coordinate system.

    The grid spans BOTH maps in a single 2D table:
      Map 1 → cols [0, GRID_COLS-1]           × rows [0, GRID_ROWS-1]
      Map 2 → cols [MAP2_COL_OFFSET, TOTAL-1] × rows [0, MAP2_ROWS-1]

    A single gridState table covers both maps. cellToWorld dispatches
    to the right world-space origin by checking the col range.
    Tower placement / path / mob systems all read gridState[c][r]
    unchanged regardless of which map the cell belongs to.

    setup(ctx) reads TdRoom's published fields (rc, halfW, halfD) plus
    module-level constants, builds the shared gridState, defines
    cellToWorld, marks map 1's enemy path, and reserves a heart
    exclusion zone. Publishes:
      ctx.gridState           -- 2D table [col][row] → "open"|"path"|"heart"|"occupied"|"decor"
      ctx.cellToWorld         -- function(col, row) → Vector3
      ctx.pathWaypointCells   -- map 1 waypoint sequence (for visual tile rendering)
      ctx.heartCell           -- last waypoint, where the TreeHeart sits

    Constants read from ctx:
      CELL_SIZE, GRID_COLS, GRID_ROWS, PATH_WIDTH_CELLS, HEART_EXCLUSION_CELLS,
      MAP2_CENTER, MAP2_WIDTH, MAP2_DEPTH, MAP2_COLS, MAP2_ROWS,
      MAP2_COL_OFFSET, MAP2_TOTAL_COLS

    TdRoom fields read from ctx:
      rc, halfW, halfD
]]

local Grid = {}

function Grid.setup(ctx)
    local CELL_SIZE             = ctx.CELL_SIZE
    local GRID_COLS             = ctx.GRID_COLS
    local GRID_ROWS             = ctx.GRID_ROWS
    local PATH_WIDTH_CELLS      = ctx.PATH_WIDTH_CELLS
    local HEART_EXCLUSION_CELLS = ctx.HEART_EXCLUSION_CELLS
    local MAP2_CENTER           = ctx.MAP2_CENTER
    local MAP2_WIDTH            = ctx.MAP2_WIDTH
    local MAP2_DEPTH            = ctx.MAP2_DEPTH
    local MAP2_ROWS             = ctx.MAP2_ROWS
    local MAP2_COL_OFFSET       = ctx.MAP2_COL_OFFSET
    local MAP3_CENTER           = ctx.MAP3_CENTER
    local MAP3_WIDTH            = ctx.MAP3_WIDTH
    local MAP3_DEPTH            = ctx.MAP3_DEPTH
    local MAP3_ROWS             = ctx.MAP3_ROWS
    local MAP3_COL_OFFSET       = ctx.MAP3_COL_OFFSET
    local MAP3_TOTAL_COLS       = ctx.MAP3_TOTAL_COLS

    local rc    = ctx.rc
    local halfW = ctx.halfW
    local halfD = ctx.halfD

    local gridState = {}
    local MAX_GRID_ROWS = math.max(GRID_ROWS, MAP2_ROWS, MAP3_ROWS)
    for c = 0, MAP3_TOTAL_COLS - 1 do
        gridState[c] = {}
        for r = 0, MAX_GRID_ROWS - 1 do
            gridState[c][r] = "open"
        end
    end

    local function cellToWorld(col, row)
        -- v3 multi-map: cells dispatch to map 1, 2, or 3 by col range.
        -- Map 3 first (highest range), map 2, then map 1 (default).
        if col >= MAP3_COL_OFFSET then
            local localCol = col - MAP3_COL_OFFSET
            return Vector3.new(
                MAP3_CENTER.X - MAP3_WIDTH/2 + (localCol + 0.5) * CELL_SIZE,
                MAP3_CENTER.Y,
                MAP3_CENTER.Z - MAP3_DEPTH/2 + (row + 0.5) * CELL_SIZE
            )
        end
        if col >= MAP2_COL_OFFSET then
            local localCol = col - MAP2_COL_OFFSET
            return Vector3.new(
                MAP2_CENTER.X - MAP2_WIDTH/2 + (localCol + 0.5) * CELL_SIZE,
                MAP2_CENTER.Y,
                MAP2_CENTER.Z - MAP2_DEPTH/2 + (row + 0.5) * CELL_SIZE
            )
        end
        return Vector3.new(
            rc.X - halfW + (col + 0.5) * CELL_SIZE,
            0,
            rc.Z - halfD + (row + 0.5) * CELL_SIZE
        )
    end

    local pathWaypointCells = {
        {57,  8},
        {42,  8},
        {42, 34},
        {30, 34},
        {30,  8},
        {18,  8},
        {18, 28},
        { 4, 28},
    }

    -- KEY FIX: Mark path cells by sweeping a PATH_WIDTH_CELLS-wide brush along each
    -- segment. For segment a→b, determine the axis of travel; stretch the brush
    -- perpendicular to the direction. Also pad end-points by half-width so corners
    -- are fully covered (matches the visual path tiles).
    local pathHalf = math.floor(PATH_WIDTH_CELLS / 2)

    local function markPathRect(c1, r1, c2, r2)
        local cmin = math.min(c1, c2)
        local cmax = math.max(c1, c2)
        local rmin = math.min(r1, r2)
        local rmax = math.max(r1, r2)
        for c = cmin, cmax do
            for r = rmin, rmax do
                if c >= 0 and c < GRID_COLS and r >= 0 and r < GRID_ROWS then
                    gridState[c][r] = "path"
                end
            end
        end
    end

    for i = 1, #pathWaypointCells - 1 do
        local a = pathWaypointCells[i]
        local b = pathWaypointCells[i + 1]
        local ac, ar = a[1], a[2]
        local bc, br = b[1], b[2]
        -- Horizontal segment
        if ar == br then
            local c1 = math.min(ac, bc) - pathHalf + 1
            local c2 = math.max(ac, bc) + pathHalf
            local r1 = ar - pathHalf + 1
            local r2 = ar + pathHalf
            markPathRect(c1, r1, c2, r2)
        else
            -- Vertical segment
            local c1 = ac - pathHalf + 1
            local c2 = ac + pathHalf
            local r1 = math.min(ar, br) - pathHalf + 1
            local r2 = math.max(ar, br) + pathHalf
            markPathRect(c1, r1, c2, r2)
        end
    end

    -- Heart exclusion zone
    local heartCell = pathWaypointCells[#pathWaypointCells]
    for oc = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
        for or_ = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
            local cc, rr = heartCell[1] + oc, heartCell[2] + or_
            if cc >= 0 and cc < GRID_COLS and rr >= 0 and rr < GRID_ROWS then
                if gridState[cc][rr] == "open" then
                    gridState[cc][rr] = "heart"
                end
            end
        end
    end

    -- Publish fields downstream modules + hub code need.
    ctx.gridState = gridState
    ctx.cellToWorld = cellToWorld
    ctx.pathWaypointCells = pathWaypointCells
    ctx.heartCell = heartCell
    ctx.pathHalf = pathHalf  -- used by map 2's markPathRectMap2 call sites
    ctx.MAX_GRID_ROWS = MAX_GRID_ROWS  -- used by DevReset grid-cleanup loop
end

return Grid
