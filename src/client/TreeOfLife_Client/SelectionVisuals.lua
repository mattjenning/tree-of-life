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

    -- Compute a WORLD-AXIS bounding box by scanning descendants. We can't
    -- rely on Model:GetBoundingBox — when the Model has no PrimaryPart it
    -- falls back to the first child's orientation, which for the Power
    -- Tower means the TowerBase cylinder's rotated CFrame. That made the
    -- cage hang sideways ("oriented incorrectly"). Manual min/max over
    -- every Part's eight world corners gives a proper axis-aligned cage
    -- around Core and Aux alike.
    local minX, minY, minZ =  math.huge,  math.huge,  math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for _, desc in ipairs(tower:GetDescendants()) do
        if desc:IsA("BasePart") then
            local cf, sz = desc.CFrame, desc.Size
            for dx = -1, 1, 2 do
                for dy = -1, 1, 2 do
                    for dz = -1, 1, 2 do
                        local corner = cf:PointToWorldSpace(Vector3.new(
                            sz.X * 0.5 * dx,
                            sz.Y * 0.5 * dy,
                            sz.Z * 0.5 * dz))
                        if corner.X < minX then minX = corner.X end
                        if corner.Y < minY then minY = corner.Y end
                        if corner.Z < minZ then minZ = corner.Z end
                        if corner.X > maxX then maxX = corner.X end
                        if corner.Y > maxY then maxY = corner.Y end
                        if corner.Z > maxZ then maxZ = corner.Z end
                    end
                end
            end
        end
    end
    if minX == math.huge then return end  -- no parts found

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

    -- Inflate X/Z a hair so brackets don't z-fight the model's surface.
    -- Y gets a SMALL upward nudge from the tower bottom instead of padding
    -- down — the tower's minY is typically the floor, so extending below
    -- would bury the bottom brackets.
    local PAD = 0.15
    local centerX = (minX + maxX) / 2
    local centerZ = (minZ + maxZ) / 2
    local halfX   = (maxX - minX) / 2 + PAD
    local halfZ   = (maxZ - minZ) / 2 + PAD
    local floorY  = minY + PAD
    local topY    = maxY + PAD

    -- 8 corner brackets forming a 3D cage around the tower. Each corner
    -- has three short bars along ±X, ±Y, ±Z — same scheme as a 3D editor
    -- bounds widget. Bar axes are controlled by dx/dy/dz signs per corner.
    -- Bracket size scaled 50% to match the tower's visual downscale —
    -- old 1.5-stud bars read as huge next to a half-scale Power Tower.
    local bracketLen = 0.75
    local bracketThickness = 0.12
    local bracketColor = Color3.fromRGB(120, 255, 150)

    local function makeBar(x1, y1, z1, x2, y2, z2)
        local lenX = math.abs(x2 - x1)
        local lenY = math.abs(y2 - y1)
        local lenZ = math.abs(z2 - z1)
        local p = Instance.new("Part")
        p.Anchored = true
        p.CanCollide = false
        p.CastShadow = false
        p.CanQuery = false  -- don't block the bullseye mob-pick raycast
        p.Material = Enum.Material.Neon
        p.Color = bracketColor
        p.Transparency = 0.1
        p.Size = Vector3.new(
            math.max(lenX, bracketThickness),
            math.max(lenY, bracketThickness),
            math.max(lenZ, bracketThickness))
        p.CFrame = CFrame.new((x1 + x2) / 2, (y1 + y2) / 2, (z1 + z2) / 2)
        p.Parent = selectionFolder
    end

    -- 8 corners: (sign of X, sign of Y picking floor vs top, sign of Z)
    -- For each corner, dx/dy/dz point INWARD so each bar extends from the
    -- corner toward the cage interior.
    local corners = {
        {centerX - halfX, floorY, centerZ - halfZ,  1,  1,  1},  -- bottom NW
        {centerX + halfX, floorY, centerZ - halfZ, -1,  1,  1},  -- bottom NE
        {centerX - halfX, floorY, centerZ + halfZ,  1,  1, -1},  -- bottom SW
        {centerX + halfX, floorY, centerZ + halfZ, -1,  1, -1},  -- bottom SE
        {centerX - halfX, topY,   centerZ - halfZ,  1, -1,  1},  -- top NW
        {centerX + halfX, topY,   centerZ - halfZ, -1, -1,  1},  -- top NE
        {centerX - halfX, topY,   centerZ + halfZ,  1, -1, -1},  -- top SW
        {centerX + halfX, topY,   centerZ + halfZ, -1, -1, -1},  -- top SE
    }
    for _, c in ipairs(corners) do
        local cx, cy, cz, dx, dy, dz = c[1], c[2], c[3], c[4], c[5], c[6]
        makeBar(cx, cy, cz, cx + dx * bracketLen, cy, cz)                -- X arm
        makeBar(cx, cy, cz, cx, cy + dy * bracketLen, cz)                -- Y arm
        makeBar(cx, cy, cz, cx, cy, cz + dz * bracketLen)                -- Z arm
    end

    -- Range circle on the floor (a thin neon ring approximated by many segments).
    -- Cheaper alternative: a single big disc with a ring texture, but custom
    -- segments are simpler and don't need an asset. Ring Y sits 0.35 above
    -- floorY so it clears path tiles (same offset as the placement ghost).
    local range = tower:GetAttribute("Range") or 30
    local SEGMENTS = 48
    local segLen = (2 * math.pi * range) / SEGMENTS
    local ringY = floorY + 0.35
    for i = 0, SEGMENTS - 1 do
        local a = (i / SEGMENTS) * 2 * math.pi
        local x = centerX + math.cos(a) * range
        local z = centerZ + math.sin(a) * range
        local seg = Instance.new("Part")
        seg.Size = Vector3.new(segLen + 0.1, 0.12, 0.35)
        seg.CFrame = CFrame.new(x, ringY, z) * CFrame.Angles(0, -a + math.pi / 2, 0)
        seg.Anchored = true
        seg.CanCollide = false
        seg.CanQuery = false  -- don't block the bullseye mob-pick raycast
        seg.CastShadow = false
        seg.Material = Enum.Material.Neon
        seg.Color = Color3.fromRGB(80, 160, 255)
        seg.Transparency = 0.25
        seg.Parent = selectionFolder
    end
end

return SelectionVisuals
