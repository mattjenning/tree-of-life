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
    -- ENEMY PATH waypoints — PHASE-AWARE per ea3-48.
    --
    -- Three path layouts (one per phase) defined in
    -- Config.Map4.PhasePaths. The active phase is read from
    -- Workspace.Map4ActivePhase (default 3 = full bounds for
    -- back-compat with FULL AUTO / TOWER SUPER paths). On phase
    -- change, the path is REBUILT: stale "path" cells revert to
    -- "open" + the new phase's path cells get marked.
    --
    -- Heart cell is FIXED at Config.Map4.HeartCell so the heart
    -- model doesn't move per phase. All phase paths end at this
    -- cell. Mobs may briefly walk through cells outside the active
    -- phase bounds on their way to the heart — that's OK because
    -- bounds enforcement only restricts TOWER PLACEMENT, not mob
    -- movement.
    ------------------------------------------------------------
    -- ea3-63: heart cell is PHASE-AWARE — each phase's heart matches
    -- the corresponding story-map heart cell (per Matthew "map 1
    -- infinite should match map 1 path... update heart health too").
    -- m4HeartCell is mutable; updated on phase change alongside the
    -- heart MODEL repositioning.
    local function heartCellForPhase(phase)
        local pc = Config.Map4.PhaseHeartCells and Config.Map4.PhaseHeartCells[phase]
        if pc then return { MAP4_COL_OFFSET + pc.col, pc.row } end
        return { MAP4_COL_OFFSET + Config.Map4.HeartCell.col, Config.Map4.HeartCell.row }
    end
    local m4HeartCell = heartCellForPhase(3)  -- placeholder until activePhase resolves below

    local function markPathRect(c1, r1, c2, r2)
        local cmin, cmax = math.min(c1, c2), math.max(c1, c2)
        local rmin, rmax = math.min(r1, r2), math.max(r1, r2)
        for c = cmin, cmax do
            for r = rmin, rmax do
                if c >= MAP4_COL_OFFSET and c < MAP4_TOTAL_COLS
                   and r >= 0 and r < MAP4_ROWS then
                    if gridState[c][r] ~= "heart" then
                        gridState[c][r] = "path"
                    end
                end
            end
        end
    end

    -- Reset every Map 4 cell that's currently "path" / "blocked"
    -- / "heart" back to "open". Called before re-marking the
    -- active phase's path / blocker / heart-exclusion zone so old
    -- phase-specific markings don't pile up.
    --
    -- ea3-72: "heart" cells added to the reset set per Matthew
    -- "make sure extra heart platforms are cleaned up". Each
    -- phase has its own heart cell + exclusion zone; before this
    -- fix, prior phases' "heart"-tagged cells stayed in gridState
    -- across phase changes (markPathRect skips heart cells, so
    -- they couldn't be overwritten). The visual path-tile rebuild
    -- then drew a HeartCell tile for EVERY "heart" cell across
    -- ALL prior phases — orphan wooden platforms appeared at
    -- phase 1's + phase 2's heart cells while the player was in
    -- phase 3. Now reset clears all three categories; markHeartCell
    -- runs immediately after to re-mark only the active phase's
    -- exclusion zone. River cells (persistent scenery) stay
    -- untouched.
    local function resetPathAndBlockerCells()
        for c = MAP4_COL_OFFSET, MAP4_TOTAL_COLS - 1 do
            for r = 0, MAP4_ROWS - 1 do
                local v = gridState[c][r]
                if v == "path" or v == "blocked" or v == "heart" then
                    gridState[c][r] = "open"
                end
            end
        end
    end

    -- Mark the heart cell + exclusion zone. Heart-marking is
    -- idempotent so repeated calls don't break.
    local function markHeartCell()
        for dc = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
            for dr = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
                local cc, rr = m4HeartCell[1] + dc, m4HeartCell[2] + dr
                if cc >= MAP4_COL_OFFSET and cc < MAP4_TOTAL_COLS
                   and rr >= 0 and rr < MAP4_ROWS then
                    gridState[cc][rr] = "heart"
                end
            end
        end
    end

    -- Build the active phase's path waypoints (with absolute cols).
    local function buildPhaseWaypointsAbs(phase)
        local localPath = Config.Map4.PhasePaths[phase] or Config.Map4.PhasePaths[3]
        local out = {}
        for _, wp in ipairs(localPath) do
            table.insert(out, { MAP4_COL_OFFSET + wp[1], wp[2] })
        end
        return out
    end

    -- Mark gridState cells as "path" along the active phase's
    -- waypoint sequence. Same logic as the old inline loop, just
    -- parameterized.
    local function markPathForPhase(phase)
        local pathCells = buildPhaseWaypointsAbs(phase)
        for i = 1, #pathCells - 1 do
            local a, b = pathCells[i], pathCells[i+1]
            if a[1] == b[1] then
                markPathRect(a[1] - pathHalf, math.min(a[2], b[2]) - pathHalf,
                             a[1] + pathHalf, math.max(a[2], b[2]) + pathHalf)
            else
                markPathRect(math.min(a[1], b[1]) - pathHalf, a[2] - pathHalf,
                             math.max(a[1], b[1]) + pathHalf, a[2] + pathHalf)
            end
        end
    end

    -- Mark the staircase blocker cells if the active phase matches.
    -- Uses gridState[c][r] = "blocked" — TowerPlacement.canPlaceAt
    -- treats this the same as a non-open cell (no placement).
    local function markStaircaseBlockerForPhase(phase)
        local sb = Config.Map4.StaircaseBlocker
        if not sb or sb.ActivePhase ~= phase then return end
        for c = MAP4_COL_OFFSET + sb.ColMin, MAP4_COL_OFFSET + sb.ColMax do
            for r = sb.RowMin, sb.RowMax do
                if c >= MAP4_COL_OFFSET and c < MAP4_TOTAL_COLS
                   and r >= 0 and r < MAP4_ROWS then
                    if gridState[c][r] == "open" then
                        gridState[c][r] = "blocked"
                    end
                end
            end
        end
    end

    -- Apply the active phase's grid state — the public entry point.
    -- Resets path/blocker cells to "open", re-marks the phase's
    -- path + blocker, re-marks the heart exclusion (idempotent).
    local function applyPhaseGrid(phase)
        resetPathAndBlockerCells()
        markPathForPhase(phase)
        markStaircaseBlockerForPhase(phase)
        markHeartCell()
    end

    -- Initial setup: read active phase from Workspace (default 3).
    local function activePhase(): number
        local p = Workspace:GetAttribute("Map4ActivePhase")
        if type(p) == "number" and Config.Map4.PhaseBounds[p] then
            return p
        end
        return 3  -- full bounds default for back-compat
    end
    applyPhaseGrid(activePhase())

    -- Back-compat alias: the rest of Map4.lua (steam clouds /
    -- pickle-tree placement / spawn-cf calc / mob-spawner config)
    -- references `map4PathCells` to read the path's start cell +
    -- waypoint count. Now sourced from the active phase's path
    -- so old code keeps working without per-call updates.
    -- Note: the alias snapshots the path at setup time. On phase
    -- change the GRID gets rebuilt via applyPhaseGrid; consumers
    -- of this alias don't typically care about phase 1 vs 3
    -- waypoints (steam-cloud spawn, etc. is decor placement that
    -- ignores path detail).
    local map4PathCells = buildPhaseWaypointsAbs(activePhase())

    -- Re-apply on phase change. The new sweep runner sets this
    -- attribute as it advances through phases 1 → 2 → 3 → 4.
    Workspace:GetAttributeChangedSignal("Map4ActivePhase"):Connect(function()
        -- ea3-63: refresh heart cell + grid markers for the active
        -- phase (matches story-map paths + heart positions).
        m4HeartCell = heartCellForPhase(activePhase())
        applyPhaseGrid(activePhase())
        -- Tower-placement clients should refresh — fire grid
        -- broadcast via ctx.broadcastGrid if available. Hub setup
        -- publishes that helper after Map4.setup runs, so we
        -- nil-check.
        if ctx.broadcastGrid then ctx.broadcastGrid() end
    end)

    ------------------------------------------------------------
    -- SLIME RIVER + BRIDGES + VOLCANO — ambient scenery for the
    -- live Pickle Swamp. ea3-68 restored these per Matthew "put the
    -- river bridge and volcano back but remove it when you rebuild
    -- for sims". Geometry is the pre-ea3-47 build verbatim. The
    -- arena sweep toggles them via Workspace.Map4ArenaSweepActive
    -- (set by ArenaSweepRunner.runOneCombo): when true, the three
    -- folders move into ServerStorage's Map4CullStash and river
    -- cells flip "river" → "open" so the autoplace strategy has
    -- the full inner arena to work with. When the sweep ends the
    -- folders + river cells restore.
    ------------------------------------------------------------
    local SLIME_COLOR    = Color3.fromRGB(80, 220, 80)
    local riverCenterCol = MAP4_COL_OFFSET + 60
    local RIVER_HALF_WIDTH = 5  -- studs (perpendicular to flow direction)
    local RIVER_ROW_MAX  = MAP4_ROWS - 1
    -- Track every (col,row) we mark "river" so we can flip them
    -- back to "open" during a sweep without overwriting "path" /
    -- "heart" / "blocked" cells set by applyPhaseGrid.
    local riverCells = {}
    do
        local RIVER_CELL_HALF = 2  -- cols 58-62
        for c = riverCenterCol - RIVER_CELL_HALF, riverCenterCol + RIVER_CELL_HALF do
            for r = 0, RIVER_ROW_MAX do
                if c >= MAP4_COL_OFFSET and c < MAP4_TOTAL_COLS then
                    if gridState[c] and gridState[c][r] == "open" then
                        gridState[c][r] = "river"
                        table.insert(riverCells, { c, r })
                    end
                end
            end
        end
    end
    do
        local riverFolder = Instance.new("Folder")
        riverFolder.Name = "Map4SlimeRiver"
        riverFolder.Parent = map4Room
        -- 22 overlapping segments traces the full-height river with
        -- a sinusoidal wobble; banks (raised slate slabs) on each
        -- side, with the east bank skipped around row 58 so the
        -- volcano flow corridor reads as continuous slime.
        local segCount = 22
        for i = 0, segCount - 1 do
            local t = i / (segCount - 1)
            local row = t * RIVER_ROW_MAX
            local wobble = math.sin(t * math.pi * 1.4) * 4
            local centerCellWorld = cellToWorld(
                math.floor(riverCenterCol + wobble / CELL_SIZE),
                math.floor(row))
            local seg = makePart({
                Name = "SlimeRiverSeg" .. i,
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
        for side = -1, 1, 2 do
            for i = 0, segCount - 1 do
                local t = i / (segCount - 1)
                local row = t * RIVER_ROW_MAX
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

    -- BRIDGE — single bridge over the river at the top east path
    -- crossing (col 60, row 8). Decorative; path cells stay walkable.
    do
        local bridgeFolder = Instance.new("Folder")
        bridgeFolder.Name = "Map4Bridges"
        bridgeFolder.Parent = map4Room
        local crossCenter = cellToWorld(riverCenterCol, 8)
        local crossX, crossZ = crossCenter.X, crossCenter.Z
        for plank = 0, 4 do
            makePart({
                Name = "BridgePlank_" .. plank,
                Size = Vector3.new(2.4, 0.4, RIVER_HALF_WIDTH * 2.4),
                CFrame = CFrame.new(crossX - 6 + plank * 3, floorTopY + 0.3, crossZ)
                    * CFrame.Angles(rand(-2, 2) * math.pi / 180, 0,
                                    rand(-3, 3) * math.pi / 180),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(95, 60, 35),
                Parent = bridgeFolder,
            })
        end
        for postSide = -1, 1, 2 do
            for _, zSide in ipairs({ -1, 1 }) do
                makePart({
                    Name = ("BridgePost_%d%s"):format(postSide, zSide < 0 and "" or "B"),
                    Size = Vector3.new(0.6, 4, 0.6),
                    CFrame = CFrame.new(
                        crossX + postSide * 7,
                        floorTopY + 2,
                        crossZ + zSide * RIVER_HALF_WIDTH * 1.1),
                    Material = Enum.Material.Wood,
                    Color = Color3.fromRGB(85, 55, 30),
                    Parent = bridgeFolder,
                })
            end
        end
    end

    -- MINI VOLCANO — stacked cylinder cone in the SE corner with a
    -- glowing slime mouth, neon cascade down the west face, and
    -- ground-flow strip into the river. Decorative; doesn't damage
    -- mobs or interact with placement.
    do
        local volcanoFolder = Instance.new("Folder")
        volcanoFolder.Name = "Map4Volcano"
        volcanoFolder.Parent = map4Room
        local volcanoBase = cellToWorld(MAP4_COL_OFFSET + 78, 58)
        local CONE_LAYERS = 8
        local BASE_R, TIP_R, CONE_H = 14, 3.2, 28
        for i = 0, CONE_LAYERS - 1 do
            local t = i / (CONE_LAYERS - 1)
            local r = BASE_R + (TIP_R - BASE_R) * t
            makePart({
                Name = "VolcanoLayer" .. i,
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(CONE_H / CONE_LAYERS + 0.05, r * 2, r * 2),
                CFrame = CFrame.new(
                    volcanoBase.X,
                    floorTopY + (i + 0.5) * (CONE_H / CONE_LAYERS),
                    volcanoBase.Z)
                    * CFrame.Angles(0, 0, math.rad(90)),
                Material = Enum.Material.Slate,
                Color = Color3.fromRGB(
                    math.floor(70 + t * 20),
                    math.floor(70 + t * 60),
                    math.floor(60 + t * 30)),
                Parent = volcanoFolder,
            })
        end
        makePart({
            Name = "VolcanoMouth",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.6, TIP_R * 2.1, TIP_R * 2.1),
            CFrame = CFrame.new(volcanoBase.X, floorTopY + CONE_H + 0.2, volcanoBase.Z)
                * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Neon,
            Color = SLIME_COLOR,
            Transparency = 0.05,
            Parent = volcanoFolder,
        })
        local mouthY = floorTopY + CONE_H + 0.1
        local cascadeTop  = Vector3.new(volcanoBase.X - TIP_R, mouthY, volcanoBase.Z)
        local CASCADE_LANDING_OFFSET = 3
        local cascadeBase = Vector3.new(
            volcanoBase.X - BASE_R - CASCADE_LANDING_OFFSET,
            floorTopY + 0.05, volcanoBase.Z)
        local cascadeVec = cascadeTop - cascadeBase
        local cascadeLen = cascadeVec.Magnitude
        local slopeAngle = math.atan2(cascadeVec.Y, cascadeVec.X)
        local CASCADE_SEGS = CONE_LAYERS
        local CASCADE_WIDTH_BASE = BASE_R * 0.43
        local CASCADE_WIDTH_TIP  = TIP_R  * 0.75
        for i = 0, CASCADE_SEGS - 1 do
            local t = (i + 0.5) / CASCADE_SEGS
            local mid = cascadeBase + cascadeVec * t
            local segLen = (cascadeLen / CASCADE_SEGS) * 1.25
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
        local riverEastWorld = cellToWorld(riverCenterCol, 58)
        local groundStartX = cascadeBase.X - 2
        local groundEndX   = riverEastWorld.X - RIVER_HALF_WIDTH * 0.5
        local groundLen    = groundStartX - groundEndX
        local FLOW_WIDTH   = CASCADE_WIDTH_BASE + 0.4
        if groundLen > 0 then
            makePart({
                Name = "VolcanoFlowJoint",
                Size = Vector3.new(2.6, 0.6, FLOW_WIDTH + 0.3),
                CFrame = CFrame.new(cascadeBase.X - 1, floorTopY + 0.08, volcanoBase.Z),
                Material = Enum.Material.Neon,
                Color = SLIME_COLOR,
                Transparency = 0.15,
                CanCollide = false,
                Parent = volcanoFolder,
            })
            local FLOW_SEGS = math.max(2, math.floor(groundLen / (CELL_SIZE * 2.5)))
            for i = 0, FLOW_SEGS - 1 do
                local t = (i + 0.5) / FLOW_SEGS
                local segLen = (groundLen / FLOW_SEGS) * 1.3
                local cx = groundStartX - groundLen * t
                local wobble = math.sin(t * math.pi * 2) * 0.9
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
        end
        local mouth = volcanoFolder:FindFirstChild("VolcanoMouth")
        if mouth then
            local smokeAttach = Instance.new("Attachment")
            smokeAttach.Position = Vector3.new(0, TIP_R, 0)
            smokeAttach.Parent = mouth
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
    -- ea3-50: phase-aware. rebuildEnemyPathFolder clears existing
    -- waypoint parts + recreates them for the active phase. Called
    -- on setup AND on Workspace.Map4ActivePhase change so mobs
    -- spawned after the phase swap walk the new path.
    ------------------------------------------------------------
    local map4PathFolder = Instance.new("Folder")
    map4PathFolder.Name = "EnemyPath"
    map4PathFolder.Parent = map4Room
    map4PathFolder:SetAttribute("MapId", 4)
    local function rebuildEnemyPathFolder(phase)
        for _, child in ipairs(map4PathFolder:GetChildren()) do
            child:Destroy()
        end
        local pathCells = buildPhaseWaypointsAbs(phase)
        for i, cell in ipairs(pathCells) do
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
    end
    rebuildEnemyPathFolder(activePhase())
    -- Subscribe to phase change to rebuild the waypoint parts. The
    -- gridState rebuild already wired below for the active phase
    -- (applyPhaseGrid + broadcastGrid); waypoint-part rebuild fires
    -- in the same handler so mobs use the new walkable path.
    Workspace:GetAttributeChangedSignal("Map4ActivePhase"):Connect(function()
        rebuildEnemyPathFolder(activePhase())
    end)

    ------------------------------------------------------------
    -- Visual path tiles — dirt-colored slate squares above floor
    -- so the path reads even in low light.
    -- ea3-53: rebuilt on phase change so visual path tiles match
    -- the active phase's path layout. Stored in a folder so the
    -- rebuild can wipe + recreate cleanly.
    ------------------------------------------------------------
    local pathTileFolder = Instance.new("Folder")
    pathTileFolder.Name = "Map4PathTiles"
    pathTileFolder.Parent = map4Room
    local function rebuildPathTiles()
        for _, child in ipairs(pathTileFolder:GetChildren()) do
            child:Destroy()
        end
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
                        Parent = pathTileFolder,
                    })
                end
            end
        end
    end
    rebuildPathTiles()
    Workspace:GetAttributeChangedSignal("Map4ActivePhase"):Connect(function()
        -- Slight defer so applyPhaseGrid (gridState rebuild) finishes
        -- before we re-read gridState for the visual tiles.
        task.defer(rebuildPathTiles)
    end)

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
    -- ENEMY SPAWN at the start of the path. ea3-53: position is
    -- PHASE-AWARE — moves to the active phase's waypoint[1] when
    -- Map4ActivePhase changes. Mobs spawn at this part's position
    -- (MobFactory reads spawnPart.Position), so without the move
    -- they'd spawn at phase 3's start regardless of active phase
    -- and walk weirdly across the map (Matthew 2026-04-29: "the
    -- pathing wasn't working").
    ------------------------------------------------------------
    local function spawnPosForPhase(phase)
        local pathCells = buildPhaseWaypointsAbs(phase)
        local first = pathCells[1] or { MAP4_COL_OFFSET, 0 }
        return cellToWorld(first[1], first[2]) + Vector3.new(0, 1, 0)
    end
    local m4SpawnPos = spawnPosForPhase(activePhase())
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
    -- Reposition on phase change. Existing rebuildEnemyPathFolder
    -- handler updates waypoint Parts; this matches the spawn part
    -- to the new phase's waypoint[1].
    Workspace:GetAttributeChangedSignal("Map4ActivePhase"):Connect(function()
        map4Spawn.CFrame = CFrame.new(spawnPosForPhase(activePhase()))
    end)

    -- ea3-63: heart MODEL repositions + HP swap on phase change.
    -- Per Matthew "map 1 infinite should match map 1 path. map 2
    -- is map 2 path... update heart health too to match in
    -- infinite". Each phase's heart matches its story-map heart
    -- cell + HP (PhaseHeartCells / PhaseHeartHp in Config.Map4).
    Workspace:GetAttributeChangedSignal("Map4ActivePhase"):Connect(function()
        local phase = activePhase()
        local newHeartCell = heartCellForPhase(phase)
        local newWorldPos = cellToWorld(newHeartCell[1], newHeartCell[2])
                          + Vector3.new(0, 4, 0)
        map4Heart.CFrame = CFrame.new(newWorldPos)
        m4HpAnchor.CFrame = CFrame.new(newWorldPos + Vector3.new(0, 11, 0))
        local phaseHp = Config.Map4.PhaseHeartHp
                        and Config.Map4.PhaseHeartHp[phase]
                        or Config.Map4.HeartMaxHp
        map4Heart:SetAttribute("MaxHealth", phaseHp)
        map4Heart:SetAttribute("Health", phaseHp)
        print(("[Map4] phase %d → heart cell (%d,%d), HP %d"):format(
            phase, newHeartCell[1], newHeartCell[2], phaseHp))
    end)

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
    -- ARENA SWEEP SCENERY TOGGLE (ea3-68)
    -- ArenaSweepRunner sets Workspace.Map4ArenaSweepActive=true at
    -- sweep start, false at sweep end. While active:
    --   • Map4SlimeRiver / Map4Bridges / Map4Volcano fold into
    --     ServerStorage's Map4CullStash (visually hidden, no part
    --     load on the analyst's screen).
    --   • River cells flip "river" → "open" so the sweep autoplace
    --     strategy + canPlaceAt logic see the full inner arena
    --     without river bands carving out cols 58-62.
    -- On sweep end the folders restore + river cells flip back —
    -- but the flip-back is conditional: only "open" cells become
    -- "river" again (a phase-active path or heart-exclusion cell
    -- stays as the phase grid set it). riverCells was captured at
    -- river build time so cells the river NEVER touched (path
    -- crossings, etc.) aren't accidentally turned into river.
    ------------------------------------------------------------
    local sceneryFolders = { "Map4SlimeRiver", "Map4Bridges", "Map4Volcano" }
    local function applyArenaSweepCull(hide)
        for _, name in ipairs(sceneryFolders) do
            local f = findFolderByName(name)
            if f then
                f.Parent = hide and cullStash or map4Room
            end
        end
        -- River-cell grid toggle. Skip cells that have since become
        -- "path" / "heart" / "blocked" via applyPhaseGrid — those
        -- are owned by the phase grid, not the river.
        for _, cr in ipairs(riverCells) do
            local c, r = cr[1], cr[2]
            if gridState[c] then
                local v = gridState[c][r]
                if hide and v == "river" then
                    gridState[c][r] = "open"
                elseif (not hide) and v == "open" then
                    gridState[c][r] = "river"
                end
            end
        end
        if ctx.broadcastGrid then ctx.broadcastGrid() end
    end
    Workspace:GetAttributeChangedSignal("Map4ArenaSweepActive"):Connect(function()
        applyArenaSweepCull(Workspace:GetAttribute("Map4ArenaSweepActive") == true)
    end)
    -- Apply current state on boot (so a server-restart mid-sweep
    -- restores the right scenery state immediately rather than
    -- waiting for the next attribute change).
    applyArenaSweepCull(Workspace:GetAttribute("Map4ArenaSweepActive") == true)

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
