--!strict
--[[
    Rarity.lua — Shared rarity palette + tier metadata. Single source of
    truth for the colors the game uses to communicate rarity across the
    upgrade picker, attachment cards, temp-tower reward modal, tower info
    popup, and Phoenix cooldown fill.

    WHY THIS MODULE EXISTS:
    The palette was duplicated in 4 files before this module existed:
    systems/UpgradeCards.lua (server), server/Attachments.lua,
    client/AttachmentsModal.lua, client/init.client.lua. A color tweak
    to one instance would silently desync with the others — and playtest
    noted at least one (Phoenix cooldown fill used a hardcoded Exceptional
    purple). Centralizing makes every rarity visual drive off one table.

    USAGE:
        local Rarity = require(ReplicatedStorage.Shared.Rarity)
        local color = Rarity.Colors[2]          -- rare blue
        local name  = Rarity.Names[rarityIdx]   -- "Rare"
        local c     = Rarity.ColorFor("Legendary")

    NAMING CONVENTION:
      - Indexes 1..5 match the attachment / upgrade-card rarity ordering
        (Common → Rare → Exceptional → Legendary → Mythical).
      - "Special" is index 6, used only by upgrade cards (targets specials
        like AOE / Stun / Knockback, not stat %). Attachments don't have
        a Special tier; indexes 1..5 suffice for them.
]]

local Rarity = {}

Rarity.Names = table.freeze({
    [1] = "Common",
    [2] = "Rare",
    [3] = "Exceptional",
    [4] = "Legendary",
    [5] = "Mythical",
    [6] = "Special",  -- upgrade-card tier, not a droppable rarity
})

Rarity.Colors = table.freeze({
    [1] = Color3.fromRGB(200, 200, 200),  -- Common — neutral gray
    [2] = Color3.fromRGB( 80, 150, 255),  -- Rare — cobalt blue
    [3] = Color3.fromRGB(180,  80, 220),  -- Exceptional — violet
    [4] = Color3.fromRGB(255, 170,  40),  -- Legendary — amber
    [5] = Color3.fromRGB(255,  60, 140),  -- Mythical — magenta
    [6] = Color3.fromRGB( 60, 220, 200),  -- Special — teal (upgrade cards only)
})

-- Name → index lookup, built eagerly for O(1) access.
Rarity.IndexByName = (function()
    local t = {}
    for i, n in ipairs(Rarity.Names) do t[n] = i end
    return table.freeze(t)
end)()

-- Helper: resolve a rarity NAME to its Color3. Returns Common gray if
-- the name is unknown so callers don't need to nil-check.
function Rarity.ColorFor(name: string): Color3
    local idx = Rarity.IndexByName[name]
    return Rarity.Colors[idx or 1]
end

table.freeze(Rarity)
return Rarity
