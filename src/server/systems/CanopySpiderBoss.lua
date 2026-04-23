--[[
    CanopySpiderBoss.lua — Map 3 boss web-attack mechanic.

    THE FIGHT:
    The Canopy Weaver (mob type `canopyspider`) is slow, tanky, and
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

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Tags    = require(Shared:WaitForChild("Tags"))
local Config  = require(Shared:WaitForChild("Config"))

local CanopySpiderBoss = {}

-- Tuning lives in Config.Map2.CanopyWeaver so balance can be adjusted
-- without touching code. Read once at module load — these are set at
-- server boot and don't change during play.
local CW_CFG = Config.Map2 and Config.Map2.CanopyWeaver or {}
local WEB_ATTACK_INTERVAL_SEC = CW_CFG.WebAttackIntervalSec or 15
local WEB_COUNT_PER_ATTACK    = CW_CFG.WebCountPerAttack    or 3
local WEB_FLIGHT_SEC          = CW_CFG.WebFlightSec         or 2.5
local WEB_BOSS_PAUSE_SEC      = CW_CFG.BossPauseSec         or 2.5
local TOWER_WEBBED_DURATION   = CW_CFG.TowerWebbedSec       or 3

-- Module-local registry of active webs, indexed by WebId string. Each entry:
--   { part, targetTower, landsAt, resolved = bool }
local activeWebs = {}
local nextWebId = 0

local function makeWebPart(startPos, color)
    local web = Instance.new("Part")
    web.Name = "SpiderWeb"
    web.Shape = Enum.PartType.Ball
    web.Size = Vector3.new(2.5, 2.5, 2.5)
    web.Anchored = true
    web.CanCollide = false
    web.CastShadow = false
    web.Material = Enum.Material.Neon
    web.Color = color or Color3.fromRGB(240, 240, 255)
    web.Transparency = 0.15
    web.CFrame = CFrame.new(startPos)
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
    local web = makeWebPart(startPos)
    web:SetAttribute("WebId", webId)
    web:SetAttribute("TargetTowerName", targetTower.Name)

    activeWebs[webId] = {
        part        = web,
        targetTower = targetTower,
        landsAt     = os.clock() + WEB_FLIGHT_SEC,
        resolved    = false,
    }

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
            state.resolved = true
            if web.Parent then web:Destroy() end
            activeWebs[webId] = nil
            -- Apply webbed state to target tower, if it still exists.
            local tower = state.targetTower
            if tower and tower.Parent then
                tower:SetAttribute("WebbedUntil", os.clock() + TOWER_WEBBED_DURATION)
                print(("[CanopySpider] Web landed on %s → webbed for %ds"):format(
                    tower.Name, TOWER_WEBBED_DURATION))
            end
        end
    end)
end

-- Run one web-attack beat: pause boss, spawn webs at 3 random targets.
local function fireWebAttack(ctx, bossMob)
    local data = ctx.activeMobs[bossMob]
    if not data then return end
    -- Freeze the boss in place. MobUpdate checks BossWebbing and halts
    -- pathing if now < BossWebbing (new attribute; added alongside stun).
    bossMob:SetAttribute("BossWebbing", os.clock() + WEB_BOSS_PAUSE_SEC)

    local targets = pickWebTargets(WEB_COUNT_PER_ATTACK)
    if #targets == 0 then return end
    local startPos = bossMob.Position + Vector3.new(0, 3, 0)
    for _, tower in ipairs(targets) do
        spawnWeb(startPos, tower)
    end
end

-- Boss-lifecycle watcher: when a canopyspider is in play, tick a 15s
-- web-attack loop until it dies / leaves the table.
local activeBosses = {}  -- [mob] = true, tracks watcher ownership

local function watchBoss(ctx, bossMob)
    if activeBosses[bossMob] then return end
    activeBosses[bossMob] = true

    task.spawn(function()
        -- Small grace period so the first attack isn't instant.
        task.wait(5)
        while bossMob and bossMob.Parent do
            fireWebAttack(ctx, bossMob)
            task.wait(WEB_ATTACK_INTERVAL_SEC)
        end
        activeBosses[bossMob] = nil
    end)
end

function CanopySpiderBoss.setup(ctx)
    local tapRemote = Remotes.getOrCreate(Remotes.Names.TapSpiderWeb, "RemoteEvent")

    -- Tap handler: player tapped a web target. Find + destroy the matching
    -- web (if still pending), mark resolved so the flight task skips the
    -- webbing effect.
    tapRemote.OnServerEvent:Connect(function(player, payload)
        local webId = payload and payload.webId
        if type(webId) ~= "string" then return end
        local state = activeWebs[webId]
        if not state or state.resolved then return end
        state.resolved = true
        if state.part and state.part.Parent then
            state.part:Destroy()
        end
        activeWebs[webId] = nil
        print(("[CanopySpider] %s tapped web %s"):format(player.Name, webId))
    end)

    -- Poll activeMobs each Heartbeat for a canopyspider that isn't yet
    -- being watched. Polling (vs reacting to spawn event) keeps the system
    -- robust to dev-spawns and future wave-integration without wiring a
    -- new signal.
    RunService.Heartbeat:Connect(function()
        if not ctx.activeMobs then return end
        for mob, _ in pairs(ctx.activeMobs) do
            if mob and mob.Parent then
                -- MobFactory names mobs "Mob_<type>". The map-2 spider
                -- boss has its isCanopySpider flag baked in at MOB_TYPES.
                if mob.Name == "Mob_spider" and not activeBosses[mob] then
                    watchBoss(ctx, mob)
                end
            end
        end
    end)

    -- Cleanup: if all players leave while webs are in flight, drop the
    -- pending state so nothing lingers between sessions.
    Players.PlayerRemoving:Connect(function()
        if #Players:GetPlayers() <= 1 then  -- last player leaving
            for id, state in pairs(activeWebs) do
                state.resolved = true
                if state.part and state.part.Parent then
                    state.part:Destroy()
                end
                activeWebs[id] = nil
            end
        end
    end)
end

return CanopySpiderBoss
