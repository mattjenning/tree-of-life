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
GoldenPickleHeart.PICKLE_GOLD_DEEP  = Color3.fromRGB(185, 145,  30)
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

    -- ea3-205 slighter curve: tips reach further vertically, spine
    -- bulges less horizontally → arc subtends ~124° instead of 225°
    -- (gentle banana instead of strong C). Tips at (W·0.15, ±H·0.50),
    -- spine at (−W·0.15, 0).
    local TIP_X_FRAC   = 0.15
    local TIP_Y_FRAC   = 0.50
    local SPINE_X_FRAC = 0.15
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
    -- ea3-204: tip diameter raised 0.32 → 0.50 so the crescent ends
    -- look smoothly rounded instead of tapering to a sharp point.
    local DIAM_MIN_FRAC  = 0.50                       -- of width — rounded end
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
            Reflectance = 0.55,
            Color = Color3.fromRGB(255, 200, 50),
            Parent = (i == 1) and parent or nil,
        })
        segments[i] = seg
    end
    for i = 2, SEGMENT_COUNT do
        segments[i].Parent = segments[1]
    end
    local body = segments[1]

    -- BUMPS — darker-gold Ball parts scattered over the chubby-
    -- middle segments. ea3-208: 40 bumps at 26% of host diameter
    -- (was 25 @ 18.9%) per Matthew "bumps bigger and more of
    -- them". Distributed pseudo-randomly over host indices 7..23
    -- (the central ~half of the 30-segment arc), at varying
    -- spherical-coord angles around each host's surface so they
    -- don't line up on a single side. Inserted into `segments`
    -- so they rotate with the pickle.
    local BUMP_COUNT     = 40
    local BUMP_DIAM_FRAC = 0.26
    local BUMP_HOST_LO   = 7
    local BUMP_HOST_HI   = 23
    for i = 1, BUMP_COUNT do
        -- Cycle through host indices; with 40 bumps over 17
        -- hosts each gets ~2.4 bumps on average. Modulo + golden-
        -- angle theta below keep positions from repeating exactly.
        local hostIdx = BUMP_HOST_LO + ((i - 1) % (BUMP_HOST_HI - BUMP_HOST_LO + 1))
        local host = segments[hostIdx]
        if host then
            -- Pseudo-random angles for surface placement. 137°
            -- (golden-angle-ish) for theta gives a low-clumping
            -- spread; phi cycles through 50°..130° for mostly
            -- equatorial placement (avoids piling on the poles).
            local theta = math.rad((i * 137) % 360)
            local phi   = math.rad(50 + ((i * 53) % 81))
            local sinPhi = math.sin(phi)
            local hostDiam = host.Size.X
            local bumpDiam = hostDiam * BUMP_DIAM_FRAC
            local r = hostDiam * 0.42                        -- on-surface offset
            local offset = Vector3.new(
                sinPhi * math.cos(theta) * r,
                math.cos(phi) * r,
                sinPhi * math.sin(theta) * r)
            local bump = makePart({
                Name = "PickleBump_" .. i,
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(bumpDiam, bumpDiam, bumpDiam),
                CFrame = CFrame.new(host.CFrame.Position + offset),
                Material = Enum.Material.Metal,
                Reflectance = 0.55,
                Color = PICKLE_GOLD_DEEP,
                Parent = body,
            })
            table.insert(segments, bump)
        end
    end
    CollectionService:AddTag(body, Tags.EnemyEndPoint)
    body:SetAttribute("MapId", mapId)
    body:SetAttribute("MaxHealth", maxHp)
    body:SetAttribute("Health", maxHp)

    -- GLOW — subtle PointLight halo. ea3-208 dialed back from
    -- Brightness=1.0 / Range=2×h per Matthew "less glowy". The
    -- pickle's metallic reflectance now does most of the visual
    -- work; this light just hints at presence in shadow.
    local light = Instance.new("PointLight")
    light.Color = PICKLE_GOLD
    light.Brightness = 0.4
    light.Range = math.max(12, height * 1.2)
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
    -- ea3-212 ray heights 2..4.5 (min raised from 1.6, max held).
    --   base + amp = 4.5   (peak)
    --   base − amp = 2     (trough)
    -- → base = 3.25, amp = 1.25.
    local RAY_BASE_HEIGHT = 3.25
    local RAY_AMPLITUDE   = 1.25
    local RAY_FREQ        = 3                               -- 3 crests / 3 troughs around the circle
    local RAY_THICK       = 0.45
    local RAY_TRANS       = 0.78
    -- Color shift across the height range: short rays read as
    -- yellow, tall rays shift toward gold (ea3-213 — was green).
    -- Ray.Color updates per-frame in the Heartbeat hook below
    -- based on current height.
    local RAY_COLOR_LOW   = Color3.fromRGB(255, 220, 80)    -- short / yellow
    local RAY_COLOR_HIGH  = Color3.fromRGB(240, 170, 40)    -- tall / gold
    -- Tracked rays for animation. Stores ray + spatial info so the
    -- Heartbeat hook below can update each ray's height (Size +
    -- CFrame) per frame as the wave travels around the circumference.
    local rays = {}
    for i = 1, RAY_COUNT do
        local theta = (i - 1) * (2 * math.pi / RAY_COUNT)
        local rx = math.cos(theta) * pedestalRadius
        local rz = math.sin(theta) * pedestalRadius
        -- Initial height: t=0, so this is just the spatial sine.
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
        table.insert(rays, { ray = ray, theta = theta, rx = rx, rz = rz })
    end

    -- SLOW Y-AXIS ROTATION around centerWorld. Iterates all 30
    -- crescent segments. ALSO drives the ray-pulse animation: each
    -- ray's height tracks a TRAVELING sine wave so the curtain
    -- crests move around the rim over time. Wave: each ray's
    -- height = base + amplitude · sin(theta · spatialFreq + ω · t),
    -- where ω is the angular speed of the wave traversal.
    local ROT_DEG_PER_SEC  = 18
    local RAY_PULSE_OMEGA  = 2.0                             -- rad/s wave traversal speed
    local angle = 0
    local rayPulseT = 0
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
        -- Crescent rotation
        angle = angle + math.rad(ROT_DEG_PER_SEC) * dt
        local rotCF = CFrame.new(centerWorld) * CFrame.Angles(0, angle, 0)
        for _, p in ipairs(segments) do
            if p.Parent then
                p.CFrame = rotCF * initialOffsets[p]
            end
        end
        -- Ray traveling-wave pulse: rise/fall around the rim.
        rayPulseT = rayPulseT + dt
        for _, r in ipairs(rays) do
            if r.ray.Parent then
                local h = RAY_BASE_HEIGHT
                        + RAY_AMPLITUDE
                        * math.sin(r.theta * RAY_FREQ + rayPulseT * RAY_PULSE_OMEGA)
                -- Clamp to a tiny floor so we never request a 0-size
                -- part (Roblox enforces a 0.05 stud minimum anyway).
                if h < 0.05 then h = 0.05 end
                r.ray.Size = Vector3.new(h, RAY_THICK, RAY_THICK)
                r.ray.CFrame = CFrame.new(
                    position.X + r.rx,
                    pedestalTopY + h * 0.5,
                    position.Z + r.rz)
                    * CFrame.Angles(0, 0, math.rad(90))
                -- Color shift: short rays = yellow, tall rays = gold.
                -- t = 0 (trough) → YELLOW; t = 1 (peak) → GOLD.
                local colorT = math.clamp(h / (RAY_BASE_HEIGHT + RAY_AMPLITUDE), 0, 1)
                r.ray.Color = RAY_COLOR_LOW:Lerp(RAY_COLOR_HIGH, colorT)
            end
        end
    end)

    return body
end

return GoldenPickleHeart
