--!strict
--[[
    PermanentTowerStore — persistent per-player collection of permanent towers.

    WHAT IS A PERMANENT TOWER:
    Earned by defeating the run boss (Pickle Lord). The player accumulates a
    collection across runs and picks ONE to equip each run via the pedestal
    (rises after each map boss). An equipped permanent tower behaves like
    the Core tower for purposes of per-map stock grants — the player gets
    1× stock at run start and 1× more on each map entry (matching the Core).

    SCHEMA (DataStore "TreeOfLife_PermanentTowers_v1"):
        {
            version = 1,
            owned = {
                ["FrostMelon"] = { type = "FrostMelon", rarity = "Legendary" },
                ["MushroomMortar"] = { type = "MushroomMortar", rarity = "Rare" },
            },
            equipped = "FrostMelon",  -- string towerId, or nil
            prefs = {
                hasSeenIntro = true,    -- player has closed the welcome modal once; never shown again
            },
        }

    DUPLICATE POLICY:
    Same as AttachmentStore: trying to award a tower you already own at
    equal-or-higher rarity is a no-op (returns "duplicate"). Higher rarity
    replaces lower (returns "upgraded"). Never-seen type returns "new".

    PUBLIC API:
        Store.load(player)                → data table (auto-created if new)
        Store.save(player)                → bool
        Store.getOwned(player)            → { [type] = entry, ... }
        Store.getEquipped(player)         → entry or nil
        Store.setEquipped(player, type?)  → bool (type may be nil to unequip)
        Store.tryAward(player, type, rarity) → { result, entry }

    Intentionally mirrors the AttachmentStore API so the client-side patterns
    (inventory panels, reveal modals) can be adapted with minimal reshuffling.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players          = game:GetService("Players")

local Store = {}

local STORE_NAME = "TreeOfLife_PermanentTowers_v1"
local store = DataStoreService:GetDataStore(STORE_NAME)

local cache = {}   -- [userId] = data table (loaded lazily)
local dirty = {}   -- [userId] = true when cache has unsaved changes

local DEFAULT_DATA = {
    version = 1,
    owned = {},
    equipped = nil,
    prefs = {},  -- per-player UX flags (e.g. hasSeenIntro)
}

local MAX_RETRIES = 4

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end

local function pcallRetry(fn, ...)
    local attempt = 0
    local lastErr
    while attempt < MAX_RETRIES do
        attempt = attempt + 1
        local ok, result = pcall(fn, ...)
        if ok then return true, result end
        lastErr = result
        task.wait(0.5 * attempt)
    end
    return false, lastErr
end

-- Rarity ranking helper (higher = better). Uses the same order as TempTowers
-- so duplicate-award logic stays consistent with the picker flow.
local RARITY_RANK = {
    Common = 1, Rare = 2, Exceptional = 3, Legendary = 4, Mythical = 5,
}

function Store.load(player)
    local userId = player.UserId
    if cache[userId] then return cache[userId] end

    local key = "user_" .. tostring(userId)
    local ok, data = pcallRetry(function() return store:GetAsync(key) end)
    if not ok then
        warn(("[PermanentTowerStore] load failed for %s (%d): %s — using empty data")
            :format(player.Name, userId, tostring(data)))
        cache[userId] = deepCopy(DEFAULT_DATA)
        return cache[userId]
    end
    if type(data) ~= "table" then
        cache[userId] = deepCopy(DEFAULT_DATA)
        return cache[userId]
    end
    -- Ensure required fields exist on older/partial records.
    data.version  = data.version or 1
    data.owned    = data.owned or {}
    data.prefs    = data.prefs or {}
    cache[userId] = data
    return data
end

function Store.getPref(player, key)
    local data = Store.load(player)
    return data.prefs[key]
end

function Store.setPref(player, key, value)
    local data = Store.load(player)
    data.prefs[key] = value
    dirty[player.UserId] = true
    Store.save(player)
end

function Store.save(player)
    local userId = player.UserId
    local data = cache[userId]
    if not data then return false end
    if not dirty[userId] then return true end
    local key = "user_" .. tostring(userId)
    local ok, err = pcallRetry(function() return store:SetAsync(key, data) end)
    if not ok then
        warn(("[PermanentTowerStore] save failed for %s (%d): %s")
            :format(player.Name, userId, tostring(err)))
        return false
    end
    dirty[userId] = nil
    return true
end

function Store.getOwned(player)
    return Store.load(player).owned or {}
end

function Store.getEquipped(player)
    local data = Store.load(player)
    local eqType = data.equipped
    if not eqType then return nil end
    return data.owned and data.owned[eqType] or nil
end

function Store.setEquipped(player, towerType)
    local data = Store.load(player)
    if towerType == nil then
        data.equipped = nil
    elseif data.owned[towerType] then
        data.equipped = towerType
    else
        return false
    end
    dirty[player.UserId] = true
    Store.save(player)
    return true
end

-- Award a tower to the player's collection. Returns { result, entry } where
-- result is "new" (first time seeing this type), "upgraded" (higher rarity
-- replaces existing), or "duplicate" (same/lower rarity, no change).
function Store.tryAward(player, towerType, rarity)
    local data = Store.load(player)
    local existing = data.owned[towerType]
    local newRank = RARITY_RANK[rarity] or 0

    if not existing then
        data.owned[towerType] = { type = towerType, rarity = rarity }
        dirty[player.UserId] = true
        Store.save(player)
        return { result = "new", entry = data.owned[towerType] }
    end

    local curRank = RARITY_RANK[existing.rarity] or 0
    if newRank > curRank then
        data.owned[towerType] = { type = towerType, rarity = rarity }
        dirty[player.UserId] = true
        Store.save(player)
        return { result = "upgraded", entry = data.owned[towerType], oldRarity = existing.rarity }
    end

    return { result = "duplicate", entry = existing }
end

-- Autosave on leave so nothing is lost if we never explicitly flushed after
-- an award.
Players.PlayerRemoving:Connect(function(player)
    if dirty[player.UserId] then
        Store.save(player)
    end
    cache[player.UserId] = nil
    dirty[player.UserId] = nil
end)

return Store
