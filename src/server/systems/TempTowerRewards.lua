--[[
    TempTowerRewards.lua — Temp-tower 3-card picker shown after a map
    boss defeat. Also handles the "dud" replacement path where a rolled
    card the player already owns at equal-or-higher rarity becomes a
    +1 Reroll Token pick instead.

    FLOW:
      1. Wave system fires BossDefeated with { mapId = 1|2|3 }.
      2. For each player, roll 3 distinct (towerId, rarity) cards using
         the boss's rarity-weight pool (Map1 low-bias, Map2 mid, Map3 high).
      3. For each rolled card, check if the player already has a copy of
         that tower at >= the rolled rarity. If so, flag dud = true — the
         client will animate those cards into reroll-token cards.
      4. Store the roll per-player in `pending` keyed by UserId so the
         pick handler can resolve cardIndex → (tower grant | token grant).
      5. Fire ShowTempTowerReward to the player with the card payload.
      6. On TempTowerPicked:
           - If the picked card is a dud → +1 RerollTokens attribute.
           - Else → set <towerId>Rarity + <towerId>Stock attributes (the
             stock count comes from the template, NOT from the rarity;
             all rarities share the same stock per tower).
           - Clear pending state.

    WHY A SEPARATE MODULE:
    Keeps the reward logic in one place so adding Map 2/3 integration
    (step 8) and the Pickle-Lord permanent-tower path (step 10) is a
    delta here rather than spraying across the hub or wave system.

    SCOPE NOTES:
    - This module grants the STOCK + RARITY attributes. Making the new
      tower actually placeable (builder fn + hotbar slot) is separate
      work (steps 5+6 — tower implementations).
    - Duplicate policy is "replace if higher rarity, else dud (reroll
      token)" per TempTowers.shouldReplaceOnDuplicate.
    - The run boss (Pickle Lord) uses a different flow and is NOT
      handled here. It fires its own remote in a later step.

    setup(ctx) reads:
      ctx (no fields required today; the bindable is fetched from
      ReplicatedStorage directly)

    Publishes:
      ShowTempTowerReward (server → client)
      TempTowerPicked     (client → server)
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Remotes      = require(Shared:WaitForChild("Remotes"))
local Tags         = require(Shared:WaitForChild("Tags"))
local TempTowers   = require(Shared:WaitForChild("TempTowers"))
local MapRegistry  = require(Shared:WaitForChild("MapRegistry"))
local _ = Tags  -- referenced inside the cutscene branch; keep as an explicit dep

local TempTowerRewards = {}

-- Per-player pending picker state. Cleared on pick or on player leaving.
-- Shape: { [userId] = { mapId = 1|2|3, cards = { [i] = cardPayload } } }
local pending = {}

-- Map the wave-system mapId (1..3) to the boss-weight pool in TempTowers.
local MAP_BOSS_WEIGHTS = {
    [1] = TempTowers.BossWeights.Map1,
    [2] = TempTowers.BossWeights.Map2,
    [3] = TempTowers.BossWeights.Map3,
}

-- Attribute naming: `<TowerId>Rarity` and `<TowerId>Stock` live on the
-- Player instance. Matches the existing `PowerStock` naming pattern.
local function rarityAttr(towerId) return towerId .. "Rarity" end
local function stockAttr(towerId)  return towerId .. "Stock"  end

-- Resolve a single rolled (towerId, rarity) into a client-bound card.
-- Checks the player's current inventory to flag duds.
local function buildCardPayload(player, rolled)
    local tpl = TempTowers.Templates[rolled.towerId]
    if not tpl then return nil end

    local stats = TempTowers.resolveStats(rolled.towerId, rolled.rarity) or {}

    local currentRarity = player:GetAttribute(rarityAttr(rolled.towerId))
    local dud = false
    if currentRarity and not TempTowers.shouldReplaceOnDuplicate(currentRarity, rolled.rarity) then
        dud = true
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
        dud         = dud,
    }
end

