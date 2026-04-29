--[[
    TowerPlacement.lua — Server handlers for the full tower lifecycle:
      - TowerPicked : player chose a tower from the pre-wave picker
      - PlaceTower  : player confirmed placement at an (anchorCol, anchorRow)
      - SellTower   : player picked up a placed tower (refund 1 stock,
                      spend reroll tokens, free the grid cells)

    WHY THIS MODULE EXISTS:
    The placement handler alone was ~230 lines of validation, world-space
    math, model scaling, cumulative-upgrade stamping, and attachment
    application. Sitting inside the hub orchestrator it was the largest
    single function in the file. Moving it here keeps the hub focused on
    wiring and makes this file the one place to look for "what happens
    when the player places a tower."

    setup(ctx) reads:
      ctx.gridState                              (shared multi-map grid)
      ctx.rc / halfW / halfD                     (map 1 world origin)
      ctx.CELL_SIZE
      ctx.MAP2_CENTER / WIDTH / DEPTH / COL_OFFSET / TOTAL_COLS / ROWS
      ctx.GRID_COLS / GRID_ROWS
      ctx.TOWER_BUILDERS                         (from TowerBuilders.setup)
      ctx.RunState                               (firstPickFired flag)
      ctx.broadcastGrid                          (grid diff → all clients)
      ctx.grantPermanentStock                    (from PermanentTowers)
      ctx.fireLeafMessage                        (map 1 intro leaf)

    Publishes nothing — purely side-effecting handler setup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace         = game:GetService("Workspace")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local TowerTypes  = require(Shared:WaitForChild("TowerTypes"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))
local BBoxUtil    = require(Shared:WaitForChild("BBoxUtil"))
local CoreTypes   = require(Shared:WaitForChild("CoreTypes"))
local StatLedger  = require(script.Parent:WaitForChild("StatLedger"))

local AttachmentStore = require(ServerScriptService:WaitForChild("AttachmentStore"))
local Attachments     = require(ServerScriptService:WaitForChild("Attachments"))

-- Map 1 leaf message — fired AFTER the player picks a tower (not at
-- portal entry, so the narrative text doesn't get covered by the
-- tower-picker UI). One line is picked at random per run.
local MAP1_LEAF_LINES = {
    "protect me, and I'll reward you",
    "who will help me?",
    "will you reach the top?",
    "what terrors await?",
    "can you save me?",
}

local TowerPlacement = {}

function TowerPlacement.setup(ctx)
    local gridState          = ctx.gridState
    local rc                 = ctx.rc
    local halfW              = ctx.halfW
    local halfD              = ctx.halfD
    local CELL_SIZE          = ctx.CELL_SIZE
    local MAP2_CENTER        = ctx.MAP2_CENTER
    local MAP2_WIDTH         = ctx.MAP2_WIDTH
    local MAP2_DEPTH         = ctx.MAP2_DEPTH
    local MAP2_COL_OFFSET    = ctx.MAP2_COL_OFFSET
    local MAP2_TOTAL_COLS    = ctx.MAP2_TOTAL_COLS
    local MAP2_ROWS          = ctx.MAP2_ROWS
    local MAP3_CENTER        = ctx.MAP3_CENTER
    local MAP3_WIDTH         = ctx.MAP3_WIDTH
    local MAP3_DEPTH         = ctx.MAP3_DEPTH
    local MAP3_COL_OFFSET    = ctx.MAP3_COL_OFFSET
    local MAP3_TOTAL_COLS    = ctx.MAP3_TOTAL_COLS
    local MAP3_ROWS          = ctx.MAP3_ROWS
    local MAP4_CENTER        = ctx.MAP4_CENTER
    local MAP4_WIDTH         = ctx.MAP4_WIDTH
    local MAP4_DEPTH         = ctx.MAP4_DEPTH
    local MAP4_COL_OFFSET    = ctx.MAP4_COL_OFFSET
    local MAP4_TOTAL_COLS    = ctx.MAP4_TOTAL_COLS
    local MAP4_ROWS          = ctx.MAP4_ROWS
    local GRID_COLS          = ctx.GRID_COLS
    local GRID_ROWS          = ctx.GRID_ROWS
    local TOWER_BUILDERS     = ctx.TOWER_BUILDERS
    local RunState           = ctx.RunState
    local broadcastGrid      = ctx.broadcastGrid
    local grantPermanentStock = ctx.grantPermanentStock
    local fireLeafMessage    = ctx.fireLeafMessage

    local towerPickedRemote = ReplicatedStorage:WaitForChild(Remotes.Names.TowerPicked)
    local placeTowerRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.PlaceTower)
    local showHotbarRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.ShowHotbar)
    local autoStartBindable = ReplicatedStorage:WaitForChild(Remotes.Names.WaveAutoStart)
    local sellTowerRemote   = ReplicatedStorage:FindFirstChild(Remotes.Names.SellTower)
        or (function()
            local r = Instance.new("RemoteEvent")
            r.Name = Remotes.Names.SellTower
            r.Parent = ReplicatedStorage
            return r
        end)()

    -- Thin footprint + base-stats lookup for the placement handler.
    -- TowerTypes for Core, TempTowers.Templates for aux. The placement
    -- handler only reads `footprint` from this table; damage/range/fireRate
    -- are stamped directly by the builders (from either TowerTypes or
    -- TempTowers.resolveStats depending on tower type).
    local TOWER_DEFS = {}
    -- Core archetypes — all three live in shared/TowerTypes. Loop
    -- handles whichever the player picks via the loadout's coreId.
    -- Per Matthew 2026-04-27: ControlCore + SupportCore selectable
    -- as alternatives to Power.
    for _, id in ipairs(CoreTypes.Ids) do
        local t = TowerTypes[id]
        if t then
            TOWER_DEFS[id] = {
                footprint = { t.footprintWidth, t.footprintDepth },
                damage    = t.damage,
                range     = t.range,
                fireRate  = t.fireRate,
            }
        end
    end
    for id, tpl in pairs(TempTowers.Templates) do
        TOWER_DEFS[id] = {
            footprint = { tpl.footprintWidth, tpl.footprintDepth },
            damage    = tpl.damage,
            range     = tpl.range,
            fireRate  = tpl.fireRate,
        }
    end

    -- Grid-footprint check. Four-way per-col dispatch:
    --   map 1 → cols [0, GRID_COLS-1]
    --   map 2 → cols [MAP2_COL_OFFSET, MAP2_TOTAL_COLS-1]
    --   map 3 → cols [MAP3_COL_OFFSET, MAP3_TOTAL_COLS-1]
    --   map 4 → cols [MAP4_COL_OFFSET, MAP4_TOTAL_COLS-1]   (Pickle Swamp / Infinite)
    -- rowMax differs per map. (Per the shared-grid dispatch rule — every
    -- cell↔world path must branch the same way as Grid.cellToWorld.)
    local function canPlaceAt(anchorCol, anchorRow, footprintW, footprintD)
        local colMin, colMax, rowMax
        if anchorCol >= MAP4_COL_OFFSET then
            colMin = MAP4_COL_OFFSET
            colMax = MAP4_TOTAL_COLS - 1
            rowMax = MAP4_ROWS - 1
        elseif anchorCol >= MAP3_COL_OFFSET then
            colMin = MAP3_COL_OFFSET
            colMax = MAP3_TOTAL_COLS - 1
            rowMax = MAP3_ROWS - 1
        elseif anchorCol >= MAP2_COL_OFFSET then
            colMin = MAP2_COL_OFFSET
            colMax = MAP2_TOTAL_COLS - 1
            rowMax = MAP2_ROWS - 1
        else
            colMin = 0
            colMax = GRID_COLS - 1
            rowMax = GRID_ROWS - 1
        end
        for dc = 0, footprintW - 1 do
            for dr = 0, footprintD - 1 do
                local c = anchorCol + dc
                local r = anchorRow + dr
                if c < colMin or c > colMax or r < 0 or r > rowMax then return false end
                if gridState[c][r] ~= "open" then return false end
            end
        end
        return true
    end

    local function markCellsOccupied(anchorCol, anchorRow, footprintW, footprintD)
        for dc = 0, footprintW - 1 do
            for dr = 0, footprintD - 1 do
                gridState[anchorCol + dc][anchorRow + dr] = "occupied"
            end
        end
    end

    ------------------------------------------------------------
    -- TOWER PICKED — player chose a tower from the pre-wave picker.
    ------------------------------------------------------------
    -- 2026-04-28 di: extended to handle all three Core archetypes
    -- (Power / ControlCore / SupportCore). Was hardcoded to Power
    -- only — selecting CONTROL or SUPPORT in the picker fired the
    -- TowerPicked remote but the server silently dropped it,
    -- leaving the player with 0 stock and no countdown to first
    -- wave. Per Matthew "picking control doesn't start the game."
    -- DoT/CC stock attributes left as defensive zeroes for any
    -- legacy reader; the actual DoT/CC archetype cards were
    -- removed from the picker (init.client.lua towerDefs) in the
    -- same commit.
    -- 2026-04-29 ea3: replaced inline CORE_TYPES + isCoreType() with
    -- shared CoreTypes.isCore() so future Core archetypes don't need
    -- a parallel update here.
    towerPickedRemote.OnServerEvent:Connect(function(player, towerType)
        if not CoreTypes.isCore(towerType) then return end
        -- Grant stock for the picked Core, zero out the others (so
        -- a re-pick mid-run doesn't leave stale stock from the prior
        -- Core hanging around).
        --
        -- 2026-04-28 dk: also stamp `<id>Equipped` for all 3 Cores —
        -- true for the picked one, false for the others. The hotbar
        -- builder's Equipped-aware path then hides non-picked Cores.
        -- Was: Power's legacy "show on HasBeenGrantedStock" rule
        -- displayed Power's slot even when the player picked Control
        -- or Support (because HasBeenGrantedStock fires regardless).
        -- Per Matthew "when you select control don't show power."
        for _, c in ipairs(CoreTypes.Ids) do
            player:SetAttribute(c .. "Stock", c == towerType and 1 or 0)
            player:SetAttribute(c .. "Equipped", c == towerType)
        end
        -- Legacy DoT/CC stock — defensive zero. No live consumers
        -- after the di cleanup; kept to avoid breaking any reader
        -- that grep missed.
        player:SetAttribute("DoTStock", 0)
        player:SetAttribute("CCStock", 0)
        -- Flag so the failsafe loop doesn't re-prompt after stock hits 0 from placing
        player:SetAttribute("HasBeenGrantedStock", true)
        -- If a permanent tower is equipped from a prior run's Pickle Lord kill,
        -- grant that too so the player enters the TD room with Core AND the
        -- carried-over Aux permanent. Safe no-op if nothing equipped.
        if grantPermanentStock then
            grantPermanentStock(player)
        end
        showHotbarRemote:FireClient(player)
        print(("[TreeOfLife] %s picked %s; stock = 1"):format(player.Name, towerType))

        -- Fire the 5-second pre-wave countdown + leaf intro.
        --
        -- 2026-04-29 ea3-10 multi-player split:
        --   • RunState.autoStartScheduled — global single-fire so wave 1
        --     auto-starts exactly once regardless of how many players
        --     pick. Reuses RunState.firstPickFired's role of "we've
        --     already scheduled wave 1."
        --   • Per-player first-pick UX — each player gets their OWN
        --     5-second countdown banner + falling-leaf intro the FIRST
        --     time THEY pick a Core. Tracked via the player attribute
        --     `HadFirstPickIntro` so a re-pick (e.g. RUN RESET → pick
        --     again) doesn't re-fire. Before this split, only the
        --     server's first-ever picker saw the intro; later joiners
        --     entered wave 1 with no UX prep.
        local hadIntro = player:GetAttribute("HadFirstPickIntro") == true
        if not hadIntro then
            player:SetAttribute("HadFirstPickIntro", true)
            local wsRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.WaveState)
            if wsRemote then
                wsRemote:FireClient(player, {
                    wave = 0, totalWaves = 5, mobsAlive = 0, map = "Crook of the Tree (Morning)", stage = 1,
                    inProgress = false, pendingCountdown = 5,
                })
            end
            -- Falling-leaf intro for map 1. Fires here (rather than at portal
            -- entry) so the message isn't covered by the tower-picker UI.
            -- Slight delay so the picker has fully closed before the leaf appears.
            local leaf = MAP1_LEAF_LINES[math.random(1, #MAP1_LEAF_LINES)]
            task.delay(0.4, function() fireLeafMessage(player, leaf, 7) end)
        end

        -- Schedule wave 1 auto-start exactly once across the whole server,
        -- regardless of which player picks first or how many pick. The
        -- 5-second delay matches the per-player countdown banner above.
        if not RunState.firstPickFired then
            RunState.firstPickFired = true
            task.delay(5, function()
                autoStartBindable:Fire(player)
            end)
        end
    end)

    ------------------------------------------------------------
    -- PLACE TOWER — player confirmed placement at (anchorCol, anchorRow).
    -- 2026-04-29 ea3-36 Phase E-2.5: extracted from a closure-only
    -- OnServerEvent handler into `placeTowerInternal` so the body
    -- can be reused by server-internal callers (StorySuperAuto's
    -- onMapEntered hook). The OnServerEvent shim below just calls
    -- placeTowerInternal — semantics for player-driven placement
    -- are unchanged. Also published on ctx as
    -- `ctx.placeTowerForPlayer` for cross-script use (E-2.5 hook).
    ------------------------------------------------------------
    local function placeTowerInternal(player, towerType, anchorCol, anchorRow)
        if type(anchorCol) ~= "number" or type(anchorRow) ~= "number" then
            print(("[ToL] %s placement REJECTED: bad coords %s %s"):format(player.Name, tostring(anchorCol), tostring(anchorRow)))
            return
        end
        anchorCol = math.floor(anchorCol)
        anchorRow = math.floor(anchorRow)
        local def = TOWER_DEFS[towerType]
        if not def then
            print(("[ToL] %s placement REJECTED: unknown tower type %s"):format(player.Name, tostring(towerType)))
            return
        end
        local stockAttr = towerType .. "Stock"
        local stock = player:GetAttribute(stockAttr) or 0
        if stock <= 0 then
            print(("[ToL] %s placement REJECTED: no stock of %s (has %d)"):format(player.Name, towerType, stock))
            return
        end
        local fw, fd = def.footprint[1], def.footprint[2]
        if not canPlaceAt(anchorCol, anchorRow, fw, fd) then
            print(("[ToL] %s placement REJECTED: cells (%d,%d) %dx%d not all open"):format(player.Name, anchorCol, anchorRow, fw, fd))
            return
        end
        local builder = TOWER_BUILDERS[towerType]
        if not builder then
            print(("[ToL] %s placement REJECTED: no builder for %s"):format(player.Name, towerType))
            return
        end

        local centerCol = anchorCol + (fw - 1) / 2
        local centerRow = anchorRow + (fd - 1) / 2
        -- v4 multi-map: pick the right world-space origin for this
        -- anchor's map. FOUR-way per-col dispatch, HIGHEST RANGE
        -- FIRST. Map 4 (cols 225-314) MUST be checked before Map 3
        -- (cols 135-224) — both branches fire when col >= 135, but
        -- Map 4's offset is higher so the conditional has to test
        -- Map 4 first. Pre-2026-04-26 this branch was missing
        -- entirely, and Map 4 placements landed in Map 3's coord
        -- frame at localCol = (col - 135), putting Power Core at
        -- map3.X + 135 stud — outside Map 3's bounds, on Map 3's
        -- floor Y, invisible from the swamp.
        local centerPos
        if anchorCol >= MAP4_COL_OFFSET then
            local localCol = centerCol - MAP4_COL_OFFSET
            centerPos = Vector3.new(
                MAP4_CENTER.X - MAP4_WIDTH / 2 + (localCol + 0.5) * CELL_SIZE,
                MAP4_CENTER.Y + 1,
                MAP4_CENTER.Z - MAP4_DEPTH / 2 + (centerRow + 0.5) * CELL_SIZE
            )
        elseif anchorCol >= MAP3_COL_OFFSET then
            local localCol = centerCol - MAP3_COL_OFFSET
            centerPos = Vector3.new(
                MAP3_CENTER.X - MAP3_WIDTH / 2 + (localCol + 0.5) * CELL_SIZE,
                MAP3_CENTER.Y + 1,
                MAP3_CENTER.Z - MAP3_DEPTH / 2 + (centerRow + 0.5) * CELL_SIZE
            )
        elseif anchorCol >= MAP2_COL_OFFSET then
            local localCol = centerCol - MAP2_COL_OFFSET
            centerPos = Vector3.new(
                MAP2_CENTER.X - MAP2_WIDTH / 2 + (localCol + 0.5) * CELL_SIZE,
                MAP2_CENTER.Y + 1,
                MAP2_CENTER.Z - MAP2_DEPTH / 2 + (centerRow + 0.5) * CELL_SIZE
            )
        else
            centerPos = Vector3.new(
                rc.X - halfW + (centerCol + 0.5) * CELL_SIZE,
                1,
                rc.Z - halfD + (centerRow + 0.5) * CELL_SIZE
            )
        end

        local tower = builder(centerPos, player)
        -- Visual downscale: towers render at 50% of their authored size. The
        -- grid footprint (def.footprint cells) + collision / click area are
        -- unchanged — this is purely a mobile-readability tweak so a Power
        -- Tower doesn't block half the iPad screen. ScaleTo scales parts +
        -- their positions around the model's pivot, which leaves the base
        -- floating above the floor (pivot is bounding-box center); the
        -- re-seat math below shifts the model down so the new bottom of
        -- the bounding box sits at centerPos.Y again.
        if tower and tower:IsA("Model") then
            local originalPivot = tower:GetPivot()
            tower:ScaleTo(0.5)
            -- Re-seat: walk descendants for the WORLD-AXIS lowest Y
            -- (NOT model:GetBoundingBox() — that returns a CFrame
            -- aligned to the first child for towers without
            -- PrimaryPart, and the rotated cylinder used by Power
            -- Tower's TowerBase made the "bottom" math wrong, leaving
            -- towers buried below the floor and causing wonky click
            -- detection. Surfaced 2026-04-26 playtest screenshot.)
            local minWorldY = BBoxUtil.worldAxisFloorY(tower)
            if minWorldY then
                local deltaY = centerPos.Y - minWorldY
                if math.abs(deltaY) > 0.01 then
                    tower:PivotTo(originalPivot + Vector3.new(0, deltaY, 0))
                end
            end
        end
        -- typeData holds Ammo/MaxShots/defaultTargetMode. Both TowerTypes
        -- entries (Power / future Slow / Assassin) and TempTowers.Templates
        -- use the same field names, so either lookup works here.
        local typeData = TowerTypes[towerType] or TempTowers.Templates[towerType]
        if not typeData then
            print(("[ToL] %s placement REJECTED: no typeData for %s"):format(player.Name, towerType))
            tower:Destroy()
            return
        end
        -- Temp towers (from TempTowers.Templates) use no ammo — once placed they
        -- fire forever. Ammo is a core Power-tower mechanic (refill at piles) but
        -- temp towers are "deploy and forget" rewards.
        local isTempTower = TempTowers.Templates[towerType] ~= nil
        markCellsOccupied(anchorCol, anchorRow, fw, fd)
        -- StatLedger registry — adds (towerType, equippedRarity) pair to
        -- the run's loadout for future Infinite-mode tier-list analysis.
        StatLedger.recordPlacement(towerType,
            tower:GetAttribute("EquippedRarityName"))
        tower:SetAttribute("AnchorCol", anchorCol)
        tower:SetAttribute("AnchorRow", anchorRow)
        tower:SetAttribute("FootprintW", fw)
        tower:SetAttribute("FootprintD", fd)
        tower:SetAttribute("Owner", player.UserId)
        if isTempTower then
            tower:SetAttribute("NoAmmo", true)
        else
            -- Ammo model: MaxAmmo is the pip count on the HUD, MaxShots is the
            -- real shot count (10 shots per pip). A pile pickup = +10 shots = +1 pip.
            -- Both start fully loaded at placement.
            tower:SetAttribute("MaxAmmo",  typeData.maxAmmo)
            tower:SetAttribute("Ammo",     typeData.maxAmmo)
            tower:SetAttribute("MaxShots", typeData.maxShots)
            tower:SetAttribute("Shots",    typeData.maxShots)
        end
        -- 2026-04-28 do: per-tower Infinite-arena target preference.
        -- Map 4 (Pickle Swamp / Infinite) placement reads
        -- `typeData.infiniteTargetMode` if set; story-mode placement
        -- falls back to `defaultTargetMode = "First"` per the
        -- established convention (feedback_default_target_mode
        -- memory). Per Matthew "in infinite, automatically set
        -- blinkberry to target strongest. remember which towers
        -- have aiming preference." Currently only BlinkBerry opts
        -- in (Strongest); other towers can add the field as their
        -- Infinite identity calls for it.
        local targetMode = typeData.defaultTargetMode
        if anchorCol >= MAP4_COL_OFFSET and typeData.infiniteTargetMode then
            targetMode = typeData.infiniteTargetMode
        end
        tower:SetAttribute("TargetMode", targetMode)
        -- Timestamp for lifetime-DPS calc on the client. workspace:GetServerTimeNow()
        -- is synced across server + clients, so the client's (now - PlacementTime)
        -- matches the actual elapsed seconds since placement.
        tower:SetAttribute("PlacementTime", Workspace:GetServerTimeNow())
        -- Y coord of the floor this tower sits on, so the client's selection
        -- visuals (bracket cage floor + range ring) can anchor to the real
        -- floor instead of inferring from GetDescendants bounds (which gets
        -- dragged below floor by attachment VFX / invisible anchors).
        tower:SetAttribute("FloorY", centerPos.Y)

        -- Apply cumulative upgrade bonuses the player has already earned this run
        -- to this freshly-placed tower. Without this step, a Core placed on map 2
        -- would start at 0 bonus even though the player picked 8 damage cards
        -- across map 1 — every new placement would discard their upgrade progress.
        -- UpgradeCards.lua maintains per-player cumulative attributes:
        --   <Category>DamageFlat   (flat additive — Damage)
        --   <Category><Stat>Pct    (additive % — Range, FireRate)
        -- We read the category matching this tower and stamp it onto the tower's
        -- Base/Bonus attributes + live stat.
        do
            local category = isTempTower and "Aux" or "Core"
            -- Damage: flat additive bonus.
            -- 2026-04-28 dr: ControlCore inherits CoreDamageFlat split
            -- 80% Damage / 20% StackDotTickDmg per Matthew "for
            -- controlcore damage upgrade, give 80% to tower and 20%
            -- to the dot tick." Mirrors the UpgradeCards.lua live-
            -- application split so a freshly-placed ControlCore on
            -- Map 2/3 reflects all prior damage picks correctly.
            local flatDamage = player:GetAttribute(category .. "DamageFlat") or 0
            if flatDamage ~= 0 then
                local damageShare, dotShare = flatDamage, 0
                if towerType == "ControlCore" then
                    damageShare = math.floor(flatDamage * 0.8 + 0.5)
                    dotShare = flatDamage - damageShare  -- exact split
                end
                local baseVal = tower:GetAttribute("DamageBase") or tower:GetAttribute("Damage") or 0
                tower:SetAttribute("DamageFlat", damageShare)
                tower:SetAttribute("Damage", baseVal + damageShare)
                if dotShare > 0 then
                    -- Builder set StackDotTickDmg to the template default;
                    -- read that as the base, then layer the inherited flat.
                    local dotBase = tower:GetAttribute("StackDotTickDmg") or 0
                    tower:SetAttribute("StackDotTickDmgBase", dotBase)
                    tower:SetAttribute("StackDotTickDmgFlat", dotShare)
                    tower:SetAttribute("StackDotTickDmg", dotBase + dotShare)
                end
            end
            -- Range / FireRate: additive percentage bonus.
            for _, stat in ipairs({ "Range", "FireRate" }) do
                local pct = player:GetAttribute(category .. stat .. "Pct") or 0
                if pct ~= 0 then
                    local baseVal = tower:GetAttribute(stat .. "Base") or tower:GetAttribute(stat) or 0
                    tower:SetAttribute(stat .. "BonusPct", pct)
                    tower:SetAttribute(stat, baseVal * (1 + pct / 100))
                end
            end
            -- Core-only specials stacked across picks (Aux doesn't get specials).
            if category == "Core" then
                for _, attrName in ipairs({ "AoeRadius", "StunDuration", "Knockback" }) do
                    local stacked = player:GetAttribute("Core" .. attrName)
                    if stacked then
                        tower:SetAttribute(attrName, stacked)
                    end
                end
                -- Knockback + Stun: per-tower proc chance attributes track the
                -- picked-up chance stack. Copy onto the freshly-placed tower
                -- so Effects.lua's applyHitEffects reads the accumulated chance
                -- (not the 5% default). Core cumulative is authoritative —
                -- placement inherits whatever chance the player has stacked up.
                for _, chanceAttr in ipairs({ "StunChance", "KnockbackChance" }) do
                    local c = player:GetAttribute("Core" .. chanceAttr)
                    if c then tower:SetAttribute(chanceAttr, c) end
                end
                local ammoMult = player:GetAttribute("CoreMaxShotsMult") or 1.0
                if ammoMult > 1.0 and tower:GetAttribute("MaxShots") then
                    local cur = tower:GetAttribute("MaxShots")
                    tower:SetAttribute("MaxShots", math.floor(cur * ammoMult + 0.5))
                    tower:SetAttribute("Shots", tower:GetAttribute("MaxShots"))
                end
            end

            -- 2026-04-29 ea3-26: Core-upgrade stacks at placement.
            -- The map-boss Core upgrade picker stamps `<id>Stacks` on
            -- the player; freshly-placed towers inherit those bonuses.
            -- CoreUpgrades.lua's applyUpgradeEffect handles the
            -- RETROACTIVE bump on existing towers when the pick lands;
            -- this block handles NEW placements. (See memory:
            -- project_core_upgrade_picker.md.)
            local powerBaseStacks = player:GetAttribute("PowerBaseDamageStacks") or 0
            if powerBaseStacks > 0 then
                local cur = tower:GetAttribute("Damage") or 0
                tower:SetAttribute("Damage", cur + powerBaseStacks)
            end
            local controlDotStacks = player:GetAttribute("ControlDotTickDamageStacks") or 0
            if controlDotStacks > 0 then
                local cur = tower:GetAttribute("StackDotTickDmg") or 0
                if cur > 0 then
                    tower:SetAttribute("StackDotTickDmg", cur + controlDotStacks)
                end
            end
        end

        -- Apply the player's equipped attachment to this tower (if any). The
        -- equipped slot is loadout-style: one chosen attachment per run, applied
        -- to every tower this player places. PowerCore is applied here at
        -- placement; Detonator and Phoenix are read by the wave system at fire
        -- time so we just tag the tower with the attachment metadata.
        do
            local equipped = AttachmentStore.getEquipped(player)
            local mirroredType = player:GetAttribute("EquippedAttachmentType") or "(nil)"
            if not equipped then
                -- Loud warning: if the player attribute claims something is equipped
                -- but the store says otherwise, the HUD will lie about Phoenix being
                -- ready. This was a bug we hit where the equip remote handler set
                -- the attribute even on rejected (un-owned) equips.
                if mirroredType ~= "" and mirroredType ~= "(nil)" then
                    warn(("[ToL DIAG] %s placed tower with HUD-claimed-equipped=%s but AttachmentStore says nothing equipped — inconsistency"):format(
                        player.Name, mirroredType))
                else
                    print(("[ToL] %s placed tower with no equipped attachment"):format(player.Name))
                end
            end
            if equipped then
                local effect = Attachments.getEffect(equipped)
                tower:SetAttribute("EquippedType", equipped.type)
                tower:SetAttribute("EquippedRarity", equipped.rarity)
                if equipped.type == "PowerCore" and type(effect) == "number" then
                    local newBase = (tower:GetAttribute("DamageBase") or 18) + effect
                    tower:SetAttribute("DamageBase", newBase)
                    local flat = tower:GetAttribute("DamageFlat") or 0
                    tower:SetAttribute("Damage", newBase + flat)
                elseif equipped.type == "Detonator" and type(effect) == "table" then
                    tower:SetAttribute("DetonatorRadius", effect.radius)
                    tower:SetAttribute("DetonatorHpPct", effect.hpPct)
                elseif equipped.type == "Phoenix" and type(effect) == "number" then
                    tower:SetAttribute("PhoenixCooldown", effect)
                    -- Carryover from the prior map's Core tower (see the
                    -- boss-defeat cutscene in systems/TempTowerRewards.lua).
                    -- If present, resume the cooldown state so the Phoenix
                    -- reads as "the same tower in a new spot" rather than
                    -- a fresh instance with a free charge.
                    local carryCd    = player:GetAttribute("PhoenixCarryCdRemaining")
                    local carryGrace = player:GetAttribute("PhoenixCarryGraceRemaining")
                    local carryReady = player:GetAttribute("PhoenixCarryReady")
                    if carryCd ~= nil or carryGrace ~= nil or carryReady ~= nil then
                        tower:SetAttribute("PhoenixReady",            carryReady == true)
                        tower:SetAttribute("PhoenixCdRemaining",      carryCd    or 0)
                        tower:SetAttribute("PhoenixGraceRemaining",   carryGrace or 0)
                        player:SetAttribute("PhoenixCarryCdRemaining",    nil)
                        player:SetAttribute("PhoenixCarryGraceRemaining", nil)
                        player:SetAttribute("PhoenixCarryReady",          nil)
                        print(("[Phoenix DIAG] carryover: cdRem=%.1f ready=%s"):format(
                            carryCd or 0, tostring(carryReady == true)))
                    else
                        tower:SetAttribute("PhoenixReady", true)
                        tower:SetAttribute("PhoenixCdRemaining", 0)
                        tower:SetAttribute("PhoenixGraceRemaining", 0)
                    end
                    print(("[Phoenix DIAG] tower attached: cooldown=%ds (rarity %s)"):format(
                        effect, tostring(equipped.rarity)))
                end
                -- (silenced equipped-tower placement trace; was per-tower spam during AUTO RUN.)
            end
        end

        player:SetAttribute(stockAttr, stock - 1)
        broadcastGrid()

        -- Dev: first Core placement after a dev map-2 teleport → run the full
        -- map-1 upgrade simulation (12 picks) against this tower. Fires a
        -- BindableEvent that the wave system listens for (cross-script call
        -- into ctx.simulateOnePick). Flag is cleared on the consumer side
        -- so a second Core placement doesn't re-simulate.
        if not isTempTower and player:GetAttribute("DevSimulateMap1OnNextCore") then
            -- Attribute now holds the pickCount directly (used to be a bool).
            -- Map 2 dev port stores 12 (one map's worth of picks); map 3
            -- stores 24 (two maps, since map 3 = one map further than map 2).
            local raw = player:GetAttribute("DevSimulateMap1OnNextCore")
            local pickCount = (type(raw) == "number" and raw) or 12
            local simBindable = Remotes.getOrCreate(Remotes.Names.DevSimulateMap1Picks, "BindableEvent")
            simBindable:Fire({ player = player, pickCount = pickCount })
        end

        -- (silenced per-placement trace — fired ~7 times per loadout × 81 = 567 lines per sweep.)
    end

    -- Player-driven path: the existing PlaceTower remote shim. Identical
    -- (player, towerType, anchorCol, anchorRow) signature to the internal
    -- function, so the OnServerEvent handler can pass-through directly.
    placeTowerRemote.OnServerEvent:Connect(placeTowerInternal)

    -- Server-internal path: cross-script callers (StorySuperAuto's
    -- onMapEntered hook) use this to programmatically place towers
    -- during a sweep. Same validation as the remote path — caller
    -- still has to grant stock + ensure the cell is open + supply a
    -- real Player instance.
    ctx.placeTowerForPlayer = placeTowerInternal

    ------------------------------------------------------------
    -- SELL TOWER — client fires SellTower with { tower }. Validates ownership,
    -- costs 1-3 reroll tokens (aux=1, core=3), refunds +1 stock of the
    -- tower's type, frees the grid cells it occupied, and destroys the tower.
    -- The refund path is the inverse of placement: same AnchorCol/Row/Footprint
    -- attributes, same markCells loop with "open" instead of "occupied".
    -- Upgrade stacks stored on the player (Core/AuxDamageFlat, RangePct,
    -- etc.) stay — the sell is a reposition tool, not a progression-reset.
    -- The next tower of that type placed inherits the accumulated upgrades
    -- at placement time.
    ------------------------------------------------------------
    sellTowerRemote.OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= "table" then return end
        local tower = payload.tower
        if typeof(tower) ~= "Instance" or not tower:IsA("Model") or not tower.Parent then
            return
        end
        if tower:GetAttribute("Owner") ~= player.UserId then
            print(("[ToL] PickUp REJECTED: %s doesn't own %s"):format(player.Name, tower.Name))
            return
        end

        -- Pick-up cost varies by tower category: Core = 3 reroll tokens, Aux = 1.
        -- Core is the more expensive retry because the player has invested
        -- upgrades into it (stamped at placement) and the pick-up lets them
        -- reposition without losing that progress.
        local isTemp = TempTowers.Templates[tower:GetAttribute("TowerType") or ""] ~= nil
        local cost = isTemp and 1 or 3
        local tokens = player:GetAttribute("RerollTokens") or 0
        if tokens < cost then
            print(("[ToL] PickUp REJECTED: %s has %d / %d reroll tokens"):format(
                player.Name, tokens, cost))
            return
        end

        local anchorCol  = tower:GetAttribute("AnchorCol")
        local anchorRow  = tower:GetAttribute("AnchorRow")
        local footprintW = tower:GetAttribute("FootprintW")
        local footprintD = tower:GetAttribute("FootprintD")
        local towerType  = tower:GetAttribute("TowerType")
        if not (anchorCol and anchorRow and footprintW and footprintD and towerType) then
            print(("[ToL] PickUp REJECTED: %s missing placement attrs"):format(tower.Name))
            return
        end

        player:SetAttribute("RerollTokens", tokens - cost)
        local stockAttr = towerType .. "Stock"
        local curStock = player:GetAttribute(stockAttr) or 0
        player:SetAttribute(stockAttr, curStock + 1)

        -- Free the cells this tower held. Use "open" (not path/heart/decor) so
        -- other towers can place here again.
        for dc = 0, footprintW - 1 do
            for dr = 0, footprintD - 1 do
                local c = anchorCol + dc
                local r = anchorRow + dr
                if gridState[c] and gridState[c][r] == "occupied" then
                    gridState[c][r] = "open"
                end
            end
        end

        tower:Destroy()
        broadcastGrid()
        showHotbarRemote:FireClient(player)  -- refresh hotbar so new stock count shows
        print(("[ToL] %s picked up %s (+1 %sStock, -%d RerollTokens)"):format(
            player.Name, towerType, towerType, cost))
    end)
end

return TowerPlacement
