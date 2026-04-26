--[[
    Zones.lua — Persistent ground zones that tick damage and/or apply slow
    to mobs inside them. Used by two temp towers so far:
      - Honey Hive: sticky gold patches (tick damage + slow)
      - Spore Puffball: poison clouds (tick damage, no slow)

    MODEL:
    A zone is a point + radius + lifetime + per-second tick. Every tick,
    each mob in the activeMobs table whose distance to the zone center
    is <= radius takes tickDmg damage and (if slowPct set) gets a fresh
    slow window. Slow refreshes while the mob stays inside — leaving the
    zone lets the slow expire.

    VISUAL:
    One flat neon cylinder part at the zone's world position, sized to
    the radius, tinted by the `color` param. No fancy particles yet —
    simple reads well and doesn't thrash the render when several zones
    stack. Vertical position follows the zone's base Y (passed in).

    LIFECYCLE:
    Zones live in a module-local list. A Heartbeat loop iterates the
    list each frame, ticks due zones, and destroys expired ones (visual
    + list entry). Adding a zone is O(1); per-frame cost is O(zones ×
    mobsInRange), which is fine at this scale.

    LIMITATIONS (intentional):
    - Zones do NOT stack damage if the player drops two patches on the
      same spot — each ticks independently, which is fine (more damage).
    - Zones do NOT apply to Phoenix-captured mobs (they're already frozen
      + pending respawn; ticking them would be weird).

    setup(ctx) reads:
      ctx.activeMobs, ctx.damageMob, ctx.gameSpeed

    Publishes:
      ctx.spawnZone(params)
--]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local StatLedger = require(script.Parent:WaitForChild("StatLedger"))

local Zones = {}

function Zones.setup(ctx)
    local zones = {}

    -- Build the flat cylinder visual for a zone. Separated so the
    -- spawn path stays readable.
    local function buildZoneVisual(position, radius, color)
        -- Per playtest 2026-04-26: honey-hive / spore-puff zones
        -- read overwhelming with Neon material at Transparency 0.55.
        -- Toned down to SmoothPlastic at 0.85 (much more see-through,
        -- no glow). To keep the zone EDGE readable, a brighter Neon
        -- ring (cylinder + segmented outline) sits on top of the
        -- main disc — same "translucent fill + sharp outline"
        -- pattern the smash circle uses.
        local zoneColor = color or Color3.fromRGB(150, 220, 150)
        local disc = Instance.new("Part")
        disc.Name = "ZoneDisc"
        disc.Shape = Enum.PartType.Cylinder
        disc.Size = Vector3.new(0.3, radius * 2, radius * 2)
        disc.Anchored = true
        disc.CanCollide = false
        disc.CastShadow = false
        disc.Material = Enum.Material.SmoothPlastic
        disc.Color = zoneColor
        disc.Transparency = 0.85
        disc.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
        disc.Parent = workspace

        -- Highlighted outline: 32 short tangential bar segments at
        -- the zone perimeter, fully opaque Neon. Children of `disc`
        -- so they auto-clean when the zone expires + the disc is
        -- destroyed. ~32 segments approximates a smooth ring at
        -- typical zone radii (4-12 stud).
        local SEGMENTS = 32
        local segLen = (2 * math.pi * radius) / SEGMENTS + 0.05
        for i = 0, SEGMENTS - 1 do
            local angle = (i / SEGMENTS) * 2 * math.pi
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
            seg.Color = zoneColor
            seg.Transparency = 0.1
            seg.Parent = disc
        end
        return disc
    end

    -- Accepted params:
    --   position      : Vector3  — world position (centered on floor)
    --   radius        : number   — studs
    --   lifetime      : number   — seconds (wallclock, will scale with gameSpeed? no — kept
    --                              wallclock for simplicity; tick cadence also wallclock)
    --   tickDmg       : number?  — damage per tick (can be 0 for slow-only patches)
    --   tickPerSec    : number?  — ticks per second (default 1)
    --   slowPct       : number?  — 0..1; present = mobs inside are slowed
    --   slowDuration  : number?  — seconds (default 0.5) — short; refreshed each tick
    --                              so mobs inside stay slowed but mobs that leave
    --                              quickly recover
    --   color         : Color3?  — visual tint
    --   sourceTower   : Model?   — passed to damageMob for upgrade/attachment hooks
    local function spawnZone(params)
        local lifetime   = params.lifetime or 2
        local tickPerSec = params.tickPerSec or 1
        local zone = {
            position     = params.position,
            radius       = params.radius or 6,
            expiresAt    = os.clock() + lifetime,
            tickDmg      = params.tickDmg or 0,
            tickInterval = 1 / tickPerSec,
            nextTickAt   = os.clock() + (1 / tickPerSec),
            slowPct      = params.slowPct,
            slowDuration = params.slowDuration or 0.5,
            sourceTower  = params.sourceTower,
        }
        zone.visual = buildZoneVisual(zone.position, zone.radius, params.color)
        table.insert(zones, zone)
    end

    -- Heartbeat: tick zones, expire zones, apply effects. Iterates in
    -- reverse so we can table.remove safely.
    RunService.Heartbeat:Connect(function(_dt)
        if #zones == 0 then return end
        local now = os.clock()
        for i = #zones, 1, -1 do
            local z = zones[i]
            if now >= z.expiresAt then
                if z.visual and z.visual.Parent then
                    z.visual:Destroy()
                end
                table.remove(zones, i)
            elseif now >= z.nextTickAt then
                -- Build a snapshot of in-range mobs first so damageMob's
                -- potential mob-destroying side effects don't mutate the
                -- table while we iterate.
                local hit = {}
                for mob, data in pairs(ctx.activeMobs) do
                    if mob.Parent then
                        local d = (mob.Position - z.position).Magnitude
                        if d <= z.radius then
                            table.insert(hit, { mob = mob, data = data })
                        end
                    end
                end
                for _, entry in ipairs(hit) do
                    if z.tickDmg and z.tickDmg > 0 then
                        ctx.damageMob(entry.mob, z.tickDmg, z.sourceTower)
                    end
                    if z.slowPct and z.slowPct > 0 then
                        entry.data.slowUntil = now + (z.slowDuration / ctx.gameSpeed)
                        entry.data.slowMult  = 1 - z.slowPct
                        -- StatLedger: zone slows credited to the zone's
                        -- source tower (HoneyHive). Slow-value uses the
                        -- per-tick duration so a sustained zone hit on
                        -- a mob that re-ticks accumulates over time.
                        StatLedger.recordSlow(z.sourceTower, 1 - z.slowPct, z.slowDuration)
                    end
                end
                z.nextTickAt = now + z.tickInterval
            end
        end
    end)

    -- Clear active zones on run reset so stale visuals don't linger into
    -- the next run. ClearAllMobs already wipes mob references, but the
    -- zone parts persist until their lifetime expires — removing them
    -- proactively keeps the world clean on reset.
    local runResetBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.RunReset)
    if runResetBindable then
        runResetBindable.Event:Connect(function()
            for _, z in ipairs(zones) do
                if z.visual and z.visual.Parent then
                    z.visual:Destroy()
                end
            end
            table.clear(zones)
        end)
    end

    ctx.spawnZone = spawnZone
end

return Zones
