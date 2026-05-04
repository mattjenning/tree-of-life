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

    HEAT MECHANIC (Spore-only, 2026-04-27):
    Spore zones can opt in to overlap-heat (`enableHeat = true` in
    spawnZone params). When two heat-enabled zones overlap such that
    their centers are within `(r1+r2) × OVERLAP_FRACTION`, both zones
    gain +1 heatLevel (mutual). Heat scales tickDmg via HEAT_MULT
    table AND brightens the visual disc + outline. On expire, heat
    is decremented from each formerly-overlapping zone (clean
    bookkeeping). Honey patches DO NOT enable heat — keeps the slow-
    and-tick mechanic from compounding in unintended ways.

    LIMITATIONS (intentional):
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
local MobUtil = require(Shared:WaitForChild("MobUtil"))
local StatLedger = require(script.Parent:WaitForChild("StatLedger"))

local Zones = {}

-- Heat curve constants (Spore overlap mechanic, 2026-04-27).
-- Damage multiplier indexed by heatLevel; clamps at HEAT_CAP so a
-- dense Spore-trio cluster can't runaway-multiply.
local HEAT_DAMAGE_MULT = { 1.0, 1.4, 1.8, 2.2 }
local HEAT_CAP         = 4
-- Centers within (r1+r2) × OVERLAP_FRACTION are treated as
-- "meaningfully overlapping" for heat purposes. 0.7 = ≥30% area
-- overlap; tuned so adjacent-but-not-stacked clouds DON'T heat
-- (avoids "heat 2 just because two clouds touch at the edge").
local OVERLAP_FRACTION = 0.7
-- Visual color/transparency endpoints — heat 1 (no overlap) renders
-- the base spore-green at full transparency; heat HEAT_CAP renders
-- a brighter pale-yellow-green at lower transparency. Linearly
-- interpolated for intermediate heats.
local HEAT_COLOR_BASE  = Color3.fromRGB(140, 230, 140)
local HEAT_COLOR_HOT   = Color3.fromRGB(255, 255, 180)
local HEAT_TRANS_BASE  = 0.85
local HEAT_TRANS_HOT   = 0.70

local function colorForHeat(heatLevel)
    local hl = math.min(heatLevel, HEAT_CAP)
    if HEAT_CAP <= 1 then return HEAT_COLOR_BASE, HEAT_TRANS_BASE end
    local t = (hl - 1) / (HEAT_CAP - 1)
    return HEAT_COLOR_BASE:Lerp(HEAT_COLOR_HOT, t),
           HEAT_TRANS_BASE + (HEAT_TRANS_HOT - HEAT_TRANS_BASE) * t
end

local function damageMultForHeat(heatLevel)
    return HEAT_DAMAGE_MULT[math.min(math.max(1, heatLevel), HEAT_CAP)]
end

-- Cached on first lookup since the remote isn't created until
-- Remotes.getOrCreate runs in setup().
local retintRemote = nil

local function retintZoneVisual(zone)
    -- Server-side visuals were retired 2026-04-28 — the disc + 32-
    -- segment outline now render client-side via ZoneRenderer.lua.
    -- Heat re-tint becomes a RemoteEvent broadcast: server tells
    -- every client "zoneId X's color is now Y", client looks up
    -- its local part and repaints. Honey patches (enableHeat=false)
    -- never re-tint so they don't fire.
    if not zone.enableHeat then return end
    if not retintRemote then
        retintRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.ZoneRetinted)
    end
    if not retintRemote then return end
    local color = colorForHeat(zone.heatLevel)
    retintRemote:FireAllClients({
        zoneId = zone.id,
        color  = color,
    })
end

