--!strict
--[[
    TreeOfLife_AttachmentStore (v2) — persistent per-player attachment system.

    Schema changes from v1:
        - DataStore name bumped to _v2 (effectively wipes v1 PowerCore stacks)
        - Player owns at most ONE attachment per type
        - Each attachment has a rarity (1-5: Common, Rare, Exceptional, Legendary, Mythical)
        - Single "equipped" type at a time (loadout style)
        - Award flow: rolled randomly on Final Boss kill; duplicates of same/lower
          rarity are discarded; higher rarity replaces (upgrade)

    Data shape:
        {
            version = 2,
            owned = {
                ["PowerCore"] = {type="PowerCore", rarity=2},
                ["Detonator"] = {type="Detonator", rarity=4},
            },
            equipped = "PowerCore",  -- type currently equipped, or nil
        }

    Public API:
        Store.load(player) -> data table (auto-create if new)
        Store.save(player) -> bool
        Store.getOwned(player) -> {[type] = entry, ...}
        Store.getEquipped(player) -> entry or nil
        Store.setEquipped(player, type|nil) -> bool
        Store.tryAward(player, type, rarity) -> {result="new"|"upgraded"|"duplicate", entry=...}
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Store = {}

local STORE_NAME = "TreeOfLife_Attachments_v2"
local store = DataStoreService:GetDataStore(STORE_NAME)

local cache = {}
local dirty = {}

local DEFAULT_DATA = {
    version = 2,
    owned = {},
    equipped = nil,
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

function Store.load(player)
    local userId = player.UserId
    if cache[userId] then return cache[userId] end

    local key = "user_" .. tostring(userId)
    local ok, data = pcallRetry(function() return store:GetAsync(key) end)
    if not ok then
        warn(("[AttachmentStore] load failed for %s (%d): %s — using empty data")
            :format(player.Name, userId, tostring(data)))
        cache[userId] = deepCopy(DEFAULT_DATA)
    elseif data == nil then
        cache[userId] = deepCopy(DEFAULT_DATA)
    else
        if type(data) ~= "table" then data = deepCopy(DEFAULT_DATA) end
        data.version = data.version or 2
        data.owned = data.owned or {}
        cache[userId] = data
    end
    dirty[userId] = false
    return cache[userId]
end

function Store.save(player)
    local userId = player.UserId
    local data = cache[userId]
    if not data then return false end
    if not dirty[userId] then return true end

    local key = "user_" .. tostring(userId)
    local ok, err = pcallRetry(function() store:SetAsync(key, data) end)
    if ok then
        dirty[userId] = false
        return true
    else
        warn(("[AttachmentStore] save failed for %s (%d): %s")
            :format(player.Name, userId, tostring(err)))
        return false
    end
end

function Store.getOwned(player)
    local data = Store.load(player)
    return data.owned
end

function Store.getEquipped(player)
    local data = Store.load(player)
    if not data.equipped then return nil end
    return data.owned[data.equipped]
end

function Store.setEquipped(player, attType)
    local data = Store.load(player)
    if attType ~= nil and not data.owned[attType] then
        return false  -- can't equip what you don't own
    end
    data.equipped = attType
    dirty[player.UserId] = true
    return true
end

-- Returns one of:
--   { result = "new",       entry = {...} }
--   { result = "upgraded",  entry = {...}, oldRarity = N }
--   { result = "duplicate", entry = {...} }
-- DEV only: wipe this player's attachments back to default (no owned,
-- nothing equipped). Called by Ground Zero reset.
function Store.wipe(player)
    cache[player.UserId] = deepCopy(DEFAULT_DATA)
    dirty[player.UserId] = true
    Store.save(player)
end

function Store.tryAward(player, attType, rarity)
    local data = Store.load(player)
    local existing = data.owned[attType]
    if not existing then
        local entry = {type = attType, rarity = rarity}
        data.owned[attType] = entry
        if not data.equipped then
            data.equipped = attType
        end
        dirty[player.UserId] = true
        return {result = "new", entry = entry}
    elseif rarity > existing.rarity then
        local oldRarity = existing.rarity
        existing.rarity = rarity
        dirty[player.UserId] = true
        return {result = "upgraded", entry = existing, oldRarity = oldRarity}
    else
        return {result = "duplicate", entry = existing}
    end
end

Players.PlayerRemoving:Connect(function(player)
    Store.save(player)
    cache[player.UserId] = nil
    dirty[player.UserId] = nil
end)

game:BindToClose(function()
    for _, player in ipairs(Players:GetPlayers()) do
        Store.save(player)
    end
end)

print("[AttachmentStore] v2 module loaded. DataStore: " .. STORE_NAME)
return Store
