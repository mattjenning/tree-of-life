--!strict
--[[
    MobUtil.lua — Shared mob/heart helpers used across BOTH the wave-system
    mob loop (regular path mobs in MobUpdate.lua) and custom standalone
    mob walkers (Map3BirdBoss eggs).

    WHY THIS MODULE EXISTS:
    The "mob reaches the heart and damages it" path lived in two places
    with hand-copied math:
        heart:SetAttribute("Health", math.max(0, hp - dmg))
    Two paths means two opportunities for them to drift (different damage
    formulas, different signed-overflow guards, etc). Extracting one helper
    locks the canonical "damage to heart = mob's MaxHP, clamped at 0".

    PHOENIX NOTE: the wave-system mob loop wraps this in a Phoenix-grace
    branch (capture-mob OR consume-phoenix-charge OR damage). Phoenix is
    WaveContext-only state, so the wrapping logic stays in MobUpdate; this
    helper is the inner unconditional damage step.
]]

local MobUtil = {}

-- Apply `amount` damage to a heart Part. Damage is clamped so Health never
-- goes below 0. No-op if `heart` is nil or has no Health attribute. Returns
-- the new Health for callers that want to react (e.g. fire game-over).
--
-- Canonical usage:
--   - Wave-system mob walking path-end: amount = data.damage (= MaxHP)
--   - Map3BirdBoss eggs reaching heart: amount = eggHp (= MaxHP)
-- Other amounts are valid but should be rare and commented at the call
-- site to explain the deviation.
function MobUtil.damageHeart(heart: Instance?, amount: number): number
    if not heart or not (heart :: any).GetAttribute then return 0 end
    local hp = (heart :: any):GetAttribute("Health") or 0
    if type(hp) ~= "number" then return 0 end
    local newHp = math.max(0, hp - amount)
    ;(heart :: any):SetAttribute("Health", newHp)
    return newHp
end

return MobUtil
