--[[
    PermanentTowers.lua — Equip-flow system for permanent towers.

    FLOW:
      1. Pedestal geometry (built in Map2.lua) rises after a map boss is
         defeated. Its ProximityPrompt's Triggered event fires OpenPermanentEquip
         on the server.
      2. This module receives OpenPermanentEquip → reads the player's
         collection from PermanentTowerStore → fires ShowPermanentEquip with
         the serializable collection payload.
      3. Client renders an equip modal. Player picks one entry (or cancels).
      4. Client fires PermanentTowerEquipped with {towerId}.
      5. This module: sets EquippedPermanentType/Rarity attributes on the
         player, persists to DataStore, and (if mid-run) grants 1× stock of
         the equipped tower immediately so the player can place it.

    RUN-START GRANT:
    Setup also listens for the existing TowerPicked remote (the starter-tower
    picker). When a player picks Core at run start, we ALSO grant the
    equipped permanent tower 1× stock so they enter the TD room with both.

    SwitchMap already grants +1 PowerStock on map 2+ entry. It ALSO needs to
    grant +1 stock for the equipped permanent tower — handled inline in the
    wave system's SwitchMap handler alongside the Power grant.

    COLLECTION STATE (per player, from DataStore):
      { equipped = "FrostMelon" | nil,
        owned = { [type] = { type, rarity }, ... } }

    setup(ctx) reads:
      ctx (no required fields; remotes looked up via Remotes module)

    Publishes:
      ctx.grantPermanentStock(player) — called by wave system on map transition
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))

local Store = require(ServerScriptService:WaitForChild("PermanentTowerStore"))

local PermanentTowers = {}

-- Build a client-safe snapshot of a player's collection. DataStore entries
-- are already plain tables, but we add display metadata (displayName,
-- color, footprint) so the client doesn't need to know about TempTowers.
local function buildCollectionPayload(player)
    local data = Store.load(player)
    local equippedType = data.equipped

    local entries = {}
    for towerId, entry in pairs(data.owned or {}) do
        local tpl = TempTowers.Templates[towerId]
        if tpl then
            table.insert(entries, {
                towerId     = towerId,
                displayName = tpl.displayName,
                description = tpl.description,
                rarity      = entry.rarity,
                color       = TempTowers.RarityColors[entry.rarity]
                            or TempTowers.RarityColors.Common,
                footprint   = { w = tpl.footprintWidth, h = tpl.footprintDepth },
                stock       = tpl.stock,
                isEquipped  = (towerId == equippedType),
            })
        end
    end
    -- Deterministic sort so the UI doesn't jump around between opens.
    table.sort(entries, function(a, b) return a.towerId < b.towerId end)
    return {
        equipped = equippedType,
        entries  = entries,
    }
end

-- Grant 1× stock of the player's equipped permanent tower. Called at run
-- start (after starter tower pick) and on each SwitchMap so the Aux permanent
-- keeps pace with Core's +1/map grant.
local function grantPermanentStock(player)
    local equipped = Store.getEquipped(player)
    if not equipped then return end
    local towerId = equipped.type
    local tpl = TempTowers.Templates[towerId]
    if not tpl then return end

    -- Mirror the map-boss-picker grant path: set Rarity + ensure Stock is
    -- at least the template's full count (never accumulate above — at-most
    -- semantics mirror Core's "max 1 per map entry" rule).
    player:SetAttribute(towerId .. "Rarity", equipped.rarity)
    local cur = player:GetAttribute(towerId .. "Stock") or 0
    player:SetAttribute(towerId .. "Stock", math.max(tpl.stock, cur))
    print(("[PermanentTowers] %s granted 1× %s [%s] from equipped permanent"):format(
        player.Name, tpl.displayName, equipped.rarity))
end

