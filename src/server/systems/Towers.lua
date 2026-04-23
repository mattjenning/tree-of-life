--[[
    Towers.lua — Tower firing loop.

    Called every Heartbeat from the main loop with the current list of
    tagged tower parts. For each tower:
      1. Check if it has shots (or the owner has DevUnlimitedAmmo).
      2. Respect the per-tower fire-rate cooldown.
      3. Pick a target via ctx.findTarget (Targeting.lua).
      4. Apply stun/knockback effects via ctx.applyHitEffects; each proc
         grants one extra damage hit.
      5. Deal damage via ctx.damageMob.
      6. Spawn firing bolt + AOE burst VFX.
      7. Decrement Shots (unless unlimited).

    Per-tower state:
      - towerLastFire[towerModel]  : os.clock of last shot (cooldown)
      - towerOwnerCache[towerModel]: cached Player reference (saved per-frame
                                     Players:GetPlayerByUserId calls)

    Both tables are module-local but published on ctx so Phoenix and
    DevRemotes can access / clear them. A GetInstanceRemovedSignal(Tower)
    handler drops cache entries when a tower is destroyed so DevReset
    and normal tower-destroy flows don't leak memory across runs.

    setup(ctx) reads (late-resolved at call time):
      ctx.activeMobs, ctx.WaveConfig, ctx.gameSpeed
      ctx.findTarget                  (Targeting.lua)
      ctx.applyHitEffects, fireBolt, spawnAoeBurst  (Effects.lua)
      ctx.damageMob                   (orchestrator until commit 9)
      ctx.phoenixDisplayCd, ctx.phoenixDisplayGrace
                                      (for tag-removed cache cleanup)

    And publishes:
      ctx.updateTowers(towerList)  -- called from Heartbeat
      ctx.towerLastFire            -- for Phoenix / dev reset to read/clear
      ctx.towerOwnerCache          -- for Phoenix / dev reset to read/clear
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags = require(Shared:WaitForChild("Tags"))

local Towers = {}

function Towers.setup(ctx)
    local towerLastFire   = {}  -- [tower model] = os.clock() of last shot
    local towerOwnerCache = {}  -- [tower model] = Player (cached per tower)

    -- Publish caches so Phoenix + DevReset can read/clear them.
    ctx.towerLastFire   = towerLastFire
    ctx.towerOwnerCache = towerOwnerCache

    -- The owner of a tower never changes after placement, so we resolve it once
    -- via getTowerOwner and cache. Saves a per-frame Players:GetPlayerByUserId
    -- call per tower.
    local function getTowerOwner(towerModel)
        local cached = towerOwnerCache[towerModel]
        if cached and cached.Parent then return cached end
        local ownerId = towerModel:GetAttribute("Owner")
        if not ownerId then return nil end
        local p = Players:GetPlayerByUserId(ownerId)
        if p then towerOwnerCache[towerModel] = p end
        return p
    end

    -- Clean per-tower cache entries when a tower is removed. Without this,
    -- DevReset destroys towers but the table entries linger across runs —
    -- a slow leak. The tag is removed when the tower model is destroyed,
    -- which fires GetInstanceRemovedSignal.
    CollectionService:GetInstanceRemovedSignal(Tags.Tower):Connect(function(taggedPart)
        -- The tagged instance is the tower's BasePart, not the model. Walk
        -- both to be safe — caches might key on either depending on insertion site.
        local model = taggedPart.Parent
        if model then
            towerLastFire[model]   = nil
            towerOwnerCache[model] = nil
            if ctx.phoenixDisplayCd    then ctx.phoenixDisplayCd[model]    = nil end
            if ctx.phoenixDisplayGrace then ctx.phoenixDisplayGrace[model] = nil end
        end
        towerLastFire[taggedPart]   = nil
        towerOwnerCache[taggedPart] = nil
        if ctx.phoenixDisplayCd    then ctx.phoenixDisplayCd[taggedPart]    = nil end
        if ctx.phoenixDisplayGrace then ctx.phoenixDisplayGrace[taggedPart] = nil end
    end)

    local function updateTowers(towerList)
        local now = os.clock()
        for _, towerBase in ipairs(towerList) do
            local towerModel = towerBase.Parent
            if towerModel and towerModel.Parent then
                local shots = towerModel:GetAttribute("Shots") or 0
                local owner = getTowerOwner(towerModel)
                local unlimited = owner and owner:GetAttribute("DevUnlimitedAmmo") == true
                if shots > 0 or unlimited then
                    local baseDamage = towerModel:GetAttribute("Damage") or 10
                    -- Per-player bonus damage (final boss minigame).
                    local damage = baseDamage
                    if owner then
                        local until_ = owner:GetAttribute("BonusDamageUntil") or 0
                        if now < until_ then
                            damage = baseDamage * ctx.WaveConfig.finalBossBonusMultiplier
                        end
                    end
                    local range    = towerModel:GetAttribute("Range")    or 25
                    local fireRate = towerModel:GetAttribute("FireRate") or 1
                    local aoeRadius = towerModel:GetAttribute("AoeRadius")
                    local lastFire = towerLastFire[towerModel] or 0
                    -- Effective fire rate scales with ctx.gameSpeed so towers
                    -- shoot in proportion to mob movement during 2x/3x/5x/10x.
                    local interval = 1 / (fireRate * ctx.gameSpeed)
                    if now - lastFire >= interval then
                        local tp = towerBase.Position
                        local mode = towerModel:GetAttribute("TargetMode") or "First"
                        local target = ctx.findTarget(tp, range, mode)
                        if target then
                            -- Apply secondary effects (stun/knockback) BEFORE the
                            -- damage hit. If the damage kills the target, the mob
                            -- gets removed from activeMobs and applyHitEffects
                            -- becomes a no-op. Doing it first preserves the roll.
                            -- Each proc returns a count; for every proc we deal
                            -- an EXTRA hit of normal damage (so a stun-and-
                            -- knockback double-proc = 3 total damage hits).
                            local procs = ctx.applyHitEffects(towerModel, target)
                            ctx.damageMob(target, damage, towerModel)
                            for _ = 1, procs do
                                ctx.damageMob(target, damage, towerModel)
                            end
                            ctx.fireBolt(tp + Vector3.new(0, 10, 0), target.Position, Color3.fromRGB(255, 120, 80))

                            if aoeRadius and aoeRadius > 0 then
                                local targetPos = target.Position
                                ctx.spawnAoeBurst(targetPos, aoeRadius)
                                for mob, _ in pairs(ctx.activeMobs) do
                                    if mob ~= target and mob.Parent then
                                        if (mob.Position - targetPos).Magnitude <= aoeRadius then
                                            local mobProcs = ctx.applyHitEffects(towerModel, mob)
                                            ctx.damageMob(mob, damage, towerModel)
                                            for _ = 1, mobProcs do
                                                ctx.damageMob(mob, damage, towerModel)
                                            end
                                        end
                                    end
                                end
                            end

                            towerLastFire[towerModel] = now
                            if not unlimited then
                                towerModel:SetAttribute("Shots", shots - 1)
                            end
                        end
                    end
                end
            end
        end
    end

    ctx.updateTowers = updateTowers
    ctx.getTowerOwner = getTowerOwner
end

return Towers
