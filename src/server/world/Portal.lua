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

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

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

    -- Hub tree doorway: Touched for desktop, ClickDetector for mobile.
    -- Both paths teleport into the TD room, then prompt for tower select.
    portal.Touched:Connect(function(hit)
        local char = hit:FindFirstAncestorOfClass("Model")
        if not char then return end
        local player = Players:GetPlayerFromCharacter(char)
        if not player then return end
        teleportPlayer(player, TD_SPAWN_CF)
        remoteEnterPortal:FireClient(player)
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
    devTeleportRemote.OnServerEvent:Connect(function(player, target)
        if type(target) ~= "string" then return end
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
            print(("[ToL] DEV %s teleported to map 2, wave 1 starting"):format(player.Name))
        else
            warn("[ToL] DEV teleport — unknown target: " .. tostring(target))
        end
    end)

    -- Publish spawn CFrames and the teleport helper so DevRemotes (and
    -- any future module) can teleport players without re-implementing
    -- the cooldown pattern.
    ctx.HUB_SPAWN_CF   = HUB_SPAWN_CF
    ctx.TD_SPAWN_CF    = TD_SPAWN_CF
    ctx.teleportPlayer = teleportPlayer
end

return Portal
