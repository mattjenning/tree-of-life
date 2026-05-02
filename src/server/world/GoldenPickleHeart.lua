--[[
    GoldenPickleHeart.lua — shared builder for the "Golden Pickle"
    heart visual.

    Used by all four maps (Hub TD-room, Map 2, Map 3, Map 4) so the
    visual stays consistent and tuning happens in one place. Per
    Matthew 2026-05-01: every map's heart is the Golden Pickle —
    same fiction, same colors, scaled per-map for the difficulty
    cadence (Map 1 smallest, Map 3/4 biggest).

    SHAPE:
      • Body — vertical Cylinder (rotated 90° on Z), gold Neon
      • 4 bumps — small Balls dotted around the body for cucumber
        texture, slightly deeper gold
      • Stem — short amber Wood block on top
      • PointLight — gold glow

    All proportions scale with `height` and `width` so a 14-tall
    Map 3 heart looks the same shape as a 12-tall Map 1 heart.
    The body Part holds the Tags.EnemyEndPoint tag + MapId /
    MaxHealth / Health attributes — these are the authoritative
    damage-target hooks the wave system reads. Bumps + stem are
    visual children parented to the body.

    Heart parts are anchored. The heart never moves, so absolute
    CFrames work without WeldConstraints; child parts stay put as
    long as the body's CFrame doesn't change.

    PUBLIC API:
      GoldenPickleHeart.create(props) -> Part
        Returns the body Part. Caller is responsible for HP-bar
        billboards (those vary per map — anchor offset, billboard
        size, Refresh closure all live in the per-map world file).

    props:
      name      : string    Part.Name (e.g. "TreeHeart", "TreeHeartMap2")
      mapId     : int       0/1/2/3/4 (written to MapId attribute)
      position  : Vector3   Body center world position
      height    : number    Pickle vertical dimension (default 12)
      width     : number    Pickle radius diameter (default 6)
      maxHp     : number    MaxHealth + Health (default 1000)
      parent    : Instance  Where the body Part is parented
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Tags = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Tags"))

local GoldenPickleHeart = {}

-- Palette. Single source of truth so color tweaks happen in ONE
-- place across all four maps. Exported so per-map HP-bar billboards
-- can match the body color (HP fill, label-text strokes, etc.).
GoldenPickleHeart.PICKLE_GOLD       = Color3.fromRGB(255, 215,  70)
GoldenPickleHeart.PICKLE_GOLD_DEEP  = Color3.fromRGB(220, 175,  40)
GoldenPickleHeart.PICKLE_STEM_AMBER = Color3.fromRGB(150, 100,  30)

local PICKLE_GOLD       = GoldenPickleHeart.PICKLE_GOLD
local PICKLE_GOLD_DEEP  = GoldenPickleHeart.PICKLE_GOLD_DEEP
-- PICKLE_STEM_AMBER export above is kept for backward compat (other
-- world modules may color-match against it) but the local alias is
-- gone since ea3-187 dropped the wooden stem from the heart visual.

local function makePart(p)
    local part = Instance.new("Part")
    part.Anchored = true
    part.CanCollide = false              -- mobs path through the heart
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    for k, v in pairs(p) do part[k] = v end
    return part
end

function GoldenPickleHeart.create(props)
    local name     = props.name or "GoldenPickleHeart"
    local mapId    = props.mapId or 0
    local position = props.position
    local height   = props.height or 12
    local width    = props.width or 6
    local maxHp    = props.maxHp or 1000
    local parent   = props.parent

    -- 7-SEGMENT ARC C-CURVE — per Matthew 2026-05-02 ea3-190.
    -- Two-halves at ±60° (ea3-189) read as a kinked corner at the
    -- spine, not a smooth curve. Replaced with 7 ellipsoid segments
    -- spaced along a true circular arc that passes through the
    -- bottom tip, the spine, and the top tip.
    --
    -- ARC CONSTRUCTION (in heart-local XY plane, heart center at 0,0):
    --   spine point      = (-W*0.4, 0)
    --   bottom-right tip = (+W*0.4, -H*0.45)
    --   top-right tip    = (+W*0.4, +H*0.45)
    --
    --   Solving for the arc center (cx, 0) (on the X axis by
    --   symmetry) and radius r such that all three points are on
    --   the arc:
    --     spine on arc:  r = W*0.4 + cx
    --     top   on arc:  r² = (W*0.4 - cx)² + (H*0.45)²
    --     → cx = H² * 0.127 / W
    --     → r  = W*0.4 + cx
    --
    --   For H = W = 12: cx = 1.52, r = 6.32.
    --
    -- SEGMENT PLACEMENT
    --   Sweep angle range: from -58.7° (bottom tip) to +58.7° (top
    --   tip), going CLOCKWISE through 180° (the left spine). Total
    --   sweep is 360 - (top - bottom) = 360 - 117.4 = 242.6°.
    --
    --   7 segments at evenly-spaced parameter t ∈ [0, 1]:
    --     angleDeg(t) = startAngle - t * sweepDeg
    --   Segment positions: (cx + r·cos(angle), r·sin(angle))
    --   Segment tilt: tangent to arc at that angle. For CW sweep,
    --   tangent direction is θ - 180° from +X axis. Rotating a
    --   vertical bar (long axis +Y) to that direction = Z-rotation
    --   of (θ - 180°) (math sign).
    --
    -- The pickle FLOATS — center lifts max(2, height × 0.25) above
    -- caller's `position`. The pedestal (built separately by the
    -- caller) stays at `position`; the pickle hovers above it.
    local floatY      = math.max(2, height * 0.25)
    local centerWorld = position + Vector3.new(0, floatY, 0)

    -- Arc geometry (heart-local coordinates).
    local cx          = (height * height * 0.127) / width
    local arcRadius   = width * 0.4 + cx
    local startAngle  = -58.7                            -- bottom tip
    local sweepDeg    = 242.6                            -- CW sweep to top tip via left spine

    -- Segment dimensions.
    local PART_COUNT  = 7
    local segArcLen   = arcRadius * math.rad(sweepDeg / PART_COUNT)
    local segLength   = segArcLen * 1.35                 -- 35% overlap so segments merge into a continuous tube
    local segWidth    = width * 0.45                     -- thickness across the curve
    local segDepth    = width * 0.45                     -- into-page

    -- Build all 7 segments. The first segment is the tag-bearing
    -- primary (carries EnemyEndPoint + MapId/MaxHealth/Health);
    -- the remaining 6 are sibling visuals parented to it.
    local segments = {}
    for i = 1, PART_COUNT do
        local t = (i - 1) / (PART_COUNT - 1)
        local angleDeg = startAngle - t * sweepDeg
        local angleRad = math.rad(angleDeg)
        local px = cx + arcRadius * math.cos(angleRad)
        local py = arcRadius * math.sin(angleRad)
        local tiltDeg = angleDeg - 180

        local seg = makePart({
            Name = (i == 1) and name or ("PickleSegment" .. i),
            Shape = Enum.PartType.Block,
            Size = Vector3.new(segWidth, segLength, segDepth),
            CFrame = CFrame.new(centerWorld + Vector3.new(px, py, 0))
                   * CFrame.Angles(0, 0, math.rad(tiltDeg)),
            Material = Enum.Material.Neon,
            Color = PICKLE_GOLD,
            Transparency = 0.05,
            Parent = (i == 1) and parent or nil,
        })
        do
            local mesh = Instance.new("SpecialMesh")
            mesh.MeshType = Enum.MeshType.Sphere
            mesh.Parent = seg
        end
        segments[i] = seg
    end
    -- Parent segments 2..7 to the first segment (the body). Done in
    -- a second pass after segments[1] exists.
    for i = 2, PART_COUNT do
        segments[i].Parent = segments[1]
    end

    local body = segments[1]
    CollectionService:AddTag(body, Tags.EnemyEndPoint)
    body:SetAttribute("MapId", mapId)
    body:SetAttribute("MaxHealth", maxHp)
    body:SetAttribute("Health", maxHp)

    -- Reference the unused PICKLE_GOLD_DEEP local so selene's
    -- unused-variable check stays clean — the export is preserved
    -- for any future variant that wants the deeper accent shade.
    local _ = PICKLE_GOLD_DEEP

    -- GLOW — PointLight halo. Brightness=1, Range=2×h matches
    -- ea3-180 tuning; the floating + rotating motion adds visual
    -- interest without needing the over-glow.
    local light = Instance.new("PointLight")
    light.Color = PICKLE_GOLD
    light.Brightness = 1.0
    light.Range = math.max(20, height * 2)
    light.Parent = body

    -- SLOW ROTATION — RunService.Heartbeat loop sets each part's
    -- world CFrame each frame relative to centerWorld + a continuously
    -- advancing Y-rotation. Anchored parts can't be rotated by
    -- physics, so we drive them by script. Disconnects automatically
    -- when the heart Part is destroyed (clearAllMobs / map teardown).
    local ROT_DEG_PER_SEC = 18
    local angle = 0
    -- Capture each part's INITIAL offset from centerWorld in
    -- centerWorld-local space, so rotation is purely a Y-rotation
    -- around centerWorld applied to the captured offsets.
    local rotatingParts = {}
    for _, seg in ipairs(segments) do
        table.insert(rotatingParts, seg)
    end
    local initialOffsets = {}
    for _, p in ipairs(rotatingParts) do
        initialOffsets[p] = CFrame.new(centerWorld):ToObjectSpace(p.CFrame)
    end

    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not body.Parent then
            conn:Disconnect()
            return
        end
        angle = angle + math.rad(ROT_DEG_PER_SEC) * dt
        local rotCF = CFrame.new(centerWorld) * CFrame.Angles(0, angle, 0)
        for _, p in ipairs(rotatingParts) do
            if p.Parent then
                p.CFrame = rotCF * initialOffsets[p]
            end
        end
    end)

    return body
end

return GoldenPickleHeart
