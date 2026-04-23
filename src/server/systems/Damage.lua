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

local Damage = {}

function Damage.setup(ctx)
    local function damageMob(mob, amount, sourceTower, isChainDamage)
        local data = ctx.activeMobs[mob]
        if not data then return false end
        if data._phoenixQueued then return false end  -- mob is in limbo, invulnerable
        -- Round to the nearest integer at hit time so mobs, HP bars, damage
        -- popups, and stat totals all read as whole numbers. Aux base damages
        -- scaled by rarity (0.91×–1.30×) produce decimals like 1.82 that
        -- look wrong on the HUD and in damage popups. Storage stays float
        -- upstream (Damage attribute, upgrade math) so accumulated bonuses
        -- don't drift — only the HIT amount is integer. Clamped to ≥1 so
        -- a rounding-down-to-0 can't make a tower deal literal zero damage.
        amount = math.max(1, math.floor(amount + 0.5))
        data.hp = data.hp - amount
        ctx.spawnDamageNumber(mob.Position, amount)

        -- Dev STATS panel: track total damage + first-hit time per tower so
        -- the client can display lifetime damage + average DPS. The cap at
        -- the mob's remaining HP (amount could include overkill) keeps the
        -- number honest — we don't want a 999-damage hit on a 10-HP mob to
        -- inflate the stat. Only bump if the hit actually landed on a live
        -- mob (data is still present); skip for chain hits to avoid double-
        -- counting when Detonator proc damages N other mobs (those would
        -- read sourceTower too, but we already credit the initiating hit).
        if sourceTower and sourceTower.Parent and not isChainDamage then
            local effective = math.min(amount, data.hp + amount)  -- pre-hit hp = data.hp + amount
            local prev = sourceTower:GetAttribute("TotalDamageDone") or 0
            sourceTower:SetAttribute("TotalDamageDone", prev + effective)
            if not sourceTower:GetAttribute("FirstHitTime") then
                sourceTower:SetAttribute("FirstHitTime", os.clock())
            end
        end
        if data.hpFill then
            data.hpFill.Size = UDim2.new(math.max(0, data.hp / data.maxHp), -2, 1, -2)
        end
        if data.hpText then
            data.hpText.Text = string.format("%d / %d", math.max(0, math.floor(data.hp)), data.maxHp)
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
