--[[
    InfinitePathGeometry.lua — Pure-math path / coverage helpers
    for the closed-form simulator.

    Per project_simulator_improvement.md Phase 2: replace the v1
    sim's uniform `range / PATH_LENGTH` coverage (which treats
    every tower as if it sees the entire path) with per-segment
    line-circle intersection math from the actual Map 4 waypoints
    + INFINITE_PATTERN auto-place positions. A tower far from the
    river only catches mobs on the leg that passes near it; a
    tower near the heart sees mobs much later (less time to kill).

    All geometry is pure number-crunching — no Roblox dependency,
    no Workspace reads. Coordinates are 2D (col, row) in CELL
    units; pass `cellSize` (default 2 studs) to convert to studs
    when needed. Mob speeds (studs/sec) come from
    Config.InfiniteArena.MobBaseline.

    DESIGN
    ------
    • Map 4 path: 6 waypoints in cell coords, MAP4_COL_OFFSET-
      stripped (the simulator only cares about RELATIVE geometry,
      not the absolute world position). Same cells the live
      Map4.lua build uses, kept in sync via Phase-2 commit.
    • Auto-place pattern: 32 slot positions, role-tagged. First N
      get filled by the loadout's towers in role-priority order
      (DPS slots first, then Control, then Support). Solo
      consumes slots 1-2, Duo 1-3, Trio 1-4.
    • Per-tower exposure: sum over each path segment of the line-
      segment ∩ circle intersection length, in studs.
    • Per-mob exposure time: exposure_studs / mob_speed.

    LIMITATIONS (callable for Phase-2 tests; don't pretend they're
    accurate yet):
      ✗ Tower auto-place falls back across roles (DPS pool overflow
        → Control slots, etc). Phase 2 v1 picks the FIRST slot of
        the matching role; if no slot matches it falls back to the
        next available slot regardless of role. Live game's
        fallback algorithm is more sophisticated.
      ✗ Power Core slot 1 is forced (matches live).
      ✗ Trio anchor InfiniteStandard always lands in a DPS slot.
      ✗ Mob speed is uniform across the path (no speed changes
        per segment yet — Phase 3 slow integration handles
        slow-segment vs free-segment splits).
]]

local InfinitePathGeometry = {}

------------------------------------------------------------
-- Map 4 path waypoints (cell coords, MAP4_COL_OFFSET stripped).
-- Source: server/world/Map4.lua:135-142 — must stay in sync.
-- Per Matthew 2026-04-26: leftmost N-S leg lives at col 2.
------------------------------------------------------------
local MAP4_PATH_CELLS = {
    { 5, 58 },  -- SW spawn
    { 38, 58 }, -- east leg along row 58
    { 38, 32 }, -- north along col 38
    { 2,  32 }, -- west to far-left wall
    { 2,  8  }, -- north along col 2 (against boundary)
    { 80, 8  }, -- east, all the way to heart
}
InfinitePathGeometry.PATH_CELLS = MAP4_PATH_CELLS

------------------------------------------------------------
-- INFINITE_PATTERN auto-place slots — mirror of
-- client/init.client.lua:1895. Role tags drive solo/duo/trio
-- assignment.
------------------------------------------------------------
local INFINITE_PATTERN = {
    { co =  6, ro = 12, role = "DPS"     },  -- slot 1 — Power Core anchor
    { co =  6, ro = 17, role = "DPS"     },
    { co =  6, ro = 22, role = "DPS"     },
    { co =  6, ro = 27, role = "DPS"     },
    { co = 12, ro = 12, role = "DPS"     },
    { co = 12, ro = 17, role = "DPS"     },
    { co = 12, ro = 22, role = "DPS"     },
    { co = 12, ro = 27, role = "DPS"     },
    { co =  6, ro = 50, role = "DPS"     },
    { co = 12, ro = 50, role = "DPS"     },
    { co = 18, ro = 50, role = "DPS"     },
    { co = 24, ro = 50, role = "DPS"     },
    { co = 30, ro = 50, role = "DPS"     },
    { co = 42, ro = 50, role = "DPS"     },
    { co = 48, ro = 50, role = "DPS"     },
    { co = 54, ro = 50, role = "DPS"     },
    { co = 18, ro = 12, role = "Control" },
    { co = 18, ro = 17, role = "Control" },
    { co = 18, ro = 22, role = "Control" },
    { co = 18, ro = 27, role = "Control" },
    { co = 24, ro = 12, role = "Control" },
    { co = 24, ro = 17, role = "Control" },
    { co = 24, ro = 22, role = "Control" },
    { co = 24, ro = 27, role = "Control" },
    { co = 50, ro = 12, role = "Control" },
    { co = 50, ro = 17, role = "Control" },
    { co = 50, ro = 22, role = "Control" },
    { co = 50, ro = 27, role = "Control" },
    { co =  6, ro = 0,  role = "Support" },
    { co = 12, ro = 0,  role = "Support" },
    { co = 18, ro = 0,  role = "Support" },
    { co = 24, ro = 0,  role = "Support" },
    { co = 30, ro = 0,  role = "Support" },
    { co = 42, ro = 0,  role = "Support" },
    { co = 48, ro = 0,  role = "Support" },
    { co = 54, ro = 0,  role = "Support" },
}
InfinitePathGeometry.INFINITE_PATTERN = INFINITE_PATTERN

