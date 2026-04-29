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

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Tags        = require(Shared:WaitForChild("Tags"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))
local Rarity      = require(Shared:WaitForChild("Rarity"))
local Config      = require(Shared:WaitForChild("Config"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))

-- Classify a tower as Core (starter / Power) vs Aux (temp-tower rewards).
-- Used for target-routed upgrades on map 2+: cards can target one category
-- only, so AOE pickers on a Core card don't accidentally splash onto Aux
-- towers and vice versa.
local function towerCategory(towerModel)
    local t = towerModel:GetAttribute("TowerType")
    if TempTowers.Templates[t] then return "Aux" end
    return "Core"
end

-- Does a card target a given tower? "All" = yes; "Core" or "Aux" = match the
-- tower's own category. nil target is treated as "All" (legacy map-1 cards).
local function upgradeAppliesTo(target, towerModel)
    if not target or target == "All" then return true end
    return target == towerCategory(towerModel)
end

-- Upgrade-picker tier weights. Colors + names come from shared/Rarity so
-- every module that renders rarity (attachment cards, tower info, Phoenix
-- cooldown fill) reads the same palette.
local RARITY_TIERS = {
    {name = Rarity.Names[1], weight = 50, color = Rarity.Colors[1]},  -- Common
    {name = Rarity.Names[2], weight = 25, color = Rarity.Colors[2]},  -- Rare
    {name = Rarity.Names[3], weight = 10, color = Rarity.Colors[3]},  -- Exceptional
    {name = Rarity.Names[4], weight = 5,  color = Rarity.Colors[4]},  -- Legendary
    {name = Rarity.Names[5], weight = 2,  color = Rarity.Colors[5]},  -- Mythical
    {name = Rarity.Names[6], weight = 8,  color = Rarity.Colors[6]},  -- Special
}

-- Per-rarity multiplier ranges for stat upgrades (Range / FireRate).
-- Damage uses DAMAGE_FLAT_TIERS below — flat numbers, not percentages.
-- The 20× base-damage spread across aux towers (HoneyHive 2 → Mortar 40)
-- made shared % cards wildly inconsistent; flat + per-map scaling keeps
-- every Damage pick equally meaningful on every tower.
local RARITY_MULTS = {
    Common      = {min = 1.10, max = 1.20},
    Rare        = {min = 1.20, max = 1.35},
    Exceptional = {min = 1.35, max = 1.50},
    Legendary   = {min = 1.50, max = 1.65},
    Mythical    = {min = 1.65, max = 2.00},
}

-- Flat Damage bonus tiers (map 1 baseline). A pick lands a random integer
-- in [min, max] scaled by MAP_DAMAGE_SCALE[currentMapId]. Sized so a
-- Mythical matches roughly what an 80% × base-18 Core card would do on
-- map 1 (~14 flat); aux towers with smaller bases get the same bump.
local DAMAGE_FLAT_TIERS = {
    Common      = {min = 2,  max = 4 },
    Rare        = {min = 4,  max = 6 },
    Exceptional = {min = 6,  max = 9 },
    Legendary   = {min = 9,  max = 12},
    Mythical    = {min = 12, max = 18},
}

-- Per-map scale factor for flat Damage picks. Mob HP on map 2 is ~3.4×
-- map 1; map 3 will be ~6× once tuned. Cards scale to match so picks
-- stay meaningful deep into the run. Falls back to 1 for unknown maps.
local MAP_DAMAGE_SCALE = { [1] = 1, [2] = 3, [3] = 6 }

-- Special bonus pool. All specials stack and can be rolled repeatedly.
-- AmmoCapacity removed from the special pool — the ammo system was
-- retired (towers fire unlimited). Kept the SPECIAL_EFFECTS entry for
-- reference but the pool no longer rolls it.
local SPECIAL_TYPES = {"AOE", "Knockback", "Stun"}

