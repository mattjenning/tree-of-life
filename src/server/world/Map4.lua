--[[
    Map4.lua — Pickle Swamp / Infinite Arena terrain.

    Phase 1 of project_infinite_arena.md (balance / benchmark sandbox).
    Reached via the hub's swirling green portal, NOT via SwitchMap from
    a prior map. Tower placement, mob walking, StatLedger all reuse the
    standard mapId pipeline; the wave system gets a custom infinite
    spawner instead of WAVES[4] (B2d follow-up).

    Visual brief (Matthew, 2026-04-26):
      • Swamp-like base — dark slate-green floor with irregular bumps
      • Steam clouds drifting above the ground (anchored translucent
        spheres bobbing via Heartbeat tweens)
      • Green slime river winding N-S across the map
      • Rickety wooden bridges where the mob path crosses the river
      • A mini volcano in the NE corner oozing green slime + smoke
      • Pickle trees with glowing pickle-fruit point lights — the fruit
        is the primary light source for the map (no skybox sun)

    Mirrors Map3.lua's setup(ctx) shape:
      Reads:  MAP4_CENTER, MAP4_WIDTH, MAP4_DEPTH, MAP4_HEIGHT,
              CELL_SIZE, MAP4_COL_OFFSET, MAP4_TOTAL_COLS, MAP4_ROWS,
              MAP4_COLS, HEART_EXCLUSION_CELLS, makePart, rand,
              cellToWorld, gridState, pathHalf
      Publishes:
              ctx.map4Room
              ctx.map4Heart
              ctx.MAP4_PLAYER_SPAWN_CF
]]

local Workspace         = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags   = require(Shared:WaitForChild("Tags"))
local Config = require(Shared:WaitForChild("Config"))

local Map4 = {}

