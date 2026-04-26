--[[
    Portal.lua — Player entry flow for the hub world:

      1. The HubSpawn SpawnLocation parented under Workspace. New players
         respawn here (front of the giant tree, facing the doorway).
      2. The hub tree doorway portal: Touched event + ClickDetector
         (mobile friendly). Both teleport the player into the TD room
         and fire the tower-selection UI.
      3. Dev teleport handler: the dev panel's hub/map1/map2 buttons,
         with side-effects (SwitchMap bindable, grant starter stock on
         map 2 so the player can immediately place towers).

    The map-1-to-map-2 portal on the TD room's east wall is NOT here —
    it's constructed + wired by Map2.setup() in world/Map2.lua, because
    its existence is conceptually a map-2 feature.

    setup(ctx) reads:
      ctx.portal, treeBase, trunkSurfaceZ  (from HubWorld)
      ctx.rc, halfW                         (from TdRoom — for TD_SPAWN_CF)
      ctx.MAP2_PLAYER_SPAWN_CF              (from Map2)
      ctx.applyMap2Stage1OnEntry            (from Map2StageVisuals; late-resolved)

    And publishes:
      ctx.HUB_SPAWN_CF, ctx.TD_SPAWN_CF   -- useful for DevRemotes / any
                                            future handler that needs to
                                            place the player back at a
                                            named location
]]

local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Remotes      = require(Shared:WaitForChild("Remotes"))
local TempTowers   = require(Shared:WaitForChild("TempTowers"))
local MapRegistry  = require(Shared:WaitForChild("MapRegistry"))

-- DataStore for per-player prefs (e.g. hasSeenIntro). Required once at
-- module load; require() caches so hoisting this to module scope is
-- just for clarity, not performance.
local PermanentTowerStore = require(ServerScriptService:WaitForChild("PermanentTowerStore"))

local Portal = {}

