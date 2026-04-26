--[[
    CanopySpiderBoss.lua — Map 2 boss web-attack mechanic. (File name kept
    for Git history; the mob is the Web Weaver per the canonical boss
    naming — see memory/project_boss_names.md.)

    THE FIGHT:
    The Web Weaver (mob type `canopyspider`) is slow, tanky, and
    every 15 seconds PAUSES to spit webs at the player's towers. Each
    web is a projectile with a tappable target; the player has ~2.5s
    to tap the target before the web lands. If they miss, the target
    tower gets locked out of firing for 3 seconds (tower-level stun).

    FLOW PER WEB ATTACK:
      1. Boss HP > 0 and 15s has elapsed since last attack (or since spawn).
      2. Freeze boss movement for 2.5s (BossWebbing attribute — MobUpdate
         reads this and skips the pathing step).
      3. Pick up to 3 owned tower targets at random (skip already-webbed).
      4. For each target, spawn a web Part tagged SpiderWeb with a unique
         WebId attribute. The client auto-attaches a tap-target BillboardGui
         to anything tagged SpiderWeb.
      5. Animate the web from the boss up and over to the target tower
         (arc trajectory, 2.5s flight time).
      6. On tap (TapSpiderWeb remote with WebId) OR on flight-end:
            - Tapped → destroy web, no effect
            - Flight ended + not tapped → destroy web, apply
              WebbedUntil = now + 3 to the target tower
      7. Wait 15s, repeat.

    DEPENDENCIES:
    - ctx.activeMobs (to find the canopyspider in play)
    - Tower ownership tracked via `Owner` attribute + Tags.Tower
    - Towers.lua checks `WebbedUntil` in fire loop (added inline).
    - Client system renders web targets + webbed-tower overlays.

    setup(ctx) reads:
      ctx.activeMobs (late-resolved)

    Publishes: nothing on ctx; all communication via Remotes/Tags.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Remotes  = require(Shared:WaitForChild("Remotes"))
local Tags     = require(Shared:WaitForChild("Tags"))
local Config   = require(Shared:WaitForChild("Config"))
local GameTime = require(Shared:WaitForChild("GameTime"))

local CanopySpiderBoss = {}

-- Tuning lives in Config.Map2.WebWeaver so balance can be adjusted
-- without touching code. Read once at module load — these are set at
-- server boot and don't change during play.
local CW_CFG = Config.Map2 and Config.Map2.WebWeaver or {}
local WEB_ATTACK_INTERVAL_SEC = CW_CFG.WebAttackIntervalSec or 15
local WEB_COUNT_PER_ATTACK    = CW_CFG.WebCountPerAttack    or 3
local WEB_FLIGHT_SEC          = CW_CFG.WebFlightSec         or 2.5
-- Landed webs stay on the tower permanently and require this many taps
-- to clear. Auto-expiry was removed (used to be TOWER_WEBBED_DURATION
-- seconds) — per design, losing a tower to a web is a commitment the
-- player has to actively undo.
local LANDED_WEB_TAPS_TO_CLEAR = CW_CFG.LandedWebTapsToClear or 5

-- Module-local registry of active webs, indexed by WebId string. Each entry:
--   { part, targetTower, landsAt, resolved = bool }
local activeWebs = {}
local nextWebId = 0

local function makeWebPart(startPos, color, webId)
    local web = Instance.new("Part")
    web.Name = "SpiderWeb"
    web.Shape = Enum.PartType.Ball
    -- Bigger click target than the old 2.5: ClickDetector uses the Part's
    -- actual geometry for hit-testing, so a larger ball = easier to tap
    -- even mid-arc. Still visually lightweight at Transparency 0.15.
    web.Size = Vector3.new(4, 4, 4)
    web.Anchored = true
    web.CanCollide = false
    web.CastShadow = false
    web.Material = Enum.Material.Neon
    web.Color = color or Color3.fromRGB(240, 240, 255)
    web.Transparency = 0.15
    web.CFrame = CFrame.new(startPos)
    if webId then
        web:SetAttribute("WebId", webId)
    end
    -- Server-side ClickDetector. The earlier BillboardGui + TextButton
    -- approach was silently failing on map 2 (the button would render
    -- but clicks didn't reach the server). ClickDetector hit-tests the
    -- 3D Part directly and fires MouseClick on the server — no client
    -- wiring, no remote hop. MaxActivationDistance set way out so
    -- players don't have to chase the web across the room.
    local cd = Instance.new("ClickDetector")
    cd.MaxActivationDistance = 500
    cd.Parent = web
    web.Parent = workspace
    CollectionService:AddTag(web, Tags.SpiderWeb)
    return web
end

-- Pick up to N random player-owned towers that are NOT currently webbed.
-- Returns a list of Model references. Order is randomized.
local function pickWebTargets(n)
    local candidates = {}
    local now = os.clock()
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local tower = base.Parent
        if tower and tower.Parent then
            local webbedUntil = tower:GetAttribute("WebbedUntil") or 0
            if now >= webbedUntil then
                table.insert(candidates, tower)
            end
        end
    end
    -- Fisher-Yates partial shuffle
    for i = #candidates, 2, -1 do
        local j = math.random(1, i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end
    local picks = {}
    for i = 1, math.min(n, #candidates) do
        table.insert(picks, candidates[i])
    end
    return picks
end

-- Spawn one web projectile, animate it over WEB_FLIGHT_SEC seconds from
-- `startPos` to the target tower's current position. Resolve via tap or
-- flight-end.
local function spawnWeb(startPos, targetTower)
    if not targetTower or not targetTower.Parent then return end
    local baseTarget = targetTower:FindFirstChild("TowerBase")
        or targetTower:FindFirstChildWhichIsA("BasePart")
    if not baseTarget then return end

    nextWebId = nextWebId + 1
    local webId = tostring(nextWebId)

    local endPos = baseTarget.Position + Vector3.new(0, 5, 0)
    local web = makeWebPart(startPos, nil, webId)
    web:SetAttribute("TargetTowerName", targetTower.Name)

    activeWebs[webId] = {
        part            = web,
        targetTower     = targetTower,
        landsAt         = os.clock() + WEB_FLIGHT_SEC,
        resolved        = false,  -- true once the web is gone (popped or cleared)
        landed          = false,  -- true once it sticks to the tower
        tapsRemaining   = LANDED_WEB_TAPS_TO_CLEAR,  -- countdown once landed
    }

    -- Wire the ClickDetector: one click pops the in-flight web. Landed
    -- webs are destroyed at land-time so this detector only ever fires
    -- for in-flight taps.
    local cd = web:FindFirstChildOfClass("ClickDetector")
    if cd then
        cd.MouseClick:Connect(function(player)
            local state = activeWebs[webId]
            if not state or state.resolved or state.landed then return end
            state.resolved = true
            -- Pop visual: spawn a burst of small radial spark parts at
            -- the web's position before destroying it. Reads as "you hit
            -- it!" feedback — otherwise the web silently disappears and
            -- the player isn't sure they did anything.
            local popPos = state.part and state.part.Position
            if state.part and state.part.Parent then state.part:Destroy() end
            activeWebs[webId] = nil
            if popPos then
                for i = 1, 10 do
                    local a = (i / 10) * math.pi * 2
                    local dir = Vector3.new(math.cos(a), math.random() * 0.5, math.sin(a))
                    local spark = Instance.new("Part")
                    spark.Shape = Enum.PartType.Ball
                    spark.Size = Vector3.new(0.6, 0.6, 0.6)
                    spark.Anchored = true
                    spark.CanCollide = false
                    spark.CastShadow = false
                    spark.CanQuery = false
                    spark.Material = Enum.Material.Neon
                    spark.Color = Color3.fromRGB(240, 240, 255)
                    spark.Transparency = 0.1
                    spark.CFrame = CFrame.new(popPos)
                    spark.Parent = workspace
                    local start = popPos
                    local target = popPos + dir * 4
                    local t0 = os.clock()
                    task.spawn(function()
                        while os.clock() - t0 < 0.4 do
                            if not spark.Parent then return end
                            local t = (os.clock() - t0) / 0.4
                            spark.CFrame = CFrame.new(start:Lerp(target, t))
                            spark.Transparency = 0.1 + t * 0.9
                            RunService.Heartbeat:Wait()
                        end
                        if spark.Parent then spark:Destroy() end
                    end)
                end
            end
            print(("[CanopySpider] %s popped web %s in-flight (ClickDetector)"):format(
                player.Name, webId))
        end)
    end

    -- Arc flight via quadratic bezier with an elevated midpoint so the
    -- web visibly sails over obstacles.
    local mid = startPos:Lerp(endPos, 0.5) + Vector3.new(0, 20, 0)
    task.spawn(function()
        local startT = os.clock()
        while os.clock() - startT < WEB_FLIGHT_SEC do
            local state = activeWebs[webId]
            if not state or state.resolved then break end
            if not web.Parent then break end
            local t = math.min(1, (os.clock() - startT) / WEB_FLIGHT_SEC)
            local p = (1 - t)^2 * startPos + 2 * (1 - t) * t * mid + t^2 * endPos
            web.CFrame = CFrame.new(p)
            RunService.Heartbeat:Wait()
        end
        -- Resolve if still pending (flight ended without a tap).
        local state = activeWebs[webId]
        if state and not state.resolved then
            -- Landing. Hand off to the tower itself: the WebTapsRemaining
            -- and WebbedUntil attributes on the tower are the source of
            -- truth from here on. The web Part is destroyed — the client's
            -- WEBBED overlay on the tower becomes the clickable target,
            -- so we don't need two separate click surfaces competing.
            local tower = state.targetTower
            state.resolved = true
            if state.part and state.part.Parent then state.part:Destroy() end
            activeWebs[webId] = nil
            if tower and tower.Parent then
                tower:SetAttribute("WebbedUntil", os.clock() + 1e9)
                tower:SetAttribute("WebTapsRemaining", LANDED_WEB_TAPS_TO_CLEAR)
                -- Parent the ClickDetector to the tower MODEL (not a single
                -- Part), so clicking any of the tower's descendant Parts
                -- (base, column, gem, spikes) registers. Core Power Tower
                -- players tend to click the gem at the top; anchoring to
                -- TowerBase alone left most of the visible tower unclickable.
                local existing = tower:FindFirstChild("WebbedClickDetector")
                if existing then existing:Destroy() end
                local cd = Instance.new("ClickDetector")
                cd.Name = "WebbedClickDetector"
                cd.MaxActivationDistance = 500
                cd.Parent = tower
                cd.MouseClick:Connect(function(player)
                    if not tower.Parent then return end
                    local remaining = (tower:GetAttribute("WebTapsRemaining") or 0) - 1
                    if remaining > 0 then
                        tower:SetAttribute("WebTapsRemaining", remaining)
                    else
                        tower:SetAttribute("WebbedUntil", 0)
                        tower:SetAttribute("WebTapsRemaining", nil)
                        if cd.Parent then cd:Destroy() end
                        print(("[CanopySpider] %s cleared landed web on %s"):format(
                            player.Name, tower.Name))
                    end
                end)
                print(("[CanopySpider] Web landed on %s — %d taps to clear"):format(
                    tower.Name, LANDED_WEB_TAPS_TO_CLEAR))
            end
        end
    end)
end

-- Run one web-attack beat: launch webs and immediately keep walking.
-- Per Matthew: boss should NOT pause after launching webs — keep
-- pressure on the heart while the player tries to clear webs in flight.
local function fireWebAttack(ctx, bossMob)
    local data = ctx.activeMobs[bossMob]
    if not data then return end

    local targets = pickWebTargets(WEB_COUNT_PER_ATTACK)
    if #targets == 0 then return end
    local startPos = bossMob.Position + Vector3.new(0, 3, 0)
    for _, tower in ipairs(targets) do
        spawnWeb(startPos, tower)
    end
    -- Force 1× speed during the web flight window so the player has
    -- time to tap webs without the rest of the wave-system speed
    -- multiplier squashing the reaction window. Released when the
    -- last web's flight time has elapsed. GameTime.lockSpeed returns
    -- an idempotent release closure so the safety unlock can't double-fire.
    local releaseSpeed = GameTime.lockSpeed()
    task.delay(WEB_FLIGHT_SEC + 0.1, releaseSpeed)
end

-- Boss-lifecycle watcher: when a canopyspider is in play, tick a 15s
-- web-attack loop until it dies / leaves the table.
local activeBosses = {}  -- [mob] = true, tracks watcher ownership

-- Release any pending webs (tapped or not). Called on boss death so
-- mid-flight webs don't continue to the tower AFTER the fight is over,
-- and on run reset to wipe stale state.
local function releaseAllWebs()
    for id, state in pairs(activeWebs) do
        state.resolved = true
        if state.part and state.part.Parent then
            state.part:Destroy()
        end
        activeWebs[id] = nil
    end
    -- Also clear any tower-side webbed state so stuck towers aren't
    -- permanently locked out after a boss-death / run-reset cleanup.
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = towerBase.Parent
        if t and (t:GetAttribute("WebTapsRemaining") or 0) > 0 then
            t:SetAttribute("WebbedUntil", 0)
            t:SetAttribute("WebTapsRemaining", nil)
            -- Strip any stale WebbedClickDetector (parented to the Model).
            local cd = t:FindFirstChild("WebbedClickDetector")
            if cd then cd:Destroy() end
        end
    end
end

local function watchBoss(ctx, bossMob)
    if activeBosses[bossMob] then return end
    activeBosses[bossMob] = true

    -- Spiderling escorts: 4 minis staggered along the path at 3-stud
    -- spacing around the boss — 2 ahead (closer to the heart) and 2
    -- behind. Ahead-ones get waypointIndex = 2 so they path toward the
    -- next waypoint rather than walking back to spawn; behind-ones stay
    -- at waypointIndex = 1 so they walk through the spawn point on their
    -- way to wp[2] just like normal mobs.
    if ctx.makeMob and ctx.getWaypoints then
        local waypoints = ctx.getWaypoints()
        if #waypoints >= 2 then
            local wp1 = waypoints[1].Position
            local wp2 = waypoints[2].Position
            -- Horizontal direction along the path at the spawn segment.
            -- Ignore Y so mobs stay on the floor regardless of any
            -- up-down variation in the waypoint chain.
            local dir = Vector3.new(wp2.X - wp1.X, 0, wp2.Z - wp1.Z)
            if dir.Magnitude > 0.01 then dir = dir.Unit else dir = Vector3.new(0, 0, 1) end

            local STAGGER = 3  -- studs between each mob along the path
            local SPAWNS = {
                { offset =  2 * STAGGER, wpIdx = 2 },  -- ahead2
                { offset =  1 * STAGGER, wpIdx = 2 },  -- ahead1
                { offset = -1 * STAGGER, wpIdx = 1 },  -- behind1
                { offset = -2 * STAGGER, wpIdx = 1 },  -- behind2
            }
            for _, entry in ipairs(SPAWNS) do
                local ling = ctx.makeMob("spiderling", waypoints, 1.0)
                if ling then
                    local data = ctx.activeMobs[ling]
                    if data then
                        data.waypointIndex = entry.wpIdx
                    end
                    local pos = wp1 + dir * entry.offset
                    -- Keep the mob's own Y (makeMob sets it to floor + half
                    -- size) and just slot in the X/Z offset.
                    ling.CFrame = CFrame.new(pos.X, ling.Position.Y, pos.Z)
                end
            end
        end
    end

    task.spawn(function()
        -- Game-time wait via GameTime.adaptiveWait — polls GameSpeed each
        -- frame so an N-game-second wait stays N-game-seconds even when a
        -- boss-phase lock briefly pins gs at 1 mid-wait. Earlier impl
        -- computed a fixed wallclock duration BEFORE fireWebAttack and
        -- the lock push from the previous attack outlived the wait,
        -- pinning gs=1 forever. Predicate exits the wait immediately if
        -- the boss dies mid-wait so we don't try to fire a web after.
        local function alive() return bossMob and bossMob.Parent ~= nil end
        GameTime.adaptiveWait(5, alive)
        while bossMob and bossMob.Parent do
            fireWebAttack(ctx, bossMob)
            GameTime.adaptiveWait(WEB_ATTACK_INTERVAL_SEC, alive)
        end
        activeBosses[bossMob] = nil
        -- Boss is dead (or cleared) — drop any webs still in flight so
        -- the player's towers don't get surprise-webbed after the kill.
        releaseAllWebs()
    end)
end

function CanopySpiderBoss.setup(ctx)
    local tapRemote = Remotes.getOrCreate(Remotes.Names.TapSpiderWeb, "RemoteEvent")

    -- Tap handler: player tapped a web target. Find + destroy the matching
    -- web (if still pending), mark resolved so the flight task skips the
    -- webbing effect.
    tapRemote.OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= "table" then return end

        -- Two tap sources:
        --   1. In-flight webs (payload.webId) — one tap pops them instantly.
        --   2. Landed-on-tower overlay (payload.tower = Model) — decrements
        --      the tower's WebTapsRemaining and clears WebbedUntil on 0.
        local towerInst = payload.tower
        if typeof(towerInst) == "Instance" and towerInst:IsA("Model") then
            local taps = (towerInst:GetAttribute("WebTapsRemaining") or 0) - 1
            if taps > 0 then
                towerInst:SetAttribute("WebTapsRemaining", taps)
            else
                towerInst:SetAttribute("WebbedUntil", 0)
                towerInst:SetAttribute("WebTapsRemaining", nil)
                print(("[CanopySpider] %s cleared landed web on %s"):format(
                    player.Name, towerInst.Name))
            end
            return
        end

        local webId = payload.webId
        if type(webId) ~= "string" then return end
        local state = activeWebs[webId]
        if not state or state.resolved then return end
        -- Only in-flight webs have an activeWebs entry now (landed webs are
        -- destroyed + removed from the registry immediately on land). So
        -- any tap with a webId is an in-flight pop.
        state.resolved = true
        if state.part and state.part.Parent then state.part:Destroy() end
        activeWebs[webId] = nil
        print(("[CanopySpider] %s popped web %s in-flight"):format(
            player.Name, webId))
    end)

    -- Poll activeMobs each Heartbeat for a canopyspider that isn't yet
    -- being watched. Polling (vs reacting to spawn event) keeps the system
    -- robust to dev-spawns and future wave-integration without wiring a
    -- new signal.
    RunService.Heartbeat:Connect(function()
        if not ctx.activeMobs or not ctx.MOB_TYPES then return end
        for mob, _ in pairs(ctx.activeMobs) do
            if mob and mob.Parent and not activeBosses[mob] then
                -- Detect via the def's isCanopySpider flag rather than the
                -- mob's Name string — survives mob-type renames and lets
                -- multiple MOB_TYPES opt into the same web mechanic if
                -- that ever becomes useful (e.g. a map 4 variant).
                local mobType = string.gsub(mob.Name, "^Mob_", "")
                local def = ctx.MOB_TYPES[mobType]
                if def and def.isCanopySpider then
                    watchBoss(ctx, mob)
                end
            end
        end
    end)

    -- Cleanup: drop any in-flight webs on (a) run reset and (b) the last
    -- player leaving. Both cases imply the current fight is abandoned, so
    -- lingering web parts + active watchers would pollute the next run.
    local runResetBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.RunReset)
    if runResetBindable then
        runResetBindable.Event:Connect(releaseAllWebs)
    end

    Players.PlayerRemoving:Connect(function()
        if #Players:GetPlayers() <= 1 then
            releaseAllWebs()
        end
    end)
end

return CanopySpiderBoss