function Map4.setup(ctx)
    local MAP4_CENTER     = ctx.MAP4_CENTER
    local MAP4_WIDTH      = ctx.MAP4_WIDTH
    local MAP4_DEPTH      = ctx.MAP4_DEPTH
    local MAP4_HEIGHT     = ctx.MAP4_HEIGHT
    local CELL_SIZE       = ctx.CELL_SIZE
    local MAP4_COL_OFFSET = ctx.MAP4_COL_OFFSET
    local MAP4_TOTAL_COLS = ctx.MAP4_TOTAL_COLS
    local MAP4_ROWS       = ctx.MAP4_ROWS
    local HEART_EXCLUSION_CELLS = ctx.HEART_EXCLUSION_CELLS

    local makePart = ctx.makePart
    local rand     = ctx.rand

    local cellToWorld = ctx.cellToWorld
    local gridState   = ctx.gridState
    local pathHalf    = ctx.pathHalf

    local map4Room = Instance.new("Model")
    map4Room.Name = "TreeOfLifeMap4Room"
    map4Room.Parent = Workspace

    local m4c       = MAP4_CENTER
    local m4HalfW   = MAP4_WIDTH / 2
    local m4HalfD   = MAP4_DEPTH / 2
    local floorTopY = m4c.Y + 1   -- floor part top surface

    -- Player spawn — on the floor near the path's start corner so the
    -- player lands looking toward the heart on entry.
    local MAP4_PLAYER_SPAWN_POS = m4c + Vector3.new(-m4HalfW + 18, 4, m4HalfD - 22)
    local MAP4_PLAYER_SPAWN_CF = CFrame.lookAt(
        MAP4_PLAYER_SPAWN_POS,
        Vector3.new(m4c.X + 30, m4c.Y + 1, m4c.Z))

    ------------------------------------------------------------
    -- FLOOR — dark slate-green swamp surface. Single big slab; the
    -- "irregular bumps" come from scattered raised slate tiles
    -- placed on top (next block) so we don't have to fragment the
    -- main floor into 4000+ parts.
    ------------------------------------------------------------
    makePart({
        Name = "Map4Floor",
        Size = Vector3.new(MAP4_WIDTH, 2, MAP4_DEPTH),
        CFrame = CFrame.new(m4c),
        Material = Enum.Material.Slate,
        Color = Color3.fromRGB(48, 58, 42),
        Parent = map4Room,
    })

    ------------------------------------------------------------
    -- INVISIBLE WALL BARRIERS (mob/player containment)
    ------------------------------------------------------------
    local INVIS_THICK = 1
    local function invisWall(name, size, cframe)
        local p = makePart({
            Name = name,
            Size = size,
            CFrame = cframe,
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(40, 30, 20),
            Transparency = 1,
            Parent = map4Room,
        })
        p.CastShadow = false
        return p
    end
    invisWall("Map4InvisWallW",
        Vector3.new(INVIS_THICK, MAP4_HEIGHT, MAP4_DEPTH + INVIS_THICK * 2),
        CFrame.new(m4c + Vector3.new(-m4HalfW - INVIS_THICK/2, MAP4_HEIGHT/2, 0)))
    invisWall("Map4InvisWallE",
        Vector3.new(INVIS_THICK, MAP4_HEIGHT, MAP4_DEPTH + INVIS_THICK * 2),
        CFrame.new(m4c + Vector3.new(m4HalfW + INVIS_THICK/2, MAP4_HEIGHT/2, 0)))
    invisWall("Map4InvisWallN",
        Vector3.new(MAP4_WIDTH, MAP4_HEIGHT, INVIS_THICK),
        CFrame.new(m4c + Vector3.new(0, MAP4_HEIGHT/2, -m4HalfD - INVIS_THICK/2)))
    invisWall("Map4InvisWallS",
        Vector3.new(MAP4_WIDTH, MAP4_HEIGHT, INVIS_THICK),
        CFrame.new(m4c + Vector3.new(0, MAP4_HEIGHT/2, m4HalfD + INVIS_THICK/2)))

    ------------------------------------------------------------
    -- ENEMY PATH waypoints (must be declared before river/bridges
    -- so the path-grid marking is in place when river-cells get
    -- "decor" painted under bridges).
    --
    -- Path layout: start in SW, two N-S legs separated by the river,
    -- end at heart in NE. Crosses the river (~col offset+30) twice.
    ------------------------------------------------------------
    -- Per Matthew 2026-04-26: "move the leftern-most path up against
    -- the map boundary to make more room and tetris the towers before
    -- placing to maximize real estate." Leftmost N-S leg shifted from
    -- col 8 to col 2 (path band cols 0-4 with pathHalf=2). Frees ~6
    -- cells of horizontal space (cols 5-10) between the path and the
    -- DPS column for tighter tower packing.
    local map4PathCells = {
        {MAP4_COL_OFFSET +  5, 58},   -- SW spawn
        {MAP4_COL_OFFSET + 38, 58},   -- east leg along row 58
        {MAP4_COL_OFFSET + 38, 32},   -- north along col 38
        {MAP4_COL_OFFSET +  2, 32},   -- west to far-left wall
        {MAP4_COL_OFFSET +  2,  8},   -- north along col 2 (against boundary)
        {MAP4_COL_OFFSET + 80,  8},   -- east, all the way to heart
    }
    local function markPathRect(c1, r1, c2, r2)
        local cmin, cmax = math.min(c1, c2), math.max(c1, c2)
        local rmin, rmax = math.min(r1, r2), math.max(r1, r2)
        for c = cmin, cmax do
            for r = rmin, rmax do
                if c >= MAP4_COL_OFFSET and c < MAP4_TOTAL_COLS
                   and r >= 0 and r < MAP4_ROWS then
                    gridState[c][r] = "path"
                end
            end
        end
    end
    for i = 1, #map4PathCells - 1 do
        local a, b = map4PathCells[i], map4PathCells[i+1]
        if a[1] == b[1] then
            markPathRect(a[1] - pathHalf, math.min(a[2], b[2]) - pathHalf,
                         a[1] + pathHalf, math.max(a[2], b[2]) + pathHalf)
        else
            markPathRect(math.min(a[1], b[1]) - pathHalf, a[2] - pathHalf,
                         math.max(a[1], b[1]) + pathHalf, a[2] + pathHalf)
        end
    end
    local m4HeartCell = map4PathCells[#map4PathCells]
    for dc = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
        for dr = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
            local cc, rr = m4HeartCell[1] + dc, m4HeartCell[2] + dr
            if cc >= MAP4_COL_OFFSET and cc < MAP4_TOTAL_COLS
               and rr >= 0 and rr < MAP4_ROWS then
                gridState[cc][rr] = "heart"
            end
        end
    end

    ------------------------------------------------------------
    -- SLIME RIVER — vertical winding ribbon at roughly col offset+22.
    -- Built as overlapping slate-blue cylinder segments (longer-axis
    -- horizontal, lying on the floor) to read as a continuous flow
    -- with subtle wobble. Glows green via Neon material.
    --
    -- ALSO marks the river cells in gridState as "river" so towers
    -- can't be placed in the slime. Bridges where the path crosses
    -- (rows 30-34 and 56-60) are already marked "path" by the loop
    -- above — we skip cells that aren't currently "open" so bridges
    -- stay walkable and the heart-exclusion zone stays intact.
    ------------------------------------------------------------
    local SLIME_COLOR = Color3.fromRGB(80, 220, 80)
    -- River runs VERTICAL (north-south, along Z) on the heart side
    -- of the map at col 60. Crosses the top east path (row 8) once
    -- at (col 60, row 8) where the path comes west from the heart.
    -- Per Matthew 2026-04-26: "the river runs the wrong way. it
    -- should be rotated 90 degrees." Was horizontal at row 14; now
    -- vertical at col 60.
    local riverCenterCol = MAP4_COL_OFFSET + 60
    local RIVER_HALF_WIDTH = 5  -- studs (perpendicular to flow direction)
    -- River spans the FULL map height (rows 0 to MAP4_ROWS-1).
    -- Per Matthew 2026-04-26: "river needs to go all the way out".
    -- Doesn't add new path crossings — col 60 only intersects the
    -- top east leg (row 8); other paths are at col 36-40 (right N-S),
    -- col 8 (left N-S), and rows 30-34 / 56-60 (east legs) which all
    -- miss col 60.
    local RIVER_ROW_MAX = MAP4_ROWS - 1

    -- River-cell band: cols 58-62 (centered at col 60, ±2 cells).
    -- Cells already marked "path" (top east at row 6-10) stay path
    -- so the bridge crossing still walks.
    do
        local RIVER_CELL_HALF = 2  -- cols 58-62
        for c = riverCenterCol - RIVER_CELL_HALF, riverCenterCol + RIVER_CELL_HALF do
            for r = 0, RIVER_ROW_MAX do
                if c >= MAP4_COL_OFFSET and c < MAP4_TOTAL_COLS then
                    if gridState[c] and gridState[c][r] == "open" then
                        gridState[c][r] = "river"
                    end
                end
            end
        end
    end
    do
        local riverFolder = Instance.new("Folder")
        riverFolder.Name = "Map4SlimeRiver"
        riverFolder.Parent = map4Room
        -- Segment count scales with river length. Full-height river
        -- (rows 0-65) needs ~22 segments at ~3 rows / segment for
        -- visual continuity. Each segment is ~7 rows long with
        -- overlap.
        local segCount = 22
        for i = 0, segCount - 1 do
            local t = i / (segCount - 1)
            local row = t * RIVER_ROW_MAX
            -- Sinusoidal wobble across cols (perpendicular to flow).
            local wobble = math.sin(t * math.pi * 1.4) * 4
            local centerCellWorld = cellToWorld(
                math.floor(riverCenterCol + wobble / CELL_SIZE),
                math.floor(row))
            local seg = makePart({
                Name = "SlimeRiverSeg" .. i,
                -- Long axis along Z (flow direction = north-south).
                -- Size: perpendicular X = RIVER_HALF_WIDTH * 2,
                -- along-flow Z = enough to slightly overlap neighbor.
                Size = Vector3.new(RIVER_HALF_WIDTH * 2, 0.6, CELL_SIZE * 4),
                CFrame = CFrame.new(centerCellWorld.X, floorTopY + 0.05, centerCellWorld.Z),
                Material = Enum.Material.Neon,
                Color = SLIME_COLOR,
                Transparency = 0.15,
                CanCollide = false,
                Parent = riverFolder,
            })
            seg.CastShadow = false
        end
        -- Slime banks — raised mucky border parts on each side of
        -- the river. Now along X axis (east + west of the river)
        -- since flow runs north-south.
        --
        -- Skip the EAST bank around row 58 where the volcano flow
        -- crosses — the bank slab cuts across the flow path
        -- (perpendicular to it) and reads as a stone gap between
        -- the volcano pool and the river. Per Matthew 2026-04-26:
        -- "remove that stone or raise the level of slime coming
        -- from the volcano." Removed.
        for side = -1, 1, 2 do
            for i = 0, segCount - 1 do
                local t = i / (segCount - 1)
                local row = t * RIVER_ROW_MAX
                -- East bank skip window covers row 58 ± 4 to fully
                -- clear the volcano-flow corridor (FLOW_WIDTH ≈ 6.4
                -- in studs, plus a stud or two on each side).
                if side == 1 and math.abs(row - 58) <= 4 then
                    continue
                end
                local wobble = math.sin(t * math.pi * 1.4) * 4
                local centerCellWorld = cellToWorld(
                    math.floor(riverCenterCol + wobble / CELL_SIZE),
                    math.floor(row))
                makePart({
                    Name = "SlimeBank" .. side .. "_" .. i,
                    Size = Vector3.new(2.5, 0.4, CELL_SIZE * 5),
                    CFrame = CFrame.new(
                        centerCellWorld.X + side * (RIVER_HALF_WIDTH + 1.2),
                        floorTopY + 0.2,
                        centerCellWorld.Z),
                    Material = Enum.Material.Slate,
                    Color = Color3.fromRGB(60, 70, 50),
                    Parent = riverFolder,
                })
            end
        end
    end

    ------------------------------------------------------------
    -- BRIDGE — single bridge over the horizontal river where the
    -- southbound left N-S path leg (col 8) crosses it (row ~14).
    -- Path cells at col 8 rows 12-16 stay marked "path" (markPath
    -- ran first, river marking skips non-open cells), so the
    -- southbound walk works regardless. Bridge is decorative.
    ------------------------------------------------------------
    do
        local bridgeFolder = Instance.new("Folder")
        bridgeFolder.Name = "Map4Bridges"
        bridgeFolder.Parent = map4Room
        -- River is vertical at col 60 rows 0-30; top east path runs
        -- along row 8 cols 6-82. Bridge sits at the crossing
        -- (col 60, row 8) and runs east-west (perpendicular to the
        -- river's north-south flow), so its long axis is X.
        local crossCenter = cellToWorld(riverCenterCol, 8)
        local crossX, crossZ = crossCenter.X, crossCenter.Z
        for plank = 0, 4 do
            makePart({
                Name = "BridgePlank_" .. plank,
                Size = Vector3.new(2.4, 0.4, RIVER_HALF_WIDTH * 2.4),
                CFrame = CFrame.new(
                    crossX - 6 + plank * 3,
                    floorTopY + 0.3,
                    crossZ)
                    * CFrame.Angles(rand(-2, 2) * math.pi / 180,
                                    0,
                                    rand(-3, 3) * math.pi / 180),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(95, 60, 35),
                Parent = bridgeFolder,
            })
        end
        -- Posts at each end of the bridge (X-axis since bridge runs
        -- east-west here).
        for postSide = -1, 1, 2 do
            makePart({
                Name = "BridgePost_" .. postSide,
                Size = Vector3.new(0.6, 4, 0.6),
                CFrame = CFrame.new(
                    crossX + postSide * 7,
                    floorTopY + 2,
                    crossZ - RIVER_HALF_WIDTH * 1.1),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(85, 55, 30),
                Parent = bridgeFolder,
            })
            makePart({
                Name = "BridgePost_" .. postSide .. "B",
                Size = Vector3.new(0.6, 4, 0.6),
                CFrame = CFrame.new(
                    crossX + postSide * 7,
                    floorTopY + 2,
                    crossZ + RIVER_HALF_WIDTH * 1.1),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(85, 55, 30),
                Parent = bridgeFolder,
            })
        end
    end

    ------------------------------------------------------------
    -- MINI VOLCANO — stacked cylinders forming a cone in the NE
    -- corner, with a smoke ParticleEmitter at the top + slime
    -- drips that "ooze" toward the river. Visual only; doesn't
    -- damage / interact with mobs.
    ------------------------------------------------------------
    do
        local volcanoFolder = Instance.new("Folder")
        volcanoFolder.Name = "Map4Volcano"
        volcanoFolder.Parent = map4Room
        local volcanoBase = cellToWorld(MAP4_COL_OFFSET + 78, 58)
        -- Volcano scaled 2x per Matthew 2026-04-26: "make volcano
        -- 2x sized" — was 7 base / 14 tall, now 14 base / 28 tall.
        -- Stays SE-corner placement; doesn't reach the heart (col
        -- 80, row 8) or the river (col 60) since volcano is row 58
        -- and the new west edge is at col ~75 (still well east of
        -- the river).
        local CONE_LAYERS = 8
        local BASE_R = 14
        local TIP_R  = 3.2
        local CONE_H = 28
        for i = 0, CONE_LAYERS - 1 do
            local t = i / (CONE_LAYERS - 1)
            local r = BASE_R + (TIP_R - BASE_R) * t
            local layer = makePart({
                Name = "VolcanoLayer" .. i,
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(CONE_H / CONE_LAYERS + 0.05, r * 2, r * 2),
                CFrame = CFrame.new(
                    volcanoBase.X,
                    floorTopY + (i + 0.5) * (CONE_H / CONE_LAYERS),
                    volcanoBase.Z)
                    * CFrame.Angles(0, 0, math.rad(90)),
                Material = Enum.Material.Slate,
                -- Gradient base→tip: ashy gray bottom, hot greenish top.
                Color = Color3.fromRGB(
                    math.floor(70 + t * 20),
                    math.floor(70 + t * 60),
                    math.floor(60 + t * 30)),
                Parent = volcanoFolder,
            })
            local _ = layer
        end
        -- Glowing slime mouth at the top.
        makePart({
            Name = "VolcanoMouth",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.6, TIP_R * 2.1, TIP_R * 2.1),
            CFrame = CFrame.new(
                volcanoBase.X, floorTopY + CONE_H + 0.2, volcanoBase.Z)
                * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Neon,
            Color = SLIME_COLOR,
            Transparency = 0.05,
            Parent = volcanoFolder,
        })
        -- Slime ooze — uses the SAME visual treatment as the river
        -- (Neon slabs, SLIME_COLOR, transparency 0.15) per Matthew
        -- 2026-04-26: "the volcano flowing water doesn't look like
        -- the river, use the same effect and have it cascade down
        -- the volcano and flow into the river" + follow-up "make
        -- the slime waterfall thinner and have it match the volcano
        -- topography better, and remove the gap from the pool to
        -- the river."
        --
        -- Two phases:
        --   1. Cascade — 8 tilted slabs (one per cone cylinder
        --      layer) hugging the cone's western slope. Width
        --      tapers from ~3 at the base to ~1.2 at the tip so
        --      the cascade traces the cone's silhouette instead
        --      of slabbing across it.
        --   2. Ground flow — narrow Neon slabs from the cone base
        --      west, extended INTO the river at row 58 so there's
        --      no gap between the pool and the slime river (the
        --      river segment at this row wobbles ~3 studs west of
        --      its unwobbled center, so we end the flow well past
        --      the unwobbled east bank).
        local mouthY      = floorTopY + CONE_H + 0.1
        -- cascadeTop sits ON the cone's WEST face at the tip
        -- (X = vX - TIP_R), not inside it (was vX - TIP_R * 0.6,
        -- which placed the top slab between the cone center and
        -- the face — the cascade visually floated inside the
        -- cone). Per Matthew 2026-04-26: "make sure the slime is
        -- on the face of the volano." With cascadeBase at
        -- vX - BASE_R and cascadeTop at vX - TIP_R, the cascade
        -- now interpolates exactly along the cone's west slope.
        local cascadeTop  = Vector3.new(
            volcanoBase.X - TIP_R, mouthY, volcanoBase.Z)
        -- Cascade base sits AT the floor surface (was floorY+0.4)
        -- so the slanted lower edge of the bottom slab actually
        -- touches the ground; combined with the eastward extension
        -- of the ground flow (below) this closes the visible gap
        -- at the cone base. Per Matthew 2026-04-26: "fix the red
        -- circled part. there should be no gap."
        local cascadeBase = Vector3.new(
            volcanoBase.X - BASE_R, floorTopY + 0.05, volcanoBase.Z)
        local cascadeVec  = cascadeTop - cascadeBase  -- base→top
        local cascadeLen  = cascadeVec.Magnitude
        -- Slope angle = atan2(rise, run). Rotating a default-flat
        -- slab by this angle around Z aligns its long axis along
        -- the cone slope (east end up, west end down).
        local slopeAngle  = math.atan2(cascadeVec.Y, cascadeVec.X)
        local CASCADE_SEGS = CONE_LAYERS  -- 8 — one per cone layer
        -- Cascade width scales with the cone size. At BASE_R=14
        -- (2x volcano), base width = 6 / tip width = 2.4 — still
        -- hugs the cone face without slabbing across it.
        local CASCADE_WIDTH_BASE = BASE_R * 0.43   -- = 6 at BASE_R=14
        local CASCADE_WIDTH_TIP  = TIP_R  * 0.75   -- = 2.4 at TIP_R=3.2
        for i = 0, CASCADE_SEGS - 1 do
            local t = (i + 0.5) / CASCADE_SEGS  -- 0 = base, 1 = top
            local mid = cascadeBase + cascadeVec * t
            local segLen = (cascadeLen / CASCADE_SEGS) * 1.25  -- overlap
            local segWidth = CASCADE_WIDTH_BASE
                + (CASCADE_WIDTH_TIP - CASCADE_WIDTH_BASE) * t
            makePart({
                Name = "VolcanoCascadeSeg" .. i,
                Size = Vector3.new(segLen, 0.6, segWidth),
                CFrame = CFrame.new(mid) * CFrame.Angles(0, 0, slopeAngle),
                Material = Enum.Material.Neon,
                Color = SLIME_COLOR,
                Transparency = 0.15,
                CanCollide = false,
                Parent = volcanoFolder,
            })
        end

        -- Ground flow base PUSHED OUT past the cone footprint per
        -- Matthew 2026-04-27: "volcano still clipping the flow;
        -- the flow base needs to be moved out." First flow segment
        -- now starts at cascadeBase.X - 2 (2 studs west of the
        -- cone's western surface), so even with the segment-overlap
        -- factor extending its east edge slightly past groundStartX
        -- the slab still sits OUTSIDE the cone's bottom cylinder
        -- (radius BASE_R = 14 from cone center). The cascade-to-
        -- ground transition is bridged by the joint patch added
        -- below, which sits in the gap region (cone surface to
        -- 2 studs west) — fully on the floor, no cone clipping.
        local riverEastWorld = cellToWorld(riverCenterCol, 58)
        local groundStartX = cascadeBase.X - 2
        local groundEndX   = riverEastWorld.X - RIVER_HALF_WIDTH * 0.5
        local groundLen    = groundStartX - groundEndX  -- positive (flows west)
        local FLOW_WIDTH   = CASCADE_WIDTH_BASE + 0.4  -- slightly wider than cascade base
        if groundLen > 0 then
            -- Transition patch in the 2-stud gap between the cone
            -- surface (vX - BASE_R) and the flow's west-pushed
            -- start (groundStartX = vX - BASE_R - 2). Centered in
            -- the gap at vX - BASE_R - 1, span X = 2.6 (slight
            -- overlap with both the cascade base — whose slanted
            -- lower-west corner extends past the cone surface —
            -- and the first flow segment to the west). Stays
            -- entirely OUTSIDE the cone's bottom cylinder, no
            -- clipping.
            makePart({
                Name = "VolcanoFlowJoint",
                Size = Vector3.new(2.6, 0.6, FLOW_WIDTH + 0.3),
                CFrame = CFrame.new(
                    cascadeBase.X - 1,
                    floorTopY + 0.08,
                    volcanoBase.Z),
                Material = Enum.Material.Neon,
                Color = SLIME_COLOR,
                Transparency = 0.15,
                CanCollide = false,
                Parent = volcanoFolder,
            })

            local FLOW_SEGS = math.max(2, math.floor(groundLen / (CELL_SIZE * 2.5)))
            for i = 0, FLOW_SEGS - 1 do
                local t = (i + 0.5) / FLOW_SEGS
                local segLen = (groundLen / FLOW_SEGS) * 1.3  -- overlap
                local cx = groundStartX - groundLen * t
                local wobble = math.sin(t * math.pi * 2) * 0.9  -- gentler
                makePart({
                    Name = "VolcanoFlowSeg" .. i,
                    Size = Vector3.new(segLen, 0.6, FLOW_WIDTH),
                    CFrame = CFrame.new(cx, floorTopY + 0.08, volcanoBase.Z + wobble),
                    Material = Enum.Material.Neon,
                    Color = SLIME_COLOR,
                    Transparency = 0.15,
                    CanCollide = false,
                    Parent = volcanoFolder,
                })
            end
            -- Volcano flow banks REMOVED per Matthew 2026-04-26
            -- "ss3 is another shot of the disconnect between
            -- volcano pool and river" — the slate bank slabs along
            -- both sides of the flow read as a stair-stepped stone
            -- gap because the wobble made them shift across each
            -- segment. The flow itself reaches into the river
            -- footprint cleanly without the banks; cleaner without
            -- the framing slabs.
        end
        -- Smoke + sparks from the mouth.
        local smokeAttach = Instance.new("Attachment")
        smokeAttach.Position = Vector3.new(0, TIP_R, 0)
        smokeAttach.Parent = volcanoFolder:FindFirstChild("VolcanoMouth")
        local smoke = Instance.new("ParticleEmitter")
        smoke.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(160, 220, 130)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 100, 70)),
        })
        smoke.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1.2),
            NumberSequenceKeypoint.new(1, 4.5),
        })
        smoke.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.4),
            NumberSequenceKeypoint.new(1, 1),
        })
        smoke.Lifetime = NumberRange.new(2, 3.5)
        smoke.Rate = Config.Map4.Volcano.SmokeRate
        smoke.Speed = NumberRange.new(2, 4)
        smoke.SpreadAngle = Vector2.new(20, 20)
        smoke.LightEmission = 0.4
        smoke.Parent = smokeAttach
    end

    ------------------------------------------------------------
    -- STEAM CLOUDS — anchored translucent off-white-green spheres
    -- bobbing up/down via a single Heartbeat sine wave (cheap, no
    -- per-cloud TweenService traffic). Scattered across the map at
    -- low altitude (Y = 4-12 above floor).
    ------------------------------------------------------------
    do
        local steamFolder = Instance.new("Folder")
        steamFolder.Name = "Map4SteamClouds"
        steamFolder.Parent = map4Room
        local clouds = {}
        for i = 1, Config.Map4.SteamClouds.Count do
            -- Random position inside the arena, biased toward the
            -- river (steam rises off slime). Don't worry about path
            -- collision — clouds float well above the path.
            local cellCol = math.floor(MAP4_COL_OFFSET + 2 + rand(0, MAP4_TOTAL_COLS - MAP4_COL_OFFSET - 4))
            local cellRow = math.floor(2 + rand(0, MAP4_ROWS - 4))
            local pos = cellToWorld(cellCol, cellRow)
            local baseY = floorTopY + 5 + rand(0, 8)
            local size = 6 + rand(0, 5)
            local p = makePart({
                Name = "SteamCloud" .. i,
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(size, size * 0.7, size),
                CFrame = CFrame.new(pos.X, baseY, pos.Z),
                Material = Enum.Material.Neon,
                Color = Color3.fromRGB(220, 240, 220),
                Transparency = 0.78,
                CanCollide = false,
                Parent = steamFolder,
            })
            p.CastShadow = false
            table.insert(clouds, {
                part = p,
                baseY = baseY,
                phase = rand(0, math.pi * 2),
            })
        end
        -- Single Heartbeat tick drives all cloud bobs. ~36 sin calls
        -- per frame — negligible CPU.
        local bobAmp    = Config.Map4.SteamClouds.BobAmplitudeStud
        local bobPeriod = Config.Map4.SteamClouds.BobPeriodSec
        game:GetService("RunService").Heartbeat:Connect(function()
            local t = os.clock()
            for _, c in ipairs(clouds) do
                if c.part.Parent then
                    local y = c.baseY + math.sin(t * (math.pi * 2 / bobPeriod) + c.phase) * bobAmp
                    c.part.CFrame = CFrame.new(c.part.Position.X, y, c.part.Position.Z)
                end
            end
        end)
    end

    ------------------------------------------------------------
    -- PICKLE TREES — primary light source. Each tree = a tall
    -- trunk + a leafy canopy + N pickle-fruit Balls with PointLights
    -- inside them. Placed around the perimeter, avoiding the path.
    ------------------------------------------------------------
    do
        local treesFolder = Instance.new("Folder")
        treesFolder.Name = "Map4PickleTrees"
        treesFolder.Parent = map4Room

        -- Place trees at perimeter cells, evenly spaced by angle.
        local treeCount = Config.Map4.PickleTrees.Count
        local fruitsPerTree = Config.Map4.PickleTrees.FruitsPerTree
        local fruitLightRange = Config.Map4.PickleTrees.FruitLightRange
        for i = 1, treeCount do
            local angle = (i / treeCount) * math.pi * 2
            local rx = math.cos(angle) * (m4HalfW - 8)
            local rz = math.sin(angle) * (m4HalfD - 8)
            local trunkBaseX = m4c.X + rx
            local trunkBaseZ = m4c.Z + rz

            -- Skip if too close to a path waypoint (tree would block path).
            local skip = false
            for _, wp in ipairs(map4PathCells) do
                local wpW = cellToWorld(wp[1], wp[2])
                local dx = wpW.X - trunkBaseX
                local dz = wpW.Z - trunkBaseZ
                if dx * dx + dz * dz < 64 then
                    skip = true; break
                end
            end
            if skip then continue end

            local trunkHeight = 18 + rand(-2, 4)
            local trunk = makePart({
                Name = "PickleTreeTrunk" .. i,
                Size = Vector3.new(1.6, trunkHeight, 1.6),
                CFrame = CFrame.new(trunkBaseX, floorTopY + trunkHeight / 2, trunkBaseZ),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(70, 50, 35),
                Parent = treesFolder,
            })
            local _ = trunk

            -- Canopy — three overlapping spheres for a leafy clump.
            for cs = 0, 2 do
                local off = Vector3.new(
                    rand(-2, 2),
                    trunkHeight + 1 + cs * 1.4,
                    rand(-2, 2))
                makePart({
                    Name = "PickleTreeCanopy" .. i .. "_" .. cs,
                    Shape = Enum.PartType.Ball,
                    Size = Vector3.new(7 + rand(0, 2), 6, 7 + rand(0, 2)),
                    CFrame = CFrame.new(trunkBaseX + off.X, floorTopY + off.Y, trunkBaseZ + off.Z),
                    Material = Enum.Material.LeafyGrass,
                    Color = Color3.fromRGB(50, 95, 45),
                    Parent = treesFolder,
                })
            end

            -- Pickle fruit — small glowing green Balls with PointLights.
            for f = 1, fruitsPerTree do
                local fruitOff = Vector3.new(
                    rand(-3, 3),
                    trunkHeight + rand(-1, 3),
                    rand(-3, 3))
                local fruit = makePart({
                    Name = "PickleFruit" .. i .. "_" .. f,
                    Shape = Enum.PartType.Ball,
                    Size = Vector3.new(1.3, 1.6, 1.3),
                    CFrame = CFrame.new(
                        trunkBaseX + fruitOff.X,
                        floorTopY + fruitOff.Y,
                        trunkBaseZ + fruitOff.Z),
                    Material = Enum.Material.Neon,
                    Color = Color3.fromRGB(160, 240, 100),
                    Transparency = 0.05,
                    Parent = treesFolder,
                })
                local light = Instance.new("PointLight")
                light.Color = Color3.fromRGB(160, 240, 130)
                light.Brightness = 1.6
                light.Range = fruitLightRange
                light.Parent = fruit
            end
        end
    end

    ------------------------------------------------------------
    -- ENEMY PATH waypoints (tagged Parts the wave system reads).
    ------------------------------------------------------------
    local map4PathFolder = Instance.new("Folder")
    map4PathFolder.Name = "EnemyPath"
    map4PathFolder.Parent = map4Room
    map4PathFolder:SetAttribute("MapId", 4)
    for i, cell in ipairs(map4PathCells) do
        local worldPos = cellToWorld(cell[1], cell[2]) + Vector3.new(0, 1, 0)
        local part = makePart({
            Name = "Waypoint" .. i,
            Size = Vector3.new(2, 0.2, 2),
            CFrame = CFrame.new(worldPos),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(180, 240, 140),  -- swamp green path glow
            Transparency = 0.55,
            CanCollide = false,
            Parent = map4PathFolder,
        })
        part:SetAttribute("MapId", 4)
        CollectionService:AddTag(part, Tags.EnemyWaypoint)
    end

    ------------------------------------------------------------
    -- Visual path tiles — dirt-colored slate squares above floor
    -- so the path reads even in low light.
    ------------------------------------------------------------
    for c = MAP4_COL_OFFSET, MAP4_TOTAL_COLS - 1 do
        for r = 0, MAP4_ROWS - 1 do
            local s = gridState[c][r]
            if s == "path" or s == "heart" then
                local worldPos = cellToWorld(c, r)
                worldPos = Vector3.new(worldPos.X, floorTopY + 0.15, worldPos.Z)
                makePart({
                    Name = (s == "path") and "PathCell" or "HeartCell",
                    Size = Vector3.new(CELL_SIZE, 0.3, CELL_SIZE),
                    CFrame = CFrame.new(worldPos),
                    Material = Enum.Material.Slate,
                    Color = (s == "path") and Color3.fromRGB(95, 70, 50)
                                           or Color3.fromRGB(140, 110, 70),
                    CanCollide = false,
                    Parent = map4Room,
                })
            end
        end
    end

    ------------------------------------------------------------
    -- HEART — Tree-of-Life heart at the path end.
    ------------------------------------------------------------
    local m4HeartWorldPos = cellToWorld(m4HeartCell[1], m4HeartCell[2])
                          + Vector3.new(0, 4, 0)
    local map4Heart = makePart({
        Name = "TreeHeartMap4",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(14, 14, 14),
        CFrame = CFrame.new(m4HeartWorldPos),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(255, 220, 140),
        Transparency = 0.2,
        CanCollide = false,
        Parent = map4Room,
    })
    CollectionService:AddTag(map4Heart, Tags.EnemyEndPoint)
    map4Heart:SetAttribute("MapId", 4)
    local heartHp = Config.Map4.HeartMaxHp
    map4Heart:SetAttribute("MaxHealth", heartHp)
    map4Heart:SetAttribute("Health", heartHp)
    local heartLight = Instance.new("PointLight")
    heartLight.Color = Color3.fromRGB(255, 220, 140)
    heartLight.Brightness = 3
    heartLight.Range = 60
    heartLight.Parent = map4Heart

    -- HP billboard
    local m4HpAnchor = makePart({
        Name = "HeartHPAnchorMap4",
        Size = Vector3.new(1, 1, 1),
        CFrame = CFrame.new(m4HeartWorldPos + Vector3.new(0, 11, 0)),
        Transparency = 1,
        CanCollide = false,
        Parent = map4Room,
    })
    local m4HpBillboard = Instance.new("BillboardGui")
    m4HpBillboard.Size = UDim2.fromOffset(140, 28)
    m4HpBillboard.AlwaysOnTop = true
    m4HpBillboard.LightInfluence = 0
    m4HpBillboard.MaxDistance = 280
    m4HpBillboard.Parent = m4HpAnchor
    local m4HpBg = Instance.new("Frame")
    m4HpBg.Size = UDim2.fromScale(1, 1)
    m4HpBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    m4HpBg.BackgroundTransparency = 0.2
    m4HpBg.BorderSizePixel = 0
    m4HpBg.Parent = m4HpBillboard
    local m4HpFill = Instance.new("Frame")
    m4HpFill.Size = UDim2.new(1, -2, 1, -2)
    m4HpFill.Position = UDim2.fromOffset(1, 1)
    m4HpFill.BackgroundColor3 = Color3.fromRGB(255, 220, 140)
    m4HpFill.BorderSizePixel = 0
    m4HpFill.Parent = m4HpBg
    local m4HpText = Instance.new("TextLabel")
    m4HpText.Size = UDim2.fromScale(1, 1)
    m4HpText.BackgroundTransparency = 1
    m4HpText.Text = string.format("%d / %d", heartHp, heartHp)
    m4HpText.Font = Enum.Font.FredokaOne
    m4HpText.TextSize = 16
    m4HpText.TextColor3 = Color3.fromRGB(40, 30, 10)
    m4HpText.Parent = m4HpBillboard
    map4Heart:SetAttribute("HPFillSize", m4HpFill.Size)  -- snapshot for damage updater
    map4Heart:GetAttributeChangedSignal("Health"):Connect(function()
        local hp = map4Heart:GetAttribute("Health") or 0
        local max = map4Heart:GetAttribute("MaxHealth") or heartHp
        local frac = math.clamp(hp / max, 0, 1)
        m4HpFill.Size = UDim2.new(frac, -2, 1, -2)
        m4HpText.Text = string.format("%d / %d", math.max(0, math.floor(hp)), max)
    end)

    ------------------------------------------------------------
    -- ENEMY SPAWN at the start of the path.
    ------------------------------------------------------------
    local m4SpawnPos = cellToWorld(map4PathCells[1][1], map4PathCells[1][2])
                     + Vector3.new(0, 1, 0)
    local map4Spawn = makePart({
        Name = "EnemySpawnMap4",
        Size = Vector3.new(3, 0.3, 3),
        CFrame = CFrame.new(m4SpawnPos),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(120, 200, 100),
        Transparency = 0.5,
        CanCollide = false,
        Parent = map4Room,
    })
    map4Spawn:SetAttribute("MapId", 4)
    CollectionService:AddTag(map4Spawn, Tags.EnemySpawn)

    -- Suppress unused-import warning for TweenService — reserved for
    -- B2d follow-up (drifting steam clouds will likely use a global
    -- tween group instead of per-frame Heartbeat at scale).
    local _ = TweenService

    ------------------------------------------------------------
    -- GROUND-EFFECTS CULL ABOVE 20× — listen to the Workspace
    -- "InfiniteMathOnly" attribute (set by WaveSystem when on
    -- Map 4 with gameSpeed > 20). When true, hide the visual
    -- decoration folders (steam clouds, volcano, pickle trees);
    -- when false, restore. Path geometry (river, bridge) stays
    -- visible since players still navigate it. Per Matthew
    -- 2026-04-26: "remove ground effects above 20x".
    --
    -- Strategy: re-parent the decoration folder to a stash
    -- (workspace child or nil). Restoring re-parents back to
    -- map4Room. Cheap toggle, no per-part transparency math.
    ------------------------------------------------------------
    local cullStash = Instance.new("Folder")
    cullStash.Name = "Map4CullStash"
    cullStash.Parent = game:GetService("ServerStorage")
    local function findFolderByName(name)
        return map4Room:FindFirstChild(name) or cullStash:FindFirstChild(name)
    end
    -- Volcano stays visible at high speed (Matthew 2026-04-26:
    -- "what happened to the volcano?" — was hiding when speed >20×
    -- triggered the InfiniteMathOnly cull). It's a static cone so
    -- there's no per-frame animation cost; only the smoke emitter
    -- is animated, and that's a single ParticleEmitter — negligible
    -- vs the steam-cloud Heartbeat sine fan-out.
    local cullableNames = { "Map4SteamClouds", "Map4PickleTrees" }
    local function applyCull(hide)
        for _, name in ipairs(cullableNames) do
            local f = findFolderByName(name)
            if f then
                f.Parent = hide and cullStash or map4Room
            end
        end
    end
    Workspace:GetAttributeChangedSignal("InfiniteMathOnly"):Connect(function()
        applyCull(Workspace:GetAttribute("InfiniteMathOnly") == true)
    end)
    -- Apply current state on boot (handles late-binding edge case
    -- where speed was already > 20× before this listener attached).
    applyCull(Workspace:GetAttribute("InfiniteMathOnly") == true)

    ------------------------------------------------------------
    -- Publish ctx fields so the Infinite system + tower placement
    -- can find the heart, spawn position, and player CFrame.
    ------------------------------------------------------------
    ctx.map4Room              = map4Room
    ctx.map4Heart             = map4Heart
    ctx.MAP4_PLAYER_SPAWN_CF  = MAP4_PLAYER_SPAWN_CF

    print(("[Map4] Pickle Swamp built. Cols %d-%d, %d path waypoints, "
        .. "%d steam clouds, %d pickle trees"):format(
        MAP4_COL_OFFSET, MAP4_TOTAL_COLS - 1, #map4PathCells,
        Config.Map4.SteamClouds.Count, Config.Map4.PickleTrees.Count))
end

return Map4
