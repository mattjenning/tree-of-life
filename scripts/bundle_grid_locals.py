#!/usr/bin/env python3
"""
Phase 6d: Collapse 30 top-level grid-config locals in init.client.lua
into a single `mapCfg` table keyed by mapId. Frees ~25 module-scope
register slots — init.client.lua is currently at 187/200, near the
Luau ceiling.

The mapping:
    GRID_COLS         → mapCfg[1].cols / mapCfg[1].totalCols
    GRID_ROWS         → mapCfg[1].rows
    ROOM_CENTER_X     → mapCfg[1].centerX
    ROOM_CENTER_Z     → mapCfg[1].centerZ
    ROOM_WIDTH        → mapCfg[1].width
    ROOM_DEPTH        → mapCfg[1].depth
    FLOOR_Y           → mapCfg[1].floorY
    ROOM_MIN_X        → mapCfg[1].minX
    ROOM_MIN_Z        → mapCfg[1].minZ

    MAP2_*            → mapCfg[2].*
    MAP3_*            → mapCfg[3].*

CELL_SIZE and MAX_GRID_ROWS stay as standalone locals (universal +
derived; cheaper as locals than table accesses on hot paths).

Word-boundary substitution. Run from repo root.
"""
import re
import sys
from pathlib import Path


REPLACEMENTS = [
    # Map 1 (legacy "ROOM_*", "GRID_*", "FLOOR_*" naming).
    ("GRID_COLS",        "mapCfg[1].cols"),
    ("GRID_ROWS",        "mapCfg[1].rows"),
    ("ROOM_CENTER_X",    "mapCfg[1].centerX"),
    ("ROOM_CENTER_Z",    "mapCfg[1].centerZ"),
    ("ROOM_WIDTH",       "mapCfg[1].width"),
    ("ROOM_DEPTH",       "mapCfg[1].depth"),
    ("FLOOR_Y",          "mapCfg[1].floorY"),
    ("ROOM_MIN_X",       "mapCfg[1].minX"),
    ("ROOM_MIN_Z",       "mapCfg[1].minZ"),
    # Map 2.
    ("MAP2_CENTER_X",    "mapCfg[2].centerX"),
    ("MAP2_CENTER_Z",    "mapCfg[2].centerZ"),
    ("MAP2_WIDTH",       "mapCfg[2].width"),
    ("MAP2_DEPTH",       "mapCfg[2].depth"),
    ("MAP2_COLS",        "mapCfg[2].cols"),
    ("MAP2_ROWS",        "mapCfg[2].rows"),
    ("MAP2_COL_OFFSET",  "mapCfg[2].colOffset"),
    ("MAP2_TOTAL_COLS",  "mapCfg[2].totalCols"),
    ("MAP2_FLOOR_Y",     "mapCfg[2].floorY"),
    ("MAP2_MIN_X",       "mapCfg[2].minX"),
    ("MAP2_MIN_Z",       "mapCfg[2].minZ"),
    # Map 3.
    ("MAP3_CENTER_X",    "mapCfg[3].centerX"),
    ("MAP3_CENTER_Z",    "mapCfg[3].centerZ"),
    ("MAP3_WIDTH",       "mapCfg[3].width"),
    ("MAP3_DEPTH",       "mapCfg[3].depth"),
    ("MAP3_COLS",        "mapCfg[3].cols"),
    ("MAP3_ROWS",        "mapCfg[3].rows"),
    ("MAP3_COL_OFFSET",  "mapCfg[3].colOffset"),
    ("MAP3_TOTAL_COLS",  "mapCfg[3].totalCols"),
    ("MAP3_FLOOR_Y",     "mapCfg[3].floorY"),
    ("MAP3_MIN_X",       "mapCfg[3].minX"),
    ("MAP3_MIN_Z",       "mapCfg[3].minZ"),
]

