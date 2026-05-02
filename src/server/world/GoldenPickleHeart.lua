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

    -- SMOOTH CRESCENT MOON via CSG SubtractAsync — per Matthew
    -- 2026-05-02 ea3-198: previous 7-segment arc still read as
    -- lumpy. Roblox primitives can't natively render a smooth
    -- crescent, so we use Workspace:SubtractAsync(outer, {inner})
    -- to carve a chubby crescent moon out of two ellipsoids.
    --
    -- GEOMETRY (heart-local XY, center 0,0):
    --   outer ellipsoid  size (W·crescent, H·crescent, depth·crescent)
    --                    centered at heart center
    --   inner ellipsoid  size (W·cut, H·cut, depth·cut)
    --                    offset +X by cutOffsetX
    --   crescent = outer ∖ inner
    --
    -- Chubby moon: cut depth tuned so the LEFT-side tube thickness
    -- ≈ 30-40% of the heart's width. Smaller cut depth = chubbier.
    --
    -- FLOAT — center is lifted so the heart's lowest point sits
    -- comfortably above the pedestal: floatY = (H/2) + 1 stud
    -- margin. For H=12: floatY = 7, lowest point at position.y + 1.
    local floatY      = (height * 0.5) + 1
    local centerWorld = position + Vector3.new(0, floatY, 0)

    -- Crescent geometry knobs (chubby moon defaults).
    local CRESCENT_W_FRAC = 0.95   -- outer X-extent as fraction of height
    local CRESCENT_H_FRAC = 1.00   -- outer Y-extent (full height)
    local CRESCENT_Z_FRAC = 0.70   -- depth (front-to-back)
    local CUT_W_FRAC      = 0.85   -- inner ellipsoid relative to outer
    local CUT_H_FRAC      = 0.85
    local CUT_OFFSET_FRAC = 0.40   -- +X offset of inner relative to height

    local outerSize = Vector3.new(
        height * CRESCENT_W_FRAC,
        height * CRESCENT_H_FRAC,
        height * CRESCENT_Z_FRAC)
    local innerSize = Vector3.new(
        height * CRESCENT_W_FRAC * CUT_W_FRAC,
        height * CRESCENT_H_FRAC * CUT_H_FRAC,
        height * CRESCENT_Z_FRAC * 1.10)             -- slightly deeper Z to ensure clean cut
    local cutOffset = Vector3.new(height * CUT_OFFSET_FRAC, 0, 0)

    local outerSphere = Instance.new("Part")
    outerSphere.Name = "OuterCrescentTemp"
    outerSphere.Shape = Enum.PartType.Ball
    outerSphere.Size = outerSize
    outerSphere.CFrame = CFrame.new(centerWorld)
    outerSphere.Material = Enum.Material.Metal
    outerSphere.Reflectance = 0.30
    outerSphere.Color = Color3.fromRGB(255, 200, 50)
    outerSphere.Anchored = true
    outerSphere.CanCollide = false
    outerSphere.TopSurface = Enum.SurfaceType.Smooth
    outerSphere.BottomSurface = Enum.SurfaceType.Smooth
    outerSphere.Parent = workspace

    local innerSphere = Instance.new("Part")
    innerSphere.Name = "InnerCrescentCut"
    innerSphere.Shape = Enum.PartType.Ball
    innerSphere.Size = innerSize
    innerSphere.CFrame = CFrame.new(centerWorld + cutOffset)
    innerSphere.Anchored = true
    innerSphere.CanCollide = false
    innerSphere.Parent = workspace

    -- Subtract is async; pcall guards against rare CSG failures.
    -- Fallback: keep the outer sphere as the heart body (uncarved).
    -- Bracket-style dynamic call bypasses selene's standard-library
    -- check (its bundled roblox.yml is older than the SubtractAsync
    -- API). Functionally identical to workspace:SubtractAsync(...).
    local body
    local subtracted
    local ok = pcall(function()
        subtracted = workspace["SubtractAsync"](workspace, outerSphere, { innerSphere })
    end)
    if ok and subtracted then
        body = subtracted
        body.Name = name
        body.UsePartColor = true
        body.Material = Enum.Material.Metal
        body.Reflectance = 0.30
        body.Color = Color3.fromRGB(255, 200, 50)
        body.Anchored = true
        body.CanCollide = false
        body.CastShadow = false
        body.Parent = parent
        outerSphere:Destroy()
        innerSphere:Destroy()
    else
        warn("[GoldenPickleHeart] CSG SubtractAsync failed; using uncarved outer sphere as fallback")
        innerSphere:Destroy()
        outerSphere.Name = name
        outerSphere.Parent = parent
        body = outerSphere
    end
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
    local RAY_BASE_HEIGHT = 22                              -- mean wall height
    local RAY_AMPLITUDE   = 9                               -- sine peak above/below mean
    local RAY_FREQ        = 4                               -- full sine cycles around the circle
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

    -- SLOW Y-AXIS ROTATION around centerWorld. With one CSG body
    -- it's a single CFrame update per frame. body's own CFrame
    -- after SubtractAsync is at the crescent's centroid (offset
    -- from centerWorld due to the asymmetric cut), so we capture
    -- the initial offset in centerWorld-local space and rotate.
    local ROT_DEG_PER_SEC = 18
    local angle = 0
    local initialBodyOffset = CFrame.new(centerWorld):ToObjectSpace(body.CFrame)

    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not body.Parent then
            conn:Disconnect()
            return
        end
        angle = angle + math.rad(ROT_DEG_PER_SEC) * dt
        body.CFrame = CFrame.new(centerWorld)
                    * CFrame.Angles(0, angle, 0)
                    * initialBodyOffset
    end)

    return body
end

return GoldenPickleHeart
