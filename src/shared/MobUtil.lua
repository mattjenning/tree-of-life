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

--[[
    PER-SOURCE SLOW TRACKING (Matthew 2026-04-27)

    Replaces the prior single-slow model (data.slowUntil + data.slowMult)
    with a per-source map: data.slows = { [Tower] = { endsAt, mult } }.

    Mechanics per Matthew:
      • "highest slow mult should take precedence" — strongest slow
        active right now (lowest numerical mult = greatest %) is what
        the mob's movement uses
      • "keep both timers running, so if higher slow runs out, lower
        slow kicks in" — when the dominant source expires, the
        next-strongest active source becomes the effective slow
      • "hitting a slow refreshes that slow's specific timer" — each
        source's timer is independent; a Frost hit only refreshes
        the Frost entry, not Honey's
      • "it can never go back the max of the slow timer" — i.e. each
        hit just resets endsAt to gameNow + slowDuration; no cumulative
        timer extension above the source's slowDuration value

    Visual: one Highlight on the mob colored by the CURRENTLY active
    (strongest) source's SlowEffectColor. When the active source
    changes (dominant expires, weaker takes over), the highlight
    recolors. When no source is active, the highlight clears.
--]]

-- Apply / refresh a slow from `sourceTower` on the mob represented
-- by `data` (= ctx.activeMobs[mob]). Idempotent; calling repeatedly
-- with the same source just refreshes that source's endsAt.
function MobUtil.applySlow(data: any, sourceTower: any, slowPct: number, slowDuration: number, gameNow: number)
    if not data or type(data) ~= "table" then return end
    if not sourceTower then return end
    if not slowPct or slowPct <= 0 or not slowDuration or slowDuration <= 0 then return end
    data.slows = data.slows or {}
    local entry = data.slows[sourceTower]
    if entry then
        entry.endsAt = gameNow + slowDuration
        entry.mult   = 1 - slowPct
    else
        data.slows[sourceTower] = {
            endsAt = gameNow + slowDuration,
            mult   = 1 - slowPct,
        }
    end
end

-- Compute the currently active slow on this mob.
-- Returns (mult, sourceTower) for the strongest active slow, or
-- (nil, nil) if no source is active. Strongest = lowest mult value
-- (= highest slow %). Side effect: prunes expired entries from
-- data.slows so the table doesn't accumulate dead references.
function MobUtil.activeSlow(data: any, gameNow: number): (number?, any?)
    if not data or type(data) ~= "table" or not data.slows then
        return nil, nil
    end
    local bestMult, bestSource = nil, nil
    local toRemove = nil
    for source, slow in pairs(data.slows) do
        if slow.endsAt > gameNow then
            if not bestMult or slow.mult < bestMult then
                bestMult   = slow.mult
                bestSource = source
            end
        else
            toRemove = toRemove or {}
            table.insert(toRemove, source)
        end
    end
    if toRemove then
        for _, k in ipairs(toRemove) do
            data.slows[k] = nil
        end
    end
    return bestMult, bestSource
end

-- Refresh the per-mob slow Highlight to match the currently active
-- slow source. Idempotent; safe to call every frame.
--   • Active source w/ SlowEffectColor → ensure Highlight exists,
--     update color to match
--   • No active source                  → clear Highlight
-- Per Matthew 2026-04-27: "add subtle effect to slowed characters
-- (blue frost for frost melon for example)." Source-tied color
-- (Frost = icy blue, Honey = warm gold) reads as "I can see WHICH
-- slow source is dominating right now" — when Frost expires and
-- Honey takes over, the mob recolors.
function MobUtil.refreshSlowVisual(target: any, data: any, gameNow: number)
    if not data or type(data) ~= "table" then return end
    if not target or not target.Parent then
        MobUtil.clearSlowVisual(data)
        return
    end
    local _, activeSource = MobUtil.activeSlow(data, gameNow)
    if not activeSource then
        MobUtil.clearSlowVisual(data)
        return
    end
    local color = activeSource:GetAttribute("SlowEffectColor")
    if not color then
        -- Source has no defined color — leave any existing visual alone
        -- (the previous source's color persists until something replaces
        -- it). Could clear instead; choosing leave to avoid flickering.
        return
    end
    local hl = data.slowVisual
    if hl and hl.Parent then
        hl.FillColor    = color
        hl.OutlineColor = color
        return
    end
    hl = Instance.new("Highlight")
    hl.Name = "ToL_SlowVisual"
    hl.Adornee = target
    hl.FillColor = color
    hl.OutlineColor = color
    -- Subtle settings: very transparent fill + soft outline. Reads
    -- as "this mob is glowing slightly blue/gold" without becoming
    -- a glaring overlay. Per Matthew "subtle effect" instruction.
    hl.FillTransparency    = 0.80
    hl.OutlineTransparency = 0.40
    hl.DepthMode = Enum.HighlightDepthMode.Occluded
    hl.Parent = target
    data.slowVisual = hl
end

-- Remove the slow visual if present. Used by refreshSlowVisual when
-- no source is active and (defensively) by callers that want to
-- force-clear (e.g. mob dying, run ending).
function MobUtil.clearSlowVisual(data: any)
    if not data or type(data) ~= "table" then return end
    local hl = data.slowVisual
    if hl and hl.Parent then
        hl:Destroy()
    end
    data.slowVisual = nil
end

return MobUtil
