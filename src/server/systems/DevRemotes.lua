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
      ctx.gridState, MAP4_TOTAL_COLS, MAX_GRID_ROWS  (grid walk on reset)
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

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local Tags       = require(Shared:WaitForChild("Tags"))
local Remotes    = require(Shared:WaitForChild("Remotes"))
local TempTowers = require(Shared:WaitForChild("TempTowers"))

local AttachmentStore      = require(ServerScriptService:WaitForChild("AttachmentStore"))
local PermanentTowerStore  = require(ServerScriptService:WaitForChild("PermanentTowerStore"))
local Attachments     = require(ServerScriptService:WaitForChild("Attachments"))

local DevRemotes = {}

function DevRemotes.setup(ctx)
    local gridState       = ctx.gridState
    local MAP4_TOTAL_COLS = ctx.MAP4_TOTAL_COLS  -- spans all four maps
    local MAX_GRID_ROWS   = ctx.MAX_GRID_ROWS
    local tdRoom          = ctx.tdRoom
    local floor           = ctx.floor
    local RunState        = ctx.RunState
    local broadcastGrid   = ctx.broadcastGrid

    local devResetRemote      = ReplicatedStorage:WaitForChild(Remotes.Names.DevReset)
    local setTargetModeRemote = ReplicatedStorage:WaitForChild(Remotes.Names.SetTowerTargetMode)
    local showHotbarRemote    = ReplicatedStorage:WaitForChild(Remotes.Names.ShowHotbar)
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
    -- Wrapped in `performDevReset` so DevGroundZero (below) can reuse
    -- the full in-session teardown after wiping DataStores.
    ------------------------------------------------------------
    local function performDevReset(player)
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
        -- back to "open". Walks the FULL shared grid (all four maps incl.
        -- Map 4 / Pickle Swamp) so reset works regardless of which map
        -- the player was in when they reset.
        for c = 0, MAP4_TOTAL_COLS - 1 do
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
            -- RerollTokens is run-scoped (stage-boss kill reward).
            -- Starting amount = 3 (matches TreeOfLife_Hub PlayerAdded).
            -- Seedlings are NOT reset — persistent across runs as the
            -- future run-boss → shop currency.
            p:SetAttribute("RerollTokens", 3)
            p:SetAttribute("HasReceivedFreeReward", false)
            p:SetAttribute("HasReceivedFreeReward_Map1", false)
            p:SetAttribute("HasReceivedFreeReward_Map2", false)
            p:SetAttribute("HasReceivedFreeReward_Map3", false)
            -- Dev-simulator ammo threshold flags: reset per run so DevSkipToBoss
            -- re-evaluates the 5/15 SPS triggers fresh on each replay.
            p:SetAttribute("DevAmmoPickedAt5", nil)
            p:SetAttribute("DevAmmoPickedAt15", nil)
            -- Final-boss minigame's rolling bonus-damage stack lives in
            -- FinalBoss.lua's per-player table now (was a pair of player
            -- attributes pre-2026-04). Clear via the helper so dev reset
            -- wipes it without poking module internals.
            if ctx.clearPlayerBonus then ctx.clearPlayerBonus(p) end
            -- Pickle Lord's range-decay attribute. While he's alive his
            -- 30-game-sec tick multiplies this × 0.9; reset wipes back
            -- to nil so the next run starts at full range. Towers.lua
            -- treats nil as 1.0 (no decay).
            p:SetAttribute("RangeDecayMultiplier", nil)
            p:SetAttribute("MaxCarry", 15)
            p:SetAttribute("RunLuckSum", 0)
            p:SetAttribute("RunLuckCount", 0)
            p:SetAttribute("MapPickCount", 0)
            -- Clear any temp-tower rarity+stock attributes the player picked
            -- during the run. Permanent towers (earned from Pickle Lord)
            -- would be stored under different attribute names and NOT
            -- reset here; temp towers are run-scoped.
            for towerId in pairs(TempTowers.Templates) do
                p:SetAttribute(towerId .. "Rarity", nil)
                p:SetAttribute(towerId .. "Stock",  nil)
            end
            -- Clear cumulative upgrade attributes (Core/Aux × Damage/Range/
            -- FireRate percentages + Core special stacks + ammo cap mult).
            -- These accumulate across a run and must reset so the next run
            -- doesn't inherit prior upgrades on freshly-placed towers.
            for _, category in ipairs({ "Core", "Aux" }) do
                -- Damage is flat additive (new system); Range/FireRate are %.
                p:SetAttribute(category .. "DamageFlat", 0)
                for _, stat in ipairs({ "Range", "FireRate" }) do
                    p:SetAttribute(category .. stat .. "Pct", 0)
                end
            end
            p:SetAttribute("CoreAoeRadius",    nil)
            p:SetAttribute("CoreStunDuration", nil)
            p:SetAttribute("CoreKnockback",    nil)
            -- Proc-chance stacks for Knockback + Stun (new chance-based
            -- system — magnitude fixed, chance stacks on repeat picks).
            p:SetAttribute("CoreStunChance",      nil)
            p:SetAttribute("CoreKnockbackChance", nil)
            p:SetAttribute("CoreMaxShotsMult", 1.0)
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
    end
    devResetRemote.OnServerEvent:Connect(performDevReset)

    ------------------------------------------------------------
    -- DEV GROUND ZERO: DevReset PLUS wipes the persistent DataStores
    -- (attachments, permanent towers, per-player prefs like
    -- hasSeenIntro / first-time-player flags). Re-fires DevReset path
    -- so the in-session state (towers, grid, attrs, stock) is also
    -- cleared. Use this when you want to experience the game from a
    -- truly fresh account — including the first-time-player fairy.
    ------------------------------------------------------------
    local groundZeroRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevGroundZero)
        or (function()
            local r = Instance.new("RemoteEvent")
            r.Name = Remotes.Names.DevGroundZero
            r.Parent = ReplicatedStorage
            return r
        end)()
    groundZeroRemote.OnServerEvent:Connect(function(player)
        print(("[ToL] DEV GROUND ZERO fired by %s"):format(player.Name))
        -- Wipe persisted stores first so the re-fired DevReset path
        -- doesn't regrant anything that should be forgotten.
        pcall(function() PermanentTowerStore.wipe(player) end)
        pcall(function() AttachmentStore.wipe(player) end)
        -- Clear per-player runtime attrs that mirror store state.
        player:SetAttribute("Seedlings", 0)
        player:SetAttribute("EquippedAttachmentType", nil)
        player:SetAttribute("EquippedAttachmentRarity", nil)
        player:SetAttribute("HasSeenFirstDeathFairy", nil)
        -- Fire DevReset to rebuild the in-session state (towers, grid,
        -- stock, attrs) from scratch, same path the normal RESET button uses.
        performDevReset(player)
    end)

    ------------------------------------------------------------
    -- FIRST-DEATH FAIRY pick handler. Fired by client when the player
    -- chooses one of the 3 common attachments offered on their first
    -- death. Grants the attachment at Common rarity + sets the pref
    -- flag so the fairy doesn't re-fire on future deaths.
    ------------------------------------------------------------
    local pickFairyRemote = Remotes.getOrCreate(
        Remotes.Names.PickFirstDeathAttachment, "RemoteEvent")
    local ALLOWED_FAIRY_ATTACHMENTS = {
        PowerCore = true, Detonator = true, Phoenix = true,
    }
    pickFairyRemote.OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= "table" then return end
        local attType = payload.attType
        if type(attType) ~= "string" or not ALLOWED_FAIRY_ATTACHMENTS[attType] then
            return
        end
        -- Guard against double-fire — if pref is already set, ignore.
        if PermanentTowerStore.getPref(player, "hasSeenFirstDeathFairy") then return end
        -- Grant Common rarity + auto-equip so the resurrection restarts
        -- the wave with the attachment already active. Duplicate policy:
        -- no-op if player already owns at Common+ (shouldn't happen for
        -- a first-death player but be safe).
        local result = AttachmentStore.tryAward(player, attType, "Common")
        AttachmentStore.setEquipped(player, attType)
        player:SetAttribute("EquippedAttachmentType", attType)
        player:SetAttribute("EquippedAttachmentRarity", 1)  -- Common = 1
        PermanentTowerStore.setPref(player, "hasSeenFirstDeathFairy", true)
        print(("[ToL] %s chose first-death fairy gift: %s (Common) — %s (equipped)"):format(
            player.Name, attType, result.result))
        -- Push the attachments-changed notification so the inventory
        -- panel + HUD refresh for the client.
        if attachmentsChangedRemote then
            attachmentsChangedRemote:FireClient(player, {
                owned = AttachmentStore.getOwned(player),
                equipped = AttachmentStore.load(player).equipped,
            })
        end
        -- Trigger the team-wide resurrection: heart healed, mobs cleared,
        -- current wave restarts with the new attachment equipped. The
        -- wave system's ResurrectAfterFirstDeath listener owns the state
        -- transitions — DevRemotes just signals.
        local resurrectBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.ResurrectAfterFirstDeath)
        if resurrectBindable then resurrectBindable:Fire() end
    end)

    ------------------------------------------------------------
    -- Target mode change: client → server. Validates the caller owns
    -- the tower and the mode is one of the allowed values.
    ------------------------------------------------------------
    local VALID_TARGET_MODES = {First = true, Last = true, Center = true, Strongest = true, Weakest = true}
    setTargetModeRemote.OnServerEvent:Connect(function(player, towerModel, mode)
        if typeof(towerModel) ~= "Instance" or not towerModel:IsA("Model") then return end
        if not towerModel.Parent then return end
        if not VALID_TARGET_MODES[mode] then return end
        if towerModel:GetAttribute("Owner") ~= player.UserId then return end
        towerModel:SetAttribute("TargetMode", mode)
        print(("[TreeOfLife] %s set %s TargetMode=%s"):format(
            player.Name, towerModel.Name, mode))
    end)

    -- BossDefeated reward flow lives in systems/TempTowerRewards.lua now.
    -- This module no longer touches BossDefeated (it used to roll an
    -- attachment here; attachments are reserved for the Run Boss / shop
    -- flow, per the locked economy: stage bosses → reroll tokens,
    -- map bosses → temp tower picker, run boss → seedlings + permanent
    -- tower + attachment).

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

    -- (Previously pushed an AttachmentsChanged payload after each
    -- BossDefeated to keep the picker in sync with the new award.
    -- No longer needed — attachments aren't awarded on map-boss
    -- kills in the new economy. When the Run Boss is built and
    -- grants Seedlings / attachments, re-add a FireClient here.)
end

return DevRemotes
