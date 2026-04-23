--[[
    UpgradeCards.lua — Upgrade picker card generation + application.

    Owns the upgrade RNG and per-pick mutation logic. Called from:
      - onWaveCleared (offers upgrades between waves)
      - remoteUpgradePicked handler (applies the player's choice)
      - Reroll remote handler (fresh card set, caps at WaveConfig.maxRerollsPerStage)
      - GiveFreeReward bindable (first-tower-placed gift)
      - DevAddStun remote (mirrors picking a Stun special)
      - DevSkipToBoss remote (simulates picks to jump to a stage's boss)

    Card shape (passed through Remotes to the client picker UI):

      stat card:
        {kind="stat", stat="Damage"|"Range"|"FireRate",
         rarity=<string>, multiplier=<number>,
         description=<string>, color=Color3}

      special card:
        {kind="special", special="AOE"|"Knockback"|"Stun"|"AmmoCapacity",
         rarity="Special", description=<string>, color=Color3}

    BALANCE INVARIANTS (don't change without design sign-off):
      - Rarity weights per tier: Common 50 / Rare 25 / Exceptional 10 /
        Legendary 5 / Mythical 2 / Special 8.
      - Stat multiplier ranges per rarity (RARITY_MULTS below).
      - Range cards multiply the bonus portion by 0.8 — Range compounds
        multiplicatively across picks and gets out of hand at high
        rarities if allowed to roll the same range as Damage/FireRate.
      - Upgrade cards use the Base + BonusPct pattern: additive not
        compounding. 10 stacked +20% picks = +200% bonus, NOT 1.20^10.

    setup(ctx) reads:
      ctx.WaveConfig.maxRerollsPerStage

    And publishes:
      ctx.generateCardsForPlayer(player, waveIndex) → payload
      ctx.applyUpgrade(player, upgrade)
      ctx.simulateOnePick(player)              -- used by DevSkipToBoss
      ctx.applyStunStackToOwnedTowers(player)  -- used by DevAddStun
      ctx.rollRarity() → rarity name           -- utility
      ctx.getTierColor(rarity) → Color3        -- utility
      ctx.RARITY_TO_SCORE                      -- int score per rarity
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags = require(Shared:WaitForChild("Tags"))

-- Module-scope tables are treated as immutable reference data.
local RARITY_TIERS = {
    {name = "Common",      weight = 50, color = Color3.fromRGB(200, 200, 200)},
    {name = "Rare",        weight = 25, color = Color3.fromRGB(80, 150, 255)},
    {name = "Exceptional", weight = 10, color = Color3.fromRGB(180, 80, 220)},
    {name = "Legendary",   weight = 5,  color = Color3.fromRGB(255, 170, 40)},
    {name = "Mythical",    weight = 2,  color = Color3.fromRGB(255, 60,  140)},
    {name = "Special",     weight = 8,  color = Color3.fromRGB(60, 220, 200)},
}

-- Per-rarity multiplier ranges for stat upgrades (Damage / Range / FireRate)
local RARITY_MULTS = {
    Common      = {min = 1.10, max = 1.20},
    Rare        = {min = 1.20, max = 1.35},
    Exceptional = {min = 1.35, max = 1.50},
    Legendary   = {min = 1.50, max = 1.65},
    Mythical    = {min = 1.65, max = 2.00},
}

-- Special bonus pool. All specials stack and can be rolled repeatedly.
local SPECIAL_TYPES = {"AOE", "Knockback", "Stun", "AmmoCapacity"}

-- For each special: attr name, base value (first time it's added),
-- increment value (each subsequent stack).
-- AmmoCapacity is a combo special: it both bumps the player's MaxCarry by
-- +10 AND doubles every owned tower's MaxShots.
local SPECIAL_EFFECTS = {
    AOE          = {attr = "AoeRadius",    base = 4,    increment = 2},
    Knockback    = {attr = "Knockback",    base = 2,    increment = 1},
    Stun         = {attr = "StunDuration", base = 0.2,  increment = 0.2},
    AmmoCapacity = {playerCarryDelta = 10, towerShotsMult = 2.0},  -- custom apply
}

-- RUN LUCK: numeric mapping for rarity names. Used by generateCardsForPlayer
-- to track running average across all cards offered this run, exposed to the
-- client via the RunLuckSum + RunLuckCount player attributes (and reset by
-- RunReset). Specials roll about as often as Exceptionals (8% vs 10%) and
-- are clearly mid-to-high value, so we score them at 3.
local RARITY_TO_SCORE = {
    Common = 1, Rare = 2, Exceptional = 3, Legendary = 4, Mythical = 5,
    Special = 3,
}

-- DEV_PICK_SCORE — used only by the dev simulator to rank cards for
-- "which is best to greedy-pick". Higher than RARITY_TO_SCORE for
-- Specials because a stacking effect usually outvalues a +20% stat bump.
local DEV_PICK_SCORE = {
    Mythical = 6,
    Special = 5,
    Legendary = 4,
    Exceptional = 3,
    Rare = 2,
    Common = 1,
}

local UpgradeCards = {}

function UpgradeCards.setup(ctx)
    local WaveConfig = ctx.WaveConfig

    local function describeSpecial(special, hasAlready)
        local eff = SPECIAL_EFFECTS[special]
        if special == "AmmoCapacity" then
            return string.format("+%d carry, double tower ammo", eff.playerCarryDelta)
        elseif special == "AOE" then
            if hasAlready then
                return string.format("Improve AOE (+%g radius)", eff.increment)
            else
                return string.format("Add AOE (+%g radius)", eff.base)
            end
        elseif special == "Knockback" then
            if hasAlready then
                return string.format("Improve Knockback (+%g)", eff.increment)
            else
                return string.format("Add Knockback (+%g, 10%% chance)", eff.base)
            end
        elseif special == "Stun" then
            if hasAlready then
                return string.format("Improve Stun (+%gs)", eff.increment)
            else
                return string.format("Add Stun (+%gs, 10%% chance)", eff.base)
            end
        end
        return special
    end

    local function rollRarity()
        local total = 0
        for _, tier in ipairs(RARITY_TIERS) do total = total + tier.weight end
        local r = math.random() * total
        local acc = 0
        for _, tier in ipairs(RARITY_TIERS) do
            acc = acc + tier.weight
            if r <= acc then return tier.name end
        end
        return "Common"
    end

    local function getTierColor(name)
        for _, tier in ipairs(RARITY_TIERS) do
            if tier.name == name then return tier.color end
        end
        return Color3.fromRGB(200, 200, 200)
    end

    -- Roll a stat upgrade card for a specific stat (Damage/Range/FireRate).
    -- Returns a table with rarity, kind="stat", stat, multiplier, description.
    -- For Damage cards we ALSO include flatDamage so the client can show "+12 damage"
    -- which requires knowing the player's CURRENT damage at card-show time.
    local function rollStatCard(rarity, stat, currentDamage)
        local m = RARITY_MULTS[rarity]
        local mult = m.min + math.random() * (m.max - m.min)
        -- Range is 20% weaker than Damage/FireRate at every rarity. Range
        -- compounds multiplicatively per pick and gets out of hand fast at high
        -- rarities, so we shrink the bonus portion (mult - 1) by 20%.
        if stat == "Range" then
            mult = 1 + (mult - 1) * 0.8
        end
        local pct = math.floor((mult - 1) * 100 + 0.5)
        local desc
        if stat == "Damage" then
            local flat = math.floor((currentDamage or 0) * (mult - 1) + 0.5)
            desc = string.format("+%d damage", flat)
        elseif stat == "Range" then
            desc = string.format("+%d%% Range", pct)
        elseif stat == "FireRate" then
            desc = string.format("+%d%% Fire Rate", pct)
        else
            desc = string.format("+%d%% %s", pct, stat)
        end
        return {
            kind = "stat",
            rarity = rarity,
            stat = stat,
            multiplier = mult,
            description = desc,
        }
    end

    -- Returns true if any of the player's towers already has the given special.
    -- AmmoCapacity returns false because its wording is the same regardless of
    -- prior stacks ("+10 carry, double tower ammo").
    local function playerHasSpecial(player, special)
        if special == "AmmoCapacity" then return false end
        local effect = SPECIAL_EFFECTS[special]
        if not effect or not effect.attr then return false end
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local tower = towerBase.Parent
            if tower and tower:GetAttribute("Owner") == player.UserId then
                local val = tower:GetAttribute(effect.attr)
                if val and type(val) == "number" and val > 0 then return true end
            end
        end
        return false
    end

    -- Roll a special bonus card for the given player. All specials are now
    -- repeatable, so no pool exclusions. Card text reflects whether the player
    -- already owns the rolled special ("Add" vs "Improve" wording).
    -- excludeSet (optional): {[specialName]=true} — types to skip when rolling.
    -- Caller passes this to prevent duplicate Special cards in the same picker.
    local function rollSpecialCard(player, excludeSet)
        excludeSet = excludeSet or {}
        local pool = {}
        for _, t in ipairs(SPECIAL_TYPES) do
            if not excludeSet[t] then table.insert(pool, t) end
        end
        if #pool == 0 then pool = SPECIAL_TYPES end
        local pick = pool[math.random(1, #pool)]
        local hasAlready = playerHasSpecial(player, pick)
        return {
            kind = "special",
            rarity = "Special",
            special = pick,
            description = describeSpecial(pick, hasAlready),
        }
    end

    local function getPlayerBaseDamage(player)
        local maxBase = 0
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local tower = towerBase.Parent
            if tower and tower:GetAttribute("Owner") == player.UserId then
                local d = tower:GetAttribute("DamageBase")
                      or tower:GetAttribute("Damage")  -- legacy fallback
                      or 0
                if d > maxBase then maxBase = d end
            end
        end
        return maxBase
    end

    local function generateCardsForPlayer(player, waveIndex)
        local stats = {"Damage", "Range", "FireRate"}
        local currentDamage = getPlayerBaseDamage(player)

        local cards = {}
        local usedSpecials = {}  -- {[specialName]=true} — prevents duplicate Special cards
        -- ALWAYS produce one card per stat slot. Rarity is rolled per slot.
        -- If a slot rolls "Special", swap it for a Special bonus card instead,
        -- excluding any Special types already drawn earlier in this picker.
        for _, stat in ipairs(stats) do
            local rarity = rollRarity()
            local card
            if rarity == "Special" then
                card = rollSpecialCard(player, usedSpecials)
                usedSpecials[card.special] = true
            else
                card = rollStatCard(rarity, stat, currentDamage)
            end
            card.color = getTierColor(card.rarity)
            table.insert(cards, card)
        end

        local rerollsUsed = player:GetAttribute("RerollsUsed") or 0
        return {
            wave = waveIndex,
            cards = cards,
            rerollsRemaining = math.max(0, WaveConfig.maxRerollsPerStage - rerollsUsed),
        }
    end

    -- applyUpgrade(player, upgrade): apply an upgrade payload to the player's
    -- towers as if they had just picked it from the upgrade picker. Updates
    -- RUN LUCK tracking. Used by the remoteUpgradePicked handler AND by the
    -- dev "skip to boss" path (which synthesizes picks server-side).
    --
    -- Upgrade payload shape (matches what generateCardsForPlayer produces):
    --   stat card:    {kind="stat", stat=..., multiplier=..., rarity=..., description=...}
    --   special card: {kind="special", special=..., rarity="Special", description=...}
    local function applyUpgrade(player, upgrade)
        if type(upgrade) ~= "table" then return end
        local kind = upgrade.kind or "stat"  -- legacy cards default to stat

        -- RUN LUCK tracking: score this pick by its rarity. Validation: trust
        -- only the known rarity names; anything else (or missing) scores 1
        -- so a malicious client can't inflate by sending rarity="Mythical".
        do
            local pickedScore = RARITY_TO_SCORE[upgrade.rarity] or 1
            local prevSum   = player:GetAttribute("RunLuckSum")   or 0
            local prevCount = player:GetAttribute("RunLuckCount") or 0
            player:SetAttribute("RunLuckSum",   prevSum + pickedScore)
            player:SetAttribute("RunLuckCount", prevCount + 1)
        end

        -- STAT UPGRADE: ADDITIVE bonus percentages. Each pick adds (mult-1)*100
        -- to a cumulative ${Stat}BonusPct attribute, then recomputes the live
        -- stat from the immutable base. This avoids exponential compounding
        -- (10 stacked +20% picks = +200% bonus, NOT 1.20^10 = +519%).
        if kind == "stat" then
            local stat = upgrade.stat
            local mult = tonumber(upgrade.multiplier)
            if not stat or not mult then return end
            if stat ~= "Damage" and stat ~= "Range" and stat ~= "FireRate" then return end
            if mult < 1 or mult > 5 then return end
            local addedPct = (mult - 1) * 100
            for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local towerModel = towerBase.Parent
                if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
                    -- Fall back to the current value as the "base" for legacy
                    -- towers placed before the BaseStat snapshots existed.
                    local baseVal = towerModel:GetAttribute(stat .. "Base")
                    if not baseVal then
                        baseVal = towerModel:GetAttribute(stat) or 0
                        towerModel:SetAttribute(stat .. "Base", baseVal)
                    end
                    local curBonusPct = towerModel:GetAttribute(stat .. "BonusPct") or 0
                    local newBonusPct = curBonusPct + addedPct
                    towerModel:SetAttribute(stat .. "BonusPct", newBonusPct)
                    towerModel:SetAttribute(stat, baseVal * (1 + newBonusPct / 100))
                end
            end
            print(("[Waves] %s picked %s upgrade: %s (+%g%% → cumulative %s bonus)"):format(
                player.Name, upgrade.rarity or "?", upgrade.description or "?",
                addedPct, stat))

        -- SPECIAL: AOE / Knockback / Stun / AmmoCapacity
        elseif kind == "special" then
            local special = upgrade.special
            local effect = SPECIAL_EFFECTS[special]
            if not effect then return end

            if special == "AmmoCapacity" then
                -- Bump the player's carry cap by +playerCarryDelta. Fallback
                -- mirrors the hub's starting capacity (15).
                local curCarry = player:GetAttribute("MaxCarry") or 15
                player:SetAttribute("MaxCarry", curCarry + effect.playerCarryDelta)
                -- Double every owned tower's MaxShots (cap only — current Shots unchanged)
                for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                    local towerModel = towerBase.Parent
                    if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
                        local maxShots = towerModel:GetAttribute("MaxShots") or 50
                        towerModel:SetAttribute("MaxShots", math.floor(maxShots * effect.towerShotsMult + 0.5))
                    end
                end
            else
                -- AOE / Knockback / Stun: stack on each owned tower
                for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                    local towerModel = towerBase.Parent
                    if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
                        local current = towerModel:GetAttribute(effect.attr)
                        if current then
                            towerModel:SetAttribute(effect.attr, current + effect.increment)
                        else
                            towerModel:SetAttribute(effect.attr, effect.base)
                        end
                    end
                end
            end
            print(("[Waves] %s picked SPECIAL: %s"):format(player.Name, special))
        end
    end

    -- Return the highest RangeBonusPct across the player's owned towers.
    -- (They should all be the same since picks apply to all owned towers,
    --  but be defensive.)
    local function getPlayerRangeBonus(player)
        local maxBonus = 0
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local t = towerBase.Parent
            if t and t:GetAttribute("Owner") == player.UserId then
                local b = t:GetAttribute("RangeBonusPct") or 0
                if b > maxBonus then maxBonus = b end
            end
        end
        return maxBonus
    end

    -- Synthesize a single player's pick using the greedy "highest rarity,
    -- skip Range if already 60%+, skip AmmoCapacity" strategy. Used by the
    -- DevSkipToBoss handler to simulate the picks a player WOULD have made
    -- if they'd played through the waves they're skipping.
    local function simulateOnePick(player)
        local payload = generateCardsForPlayer(player, 0)
        local cards = payload.cards or {}
        if #cards == 0 then return end

        -- Sort indexes by DEV_PICK_SCORE descending, stable on original index
        local order = {}
        for i = 1, #cards do order[i] = i end
        table.sort(order, function(a, b)
            local sa = DEV_PICK_SCORE[cards[a].rarity] or 0
            local sb = DEV_PICK_SCORE[cards[b].rarity] or 0
            if sa ~= sb then return sa > sb end
            return a < b
        end)

        local rangeBonus = getPlayerRangeBonus(player)
        local pickIdx = nil
        for _, i in ipairs(order) do
            local c = cards[i]
            local isRange = (c.kind == "stat" and c.stat == "Range")
            local isAmmoCap = (c.kind == "special" and c.special == "AmmoCapacity")
            if isRange and rangeBonus >= 60 then
                -- Skip — Range is already capped per the user's preference
            elseif isAmmoCap then
                -- Skip — AmmoCapacity is a QoL pick that doesn't contribute to
                -- DPS, and the dev simulator is meant to produce a combat-ready
                -- tower to fight the boss. Leave it for the real player to pick.
            else
                pickIdx = i
                break
            end
        end

        -- Fallback: if every card was skipped (extremely rare), pick the first.
        if not pickIdx then pickIdx = order[1] end
        applyUpgrade(player, cards[pickIdx])
    end

    -- Apply one Stun stack to each of the player's owned towers, using the
    -- same SPECIAL_EFFECTS.Stun base/increment the special-card path uses.
    -- Called by the DevAddStun remote handler; bypasses the upgrade-picked
    -- path so it doesn't inflate RUN LUCK. Returns number of towers touched.
    local function applyStunStackToOwnedTowers(player)
        local effect = SPECIAL_EFFECTS.Stun
        if not effect then return 0 end
        local touched = 0
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local towerModel = towerBase.Parent
            if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
                local current = towerModel:GetAttribute(effect.attr)
                if current then
                    towerModel:SetAttribute(effect.attr, current + effect.increment)
                else
                    towerModel:SetAttribute(effect.attr, effect.base)
                end
                touched = touched + 1
            end
        end
        return touched
    end

    -- Publish
    ctx.generateCardsForPlayer      = generateCardsForPlayer
    ctx.applyUpgrade                = applyUpgrade
    ctx.simulateOnePick             = simulateOnePick
    ctx.applyStunStackToOwnedTowers = applyStunStackToOwnedTowers
    ctx.rollRarity                  = rollRarity
    ctx.getTierColor                = getTierColor
    ctx.RARITY_TO_SCORE             = RARITY_TO_SCORE
end

return UpgradeCards
