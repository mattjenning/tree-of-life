--[[
    DevRemotes.lua — Handlers for Remote/Bindable events that aren't
    part of the core tower placement / wave-loop path:

      - DevReset    : dev-panel "reset run" button. Wipes towers,
                      restores grid, resets stage visuals, restarts
                      the auto-start countdown.
      - SetTowerTargetMode : client → server, change a tower's
                      target-priority mode (First/Strongest/Center/Last).
      - BossDefeated (bindable, fired by the wave system when the
                      final boss dies):
          * handler 1 : roll + award a random attachment per player
          * handler 2 : push a fresh AttachmentsChanged payload after
                        the award so any open picker updates
      - Attachment endpoints (GetAttachments / EquipAttachment).
        Remote instances are created here if they don't exist, so the
        Client's WaitForChild resolves.

    Despite the "DevRemotes" name (inherited from the Phase 2 plan),
    this module now owns more than just dev stuff. That's fine — the
    commit message calls it out — a rename could happen later.

    setup(ctx) reads:
      ctx.gridState, MAP2_TOTAL_COLS, MAX_GRID_ROWS  (grid walk on reset)
      ctx.tdRoom, floor                               (decor/floor reset)
      ctx.RunState                                    (firstPickFired flag)
      ctx.broadcastGrid                               (post-reset broadcast)
      ctx.applyMap2StageVisuals                       (reset map 2 visuals)
      ctx.cancelLightingTweens, STAGE_LIGHTING        (snap lighting back)

    Publishes nothing.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Tags    = require(Shared:WaitForChild("Tags"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local AttachmentStore = require(ServerScriptService:WaitForChild("AttachmentStore"))
local Attachments     = require(ServerScriptService:WaitForChild("Attachments"))

local DevRemotes = {}

function DevRemotes.setup(ctx)
    local gridState       = ctx.gridState
    local MAP2_TOTAL_COLS = ctx.MAP2_TOTAL_COLS
    local MAX_GRID_ROWS   = ctx.MAX_GRID_ROWS
    local tdRoom          = ctx.tdRoom
    local floor           = ctx.floor
    local RunState        = ctx.RunState
    local broadcastGrid   = ctx.broadcastGrid

    local devResetRemote      = ReplicatedStorage:WaitForChild(Remotes.Names.DevReset)
    local setTargetModeRemote = ReplicatedStorage:WaitForChild(Remotes.Names.SetTowerTargetMode)
    local showHotbarRemote    = ReplicatedStorage:WaitForChild(Remotes.Names.ShowHotbar)
    local bossDefeatedBindable = ReplicatedStorage:WaitForChild(Remotes.Names.BossDefeated)
    local autoStartBindable    = ReplicatedStorage:WaitForChild(Remotes.Names.WaveAutoStart)

    -- Attachment endpoints. Remote instances are created here if not
    -- present (the Client WaitForChilds them at startup; the hub's
    -- earlier ensureRemote pass doesn't cover them since they're a
    -- RemoteFunction plus two RemoteEvents).
    local getAttachmentsFunc = ReplicatedStorage:FindFirstChild(Remotes.Names.GetAttachments)
    if not getAttachmentsFunc then
        getAttachmentsFunc = Instance.new("RemoteFunction")
        getAttachmentsFunc.Name = Remotes.Names.GetAttachments
        getAttachmentsFunc.Parent = ReplicatedStorage
    end
    local equipAttachmentRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.EquipAttachment)
    if not equipAttachmentRemote then
        equipAttachmentRemote = Instance.new("RemoteEvent")
        equipAttachmentRemote.Name = Remotes.Names.EquipAttachment
        equipAttachmentRemote.Parent = ReplicatedStorage
    end
    local attachmentsChangedRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.AttachmentsChanged)
    if not attachmentsChangedRemote then
        attachmentsChangedRemote = Instance.new("RemoteEvent")
        attachmentsChangedRemote.Name = Remotes.Names.AttachmentsChanged
        attachmentsChangedRemote.Parent = ReplicatedStorage
    end
    local attachmentRevealRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.AttachmentRevealed)
    if not attachmentRevealRemote then
        attachmentRevealRemote = Instance.new("RemoteEvent")
        attachmentRevealRemote.Name = Remotes.Names.AttachmentRevealed
        attachmentRevealRemote.Parent = ReplicatedStorage
    end

    ------------------------------------------------------------
    -- DEV RESET: clears all placed towers, resets grid, restores stock to 3.
    -- Anyone in the game can fire this from the dev button.
    ------------------------------------------------------------
    devResetRemote.OnServerEvent:Connect(function(player)
        print(("[ToL] DEV RESET fired by %s"):format(player.Name))

        -- (1) Destroy ALL towers via CollectionService tag. Catches any tower
        -- regardless of parent, matching exactly the set the wave system and
        -- Phoenix system iterate over.
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local model = towerBase.Parent
            if model and model.Parent then
                model:Destroy()
            elseif towerBase.Parent then
                towerBase:Destroy()
            end
        end

        -- (2) Aggressive grid cleanup: any cell that ISN'T path or heart goes
        -- back to "open". Walks the FULL shared grid (both maps) so reset
        -- works regardless of which map the player was in when they reset.
        for c = 0, MAP2_TOTAL_COLS - 1 do
            for r = 0, MAX_GRID_ROWS - 1 do
                local s = gridState[c][r]
                -- Preserve path/heart/decor so permanent geometry (staircase etc.)
                -- stays impassable to tower placement across runs.
                if s ~= "path" and s ~= "heart" and s ~= "decor" then
                    gridState[c][r] = "open"
                end
            end
        end

        -- (3) Restore heart HP — both maps' hearts (each has their own MaxHealth)
        for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
            h:SetAttribute("Health", h:GetAttribute("MaxHealth") or 500)
        end

        -- (4) Tell wave system to fully reset run/stage state BEFORE we rebuild
        -- hotbars, so the "waveInProgress=false" state is in place when the
        -- auto-start countdown is checked.
        do
            local runResetBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.RunReset)
            if runResetBindable then runResetBindable:Fire() end
        end

        -- (4a) Reset map 2 visuals to stage 1 (re-buries stage 2/3 staircase
        -- parts and flips their risen=false so they'll re-animate on stage
        -- advance next run).
        ctx.applyMap2StageVisuals(1, false)

        -- (5) Restore everyone's stock and attrs. Set the attribute FIRST,
        -- then wait a frame so the replication lands before we fire
        -- ShowHotbar. Prevents a race where the client rebuilds the hotbar
        -- from a stale stock value of 0.
        for _, p in ipairs(Players:GetPlayers()) do
            p:SetAttribute("PowerStock", 1)
            p:SetAttribute("DoTStock", 0)
            p:SetAttribute("CCStock", 0)
            p:SetAttribute("CarryingAmmo", 0)
            p:SetAttribute("WaveAutoStartScheduled", nil)
            p:SetAttribute("RerollsUsed", 0)
            -- RerollTokens is run-scoped (stage-boss kill reward), reset
            -- each new run. Seedlings are NOT reset — persistent across
            -- runs as the future run-boss → shop currency.
            p:SetAttribute("RerollTokens", 0)
            p:SetAttribute("HasReceivedFreeReward", false)
            p:SetAttribute("BonusDamageUntil", 0)
            p:SetAttribute("MaxCarry", 15)
            p:SetAttribute("RunLuckSum", 0)
            p:SetAttribute("RunLuckCount", 0)
        end
        task.wait()  -- let attribute replication flush
        for _, p in ipairs(Players:GetPlayers()) do
            showHotbarRemote:FireClient(p)
        end

        -- (6) Reset stage visuals to stage 1. Cancel any in-flight stage-lighting
        -- tweens so they don't overwrite the snap a frame later.
        do
            local existing = tdRoom:FindFirstChild("StageDecor")
            if existing then existing:Destroy() end
            ctx.cancelLightingTweens()
            local cfg = ctx.STAGE_LIGHTING and ctx.STAGE_LIGHTING[1]
            if cfg then
                Lighting.ClockTime = cfg.clockTime
                Lighting.Ambient = cfg.ambient
                if floor and floor.Parent then floor.Color = cfg.floorTint end
            end
        end

        -- (7) Re-fire the 5-second countdown since everyone already has stock
        -- (no tower-pick event will fire after a reset).
        RunState.firstPickFired = true
        local wsRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.WaveState)
        if wsRemote then
            wsRemote:FireAllClients({
                wave = 0, totalWaves = 5, mobsAlive = 0, map = "Crook of the Tree (Morning)", stage = 1,
                inProgress = false, pendingCountdown = 5,
            })
        end
        task.delay(5, function()
            autoStartBindable:Fire(player)
        end)

        -- (8) Broadcast updated grid state to all clients
        broadcastGrid()
    end)

    ------------------------------------------------------------
    -- Target mode change: client → server. Validates the caller owns
    -- the tower and the mode is one of the allowed values.
    ------------------------------------------------------------
    local VALID_TARGET_MODES = {First = true, Strongest = true, Center = true, Last = true}
    setTargetModeRemote.OnServerEvent:Connect(function(player, towerModel, mode)
        if typeof(towerModel) ~= "Instance" or not towerModel:IsA("Model") then return end
        if not towerModel.Parent then return end
        if not VALID_TARGET_MODES[mode] then return end
        if towerModel:GetAttribute("Owner") ~= player.UserId then return end
        towerModel:SetAttribute("TargetMode", mode)
        print(("[TreeOfLife] %s set %s TargetMode=%s"):format(
            player.Name, towerModel.Name, mode))
    end)

    ------------------------------------------------------------
    -- BossDefeated → roll a random attachment for each player and try
    -- to award. Rarity rolls via Attachments.RARITY_DROP_WEIGHTS;
    -- type is uniform across known types. Result is one of: "new"
    -- (player didn't own this type), "upgraded" (had lower rarity),
    -- or "duplicate" (had same/higher — discarded).
    ------------------------------------------------------------
    bossDefeatedBindable.Event:Connect(function()
        -- If the boss was killed via DevSkipWave, suppress the blocking
        -- reveal modal so the dev can spam Skip Wave without having to
        -- dismiss "AWESOME" between kills. The attachment is still
        -- rolled, awarded, and saved — only the UI is skipped. Window
        -- is set by the DevSkipWave handler in the wave system; other
        -- UI firings (stage complete) check the same window.
        local suppressReveal = os.clock() < (ctx._devSkipSuppressUntil or 0)

        for _, player in ipairs(Players:GetPlayers()) do
            local rolled = Attachments.rollAttachment()
            local awardResult = AttachmentStore.tryAward(player, rolled.type, rolled.rarity)
            AttachmentStore.save(player)
            print(("[TreeOfLife] %s rolled %s → %s%s"):format(
                player.Name, Attachments.describe(rolled), awardResult.result,
                suppressReveal and " (reveal suppressed — dev skip)" or ""))
            if not suppressReveal then
                attachmentRevealRemote:FireClient(player, {
                    rolled    = rolled,
                    result    = awardResult.result,
                    entry     = awardResult.entry,
                    oldRarity = awardResult.oldRarity,
                })
            end
        end
    end)

    ------------------------------------------------------------
    -- Attachment management endpoints (v2 schema)
    -- GetAttachments: returns {owned = list of {type, rarity, isEquipped}, equipped = type|nil}
    -- EquipAttachment: client picks which type to equip (or "" to unequip)
    -- AttachmentsChanged: server pushes refreshed payload after any change
    -- AttachmentRevealed: server pushes after Final Boss kill
    ------------------------------------------------------------
    local function buildAttachmentPayload(player)
        local owned = AttachmentStore.getOwned(player)
        local equipped = AttachmentStore.load(player).equipped
        local list = {}
        for _, attType in ipairs(Attachments.TYPE_NAMES) do
            local entry = owned[attType]
            if entry then
                table.insert(list, {
                    type = entry.type,
                    rarity = entry.rarity,
                    isEquipped = (equipped == entry.type),
                })
            end
        end
        return {owned = list, equipped = equipped}
    end

    getAttachmentsFunc.OnServerInvoke = function(player)
        return buildAttachmentPayload(player)
    end

    equipAttachmentRemote.OnServerEvent:Connect(function(player, attType)
        if attType == "" then attType = nil end
        if attType ~= nil and type(attType) ~= "string" then return end
        AttachmentStore.setEquipped(player, attType)
        AttachmentStore.save(player)
        -- Mirror what's ACTUALLY equipped (re-read from the store rather than
        -- trusting `attType` directly). setEquipped silently rejects requests
        -- to equip un-owned attachments — if we mirrored the request value
        -- naively, the client HUD would think Phoenix was equipped and show
        -- "Phoenix: READY", but no tower would have Phoenix attributes, so
        -- mobs reaching the heart would do damage with no Phoenix interception.
        local actuallyEquipped = AttachmentStore.getEquipped(player)
        player:SetAttribute("EquippedAttachmentType",
            actuallyEquipped and actuallyEquipped.type or "")
        attachmentsChangedRemote:FireClient(player, buildAttachmentPayload(player))
    end)

    -- Push an attachments-changed payload after each award too (in addition to
    -- AttachmentRevealed) so the picker stays in sync if open.
    bossDefeatedBindable.Event:Connect(function()
        task.wait(0.1)
        for _, player in ipairs(Players:GetPlayers()) do
            attachmentsChangedRemote:FireClient(player, buildAttachmentPayload(player))
        end
    end)
end

return DevRemotes
