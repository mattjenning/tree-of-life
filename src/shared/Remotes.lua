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

    -- ── PLAYER FLOW ──
    EnterPortal       = "EnterPortal",       -- Client → server: player stepped into portal
    ShowSplash        = "ShowSplash",        -- Server → client: splash screen on first entry
    ShowTowerSelect   = "ShowTowerSelect",   -- Server → client: "pick your starting tower"
    TowerPicked       = "TowerPicked",       -- Client → server: starting tower choice
    ShowHotbar        = "ShowHotbar",        -- Server → client: display the tower-stock hotbar
    PlaceTower        = "PlaceTower",        -- Client → server: attempt tower placement
    SetTowerTargetMode = "SetTowerTargetMode", -- Client → server: change tower's targeting priority

    -- ── AMMO PICKUP ──
    PickupHoldStart   = "PickupHoldStart",   -- Client → server: E pressed near pile
    PickupHoldStop    = "PickupHoldStop",    -- Client → server: E released

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
    DevSkipToBoss     = "DevSkipToBoss",     -- Client → server: jump to final boss
    DevTeleport       = "DevTeleport",       -- Client → server: teleport to hub/map1/map2
    DevAddStun        = "DevAddStun",        -- Client → server: add stun stack to all towers
    DevResetCooldowns = "DevResetCooldowns", -- Client → server: reset all Phoenix cooldowns
    DevUnlimitedAmmo  = "DevUnlimitedAmmo",  -- Client → server: toggle unlimited ammo
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