function PermanentTowers.setup(ctx)
    local showEquipRemote        = Remotes.getOrCreate(Remotes.Names.ShowPermanentEquip,       "RemoteEvent")
    local equippedRemote         = Remotes.getOrCreate(Remotes.Names.PermanentTowerEquipped,   "RemoteEvent")
    local showRewardRemote       = Remotes.getOrCreate(Remotes.Names.ShowPermanentTowerReward, "RemoteEvent")
    local rewardPickedRemote     = Remotes.getOrCreate(Remotes.Names.PermanentTowerPicked,     "RemoteEvent")
    local pickleLordBindable     = Remotes.getOrCreate(Remotes.Names.PickleLordDefeated,       "BindableEvent")
    local showHotbarRemote       = ReplicatedStorage:WaitForChild(Remotes.Names.ShowHotbar)

    -- Per-player pending permanent-reward picker state. Unlike the temp
    -- reward pending table, we allow only ONE open permanent picker per
    -- player at a time (defeating the run boss is a singular moment).
    local pendingRewards = {}

    -- Opener: called directly (server-side) by Map2.lua's pedestal
    -- ProximityPrompt.Triggered. Not a remote; the trigger already runs on
    -- the server, so a remote round-trip would be wasteful.
    local function openPermanentEquip(player)
        showEquipRemote:FireClient(player, buildCollectionPayload(player))
    end
    ctx.openPermanentEquip = openPermanentEquip

    -- Player picked a collection entry to equip.
    equippedRemote.OnServerEvent:Connect(function(player, payload)
        local towerId = payload and payload.towerId
        if type(towerId) ~= "string" then return end
        local data = Store.load(player)
        if not data.owned[towerId] then
            print(("[PermanentTowers] %s tried to equip unowned %s"):format(
                player.Name, towerId))
            return
        end
        Store.setEquipped(player, towerId)

        -- Mid-run equip: grant 1× stock immediately so the switch feels live.
        -- If the player hasn't opened the TD room yet (equipping from the
        -- hub pedestal pre-map-1), the stock is still valid when they enter.
        grantPermanentStock(player)
        showHotbarRemote:FireClient(player)

        -- Push a refreshed payload back so the modal can update "equipped"
        -- state if the player keeps it open.
        showEquipRemote:FireClient(player, buildCollectionPayload(player))
    end)

    -- ============================================================
    -- PICKLE LORD REWARD FLOW
    -- Defeating the run boss → roll 3 cards using the PickleLord boss
    -- weights (standard upgrade distro: 50/25/10/5/2). Each card is a
    -- (towerId, rarity) pair. Cards that duplicate the player's existing
    -- permanent at equal-or-higher rarity arrive flagged dud so the UI
    -- can render them as "already owned." On pick, tryAward routes to
    -- DataStore (Store.tryAward handles the new / upgraded / duplicate
    -- discrimination).
    -- ============================================================
    local function buildRewardCard(player, rolled)
        local tpl = TempTowers.Templates[rolled.towerId]
        if not tpl then return nil end
        local stats = TempTowers.resolveStats(rolled.towerId, rolled.rarity) or {}

        -- Check existing permanent collection for duplicates.
        local owned = Store.getOwned(player)
        local existing = owned and owned[rolled.towerId]
        local isDuplicate = false
        local dupRarity = nil
        if existing then
            local RarityRank = TempTowers.RarityRank
            local existingRank = RarityRank[existing.rarity] or 0
            local newRank      = RarityRank[rolled.rarity]  or 0
            if newRank <= existingRank then
                isDuplicate = true
                dupRarity = existing.rarity
            end
        end

        return {
            towerId     = rolled.towerId,
            displayName = tpl.displayName,
            description = tpl.description,
            rarity      = rolled.rarity,
            color       = TempTowers.RarityColors[rolled.rarity],
            footprint   = { w = tpl.footprintWidth, h = tpl.footprintDepth },
            stock       = tpl.stock,
            stats       = stats,
            isDuplicate = isDuplicate,
            ownedRarity = dupRarity,
        }
    end

    local function showRewardForPlayer(player)
        local weights = TempTowers.BossWeights.PickleLord
        local rolls = TempTowers.rollThreeCards(weights)
        if #rolls == 0 then return end

        local cards = {}
        for _, rolled in ipairs(rolls) do
            local card = buildRewardCard(player, rolled)
            if card then table.insert(cards, card) end
        end
        if #cards == 0 then return end

        pendingRewards[player.UserId] = { cards = cards }
        showRewardRemote:FireClient(player, {
            title = "THE PICKLE LORD FALLS",
            subtitle = "Claim a permanent tower — it carries to every future run.",
            cards = cards,
        })
    end

    -- Bindable listener: fired by the wave system when Pickle Lord mob dies,
    -- or by the dev panel (DevKillPickleLord) for playtest.
    pickleLordBindable.Event:Connect(function()
        for _, player in ipairs(Players:GetPlayers()) do
            showRewardForPlayer(player)
        end
    end)

    -- Dev shortcut: fires the reward flow directly without needing a mob
    -- fight. Proxies through the bindable so the production path (mob kill
    -- → bindable → reward modal) is exactly what dev testing exercises.
    local devKillRemote = Remotes.getOrCreate(Remotes.Names.DevKillPickleLord, "RemoteEvent")
    devKillRemote.OnServerEvent:Connect(function(player)
        print(("[PermanentTowers] DEV: %s triggered Pickle Lord reward directly"):format(player.Name))
        pickleLordBindable:Fire()
    end)

    -- The Pickle Lord card pick is the LAST player action of the run —
    -- once we hand back the confirmation modal we fire GameOver(win),
    -- which renders the VICTORY banner and routes the player back to
    -- the hub. The 2.5s delay gives the confirmation modal time to
    -- read before the banner takes the screen.
    local gameOverRemote = ReplicatedStorage:WaitForChild(Remotes.Names.GameOver)

    rewardPickedRemote.OnServerEvent:Connect(function(player, payload)
        local state = pendingRewards[player.UserId]
        if not state then
            print(("[PermanentTowers] %s picked reward but no pending state"):format(player.Name))
            return
        end
        local cardIndex = payload and payload.cardIndex
        if type(cardIndex) ~= "number" or cardIndex < 1 or cardIndex > #state.cards then
            print(("[PermanentTowers] %s sent invalid reward cardIndex %s"):format(
                player.Name, tostring(cardIndex)))
            pendingRewards[player.UserId] = nil
            return
        end

        local card = state.cards[cardIndex]
        pendingRewards[player.UserId] = nil

        local result = Store.tryAward(player, card.towerId, card.rarity)
        print(("[PermanentTowers] %s picked %s [%s] permanent → %s"):format(
            player.Name, card.displayName, card.rarity, result.result))

        -- Notify client of outcome so the modal can show a brief
        -- confirmation instead of just vanishing.
        showRewardRemote:FireClient(player, {
            title = "ADDED TO YOUR COLLECTION",
            subtitle = result.result == "new" and "New permanent tower unlocked!"
                    or result.result == "upgraded" and ("Upgraded from " .. tostring(result.oldRarity))
                    or "Already owned at same or higher rarity.",
            cards = {},  -- empty = closeable confirmation panel
            confirmation = true,
        })

        -- Run end. The Pickle Lord pick is the climactic moment; after a
        -- short beat to let the confirmation register, fire VICTORY and
        -- route the player back to the hub. The runVictory flag tells
        -- the GameOverBanner to render the hub button instead of the
        -- map-1 retry button.
        task.delay(2.5, function()
            if not player.Parent then return end
            gameOverRemote:FireClient(player, {
                result             = "win",
                defeatedFinalBoss  = true,
                runVictory         = true,
                totalWavesDefeated = player:GetAttribute("RunWavesCompleted") or 0,
            })
        end)
    end)

    -- Load each player's collection on join so attribute lookups downstream
    -- hit the cached copy rather than blocking on DataStore GetAsync.
    Players.PlayerAdded:Connect(function(player)
        Store.load(player)
    end)
    for _, p in ipairs(Players:GetPlayers()) do
        Store.load(p)
    end

    Players.PlayerRemoving:Connect(function(player)
        pendingRewards[player.UserId] = nil
    end)

    ctx.grantPermanentStock = grantPermanentStock
end

return PermanentTowers
