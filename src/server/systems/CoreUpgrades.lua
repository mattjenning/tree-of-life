--[[
    CoreUpgrades.lua — Server system that fires the per-Core upgrade
    picker after each map boss defeat. The player picks ONE of three
    Core-scoped upgrades; the pick is recorded as a `<UpgradeId>Stacks`
    player attribute so future picks compound.

    PHASE B (THIS FILE) — UI shell only. Recording the pick stamps an
    attribute but does NOT change gameplay yet. Phase C wires each of
    the 9 upgrades to actual stat / mechanic effects.

    FLOW:
      1. Map boss dies → BossDefeated fires.
      2. TempTowerRewards.lua handles the picker first (their existing
         flow). On TempTowerPicked, that system handles cutscene +
         cleanup, then fires `BossRewardClaimed` with { mapId, player }.
      3. THIS system listens to BossRewardClaimed → reads the player's
         equipped Core → fires ShowCoreUpgradePicker with that Core's
         3 options.
      4. Player picks a card → CoreUpgradePicked fires server →
         server validates upgradeId belongs to player's Core → stamps
         `<UpgradeId>Stacks = (existing or 0) + 1`.

    WHY POST-BossRewardClaimed: per Matthew "alongside" — temp tower
    picker first, then Core upgrade picker. BossRewardClaimed is the
    canonical signal that the temp-tower flow + cutscene have wrapped,
    so the Core picker doesn't overlap with the cutscene visually.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Remotes       = require(Shared:WaitForChild("Remotes"))
local Tags          = require(Shared:WaitForChild("Tags"))
local CoreTypes     = require(Shared:WaitForChild("CoreTypes"))
local CoreUpgrades  = require(Shared:WaitForChild("CoreUpgrades"))
local AutoPicker    = require(script.Parent:WaitForChild("AutoPicker"))

-- WaveCtxBridge: cross-script late-resolved access to the wave
-- system's heart accessor. CoreUpgrades is set up in Hub before
-- WaveSystem completes its setup, so we resolve via the bridge
-- at tick time (handles Hub-vs-WaveSystem ordering + hot-reload
-- gracefully). Used by the SupportHeartRegen Heartbeat tick.
local WaveCtxBridge = require(ServerScriptService:WaitForChild("WaveCtxBridge"))

local CoreUpgradesSystem = {}

-- Helper: every Tower-tagged model owned by `player`. Used by upgrade
-- effects that need to retroactively bump a stat on existing placed
-- towers (e.g. PowerBaseDamage adds 1 to Damage on every owned tower).
local function getOwnedTowers(player: Player): { Instance }
    local out = {}
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local tower = base.Parent
        if tower and tower.Parent
                and tower:GetAttribute("Owner") == player.UserId then
            table.insert(out, tower)
        end
    end
    return out
end

-- applyUpgradeEffect — switch on upgradeId, do the gameplay change
-- the upgrade describes. Phase C-1 wires 3 single-axis upgrades:
-- PowerBaseDamage, ControlDotTickDamage, SupportEnemyVuln. The other
-- 6 upgrades fall through to the no-op path (still attribute-only).
-- Phase C-2 + C-3 will wire the rest.
--
-- TowerPlacement also reads the *Stacks attributes at placement time
-- so freshly-placed towers (placed AFTER the pick) inherit the bonus.
-- This function is the RETROACTIVE path — it bumps stats on towers
-- that were already placed when the pick lands.
local function applyUpgradeEffect(player: Player, upgradeId: string)
    if upgradeId == "PowerBaseDamage" then
        -- +1 base damage on every owned tower. New placements after
        -- this point pick up the bonus via TowerPlacement's PowerBaseDamageStacks
        -- read at placement time.
        for _, tower in ipairs(getOwnedTowers(player)) do
            local cur = tower:GetAttribute("Damage") or 0
            tower:SetAttribute("Damage", cur + 1)
        end

    elseif upgradeId == "ControlDotTickDamage" then
        -- +1 stacking-DOT tick damage. Only ControlCore (and any
        -- future DOT-stack tower) has StackDotTickDmg > 0 — non-DOT
        -- towers stay untouched (bumping a 0-tick tower would silently
        -- start its DOT proc with no firing logic to back it up).
        for _, tower in ipairs(getOwnedTowers(player)) do
            local cur = tower:GetAttribute("StackDotTickDmg") or 0
            if cur > 0 then
                tower:SetAttribute("StackDotTickDmg", cur + 1)
            end
        end

    elseif upgradeId == "SupportEnemyVuln" then
        -- Pure attribute-driven; Damage.lua reads SupportEnemyVulnStacks
        -- on the source tower's owner at hit time. No retroactive
        -- walk needed — every subsequent damageMob() call applies
        -- the multiplier.

    elseif upgradeId == "PowerStunKbBonus" then
        -- ea3-29 Phase C-2. Pure attribute-driven; Damage.lua
        -- powerStunKbBonusMult reads the source tower's owner's
        -- stacks at hit time, multiplies damage by (1 + 0.25 ×
        -- stacks) when target is currently stunned (data.stunUntil
        -- > gameNow) or recently knocked back (data.kbActiveUntil
        -- > gameNow; stamped by Effects.lua's KB block).

    elseif upgradeId == "PowerCoreCrit" then
        -- ea3-29 Phase C-2. Pure attribute-driven; Damage.lua
        -- powerCoreCritRoll fires on Core-tower shots only. 10%
        -- per stack chance to deal 2× damage. Capped at 100%.

    elseif upgradeId == "ControlAddSlow" then
        -- ea3-29 Phase C-2. Pure attribute-driven; Towers.lua
        -- applyTempTowerDebuffs reads the source tower's owner's
        -- stacks per hit and refreshes data.controlBonusSlowMult
        -- = (1 - 0.05 × stacks) for 2s. MobUpdate.lua multiplies
        -- the speed mult by this on each tick. Stacks multipli-
        -- catively on top of the strongest per-source slow.

    elseif upgradeId == "SupportAuraBoost" then
        -- ea3-29 Phase C-2. Pure attribute-driven; Towers.lua
        -- aura prepass reads the support tower owner's stacks and
        -- adds (5 × stacks) percentage points to BOTH the dmgPct
        -- and frPct of the aura source. (Aura cache invalidates
        -- naturally on map transition since towers are torn down +
        -- rebuilt; for the same-map case the picker doesn't fire,
        -- so cache freshness isn't an issue.)

    elseif upgradeId == "ControlDotSpread" then
        -- ea3-30 Phase C-3. Pure attribute-driven; Damage.lua's
        -- mob-death block reads the source tower's owner's stacks
        -- and, when > 0, copies the dying mob's controlStacks onto
        -- every other mob within 12 studs. Skipped on chain damage
        -- to avoid double-spread cascades.

    elseif upgradeId == "SupportHeartRegen" then
        -- ea3-30 Phase C-3. Pure attribute-driven; the Heartbeat
        -- task installed in setup() polls all players' stacks every
        -- 0.2 game-seconds and heals the active heart by 0.5% ×
        -- totalStacks of MaxHealth per game-second. Stacks SUM
        -- across players (co-op friendly).
    end
end

-- Per-player pending state — set when we fire the picker, cleared
-- on pick or on player removing. Used to validate that the
-- CoreUpgradePicked client message corresponds to a real picker
-- prompt (drops out-of-order / replay messages).
local pending: { [number]: { coreId: string, mapId: number? } } = {}

-- Returns the player's currently-equipped Core archetype id, or
-- "Power" as a defensive fallback if no Equipped flag is set.
-- Mirrors the pattern used by TempTowerRewards / WaveSystem.
local function getEquippedCore(player: Player): string
    for _, id in ipairs(CoreTypes.Ids) do
        if player:GetAttribute(id .. "Equipped") == true then
            return id
        end
    end
    return "Power"
end

function CoreUpgradesSystem.setup(_ctx)
    local rewardClaimedBindable = Remotes.getOrCreate(Remotes.Names.BossRewardClaimed, "BindableEvent")
    local showPickerRemote      = Remotes.getOrCreate(Remotes.Names.ShowCoreUpgradePicker, "RemoteEvent")
    local pickedRemote          = Remotes.getOrCreate(Remotes.Names.CoreUpgradePicked, "RemoteEvent")
    -- ea3-46: cutscene-gate signal. TempTowerRewards listens to this
    -- to hold the boss cutscene until the Core upgrade pick lands.
    local resolvedBindable      = Remotes.getOrCreate(Remotes.Names.CoreUpgradeResolved, "BindableEvent")

    -- commitPick — shared "stamp the upgrade + apply effect" path.
    -- Used by both the client OnServerEvent handler (player-driven)
    -- AND the AutoPicker auto-resolve path (SUPER AUTO sweep).
    -- ea3-46: also fires CoreUpgradeResolved with {player, mapId} so
    -- TempTowerRewards' cutscene-gate listener wakes up. mapId
    -- threaded through via a closure-captured wrapper below — the
    -- AutoPicker path already has it from the BossRewardClaimed
    -- payload; the client-driven path reads it from the pending
    -- state. Both call commitPick with mapId so this logic stays
    -- in one place.
    local function commitPick(player: Player, upgradeId: string, mapId: any)
        local attrName = upgradeId .. "Stacks"
        local existing = player:GetAttribute(attrName) or 0
        player:SetAttribute(attrName, existing + 1)
        applyUpgradeEffect(player, upgradeId)
        print(("[CoreUpgrades] %s picked %s → %s = %d"):format(
            player.Name, upgradeId, attrName, existing + 1))
        resolvedBindable:Fire({ player = player, mapId = mapId })
    end

    rewardClaimedBindable.Event:Connect(function(payload)
        local mapId  = payload and payload.mapId
        local player = payload and payload.player
        if not player or not player.Parent then return end

        local coreId  = getEquippedCore(player)
        local options = CoreUpgrades.optionsFor(coreId)
        if not options or #options == 0 then
            warn(("[CoreUpgrades] no options for coreId=%s — picker NOT firing"):format(tostring(coreId)))
            -- ea3-46: still fire CoreUpgradeResolved so the cutscene-
            -- gate listener doesn't hang on maps without a Core
            -- upgrade picker (sentinel "no upgrade was needed" path).
            resolvedBindable:Fire({ player = player, mapId = mapId })
            return
        end

        -- 2026-04-29 ea3-33 Phase E-prep: AutoPicker bypass. SUPER
        -- AUTO sweep flips the flag at sweep start; pickers
        -- auto-resolve server-side without any modal trip. Skips
        -- the showPickerRemote fire entirely.
        if AutoPicker.isActive() then
            local idx = AutoPicker.pickIndex(#options, "coreUpgrade")
            local opt = options[idx]
            if opt and opt.id then
                print(("[CoreUpgrades] AUTO map=%s player=%s — picking %s (idx %d)"):format(
                    tostring(mapId), player.Name, opt.id, idx))
                commitPick(player, opt.id, mapId)
            else
                -- Defensive: no option resolved (shouldn't happen),
                -- but still wake the cutscene-gate so the run doesn't
                -- hang. ea3-46.
                resolvedBindable:Fire({ player = player, mapId = mapId })
            end
            return
        end

        print(("[CoreUpgrades] BossRewardClaimed mapId=%s player=%s — firing picker"):format(
            tostring(mapId), player.Name))

        pending[player.UserId] = { coreId = coreId, mapId = mapId }
        showPickerRemote:FireClient(player, {
            coreId  = coreId,
            options = options,  -- frozen array; client treats as read-only
            mapId   = mapId,
        })
    end)

    pickedRemote.OnServerEvent:Connect(function(player, msg)
        if not player or not player.Parent then return end
        local state = pending[player.UserId]
        if not state then
            warn(("[CoreUpgrades] %s sent CoreUpgradePicked with no pending state — dropping"):format(player.Name))
            return
        end

        local upgradeId = msg and msg.upgradeId
        if type(upgradeId) ~= "string" then
            warn(("[CoreUpgrades] %s sent invalid upgradeId %s"):format(player.Name, tostring(upgradeId)))
            pending[player.UserId] = nil
            return
        end
        if not CoreUpgrades.belongsToCore(upgradeId, state.coreId) then
            warn(("[CoreUpgrades] %s picked %s but their Core is %s — dropping"):format(
                player.Name, upgradeId, state.coreId))
            pending[player.UserId] = nil
            return
        end

        -- Stamp `<UpgradeId>Stacks = stacks + 1` and apply the
        -- upgrade's gameplay effect via commitPick (shared with
        -- the AutoPicker auto-resolve path). mapId comes from
        -- the pending state (set when BossRewardClaimed fired).
        commitPick(player, upgradeId, state.mapId)

        pending[player.UserId] = nil
    end)

    -- Drain pending state on player remove so re-joining the same
    -- session doesn't show a stale picker.
    Players.PlayerRemoving:Connect(function(player)
        pending[player.UserId] = nil
    end)

    -- 2026-04-29 ea3-30 (Phase C-3): SupportHeartRegen tick.
    -- Heals the active heart by 0.5% × totalStacks per game-second.
    -- Stacks SUM across players (co-op contribution: parent + daughter
    -- both picking Support adds their regen). Game-time-driven so a
    -- 20× speed sweep regens 20× faster — matches what the player
    -- sees on screen.
    --
    -- Sampled at 5 Hz (200ms) instead of every Heartbeat to keep the
    -- attribute-write rate sane. The dt-since-last-tick is used as
    -- the integration window so total heal-per-second is consistent
    -- regardless of tick rate.
    local lastRegenGameTime = 0
    local REGEN_TICK_INTERVAL_GAME_S = 0.2
    RunService.Heartbeat:Connect(function()
        local wctx = WaveCtxBridge.ctx
        if not wctx or not wctx.getHeart then return end
        local nowGame = wctx.gameTime or 0
        local dt = nowGame - lastRegenGameTime
        if dt < REGEN_TICK_INTERVAL_GAME_S then return end
        lastRegenGameTime = nowGame

        -- Sum stacks across all currently-connected players.
        local totalStacks = 0
        for _, p in ipairs(Players:GetPlayers()) do
            totalStacks = totalStacks + (p:GetAttribute("SupportHeartRegenStacks") or 0)
        end
        if totalStacks <= 0 then return end

        local heart = wctx.getHeart()
        if not heart or not heart.Parent then return end
        local maxHp = heart:GetAttribute("MaxHealth") or 0
        local curHp = heart:GetAttribute("Health")    or 0
        if maxHp <= 0 or curHp <= 0 or curHp >= maxHp then return end

        -- 0.5% of MaxHealth per stack per game-second.
        local healPerSec = maxHp * 0.005 * totalStacks
        local healAmount = healPerSec * dt
        local newHp = math.min(maxHp, curHp + healAmount)
        heart:SetAttribute("Health", newHp)
    end)
end

return CoreUpgradesSystem
