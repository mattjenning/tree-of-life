--!strict
--[[
    BBoxUtil.lua — world-axis-aligned bounding box helpers.

    Why not Model:GetBoundingBox?  When a Model has no PrimaryPart,
    GetBoundingBox falls back to the FIRST CHILD's orientation. For
    Power Tower the first child is a Z-rotated cylinder, so the
    returned box hangs sideways and tests / VFX placement land
    visibly wrong. Sweeping every BasePart descendant's 8 corners
    through PointToWorldSpace and taking the world-axis min/max gives
    a proper axis-aligned box regardless of part orientations.

    Used by:
      - towerUnderScreenPos (click hit-test) in init.client.lua
      - SelectionVisuals.build (selection cube + range ring)
      - TowerPlacement.lua (re-seat tower so its bottom sits at FloorY)

    All three were pasting the same descendant-sweep block; this
    module collapses them.

    API:
      BBoxUtil.worldAxisBounds(model: Instance) → Vector3?, Vector3?
        Returns (min, max) Vectors enclosing every BasePart descendant.
        Both are nil when the model has no BasePart descendants.

      BBoxUtil.worldAxisFloorY(model: Instance) → number?
        Convenience for the common "lowest world-Y" case (used at
        tower-placement re-seat time). Returns nil if no parts found.
]]

local BBoxUtil = {}

function BBoxUtil.worldAxisBounds(model: Instance): (Vector3?, Vector3?)
    local minX, minY, minZ =  math.huge,  math.huge,  math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    local any = false
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") then
            any = true
            local cf, sz = desc.CFrame, desc.Size
            for ox = -1, 1, 2 do
                for oy = -1, 1, 2 do
                    for oz = -1, 1, 2 do
                        local cw = cf:PointToWorldSpace(Vector3.new(
                            sz.X * 0.5 * ox,
                            sz.Y * 0.5 * oy,
                            sz.Z * 0.5 * oz))
                        if cw.X < minX then minX = cw.X end
                        if cw.Y < minY then minY = cw.Y end
                        if cw.Z < minZ then minZ = cw.Z end
                        if cw.X > maxX then maxX = cw.X end
                        if cw.Y > maxY then maxY = cw.Y end
                        if cw.Z > maxZ then maxZ = cw.Z end
                    end
                end
            end
        end
    end
    if not any then return nil, nil end
    return Vector3.new(minX, minY, minZ), Vector3.new(maxX, maxY, maxZ)
end

function BBoxUtil.worldAxisFloorY(model: Instance): number?
    local minY = math.huge
    local any = false
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") then
            any = true
            local cf, sz = desc.CFrame, desc.Size
            for ox = -1, 1, 2 do
                for oy = -1, 1, 2 do
                    for oz = -1, 1, 2 do
                        local cw = cf:PointToWorldSpace(Vector3.new(
                            sz.X * 0.5 * ox,
                            sz.Y * 0.5 * oy,
                            sz.Z * 0.5 * oz))
                        if cw.Y < minY then minY = cw.Y end
                    end
                end
            end
        end
    end
    if not any then return nil end
    return minY
end

return BBoxUtil