function Portal.setup(ctx)
    local portal        = ctx.portal
    local treeBase      = ctx.treeBase
    local trunkSurfaceZ = ctx.trunkSurfaceZ
    local rc            = ctx.rc
    local halfW         = ctx.halfW

    -- Remotes are created by the hub orchestrator at startup, so WaitForChild
    -- resolves immediately here.
    local remoteEnterPortal  = ReplicatedStorage:WaitForChild(Remotes.Names.EnterPortal)
    local towerSelectRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.ShowTowerSelect)
    local devTeleportRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.DevTeleport)
    local showHotbarRemote   = ReplicatedStorage:WaitForChild(Remotes.Names.ShowHotbar)

    -- SpawnLocation on the hub side. Players respawn to this point (front
    -- of the giant tree). Re-use any existing SpawnLocation in Workspace
    -- so repeated Studio F5 doesn't accumulate duplicate spawns.
    local spawn = Workspace:FindFirstChildOfClass("SpawnLocation")
    if not spawn then
        spawn = Instance.new("SpawnLocation")
        spawn.Name = "HubSpawn"
        spawn.Size = Vector3.new(8, 1, 8)
        spawn.CFrame = CFrame.new(treeBase.X, 0.5, trunkSurfaceZ + 25)
        spawn.Anchored = true
        spawn.Neutral = true
        spawn.CanCollide = true
        spawn.Transparency = 1
        spawn.TopSurface = Enum.SurfaceType.Smooth
        spawn.Parent = Workspace
    end

    local TD_SPAWN_CF  = CFrame.new(rc + Vector3.new(-halfW + 25, 4, 0))
    local HUB_SPAWN_CF = CFrame.new(treeBase.X, 2, trunkSurfaceZ + 25)

    -- 2-second per-player cooldown so tapping the portal a few times in a
    -- row doesn't re-teleport on each touch.
    local teleportCooldown = {}
    local function teleportPlayer(player, targetCF, bypassCooldown)
        local now = os.clock()
        -- Cooldown applies to NATURAL portal triggers (prevents accidental
        -- double-fire from a single touch). DEV teleports pass bypassCooldown
        -- so a fast RESET → TP-CANOPY sequence isn't rejected by the cooldown
        -- the post-reset auto-TP-to-map-1 just set.
        if not bypassCooldown
           and teleportCooldown[player.UserId]
           and now - teleportCooldown[player.UserId] < 2 then
            return
        end
        teleportCooldown[player.UserId] = now
        local char = player.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        -- Auto-respawn dead/missing characters so the ragdoll-on-defeat
        -- flow doesn't leave us unable to teleport. RespawnTime was bumped
        -- to 60s so we can't rely on natural respawn here.
        if not char or (hum and hum.Health <= 0) then
            player:LoadCharacter()
            char = player.Character
            if not char then return end
        end
        local hrp = char:FindFirstChild("HumanoidRootPart")
            or char:WaitForChild("HumanoidRootPart", 2)
        if not hrp then return end
        hrp.CFrame = targetCF
    end

    -- First-portal-entry intro: before the tower picker, show a brief
    -- tutorial modal. Shown ONCE PER PLAYER EVER, tracked via the
    -- PermanentTowerStore "hasSeenIntro" pref (persisted across runs +
    -- sessions via DataStore). Within a session a player attribute
    -- caches the flag so we don't spam DataStore reads.
    local showIntroRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.ShowIntro)
    local function maybeShowIntro(player)
        if player:GetAttribute("HasSeenIntro") then return end
        if PermanentTowerStore.getPref(player, "hasSeenIntro") then
            player:SetAttribute("HasSeenIntro", true)
            return
        end
        player:SetAttribute("HasSeenIntro", true)
        PermanentTowerStore.setPref(player, "hasSeenIntro", true)
        if showIntroRemote then
            showIntroRemote:FireClient(player)
        end
    end

    -- Hub tree doorway: Touched for desktop, ClickDetector for mobile.
    -- Both paths teleport into the TD room, then prompt for tower select.
    portal.Touched:Connect(function(hit)
        local char = hit:FindFirstAncestorOfClass("Model")
        if not char then return end
        local player = Players:GetPlayerFromCharacter(char)
        if not player then return end
        teleportPlayer(player, TD_SPAWN_CF)
        remoteEnterPortal:FireClient(player)
        maybeShowIntro(player)
        task.wait(0.6)
        towerSelectRemote:FireClient(player)
        -- Note: map 1 leaf message fires AFTER tower pick (in towerPickedRemote
        -- handler) so it doesn't get covered by the picker UI.
    end)

    local hubClick = Instance.new("ClickDetector")
    hubClick.MaxActivationDistance = 32
    hubClick.Parent = portal
    hubClick.MouseClick:Connect(function(player)
        teleportPlayer(player, TD_SPAWN_CF)
        remoteEnterPortal:FireClient(player)
        maybeShowIntro(player)
        task.wait(0.6)
        towerSelectRemote:FireClient(player)
    end)

    ------------------------------------------------------------
    -- DEV TELEPORT — jump to hub / map 1 / map 2 from the dev panel.
    -- For map 1 and map 2, additionally fires the SwitchMap bindable so
    -- the wave system resets mobs, sets currentMapId, and auto-starts
    -- wave 1 after 4.5s (same behavior as the portal). For hub, just
    -- teleports without touching the wave system.
    ------------------------------------------------------------
    -- Dev QOL: any dev teleport or map-start move tops up reroll tokens to
    -- at least 3 (the run starting floor) so the sell loop + per-map
    -- reroll budget stays testable even after a run of sells.
    local function topUpDevRerollTokens(player)
        local cur = player:GetAttribute("RerollTokens") or 0
        if cur < 3 then player:SetAttribute("RerollTokens", 3) end
    end

    -- Dev teleport cleanup: destroy the player's existing towers before
    -- the map switch. The real map-1→map-2 flow destroys the map-1 Core
    -- in a cutscene; skipping that (as dev teleport does) leaves stale
    -- Phoenix towers on the old map that keep firing when the heart on
    -- the NEW map takes damage (tryConsumePhoenix scans ALL owned towers
    -- and a stale one with PhoenixReady=true gets consumed before the
    -- new map's one). Nuking all owned towers mimics the cutscene's
    -- destructive effect and sidesteps the Phoenix cross-map leak.
    local CollectionService = game:GetService("CollectionService")
    local Tags = require(Shared:WaitForChild("Tags"))
    local function destroyPlayerTowers(player)
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local model = towerBase.Parent
            if model and model:GetAttribute("Owner") == player.UserId then
                model:Destroy()
            end
        end
        -- Carry state would've been set by the real boss cutscene; clear
        -- it too so the new Core spawns fresh-Phoenix (not with stale
        -- carry from whatever state the skipped tower had).
        player:SetAttribute("PhoenixCarryCdRemaining", nil)
        player:SetAttribute("PhoenixCarryGraceRemaining", nil)
        player:SetAttribute("PhoenixCarryReady", nil)
    end

    -- Track per-player last known map so we can skip the destructive
    -- tower-clear when DevTeleport targets the same map. Without this,
    -- pressing the dev N/C/R hotkey from a stale-tracking client wipes
    -- every placed tower (repro: place towers on map 3 dusk, press N to
    -- "advance to night" → fires DevTeleport("map3") → destroyPlayerTowers
    -- runs even though the player never left map 3).
    -- Updated by both DevTeleport AND SwitchMap so natural map progression
    -- (walking through the portal to map 3) keeps the table in sync.
    local lastTeleportedMap = {}  -- [UserId] = "hub"/"map1"/"map2"/"map3"
    local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
    if switchMapBindable then
        switchMapBindable.Event:Connect(function(payload)
            local mapId = payload and payload.mapId
            local entry = MapRegistry.get(mapId)
            if not entry then return end
            for _, p in ipairs(Players:GetPlayers()) do
                lastTeleportedMap[p.UserId] = entry.key
            end
        end)
    end
    Players.PlayerRemoving:Connect(function(p)
        lastTeleportedMap[p.UserId] = nil
    end)

    devTeleportRemote.OnServerEvent:Connect(function(player, target)
        if type(target) ~= "string" then return end
        topUpDevRerollTokens(player)
        local last = lastTeleportedMap[player.UserId]
        if target ~= "hub" and last ~= target then
            destroyPlayerTowers(player)
        end
        lastTeleportedMap[player.UserId] = target
        if target == "hub" then
            teleportPlayer(player, HUB_SPAWN_CF, true)
            print(("[ToL] DEV %s teleported to hub"):format(player.Name))
        elseif target == "map1" then
            teleportPlayer(player, TD_SPAWN_CF, true)
            local sm = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
            if sm then sm:Fire({mapId = 1, mapName = "Crook of the Tree"}) end
            -- Dev convenience: auto-pick the Core (skip the TowerSelect
            -- modal) so the player can place towers immediately. Mirrors
            -- the map 2/3 dev paths' grant blocks. Skipped if the player
            -- already has stock from a real pick (don't overwrite progress).
            if (player:GetAttribute("PowerStock") or 0) <= 0
               and (player:GetAttribute("DoTStock")   or 0) <= 0
               and (player:GetAttribute("CCStock")    or 0) <= 0 then
                player:SetAttribute("PowerStock", 1)
                player:SetAttribute("DoTStock", 0)
                player:SetAttribute("CCStock", 0)
                player:SetAttribute("HasBeenGrantedStock", true)
                showHotbarRemote:FireClient(player)
            end
            print(("[ToL] DEV %s teleported to map 1, Core auto-granted"):format(player.Name))
        elseif target == "map2" then
            if not ctx.MAP2_PLAYER_SPAWN_CF then
                warn("[ToL] DEV teleport to map 2 — MAP2_PLAYER_SPAWN_CF not set (map 2 block failed?)")
                return
            end
            teleportPlayer(player, ctx.MAP2_PLAYER_SPAWN_CF, true)
            local sm = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
            if sm then sm:Fire({mapId = 2, mapName = "Climbing the Tree"}) end
            ctx.applyMap2Stage1OnEntry()
            -- Dev convenience: grant starting stock + show hotbar so the player
            -- can immediately place towers without going through the picker.
            if (player:GetAttribute("PowerStock") or 0) <= 0
               and (player:GetAttribute("DoTStock")   or 0) <= 0
               and (player:GetAttribute("CCStock")    or 0) <= 0 then
                player:SetAttribute("PowerStock", 1)
                player:SetAttribute("DoTStock", 0)
                player:SetAttribute("CCStock", 0)
                player:SetAttribute("HasBeenGrantedStock", true)
                showHotbarRemote:FireClient(player)
            end
            -- Dev convenience: grant a random aux tower so the map-2 test flow
            -- isn't Core-only. Skipped if the player already has any aux tower
            -- equipped (don't overwrite real run progress). Rolls from the same
            -- pool as Map1 boss drops (keeps the mix representative).
            local hasAux = false
            for towerId, _ in pairs(TempTowers.Templates) do
                if (player:GetAttribute(towerId .. "Stock") or 0) > 0 then
                    hasAux = true
                    break
                end
            end
            if not hasAux then
                local ids = {}
                for towerId, _ in pairs(TempTowers.Templates) do
                    table.insert(ids, towerId)
                end
                if #ids > 0 then
                    local pick = ids[math.random(1, #ids)]
                    local tpl = TempTowers.Templates[pick]
                    local rarity = TempTowers.rollRarity(TempTowers.BossWeights.Map1)
                    player:SetAttribute(pick .. "Rarity", rarity)
                    player:SetAttribute(pick .. "Stock",  tpl.stock)
                    print(("[ToL] DEV %s granted aux tower: %s [%s] ×%d"):format(
                        player.Name, tpl.displayName, rarity, tpl.stock))
                end
            end
            -- Map 2 dev port = one map's worth of upgrade picks (12). Fire
            -- AFTER stock + aux are granted so the simulator sees the player's
            -- equipped towers and rolls picks against the right baselines.
            -- Skipped if the player already has prior run progress (don't
            -- double-stack on top of real picks).
            if (player:GetAttribute("CoreDamageFlat") or 0) == 0
               and (player:GetAttribute("CoreRangePct") or 0) == 0
               and (player:GetAttribute("CoreFireRatePct") or 0) == 0 then
                local simBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSimulateMap1Picks)
                if simBindable then simBindable:Fire({ player = player, pickCount = 12 }) end
            end
            print(("[ToL] DEV %s teleported to map 2, wave 1 starting"):format(player.Name))
        elseif target == "map3" then
            if not ctx.MAP3_PLAYER_SPAWN_CF then
                warn("[ToL] DEV teleport to map 3 — MAP3_PLAYER_SPAWN_CF not set")
                return
            end
            teleportPlayer(player, ctx.MAP3_PLAYER_SPAWN_CF, true)
            -- Fire SwitchMap so the wave system flips currentMapId=3.
            -- Without this, StageAdvanced fires with whatever mapId the
            -- player was on previously (1 or 2), and Map3StageVisuals
            -- never gets called when the player advances waves on map 3.
            local sm = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
            if sm then sm:Fire({mapId = 3, mapName = "Canopy Nest"}) end
            ctx.applyMap3Stage1OnEntry()
            -- Same dev-stock convenience as map 2: grant a Core if the
            -- player has nothing equipped, so they can run wave 1 immediately.
            if (player:GetAttribute("PowerStock") or 0) <= 0
               and (player:GetAttribute("DoTStock")   or 0) <= 0
               and (player:GetAttribute("CCStock")    or 0) <= 0 then
                player:SetAttribute("PowerStock", 1)
                player:SetAttribute("DoTStock", 0)
                player:SetAttribute("CCStock", 0)
                player:SetAttribute("HasBeenGrantedStock", true)
                showHotbarRemote:FireClient(player)
            end
            -- Grant 2 random aux towers (map 3 = the late-game flow, so the
            -- player should already have collected a couple of map-boss
            -- drops by this point). Uses the same Map1 boss-drop weights
            -- as map 2's single-grant for parity.
            local granted = {}
            for towerId, _ in pairs(TempTowers.Templates) do
                if (player:GetAttribute(towerId .. "Stock") or 0) > 0 then
                    granted[towerId] = true
                end
            end
            local available = {}
            for towerId, _ in pairs(TempTowers.Templates) do
                if not granted[towerId] then
                    table.insert(available, towerId)
                end
            end
            for _ = 1, 2 do
                if #available == 0 then break end
                local idx = math.random(1, #available)
                local pick = available[idx]
                table.remove(available, idx)
                local tpl = TempTowers.Templates[pick]
                local rarity = TempTowers.rollRarity(TempTowers.BossWeights.Map1)
                player:SetAttribute(pick .. "Rarity", rarity)
                player:SetAttribute(pick .. "Stock",  tpl.stock)
                print(("[ToL] DEV %s granted aux tower: %s [%s] ×%d"):format(
                    player.Name, tpl.displayName, rarity, tpl.stock))
            end
            -- Map 3 = TWO maps' worth of upgrade picks (24 = 12 map-1 + 12
            -- map-2 with aux mix). Fire AFTER aux towers are granted so the
            -- second-12 picks see the equipped aux baselines and roll Aux
            -- upgrades against them. Pre-running the sim NOW (instead of
            -- deferring to first Core placement) means the placement preview
            -- already shows the modified range / damage / fire rate.
            if (player:GetAttribute("CoreDamageFlat") or 0) == 0
               and (player:GetAttribute("CoreRangePct") or 0) == 0
               and (player:GetAttribute("CoreFireRatePct") or 0) == 0 then
                local simBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSimulateMap1Picks)
                if simBindable then simBindable:Fire({ player = player, pickCount = 24 }) end
            end
            print(("[ToL] DEV %s teleported to map 3, wave 1 starting"):format(player.Name))
        else
            warn("[ToL] DEV teleport — unknown target: " .. tostring(target))
        end
    end)

    ------------------------------------------------------------
    -- DEV: cycle visual stage (1→2→3→4→1) for a given mapId.
    --
    -- Independent of the wave system — lets you preview per-stage growth
    -- (lighting, decor, branches, leaves, flowers, butterflies) without
    -- running waves. Each map keeps its own cycle counter.
    ------------------------------------------------------------
    local mapDevStage = { [1] = 1, [2] = 1, [3] = 1 }
    local cycleStageRemote = ReplicatedStorage:WaitForChild(Remotes.Names.DevCycleMapStage)
    -- Server-internal bindable so the wave system picks up the dev stage
    -- and re-broadcasts WaveState. Resolved AT FIRE TIME below — looking
    -- it up here would race against the wave system's getOrCreate.
    cycleStageRemote.OnServerEvent:Connect(function(player, mapId)
        mapId = tonumber(mapId)
        if not mapId or not mapDevStage[mapId] then return end
        mapDevStage[mapId] = (mapDevStage[mapId] % 4) + 1
        local stage = mapDevStage[mapId]
        if mapId == 1 then
            if ctx.tweenStageLighting then ctx.tweenStageLighting(stage) end
            if ctx.growStageDecor    then ctx.growStageDecor(stage)    end
        elseif mapId == 2 then
            if ctx.tweenStageLightingMap2 then ctx.tweenStageLightingMap2(stage) end
            if ctx.applyMap2StageVisuals  then ctx.applyMap2StageVisuals(stage)  end
        elseif mapId == 3 then
            if ctx.tweenStageLightingMap3 then ctx.tweenStageLightingMap3(stage) end
            if ctx.applyMap3StageVisuals  then ctx.applyMap3StageVisuals(stage, true) end
            -- Bird boss is the night stage on map 3. Auto-start when we
            -- cycle into stage 4; auto-stop when leaving it. Also clear
            -- any leftover wave mobs so the boss phase begins on a clean
            -- arena (per Matthew "the map should clear when you dev
            -- cycle to the boss stage").
            if stage == 4 and ctx.startBirdBoss then
                -- Clear any leftover wave mobs so the boss phase begins on
                -- a clean arena. CRITICAL bug history: the previous version
                -- did `mobPart.Parent or mobPart` and destroyed the parent
                -- when it was a Model — but mob Parts are parented DIRECTLY
                -- to ctx.tdRoom (also a Model, holding every tower). That
                -- chain wiped EVERY placed tower on stage 3 → 4. Now we
                -- destroy the mobPart itself; that's enough since each mob
                -- is a single Part, not a multi-Part Model.
                --
                -- TODO (next code cleanup): scan the codebase for the same
                -- pattern — any `:GetTagged(...)` loop that walks
                -- `part.Parent` and destroys it unconditionally. The risk
                -- shows up wherever entities are tagged-but-not-Modeled
                -- and get parented to a shared bucket (tdRoom, hubModel,
                -- etc.). Candidate hits to audit: ammo cleanup, web /
                -- spider / bird-boss leftover sweeps, DevReset's grid
                -- cleanup loop, anything that loops Tags.Mob /
                -- Tags.AmmoPile / Tags.SpiderWeb and calls Destroy on a
                -- parent reference. (BirdDiveMark used to be in this list
                -- too, removed with the legacy dive-strike mechanic.)
                for _, mobPart in ipairs(CollectionService:GetTagged(Tags.Mob or "Mob")) do
                    if mobPart.Parent then mobPart:Destroy() end
                end
                ctx.startBirdBoss()
            elseif stage ~= 4 and ctx.stopBirdBoss then
                ctx.stopBirdBoss()
            end
        end
        -- Update HUD label via wave-system stage state. Re-resolve each
        -- fire — the wave system may have created the bindable AFTER
        -- Portal.setup ran, in which case caching at setup-time gives nil.
        local devSetWaveStage = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSetWaveStage)
        if devSetWaveStage then devSetWaveStage:Fire(stage) end
        print(("[ToL] DEV %s cycled map %d visual stage → %d"):format(
            player.Name, mapId, stage))
    end)

    ------------------------------------------------------------
    -- DEV MOVE TO MAP START — map-2+ RESET button behavior.
    -- Respawns the player at their current map's spawn CFrame WITHOUT
    -- touching towers, grid, wave state, or upgrade progress. Full
    -- DevReset on map 2 was destructive (nuked the run to force a
    -- "re-place Core on map 2" state that blew up in several ways:
    -- wave token desync, stuck staircase visuals, lost dev-simulated
    -- Core upgrades). This is the gentler "oh wait, I need to be at
    -- the path start" affordance — use it during playtest when the
    -- player wanders off and can't see the mobs anymore.
    --
    -- Client picks between this and DevReset based on currentWaveState.mapId.
    ------------------------------------------------------------
    -- Client passes the current mapId (read from its cached WaveState);
    -- dev-only remote so we trust it. Server picks the right spawn CF.
    local moveToStartRemote = ReplicatedStorage:WaitForChild(Remotes.Names.DevMoveToMapStart)
    moveToStartRemote.OnServerEvent:Connect(function(player, mapId)
        mapId = tonumber(mapId) or 1
        topUpDevRerollTokens(player)
        local targetCF
        if mapId == 2 then
            targetCF = ctx.MAP2_PLAYER_SPAWN_CF
        elseif mapId == 1 then
            targetCF = TD_SPAWN_CF
        else
            targetCF = HUB_SPAWN_CF
        end
        if not targetCF then
            warn(("[ToL] MoveToMapStart: no spawn CF for mapId=%d"):format(mapId))
            return
        end
        teleportPlayer(player, targetCF)
        print(("[ToL] %s moved to map %d start"):format(player.Name, mapId))
    end)

    -- Server-internal bindable: WaveSystem's resurrect flow fires this
    -- for each player after the heart is healed, so ragdolled bodies
    -- come back to the TD room (not the hub SpawnLocation that a
    -- natural LoadCharacter would use). WaveSystem can't share ctx
    -- with the hub — separate script, separate WaveContext — so a
    -- bindable is the cleanest way to reach teleportPlayer + spawn CFs.
    local respawnBindable = Remotes.getOrCreate(
        Remotes.Names.RespawnPlayerAtMapSpawn, "BindableEvent")
    respawnBindable.Event:Connect(function(player, mapId)
        if not player or not player.Parent then return end
        mapId = tonumber(mapId) or 1
        local targetCF
        if mapId == 2 then
            targetCF = ctx.MAP2_PLAYER_SPAWN_CF
        else
            targetCF = TD_SPAWN_CF
        end
        if not targetCF then return end
        teleportPlayer(player, targetCF)
    end)

    -- Publish spawn CFrames and the teleport helper so DevRemotes (and
    -- any future module) can teleport players without re-implementing
    -- the cooldown pattern.
    ctx.HUB_SPAWN_CF   = HUB_SPAWN_CF
    ctx.TD_SPAWN_CF    = TD_SPAWN_CF
    ctx.teleportPlayer = teleportPlayer
end

return Portal
