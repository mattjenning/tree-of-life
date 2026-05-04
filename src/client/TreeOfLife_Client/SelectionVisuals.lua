--[[
    SelectionVisuals.lua — The 3D "you have this tower selected"
    affordance: 8 corner brackets forming a wireframe cage around the
    tower's bounding box, plus a blue range ring on the floor.

    Both visuals sit on the floor at the tower's stamped FloorY (so
    descendant attachment VFX / invisible anchors can't drag the cage
    or ring below the floor) and clear together when selection ends.

    Public API:
      SelectionVisuals.build(tower)  — replace any existing visuals
                                        with brackets + range ring for
                                        this tower.
      SelectionVisuals.clear()        — destroy the visuals folder.

    Module owns its own selectionFolder reference so callers don't
    need to track it.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BBoxUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BBoxUtil"))

local SelectionVisuals = {}

local selectionFolder = nil

function SelectionVisuals.clear()
    if selectionFolder then
        selectionFolder:Destroy()
        selectionFolder = nil
    end
end

function SelectionVisuals.build(tower)
    SelectionVisuals.clear()
    if not tower or not tower.Parent then return end

    selectionFolder = Instance.new("Folder")
    selectionFolder.Name = "ToL_TowerSelection"
    selectionFolder.Parent = Workspace

    -- Auto-clear when the tower is destroyed (e.g. Pickle Lord
    -- smash). Without this, the corner brackets + range ring sit
    -- in Workspace forever as a "ghost selection" because the
    -- folder lives outside the tower's hierarchy. AncestryChanged
    -- with parent=nil fires when the model is Destroy()'d.
    tower.AncestryChanged:Connect(function(_, parent)
        if not parent then
            SelectionVisuals.clear()
        end
    end)

    -- World-axis bounding box (NOT Model:GetBoundingBox — that returns a
    -- CFrame aligned to the first child for towers without PrimaryPart,
    -- making Power Tower's cage hang sideways). See shared/BBoxUtil.lua
    -- for the descendant 8-corner sweep.
    local minV, maxV = BBoxUtil.worldAxisBounds(tower)
    if not minV or not maxV then return end  -- no parts found
    local minX, minY, minZ = minV.X, minV.Y, minV.Z
    local maxX, maxY, maxZ = maxV.X, maxV.Y, maxV.Z

    -- Override minY to the tower's stamped FloorY — the Y coord of the
    -- map floor the tower was placed on. The descendant sweep above
    -- includes attachment VFX / invisible anchors / particle containers
    -- that may hang below the visible base after ScaleTo + re-seat,
    -- dragging the cage's floor brackets (and the range ring) below the
    -- actual floor. FloorY is set at placement time to centerPos.Y, so
    -- it always points at the map's floor for this tower regardless of
    -- what extraneous bits ended up in the Model tree.
    local floorAttr = tower:GetAttribute("FloorY")
    if type(floorAttr) == "number" then
        minY = floorAttr
    end

    -- Lift the box bottom slightly above the floor so the bottom
    -- rectangle of the SelectionBox cube renders ON TOP of the
    -- floor instead of coplanar with it. Without this, the bottom
    -- edges sat exactly at FloorY, got z-fight-clipped by the
    -- plank surface, and the cube appeared to miss its floor face
    -- entirely. Per playtest 2026-04-26: "adjust selection vfx so
    -- the grid is visible above ground".
    local FLOOR_LIFT = 0.5
    minY = minY + FLOOR_LIFT

    local PAD = 0.15
    local centerX = (minX + maxX) / 2
    local centerZ = (minZ + maxZ) / 2
    local floorY  = minY + PAD

    -- Selection wireframe — full cube (matches multi-select style).
    -- Per playtest 2026-04-26: "the multi selection boxes are
    -- perfect. I want this the standard even for single selection."
    -- Replaces the prior 8-corner-bracket cage. Uses an invisible
    -- anchor part sized to the world-axis bounding box (computed
    -- above), with a SelectionBox adorned to it. Anchor is a Part
    -- (not the tower model itself) so the box always reads in
    -- world axes regardless of the tower model's bounding-box
    -- orientation (Power Tower has a rotated TowerBase cylinder
    -- that would tilt a model-adornee box).
    do
        local boxSize = Vector3.new(
            (maxX - minX) + PAD * 2,
            (maxY - minY) + PAD * 2,
            (maxZ - minZ) + PAD * 2)
        local anchor = Instance.new("Part")
        anchor.Name = "ToL_SelectionAnchor"
        anchor.Anchored = true
        anchor.CanCollide = false
        anchor.CanQuery = false
        anchor.CastShadow = false
        anchor.Transparency = 1
        anchor.Size = boxSize
        anchor.CFrame = CFrame.new(
            centerX,
            (minY + maxY) / 2,
            centerZ)
        anchor.Parent = selectionFolder

        local sb = Instance.new("SelectionBox")
        sb.Adornee = anchor
        sb.LineThickness = 0.08
        sb.Color3 = Color3.fromRGB(140, 240, 180)
        sb.SurfaceColor3 = Color3.fromRGB(120, 220, 150)
        sb.SurfaceTransparency = 0.85
        sb.Parent = anchor
    end

    -- Range circle on the floor (a thin neon ring approximated by many segments).
    -- Cheaper alternative: a single big disc with a ring texture, but custom
    -- segments are simpler and don't need an asset. Ring Y sits 0.35 above
    -- floorY so it clears path tiles (same offset as the placement ghost).
    local range = tower:GetAttribute("Range") or 30
    local SEGMENTS = 48
    local ringY = floorY + 0.35

    local function drawRing(radius, color, transparency)
        local segLen = (2 * math.pi * radius) / SEGMENTS
        for i = 0, SEGMENTS - 1 do
            local a = (i / SEGMENTS) * 2 * math.pi
            local x = centerX + math.cos(a) * radius
            local z = centerZ + math.sin(a) * radius
            local seg = Instance.new("Part")
            seg.Size = Vector3.new(segLen + 0.1, 0.12, 0.35)
            seg.CFrame = CFrame.new(x, ringY, z) * CFrame.Angles(0, -a + math.pi / 2, 0)
            seg.Anchored = true
            seg.CanCollide = false
            seg.CanQuery = false  -- don't block the bullseye mob-pick raycast
            seg.CastShadow = false
            seg.Material = Enum.Material.Neon
            seg.Color = color
            seg.Transparency = transparency
            seg.Parent = selectionFolder
        end
    end

    -- Firing-range ring (blue, primary).
    drawRing(range, Color3.fromRGB(80, 160, 255), 0.25)

    -- ea3-151 — Aura-zone fill (translucent blue disc) for any tower
    -- with a non-zero AuraRadius (aux Support buff towers PaceFlower/
    -- PowerSeed/SpyglassRoot at 18, plus SupportCore at 9999 =
    -- global). Visualizes "any tower whose footprint touches inside
    -- this disc gets the aura buff" — matches the new footprint-edge
    -- check in Towers.lua. Skipped for global auras (radius >= 9999)
    -- — drawing a 9999-stud disc would just paint the entire map.
    -- Skipped for towers with no aura.
    --
    -- Pre-fix, range and auraRadius coincidentally matched 18:18 for
    -- aux Supports, so the firing-range ring READ AS the aura zone.
    -- ea3-151's footprint-edge check made the effective aura ~33%
    -- bigger than the visible 18-stud ring; SpyglassRoot (range 26 /
    -- aura 18) had range > aura. The fill disambiguates: range ring
    -- = "where I shoot," blue fill = "where I buff allies."
    --
    -- Per Matthew 2026-05-01 "give the circle 10% transparency fill
    -- of blue" → Transparency = 0.9 (10% opaque) on the same blue as
    -- the firing-range ring.
    local auraRadius = tower:GetAttribute("AuraRadius") or 0
    if auraRadius > 0 and auraRadius < 9999 then
        local fill = Instance.new("Part")
        fill.Name = "ToL_AuraFill"
        fill.Shape = Enum.PartType.Cylinder
        fill.Anchored = true
        fill.CanCollide = false
        fill.CanQuery = false
        fill.CastShadow = false
        fill.Material = Enum.Material.Neon
        fill.Color = Color3.fromRGB(80, 160, 255)
        fill.Transparency = 0.9
        -- Cylinder axis runs along LOCAL X. For a flat floor disc:
        --   Size  = (thin_height, diameter, diameter)
        --   CFrame rotated 90° around Z so X points UP (axis vertical)
        fill.Size = Vector3.new(0.1, auraRadius * 2, auraRadius * 2)
        fill.CFrame = CFrame.new(centerX, ringY, centerZ)
            * CFrame.Angles(0, 0, math.rad(90))
        fill.Parent = selectionFolder
    end
end

return SelectionVisuals