# New block to insert in place of lines 88-127.
NEW_BLOCK = """\
local CELL_SIZE = gridConfig:WaitForChild("CellSize").Value

-- Per-map grid + world-space metadata, keyed by mapId. Bundled into one
-- table to free ~25 module-scope register slots — init.client.lua sits
-- near the Luau 200-register ceiling. Adding map 4 is a one-row append.
local mapCfg = {
    [1] = {
        centerX   = gridConfig:WaitForChild("RoomCenterX").Value,
        centerZ   = gridConfig:WaitForChild("RoomCenterZ").Value,
        width     = gridConfig:WaitForChild("RoomWidth").Value,
        depth     = gridConfig:WaitForChild("RoomDepth").Value,
        floorY    = gridConfig:WaitForChild("FloorY").Value,
        cols      = gridConfig:WaitForChild("GridCols").Value,
        rows      = gridConfig:WaitForChild("GridRows").Value,
        colOffset = 0,
        totalCols = gridConfig:WaitForChild("GridCols").Value,  -- map 1 ends at GRID_COLS
    },
    [2] = {
        centerX   = gridConfig:WaitForChild("Map2CenterX").Value,
        centerZ   = gridConfig:WaitForChild("Map2CenterZ").Value,
        width     = gridConfig:WaitForChild("Map2Width").Value,
        depth     = gridConfig:WaitForChild("Map2Depth").Value,
        floorY    = gridConfig:WaitForChild("Map2FloorY").Value,
        cols      = gridConfig:WaitForChild("Map2Cols").Value,
        rows      = gridConfig:WaitForChild("Map2Rows").Value,
        colOffset = gridConfig:WaitForChild("Map2ColOffset").Value,
        totalCols = gridConfig:WaitForChild("Map2TotalCols").Value,
    },
    [3] = {
        centerX   = gridConfig:WaitForChild("Map3CenterX").Value,
        centerZ   = gridConfig:WaitForChild("Map3CenterZ").Value,
        width     = gridConfig:WaitForChild("Map3Width").Value,
        depth     = gridConfig:WaitForChild("Map3Depth").Value,
        floorY    = gridConfig:WaitForChild("Map3FloorY").Value,
        cols      = gridConfig:WaitForChild("Map3Cols").Value,
        rows      = gridConfig:WaitForChild("Map3Rows").Value,
        colOffset = gridConfig:WaitForChild("Map3ColOffset").Value,
        totalCols = gridConfig:WaitForChild("Map3TotalCols").Value,
    },
}
-- Derive XZ minima (commonly used as the cellToWorld origin).
for _, c in pairs(mapCfg) do
    c.minX = c.centerX - c.width / 2
    c.minZ = c.centerZ - c.depth / 2
end
"""


def main():
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    target = repo / "src" / "client" / "TreeOfLife_Client" / "init.client.lua"
    text = target.read_text(encoding="utf-8")
    eol = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(eol)

    # Locate the block to replace: lines starting with "local CELL_SIZE" /
    # "local GRID_COLS" through to (and including) the ROOM_MIN/MAP*_MIN
    # derivations on lines 122-127.
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith("local CELL_SIZE") and "gridConfig" in ln:
            start = i
            break
    if start is None:
        print("ERROR: didn't find start of grid-config block")
        sys.exit(1)
    end = None
    for i in range(start, len(lines)):
        if lines[i].startswith("local MAP3_MIN_Z"):
            end = i
            break
    if end is None:
        print("ERROR: didn't find end of grid-config block (MAP3_MIN_Z line)")
        sys.exit(1)
    print(f"Replacing init.client.lua lines {start + 1}..{end + 1}")

    # Replace block.
    new_lines = lines[:start] + NEW_BLOCK.split("\n") + lines[end + 1:]

    # Now substitute references throughout. Use word-boundary regex so
    # MAP2_FOO doesn't match inside MAP2_FOO_BAR. We sort longest-name-
    # first to avoid prefix collisions (e.g. MAP2_COL_OFFSET vs MAP2_COL).
    repls_sorted = sorted(REPLACEMENTS, key=lambda x: -len(x[0]))
    body = eol.join(new_lines)
    total = 0
    for old, new in repls_sorted:
        # Skip lines inside the NEW_BLOCK we just inserted; that block uses
        # old gridConfig:WaitForChild keys ("GridCols", "Map2CenterX", etc.)
        # which the regex would also match. Restrict to outside the block.
        # Simpler: do replacement on whole body but exclude WaitForChild
        # arguments by also requiring non-quote context.
        pat = re.compile(r"\b" + re.escape(old) + r"\b")
        # Substitute only when NOT immediately preceded by a quote + space:
        # WaitForChild calls look like '"GridCols"' which the \b boundary
        # does NOT exclude. Trick: use a lookbehind for any non-quote
        # character or string start that isn't a quote.
        def repl(m):
            # If the match is preceded by `"` we keep the original (this is
            # a string literal inside WaitForChild).
            i = m.start()
            if i > 0 and body[i - 1] == '"':
                return m.group(0)
            return new
        new_body, n = pat.subn(repl, body)
        body = new_body
        total += n

    target.write_text(body, encoding="utf-8", newline="")
    print(f"Replaced {total} reference sites.")


if __name__ == "__main__":
    main()