function Zones.setup(ctx)
    local zones = {}

    -- Server-side visuals retired 2026-04-28 — the disc + 32-segment
    -- outline ring is rendered client-side via
    -- src/client/TreeOfLife_Client/ZoneRenderer.lua. Server fires
    -- ZoneSpawned / ZoneRetinted / ZoneExpired RemoteEvents; clients
    -- subscribe and build / re-tint / destroy their local parts.
    -- Wins:
    --   • No 33 server parts per zone (~33 × patches/sec at busy
    --     Honey loadouts = 100s of parts/sec server-side allocation
    --     eliminated).
    --   • Tier-aware client rendering: low-tier (mobile / iPad)
    --     uses 12 outline segments instead of 32; off-tier skips
    --     the outline entirely. See Config.Vfx.Tiers.
    --   • Per-client visual quality possible (PC = high, iPad = low,
    --     server math = unchanged).

    -- Per-zone unique id. Used by the client to look up its locally-
    -- spawned part and re-tint / destroy on the server's matching
    -- ZoneRetinted / ZoneExpired event.
    local nextZoneId = 0

    -- Cached remotes; created in setup() below before any spawn.
    local zoneSpawnedRemote = Remotes.getOrCreate(Remotes.Names.ZoneSpawned, "RemoteEvent")
    local zoneExpiredRemote = Remotes.getOrCreate(Remotes.Names.ZoneExpired, "RemoteEvent")
    -- Initialize the retint remote so retintZoneVisual's lazy-lookup
    -- finds it on the first call.
    Remotes.getOrCreate(Remotes.Names.ZoneRetinted, "RemoteEvent")

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
        nextZoneId = nextZoneId + 1
        local zone = {
            id           = nextZoneId,
            position     = params.position,
            radius       = params.radius or 6,
            color        = params.color or Color3.fromRGB(150, 220, 150),
            expiresAt    = os.clock() + lifetime,
            tickDmg      = params.tickDmg or 0,
            tickInterval = 1 / tickPerSec,
            nextTickAt   = os.clock() + (1 / tickPerSec),
            slowPct      = params.slowPct,
            slowDuration = params.slowDuration or 0.5,
            sourceTower  = params.sourceTower,
            -- Heat mechanic state (Spore overlap, 2026-04-27).
            -- enableHeat opts in; Honey patches don't pass it.
            -- heatLevel starts at 1 (no overlap); overlapping is
            -- a set of zones currently sharing heat with this one.
            enableHeat   = params.enableHeat == true,
            heatLevel    = 1,
            overlapping  = {},
        }
        -- Skip the client-render broadcast when math-only mode is on
        -- (high speeds on Map 4) — damage / slow logic still ticks
        -- via the Heartbeat loop below, but no visual spawns. Per
        -- Matthew 2026-04-26: "honey hive ground effects still
        -- showing up at high speeds."
        if not ctx.mathOnlyMode then
            -- Tell every client to render the zone visual locally.
            -- Each client picks segment count from Config.Vfx tier
            -- (mobile gets 12 segments instead of 32; "off" tier
            -- skips entirely).
            zoneSpawnedRemote:FireAllClients({
                zoneId   = zone.id,
                position = zone.position,
                radius   = zone.radius,
                color    = zone.color,
                lifetime = lifetime,
                kind     = params.kind or (zone.enableHeat and "spore" or "patch"),
            })
        end

        -- Heat overlap detection (2026-04-27). Walks existing zones
        -- BEFORE inserting this one (so we don't self-match). Mutual
        -- bump on both sides — new zone AND existing zone gain heat.
        -- Re-tints the existing zone's visual to reflect its new
        -- heat. Honey patches (enableHeat=false) skip this entirely.
        if zone.enableHeat then
            for _, other in ipairs(zones) do
                if other.enableHeat then
                    local d = (other.position - zone.position).Magnitude
                    local threshold = (other.radius + zone.radius) * OVERLAP_FRACTION
                    if d < threshold then
                        zone.overlapping[other] = true
                        other.overlapping[zone] = true
                        zone.heatLevel = zone.heatLevel + 1
                        other.heatLevel = other.heatLevel + 1
                        retintZoneVisual(other)
                    end
                end
            end
            -- Re-tint own visual to reflect initial heat. Heat-1
            -- zones get the same color as before; heat-2+ zones
            -- spawn already pre-brightened.
            retintZoneVisual(zone)
        end

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
                -- Tell clients to destroy their local visual. Server
                -- side has no Part to clean up anymore (visuals moved
                -- to client 2026-04-28). Clients also have a defensive
                -- task.delay(lifetime) destroy on each spawn so a
                -- missed Expired event (network drop) still cleans up.
                zoneExpiredRemote:FireAllClients({ zoneId = z.id })
                -- Heat decrement broadcast (2026-04-27 Spore mechanic).
                -- Walk every zone we'd been heat-sharing with, drop
                -- their heat by 1 (floor at 1), and clear the back-
                -- reference. Re-tint to fade their visual back. Only
                -- runs for heat-enabled zones (Honey patches' empty
                -- `overlapping` set just iterates zero times).
                for other in pairs(z.overlapping) do
                    if other.heatLevel > 1 then
                        other.heatLevel = other.heatLevel - 1
                    end
                    other.overlapping[z] = nil
                    retintZoneVisual(other)
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
                -- Heat damage multiplier (Spore-only via enableHeat).
                -- Heat 1 = 1.0×, Heat 2 = 1.4×, Heat 3 = 1.8×, Heat 4+ = 2.2×.
                -- Non-heat zones (Honey) always pass at 1.0×.
                local heatMult = z.enableHeat and damageMultForHeat(z.heatLevel) or 1.0
                for _, entry in ipairs(hit) do
                    if z.tickDmg and z.tickDmg > 0 then
                        ctx.damageMob(entry.mob, z.tickDmg * heatMult, z.sourceTower)
                    end
                    if z.slowPct and z.slowPct > 0 and z.sourceTower then
                        -- Per-source slow: zone applies as if it were
                        -- a hit from z.sourceTower (HoneyHive). Each
                        -- HoneyHive tower has its own slow entry on
                        -- the mob — multiple Hives slowing the same
                        -- mob each get separate timers. See MobUtil
                        -- for full mechanic.
                        local gameNow = ctx.gameTime or 0
                        MobUtil.applySlow(entry.data, z.sourceTower, z.slowPct, z.slowDuration, gameNow)
                        -- StatLedger: zone slows credited to the zone's
                        -- source tower (HoneyHive). Slow-value uses the
                        -- per-tick duration so a sustained zone hit on
                        -- a mob that re-ticks accumulates over time.
                        StatLedger.recordSlow(z.sourceTower, 1 - z.slowPct, z.slowDuration)
                        MobUtil.refreshSlowVisual(entry.mob, entry.data, gameNow)
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
                zoneExpiredRemote:FireAllClients({ zoneId = z.id })
            end
            table.clear(zones)
        end)
    end

    ctx.spawnZone = spawnZone
end

return Zones
