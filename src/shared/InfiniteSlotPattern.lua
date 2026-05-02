--[[
    InfiniteSlotPattern.lua — Single-source-of-truth INFINITE_PATTERN
    auto-place slot table for Map 4 (Infinite Arena).

    Before ea3-223 this table lived as TWO byte-identical copies in
      - src/server/systems/InfinitePathGeometry.lua:69  (server math + fallback)
      - src/client/TreeOfLife_Client/init.client.lua:2010 (placeInfinitePattern)

    Both kept manually in sync. Per memory feedback_shared_grid_dispatch.md
    the codebase has been bitten by duplicated-table drift before — moving
    the canonical data to shared/ closes that hazard. Verified byte-
    identical via repo audit script before consolidation.

    The pattern is the STATIC (hand-tuned) layout. AutoPlaceStrategy
    computes a dynamic optimal pattern at server boot; when it runs,
    InfinitePathGeometry.setInfinitePattern() overrides the static
    fallback at the public-field level (see PG.getActivePattern()).
    This shared table stays as:
      • the hand-tuned shape spec the dynamic computation derives from
      • the client's reference for placeInfinitePattern()
      • the test fixture for InfinitePathGeometry tests

    Slot layout (36 total, all in MAP4-frame col/row coordinates):
      DPS (16):
        col 6/12   × row 12/17/22/27   — west DPS columns (8)
        col 6/12/18/24/30/42/48/54 × row 50 — DPS bottom-wide block (8)
      Control (12):
        col 18/24  × row 12/17/22/27   — middle Control columns (8)
        col 50     × row 12/17/22/27   — east Control column (4)
      Support (8):
        col 6/12/18/24/30/42/48/54 × row 0  — top Support row

    Slot 1 (col 6, row 12) is the canonical "Power Core anchor"
    position. Pool ordering in placeInfinitePattern puts Power FIRST
    in the DPS pool so the Core always lands there (Matthew 2026-04-26
    "core tower misplaced (circled)" fix).

    The frozen table prevents accidental mutation; consumers that need
    to OVERRIDE for dynamic placement should NOT mutate this table —
    they should call setInfinitePattern() with a separate table.
]]

local InfiniteSlotPattern = {
    -- DPS columns west of the river (rows 12-27 → 4 rows of slots).
    -- Slot 1 reserved for Power Core (the very first DPS pool entry).
    { co =  6, ro = 12, role = "DPS"     },  -- slot 1 — Power Core anchor
    { co =  6, ro = 17, role = "DPS"     },
    { co =  6, ro = 22, role = "DPS"     },
    { co =  6, ro = 27, role = "DPS"     },
    { co = 12, ro = 12, role = "DPS"     },
    { co = 12, ro = 17, role = "DPS"     },
    { co = 12, ro = 22, role = "DPS"     },
    { co = 12, ro = 27, role = "DPS"     },
    -- DPS bottom-wide block. Row 50 is between middle (row 32) and
    -- bottom (row 58) east paths. Right N-S path covers cols 36-40,
    -- so the row splits: cols 6-30 (5 slots) + cols 42-54 (3 slots).
    { co =  6, ro = 50, role = "DPS"     },
    { co = 12, ro = 50, role = "DPS"     },
    { co = 18, ro = 50, role = "DPS"     },
    { co = 24, ro = 50, role = "DPS"     },
    { co = 30, ro = 50, role = "DPS"     },
    { co = 42, ro = 50, role = "DPS"     },
    { co = 48, ro = 50, role = "DPS"     },
    { co = 54, ro = 50, role = "DPS"     },
    -- Control columns mid-zone (rows 12-27).
    { co = 18, ro = 12, role = "Control" },
    { co = 18, ro = 17, role = "Control" },
    { co = 18, ro = 22, role = "Control" },
    { co = 18, ro = 27, role = "Control" },
    { co = 24, ro = 12, role = "Control" },
    { co = 24, ro = 17, role = "Control" },
    { co = 24, ro = 22, role = "Control" },
    { co = 24, ro = 27, role = "Control" },
    -- Control right-side column (col 50, west of river at cols 58-62;
    -- clear of right N-S which is cols 36-40).
    { co = 50, ro = 12, role = "Control" },
    { co = 50, ro = 17, role = "Control" },
    { co = 50, ro = 22, role = "Control" },
    { co = 50, ro = 27, role = "Control" },
    -- Support top-row. LAST in order so DPS / Control fill their
    -- dedicated slots first via pass 1 before fallback assigns
    -- leftovers here.
    { co =  6, ro = 0,  role = "Support" },
    { co = 12, ro = 0,  role = "Support" },
    { co = 18, ro = 0,  role = "Support" },
    { co = 24, ro = 0,  role = "Support" },
    { co = 30, ro = 0,  role = "Support" },
    { co = 42, ro = 0,  role = "Support" },
    { co = 48, ro = 0,  role = "Support" },
    { co = 54, ro = 0,  role = "Support" },
}

-- Freeze each entry + the outer list so accidental mutation throws.
-- (deepFreeze pattern matches Config.lua.)
for _, slot in ipairs(InfiniteSlotPattern) do
    table.freeze(slot)
end
return table.freeze(InfiniteSlotPattern)
