--[[
    Map3.lua — Map 3 ("Canopy / Nest") construction.

    Design intent (Matthew, 2026-04-24):
      - 20% bigger than map 2 (range upgrades by stage 3 demand more space).
      - Outer walls = giant gnarled branches (woven, organic — not flat slabs).
      - Branches sprout SMALLER branches with leaves (these grow between stages).
      - Open feel: wide central area, sparse path, no claustrophobic structure.
      - Nest-like: large eggs in one corner, twig nest cushion around them.
      - Per-stage progression (Map3StageVisuals.lua):
          stage 1: small branches half-size, no flowers, no butterflies
          stage 2: small branches 75%, few flowers, 1-2 butterflies
          stage 3: full size, many flowers, several butterflies
          stage 4 (boss): everything at peak, maybe color pulse

    Mirrors Map2.lua's setup(ctx) shape:
      Reads:  MAP3_CENTER, MAP3_WIDTH, MAP3_DEPTH, MAP3_HEIGHT,
              CELL_SIZE, MAP3_COL_OFFSET, MAP3_TOTAL_COLS, MAP3_ROWS,
              MAP3_COLS, HEART_EXCLUSION_CELLS, makePart, rand,
              cellToWorld, gridState, pathHalf, fireLeafMessage, Map3Stage
      Publishes:
              ctx.map3Room
              ctx.map3Heart
              ctx.MAP3_PLAYER_SPAWN_CF
              ctx.MAP3_AMMO_SW_POS
              ctx.MAP3_AMMO_SE_POS
              ctx.Map3Stage  (populated in-place: smallBranches, flowers,
                              butterflies, baseSpawnPositions, etc.)
]]

local Workspace         = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Tags    = require(Shared:WaitForChild("Tags"))
local Config  = require(Shared:WaitForChild("Config"))

local Map3 = {}

