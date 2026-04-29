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
local CoreTypes    = require(Shared:WaitForChild("CoreTypes"))
-- Phase D (ea3-31): read the player's saved Story loadout to bias
-- the map-1 boss roll. Late-required so this file's load-order
-- doesn't matter relative to PermanentTowerStore's setup.
local PermanentTowerStore = require(script.Parent.Parent:WaitForChild("PermanentTowerStore"))
-- Phase E-prep (ea3-33): when SUPER AUTO is sweeping, AutoPicker.isActive()
-- returns true and the picker auto-resolves server-side instead of
-- showing the modal.
local AutoPicker = require(script.Parent:WaitForChild("AutoPicker"))
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
    -- 2026-04-28 du: 1-per-run reroll on the temp-tower picker per
    -- Matthew "give one aux tower reroll per run."
    local rerollRemote         = Remotes.getOrCreate(Remotes.Names.RerollAuxReward, "RemoteEvent")
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

    -- ea3-46: pendingCutsceneCtx[userId] = { mapId, coreTower, corePos }
    -- stashed by the boss-pick handler when a cutscene-eligible map's
    -- temp-tower picker resolves. The CoreUpgradeResolved listener
    -- (further down) pulls this context + plays the cutscene only
    -- after the Core upgrade pick lands. Per Matthew "don't start
    -- the pickle boss cutscene until all players select their core
    -- tower upgrade".
    local pendingCutsceneCtx   = {}  -- {[userId] = { mapId, coreTower, corePos }}

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

        -- Set the rarity snapshot. Stock is granted as 0 here; the
        -- next-map SwitchMap handler refills it to the template's
        -- full count. Per Matthew 2026-04-29 ea3-45: "give aux 0
        -- stock too, but refresh both when you arrive on map 2".
        -- Rationale: between boss-kill and walking through the
        -- portal there's nothing to defend on the cleared map, so
        -- placing the new aux there is wasted. Stock=0 keeps the
        -- slot visible (greyed) on the hotbar so the player sees
        -- what they got but can't place it until they arrive at
        -- the next map.
        player:SetAttribute(rarityAttr(card.towerId), card.rarity)
        player:SetAttribute(stockAttr(card.towerId), 0)
        print(("[TempTowerRewards] %s picked %s [%s] (stock=0 until next map), footprint=%dx%d"):format(
            player.Name, tpl.displayName, card.rarity,
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

        -- 2026-04-29 ea3-31 (Phase D-1): Story-loadout bias on map 1
        -- boss only. Per Matthew design dump 2026-04-29: "after map
        -- 1 boss is GUARANTEED to offer at least one of the player's
        -- loadout auxes (vs current random roll)."
        --
        -- Algorithm: if the player has a saved Story loadout AND
        -- one of their loadout auxes is NOT yet in the rolled cards
        -- AND not yet OWNED-this-run, swap one of the existing rolls
        -- for that aux. Picks the loadout candidate at random for
        -- variety across runs. Rarity uses the same boss-weight roll.
        --
        -- Map 2 / Map 3 boss pickers stay unbiased — players still
        -- earn random rolls there, and the loadout's role (per design)
        -- is just the early-run guarantee.
        if mapId == 1 then
            local loadout = PermanentTowerStore.getStoryLoadout(player)
            if #loadout > 0 then
                -- Build candidate set: loadout auxes that the
                -- player owns (by definition; setStoryLoadout
                -- enforces this), aren't owned-this-run, and
                -- aren't already in rolls.
                local rolledSet = {}
                for _, r in ipairs(rolls) do rolledSet[r.towerId] = true end
                local candidates = {}
                for _, id in ipairs(loadout) do
                    if not ownedIds[id] and not rolledSet[id]
                            and TempTowers.Templates[id] then
                        table.insert(candidates, id)
                    end
                end
                if #candidates > 0 then
                    local pickId = candidates[math.random(1, #candidates)]
                    -- Replace card #1 with the loadout pick. Reuses
                    -- the same rarity-weight roll the original card
                    -- had so the bias only changes IDENTITY, not
                    -- the rarity distribution.
                    rolls[1] = {
                        towerId = pickId,
                        rarity  = TempTowers.rollRarity(weights),
                    }
                    print(("[TempTowerRewards] %s loadout-biased map-1 card 1 → %s"):format(
                        player.Name, pickId))
                end
            end
        end

        local cards = {}
        for _, rolled in ipairs(rolls) do
            local card = buildCardPayload(player, rolled)
            if card then table.insert(cards, card) end
        end
        if #cards == 0 then return end

        -- 2026-04-29 ea3-33 Phase E-prep: AutoPicker bypass. SUPER
        -- AUTO sweep flips the flag at sweep start; this picker
        -- auto-resolves server-side with no modal trip + no cutscene.
        -- We grant the tower / token directly and fire the
        -- BossRewardClaimed bindable so downstream systems
        -- (CoreUpgrades next-stage trigger, world cinematics) run
        -- immediately. Cutscene wait is bypassed because the sweep
        -- runs at 20× speed and there's no human eye watching.
        if AutoPicker.isActive() then
            local idx = AutoPicker.pickIndex(#cards, "tempTower")
            local card = cards[idx]
            if card then
                if card.dud then
                    grantTokenPick(player, card)
                else
                    grantTowerPick(player, card)
                end
                print(("[TempTowerRewards] AUTO map=%s player=%s picked %s [%s] (idx %d)"):format(
                    tostring(mapId), player.Name, card.towerId, tostring(card.rarity), idx))
            end
            -- Fire the canonical "reward claimed" signal so map-transition
            -- consumers (Map2 ladder, CoreUpgrades picker) chain forward.
            rewardClaimedBindable:Fire({ mapId = mapId, player = player })
            return
        end

        pending[player.UserId] = { mapId = mapId, cards = cards }

        -- 2026-04-28 du: init the per-run reroll count to 1 if unset.
        -- Granted once per run on the FIRST picker (map 1 boss); the
        -- attribute persists across map transitions until used or run
        -- ends. RerollAuxReward handler decrements on use; PlayerAdded
        -- + RunReset re-init to 1 for fresh runs.
        if player:GetAttribute("AuxRerollsRemaining") == nil then
            player:SetAttribute("AuxRerollsRemaining", 1)
        end

        showRewardRemote:FireClient(player, {
            mapId = mapId,
            title = MAP_TITLES[mapId] or MAP_TITLES[1],
            cards = cards,
            auxRerollsRemaining = player:GetAttribute("AuxRerollsRemaining") or 0,
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

    -- 2026-04-28 du: aux-tower reroll handler. Decrements
    -- AuxRerollsRemaining and re-fires showPickerForPlayer with a
    -- fresh roll. Per Matthew "give one aux tower reroll per run."
    -- Init happens in showPickerForPlayer (default 1 on first
    -- picker show); if the player has 0 rerolls remaining, the
    -- request is ignored.
    rerollRemote.OnServerEvent:Connect(function(player)
        local state = pending[player.UserId]
        if not state then
            print(("[TempTowerRewards] %s tried to reroll but no pending state"):format(player.Name))
            return
        end
        local remaining = player:GetAttribute("AuxRerollsRemaining") or 0
        if remaining <= 0 then
            print(("[TempTowerRewards] %s tried to reroll with 0 remaining"):format(player.Name))
            return
        end
        player:SetAttribute("AuxRerollsRemaining", remaining - 1)
        print(("[TempTowerRewards] %s rerolled aux-tower picker (%d→%d remaining)")
            :format(player.Name, remaining, remaining - 1))
        -- Re-fire with a fresh roll. Pending state gets overwritten by
        -- the new showPickerForPlayer call.
        showPickerForPlayer(player, state.mapId)
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
        -- ea3-46 cutscene-gate: per Matthew "don't start the pickle
        -- boss cutscene until all players select their core tower
        -- upgrade." Order changed:
        --   1. Boss-reward picker resolves (this branch)
        --   2. Fire BossRewardClaimed → CoreUpgrades shows picker
        --   3. Player picks Core upgrade → CoreUpgradeResolved fires
        --   4. TempTowerRewards listener (defined below at setup
        --      scope) plays the cutscene + does the cleanup
        --
        -- For maps with no cutscene (currently maps without
        -- playsRewardCutscene set in MapRegistry — Pickle Lord
        -- pseudo-map etc.), we just fire BossRewardClaimed straight
        -- away; the listener is a no-op in that case (no pending
        -- cutscene context to pull).
        local mapEntry = MapRegistry.get(state.mapId)
        local playsCutscene = mapEntry and mapEntry.playsRewardCutscene or false
        if playsCutscene then
            -- Capture Core tower position now (before any state mutation).
            -- 2026-04-28 dq: extended Core detection to all three
            -- archetypes (was Power-only, broke ControlCore/SupportCore
            -- cutscenes — see prior comments).
            local coreTower
            for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local t = base.Parent
                if t and t:GetAttribute("Owner") == player.UserId
                       and CoreTypes.Set[t:GetAttribute("TowerType")] then
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
            -- Stash context for the CoreUpgradeResolved listener to consume.
            pendingCutsceneCtx[player.UserId] = {
                mapId     = state.mapId,
                coreTower = coreTower,
                corePos   = corePos,
            }
            print(("[TempTowerRewards] %s cutscene gated on Core upgrade pick (mapId=%d)"):format(
                player.Name, state.mapId))
        end
        rewardClaimedBindable:Fire({ mapId = state.mapId, player = player })

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

    -- ea3-46 cutscene-gate listener. Fires once the player picks a
    -- Core upgrade (CoreUpgrades.commitPick) — pulls the cutscene
    -- context stashed by the boss-pick handler + plays it. Without
    -- this, the cutscene never fires.
    --
    -- Single-player (and per-player MP): each player's cutscene
    -- plays after THEIR own Core upgrade pick. Future enhancement
    -- for "all players sync": track pendingCutsceneCtx as a set,
    -- only fire all when every entry has resolved.
    local resolvedBindable = Remotes.getOrCreate(Remotes.Names.CoreUpgradeResolved, "BindableEvent")
    resolvedBindable.Event:Connect(function(payload)
        local player = payload and payload.player
        if not player or not player.Parent then return end
        local ctx = pendingCutsceneCtx[player.UserId]
        if not ctx then
            -- No cutscene was queued for this player (map without
            -- playsRewardCutscene, or already played). Nothing to do.
            return
        end
        pendingCutsceneCtx[player.UserId] = nil

        local mapId     = ctx.mapId
        local coreTower = ctx.coreTower
        local corePos   = ctx.corePos

        cutsceneRemote:FireClient(player, {
            corePosition = corePos,
            duration     = 2,
        })
        -- Reset done-flag for the polling loop below.
        cutsceneDonePlayers[player.UserId] = false

        task.spawn(function()
            -- Poll for client cutscene-done ack (10s safety ceiling
            -- to handle disconnects / frozen clients).
            local deadline = os.clock() + 10
            while os.clock() < deadline do
                if cutsceneDonePlayers[player.UserId] then break end
                task.wait(0.1)
            end
            cutsceneDonePlayers[player.UserId] = nil

            -- Carry Phoenix cooldown state onto the player so the
            -- next-placed Core tower picks up where this one left off.
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
            --   Map 1: only the Core (no aux towers exist yet at
            --          this point — they're earned from THIS boss).
            --   Map 2: ALL of the player's towers (Core + every aux
            --          they earned from the map 1 boss). Stock for
            --          those auxes is restored to template default
            --          so map 3 starts with a clean board.
            if mapId == 1 then
                if coreTower and coreTower.Parent then
                    coreTower:Destroy()
                end
                -- ea3-45 defensive hotbar visibility.
                local pickedCore = "Power"
                for _, c in ipairs(CoreTypes.Ids) do
                    if player:GetAttribute(c .. "Equipped") == true then
                        pickedCore = c
                        break
                    end
                end
                player:SetAttribute(pickedCore .. "Equipped", true)
                player:SetAttribute(pickedCore .. "Stock", 0)
                showHotbarRemote:FireClient(player)
            else  -- map 2 (or 3 if cutscene flag is set there)
                for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                    local t = base.Parent
                    if t and t.Parent and t:GetAttribute("Owner") == player.UserId then
                        t:Destroy()
                    end
                end
                local pickedCore = "Power"
                for _, c in ipairs(CoreTypes.Ids) do
                    if player:GetAttribute(c .. "Equipped") == true then
                        pickedCore = c
                        break
                    end
                end
                player:SetAttribute(pickedCore .. "Stock", 1)
                for towerId, tpl in pairs(TempTowers.Templates) do
                    if player:GetAttribute(towerId .. "Rarity") then
                        player:SetAttribute(towerId .. "Stock", tpl.stock)
                    end
                end
                print(("[TempTowerRewards] %s map-%d victory cutscene-end: cleared towers, stock restored"):format(
                    player.Name, mapId))
            end
            -- The world-side cinematic (ladder drop / portal descent)
            -- already fired via BossRewardClaimed before the cutscene
            -- played; no extra event needed here. The previous code
            -- path also fired BossRewardClaimed AFTER the cutscene
            -- to gate the world cinematic; we now fire it earlier
            -- (right after the picker resolves) so CoreUpgrades can
            -- show its modal, and the world cinematic + cutscene
            -- both play in parallel afterwards.
        end)
    end)

    -- Cleanup on leave so stale pending state can't grant to a ghost UserId
    -- if a new player happens to get the same id (rare but guarded).
    Players.PlayerRemoving:Connect(function(player)
        pending[player.UserId] = nil
        pendingCutsceneCtx[player.UserId] = nil
    end)
end

return TempTowerRewards
