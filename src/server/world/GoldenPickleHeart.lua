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

    -- BANANA / C-CURVE BODY — per Matthew 2026-05-02 ea3-187:
    -- a single ellipsoid wasn't curvy enough; player wants a
    -- crescent-pickle shape. Approximated with TWO ellipsoid halves
    -- at opposing Z-tilts that meet at the heart's center, forming
    -- a "(" silhouette (curving to the right when viewed from front).
    -- Lower half is the tag-bearing primary; upper half is a sibling
    -- visual welded to the lower half.
    --
    -- The pickle FLOATS — center is lifted above the ground caller's
    -- `position` by `floatY`. The pedestal (built separately by the
    -- caller, e.g. TreeOfLife_Hub) stays at `position`; the pickle
    -- hovers above it.
    --
    -- Stem is gone (read as "wooden box" rather than stem and didn't
    -- add to the pickle silhouette).
    local floatY        = math.max(2, height * 0.25)   -- lift above pedestal
    local centerWorld   = position + Vector3.new(0, floatY, 0)
    local halfHeight    = height * 0.55                -- 10% overlap so halves merge
    local CURVE_DEG     = 22                           -- per-half tilt → ~44° total spread

    -- LOWER HALF — bottom of pickle, tilts so its top end leans into
    -- the curve's "inner" side (reading: bottom-right of the C).
    local lowerOffset = Vector3.new(width * 0.18, -halfHeight * 0.35, 0)
    local body = makePart({
        Name = name,
        Shape = Enum.PartType.Block,
        Size = Vector3.new(width, halfHeight, width * 0.85),
        CFrame = CFrame.new(centerWorld + lowerOffset)
               * CFrame.Angles(0, 0, math.rad(CURVE_DEG)),
        Material = Enum.Material.Neon,
        Color = PICKLE_GOLD,
        Transparency = 0.05,
        Parent = parent,
    })
    do
        local mesh = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.Sphere
        mesh.Parent = body
    end
    CollectionService:AddTag(body, Tags.EnemyEndPoint)
    body:SetAttribute("MapId", mapId)
    body:SetAttribute("MaxHealth", maxHp)
    body:SetAttribute("Health", maxHp)

    -- UPPER HALF — top of pickle, tilts opposite for the curve.
    local upperOffset = Vector3.new(width * 0.18, halfHeight * 0.35, 0)
    local upperHalf = makePart({
        Name = "PickleUpperHalf",
        Shape = Enum.PartType.Block,
        Size = Vector3.new(width, halfHeight, width * 0.85),
        CFrame = CFrame.new(centerWorld + upperOffset)
               * CFrame.Angles(0, 0, math.rad(-CURVE_DEG)),
        Material = Enum.Material.Neon,
        Color = PICKLE_GOLD,
        Transparency = 0.05,
        Parent = body,
    })
    do
        local mesh = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.Sphere
        mesh.Parent = upperHalf
    end

    -- BUMPS — 4 small balls clustered along the OUTER side of the
    -- curve (left side of the C, where the pickle's spine would be).
    local bumpDiameter = width * 0.38
    local bumpPattern = {
        -- Lower half cluster
        { y = -halfHeight * 0.50, x = -width * 0.10, z =  width * 0.45 },
        { y = -halfHeight * 0.15, x = -width * 0.25, z = -width * 0.40 },
        -- Upper half cluster
        { y =  halfHeight * 0.20, x = -width * 0.20, z =  width * 0.45 },
        { y =  halfHeight * 0.55, x = -width * 0.05, z = -width * 0.40 },
    }
    for i, off in ipairs(bumpPattern) do
        makePart({
            Name = "PickleBump" .. i,
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(bumpDiameter, bumpDiameter, bumpDiameter),
            CFrame = CFrame.new(centerWorld + Vector3.new(off.x, off.y, off.z)),
            Material = Enum.Material.Neon,
            Color = PICKLE_GOLD_DEEP,
            Transparency = 0.05,
            Parent = body,
        })
    end

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
    local rotatingParts = { body, upperHalf }
    for _, child in ipairs(body:GetChildren()) do
        if child:IsA("BasePart") then
            table.insert(rotatingParts, child)
        end
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