-- For each special: attr name, base value (first time it's added),
-- increment value (each subsequent stack).
-- AmmoCapacity is a combo special: it both bumps the player's MaxCarry by
-- +10 AND doubles every owned tower's MaxShots.
-- SPECIAL_EFFECTS
--   attr / base       — the fixed duration/distance of the effect
--   chanceAttr / chanceBase / chanceIncrement — per-proc chance stored on
--     the tower; FIRST pick sets chanceBase, each subsequent pick adds
--     chanceIncrement. The magnitude (base) never stacks — only the
--     chance does. Keeps stacked specials from getting out of hand
--     while still making repeat picks worthwhile.
local SPECIAL_EFFECTS = {
    AOE          = {attr = "AoeRadius",    base = 4,   increment = 2},  -- linear, keeps stacking
    Knockback    = {attr = "Knockback",    base = 3,
                    chanceAttr = "KnockbackChance", chanceBase = 0.05, chanceIncrement = 0.01},
    Stun         = {attr = "StunDuration", base = 0.5,
                    chanceAttr = "StunChance",     chanceBase = 0.05, chanceIncrement = 0.01},
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
                return string.format("Improved +%d%% knockback chance", eff.chanceIncrement * 100)
            else
                return string.format("Add Knockback (%g studs, %d%% chance)",
                    eff.base, eff.chanceBase * 100)
            end
        elseif special == "Stun" then
            if hasAlready then
                return string.format("Improved +%d%% stun chance", eff.chanceIncrement * 100)
            else
                return string.format("Add Stun (%gs, %d%% chance)",
                    eff.base, eff.chanceBase * 100)
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
    local function rollStatCard(rarity, stat, _currentDamage)
        -- Damage cards: flat integer amount, scaled by the current map.
        -- Same flat number applies to Core AND Aux regardless of base
        -- damage — the whole point of the flat system. `multiplier` is
        -- omitted on Damage cards so applyUpgrade can route by presence
        -- of `flat` vs `multiplier`.
        if stat == "Damage" then
            local tier = DAMAGE_FLAT_TIERS[rarity] or DAMAGE_FLAT_TIERS.Common
            local mapId = (ctx.StageState and ctx.StageState.currentMapId) or 1
            local scale = MAP_DAMAGE_SCALE[mapId] or 1
            local flat = math.random(tier.min, tier.max) * scale
            return {
                kind = "stat",
                rarity = rarity,
                stat = "Damage",
                flat = flat,
                description = string.format("+%d damage", flat),
            }
        end

        -- Range / FireRate still use % multipliers — no base-spread issue
        -- since these stats are already proportional to their base values.
        local m = RARITY_MULTS[rarity]
        local mult = m.min + math.random() * (m.max - m.min)
        -- Per-stat shrink factor applied to the bonus portion only:
        --   Range    × 0.80 — compounds hard at high rarities
        --   FireRate × 0.90 — tuned 10% down in v5.11 after shots-per-sec
        --                     was outpacing both ammo cap and visual
        --                     response on upgraded Core towers.
        if stat == "Range" then
            mult = 1 + (mult - 1) * 0.8
        elseif stat == "FireRate" then
            mult = 1 + (mult - 1) * 0.9
        end
        local pct = math.floor((mult - 1) * 100 + 0.5)
        local desc
        if stat == "Range" then
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

    local function generateCardsForPlayer(player, waveIndex)
        local stats = {"Damage", "Range", "FireRate"}

        -- Target policy:
        --   Map 1: ALL cards target Core only. Even if the player has an
        --          Aux permanent tower equipped from a prior Pickle Lord
        --          kill, map 1 is the "warm up your Core tower" phase.
        --   Map 2+: each stat card independently rolls Core or Aux (50/50).
        --           Specials still target Core only (Aux towers have their
        --           own baked-in mechanics; stacking would double-dip).
        local mapId = (ctx.StageState and ctx.StageState.currentMapId) or 1
        local mapEntry = MapRegistry.get(mapId)
        local splitTargets = mapEntry and mapEntry.splitTargets or false

        local cards = {}
        local usedSpecials = {}  -- {[specialName]=true} — prevents duplicate Special cards
        for _, stat in ipairs(stats) do
            local rarity = rollRarity()
            local card
            if rarity == "Special" then
                card = rollSpecialCard(player, usedSpecials)
                usedSpecials[card.special] = true
                card.target = "Core"
            else
                card = rollStatCard(rarity, stat)
                if splitTargets then
                    card.target = (math.random() < 0.5) and "Core" or "Aux"
                else
                    card.target = "Core"  -- map 1: Core-only
                end
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
            -- Per-map pick tally (for DevSkipToBoss's `stage*4 - picks`
            -- math). Separate from RunLuckCount so the run-wide luck
            -- display stays cumulative across maps while DevSkipToBoss
            -- still simulates the right number of picks per map.
            local prevMapCount = player:GetAttribute("MapPickCount") or 0
            player:SetAttribute("MapPickCount", prevMapCount + 1)
        end

        -- STAT UPGRADE routing — Damage and Range/FireRate diverge:
        --   Damage:  flat additive. Tower gets DamageFlat += upgrade.flat.
        --            Player gets <Category>DamageFlat += upgrade.flat.
        --            Per-map scaling on the card generation side.
        --   Range / FireRate: additive bonus percentages. Tower gets
        --            <Stat>BonusPct += (mult-1)*100. No exponential
        --            compounding (10 stacked +20% = +200%, not +519%).
        --
        -- TARGET ROUTING: `upgrade.target` = "Core" / "Aux" / "All" / nil.
        -- Map 1 cards target Core only. Map 2+ cards roll Core or Aux per
        -- card. Specials (Core-only) handled in their own branch below.
        -- Per-player cumulative attrs let freshly-placed towers inherit
        -- existing upgrades rather than starting at 0 — critical for
        -- map-2 Core respawns.
        if kind == "stat" then
            local stat = upgrade.stat
            if stat ~= "Damage" and stat ~= "Range" and stat ~= "FireRate" then return end
            local target = upgrade.target or "All"

            -- DAMAGE: flat additive. Adds `upgrade.flat` directly to each
            -- matching tower's live Damage and to the per-player cumulative
            -- `<Category>DamageFlat` bucket that freshly-placed towers
            -- inherit. Same flat works for Core's base-18 AND Aux's 2-40
            -- spread — every pick is equally meaningful on every tower.
            if stat == "Damage" then
                local flat = tonumber(upgrade.flat)
                if not flat or flat <= 0 then return end

                -- Aux splits the flat evenly across the player's current
                -- aux roster (the card offers a shared pool, not a per-tower
                -- multiplier). Core is a single tower — no split. Future aux
                -- placements inherit `AuxDamageFlat`, which we bump by the
                -- per-tower share so a fresh aux lines up with existing ones.
                -- Edge: 0 aux placed → no division, full bump to AuxDamageFlat
                -- so the next-placed aux gets the whole bonus.
                local function resolveShares()
                    local shares = { Core = flat, Aux = flat }
                    if target == "Aux" or target == "All" then
                        local auxCount = 0
                        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                            local t = towerBase.Parent
                            if t and t:GetAttribute("Owner") == player.UserId
                               and towerCategory(t) == "Aux" then
                                auxCount = auxCount + 1
                            end
                        end
                        if auxCount > 1 then
                            shares.Aux = math.max(1, math.floor(flat / auxCount + 0.5))
                        end
                    end
                    return shares
                end
                local shares = resolveShares()

                for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                    local towerModel = towerBase.Parent
                    if towerModel and towerModel:GetAttribute("Owner") == player.UserId
                       and upgradeAppliesTo(target, towerModel) then
                        local cat = towerCategory(towerModel)
                        local share = shares[cat] or flat
                        -- 2026-04-28 dr: ControlCore damage upgrade
                        -- splits 80% Damage / 20% StackDotTickDmg per
                        -- Matthew "for controlcore damage upgrade,
                        -- give 80% to tower and 20% to the dot tick."
                        -- Player attribute bucket (CoreDamageFlat)
                        -- still records the full pick value; the
                        -- split happens at apply-time on each
                        -- ControlCore (live here, plus inherited at
                        -- placement-time in TowerPlacement.lua).
                        local damageShare, dotShare = share, 0
                        if towerModel:GetAttribute("TowerType") == "ControlCore" then
                            damageShare = math.floor(share * 0.8 + 0.5)
                            dotShare = share - damageShare  -- exact split (no rounding loss)
                        end
                        -- Damage path
                        local baseVal = towerModel:GetAttribute("DamageBase")
                        if not baseVal then
                            baseVal = towerModel:GetAttribute("Damage") or 0
                            towerModel:SetAttribute("DamageBase", baseVal)
                        end
                        local curFlat = towerModel:GetAttribute("DamageFlat") or 0
                        local newFlat = curFlat + damageShare
                        towerModel:SetAttribute("DamageFlat", newFlat)
                        towerModel:SetAttribute("Damage", baseVal + newFlat)
                        -- StackDotTickDmg path (ControlCore only)
                        if dotShare > 0 then
                            local dotBase = towerModel:GetAttribute("StackDotTickDmgBase")
                            if not dotBase then
                                dotBase = towerModel:GetAttribute("StackDotTickDmg") or 0
                                towerModel:SetAttribute("StackDotTickDmgBase", dotBase)
                            end
                            local curDotFlat = towerModel:GetAttribute("StackDotTickDmgFlat") or 0
                            local newDotFlat = curDotFlat + dotShare
                            towerModel:SetAttribute("StackDotTickDmgFlat", newDotFlat)
                            towerModel:SetAttribute("StackDotTickDmg", dotBase + newDotFlat)
                        end
                    end
                end

                local function bumpPlayerFlat(category)
                    local attr = category .. "DamageFlat"
                    local cur = player:GetAttribute(attr) or 0
                    player:SetAttribute(attr, cur + (shares[category] or flat))
                end
                if target == "All" then
                    bumpPlayerFlat("Core")
                    bumpPlayerFlat("Aux")
                elseif target == "Core" or target == "Aux" then
                    bumpPlayerFlat(target)
                end

                print(("[Waves] %s picked %s %s Damage upgrade: %s (+%d total, +%d/tower → cumulative %s DamageFlat)"):format(
                    player.Name, target, upgrade.rarity or "?", upgrade.description or "?",
                    flat, shares[target] or flat, target))
                return
            end

            -- RANGE / FIRERATE: additive bonus percentages (unchanged).
            local mult = tonumber(upgrade.multiplier)
            if not mult or mult < 1 or mult > 5 then return end
            local addedPct = (mult - 1) * 100

            for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local towerModel = towerBase.Parent
                if towerModel and towerModel:GetAttribute("Owner") == player.UserId
                   and upgradeAppliesTo(target, towerModel) then
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

            local function bumpPlayerPct(category)
                local attr = category .. stat .. "Pct"
                local cur = player:GetAttribute(attr) or 0
                player:SetAttribute(attr, cur + addedPct)
            end
            if target == "All" then
                bumpPlayerPct("Core")
                bumpPlayerPct("Aux")
            elseif target == "Core" or target == "Aux" then
                bumpPlayerPct(target)
            end

            print(("[Waves] %s picked %s %s upgrade: %s (+%g%% → cumulative %s bonus)"):format(
                player.Name, target, upgrade.rarity or "?", upgrade.description or "?",
                addedPct, stat))

        -- SPECIAL: AOE / Knockback / Stun / AmmoCapacity.
        -- Specials are ALWAYS Core-only. Aux towers have their own
        -- mechanics baked into their rarity-scaled stats (slow, chain,
        -- pierce, cloud, patch, lob, etc.) so bolting on upgrade-card
        -- specials on top would double-dip. Specials therefore skip any
        -- tower whose category is "Aux" and only mirror into the
        -- Core-cumulative attributes.
        elseif kind == "special" then
            local special = upgrade.special
            local effect = SPECIAL_EFFECTS[special]
            if not effect then return end

            if special == "AmmoCapacity" then
                -- Carry cap is a player-level thing (ammo piles), apply as-is.
                local curCarry = player:GetAttribute("MaxCarry") or 15
                player:SetAttribute("MaxCarry", curCarry + effect.playerCarryDelta)
                -- MaxShots bump only applies to Core towers (Aux has NoAmmo).
                for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                    local towerModel = towerBase.Parent
                    if towerModel and towerModel:GetAttribute("Owner") == player.UserId
                       and towerCategory(towerModel) == "Core" then
                        local maxShots = towerModel:GetAttribute("MaxShots") or 50
                        towerModel:SetAttribute("MaxShots",
                            math.floor(maxShots * effect.towerShotsMult + 0.5))
                    end
                end
                -- Mirror into Core cumulative so future Core placements inherit
                -- the ammo-cap multiplier.
                local curCoreMult = player:GetAttribute("CoreMaxShotsMult") or 1.0
                player:SetAttribute("CoreMaxShotsMult", curCoreMult * effect.towerShotsMult)
            else
                -- AOE / Knockback / Stun: Core-only stacking.
                --   AOE: linear — each pick adds `increment` to AoeRadius.
                --   Knockback / Stun: MAGNITUDE FIXED on first pick
                --     (base studs / seconds, never grows). Each subsequent
                --     pick adds `chanceIncrement` to the per-proc chance
                --     attribute (capped at 100%). Keeps stacked picks
                --     meaningful without making a single hit push a mob
                --     halfway across the map.
                local chanceAttr = effect.chanceAttr  -- nil for AOE → plain additive path
                for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                    local towerModel = towerBase.Parent
                    if towerModel and towerModel:GetAttribute("Owner") == player.UserId
                       and towerCategory(towerModel) == "Core" then
                        local current = towerModel:GetAttribute(effect.attr)
                        if chanceAttr then
                            -- Magnitude only set on first pick; chance stacks.
                            if not current then
                                towerModel:SetAttribute(effect.attr, effect.base)
                                towerModel:SetAttribute(chanceAttr, effect.chanceBase)
                            else
                                local curChance = towerModel:GetAttribute(chanceAttr) or effect.chanceBase
                                towerModel:SetAttribute(chanceAttr,
                                    math.min(1, curChance + effect.chanceIncrement))
                            end
                        else
                            -- Linear path (AOE).
                            if current then
                                towerModel:SetAttribute(effect.attr, current + effect.increment)
                            else
                                towerModel:SetAttribute(effect.attr, effect.base)
                            end
                        end
                    end
                end
                -- Mirror into Core cumulative so future Core placements
                -- inherit the same magnitude + chance.
                local coreAttr = "Core" .. effect.attr
                local curCore = player:GetAttribute(coreAttr)
                if chanceAttr then
                    local coreChanceAttr = "Core" .. chanceAttr
                    if not curCore then
                        player:SetAttribute(coreAttr, effect.base)
                        player:SetAttribute(coreChanceAttr, effect.chanceBase)
                    else
                        local curC = player:GetAttribute(coreChanceAttr) or effect.chanceBase
                        player:SetAttribute(coreChanceAttr,
                            math.min(1, curC + effect.chanceIncrement))
                    end
                else
                    if curCore then
                        player:SetAttribute(coreAttr, curCore + effect.increment)
                    else
                        player:SetAttribute(coreAttr, effect.base)
                    end
                end
            end
            print(("[Waves] %s picked SPECIAL (Core-only): %s"):format(player.Name, special))
        end
    end

    -- Return the MIN live Range attribute across the player's owned
    -- towers in a category. Used by simulateOnePick to aim for a
    -- per-tower range floor by the time the player reaches the
    -- Pickle Lord.
    --
    -- WHEN NO TOWERS EXIST — the dev-port simulator runs picks
    -- BEFORE the player places anything, so we have no live tower
    -- to read Range from. We ESTIMATE from the player's cumulative
    -- bonus attribute (`<Category>RangePct`) applied to a baseline
    -- 30-stud tower (Power's default). Without this fallback the
    -- simulator returned math.huge with no towers placed → range
    -- cards SKIPPED on every pick → the player ended up at 0%
    -- range bonus heading into Pickle Lord even with the new goal
    -- logic. (Surfaced 2026-04-26 playtest: "Power Tower Range:
    -- 24" after dev-port to Pickle Lord.)
    local BASELINE_BASE_RANGE = Config.UpgradeCards.BaselineBaseRange
    local function getMinRangeByCategory(player, category)
        local minRange = math.huge
        local found = false
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local t = towerBase.Parent
            if t and t:GetAttribute("Owner") == player.UserId
                   and towerCategory(t) == category then
                local r = t:GetAttribute("Range") or 0
                if r < minRange then minRange = r end
                found = true
            end
        end
        if not found then
            local pct = player:GetAttribute(category .. "RangePct") or 0
            return BASELINE_BASE_RANGE * (1 + pct / 100)
        end
        return minRange
    end

    -- Live shots-per-second on the player's Core tower (Power). Used by
    -- the dev simulator to force-pick AmmoCapacity at the two SPS
    -- thresholds (5 and 15) where the tower would otherwise outshoot
    -- its magazine during the boss fight.
    local function getCoreSPS(player)
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local t = towerBase.Parent
            if t and t:GetAttribute("Owner") == player.UserId
                   and towerCategory(t) == "Core" then
                return t:GetAttribute("FireRate") or 0
            end
        end
        return 0
    end

    -- Synthesize a single player's pick. Dev greedy algorithm:
    --   1. Reroll loop: if the card set is uninspiring, burn a free reroll
    --      or a RerollToken to draw again. "Uninspiring" thresholds:
    --        * any pick (early/late): no Special AND nothing > Common → reroll
    --        * late picks (pickInStage >= 3): nothing > Rare → reroll
    --   2. Force AmmoCapacity once Core SPS crosses 5, then again at 15 —
    --      keeps the simulated tower from starving on shots at the boss.
    --      Flag stored as player attributes so repeat calls don't double-
    --      pick at the same threshold.
    --   3. Otherwise: greedy by rarity, skipping Range-on-Core when Core
    --      RangeBonusPct >= 60 and Range-on-Aux when Aux RangeBonusPct >= 60.
    local AMMO_THRESHOLDS = {
        { attr = "DevAmmoPickedAt5",  sps = 5  },
        { attr = "DevAmmoPickedAt15", sps = 15 },
    }

    local function simulateOnePick(player, pickIndex)
        pickIndex = pickIndex or 1
        local pickInStage = ((pickIndex - 1) % 4) + 1  -- 1..4 within a stage

        -- Reroll loop: up to 3 attempts to find a card worth picking.
        -- Stops as soon as a set has a Special, a non-Common card, or the
        -- player is out of rerolls/tokens.
        local payload
        local MAX_REROLL_TRIES = Config.UpgradeCards.MaxRerollTries
        for _ = 1, MAX_REROLL_TRIES do
            payload = generateCardsForPlayer(player, 0)
            local cards = payload.cards or {}
            if #cards == 0 then return end

            local hasSpecial, highScore = false, 0
            for _, c in ipairs(cards) do
                local s = DEV_PICK_SCORE[c.rarity] or 0
                if c.rarity == "Special" then hasSpecial = true end
                if s > highScore then highScore = s end
            end
            local anyOverCommon = highScore > (DEV_PICK_SCORE.Common or 1)
            local anyOverRare   = highScore > (DEV_PICK_SCORE.Rare    or 2)

            local wantReroll = (not hasSpecial and not anyOverCommon)
                            or (pickInStage >= 3 and not anyOverRare)

            if not wantReroll then break end

            local rerollsUsed = player:GetAttribute("RerollsUsed") or 0
            local tokens      = player:GetAttribute("RerollTokens") or 0
            if rerollsUsed < WaveConfig.maxRerollsPerStage then
                player:SetAttribute("RerollsUsed", rerollsUsed + 1)
            elseif tokens > 0 then
                player:SetAttribute("RerollTokens", tokens - 1)
            else
                break  -- nothing to spend; pick what we've got
            end
            -- Loop back and regenerate cards.
        end

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

        -- Ammo forcing: if Core SPS has crossed an un-claimed threshold
        -- and AmmoCapacity is in this pool, take it outright.
        local coreSps = getCoreSPS(player)
        local forceAmmoIdx
        for _, tier in ipairs(AMMO_THRESHOLDS) do
            if coreSps >= tier.sps and not player:GetAttribute(tier.attr) then
                for _, i in ipairs(order) do
                    local c = cards[i]
                    if c.kind == "special" and c.special == "AmmoCapacity" then
                        forceAmmoIdx = i
                        player:SetAttribute(tier.attr, true)
                        break
                    end
                end
                if forceAmmoIdx then break end
            end
        end
        if forceAmmoIdx then
            applyUpgrade(player, cards[forceAmmoIdx])
            return
        end

        -- Range targeting (per playtest 2026-04-26):
        --   GOAL: every owned tower has Range >= TARGET_MIN_RANGE
        --   stud by the time the player reaches Pickle Lord.
        --
        --   Below goal (any category) → PREFER range cards. The
        --   greedy-rarity loop below would otherwise pick higher-
        --   rarity Damage/FireRate cards first and never burn an
        --   offer's range card unless it happened to be the only
        --   non-Common in the set. We override the order: if any
        --   range card targets a below-goal category, pick THAT
        --   one (highest-rarity if multiple). Only if no such
        --   card exists do we fall through to standard rarity-
        --   greedy.
        --
        --   At/above goal on map 1+2 → SKIP range (don't waste a
        --   pick when other stats need building).
        --
        --   At/above goal on map 3+ → range is back in the normal
        --   greedy rotation (the run boss benefits from extra
        --   reach if rolls favor range).
        local TARGET_MIN_RANGE = Config.UpgradeCards.TargetMinRange
        local PICKS_PER_MAP    = 12     -- 4 picks/stage × 3 stages
        local mapNumber        = math.floor((pickIndex - 1) / PICKS_PER_MAP) + 1
        local isMap3OrLater    = mapNumber >= 3
        local coreMinRange = getMinRangeByCategory(player, "Core")
        local auxMinRange  = getMinRangeByCategory(player, "Aux")
        local coreBelow    = coreMinRange < TARGET_MIN_RANGE
        local auxBelow     = auxMinRange  < TARGET_MIN_RANGE

        local pickIdx = nil

        -- PASS 1 — range preference. Find the highest-rarity range
        -- card matching a below-goal category. `order` is already
        -- rarity-DESC-sorted, so first match wins.
        if coreBelow or auxBelow then
            for _, i in ipairs(order) do
                local c = cards[i]
                if c.kind == "stat" and c.stat == "Range" then
                    local target = c.target or "Core"
                    if (target == "Core" and coreBelow)
                       or (target == "Aux"  and auxBelow)
                       or (target == "All"  and (coreBelow or auxBelow)) then
                        pickIdx = i
                        break
                    end
                end
            end
        end

        -- PASS 2 — standard rarity-greedy, with skip filters.
        if not pickIdx then
            for _, i in ipairs(order) do
                local c = cards[i]
                local target = c.target or "Core"
                local isRange = (c.kind == "stat" and c.stat == "Range")
                local isAmmoCap = (c.kind == "special" and c.special == "AmmoCapacity")
                local skipRange = false
                if isRange then
                    local catMin = (target == "Core") and coreMinRange or auxMinRange
                    -- Goal met for this category: skip on map 1+2,
                    -- allow on map 3.
                    if catMin >= TARGET_MIN_RANGE and not isMap3OrLater then
                        skipRange = true
                    end
                end
                if skipRange then
                    -- Skip: range goal already met for this category
                    -- and we're still on map 1 or 2.
                elseif isAmmoCap and coreSps < 5 then
                    -- Skip: Core isn't firing fast enough yet to benefit from
                    -- an ammo-cap pick; threshold-forcing above handles the
                    -- >5/>15 SPS cases explicitly.
                else
                    pickIdx = i
                    break
                end
            end
        end

        -- Fallback: if every card was skipped, pick the first.
        if not pickIdx then pickIdx = order[1] end
        applyUpgrade(player, cards[pickIdx])

        -- DEV LUCK PEG: force the DISPLAYED run-luck bar to read
        -- 6 / 10 for any auto-rolled run, regardless of what
        -- rarities the sim actually picked.
        --
        -- The HUD (DevPanel.lua's avgRarityToDisplay) maps raw
        -- avg rarity score (1..5) onto a 1..10 display via a
        -- two-piece linear curve anchored at avg 2.71 → display 5
        -- (the "average greedy player" baseline). Above-anchor
        -- formula: display = 5 + (avg - 2.71) / (5 - 2.71) * 5.
        --
        -- 2026-04-29 dx: target bumped 5.5 → 6 per Matthew "give
        -- avg luck of 6 when auto advancing on dev map port."
        -- Solving display = 6:
        --   1 = (avg - 2.71) * 5 / 2.29
        --   avg = 2.71 + 0.458 = 3.168.
        -- We overwrite RunLuckSum so sum/count == that target avg.
        -- Real player picks (don't run through simulateOnePick)
        -- keep their natural luck score.
        local TARGET_AVG = 3.168
        local luckCount = player:GetAttribute("RunLuckCount") or 0
        if luckCount > 0 then
            player:SetAttribute("RunLuckSum", luckCount * TARGET_AVG)
        end
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
                -- First pick seeds magnitude + base chance; subsequent
                -- picks only bump chance (same rule as the card path).
                local cur = towerModel:GetAttribute(effect.attr)
                if not cur then
                    towerModel:SetAttribute(effect.attr, effect.base)
                    towerModel:SetAttribute(effect.chanceAttr, effect.chanceBase)
                else
                    local curC = towerModel:GetAttribute(effect.chanceAttr) or effect.chanceBase
                    towerModel:SetAttribute(effect.chanceAttr,
                        math.min(1, curC + effect.chanceIncrement))
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