-- ea3-116: dynamic pattern override hook. AutoPlaceStrategy can compute
-- an optimal slot table at server boot via computeInfinitePattern(); the
-- result lands here via setInfinitePattern(). When set, assignSlots /
-- pathExposureCells / etc. read from the dynamic pattern. When nil,
-- fall back to the static (hand-tuned) INFINITE_PATTERN above. The
-- static stays as the authoritative shape spec (slot count + role mix)
-- and as a fallback for client / test contexts where AutoPlaceStrategy
-- isn't available.
local _dynamicPattern: { { co: number, ro: number, role: string } }? = nil

-- ea3-117: setter must ONLY be called during server boot (Hub.server.lua
-- after AutoPlaceStrategy.setup) or BETWEEN sweeps. A mid-sweep call
-- creates a split-pattern hazard — early-placed towers use the OLD
-- pattern, late-placed use the NEW; sim sees neither cleanly and the
-- validator delta inflates. The caller (currently only Hub) knows the
-- timing and is responsible for the constraint. This module stays
-- Roblox-free per the header docstring (no Workspace reads).
function InfinitePathGeometry.setInfinitePattern(pattern)
    if type(pattern) ~= "table" or #pattern == 0 then
        warn("[InfinitePathGeometry] setInfinitePattern called with empty pattern — keeping static fallback")
        return
    end
    _dynamicPattern = pattern
    InfinitePathGeometry.INFINITE_PATTERN = pattern  -- keep public field in sync
    print(("[InfinitePathGeometry] dynamic pattern installed — %d slots"):format(#pattern))
end

function InfinitePathGeometry.getActivePattern()
    return _dynamicPattern or INFINITE_PATTERN
end

------------------------------------------------------------
-- Public: segmentCircleIntersection(p1, p2, c, r)
--   p1, p2 = {x, y} segment endpoints
--   c      = {x, y} circle center
--   r      = radius
-- Returns the length of the segment that lies INSIDE the circle.
--
-- Math: parametrize segment as p1 + t*(p2-p1), t in [0,1].
-- Solve |p1 + t*d - c| = r → quadratic in t. Length = (t1-t0) *
-- |d| where [t0, t1] is the clamped intersection range.
------------------------------------------------------------
function InfinitePathGeometry.segmentCircleIntersection(p1, p2, c, r)
    local dx, dy = p2[1] - p1[1], p2[2] - p1[2]
    local fx, fy = p1[1] - c[1], p1[2] - c[2]
    local a = dx * dx + dy * dy
    if a == 0 then
        -- p1 == p2 (zero-length segment): inside ↔ at center within r.
        if (fx * fx + fy * fy) <= r * r then return 0 end
        return 0
    end
    local b = 2 * (fx * dx + fy * dy)
    local cc = fx * fx + fy * fy - r * r
    local disc = b * b - 4 * a * cc
    if disc < 0 then return 0 end
    local sq = math.sqrt(disc)
    local t0 = (-b - sq) / (2 * a)
    local t1 = (-b + sq) / (2 * a)
    if t0 > t1 then t0, t1 = t1, t0 end
    -- Clamp to [0, 1] (segment range).
    if t1 < 0 or t0 > 1 then return 0 end
    if t0 < 0 then t0 = 0 end
    if t1 > 1 then t1 = 1 end
    local segLen = math.sqrt(a)
    return (t1 - t0) * segLen
end

------------------------------------------------------------
-- Public: pathExposureCells(towerCol, towerRow, towerRange, pathCells?)
--   Total exposure length (in CELLS) for a tower at (col, row)
--   with the given range, summed across every path segment.
--   pathCells defaults to MAP4_PATH_CELLS.
------------------------------------------------------------
function InfinitePathGeometry.pathExposureCells(towerCol, towerRow, towerRange, pathCells)
    pathCells = pathCells or MAP4_PATH_CELLS
    local total = 0
    local center = { towerCol, towerRow }
    for i = 1, #pathCells - 1 do
        local a, b = pathCells[i], pathCells[i + 1]
        total = total + InfinitePathGeometry.segmentCircleIntersection(
            { a[1], a[2] }, { b[1], b[2] }, center, towerRange)
    end
    return total
end

------------------------------------------------------------
-- Public: pathLengthCells(pathCells?) — total length in cells.
------------------------------------------------------------
function InfinitePathGeometry.pathLengthCells(pathCells)
    pathCells = pathCells or MAP4_PATH_CELLS
    local total = 0
    for i = 1, #pathCells - 1 do
        local a, b = pathCells[i], pathCells[i + 1]
        local dx, dy = b[1] - a[1], b[2] - a[2]
        total = total + math.sqrt(dx * dx + dy * dy)
    end
    return total
end

------------------------------------------------------------
-- Public: assignSlots(roles)
--   `roles` = list of {"DPS", "Control", "Support", ...} in
--   loadout order (Power first, then auxes in the order they
--   appear in the queue).
--   Returns a parallel list of pattern slots, one per role
--   entry. Algorithm:
--     1. Power → slot 1 (forced DPS anchor).
--     2. Each subsequent tower picks the FIRST unused pattern
--        slot whose role matches; if no role match, falls back
--        to the first unused slot of any role.
--   This is a simplification of the live auto-place fallback
--   chain (which tries spiral fits when slot is occupied) but
--   is sufficient for Phase-2 sim accuracy.
------------------------------------------------------------
function InfinitePathGeometry.assignSlots(roles)
    if type(roles) ~= "table" or #roles == 0 then return {} end
    local pattern = _dynamicPattern or INFINITE_PATTERN
    local used = {}
    local out = {}
    for i, role in ipairs(roles) do
        if i == 1 then
            -- Power slot 1 anchor — always slot[1] (DPS-tagged in
            -- the pattern, which is fine since Power is DPS-roled).
            out[1] = pattern[1]
            used[1] = true
        else
            local picked = nil
            for slotIdx, slot in ipairs(pattern) do
                if not used[slotIdx] and slot.role == role then
                    picked = slotIdx
                    break
                end
            end
            if not picked then
                -- Fallback: any unused slot.
                for slotIdx in ipairs(pattern) do
                    if not used[slotIdx] then
                        picked = slotIdx
                        break
                    end
                end
            end
            if picked then
                out[i] = pattern[picked]
                used[picked] = true
            end
        end
    end
    return out
end

------------------------------------------------------------
-- Public: exposureSecondsForTower(slot, towerRange, mobSpeed, cellSize?)
--   Convenience: combines pathExposureCells × cellSize / mobSpeed
--   to produce game-seconds-of-exposure per mob for a tower at
--   the given pattern slot.
------------------------------------------------------------
function InfinitePathGeometry.exposureSecondsForTower(slot, towerRange, mobSpeed, cellSize)
    if not slot then return 0 end
    cellSize = cellSize or 2
    -- Tower range is in studs; convert to cell units for the
    -- cell-coord geometry (range_cells = range_studs / cellSize).
    local rangeCells = towerRange / cellSize
    local exposureCells = InfinitePathGeometry.pathExposureCells(
        slot.co, slot.ro, rangeCells)
    local exposureStuds = exposureCells * cellSize
    if mobSpeed <= 0 then return 0 end
    return exposureStuds / mobSpeed
end

return InfinitePathGeometry
