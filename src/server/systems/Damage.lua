--[[
    Damage.lua — damageMob + Detonator chain-damage logic.

    damageMob(mob, amount, sourceTower, isChainDamage) → bool killed?
      Applies `amount` damage to `mob`:
        - Skips if the mob is in Phoenix limbo (_phoenixQueued)
        - Updates data.hp, HP bar fill, HP text
        - Calls ctx.checkPhaseTrigger so the final boss can kick off a
          phase windup if HP just crossed a new threshold
        - On kill:
            * Detonator chain: if sourceTower has DetonatorRadius +
              DetonatorHpPct attributes and this wasn't itself a chain
              hit, spawns a shrapnel burst and damages every OTHER mob
              in radius for `data.maxHp * pct` damage. Chain hits also
              roll applyHitEffects (stun / knockback) BEFORE the damage
              so a lethal chain hit doesn't strand the roll.
            * Destroys stun stars, clears finalBoss.instance if this
              was the final boss, removes from ctx.activeMobs, Destroys
              the Part.
      Returns true if the mob died, false otherwise.

    sourceTower is optional (e.g. heart-damage calls don't pass it) and is
    only used to read Detonator attributes off the originating tower.
    isChainDamage is true for recursive calls spawned by the Detonator
    burst — prevents infinite chains.

    setup(ctx) reads (late-resolved at call time):
      ctx.activeMobs, ctx.spawnDamageNumber, ctx.spawnDetonatorBurst,
      ctx.applyHitEffects, ctx.checkPhaseTrigger, ctx.FinalBossState

    And publishes:
      ctx.damageMob
]]

local Players    = game:GetService("Players")

local StatLedger = require(script.Parent:WaitForChild("StatLedger"))

local Damage = {}

-- supportEnemyVulnMult — per-source-tower multiplier looking up the
-- owning player's SupportEnemyVulnStacks (Core upgrade, ea3-26 / Phase
-- C-1). +5% damage taken per stack; stacks compound across the run's
-- map-boss picks.
--
-- Looks up the player from the source tower's `Owner` attribute; nil-
-- safe so heart-damage / unowned-source paths fall through to 1.0.
local function supportEnemyVulnMult(sourceTower: Instance?): number
    if not sourceTower then return 1 end
    local userId = sourceTower:GetAttribute("Owner")
    if type(userId) ~= "number" then return 1 end
    local player = Players:GetPlayerByUserId(userId)
    if not player then return 1 end
    local stacks = player:GetAttribute("SupportEnemyVulnStacks") or 0
    if stacks <= 0 then return 1 end
    return 1 + 0.05 * stacks
end