function Map3.setup(ctx)
    local MAP3_CENTER     = ctx.MAP3_CENTER
    local MAP3_WIDTH      = ctx.MAP3_WIDTH
    local MAP3_DEPTH      = ctx.MAP3_DEPTH
    local MAP3_HEIGHT     = ctx.MAP3_HEIGHT
    local TD_WALL_THICK   = ctx.TD_WALL_THICK
    local CELL_SIZE       = ctx.CELL_SIZE
    local MAP3_COL_OFFSET = ctx.MAP3_COL_OFFSET
    local MAP3_TOTAL_COLS = ctx.MAP3_TOTAL_COLS
    local MAP3_ROWS       = ctx.MAP3_ROWS
    local MAP3_COLS       = ctx.MAP3_COLS
    local HEART_EXCLUSION_CELLS = ctx.HEART_EXCLUSION_CELLS

    local makePart = ctx.makePart
    local rand     = ctx.rand

    local cellToWorld = ctx.cellToWorld
    local gridState   = ctx.gridState
    local pathHalf    = ctx.pathHalf

    local Map3Stage = ctx.Map3Stage

    local m3c = MAP3_CENTER
    local m3HalfW = MAP3_WIDTH / 2
    local m3HalfD = MAP3_DEPTH / 2

    local map3Room = Instance.new("Model")
    map3Room.Name = "TreeOfLifeMap3Room"
    map3Room.Parent = Workspace

    -- Player spawn — south-center of the map, facing the heart (NE corner).
    local MAP3_PLAYER_SPAWN_POS = Vector3.new(
        m3c.X,
        m3c.Y + 1,
        m3c.Z + m3HalfD - 6 * CELL_SIZE   -- 6 cells north of south wall
    )
    -- Look toward map center (and the path/heart beyond it).
    local MAP3_PLAYER_SPAWN_CF = CFrame.lookAt(
        MAP3_PLAYER_SPAWN_POS,
        Vector3.new(m3c.X, m3c.Y + 1, m3c.Z)
    )

    ------------------------------------------------------------
    -- FLOOR — warm wood, slightly more golden than map 2
    ------------------------------------------------------------
    makePart({
        Name = "Map3Floor",
        Size = Vector3.new(MAP3_WIDTH, 2, MAP3_DEPTH),
        CFrame = CFrame.new(m3c),
        Material = Enum.Material.WoodPlanks,
        Color = Color3.fromRGB(165, 130, 80),  -- sun-bleached warm wood
        Parent = map3Room,
    })

    ------------------------------------------------------------
    -- INVISIBLE WALL BARRIERS — keep mobs/players inside the arena.
    -- Cosmetic gnarled branches go ON TOP of these. Using a transparent
    -- thin slab keeps the perimeter sealed even when the visual branches
    -- are porous.
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
            Parent = map3Room,
        })
        p.CastShadow = false
        return p
    end
    invisWall("Map3InvisWallW",
        Vector3.new(INVIS_THICK, MAP3_HEIGHT, MAP3_DEPTH + INVIS_THICK * 2),
        CFrame.new(m3c + Vector3.new(-m3HalfW - INVIS_THICK/2, MAP3_HEIGHT/2, 0)))
    invisWall("Map3InvisWallE",
        Vector3.new(INVIS_THICK, MAP3_HEIGHT, MAP3_DEPTH + INVIS_THICK * 2),
        CFrame.new(m3c + Vector3.new(m3HalfW + INVIS_THICK/2, MAP3_HEIGHT/2, 0)))
    invisWall("Map3InvisWallN",
        Vector3.new(MAP3_WIDTH, MAP3_HEIGHT, INVIS_THICK),
        CFrame.new(m3c + Vector3.new(0, MAP3_HEIGHT/2, -m3HalfD - INVIS_THICK/2)))
    invisWall("Map3InvisWallS",
        Vector3.new(MAP3_WIDTH, MAP3_HEIGHT, INVIS_THICK),
        CFrame.new(m3c + Vector3.new(0, MAP3_HEIGHT/2, m3HalfD + INVIS_THICK/2)))

    ------------------------------------------------------------
    -- ENEMY PATH — declared early so the gnarled-branch wall builder
    -- can avoid growing into path cells (per the user's "branches
    -- shouldn't fall into the path" feedback). Visual path tiles +
    -- heart geometry are drawn LATER (further down) — only the grid-
    -- state marking happens here.
    ------------------------------------------------------------
    -- S-shape path along the room edges. Egg nest sits in NE corner
    -- (cols ~80-87 rows ~1-12); east leg stops at col 73 to clear it.
    local map3PathCells = {
        {MAP3_COL_OFFSET +  5,  7},
        {MAP3_COL_OFFSET + 73,  7},
        {MAP3_COL_OFFSET + 73, 22},
        {MAP3_COL_OFFSET + 22, 22},
        {MAP3_COL_OFFSET + 22, 32},
        {MAP3_COL_OFFSET + 55, 32},
        {MAP3_COL_OFFSET + 55, 47},
        {MAP3_COL_OFFSET +  5, 47},
        {MAP3_COL_OFFSET +  5, 60},
        {MAP3_COL_OFFSET + 84, 60},
    }
    local function markPathRectMap3(c1, r1, c2, r2)
        local cmin, cmax = math.min(c1, c2), math.max(c1, c2)
        local rmin, rmax = math.min(r1, r2), math.max(r1, r2)
        for c = cmin, cmax do
            for r = rmin, rmax do
                if c >= MAP3_COL_OFFSET and c < MAP3_TOTAL_COLS
                   and r >= 0 and r < MAP3_ROWS then
                    gridState[c][r] = "path"
                end
            end
        end
    end
    for i = 1, #map3PathCells - 1 do
        local a, b = map3PathCells[i], map3PathCells[i+1]
        if a[1] == b[1] then
            markPathRectMap3(a[1] - pathHalf, math.min(a[2], b[2]) - pathHalf,
                             a[1] + pathHalf, math.max(a[2], b[2]) + pathHalf)
        else
            markPathRectMap3(math.min(a[1], b[1]) - pathHalf, a[2] - pathHalf,
                             math.max(a[1], b[1]) + pathHalf, a[2] + pathHalf)
        end
    end
    local m3HeartCell = map3PathCells[#map3PathCells]
    for dc = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
        for dr = -HEART_EXCLUSION_CELLS, HEART_EXCLUSION_CELLS do
            local cc, rr = m3HeartCell[1] + dc, m3HeartCell[2] + dr
            if cc >= MAP3_COL_OFFSET and cc < MAP3_TOTAL_COLS
               and rr >= 0 and rr < MAP3_ROWS then
                if gridState[cc][rr] == "open" then
                    gridState[cc][rr] = "heart"
                end
            end
        end
    end

    -- Path-cell check used by the branch builders below. Returns true if a
    -- world position's (col, row) lands in a path or heart cell — at any Y.
    -- The perimeter weaver below uses this to clamp branches back to the
    -- wall plane wherever the path runs close, so the branch stays
    -- continuous (hugs the wall) rather than dipping into the corridor.
    local function inPathOrHeartCell(worldPos)
        local localX = worldPos.X - (m3c.X - m3HalfW)
        local localZ = worldPos.Z - (m3c.Z - m3HalfD)
        local localCol = math.floor(localX / CELL_SIZE)
        local row = math.floor(localZ / CELL_SIZE)
        if localCol < 0 or localCol >= MAP3_COLS or row < 0 or row >= MAP3_ROWS then
            return false
        end
        local s = gridState[MAP3_COL_OFFSET + localCol][row]
        return s == "path" or s == "heart"
    end

    ------------------------------------------------------------
    -- GNARLED BRANCH WALLS — three continuous perimeter branches
    --
    -- Per Matthew's 2026-04-24 design: THREE long continuous branches
    -- loop the entire room perimeter, weaving in and out of each other.
    -- Each branch's Y and depth-from-wall oscillate via sine waves with a
    -- different phase offset, so where branch A is high, B is mid and
    -- C is low; where A is close to the wall, another is further inward.
    --
    -- The weaver clamps depth-from-wall to a small range (≤4 studs) and
    -- skips inward push when a sample lands on a path/heart cell — this
    -- keeps the branches hugging the wall along the path corridors so they
    -- never block mob movement, but elsewhere they bulge inward to weave
    -- around each other.
    --
    -- Offshoot branches sprout from a subset of waypoints using the
    -- existing buildOrganicBranch (recursive bent-segment builder).
    ------------------------------------------------------------
    -- Single bark color — the wood material's texture provides variation
    -- already; the earlier light/mid/dark cycle read as patchy.
    local BARK_COLOR = Color3.fromRGB(120, 105, 85)

    local mainBranches = {}

    -- Drop a SPHERE at a segment joint so consecutive cylinders that bend
    -- visibly fuse instead of showing a flat-cap gap.
    local function buildJoint(pos, radius)
        makePart({
            Name = "Map3BranchJoint",
            Size = Vector3.new(radius * 2.05, radius * 2.05, radius * 2.05),
            CFrame = CFrame.new(pos),
            Material = Enum.Material.Wood,
            Color = BARK_COLOR,
            Shape = Enum.PartType.Ball,
            CanCollide = true,  -- block players from running through walls
            Parent = map3Room,
        })
    end

    -- Recursively build one organic branch as a polyline of bent cylinder
    -- segments, with random forks. side/axisAlong are recorded onto every
    -- segment so the small-branch decorator can pick them as sprout anchors.
    local function buildOrganicBranch(startPos, dir, length, radius, depth, side, axisAlong)
        local segCount = math.max(3, math.floor(length / 4.5))
        local segLen = length / segCount
        local pos = startPos
        local curDir = dir.Unit
        local segRadius = radius
        -- Joint at the very start of the branch (covers the fork-anchor
        -- attachment so it reads as a node not a stump).
        buildJoint(startPos, segRadius)
        local thisChainLastIdx = nil  -- track last segment of THIS chain for stub detection
        local thisChainTipPos = startPos
        for s = 1, segCount do
            local nextPos = pos + curDir * segLen
            -- Stop growing if this segment would land in a path or heart
            -- cell. Branches need to leave the path corridor clear for mobs.
            if inPathOrHeartCell(nextPos) then
                break
            end
            local mid = (pos + nextPos) / 2
            local segPart = makePart({
                Name = "Map3OrganicBranch",
                -- Slightly longer than segLen so the cylinder ends overlap
                -- the joint balls — no visible seam at any angle.
                Size = Vector3.new(segLen + 0.8, segRadius * 2, segRadius * 2),
                CFrame = CFrame.lookAt(mid, mid + curDir) * CFrame.Angles(0, math.rad(90), 0),
                Material = Enum.Material.Wood,
                Color = BARK_COLOR,
                Shape = Enum.PartType.Cylinder,
                CanCollide = true,  -- block players from running through walls
                Parent = map3Room,
            })
            table.insert(mainBranches, {
                part = segPart,
                side = side,
                center = mid,
                radius = segRadius,
                axisAlong = axisAlong,
                kind = "offshoot",
                tipPos = nextPos,  -- world position of this segment's far end
            })
            thisChainLastIdx = #mainBranches
            thisChainTipPos = nextPos
            -- Joint ball at the segment endpoint — fills the bend and lets
            -- the next segment connect smoothly.
            buildJoint(nextPos, segRadius)
            -- Fork? Bigger angle deviation than the in-segment bend. Skip the
            -- very first segment so forks don't crowd the base anchor.
            if depth > 0 and s >= 2 and math.random() < 0.5 then
                -- Random axis (3D) to rotate the direction around.
                local axis = Vector3.new(rand(-1, 1), rand(-1, 1), rand(-1, 1))
                if axis.Magnitude < 0.001 then axis = Vector3.new(0, 1, 0) end
                axis = axis.Unit
                local angle = math.rad(rand(35, 75))
                local forkDir = CFrame.fromAxisAngle(axis, angle):VectorToWorldSpace(curDir)
                buildOrganicBranch(nextPos, forkDir,
                    length * rand(0.40, 0.65),
                    segRadius * rand(0.55, 0.75),
                    depth - 1,
                    side, axisAlong)
            end
            -- Bend between segments (small random rotation around a random axis).
            local bendAxis = Vector3.new(rand(-1, 1), rand(-1, 1), rand(-1, 1))
            if bendAxis.Magnitude < 0.001 then bendAxis = Vector3.new(0, 1, 0) end
            bendAxis = bendAxis.Unit
            local bendAngle = math.rad(rand(-22, 22))
            curDir = CFrame.fromAxisAngle(bendAxis, bendAngle):VectorToWorldSpace(curDir).Unit
            -- Taper toward the tip
            segRadius = segRadius * 0.93
            pos = nextPos
        end
        -- Mark the final segment of THIS chain as a terminal stub so the
        -- leaf decorator always anchors a leaf cluster on it. Forks have
        -- their own recursive call which handles their own termini.
        if thisChainLastIdx then
            mainBranches[thisChainLastIdx].isTerminal = true
            mainBranches[thisChainLastIdx].terminalTipPos = thisChainTipPos
        end
    end

    -- Generate perimeter waypoints in COUNTERCLOCKWISE order — N→E→S→W
    -- back to start, each side gets points spaced ~3 studs apart along
    -- its length. Each waypoint records the wall-plane position (X, Z),
    -- the inward direction (toward room center), and which side it's on.
    local perimWaypoints = {}
    local function emitSideWaypoints(fromX, fromZ, toX, toZ, alongAxis, side, inwardX, inwardZ)
        local dx, dz = toX - fromX, toZ - fromZ
        local sideLen = math.sqrt(dx * dx + dz * dz)
        local count = math.max(2, math.floor(sideLen / 3))
        for i = 1, count do
            local t = (i - 0.5) / count
            table.insert(perimWaypoints, {
                wallX = fromX + dx * t,
                wallZ = fromZ + dz * t,
                inwardX = inwardX,
                inwardZ = inwardZ,
                alongAxis = alongAxis,
                side = side,
            })
        end
    end
    -- N wall: -X to +X along Z = -halfD; inward = +Z
    emitSideWaypoints(-m3HalfW, -m3HalfD,  m3HalfW, -m3HalfD, "X", "N",  0,  1)
    -- E wall: -Z to +Z along X = +halfW; inward = -X
    emitSideWaypoints( m3HalfW, -m3HalfD,  m3HalfW,  m3HalfD, "Z", "E", -1,  0)
    -- S wall: +X to -X along Z = +halfD; inward = -Z
    emitSideWaypoints( m3HalfW,  m3HalfD, -m3HalfW,  m3HalfD, "X", "S",  0, -1)
    -- W wall: +Z to -Z along X = -halfW; inward = +X
    emitSideWaypoints(-m3HalfW,  m3HalfD, -m3HalfW, -m3HalfD, "Z", "W",  1,  0)

    local NUM_WAYPOINTS = #perimWaypoints
    -- One full lap = 2π in the sine wave.
    local TAU = math.pi * 2
    -- Each branch's Y and depth-from-wall undulates per sine. Phases offset
    -- so the three branches weave at different points around the loop.
    local BRANCH_PHASES = { 0, TAU / 3, 2 * TAU / 3 }
    local BRANCH_RADII  = { 3.4, 2.9, 2.6 }
    local Y_BASELINE    = 12     -- center of Y oscillation
    local Y_AMPLITUDE   = 9      -- ± from baseline (Y range 3..21)
    local Y_FREQ        = 2.0    -- 2 wavelengths per loop → undulation
    local DEPTH_BASE    = 2.0    -- center of depth-from-wall oscillation
    local DEPTH_AMP     = 1.8    -- ± from base (depth range 0.2..3.8 studs)
    local DEPTH_FREQ    = 3.0    -- 3 wavelengths per loop → more frequent in/out

    -- Compute a branch's position at waypoint index i, branch index b.
    -- Returns world Vector3.
    -- If the chosen position would land in a path/heart cell, clamp depth
    -- back toward the wall (zero inward push) so the branch hugs the wall
    -- along path corridors.
    local function branchSamplePos(i, branchIdx)
        local wp = perimWaypoints[i]
        local t = (i - 1) / NUM_WAYPOINTS * TAU
        local phase = BRANCH_PHASES[branchIdx]
        local y = Y_BASELINE + Y_AMPLITUDE * math.sin(t * Y_FREQ + phase)
        local depth = DEPTH_BASE + DEPTH_AMP * math.cos(t * DEPTH_FREQ + phase * 1.3)
        if depth < 0.2 then depth = 0.2 end
        local pos = m3c + Vector3.new(
            wp.wallX + wp.inwardX * depth,
            y,
            wp.wallZ + wp.inwardZ * depth
        )
        -- Path-corridor clamp: if this depth pushes into a path cell, pull
        -- back to the wall plane (depth = 0.2). Branch stays continuous.
        if inPathOrHeartCell(pos) then
            pos = m3c + Vector3.new(
                wp.wallX + wp.inwardX * 0.2,
                y,
                wp.wallZ + wp.inwardZ * 0.2
            )
        end
        return pos
    end

    -- Build one continuous loop branch. Walks the perimeter waypoints,
    -- placing a joint ball at each sampled position and connecting them
    -- with cylinder segments. Closes the loop by connecting the last
    -- waypoint back to the first.
    local function buildLoopBranch(branchIdx)
        local radius = BRANCH_RADII[branchIdx]
        local prevPos = branchSamplePos(NUM_WAYPOINTS, branchIdx)  -- wrap-around start
        buildJoint(prevPos, radius)
        for i = 1, NUM_WAYPOINTS do
            local nextPos = branchSamplePos(i, branchIdx)
            local mid = (prevPos + nextPos) / 2
            local delta = nextPos - prevPos
            local len = delta.Magnitude
            if len > 0.01 then
                local lookDir = delta.Unit
                local segPart = makePart({
                    Name = "Map3LoopBranch",
                    -- Slightly longer than len so the cylinder ends overlap
                    -- the joint balls — no visible seam at any angle.
                    Size = Vector3.new(len + 0.6, radius * 2, radius * 2),
                    CFrame = CFrame.lookAt(mid, mid + lookDir) * CFrame.Angles(0, math.rad(90), 0),
                    Material = Enum.Material.Wood,
                    Color = BARK_COLOR,
                    Shape = Enum.PartType.Cylinder,
                    CanCollide = true,
                    Parent = map3Room,
                })
                -- Record for the small-branch decorator.
                table.insert(mainBranches, {
                    part = segPart,
                    side = perimWaypoints[i].side,
                    center = mid,
                    radius = radius,
                    axisAlong = perimWaypoints[i].alongAxis,
                    kind = "loop",
                })
            end
            buildJoint(nextPos, radius)
            prevPos = nextPos
        end
    end

    for b = 1, 3 do buildLoopBranch(b) end

    -- Offshoot branches: sprout shorter recursive branches from a subset
    -- of waypoints (every 3rd, randomly chosen of the 3 loop branches).
    -- Each grows in a random inward/upward direction. The buildOrganicBranch
    -- path-cell check still applies so offshoots stop short of the path
    -- corridor. Higher density per Matthew's "more forks with leaves +
    -- buds" feedback — small-branch sprouts hang off these too.
    for i = 1, NUM_WAYPOINTS, 3 do
        local branchIdx = math.random(1, 3)
        local startPos = branchSamplePos(i, branchIdx)
        local wp = perimWaypoints[i]
        local inwardVec = Vector3.new(wp.inwardX, 0, wp.inwardZ)
        local upVec = Vector3.new(0, 1, 0)
        local randTilt = Vector3.new(rand(-0.3, 0.3), 0, rand(-0.3, 0.3))
        local dir = (inwardVec * rand(0.3, 0.7)
                   + upVec * rand(0.2, 0.7)
                   + randTilt).Unit
        buildOrganicBranch(startPos, dir,
            rand(10, 20),
            rand(1.4, 2.2),
            2,  -- depth — allow one level of fork on each offshoot
            wp.side, wp.alongAxis)
    end

    ------------------------------------------------------------
    -- SMALL BRANCHES + LEAVES
    --
    -- From a subset of the main gnarled-branch slices, sprout SMALL
    -- branches inward toward the room center. Each small branch has
    -- 1-3 leaf clusters at its tip. These are the elements that GROW
    -- between stages (Map3StageVisuals scales them up).
    --
    -- Each entry in Map3Stage.smallBranches:
    --   { part, baseSize, baseLength, leafParts, baseLeafSize, unlockStage }
    -- unlockStage controls when the branch becomes visible:
    --   stage 1: branches with unlockStage==1 (subset, ~30%) at 50% scale
    --   stage 2: stage 1 set at 75% + stage-2 set added
    --   stage 3+: all branches at 100% scale + leaves vibrant
    ------------------------------------------------------------
    local LEAF_COLOR_LIGHT = Color3.fromRGB(140, 200, 90)
    local LEAF_COLOR_DARK  = Color3.fromRGB(80, 150, 70)
    local SMALL_BRANCH_COLOR = Color3.fromRGB(110, 80, 50)

    local function sproutSmallBranch(slice, unlockStage)
        -- ONLY for terminal offshoot stubs — places a leaf clump directly
        -- on the cap. No protruding small-branch cylinder; the cluster
        -- IS the foliage. Sized to cover the cap (slice.radius × 3.5+).
        if not (slice.isTerminal and slice.terminalTipPos) then return end
        local startPos = slice.terminalTipPos
        local sproutLen = 0.4   -- placeholder length (cylinder hidden inside cap)
        local sproutRadius = 0.2
        local sproutDir = Vector3.new(0, 1, 0)
        local tip = startPos
        -- Tiny invisible placeholder cylinder — needed because the per-stage
        -- scaler indexes entry.part. Hidden inside the cap's joint ball.
        local part = makePart({
            Name = "Map3LeafStub",
            Size = Vector3.new(sproutLen, sproutRadius * 2, sproutRadius * 2),
            CFrame = CFrame.new(startPos),
            Material = Enum.Material.Wood,
            Color = BARK_COLOR,
            Shape = Enum.PartType.Cylinder,
            CanCollide = false,
            Transparency = 1,
            Parent = map3Room,
        })
        -- Leaf clump sized to cover the cap. baseLeafSize floor scales with
        -- slice.radius so even big caps are fully covered at stage 1 (where
        -- LEAF_SCALE_BY_STEP[1] = 0.55, effective ≈ slice.radius × 1.9).
        local leafCount = math.random(2, 4)
        local leafParts = {}
        -- Bigger leaves so the cap can't peek through. Min size scales with
        -- cap radius so even fat caps are fully covered at step-1 scale.
        local baseLeafSize = math.max(slice.radius * 5.5, rand(3.2, 4.2))
        for i = 1, leafCount do
            -- First leaf is centered ON the cap (no offset) for guaranteed
            -- coverage; subsequent leaves cluster tightly around it.
            local leafOffset
            if i == 1 then
                leafOffset = Vector3.new(0, 0, 0)
            else
                leafOffset = Vector3.new(
                    rand(-0.3, 0.3),
                    rand(-0.15, 0.15),
                    rand(-0.3, 0.3)
                )
            end
            local leafColor = (i % 2 == 0) and LEAF_COLOR_LIGHT or LEAF_COLOR_DARK
            local leaf = makePart({
                Name = "Map3Leaf",
                Size = Vector3.new(baseLeafSize, baseLeafSize * 0.85, baseLeafSize),
                CFrame = CFrame.new(tip + leafOffset)
                       * CFrame.Angles(rand(-0.5, 0.5), rand(0, 6.28), rand(-0.5, 0.5)),
                Material = Enum.Material.LeafyGrass,
                Color = leafColor,
                Shape = Enum.PartType.Ball,
                CanCollide = false,
                Parent = map3Room,
            })
            leaf.CastShadow = false
            table.insert(leafParts, leaf)
        end
        table.insert(Map3Stage.smallBranches, {
            part = part,
            baseLength = sproutLen,
            baseRadius = sproutRadius,
            startPos = startPos,
            sproutDir = sproutDir,
            leafParts = leafParts,
            baseLeafSize = baseLeafSize,
            tipPos = tip,
            unlockStage = unlockStage,
        })
    end

    -- A "popped-out" small branch growing from a terminal cap: a real
    -- protruding cylinder with its own leaf cluster at the tip. Used for
    -- stage-3 growth — at stage 3, every stage-1 terminal pops a new
    -- branch out of itself (per Matthew's "clusters pop out on a new
    -- branch" feedback).
    local function sproutPoppedBranch(slice, unlockStage)
        local sproutLen = rand(3, 7)
        local sproutRadius = rand(0.3, 0.5)
        local startPos
        if slice.isTerminal and slice.terminalTipPos then
            startPos = slice.terminalTipPos
        elseif slice.center then
            startPos = slice.center
        else
            return
        end
        -- Direction: outward + upward bias
        local outward = Vector3.new(rand(-1, 1), rand(0.3, 1), rand(-1, 1))
        if outward.Magnitude < 0.001 then outward = Vector3.new(0, 1, 0) end
        local sproutDir = outward.Unit
        local tip = startPos + sproutDir * sproutLen
        if inPathOrHeartCell(tip) then
            sproutLen = 1.5
            tip = startPos + sproutDir * sproutLen
        end
        local mid = startPos + sproutDir * (sproutLen / 2)
        local part = makePart({
            Name = "Map3PoppedBranch",
            Size = Vector3.new(sproutLen, sproutRadius * 2, sproutRadius * 2),
            CFrame = CFrame.lookAt(mid, mid + sproutDir) * CFrame.Angles(0, math.rad(90), 0),
            Material = Enum.Material.Wood,
            Color = SMALL_BRANCH_COLOR,
            Shape = Enum.PartType.Cylinder,
            CanCollide = true,
            Parent = map3Room,
        })
        local leafCount = math.random(2, 3)
        local leafParts = {}
        local baseLeafSize = math.max(sproutRadius * 5, rand(1.8, 2.5))
        for i = 1, leafCount do
            local leafOffset = Vector3.new(rand(-0.4, 0.4), rand(-0.2, 0.4), rand(-0.4, 0.4))
            local leafColor = (i % 2 == 0) and LEAF_COLOR_LIGHT or LEAF_COLOR_DARK
            local leaf = makePart({
                Name = "Map3Leaf",
                Size = Vector3.new(baseLeafSize, baseLeafSize * 0.85, baseLeafSize),
                CFrame = CFrame.new(tip + leafOffset)
                       * CFrame.Angles(rand(-0.5, 0.5), rand(0, 6.28), rand(-0.5, 0.5)),
                Material = Enum.Material.LeafyGrass,
                Color = leafColor,
                Shape = Enum.PartType.Ball,
                CanCollide = false,
                Parent = map3Room,
            })
            leaf.CastShadow = false
            table.insert(leafParts, leaf)
        end
        table.insert(Map3Stage.smallBranches, {
            part = part,
            baseLength = sproutLen,
            baseRadius = sproutRadius,
            startPos = startPos,
            sproutDir = sproutDir,
            leafParts = leafParts,
            baseLeafSize = baseLeafSize,
            tipPos = tip,
            unlockStage = unlockStage,
        })
    end

    -- Sprout policy:
    --   stage 1: only offshoot terminal stubs get a leaf clump on the cap.
    --   stage 3: every terminal pops a NEW branch with its own cluster,
    --            AND a fraction of LOOP segments also pop a small branch
    --            (per Matthew "little branches coming off the big branches").
    for _, slice in ipairs(mainBranches) do
        if slice.isTerminal then
            sproutSmallBranch(slice, 1)
            sproutPoppedBranch(slice, 3)
        elseif slice.kind == "loop" and math.random() < 0.18 then
            sproutPoppedBranch(slice, 3)
        end
    end

    ------------------------------------------------------------
    -- FLOWERS — sprout from leaf tips on small branches starting at stage 2.
    --
    -- Visual: small neon-bright "petal" cluster (a stretched ball + 4 petal
    -- planks around it) attached to a leaf tip. Color palette is bright
    -- pinks / yellows / pale-purples for variety.
    --
    -- Per-stage scaling: stage-2 flowers appear (small), stage-3 they reach
    -- full size + more flowers join. Stage 4 = same as 3.
    ------------------------------------------------------------
    local FLOWER_PALETTE = {
        Color3.fromRGB(255, 170, 200),  -- pink
        Color3.fromRGB(255, 230, 130),  -- pale yellow
        Color3.fromRGB(220, 170, 255),  -- pale purple
        Color3.fromRGB(255, 150, 130),  -- coral
        Color3.fromRGB(200, 240, 255),  -- pale blue-white
    }

    local function buildFlower(parentEntry, unlockStage)
        -- Mark this cluster as flower-bearing so the stage-4 fill loop
        -- knows which clusters still need a flower.
        parentEntry.hasFlower = true
        local color = FLOWER_PALETTE[math.random(1, #FLOWER_PALETTE)]
        local baseSize = rand(0.8, 1.4)
        -- Anchor flower on the OUTSIDE surface of a leaf ball, not inside.
        local leaf = parentEntry.leafParts[math.random(1, #parentEntry.leafParts)]
        local flowerDir = Vector3.new(rand(-1, 1), rand(0.2, 1), rand(-1, 1))
        if flowerDir.Magnitude < 0.001 then flowerDir = Vector3.new(0, 1, 0) end
        flowerDir = flowerDir.Unit
        local leafRadius = math.max(leaf.Size.X, leaf.Size.Y, leaf.Size.Z) / 2
        -- Anchor SLIGHTLY INSIDE the leaf (insetDist below the surface) so
        -- the petal ring (extends ~baseSize×0.5 from anchor) lands ON the
        -- leaf surface, not floating in space past it.
        local insetDist = baseSize * 0.45
        local anchor = leaf.Position + flowerDir * (leafRadius - insetDist)
        local center = makePart({
            Name = "Map3FlowerCenter",
            Size = Vector3.new(baseSize * 0.6, baseSize * 0.6, baseSize * 0.6),
            CFrame = CFrame.new(anchor),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 240, 140),  -- yellow center
            Shape = Enum.PartType.Ball,
            CanCollide = false,
            Parent = map3Room,
        })
        center.CastShadow = false
        -- PointLight on the flower center — brightness is tuned per stage
        -- by Map3StageVisuals (off in daytime, glowing at dusk/night).
        local light = Instance.new("PointLight")
        light.Color = color
        light.Range = 7
        light.Brightness = 0
        light.Parent = center
        local petalParts = {center}
        for i = 1, 5 do
            local angle = (i / 5) * math.pi * 2
            local petalOffset = Vector3.new(math.cos(angle) * baseSize * 0.5, 0, math.sin(angle) * baseSize * 0.5)
            local petal = makePart({
                Name = "Map3FlowerPetal",
                Size = Vector3.new(baseSize, baseSize * 0.25, baseSize * 0.6),
                CFrame = CFrame.new(anchor + petalOffset)
                        * CFrame.Angles(0, angle, math.rad(15)),
                Material = Enum.Material.Neon,
                Color = color,
                CanCollide = false,
                Parent = map3Room,
            })
            petal.CastShadow = false
            table.insert(petalParts, petal)
        end
        -- Capture each part's CFrame relative to the anchor so the per-stage
        -- scaler can re-pin them on top of the leaf when the leaf moves.
        local partLocalCFrames = {}
        local invAnchor = CFrame.new(-anchor)
        for _, p in ipairs(petalParts) do
            table.insert(partLocalCFrames, invAnchor * p.CFrame)
        end
        table.insert(Map3Stage.flowers, {
            parts = petalParts,
            baseSize = baseSize,
            unlockStage = unlockStage,
            parentLeaf = leaf,
            flowerDir = flowerDir,
            partLocalCFrames = partLocalCFrames,
        })
    end

    -- Spawn flowers on a fraction of the small branches. Most appear at
    -- stage 2; the rest at stage 3.
    for _, sb in ipairs(Map3Stage.smallBranches) do
        if math.random() < 0.55 then
            local stage = (math.random() < 0.6) and 2 or 3
            -- Stage 1 small branches get flowers starting stage 2.
            -- Stage 2/3 small branches: their flowers appear once they're
            -- visible AND the chosen stage rolls in.
            local effectiveStage = math.max(stage, sb.unlockStage)
            buildFlower(sb, effectiveStage)
        end
    end
    -- Some branches get a SECOND flower starting at stage 3.
    for _, sb in ipairs(Map3Stage.smallBranches) do
        if math.random() < 0.30 then
            local effectiveStage = math.max(3, sb.unlockStage)
            buildFlower(sb, effectiveStage)
        end
    end

    -- Stage 3 → 4 flower additions (per Matthew):
    --   1) Every original (stage-1 unlock) leaf cluster that doesn't yet
    --      have a flower gets one at stage 4.
    --   2) +20% more flowers — 20% of original clusters get an additional
    --      flower at stage 4 on top of whatever they already have.
    for _, sb in ipairs(Map3Stage.smallBranches) do
        if sb.unlockStage == 1 and not sb.hasFlower then
            buildFlower(sb, 4)
        end
    end
    for _, sb in ipairs(Map3Stage.smallBranches) do
        if sb.unlockStage == 1 and math.random() < 0.20 then
            buildFlower(sb, 4)
        end
    end

    ------------------------------------------------------------
    -- FLOWER BUDS — closed bulbs that appear from stage 1, alongside
    -- the sprouted leaves. Visually a single elongated ball stuck near a
    -- leaf tip. Stored in Map3Stage.flowers so the per-stage scaler
    -- already animates them.
    ------------------------------------------------------------
    local BUD_PALETTE = {
        Color3.fromRGB(220, 130, 170),  -- dusky pink
        Color3.fromRGB(230, 200, 110),  -- amber
        Color3.fromRGB(180, 140, 220),  -- lavender
        Color3.fromRGB(220, 110, 100),  -- rose-coral
        Color3.fromRGB(160, 200, 240),  -- pale sky-blue
    }

    local function buildFlowerBud(parentEntry, unlockStage)
        local color = BUD_PALETTE[math.random(1, #BUD_PALETTE)]
        local baseSize = rand(0.5, 0.9)
        local leaf = parentEntry.leafParts[math.random(1, #parentEntry.leafParts)]
        -- Capture the LOCAL offset (relative to leaf) so the bud can be
        -- repositioned when the leaf moves on stage advance. Without this
        -- the bud floats in space at the original leaf location.
        local localOffset = Vector3.new(rand(-0.4, 0.4), rand(0.25, 0.55), rand(-0.4, 0.4))
        local anchorWorld = leaf.Position + localOffset
        local bud = makePart({
            Name = "Map3FlowerBud",
            -- Elongated vertical ovoid — the closed-bud silhouette.
            Size = Vector3.new(baseSize * 0.65, baseSize * 1.4, baseSize * 0.65),
            CFrame = CFrame.new(anchorWorld)
                    * CFrame.Angles(rand(-0.3, 0.3), rand(0, 6.28), rand(-0.3, 0.3)),
            Material = Enum.Material.SmoothPlastic,
            Color = color,
            Shape = Enum.PartType.Ball,
            CanCollide = false,
            Parent = map3Room,
        })
        bud.CastShadow = false
        -- Re-use the flowers list so the per-stage scaler picks them up.
        -- Bud carries parentLeaf + localOffset so the scaler can re-pin
        -- it to the leaf each time the leaf gets moved.
        table.insert(Map3Stage.flowers, {
            parts = {bud},
            baseSize = baseSize,
            unlockStage = unlockStage,
            isBud = true,
            parentLeaf = leaf,
            localOffset = localOffset,
        })
    end

    -- Spawn buds on most small branches. Buds appear at the SAME stage as
    -- the parent small branch (stage 1, 2, or 3) — so they're the early-
    -- bloom hint that flowers are coming, present from the very start.
    for _, sb in ipairs(Map3Stage.smallBranches) do
        if math.random() < 0.7 then
            buildFlowerBud(sb, sb.unlockStage)
        end
    end
    -- A second bud on some sprouts for extra density.
    for _, sb in ipairs(Map3Stage.smallBranches) do
        if math.random() < 0.35 then
            buildFlowerBud(sb, sb.unlockStage)
        end
    end

    ------------------------------------------------------------
    -- BUTTERFLIES — small flat parts that bob in place. Stage-gated:
    --   stage 1: none
    --   stage 2: 4 butterflies
    --   stage 3: 10 butterflies
    --   stage 4: 14 butterflies (peak)
    --
    -- Animation handled by RunService.Heartbeat in Map3StageVisuals; here
    -- we just register the parts + their hover origins.
    ------------------------------------------------------------
    local BUTTERFLY_COLORS = {
        Color3.fromRGB(255, 180, 80),
        Color3.fromRGB(140, 200, 255),
        Color3.fromRGB(255, 220, 100),
        Color3.fromRGB(220, 130, 220),
        Color3.fromRGB(255, 110, 110),
    }

    -- Pick a random open flower (non-bud) anchor to use as a butterfly's
    -- hover origin. Falls back to a random in-room point if no flowers
    -- exist yet (shouldn't happen since flowers are built before butterflies).
    local function pickFlowerAnchor()
        local openFlowers = {}
        for _, f in ipairs(Map3Stage.flowers) do
            if not f.isBud and f.parts and f.parts[1] and f.parts[1].Parent then
                table.insert(openFlowers, f)
            end
        end
        if #openFlowers > 0 then
            local f = openFlowers[math.random(1, #openFlowers)]
            return f.parts[1].Position + Vector3.new(0, 1.5, 0)
        end
        return Vector3.new(
            m3c.X + rand(-m3HalfW * 0.65, m3HalfW * 0.65),
            m3c.Y + rand(8, MAP3_HEIGHT - 12),
            m3c.Z + rand(-m3HalfD * 0.65, m3HalfD * 0.65)
        )
    end

    local function buildButterfly(unlockStage)
        -- Travel-then-orbit flight per Matthew: butterflies SPAWN in the
        -- middle of the arena (slightly nudged toward their target flower
        -- so they fan out instead of clumping), then fly to the flower
        -- and orbit. The orbit's flowerPos is the hover anchor.
        local flowerPos = pickFlowerAnchor()
        local middlePos = m3c + Vector3.new(
            rand(-m3HalfW * 0.25, m3HalfW * 0.25),
            rand(8, 16),
            rand(-m3HalfD * 0.25, m3HalfD * 0.25)
        )
        local toFlower = flowerPos - middlePos
        local startPos
        if toFlower.Magnitude > 6 then
            startPos = middlePos + toFlower.Unit * 5  -- 5 studs head-start toward flower
        else
            startPos = middlePos
        end
        local hoverPos = flowerPos
        local color = BUTTERFLY_COLORS[math.random(1, #BUTTERFLY_COLORS)]
        local baseSize = rand(0.9, 1.4)
        local body = makePart({
            Name = "Map3ButterflyBody",
            Size = Vector3.new(baseSize * 0.25, baseSize * 0.15, baseSize * 0.6),
            CFrame = CFrame.new(startPos),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(40, 30, 25),
            CanCollide = false,
            Parent = map3Room,
        })
        body.CastShadow = false
        -- Two wings: thin Neon planes to either side of the body.
        local wingL = makePart({
            Name = "Map3ButterflyWing",
            Size = Vector3.new(baseSize * 0.9, baseSize * 0.05, baseSize * 0.7),
            CFrame = CFrame.new(startPos + Vector3.new(-baseSize * 0.5, 0, 0)),
            Material = Enum.Material.Neon,
            Color = color,
            Transparency = 0.1,
            CanCollide = false,
            Parent = map3Room,
        })
        wingL.CastShadow = false
        local wingR = makePart({
            Name = "Map3ButterflyWing",
            Size = Vector3.new(baseSize * 0.9, baseSize * 0.05, baseSize * 0.7),
            CFrame = CFrame.new(startPos + Vector3.new(baseSize * 0.5, 0, 0)),
            Material = Enum.Material.Neon,
            Color = color,
            Transparency = 0.1,
            CanCollide = false,
            Parent = map3Room,
        })
        wingR.CastShadow = false
        -- (No weld constraints — the Heartbeat tick repositions all three
        -- parts every frame. Welds were fighting the per-frame flap update
        -- and parking some butterflies' wings.)
        -- PointLight on the butterfly body, brightness ramped per stage
        -- (off in daytime, glowing at dusk/night).
        local bLight = Instance.new("PointLight")
        bLight.Color = color
        bLight.Range = 5
        bLight.Brightness = 0
        bLight.Parent = body
        table.insert(Map3Stage.butterflies, {
            body = body,
            wingL = wingL,
            wingR = wingR,
            hoverPos = hoverPos,
            startPos = startPos,
            baseSize = baseSize,
            phase = rand(0, math.pi * 2),
            speed = rand(0.8, 1.6),
            -- Orbit OUTSIDE the leaf balls (radius bumped from 1.4-2.6).
            -- Leaves are now 3-5 stud round balls; small radius put butterflies
            -- inside them.
            radius = rand(4, 6.5),
            unlockStage = unlockStage,
            -- Travel-then-orbit state. Set to "traveling" when butterfly
            -- becomes visible (in setButterflyVisibility).
            state = "idle",
            travelDuration = rand(2.5, 4.5),
            travelStartTime = 0,
        })
    end

    -- Butterfly count: 25 total (per Matthew's "MORE BUTTERFLIES!").
    -- All start in the middle and fly to a flower cluster, then orbit it.
    -- Distribution: 8@stage2, 12@stage3, 5@stage4.
    for i = 1, 25 do
        local unlockStage
        if i <= 8 then unlockStage = 2
        elseif i <= 20 then unlockStage = 3
        else unlockStage = 4
        end
        buildButterfly(unlockStage)
    end

    ------------------------------------------------------------
    -- EGG NEST — 5 large eggs clustered in the NE corner with a twig nest
    -- cushion around them. Reads as "this map is an actual nest."
    ------------------------------------------------------------
    local nestCenter = Vector3.new(
        m3c.X + m3HalfW - 16,
        m3c.Y + 1,
        m3c.Z - m3HalfD + 16
    )
    -- Twig nest base — a bowl-ish disc of twigs around the eggs.
    local twigCount = 26
    for i = 1, twigCount do
        local angle = (i / twigCount) * math.pi * 2 + rand(-0.15, 0.15)
        local r = rand(7, 11)
        local twigPos = nestCenter + Vector3.new(math.cos(angle) * r, rand(0, 1.5), math.sin(angle) * r)
        local twigLen = rand(6, 9)
        local twigRad = rand(0.18, 0.32)
        local lookDir = Vector3.new(math.cos(angle + math.pi/2), 0, math.sin(angle + math.pi/2))
        local twig = makePart({
            Name = "Map3NestTwig",
            Size = Vector3.new(twigLen, twigRad * 2, twigRad * 2),
            CFrame = CFrame.lookAt(twigPos, twigPos + lookDir)
                   * CFrame.Angles(0, math.rad(90), math.rad(rand(-15, 15))),
            Material = Enum.Material.Wood,
            Color = (i % 2 == 0) and Color3.fromRGB(120, 90, 55) or Color3.fromRGB(95, 70, 40),
            Shape = Enum.PartType.Cylinder,
            CanCollide = false,
            Parent = map3Room,
        })
        twig.CastShadow = false
    end

    -- 5 large eggs in a tight cluster
    local EGG_COLOR = Color3.fromRGB(245, 230, 200)  -- cream
    local EGG_SPECK = Color3.fromRGB(180, 150, 110)  -- darker speck color
    local eggOffsets = {
        {x =  0,    z =  0,    h = 9, w = 6},
        {x = -3.5,  z = -2,    h = 8, w = 5.5},
        {x =  3,    z = -1.5,  h = 8, w = 5.5},
        {x = -1.5,  z =  3.5,  h = 8.5, w = 5.8},
        {x =  3.5,  z =  3,    h = 7.5, w = 5.2},
    }
    for i, e in ipairs(eggOffsets) do
        local eggPos = nestCenter + Vector3.new(e.x, e.h / 2 + 0.5, e.z)
        local egg = makePart({
            Name = "Map3Egg" .. i,
            Size = Vector3.new(e.w, e.h, e.w),
            CFrame = CFrame.new(eggPos) * CFrame.Angles(0, rand(0, math.pi * 2), math.rad(rand(-8, 8))),
            Material = Enum.Material.SmoothPlastic,
            Color = EGG_COLOR,
            Shape = Enum.PartType.Ball,
            CanCollide = true,
            Parent = map3Room,
        })
        -- Specks on the egg shell — 5 small darker dots
        for s = 1, 5 do
            local theta = rand(0, math.pi * 2)
            local phi = rand(-math.pi / 3, math.pi / 3)
            local r = e.w * 0.5
            local speckPos = eggPos + Vector3.new(
                r * math.cos(phi) * math.cos(theta),
                r * math.sin(phi),
                r * math.cos(phi) * math.sin(theta)
            )
            local speck = makePart({
                Name = "Map3EggSpeck",
                Size = Vector3.new(0.5, 0.18, 0.5),
                CFrame = CFrame.new(speckPos),
                Material = Enum.Material.SmoothPlastic,
                Color = EGG_SPECK,
                Shape = Enum.PartType.Ball,
                CanCollide = false,
                Parent = map3Room,
            })
            speck.CastShadow = false
        end
    end

    -- (gridState path + heart marking already happened earlier in setup so
    -- the gnarled-branch wall builder could avoid path cells. Below: only
    -- the visual / tagged geometry — waypoints, tiles, heart, spawn.)

    -- EnemyPath waypoints
    local map3PathFolder = Instance.new("Folder")
    map3PathFolder.Name = "EnemyPath"
    map3PathFolder.Parent = map3Room
    map3PathFolder:SetAttribute("MapId", 3)
    for i, cell in ipairs(map3PathCells) do
        local worldPos = cellToWorld(cell[1], cell[2]) + Vector3.new(0, 1, 0)
        local part = makePart({
            Name = "Waypoint" .. i,
            Size = Vector3.new(2, 0.2, 2),
            CFrame = CFrame.new(worldPos),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(220, 200, 130),  -- pale gold for canopy
            Transparency = 0.6,
            CanCollide = false,
            Parent = map3PathFolder,
        })
        part:SetAttribute("MapId", 3)
        CollectionService:AddTag(part, Tags.EnemyWaypoint)
    end

    -- Visual path tiles
    for c = MAP3_COL_OFFSET, MAP3_TOTAL_COLS - 1 do
        for r = 0, MAP3_ROWS - 1 do
            local s = gridState[c][r]
            if s == "path" or s == "heart" then
                local worldPos = cellToWorld(c, r)
                worldPos = Vector3.new(worldPos.X, m3c.Y + 1.15, worldPos.Z)
                makePart({
                    Name = (s == "path") and "PathCell" or "HeartCell",
                    Size = Vector3.new(CELL_SIZE, 0.3, CELL_SIZE),
                    CFrame = CFrame.new(worldPos),
                    Material = Enum.Material.Slate,
                    Color = (s == "path") and Color3.fromRGB(150, 130, 90)
                                           or Color3.fromRGB(180, 160, 110),
                    CanCollide = false,
                    Parent = map3Room,
                })
            end
        end
    end

    ------------------------------------------------------------
    -- HEART — bigger again, 8000 HP (map 1 = 500, map 2 = 5000, map 3 = 8000).
    ------------------------------------------------------------
    local m3HeartWorldPos = cellToWorld(m3HeartCell[1], m3HeartCell[2]) + Vector3.new(0, 4, 0)
    local map3Heart = makePart({
        Name = "TreeHeartMap3",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(14, 14, 14),
        CFrame = CFrame.new(m3HeartWorldPos),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(255, 220, 140),
        Transparency = 0.2,
        CanCollide = false,
        Parent = map3Room,
    })
    CollectionService:AddTag(map3Heart, Tags.EnemyEndPoint)
    map3Heart:SetAttribute("MapId", 3)
    local map3HeartHp = Config.Map3.HeartMaxHp
    map3Heart:SetAttribute("MaxHealth", map3HeartHp)
    map3Heart:SetAttribute("Health", map3HeartHp)

    local m3HeartLight = Instance.new("PointLight")
    m3HeartLight.Color = Color3.fromRGB(255, 220, 140)
    m3HeartLight.Brightness = 3
    m3HeartLight.Range = 60
    m3HeartLight.Parent = map3Heart

    -- HP billboard (mirrors map 2 heart)
    local m3HpAnchor = makePart({
        Name = "HeartHPAnchorMap3",
        Size = Vector3.new(1, 1, 1),
        CFrame = CFrame.new(m3HeartWorldPos + Vector3.new(0, 11, 0)),
        Transparency = 1,
        CanCollide = false,
        Parent = map3Room,
    })
    local m3HpBillboard = Instance.new("BillboardGui")
    m3HpBillboard.Size = UDim2.fromOffset(140, 28)
    m3HpBillboard.AlwaysOnTop = true
    m3HpBillboard.LightInfluence = 0
    m3HpBillboard.MaxDistance = 280
    m3HpBillboard.Parent = m3HpAnchor
    local m3HpBg = Instance.new("Frame")
    m3HpBg.Size = UDim2.fromScale(1, 1)
    m3HpBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    m3HpBg.BackgroundTransparency = 0.2
    m3HpBg.BorderSizePixel = 0
    m3HpBg.Parent = m3HpBillboard
    local m3HpFill = Instance.new("Frame")
    m3HpFill.Size = UDim2.new(1, -4, 1, -4)
    m3HpFill.Position = UDim2.fromOffset(2, 2)
    m3HpFill.BackgroundColor3 = Color3.fromRGB(255, 220, 140)
    m3HpFill.BorderSizePixel = 0
    m3HpFill.Parent = m3HpBg
    local m3HpText = Instance.new("TextLabel")
    m3HpText.Size = UDim2.fromScale(1, 1)
    m3HpText.BackgroundTransparency = 1
    m3HpText.TextColor3 = Color3.fromRGB(255, 255, 255)
    m3HpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    m3HpText.TextStrokeTransparency = 0
    m3HpText.Font = Enum.Font.FredokaOne
    m3HpText.TextSize = 18
    m3HpText.ZIndex = 2
    m3HpText.Parent = m3HpBg
    local m3LabelBillboard = Instance.new("BillboardGui")
    m3LabelBillboard.Size = UDim2.fromOffset(200, 24)
    m3LabelBillboard.AlwaysOnTop = true
    m3LabelBillboard.LightInfluence = 0
    m3LabelBillboard.MaxDistance = 280
    m3LabelBillboard.StudsOffset = Vector3.new(0, 1.5, 0)
    m3LabelBillboard.Parent = m3HpAnchor
    local m3LabelText = Instance.new("TextLabel")
    m3LabelText.Size = UDim2.fromScale(1, 1)
    m3LabelText.BackgroundTransparency = 1
    m3LabelText.Text = "HEART OF THE TREE"
    m3LabelText.TextColor3 = Color3.fromRGB(255, 255, 255)
    m3LabelText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    m3LabelText.TextStrokeTransparency = 0
    m3LabelText.Font = Enum.Font.FredokaOne
    m3LabelText.TextSize = 16
    m3LabelText.Parent = m3LabelBillboard
    local function refreshMap3HeartHud()
        local hp = map3Heart:GetAttribute("Health") or 0
        local max = map3Heart:GetAttribute("MaxHealth") or 8000
        m3HpFill.Size = UDim2.new(math.max(0, hp / max), -4, 1, -4)
        m3HpText.Text = string.format("%d / %d", hp, max)
    end
    refreshMap3HeartHud()
    map3Heart:GetAttributeChangedSignal("Health"):Connect(refreshMap3HeartHud)
    map3Heart:GetAttributeChangedSignal("MaxHealth"):Connect(refreshMap3HeartHud)

    -- EnemySpawn at the start of the path
    local map3Spawn = makePart({
        Name = "EnemySpawnMap3",
        Size = Vector3.new(4, 0.5, 4),
        CFrame = CFrame.new(cellToWorld(map3PathCells[1][1], map3PathCells[1][2])
                            + Vector3.new(0, 1.15, 0)),
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(255, 100, 100),
        Transparency = 0.4,
        CanCollide = false,
        Parent = map3Room,
    })
    map3Spawn:SetAttribute("MapId", 3)
    CollectionService:AddTag(map3Spawn, Tags.EnemySpawn)

    -- Publish to ctx
    ctx.map3Room             = map3Room
    ctx.map3Heart            = map3Heart
    ctx.MAP3_PLAYER_SPAWN_CF = MAP3_PLAYER_SPAWN_CF

    print(("[Map3] Built. Cols %d-%d, %d main branch slices, %d small branches, %d flowers, %d butterflies"):format(
        MAP3_COL_OFFSET, MAP3_TOTAL_COLS - 1,
        #mainBranches,
        #Map3Stage.smallBranches,
        #Map3Stage.flowers,
        #Map3Stage.butterflies))
end

return Map3
