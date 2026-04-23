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

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))

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
    local function teleportPlayer(player, targetCF)
        local now = os.clock()
        if teleportCooldown[player.UserId] and now - teleportCooldown[player.UserId] < 2 then return end
        teleportCooldown[player.UserId] = now
        local char = player.Character
        if not char then return end
        local hrp = char:FindFirstChild("HumanoidRootPart")
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

    local hubClick = Instance.new("ClickDetector", portal)
    hubClick.MaxActivationDistance = 32
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
    -- at least 5 so the sell loop stays testable even after a run of sells.
    local function topUpDevRerollTokens(player)
        local cur = player:GetAttribute("RerollTokens") or 0
        if cur < 5 then player:SetAttribute("RerollTokens", 5) end
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

    devTeleportRemote.OnServerEvent:Connect(function(player, target)
        if type(target) ~= "string" then return end
        topUpDevRerollTokens(player)
        if target ~= "hub" then
            destroyPlayerTowers(player)
        end
        if target == "hub" then
            teleportPlayer(player, HUB_SPAWN_CF)
            print(("[ToL] DEV %s teleported to hub"):format(player.Name))
        elseif target == "map1" then
            teleportPlayer(player, TD_SPAWN_CF)
            local sm = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
            if sm then sm:Fire({mapId = 1, mapName = "Crook of the Tree"}) end
            print(("[ToL] DEV %s teleported to map 1, wave 1 starting"):format(player.Name))
        elseif target == "map2" then
            if not ctx.MAP2_PLAYER_SPAWN_CF then
                warn("[ToL] DEV teleport to map 2 — MAP2_PLAYER_SPAWN_CF not set (map 2 block failed?)")
                return
            end
            teleportPlayer(player, ctx.MAP2_PLAYER_SPAWN_CF)
            local sm = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
            if sm then sm:Fire({mapId = 2, mapName = "Climbing the Tree"}) end
            ctx.applyMap2Stage1OnEntry()
            -- Dev convenience: flag the player so the NEXT Core placement
            -- runs the full map-1 upgrade simulation (12 picks). Deferred
            -- to placement time because simulateOnePick's ammo-forcing rule
            -- reads live Core SPS — simulating before the tower exists
            -- would silently skip the AmmoCapacity threshold picks.
            -- Only set if the player has no prior run progress; we don't
            -- want to double-stack on top of real picks.
            if (player:GetAttribute("CoreDamageFlat") or 0) == 0
               and (player:GetAttribute("CoreRangePct") or 0) == 0
               and (player:GetAttribute("CoreFireRatePct") or 0) == 0 then
                player:SetAttribute("DevSimulateMap1OnNextCore", true)
            end
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
            print(("[ToL] DEV %s teleported to map 2, wave 1 starting"):format(player.Name))
        else
            warn("[ToL] DEV teleport — unknown target: " .. tostring(target))
        end
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

    -- Publish spawn CFrames and the teleport helper so DevRemotes (and
    -- any future module) can teleport players without re-implementing
    -- the cooldown pattern.
    ctx.HUB_SPAWN_CF   = HUB_SPAWN_CF
    ctx.TD_SPAWN_CF    = TD_SPAWN_CF
    ctx.teleportPlayer = teleportPlayer
end

return Portal
