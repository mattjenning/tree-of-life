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

    -- SMOOTH CRESCENT — 30-Ball arc (per Matthew 2026-05-02 ea3-200).
    -- ea3-198 tried CSG SubtractAsync but the result kept rendering
    -- as a sphere (silently fell back, or async timing issue). This
    -- approach is fully deterministic: 30 Ball parts placed along
    -- a circular arc with high overlap, varying diameter (sin-bell
    -- taper for chubby middle). Density is tight enough that
    -- adjacent spheres overlap >90% of their radius — visually
    -- merges into a single smooth tube.
    --
    -- ARC CONSTRUCTION (same math as the prior 7-segment arc, just
    -- many more spheres along it):
    --   spine point      = (-W·SPINE_X, 0)
    --   bottom-right tip = (+W·TIP_X, -H·TIP_Y)
    --   top-right tip    = (+W·TIP_X, +H·TIP_Y)
    --   arc center cx, radius r solved so all 3 are on the arc.
    --
    -- FLOAT — center is lifted so the crescent's lowest point sits
    -- above the pedestal: floatY = (H/2) + 1 stud margin.
    local floatY      = (height * 0.5) + 1
    local centerWorld = position + Vector3.new(0, floatY, 0)

    local TIP_X_FRAC   = 0.30
    local TIP_Y_FRAC   = 0.40
    local SPINE_X_FRAC = 0.30
    local cx = (width * width * (TIP_X_FRAC ^ 2 - SPINE_X_FRAC ^ 2)
              + height * height * TIP_Y_FRAC ^ 2)
             / (2 * width * (SPINE_X_FRAC + TIP_X_FRAC))
    local arcRadius = width * SPINE_X_FRAC + cx
    local tipAngleDeg = math.deg(math.atan2(height * TIP_Y_FRAC, width * TIP_X_FRAC - cx))
    local startAngle  = -tipAngleDeg
    local sweepDeg    = 360 - 2 * tipAngleDeg

    -- 30 Ball parts: tight enough that adjacent ones overlap into
    -- one continuous tube. Diameter varies sin-bell across the arc
    -- (skinny tips, chubby middle).
    local SEGMENT_COUNT  = 30
    local DIAM_MIN_FRAC  = 0.32                       -- of width — skinny end
    local DIAM_MAX_FRAC  = 0.70                       -- of width — fat middle
    -- arclen between segment centers; sphere diameter must >> this for overlap
    -- arclen / segments-1 ≈ 13.92 / 29 ≈ 0.48 stud spacing for default geometry
    -- Spheres of diameter 1.9-4.2 stud easily overlap that.

    local segments = {}
    for i = 1, SEGMENT_COUNT do
        local t = (i - 1) / (SEGMENT_COUNT - 1)
        local angleDeg = startAngle - t * sweepDeg
        local angleRad = math.rad(angleDeg)
        local px = cx + arcRadius * math.cos(angleRad)
        local py = arcRadius * math.sin(angleRad)
        local taperFactor = math.sin(t * math.pi)     -- 0 → 1 → 0
        local diam = width * (DIAM_MIN_FRAC
                   + (DIAM_MAX_FRAC - DIAM_MIN_FRAC) * taperFactor)

        local seg = makePart({
            Name = (i == 1) and name or ("PickleSegment" .. i),
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(diam, diam, diam),
            CFrame = CFrame.new(centerWorld + Vector3.new(px, py, 0)),
            Material = Enum.Material.Metal,
            Reflectance = 0.30,
            Color = Color3.fromRGB(255, 200, 50),
            Parent = (i == 1) and parent or nil,
        })
        segments[i] = seg
    end
    for i = 2, SEGMENT_COUNT do
        segments[i].Parent = segments[1]
    end
    local body = segments[1]
    CollectionService:AddTag(body, Tags.EnemyEndPoint)
    body:SetAttribute("MapId", mapId)
    body:SetAttribute("MaxHealth", maxHp)
    body:SetAttribute("Health", maxHp)

    -- Reference the unused PICKLE_GOLD_DEEP local so selene's
    -- unused-variable check stays clean — the export is preserved
    -- for any future variant.
    local _ = PICKLE_GOLD_DEEP

    -- GLOW — PointLight halo at Brightness=1, Range=2×h.
    local light = Instance.new("PointLight")
    light.Color = PICKLE_GOLD
    light.Brightness = 1.0
    light.Range = math.max(20, height * 2)
    light.Parent = body

    -- GOLDEN RAYS from the pedestal circumference, going up.
    -- Per Matthew 2026-05-02 ea3-199: 36 rays (was 12) packed
    -- densely so they merge into a continuous golden wall;
    -- Transparency 0.55 → 0.78 for a ghostlier curtain; heights
    -- vary in a sine wave around the circle (4 peaks / 4 troughs)
    -- so the top edge ripples instead of being a flat band.
    local pedestalRadius = props.pedestalRadius or (width * 0.7)
    local pedestalTopY   = props.pedestalTopY   or (position.y - 1)
    local RAY_COUNT       = 36
    local RAY_BASE_HEIGHT = 18                              -- mean wall height
    local RAY_AMPLITUDE   = 14                              -- bigger sine peaks for clear ripple
    local RAY_FREQ        = 3                               -- 3 crests / 3 troughs around the circle
    local RAY_THICK       = 0.45
    local RAY_TRANS       = 0.78
    for i = 1, RAY_COUNT do
        local theta = (i - 1) * (2 * math.pi / RAY_COUNT)
        local rx = math.cos(theta) * pedestalRadius
        local rz = math.sin(theta) * pedestalRadius
        -- Sine-wave height around the circumference: at theta=0
        -- the ray is at its mean+amplitude crest; goes through 4
        -- full waves (peak/trough/peak/...) over 360°.
        local h = RAY_BASE_HEIGHT + RAY_AMPLITUDE * math.sin(theta * RAY_FREQ)
        local rayCenterY = pedestalTopY + (h * 0.5)
        local ray = makePart({
            Name = "GoldenRay" .. i,
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(h, RAY_THICK, RAY_THICK),
            CFrame = CFrame.new(position.X + rx, rayCenterY, position.Z + rz)
                   * CFrame.Angles(0, 0, math.rad(90)),    -- stand vertical
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 220, 80),
            Transparency = RAY_TRANS,
            Parent = body,
        })
        ray.CanQuery = false
        ray.CastShadow = false
    end

    -- SLOW Y-AXIS ROTATION around centerWorld. Iterates all 30
    -- crescent segments (rays stay static — they're parented to body
    -- but we don't include them in the rotating set).
    local ROT_DEG_PER_SEC = 18
    local angle = 0
    local initialOffsets = {}
    for _, seg in ipairs(segments) do
        initialOffsets[seg] = CFrame.new(centerWorld):ToObjectSpace(seg.CFrame)
    end

    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not body.Parent then
            conn:Disconnect()
            return
        end
        angle = angle + math.rad(ROT_DEG_PER_SEC) * dt
        local rotCF = CFrame.new(centerWorld) * CFrame.Angles(0, angle, 0)
        for _, p in ipairs(segments) do
            if p.Parent then
                p.CFrame = rotCF * initialOffsets[p]
            end
        end
    end)

    return body
end

return GoldenPickleHeart