function Damage.setup(ctx)
    -- _isLinkEcho: 5th-arg recursion guard for BloodlinkVine echoes.
    -- When ctx.damageMob fires from the link-broadcast block below,
    -- the call passes `true` here so the echoed damage doesn't
    -- itself re-trigger broadcasts (avoids infinite multiplication
    -- in linked clusters of 3+ mobs).
    local function damageMob(mob, amount, sourceTower, isChainDamage, _isLinkEcho)
        local data = ctx.activeMobs[mob]
        if not data then
            -- Standalone-mob path: target lives outside ctx.activeMobs (e.g.
            -- the Map 3 Canopy Bird + bird-boss eggs, which Map3BirdBoss
            -- builds via makePart). Only requirement: the part exposes
            -- Health / MaxHealth attributes. Spawns the same damage popup
            -- regular mobs get and bumps the dev STATS counter so the
            -- standalone target tracks damage in TOTAL_DAMAGE_DONE too.
            if not (mob and mob.Parent) then return false end
            local hp = mob:GetAttribute("Health")
            if hp == nil then return false end
            -- Per-target damage multiplier (e.g. bird boss = 2× vulnerable
            -- during its swoop). Multiply BEFORE rounding so a 0.5× target
            -- doesn't accidentally take 0 from a 1-damage hit.
            -- ea3-26: layer the source-player's SupportEnemyVuln stacks
            -- on top (+5% per stack, additive on top of the per-target
            -- mult).
            local mult = (mob:GetAttribute("DamageTakenMultiplier") or 1)
                       * supportEnemyVulnMult(sourceTower)
            amount = math.max(1, math.floor(amount * mult + 0.5))
            local newHp = math.max(0, hp - amount)
            mob:SetAttribute("Health", newHp)
            -- Damage-popup spawn position: lift by TargetAimOffsetY
            -- (set on tall bosses like Pickle Lord whose body
            -- center is buried below the platform). Without this
            -- the popup lands underground at body.Position and
            -- the player never sees it.
            local popupY = mob:GetAttribute("TargetAimOffsetY") or 0
            local popupPos = mob.Position + Vector3.new(0, popupY, 0)
            ctx.spawnDamageNumber(popupPos, amount)
            if sourceTower and sourceTower.Parent then
                local effective = math.min(amount, hp)  -- no overkill credit
                if not isChainDamage then
                    local prev = sourceTower:GetAttribute("TotalDamageDone") or 0
                    sourceTower:SetAttribute("TotalDamageDone", prev + effective)
                    if not sourceTower:GetAttribute("FirstHitTime") then
                        sourceTower:SetAttribute("FirstHitTime", os.clock())
                    end
                end
                StatLedger.recordDamage(sourceTower, effective,
                    isChainDamage and "chain" or "direct", mob)
            end
            if newHp <= 0 then
                -- Self-cleanup. Bird-boss owners may handle death via their
                -- own AttributeChanged listener (which destroys the parent
                -- model and orphans this part — mob.Parent goes nil before
                -- we reach here, in which case the destroy is a no-op).
                -- Eggs have no listener, so they DO need this destroy.
                if mob.Parent then mob:Destroy() end
                return true
            end
            return false
        end
        if data._phoenixQueued then return false end  -- mob is in limbo, invulnerable
        -- Per-target damage multiplier (e.g. exposed/staggered states). Same
        -- DamageTakenMultiplier attribute the standalone path uses, so any
        -- mob — wave-system or custom-driven — can opt into a vulnerability
        -- buff with a single attribute set.
        -- ea3-26: layer source-player's SupportEnemyVuln stacks (+5%
        -- per stack) on top of the per-target mult.
        local mult = (mob:GetAttribute("DamageTakenMultiplier") or 1)
                   * supportEnemyVulnMult(sourceTower)
        amount = amount * mult
        -- Round to the nearest integer at hit time so mobs, HP bars, damage
        -- popups, and stat totals all read as whole numbers. Aux base damages
        -- scaled by rarity (0.91×–1.30×) produce decimals like 1.82 that
        -- look wrong on the HUD and in damage popups. Storage stays float
        -- upstream (Damage attribute, upgrade math) so accumulated bonuses
        -- don't drift — only the HIT amount is integer. Clamped to ≥1 so
        -- a rounding-down-to-0 can't make a tower deal literal zero damage.
        amount = math.max(1, math.floor(amount + 0.5))
        data.hp = data.hp - amount
        -- Mirror the new hp onto the part's Health attribute so any
        -- attribute-watching consumer (broadcastWaveState boss HP read,
        -- HUD bars on the spider boss, etc.) sees the fresh value
        -- without polling activeMobs.
        if mob.Parent then
            mob:SetAttribute("Health", math.max(0, data.hp))
        end
        ctx.spawnDamageNumber(mob.Position, amount)

        -- Dev STATS panel: track total damage + first-hit time per tower so
        -- the client can display lifetime damage + average DPS. The cap at
        -- the mob's remaining HP (amount could include overkill) keeps the
        -- number honest — we don't want a 999-damage hit on a 10-HP mob to
        -- inflate the stat. Only bump if the hit actually landed on a live
        -- mob (data is still present); skip for chain hits to avoid double-
        -- counting when Detonator proc damages N other mobs (those would
        -- read sourceTower too, but we already credit the initiating hit).
        if sourceTower and sourceTower.Parent then
            local effective = math.min(amount, data.hp + amount)  -- pre-hit hp = data.hp + amount
            if not isChainDamage then
                local prev = sourceTower:GetAttribute("TotalDamageDone") or 0
                sourceTower:SetAttribute("TotalDamageDone", prev + effective)
                if not sourceTower:GetAttribute("FirstHitTime") then
                    sourceTower:SetAttribute("FirstHitTime", os.clock())
                end
            end
            StatLedger.recordDamage(sourceTower, effective,
                isChainDamage and "chain" or "direct")
        end
        if data.hpFill then
            data.hpFill.Size = UDim2.new(math.max(0, data.hp / data.maxHp), -2, 1, -2)
        end
        if data.hpText then
            data.hpText.Text = string.format("%d / %d", math.max(0, math.floor(data.hp)), data.maxHp)
        end

        -- BloodlinkVine link broadcast (2026-04-28). If this mob is
        -- in a link cluster, echo a fraction of the damage to every
        -- OTHER mob in the same cluster (per-cluster echoFrac). The
        -- _isLinkEcho guard prevents echoes from triggering further
        -- echoes — first-hit dictates the broadcast for that frame.
        --
        -- Link membership lives on data.linkedTo, refreshed once per
        -- updateTowers tick by Towers.lua's BloodlinkVine pre-pass.
        -- Echoed call passes isChainDamage=true so stat-ledger
        -- attribution doesn't double-count for the source tower.
        if not _isLinkEcho and data.linkedTo and amount > 0 then
            for linkTower, echoFrac in pairs(data.linkedTo) do
                if linkTower and linkTower.Parent and (echoFrac or 0) > 0 then
                    local echoDmg = math.max(1, math.floor(amount * echoFrac + 0.5))
                    -- Find every other mob in this same tower's cluster
                    -- and damage it. (data.linkedTo[towerModel] = echoFrac
                    -- on each linked mob, set by the Towers.lua pre-pass.)
                    for other, otherData in pairs(ctx.activeMobs) do
                        if other ~= mob and other.Parent and otherData
                           and otherData.linkedTo
                           and otherData.linkedTo[linkTower] then
                            damageMob(other, echoDmg, linkTower, true, true)
                        end
                    end
                end
            end
        end

        -- Final boss minigame: delegate to FinalBoss.lua — if this is the
        -- active final boss and its HP just crossed a new threshold, the
        -- module starts the windup and schedules BossPhase.
        ctx.checkPhaseTrigger(mob, data)

        if data.hp <= 0 then
            -- DETONATOR: if the killing tower has Detonator attributes set,
            -- spawn a violent shrapnel burst at the dying mob's position and
            -- damage all OTHER mobs in radius. Damage scales with the
            -- EXPLODING mob's MAX HP (the bigger the mob you blow up, the
            -- bigger the boom). Skip if this damage was itself a chain
            -- reaction. Stun/knockback rolls also apply to chained mobs
            -- (apply BEFORE the damage so a kill doesn't strand the roll).
            if sourceTower and not isChainDamage then
                local detRadius = sourceTower:GetAttribute("DetonatorRadius")
                local detPct    = sourceTower:GetAttribute("DetonatorHpPct")
                if detRadius and detPct and detRadius > 0 and detPct > 0 then
                    local detDamage = math.max(1, math.floor(data.maxHp * detPct + 0.5))
                    local centerPos = mob.Position
                    ctx.spawnDetonatorBurst(centerPos, detRadius)
                    for other, _ in pairs(ctx.activeMobs) do
                        if other ~= mob and other.Parent then
                            if (other.Position - centerPos).Magnitude <= detRadius then
                                ctx.applyHitEffects(sourceTower, other)
                                damageMob(other, detDamage, sourceTower, true)  -- chain
                            end
                        end
                    end
                end
            end

            if data.stunStars then
                for _, star in ipairs(data.stunStars) do star:Destroy() end
                data.stunStars = nil
            end
            if mob == ctx.FinalBossState.instance then
                ctx.FinalBossState.instance = nil
            end
            ctx.activeMobs[mob] = nil
            mob:Destroy()
            return true
        end
        return false
    end

    ctx.damageMob = damageMob
end

return Damage
