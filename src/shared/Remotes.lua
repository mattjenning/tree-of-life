--!strict
--[[
    Remotes.lua — Single source of truth for every RemoteEvent and
    BindableEvent name in the project.

    WHY THIS MODULE EXISTS:
    Before this module, Remote names were string literals scattered across
    the hub, wave system, and client. A typo like "DevSkipWaveExtra" in ONE
    place would silently break the feature — no error, just nothing happens.
    By centralizing the names, we get:
      - Autocomplete in VS Code (Remotes.DevSkipWave works; Remotes.DevSkipWav errors)
      - One file to grep when adding or renaming a Remote
      - Type-safety via `--!strict` — calling Remotes.Typo would fail at parse

    USAGE:
        local Remotes = require(ReplicatedStorage.Shared.Remotes)
        local skipRemote = Remotes.get(Remotes.Names.DevSkipWave)

    OR (for listeners that want the actual instance auto-created):
        local skipRemote = Remotes.getOrCreate(Remotes.Names.DevSkipWave, "RemoteEvent")

    CONVENTIONS:
      - `Remotes.Names` is a frozen table of string constants.
      - Names use PascalCase matching the Instance.Name attribute in workspace.
      - `event` = fire-and-forget (RemoteEvent / BindableEvent)
      - `request` = request/response — we don't currently use RemoteFunction,
        but when we do, we'll add a `Remotes.Requests` table alongside.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

-- ===========================================================================
-- NAMES — every Remote/Bindable name the project uses, in one place.
-- Organized by category for readability.
-- ===========================================================================

Remotes.Names = table.freeze({
    -- ── WAVE & STAGE FLOW ──
    WaveState         = "WaveState",         -- Server → all clients: broadcast wave progress HUD
    WaveStart         = "WaveStart",         -- Server → all clients: wave just started (for sound/FX)
    WaveAutoStart     = "WaveAutoStart",     -- Server → all clients: countdown to next wave
    StageAdvanced     = "StageAdvanced",     -- Bindable (server-side): stage 1→2 geometry triggers
    StageCleared      = "StageCleared",      -- Server → clients: stage complete modal
    StageContinue     = "StageContinue",     -- Client → server: player clicked Continue on stage modal
    StageReskin       = "StageReskin",       -- Server → clients: client-side stage visual changes
    SwitchMap         = "SwitchMap",         -- Bindable (hub ↔ waves): change active map
    RunReset          = "RunReset",          -- Bindable: full run reset (fired by DevReset handler)
    GameOver          = "GameOver",          -- Server → all clients: win or lose modal
    BossDefeated      = "BossDefeated",      -- Bindable: final boss killed, grant rewards

    -- ── BOSS FIGHT (Phase UI + mechanics) ──
    BossPhase         = "BossPhase",         -- Server → clients: boss phase transition
    BossPhaseMiss     = "BossPhaseMiss",     -- Server → clients: player missed a phase challenge
    BossTargetTap     = "BossTargetTap",     -- Client → server: player tapped a boss target
    BossWeb           = "BossWeb",           -- Server → clients: web overlay appear
    BossWindup        = "BossWindup",        -- Server → clients: boss attack windup warning

    -- ── UPGRADES & REWARDS ──
    ShowUpgrades      = "ShowUpgrades",      -- Server → client: display upgrade picker
    UpgradePicked     = "UpgradePicked",     -- Client → server: "I chose card N"
    RerollUpgrades    = "RerollUpgrades",    -- Client → server: reroll request
    GiveFreeReward    = "GiveFreeReward",    -- Bindable: unpromptable free gift
    LeafMessage       = "LeafMessage",       -- Server → client: leaf-themed flavor notification

    -- ── TEMP TOWER REWARDS (map boss picker) ──
    -- Map bosses drop 1-of-3 temp towers. Cards can be duds (already-owned
    -- at equal-or-higher rarity) which auto-convert to reroll tokens on the
    -- client; the server grants the token at the same time it fires the remote.
    ShowTempTowerReward = "ShowTempTowerReward", -- Server → client: show the 3-card temp tower picker
    TempTowerPicked     = "TempTowerPicked",     -- Client → server: player chose card N
    -- Bindable fired by TempTowerRewards AFTER a player has claimed their pick,
    -- carrying { mapId = 1|2|3 }. Per-map world modules (Map2.lua, future
    -- map 3) listen for this to run follow-up cinematics (rope ladder drop,
    -- "path above opens" leaf message) — gating them on the pick keeps those
    -- beats from happening behind the picker modal.
    BossRewardClaimed   = "BossRewardClaimed",
    -- Client-facing signal: map 1 boss-reward-claimed plays a short cutscene
    -- where the player's character walks to their Core tower, kneels, and
    -- "works on it" before the tower vanishes (carried to the next map)
    -- and the rope ladder drops. Payload = { corePosition }.
    PlayBossCutscene    = "PlayBossCutscene",
    BossCutsceneDone    = "BossCutsceneDone",    -- Client → server: cutscene arrived at tower + paused; ok to destroy + transition
    -- Client → server: player clicked the bullseye on the tower HUD and
    -- then clicked a mob, manually targeting it. Payload = { tower, mob }
    -- or { tower, mob = nil } to clear the manual override.
    SetTowerManualTarget = "SetTowerManualTarget",

    -- ── PERMANENT TOWER EQUIP (pedestal flow) ──
    -- Pedestal (Map2.lua) rises after a map boss defeat. Its ProximityPrompt
    -- fires server-side, which calls ctx.openPermanentEquip directly — so no
    -- client→server remote is needed for opening. Server then fires
    -- ShowPermanentEquip with the player's collection. Player picks →
    -- PermanentTowerEquipped → server applies attrs + saves to DataStore.
    ShowPermanentEquip      = "ShowPermanentEquip",      -- Server → client: render equip modal with collection
    PermanentTowerEquipped  = "PermanentTowerEquipped",  -- Client → server: player picked a collection entry

    -- ── PICKLE LORD (run-boss reward path) ──
    -- Pickle Lord is the separate final/run boss that lands after all 3 map
    -- bosses have been defeated. Defeating him drops a PERMANENT tower that
    -- persists in the player's DataStore collection across runs.
    PickleLordDefeated        = "PickleLordDefeated",        -- Bindable: server fires when Pickle Lord mob dies (or dev button)
    ShowPermanentTowerReward  = "ShowPermanentTowerReward",  -- Server → client: 3-card permanent picker
    PermanentTowerPicked      = "PermanentTowerPicked",      -- Client → server: player chose card N
    DevKillPickleLord         = "DevKillPickleLord",         -- Client → server: dev panel shortcut to fire the reward flow directly

    -- ── CANOPY SPIDER (map 3 boss web mechanic) ──
    -- Spider pauses every 15s to spawn web projectiles tagged SpiderWeb.
    -- Each web has a WebId attribute. Clients see the tagged parts, attach
    -- a tap-target BillboardGui, and fire TapSpiderWeb with the id when
    -- clicked. Server destroys the web (and cancels the pending tower-web
    -- effect). Missed webs → tower gets WebbedUntil attribute for 3s.
    TapSpiderWeb              = "TapSpiderWeb",              -- Client → server: player tapped a web projectile
    DevSpawnCanopySpider      = "DevSpawnCanopySpider",      -- Client → server: dev panel shortcut to spawn the map 2 boss

    -- ── CANOPY BIRD (map 3 boss — dive mechanic) ──
    -- Bird ascends every 12s + hovers over a random tower, placing a
    -- clickable dive-target. Tap = dive canceled + bonus damage to
    -- bird. Miss = dive lands + target tower loses 10 MaxShots
    -- ("peck" damage — distinct from the spider's stun).
    TapBirdDive               = "TapBirdDive",               -- Client → server: player tapped a dive-target
    DevSpawnCanopyBird        = "DevSpawnCanopyBird",        -- Client → server: dev panel shortcut to spawn the map 3 boss

    -- ── PLAYER FLOW ──
    EnterPortal       = "EnterPortal",       -- Client → server: player stepped into portal
    ShowSplash        = "ShowSplash",        -- Server → client: splash screen on first entry
    ShowIntro         = "ShowIntro",         -- Server → client: tutorial modal (first entry only)
    ShowTowerSelect   = "ShowTowerSelect",   -- Server → client: "pick your starting tower"
    TowerPicked       = "TowerPicked",       -- Client → server: starting tower choice
    ShowHotbar        = "ShowHotbar",        -- Server → client: display the tower-stock hotbar
    PlaceTower        = "PlaceTower",        -- Client → server: attempt tower placement
    SetTowerTargetMode = "SetTowerTargetMode", -- Client → server: change tower's targeting priority

    -- ── AMMO PICKUP ──
    PickupHoldStart   = "PickupHoldStart",   -- Client → server: E pressed near pile
    PickupHoldStop    = "PickupHoldStop",    -- Client → server: E released

    -- ── GAME SPEED ──
    SetGameSpeed      = "SetGameSpeed",      -- Client → server: set game speed multiplier (1/2/3)
    GameSpeedChanged  = "GameSpeedChanged",  -- Server → clients: broadcast current game speed

    -- ── GRID ──
    GridConfig        = "GridConfig",        -- Server → client: grid dimensions and origin
    GridUpdate        = "GridUpdate",        -- Server → client: per-cell state changes

    -- ── ATTACHMENTS ──
    GetAttachments      = "GetAttachments",      -- Client → server: retrieve owned attachments
    AttachmentsChanged  = "AttachmentsChanged",  -- Server → client: inventory mutated
    AttachmentRevealed  = "AttachmentRevealed",  -- Server → client: new attachment earned (animated reveal)
    EquipAttachment     = "EquipAttachment",     -- Client → server: set active attachment on tower

    -- ── DEV PANEL ──
    DevReset          = "DevReset",          -- Client → server: full reset
    DevSkipWave       = "DevSkipWave",       -- Client → server: skip current wave
    DevSkipToBoss     = "DevSkipToBoss",     -- Client → server: jump to current-stage boss + auto-kill
    DevSkipToMapBoss  = "DevSkipToMapBoss",  -- Client → server: jump to MAP boss (stage 3) + auto-kill (triggers temp-tower picker)
    DevTeleport       = "DevTeleport",       -- Client → server: teleport to hub/map1/map2
    DevAddStun        = "DevAddStun",        -- Client → server: add stun stack to all towers
    DevResetCooldowns = "DevResetCooldowns", -- Client → server: reset all Phoenix cooldowns
    DevUnlimitedAmmo  = "DevUnlimitedAmmo",  -- Client → server: toggle unlimited ammo
    DevSimulateMap1Picks = "DevSimulateMap1Picks", -- Server BindableEvent: Hub fires when a player places their first Core after a dev map-2 teleport; WaveSystem listens and simulates 12 picks (full map-1 upgrade path)
    DevMoveToMapStart    = "DevMoveToMapStart",    -- Client → server: respawn the player at their current map's spawn CFrame without touching towers/grid/wave state (map-2+ RESET behavior)
    SellTower            = "SellTower",            -- Client → server: sell a tower for 1 reroll token, refund +1 stock of its type
})

-- ===========================================================================
-- LOOKUP HELPERS
-- ===========================================================================

--- Get a Remote/Bindable instance by name. Returns nil if not found.
--- Prefer this when you want to check existence before binding.
function Remotes.get(name: string): Instance?
    return ReplicatedStorage:FindFirstChild(name)
end

--- Get a Remote/Bindable, creating it if it doesn't exist.
--- `kind` must be "RemoteEvent" or "BindableEvent" (or other Instance class).
--- Used by server scripts that want to publish an event Instance they own.
function Remotes.getOrCreate(name: string, kind: string): Instance
    local existing = ReplicatedStorage:FindFirstChild(name)
    if existing then
        return existing
    end
    local inst = Instance.new(kind)
    inst.Name = name
    inst.Parent = ReplicatedStorage
    return inst
end

--- Wait for a Remote/Bindable to exist. Used by client scripts that
--- run before the server has finished publishing Remotes.
function Remotes.waitFor(name: string, timeoutSeconds: number?): Instance?
    return ReplicatedStorage:WaitForChild(name, timeoutSeconds or 30)
end

return table.freeze(Remotes)
