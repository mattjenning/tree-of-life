--[[
    ZoneRenderer.lua — Client-side renderer for ground-zone visuals
    (Honey Hive patches + Spore Puffball clouds + future zones).

    BACKGROUND:
    Server originally built the disc + 32-segment outline ring for
    each zone in workspace, replicating ~33 parts per zone via
    standard property replication. Per the 2026-04-28 perf pass,
    that path was retired — server now fires ZoneSpawned /
    ZoneRetinted / ZoneExpired RemoteEvents and clients do the
    Part instantiation locally.

    Wins:
      • Server stops paying the part-instantiation cost (33 parts
        × N patches/sec is real allocation pressure).
      • Per-client visual quality scaling: mobile / iPad clients
        read Config.Vfx.detail() and use 12 outline segments
        instead of 32 (or skip the outline entirely on "off"
        tier). PC stays at 32.
      • Honey + Spore visuals can diverge per-client without
        server changes (kind = "patch" / "spore" hook in payload).

    DEFENSIVE LIFETIMES:
    Each spawn schedules a backup task.delay(lifetime + 0.5)
    destroy so a dropped ZoneExpired event (network drop, late
    join) doesn't leak a part. Server's expire broadcast still
    fires and runs first under normal play.

    setup(deps): expects deps.ReplicatedStorage + deps.Remotes.
]]

local Workspace = game:GetService("Workspace")

local ZoneRenderer = {}

-- Same heat-color endpoints the server uses; matched here so the
-- ZoneRetinted event can pass the post-heat color directly.
-- Material/transparency settings stay constant per part — only
-- color shifts with heat level.
local DISC_TRANSPARENCY = 0.85
local OUTLINE_TRANSPARENCY = 0.1

function ZoneRenderer.setup(deps)
    local ReplicatedStorage = deps.ReplicatedStorage or game:GetService("ReplicatedStorage")
    local Remotes = deps.Remotes or require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
    local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

    local spawnedRemote = ReplicatedStorage:WaitForChild(Remotes.Names.ZoneSpawned)
    local retintRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.ZoneRetinted)
    local expiredRemote = ReplicatedStorage:WaitForChild(Remotes.Names.ZoneExpired)

    -- zoneId → disc Part. The outline segments live as named
    -- children of the disc, so destroying the disc cleans them up.
    local zoneParts = {}

    local function buildZoneVisual(payload)
        local detail = Config.Vfx.detail()
        local segments = (detail and detail.zoneOutlineSegments) or 32
        local color = payload.color or Color3.fromRGB(150, 220, 150)
        local position = payload.position
        local radius = payload.radius or 6

        local disc = Instance.new("Part")
        disc.Name = "ZoneDisc"
        disc.Shape = Enum.PartType.Cylinder
        disc.Size = Vector3.new(0.3, radius * 2, radius * 2)
        disc.Anchored = true
        disc.CanCollide = false
        disc.CastShadow = false
        disc.Material = Enum.Material.SmoothPlastic
        disc.Color = color
        disc.Transparency = DISC_TRANSPARENCY
        disc.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
        disc.Parent = Workspace

        if segments > 0 then
            local segLen = (2 * math.pi * radius) / segments + 0.05
            for i = 0, segments - 1 do
                local angle = (i / segments) * 2 * math.pi
                local cosA = math.cos(angle)
                local sinA = math.sin(angle)
                local px = position.X + cosA * radius
                local pz = position.Z + sinA * radius
                local seg = Instance.new("Part")
                seg.Name = "ZoneOutline"
                seg.Anchored = true
                seg.CanCollide = false
                seg.CastShadow = false
                seg.Size = Vector3.new(0.4, 0.4, segLen)
                seg.CFrame = CFrame.lookAt(
                    Vector3.new(px, position.Y + 0.25, pz),
                    Vector3.new(px - sinA, position.Y + 0.25, pz + cosA))
                seg.Material = Enum.Material.Neon
                seg.Color = color
                seg.Transparency = OUTLINE_TRANSPARENCY
                seg.Parent = disc
            end
        end
        return disc
    end

    local function destroyZone(zoneId)
        local disc = zoneParts[zoneId]
        if disc then
            zoneParts[zoneId] = nil
            if disc.Parent then disc:Destroy() end
        end
    end

    spawnedRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" or type(payload.zoneId) ~= "number" then return end
        -- Defensive: tear down any stale entry on the same id (server
        -- ids monotonic; collision implies missed Expired event).
        destroyZone(payload.zoneId)
        local disc = buildZoneVisual(payload)
        zoneParts[payload.zoneId] = disc
        -- Backup expire — destroys this part if the server's
        -- ZoneExpired event never arrives. lifetime + 0.5 grace so
        -- the server-driven expire (which runs first under normal
        -- play) doesn't race the backup.
        local lifetime = payload.lifetime or 2
        task.delay(lifetime + 0.5, function()
            if zoneParts[payload.zoneId] == disc then
                destroyZone(payload.zoneId)
            end
        end)
    end)

    retintRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" or type(payload.zoneId) ~= "number" then return end
        local disc = zoneParts[payload.zoneId]
        if not disc or not disc.Parent then return end
        local color = payload.color
        if not color then return end
        disc.Color = color
        for _, child in ipairs(disc:GetChildren()) do
            if child:IsA("Part") and child.Name == "ZoneOutline" then
                child.Color = color
            end
        end
    end)

    expiredRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" or type(payload.zoneId) ~= "number" then return end
        destroyZone(payload.zoneId)
    end)
end

return ZoneRenderer
