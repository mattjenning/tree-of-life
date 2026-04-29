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

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Remotes       = require(Shared:WaitForChild("Remotes"))
local CoreTypes     = require(Shared:WaitForChild("CoreTypes"))
local CoreUpgrades  = require(Shared:WaitForChild("CoreUpgrades"))

local CoreUpgradesSystem = {}

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

    rewardClaimedBindable.Event:Connect(function(payload)
        local mapId  = payload and payload.mapId
        local player = payload and payload.player
        if not player or not player.Parent then return end

        -- Phase B sanity log so we can verify the trigger wiring is
        -- correct in Studio before mechanics land. Drop to a print()
        -- when Phase C ships.
        print(("[CoreUpgrades] BossRewardClaimed mapId=%s player=%s — firing picker"):format(
            tostring(mapId), player.Name))

        local coreId  = getEquippedCore(player)
        local options = CoreUpgrades.optionsFor(coreId)
        if not options then
            warn(("[CoreUpgrades] no options for coreId=%s — picker NOT firing"):format(tostring(coreId)))
            return
        end

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

        -- Phase B: stamp `<UpgradeId>Stacks = stacks + 1` and log.
        -- Phase C will wire each id to actual gameplay effects.
        local attrName = upgradeId .. "Stacks"
        local existing = player:GetAttribute(attrName) or 0
        player:SetAttribute(attrName, existing + 1)
        print(("[CoreUpgrades] %s picked %s → %s = %d (Phase B: attribute-only, no gameplay effect yet)"):format(
            player.Name, upgradeId, attrName, existing + 1))

        pending[player.UserId] = nil
    end)

    -- Drain pending state on player remove so re-joining the same
    -- session doesn't show a stale picker.
    local Players = game:GetService("Players")
    Players.PlayerRemoving:Connect(function(player)
        pending[player.UserId] = nil
    end)
end

return CoreUpgradesSystem
