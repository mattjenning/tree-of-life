--[[
    BirdBoss.lua — Map 3 boss dive-strike mechanic.

    THE FIGHT:
    The Canopy Bird (`isCanopyBird` flag on MOB_TYPES def) flies the path
    slowly, and every ~12 seconds ascends + hovers over a random
    player-owned tower. A tappable dive-target appears above the tower
    for ~2 seconds — tap it and the bird's dive is canceled (bonus
    damage dealt to the bird, bird returns to the path). Miss and the
    bird dives into the tower, pecking 10 MaxShots off it.

    Distinction from the Web Weaver:
      Weaver: WEB projectile that stuns the tower (can't fire for 3s)
      Bird:   DIVE that reduces the tower's MaxShots (permanent for the
              run — tower still fires but depletes faster)

    FLOW PER DIVE ATTEMPT:
      1. Bird has been alive > DiveIntervalSec since last attack (or spawn).
      2. Freeze bird movement for BossPauseSec (BossWebbing attribute,
         reused from MobUpdate's boss-halt gate).
      3. Pick a random tower that isn't already at 0 MaxShots.
      4. Spawn a dive-target Part tagged BirdDiveMark above the tower.
         Client auto-attaches a tap BillboardGui to it.
      5. Wait HoverSec seconds.
      6. If tapped (TapBirdDive remote): destroy mark, deal bonus damage
         to the bird.
      7. If not tapped: destroy mark, decrement tower MaxShots by
         TowerPeckLoss. Clamp Shots if it now exceeds MaxShots.
      8. Sleep to next DiveIntervalSec.

    DEPENDENCIES:
    - ctx.activeMobs + ctx.damageMob
    - Tags.Tower for owned-tower lookup
    - ctx.MOB_TYPES for isCanopyBird detection

    setup(ctx) reads:
      ctx (late-resolved at call time)

    Publishes: nothing on ctx. Communicates via Remotes + Tags only.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Tags    = require(Shared:WaitForChild("Tags"))
local Config  = require(Shared:WaitForChild("Config"))

local BirdBoss = {}

local CFG = Config.Map3 and Config.Map3.CanopyBird or {}
local DIVE_INTERVAL_SEC  = CFG.DiveIntervalSec  or 12
local DIVE_TARGETS_COUNT = CFG.DiveTargetsCount or 1
local HOVER_SEC          = CFG.HoverSec         or 2.0
local BOSS_PAUSE_SEC     = CFG.BossPauseSec     or 3.0
local DIVE_BONUS_DAMAGE  = CFG.DiveBonusDamage  or 500
local TOWER_PECK_LOSS    = CFG.TowerPeckLoss    or 10

-- Per-mark state, indexed by MarkId string.
-- { part, targetTower, resolvesAt, resolved }
local activeMarks = {}
local nextMarkId = 0

local function makeDiveMarkPart(position)
    local mark = Instance.new("Part")
    mark.Name = "BirdDiveMark"
    mark.Shape = Enum.PartType.Ball
    mark.Size = Vector3.new(3, 3, 3)
    mark.Anchored = true
    mark.CanCollide = false
    mark.CastShadow = false
    mark.Material = Enum.Material.Neon
    mark.Color = Color3.fromRGB(255, 180, 80)
    mark.Transparency = 0.15
    mark.CFrame = CFrame.new(position)
    mark.Parent = workspace
    CollectionService:AddTag(mark, Tags.BirdDiveMark)
    return mark
end

-- Pick a random player-owned tower that still has MaxShots to lose.
local function pickTargetTower()
    local candidates = {}
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local tower = base.Parent
        if tower and tower.Parent then
            local maxShots = tower:GetAttribute("MaxShots") or 0
            local noAmmo   = tower:GetAttribute("NoAmmo") == true
            -- Skip NoAmmo (aux) towers — peck-MaxShots is meaningless there.
            -- Skip MaxShots=0 (already drained) so the bird doesn't waste
            -- its attack on a tower it can't hurt further.
            if not noAmmo and maxShots > 0 then
                table.insert(candidates, tower)
            end
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(1, #candidates)]
end

-- Apply the peck damage: decrement MaxShots, clamp Shots so the HUD
-- doesn't show more ammo than the new capacity.
local function peckTower(tower)
    if not (tower and tower.Parent) then return end
    local maxShots = tower:GetAttribute("MaxShots") or 0
    local newMax = math.max(0, maxShots - TOWER_PECK_LOSS)
    tower:SetAttribute("MaxShots", newMax)
    local shots = tower:GetAttribute("Shots") or 0
    if shots > newMax then
        tower:SetAttribute("Shots", newMax)
    end
    print(("[BirdBoss] Pecked %s: MaxShots %d → %d"):format(
        tower.Name, maxShots, newMax))
end

local function runDiveAttempt(ctx, bossMob)
    if not bossMob or not bossMob.Parent then return end
    bossMob:SetAttribute("BossWebbing", os.clock() + BOSS_PAUSE_SEC)

    for _ = 1, DIVE_TARGETS_COUNT do
        local tower = pickTargetTower()
        if tower then
            nextMarkId = nextMarkId + 1
            local markId = tostring(nextMarkId)
            local towerBase = tower:FindFirstChild("TowerBase")
                or tower:FindFirstChildWhichIsA("BasePart")
            if towerBase then
                local markPos = towerBase.Position + Vector3.new(0, 14, 0)
                local mark = makeDiveMarkPart(markPos)
                mark:SetAttribute("MarkId", markId)
                activeMarks[markId] = {
                    part         = mark,
                    targetTower  = tower,
                    resolvesAt   = os.clock() + HOVER_SEC,
                    resolved     = false,
                }
            end
        end
    end
end

-- Per-bird watcher: every DIVE_INTERVAL_SEC, run a dive attempt while
-- alive. Mirrors CanopySpiderBoss's watchBoss pattern.
local activeBosses = {}

local function releaseAllMarks()
    for id, state in pairs(activeMarks) do
        state.resolved = true
        if state.part and state.part.Parent then
            state.part:Destroy()
        end
        activeMarks[id] = nil
    end
end

local function watchBoss(ctx, bossMob)
    if activeBosses[bossMob] then return end
    activeBosses[bossMob] = true
    task.spawn(function()
        task.wait(5)
        while bossMob and bossMob.Parent do
            runDiveAttempt(ctx, bossMob)
            task.wait(DIVE_INTERVAL_SEC)
        end
        activeBosses[bossMob] = nil
        releaseAllMarks()
    end)
end

function BirdBoss.setup(ctx)
    local tapRemote = Remotes.getOrCreate(Remotes.Names.TapBirdDive, "RemoteEvent")

    -- Tap handler: cancel the dive for that markId + deal bonus damage
    -- to the bird (the only living canopyspider-OR-canopybird alive at
    -- the time — we just grab the first isCanopyBird mob from activeMobs).
    tapRemote.OnServerEvent:Connect(function(player, payload)
        local markId = payload and payload.markId
        if type(markId) ~= "string" then return end
        local state = activeMarks[markId]
        if not state or state.resolved then return end
        state.resolved = true
        if state.part and state.part.Parent then
            state.part:Destroy()
        end
        activeMarks[markId] = nil

        -- Find the bird and deal bonus damage.
        if ctx.activeMobs and ctx.MOB_TYPES then
            for mob, _ in pairs(ctx.activeMobs) do
                if mob and mob.Parent then
                    local mobType = string.gsub(mob.Name, "^Mob_", "")
                    local def = ctx.MOB_TYPES[mobType]
                    if def and def.isCanopyBird then
                        if ctx.damageMob then
                            ctx.damageMob(mob, DIVE_BONUS_DAMAGE, nil)
                        end
                        break
                    end
                end
            end
        end
        print(("[BirdBoss] %s tapped dive-target %s"):format(player.Name, markId))
    end)

    -- Resolve pending marks whose hover window has elapsed (miss path).
    RunService.Heartbeat:Connect(function()
        local now = os.clock()
        for id, state in pairs(activeMarks) do
            if not state.resolved and now >= state.resolvesAt then
                state.resolved = true
                if state.part and state.part.Parent then
                    state.part:Destroy()
                end
                activeMarks[id] = nil
                peckTower(state.targetTower)
            end
        end
    end)

    -- Boss watcher: spin up a dive loop when a bird mob appears.
    RunService.Heartbeat:Connect(function()
        if not ctx.activeMobs or not ctx.MOB_TYPES then return end
        for mob, _ in pairs(ctx.activeMobs) do
            if mob and mob.Parent and not activeBosses[mob] then
                local mobType = string.gsub(mob.Name, "^Mob_", "")
                local def = ctx.MOB_TYPES[mobType]
                if def and def.isCanopyBird then
                    watchBoss(ctx, mob)
                end
            end
        end
    end)

    -- Clear marks on RunReset + last-player-leaving.
    local runResetBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.RunReset)
    if runResetBindable then
        runResetBindable.Event:Connect(releaseAllMarks)
    end
    Players.PlayerRemoving:Connect(function()
        if #Players:GetPlayers() <= 1 then
            releaseAllMarks()
        end
    end)
end

return BirdBoss
