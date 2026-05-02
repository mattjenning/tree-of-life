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
local PICKLE_STEM_AMBER = GoldenPickleHeart.PICKLE_STEM_AMBER

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

    -- BODY — elongated ellipsoid with a slight S-curve, per Matthew
    -- 2026-05-02 ea3-183 (was a flat-ended Cylinder). Block Part +
    -- SpecialMesh.Sphere renders as a curved ellipsoid sized to the
    -- (width × height × width × 0.85) bounds. The slight 8° tilt on
    -- Z gives a pickle-like lean instead of a perfectly straight
    -- oval. Block-shaped collision/path target geometry stays under
    -- the rounded mesh visual.
    local body = makePart({
        Name = name,
        Shape = Enum.PartType.Block,
        Size = Vector3.new(width, height, width * 0.85),
        CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(8)),
        Material = Enum.Material.Neon,
        Color = PICKLE_GOLD,
        Transparency = 0.05,
        Parent = parent,
    })
    do
        -- Sphere mesh inscribed in the Block: renders as an
        -- ellipsoid matching the part's non-uniform Size. Gives the
        -- "curved-end" silhouette of a real pickle vs the flat-ended
        -- Cylinder we used previously.
        local mesh = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.Sphere
        mesh.Parent = body
    end
    CollectionService:AddTag(body, Tags.EnemyEndPoint)
    body:SetAttribute("MapId", mapId)
    body:SetAttribute("MaxHealth", maxHp)
    body:SetAttribute("Health", maxHp)

    -- BUMPS — 4 small balls dotted around the body. Offsets scale
    -- with body dimensions so a bigger pickle keeps the same look.
    -- Pattern: alternating Z-axis (front/back) at staggered Y heights.
    local bumpDiameter = width * 0.4              -- ~40% of body width
    local bumpEdge     = width * 0.5              -- on the body's surface
    local hHalf        = height * 0.5
    local bumpPattern = {
        Vector3.new(0,  hHalf * 0.60,  bumpEdge),
        Vector3.new(0,  hHalf * 0.16, -bumpEdge),
        Vector3.new(0, -hHalf * 0.25,  bumpEdge),
        Vector3.new(0, -hHalf * 0.65, -bumpEdge * 0.9),
    }
    for i, off in ipairs(bumpPattern) do
        makePart({
            Name = "PickleBump" .. i,
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(bumpDiameter, bumpDiameter, bumpDiameter),
            CFrame = CFrame.new(position + off),
            Material = Enum.Material.Neon,
            Color = PICKLE_GOLD_DEEP,
            Transparency = 0.05,
            Parent = body,
        })
    end

    -- STEM — short amber Wood block on top. Doesn't glow; the
    -- contrast against the Neon body is what reads as "pickle stem"
    -- to the player.
    local stemSize = width * 0.23
    makePart({
        Name = "PickleStem",
        Shape = Enum.PartType.Block,
        Size = Vector3.new(stemSize, stemSize * 1.15, stemSize),
        CFrame = CFrame.new(position + Vector3.new(0, hHalf + 0.7, 0)),
        Material = Enum.Material.Wood,
        Color = PICKLE_STEM_AMBER,
        Parent = body,
    })

    -- GLOW — PointLight halo around the heart. Tuned down from the
    -- original Brightness=4/Range=4×h after Matthew 2026-05-02
    -- screenshot: the prior values + Neon body + camera exposure
    -- combined to wash out the pickle silhouette into a uniform
    -- yellow blob (bumps + cylindrical body invisible). Brightness=1
    -- and Range=2×h preserves the "glowing pickle" read while
    -- keeping the body shape readable.
    local light = Instance.new("PointLight")
    light.Color = PICKLE_GOLD
    light.Brightness = 1.0
    light.Range = math.max(20, height * 2)
    light.Parent = body

    return body
end

return GoldenPickleHeart
