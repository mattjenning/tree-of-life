--[[
    AutoPlaceStrategy.lua — Phase A (2026-04-29 ea3-49).

    Role-aware tower placement scoring for the new bounds-shrinking
    arena sweep. Per Matthew 2026-04-29:

      Core: most central, max path coverage
      Control: corners adjacent to Core
      DPS: max path coverage (after Core occupies a cell)
      Support: last, max overlap with Core+DPS aura range

    USAGE:
        local Strategy = require(...:WaitForChild("AutoPlaceStrategy"))
        Strategy.setup(ctx)  -- gridState, MAP4_*, CELL_SIZE, etc.

        -- Find best cell for a Core
        local col, row = Strategy.findOptimalCell({
            role        = "Core",
            footprintW  = 4, footprintD = 4,
            range       = 22,                       -- studs
            mapId       = 4,
            placedAllies = {},                      -- {{col, row, role}, ...}
        })

    Returns nil, nil if no valid cell found.

    DESIGN:
      All scoring is done in CELLS (Manhattan / Euclidean cell
      distance) to avoid converting to studs every iteration. Range
      gets converted to a cell radius once.

      Path coverage = count of path-tagged cells within the tower's
      cell-radius from the candidate placement center. Higher = better.

      Aura overlap (Support) = count of placed-ally tower-center
      cells within the candidate's cell-radius. Higher = better.

      Corner proximity (Control) = inverse Manhattan distance to the
      nearest Core's footprint corner. Higher = better (closer).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local AutoPlaceStrategy = {}

local _gridState
local _MAP4_COL_OFFSET
local _MAP4_TOTAL_COLS
local _MAP4_ROWS
local _CELL_SIZE
local _canPlaceAt  -- function from TowerPlacement

function AutoPlaceStrategy.setup(ctx)
    _gridState        = ctx.gridState
    _MAP4_COL_OFFSET  = ctx.MAP4_COL_OFFSET
    _MAP4_TOTAL_COLS  = ctx.MAP4_TOTAL_COLS
    _MAP4_ROWS        = ctx.MAP4_ROWS
    _CELL_SIZE        = ctx.CELL_SIZE
    -- canPlaceAt exposed via ctx by TowerPlacement.setup. Late-resolved
    -- via closure so we don't depend on setup ordering between modules.
    _canPlaceAt = function(c, r, fw, fd)
        if ctx.placeTowerForPlayer then
            -- placeTowerForPlayer is the placement closure; it has
            -- canPlaceAt internally but isn't exposed. Use the
            -- separate findOpenCellForMap helper as a probe instead
            -- since it returns nil, nil for unfit cells.
        end
        -- Direct cell-state probe: Core/aux footprints are always
        -- rectangular, so we just check every cell in the footprint
        -- is "open". This duplicates canPlaceAt's logic but avoids
        -- the cross-script wiring complexity.
        for dc = 0, fw - 1 do
            for dr = 0, fd - 1 do
                local cc = c + dc
                local rr = r + dr
                if cc < 0 or rr < 0 then return false end
                if not _gridState[cc] then return false end
                if _gridState[cc][rr] ~= "open" then return false end
            end
        end
        return true
    end
end

-- ===========================================================================
-- Phase-bounds helpers — narrow the iteration range to the active
-- phase when on Map 4. For other maps, returns the full grid range.
-- ===========================================================================

local function getMap4PhaseBounds()
    local phase = Workspace:GetAttribute("Map4ActivePhase")
    if type(phase) ~= "number" then phase = 3 end
    local pb = Config.Map4 and Config.Map4.PhaseBounds and Config.Map4.PhaseBounds[phase]
    if not pb then
        return 0, _MAP4_TOTAL_COLS - _MAP4_COL_OFFSET - 1, 0, _MAP4_ROWS - 1
    end
    return pb.colOffset, pb.colMax, pb.rowOffset, pb.rowMax
end

-- ===========================================================================
-- Scoring functions — all in cell space.
-- ===========================================================================

-- Convert tower range (studs) → cell radius. CELL_SIZE = 2 by default,
-- so a 22-stud range = 11-cell radius.
local function rangeToCellRadius(rangeStud: number): number
    return rangeStud / _CELL_SIZE
end

-- Centre cell of a tower placed at (anchorCol, anchorRow) with footprint W×D.
local function centerOf(anchorCol: number, anchorRow: number, fw: number, fd: number): (number, number)
    return anchorCol + (fw - 1) / 2, anchorRow + (fd - 1) / 2
end

-- Path-coverage score: count of "path"-tagged cells within `cellRadius`
-- of (centerC, centerR). Higher = better.
local function scorePathCoverage(centerC: number, centerR: number, cellRadius: number): number
    local count = 0
    local rInt = math.ceil(cellRadius)
    for dc = -rInt, rInt do
        for dr = -rInt, rInt do
            if dc * dc + dr * dr <= cellRadius * cellRadius then
                local cc = math.floor(centerC + dc)
                local rr = math.floor(centerR + dr)
                if _gridState[cc] and _gridState[cc][rr] == "path" then
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- Aura-overlap score (Support): count of allies (Core + DPS) whose
-- centre cell falls within `cellRadius` of (centerC, centerR).
local function scoreAuraOverlap(centerC: number, centerR: number, cellRadius: number, placedAllies): number
    local count = 0
    for _, ally in ipairs(placedAllies) do
        if ally.role == "Core" or ally.role == "DPS" then
            local dc = ally.centerC - centerC
            local dr = ally.centerR - centerR
            if dc * dc + dr * dr <= cellRadius * cellRadius then
                count = count + 1
            end
        end
    end
    return count
end

-- Corner-proximity score (Control): inverse Manhattan distance to the
-- nearest Core's footprint corner. Higher = better (closer).
local function scoreCornerProximity(centerC: number, centerR: number, placedAllies): number
    local best = math.huge
    for _, ally in ipairs(placedAllies) do
        if ally.role == "Core" then
            -- Core's 4 corners (anchor + footprint extents)
            local fw, fd = ally.footprintW, ally.footprintD
            local corners = {
                { ally.anchorCol,           ally.anchorRow         },
                { ally.anchorCol + fw - 1,  ally.anchorRow         },
                { ally.anchorCol,           ally.anchorRow + fd - 1 },
                { ally.anchorCol + fw - 1,  ally.anchorRow + fd - 1 },
            }
            for _, corner in ipairs(corners) do
                local d = math.abs(centerC - corner[1]) + math.abs(centerR - corner[2])
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then return 0 end
    return 1.0 / (1.0 + best)
end

-- ===========================================================================
-- Public: find the best placement cell for a tower of the given role.
-- ===========================================================================

-- opts: {
--   role         : "Core" | "DPS" | "Control" | "Support"
--   footprintW   : number
--   footprintD   : number
--   range        : number (studs) — for path coverage / aura range
--   mapId        : number (currently only Map 4 supported)
--   placedAllies : { { role, anchorCol, anchorRow, centerC, centerR, footprintW, footprintD }, ... }
--   targetCell   : { col, row }? — ea3-75 OPTIONAL. When provided,
--                  per-role scoring is OVERRIDDEN: cells closer to
--                  targetCell score higher.
--   avoidCell    : { col, row }? — ea3-84 OPTIONAL. When provided,
--                  per-role scoring is KEPT, but cells whose CENTER
--                  is within tower-range of avoidCell get a heavy
--                  penalty so they're rarely picked. Used by
--                  ArenaSweepRunner's phase 4 placement so towers
--                  stay JUST OUT OF range of the stationary Pickle
--                  Lord at the heart cell — towers cover the path,
--                  hit mini-pickles, but the boss itself is outside
--                  reach. Per Matthew "place towers so the pickle
--                  boss is just out of range, but they still have
--                  good path coverage."
-- }
-- Returns: anchorCol, anchorRow (or nil, nil if no fit found)
function AutoPlaceStrategy.findOptimalCell(opts: any): (number?, number?)
    local role         = opts.role or "DPS"
    local footprintW   = opts.footprintW or 4
    local footprintD   = opts.footprintD or 4
    local range        = opts.range or 22
    local mapId        = opts.mapId or 4
    local placedAllies = opts.placedAllies or {}
    local targetCell   = opts.targetCell
    local avoidCell    = opts.avoidCell

    local cellRadius = rangeToCellRadius(range)

    -- Iteration range. Map 4 = phase-aware; other maps fall back to
    -- the full grid. (Sweep mode currently only runs on Map 4 — this
    -- branch is here for future extension.)
    local colMin, colMax, rowMin, rowMax
    if mapId == 4 then
        local localCMin, localCMax, localRMin, localRMax = getMap4PhaseBounds()
        colMin = _MAP4_COL_OFFSET + localCMin
        colMax = _MAP4_COL_OFFSET + localCMax
        rowMin = localRMin
        rowMax = localRMax
    else
        colMin = 0
        colMax = (_gridState and #_gridState) or 0
        rowMin = 0
        rowMax = _MAP4_ROWS - 1
    end

    local bestScore = -math.huge
    local bestCol, bestRow = nil, nil

    -- For each candidate anchor cell that fits the footprint, score by
    -- role and track the best.
    for r = rowMin, rowMax - footprintD + 1 do
        for c = colMin, colMax - footprintW + 1 do
            if _canPlaceAt(c, r, footprintW, footprintD) then
                local centerC, centerR = centerOf(c, r, footprintW, footprintD)
                local score
                if targetCell then
                    -- ea3-85: target-cell mode = JUST INSIDE RANGE.
                    -- Per Matthew "place towers just INSIDE range of
                    -- pickle boss." Out-of-range cells excluded
                    -- (deeply negative score). Among in-range cells,
                    -- prefer MAX distance from target (so towers
                    -- spread to the range edge instead of clustering
                    -- tight at the centre). Path coverage as tiebreak.
                    -- ea3-75's "closer = better" scoring put every
                    -- tower right next to the boss, leaving most of
                    -- the path uncovered; ea3-84's "avoidCell" went
                    -- the other direction (just outside range, no
                    -- boss damage). This middle is: still hits boss,
                    -- still covers path.
                    local dc = centerC - targetCell.col
                    local dr = centerR - targetCell.row
                    local dist = math.sqrt(dc * dc + dr * dr)
                    if dist > cellRadius then
                        score = -1e9  -- out of range → exclude
                    else
                        score = dist * 100  -- closer to range edge = higher
                              + scorePathCoverage(centerC, centerR, cellRadius)
                    end
                elseif role == "Core" then
                    -- Most central + max path coverage. Path coverage
                    -- dominates; centrality nudges ties toward the
                    -- middle of the active bounds (so the Core sits
                    -- where the path winds densest, NOT at a corner
                    -- where coverage might peak by accident).
                    local boundsCenterC = (colMin + colMax) / 2
                    local boundsCenterR = (rowMin + rowMax) / 2
                    local centrality = -(math.abs(centerC - boundsCenterC) + math.abs(centerR - boundsCenterR))
                    score = scorePathCoverage(centerC, centerR, cellRadius) * 100 + centrality
                elseif role == "Control" then
                    -- Adjacent to Core's corner (corner-proximity), with
                    -- path coverage as a tiebreak. Multiplier balances
                    -- "must be near corner" vs "still useful path-wise".
                    local cornerScore = scoreCornerProximity(centerC, centerR, placedAllies)
                    score = cornerScore * 1000 + scorePathCoverage(centerC, centerR, cellRadius)
                elseif role == "Support" then
                    -- Last, max aura overlap with Core + placed DPS.
                    -- Path coverage as tiebreak (so a Support with
                    -- equal aura overlap picks the spot that's closer
                    -- to the path).
                    score = scoreAuraOverlap(centerC, centerR, cellRadius, placedAllies) * 1000
                          + scorePathCoverage(centerC, centerR, cellRadius)
                else  -- DPS (default)
                    -- Max path coverage, no centrality.
                    score = scorePathCoverage(centerC, centerR, cellRadius)
                end
                -- ea3-84: avoid-cell penalty. Cells whose center is
                -- within tower-range of avoidCell drop to a deeply
                -- negative score so they're never picked unless no
                -- out-of-range option exists. Path coverage still
                -- drives selection AMONG out-of-range cells, so
                -- towers cluster along the path just outside the
                -- boss's range.
                if avoidCell then
                    local dc = centerC - avoidCell.col
                    local dr = centerR - avoidCell.row
                    if dc * dc + dr * dr <= cellRadius * cellRadius then
                        score = score - 1e9
                    end
                end
                if score > bestScore then
                    bestScore = score
                    bestCol   = c
                    bestRow   = r
                end
            end
        end
    end

    return bestCol, bestRow
end

-- ===========================================================================
-- ea3-116: precompute the INFINITE_PATTERN slot table that drives the
-- closed-form simulator's path-exposure scoring (InfinitePathGeometry.
-- assignSlots) AND was historically used by client placeInfinitePattern.
-- Old INFINITE_PATTERN was hand-tuned with corners-first slots that left
-- ~25% of each tower's range bulging off-map; this function calls
-- findOptimalCell iteratively to produce slots that match what
-- ArenaSweepRunner's v2 failure-curve sweep actually places.
--
-- Slot layout matches the legacy hand-tuned table's role mix so the sim
-- + any legacy callers see a familiar shape:
--   • 16 DPS slots (Power Core anchor + 15 DPS pool slots)
--   • 12 Control slots
--   •  8 Support slots
-- = 36 slots total. Per-slot role mirrors the static INFINITE_PATTERN
-- so the assignSlots fallback chain (DPS → Control → Support) works
-- identically.
--
-- Per-slot footprint defaults to 4×4 (the standard tower footprint;
-- aux towers with 3×3 / 5×5 footprints fit inside the 4×4 envelope).
-- Per-slot range defaults to 22 studs (Power Core baseline; aux range
-- variance is small enough that the optimal cell is stable).
-- ===========================================================================
function AutoPlaceStrategy.computeInfinitePattern(opts): { { co: number, ro: number, role: string } }
    opts = opts or {}
    local dpsCount     = opts.dpsCount     or 16
    local controlCount = opts.controlCount or 12
    local supportCount = opts.supportCount or 8
    local footprintW   = opts.footprintW   or 4
    local footprintD   = opts.footprintD   or 4
    local range        = opts.range        or 22

    -- Set Map4ActivePhase=3 (full bounds) for the duration of the
    -- computation so findOptimalCell scores against the full path,
    -- not whichever phase happens to be active when we boot.
    local priorPhase = Workspace:GetAttribute("Map4ActivePhase")
    Workspace:SetAttribute("Map4ActivePhase", 3)

    local placedAllies = {}
    local pattern = {}

    local function addSlot(role, anchorCol, anchorRow)
        -- Convert absolute col → grid-local col (matches static
        -- INFINITE_PATTERN convention: co relative to MAP4_COL_OFFSET).
        local localCol = anchorCol - _MAP4_COL_OFFSET
        table.insert(pattern, { co = localCol, ro = anchorRow, role = role })
        local centerC = anchorCol + (footprintW - 1) / 2
        local centerR = anchorRow + (footprintD - 1) / 2
        table.insert(placedAllies, {
            role        = role,
            anchorCol   = anchorCol,
            anchorRow   = anchorRow,
            centerC     = centerC,
            centerR     = centerR,
            footprintW  = footprintW,
            footprintD  = footprintD,
        })
    end

    -- Slot 1 = Power Core anchor (Core role, scored as central + max
    -- path coverage). Subsequent DPS slots score by max path coverage
    -- alone (no centrality nudge — they fill remaining hot spots).
    local coreCol, coreRow = AutoPlaceStrategy.findOptimalCell({
        role         = "Core",
        footprintW   = footprintW,
        footprintD   = footprintD,
        range        = range,
        mapId        = 4,
        placedAllies = {},
    })
    if coreCol and coreRow then
        addSlot("DPS", coreCol, coreRow)  -- DPS role tag (matches static pattern)
    else
        warn("[AutoPlaceStrategy.precompute] Core slot scoring returned nil — falling back to legacy")
        Workspace:SetAttribute("Map4ActivePhase", priorPhase)
        return nil
    end

    -- DPS pool slots (15 more — total 16 DPS slots).
    for _ = 2, dpsCount do
        local c, r = AutoPlaceStrategy.findOptimalCell({
            role         = "DPS",
            footprintW   = footprintW,
            footprintD   = footprintD,
            range        = range,
            mapId        = 4,
            placedAllies = placedAllies,
        })
        if c and r then
            addSlot("DPS", c, r)
        else
            warn(("[AutoPlaceStrategy.precompute] DPS slot %d scoring returned nil — pattern truncated"):format(#pattern + 1))
            break
        end
    end

    -- Control slots (corner-proximity to Core).
    for _ = 1, controlCount do
        local c, r = AutoPlaceStrategy.findOptimalCell({
            role         = "Control",
            footprintW   = footprintW,
            footprintD   = footprintD,
            range        = range,
            mapId        = 4,
            placedAllies = placedAllies,
        })
        if c and r then
            addSlot("Control", c, r)
        else
            break
        end
    end

    -- Support slots (aura-overlap with Core+DPS).
    for _ = 1, supportCount do
        local c, r = AutoPlaceStrategy.findOptimalCell({
            role         = "Support",
            footprintW   = footprintW,
            footprintD   = footprintD,
            range        = range,
            mapId        = 4,
            placedAllies = placedAllies,
        })
        if c and r then
            addSlot("Support", c, r)
        else
            break
        end
    end

    Workspace:SetAttribute("Map4ActivePhase", priorPhase)
    print(("[AutoPlaceStrategy] computed INFINITE_PATTERN — %d slots (%d DPS / %d Control / %d Support)"):format(
        #pattern,
        math.min(dpsCount, #pattern),
        math.max(0, math.min(controlCount, #pattern - dpsCount)),
        math.max(0, #pattern - dpsCount - controlCount)))
    return pattern
end

return AutoPlaceStrategy
