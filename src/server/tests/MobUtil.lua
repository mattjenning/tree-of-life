--[[
    MobUtil.lua tests — verifies the heart-damage helper shared between the
    wave-system mob loop (MobUpdate) and the bird-boss egg walker
    (Map3BirdBoss). Both paths must agree on the canonical math:
    heart.Health = max(0, currentHp - amount).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests   = require(script.Parent)
local MobUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobUtil"))

local function makeFakeHeart(initialHp)
    local p = Instance.new("Part")
    p:SetAttribute("MaxHealth", initialHp)
    p:SetAttribute("Health", initialHp)
    return p
end

Tests.test("MobUtil.damageHeart: subtracts amount and returns new HP", function()
    local heart = makeFakeHeart(1000)
    local newHp = MobUtil.damageHeart(heart, 250)
    Tests.assertEq(newHp, 750)
    Tests.assertEq(heart:GetAttribute("Health"), 750)
    heart:Destroy()
end)

Tests.test("MobUtil.damageHeart: clamps at 0 (no negative HP)", function()
    local heart = makeFakeHeart(100)
    local newHp = MobUtil.damageHeart(heart, 999)
    Tests.assertEq(newHp, 0, "damage > current must clamp at 0")
    Tests.assertEq(heart:GetAttribute("Health"), 0)
    heart:Destroy()
end)

Tests.test("MobUtil.damageHeart: returns 0 and no-ops when heart is nil", function()
    local r = MobUtil.damageHeart(nil, 50)
    Tests.assertEq(r, 0)
end)

Tests.test("MobUtil.damageHeart: returns 0 when Health attribute missing", function()
    local p = Instance.new("Part")
    -- No Health attribute set.
    local r = MobUtil.damageHeart(p, 50)
    Tests.assertEq(r, 0)
    p:Destroy()
end)

Tests.test("MobUtil.damageHeart: chained damage matches plain subtraction", function()
    -- The wave-system path damages the heart via MobUtil; the egg path
    -- damages via MobUtil. Two consecutive calls should land the heart
    -- at the same HP a single (sum) call would.
    local h1 = makeFakeHeart(1000)
    MobUtil.damageHeart(h1, 200)
    MobUtil.damageHeart(h1, 350)
    local h2 = makeFakeHeart(1000)
    MobUtil.damageHeart(h2, 550)
    Tests.assertEq(h1:GetAttribute("Health"), h2:GetAttribute("Health"))
    h1:Destroy(); h2:Destroy()
end)

return nil