function TempTowerRewards.setup(_ctx)
    local bossDefeatedBindable = ReplicatedStorage:WaitForChild(Remotes.Names.BossDefeated)
    local showHotbarRemote     = ReplicatedStorage:WaitForChild(Remotes.Names.ShowHotbar)
    local showRewardRemote     = Remotes.getOrCreate(Remotes.Names.ShowTempTowerReward, "RemoteEvent")
    local tempPickedRemote     = Remotes.getOrCreate(Remotes.Names.TempTowerPicked,     "RemoteEvent")
    -- Fired after a player claims their pick so Map2 (and future map worlds)
    -- can run map-transition cinematics that shouldn't play behind the picker.
    local rewardClaimedBindable = Remotes.getOrCreate(Remotes.Names.BossRewardClaimed, "BindableEvent")
    -- Pre-create so the client's WaitForChild at startup doesn't stall
    -- with "Infinite yield possible" warnings. Fired later in grantTowerPick
    -- for map-1 claims.
    local cutsceneRemote = Remotes.getOrCreate(Remotes.Names.PlayBossCutscene, "RemoteEvent")
    -- Client → server signal fired when the boss cutscene finishes (player
    -- arrived at tower + completed pause). The destroy task below polls
    -- `cutsceneDonePlayers[userId]` with a safety timeout, so a far-off
    -- path no longer races the old hardcoded 2s wait.
    local cutsceneDoneRemote   = Remotes.getOrCreate(Remotes.Names.BossCutsceneDone, "RemoteEvent")
    local cutsceneDonePlayers  = {}  -- {[userId] = true} while awaiting ack
    cutsceneDoneRemote.OnServerEvent:Connect(function(player)
        cutsceneDonePlayers[player.UserId] = true
    end)

    -- Grant path for picking a tower card. Refreshes hotbar at the end so
    -- the new slot renders (client's towerDefs list must include this
    -- towerId — wired when each tower's builder ships in steps 5/6).
    local function grantTowerPick(player, card)
        local tpl = TempTowers.Templates[card.towerId]
        if not tpl then return end

        -- Belt-and-suspenders against the dud check missing (shouldn't
        -- happen since duds are flagged when the card is built).
        local existing = player:GetAttribute(rarityAttr(card.towerId))
        if existing and not TempTowers.shouldReplaceOnDuplicate(existing, card.rarity) then
            print(("[TempTowerRewards] %s picked a %s %s but already has %s — keeping existing"):format(
                player.Name, card.rarity, card.displayName, existing))
            return
        end

        -- Set the rarity snapshot + refill stock to the template's full count.
        -- Stock is intentionally the SAME across all rarities (rarity nudges
        -- damage/secondary, not how many copies you can place).
        player:SetAttribute(rarityAttr(card.towerId), card.rarity)
        player:SetAttribute(stockAttr(card.towerId), tpl.stock)
        print(("[TempTowerRewards] %s picked %s [%s], stock=%d, footprint=%dx%d"):format(
            player.Name, tpl.displayName, card.rarity, tpl.stock,
            tpl.footprintWidth, tpl.footprintDepth))

        -- Refresh the hotbar so the new slot shows / updates. Safe to call
        -- even if the client's towerDefs doesn't yet list this tower — the
        -- client just re-renders whatever it knows about.
        showHotbarRemote:FireClient(player)
    end

    -- Grant path for picking a dud (converted reroll-token card).
    local function grantTokenPick(player, card)
        local cur = player:GetAttribute("RerollTokens") or 0
        player:SetAttribute("RerollTokens", cur + 1)
        print(("[TempTowerRewards] %s picked dud (%s %s), +1 Reroll Token → %d"):format(
            player.Name, card.rarity, card.displayName, cur + 1))
    end

    local MAP_TITLES = {
        [1] = "Map 1 Boss Defeated — Choose Your Reward",
        [2] = "Map 2 Boss Defeated — Choose Your Reward",
        [3] = "Map 3 Boss Defeated — Choose Your Reward",
    }

    -- Post-pick narrative foreshadowing for maps that don't yet have a
    -- world-module transition cinematic (Map2.lua handles map 1 → 2
    -- ladder; future Map3.lua will handle map 2 → 3; run boss flow
    -- will handle map 3 → Pickle Lord). Until those are built, a short
    -- leaf message gives the player closure so a boss defeat isn't
    -- followed by dead silence.
    local MAP_CLOSURE_LEAFS = {
        [2] = "A breeze stirs above... the canopy waits.",
        -- Map 3's "something ancient approaches..." line moved into
        -- PickleLordBoss.startPickleLord so it lands the moment the
        -- cinematic kicks off (was firing 2s earlier when the player
        -- picked their reward, before the cinematic began).
    }

    local leafMessageRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)

    local function showPickerForPlayer(player, mapId)
        local weights = MAP_BOSS_WEIGHTS[mapId] or TempTowers.BossWeights.Map1
        -- Build the exclude set from the player's already-owned aux
        -- types so rollThreeCards prefers NEW types. Without this,
        -- a player who already owned (say) Root Sprout could be
        -- offered Root Sprout again as a card → picking it just
        -- upgrades the rarity instead of granting a new tower
        -- type, leaving them short an aux entering Pickle Lord.
        -- (2026-04-26 playtest: dev-port to map 3 + bird-boss
        -- reward of an already-owned type ended in 2 aux instead
        -- of 3.)
        local ownedIds = {}
        for towerId, _ in pairs(TempTowers.Templates) do
            if player:GetAttribute(rarityAttr(towerId)) then
                ownedIds[towerId] = true
            end
        end
        local rolls = TempTowers.rollThreeCards(weights, ownedIds)
        if #rolls == 0 then return end

        local cards = {}
        for _, rolled in ipairs(rolls) do
            local card = buildCardPayload(player, rolled)
            if card then table.insert(cards, card) end
        end
        if #cards == 0 then return end

        pending[player.UserId] = { mapId = mapId, cards = cards }

        showRewardRemote:FireClient(player, {
            mapId = mapId,
            title = MAP_TITLES[mapId] or MAP_TITLES[1],
            cards = cards,
        })
    end

    bossDefeatedBindable.Event:Connect(function(payload)
        -- Payload shape: { mapId = 1|2|3 }. Legacy fires (no payload) default to map 1.
        local mapId = (payload and payload.mapId) or 1
        for _, player in ipairs(Players:GetPlayers()) do
            -- Small stagger for multi-player: each picker opens per-player
            -- (server-side state is per-UserId), so fire for all players.
            showPickerForPlayer(player, mapId)
        end
    end)

    tempPickedRemote.OnServerEvent:Connect(function(player, payload)
        local state = pending[player.UserId]
        if not state then
            print(("[TempTowerRewards] %s picked but no pending state — ignoring"):format(player.Name))
            return
        end

        local cardIndex = payload and payload.cardIndex
        if type(cardIndex) ~= "number"
           or cardIndex < 1
           or cardIndex > #state.cards then
            print(("[TempTowerRewards] %s sent invalid cardIndex %s"):format(
                player.Name, tostring(cardIndex)))
            pending[player.UserId] = nil
            return
        end

        local card = state.cards[cardIndex]
        pending[player.UserId] = nil

        if card.dud then
            grantTokenPick(player, card)
        else
            grantTowerPick(player, card)
        end

        -- Signal post-pick so map-transition beats (ladder drop, portal
        -- descent, narrative leaf message) can run now that the picker
        -- is closed on the client. For map 1 AND map 2 we play the
        -- "walk-to-Core, pick it up" cutscene first; the BossRewardClaimed
        -- fire is delayed until the cutscene + cleanup complete so the
        -- world's cinematic (ladder drop on map 1, portal descent on map 2)
        -- lines up with the tower visually vanishing.
        local mapEntry = MapRegistry.get(state.mapId)
        local playsCutscene = mapEntry and mapEntry.playsRewardCutscene or false
        if playsCutscene then
            -- Find the player's Core tower NOW so we can pass its world
            -- position to the client cutscene + destroy it (and on map 2,
            -- destroy every other tower they own) when the cutscene ends.
            local coreTower
            for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local t = base.Parent
                if t and t:GetAttribute("Owner") == player.UserId
                       and t:GetAttribute("TowerType") == "Power" then
                    coreTower = t
                    break
                end
            end
            local corePos
            if coreTower then
                local baseSlab = coreTower:FindFirstChild("TowerBase")
                if baseSlab and baseSlab:IsA("BasePart") then
                    corePos = baseSlab.Position
                end
            end

            cutsceneRemote:FireClient(player, {
                corePosition = corePos,
                duration     = 2,
            })

            -- Per-player flag the BossCutsceneDone handler flips when the
            -- client's cutscene (variable-length run + 0.5s pause) wraps.
            -- Keyed by UserId so concurrent runs don't cross wires.
            cutsceneDonePlayers[player.UserId] = false

            task.spawn(function()
                -- Wait for the client to finish its cutscene. MoveToFinished
                -- can take anywhere from ~1s (close tower) to 8s (far path +
                -- internal Roblox cap), then the 0.5s pause on top. We poll
                -- the flag with a 10s safety ceiling so a disconnected or
                -- frozen client can't leave the tower / reward in limbo.
                local deadline = os.clock() + 10
                while os.clock() < deadline do
                    if cutsceneDonePlayers[player.UserId] then break end
                    task.wait(0.1)
                end
                cutsceneDonePlayers[player.UserId] = nil
                -- Carry Phoenix cooldown state onto the player so the
                -- next-placed Core tower picks up where this one left
                -- off. The map-N+1 Core is narratively the SAME tower,
                -- so the Phoenix shouldn't reset just because the instance
                -- gets rebuilt on a new map.
                if coreTower and coreTower.Parent
                       and coreTower:GetAttribute("EquippedType") == "Phoenix" then
                    player:SetAttribute("PhoenixCarryCdRemaining",
                        coreTower:GetAttribute("PhoenixCdRemaining") or 0)
                    player:SetAttribute("PhoenixCarryGraceRemaining",
                        coreTower:GetAttribute("PhoenixGraceRemaining") or 0)
                    player:SetAttribute("PhoenixCarryReady",
                        coreTower:GetAttribute("PhoenixReady") == true)
                end
                -- Destroy towers + restore stock.
                --   Map 1: only the Core (no aux towers exist yet).
                --   Map 2: ALL of the player's towers (Core + every aux they
                --          earned from the map 1 boss). Stock for those auxes
                --          is restored to the template default so map 3
                --          starts with a clean board + full inventory.
                if state.mapId == 1 then
                    if coreTower and coreTower.Parent then
                        coreTower:Destroy()
                    end
                else  -- map 2
                    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                        local t = base.Parent
                        if t and t.Parent and t:GetAttribute("Owner") == player.UserId then
                            t:Destroy()
                        end
                    end
                    -- Restore Core stock to 1 + every owned aux back to its
                    -- template stock. SwitchMap (Map2→Map3) does max(stock,
                    -- existing); setting before the switch fires ensures
                    -- the player walks onto map 3 with full inventory.
                    player:SetAttribute("PowerStock", 1)
                    for towerId, tpl in pairs(TempTowers.Templates) do
                        if player:GetAttribute(towerId .. "Rarity") then
                            player:SetAttribute(towerId .. "Stock", tpl.stock)
                        end
                    end
                    print(("[TempTowerRewards] %s map-2 victory: cleared all towers, stock restored"):format(player.Name))
                end
                rewardClaimedBindable:Fire({ mapId = state.mapId, player = player })
            end)
        else
            rewardClaimedBindable:Fire({ mapId = state.mapId, player = player })
        end

        -- Placeholder closure for maps whose world-module transitions
        -- aren't built yet. Map 1 → 2 ladder is handled by Map2.lua; for
        -- map 2 / map 3 boss defeats we just fire a foreshadowing leaf so
        -- the player gets some feedback between this boss and whatever
        -- future content follows.
        local closure = MAP_CLOSURE_LEAFS[state.mapId]
        if closure then
            if not leafMessageRemote then
                leafMessageRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.LeafMessage)
            end
            if leafMessageRemote then
                task.delay(0.8, function()
                    leafMessageRemote:FireClient(player, {
                        text = closure,
                        duration = 8,
                    })
                end)
            end
        end
    end)

    -- Cleanup on leave so stale pending state can't grant to a ghost UserId
    -- if a new player happens to get the same id (rare but guarded).
    Players.PlayerRemoving:Connect(function(player)
        pending[player.UserId] = nil
    end)
end

return TempTowerRewards
