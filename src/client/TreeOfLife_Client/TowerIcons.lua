--[[
    TowerIcons.lua — The 12 small UI Frame compositions that render each
    tower type's icon inside a hotbar slot, tower-picker card, or
    tower-info popup. Pure Roblox-UI Instance plumbing; no coupling to
    gameplay state.

    WHY THIS MODULE EXISTS:
    These builders totaled ~465 lines of iconographic Frame geometry in
    the middle of init.client.lua. Moving them out keeps the main client
    chunk focused on wiring + remote handlers, and lets anyone tweaking
    an icon's silhouette edit this file without scrolling past HUD and
    placement code.

    USAGE:
        local TowerIcons = require(script:WaitForChild("TowerIcons"))
        TowerIcons.Power(iconFrame)
        TowerIcons.FrostMelon(iconFrame)
        ...

    Each builder takes a single `parent` Frame and fills it with a
    composition of UI Frames (rounded rectangles + UICorner). No return
    value — mutation through parent. Safe to call multiple times on the
    same parent (it adds children, doesn't clear existing ones — the
    caller clears if needed).

    The private `round` helper below is duplicated from the main chunk
    (4 lines) so this module is self-contained.
]]

local TowerIcons = {}

-- Private: attach a UICorner to a frame with the given radius scale.
local function round(frame, radiusScale)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(radiusScale or 0.12, 0)
    c.Parent = frame
end

local function buildPowerIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    for i = 0, 3 do
        local spike = Instance.new("Frame")
        spike.Size = UDim2.new(0.18, 0, 0.65, 0)
        spike.Position = UDim2.new(0.5, 0, 0.5, 0)
        spike.AnchorPoint = Vector2.new(0.5, 0.5)
        spike.Rotation = i * 45
        spike.BackgroundColor3 = Color3.fromRGB(255, 80, 70)
        spike.BorderSizePixel = 0
        spike.Parent = holder
        round(spike, 0.15)
    end
    local core = Instance.new("Frame")
    core.Size = UDim2.new(0.32, 0, 0.32, 0)
    core.Position = UDim2.new(0.5, 0, 0.5, 0)
    core.AnchorPoint = Vector2.new(0.5, 0.5)
    core.BackgroundColor3 = Color3.fromRGB(255, 220, 180)
    core.BorderSizePixel = 0
    core.Parent = holder
    round(core, 0.5)
    local hl = Instance.new("Frame")
    hl.Size = UDim2.new(0.14, 0, 0.14, 0)
    hl.Position = UDim2.new(0.42, 0, 0.42, 0)
    hl.AnchorPoint = Vector2.new(0.5, 0.5)
    hl.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    hl.BorderSizePixel = 0
    hl.Parent = holder
    round(hl, 0.5)
end

local function buildDoTIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local big = Instance.new("Frame")
    big.Size = UDim2.new(0.55, 0, 0.55, 0)
    big.Position = UDim2.new(0.5, 0, 0.62, 0)
    big.AnchorPoint = Vector2.new(0.5, 0.5)
    big.BackgroundColor3 = Color3.fromRGB(80, 200, 100)
    big.BorderSizePixel = 0
    big.Parent = holder
    round(big, 0.5)
    local tip = Instance.new("Frame")
    tip.Size = UDim2.new(0.28, 0, 0.28, 0)
    tip.Position = UDim2.new(0.5, 0, 0.28, 0)
    tip.AnchorPoint = Vector2.new(0.5, 0.5)
    tip.Rotation = 45
    tip.BackgroundColor3 = Color3.fromRGB(80, 200, 100)
    tip.BorderSizePixel = 0
    tip.Parent = holder
    round(tip, 0.15)
    local small = Instance.new("Frame")
    small.Size = UDim2.new(0.22, 0, 0.22, 0)
    small.Position = UDim2.new(0.78, 0, 0.24, 0)
    small.AnchorPoint = Vector2.new(0.5, 0.5)
    small.BackgroundColor3 = Color3.fromRGB(120, 230, 140)
    small.BorderSizePixel = 0
    small.Parent = holder
    round(small, 0.5)
end

local function buildCCIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local outer = Instance.new("Frame")
    outer.Size = UDim2.new(0.75, 0, 0.75, 0)
    outer.Position = UDim2.new(0.5, 0, 0.5, 0)
    outer.AnchorPoint = Vector2.new(0.5, 0.5)
    outer.BackgroundColor3 = Color3.fromRGB(60, 130, 230)
    outer.BorderSizePixel = 0
    outer.Parent = holder
    round(outer, 0.5)
    local mid = Instance.new("Frame")
    mid.Size = UDim2.new(0.5, 0, 0.5, 0)
    mid.Position = UDim2.new(0.5, 0, 0.5, 0)
    mid.AnchorPoint = Vector2.new(0.5, 0.5)
    mid.BackgroundColor3 = Color3.fromRGB(30, 40, 80)
    mid.BorderSizePixel = 0
    mid.Parent = holder
    round(mid, 0.5)
    local inner = Instance.new("Frame")
    inner.Size = UDim2.new(0.3, 0, 0.3, 0)
    inner.Position = UDim2.new(0.5, 0, 0.5, 0)
    inner.AnchorPoint = Vector2.new(0.5, 0.5)
    inner.BackgroundColor3 = Color3.fromRGB(100, 180, 255)
    inner.BorderSizePixel = 0
    inner.Parent = holder
    round(inner, 0.5)
    local center = Instance.new("Frame")
    center.Size = UDim2.new(0.1, 0, 0.1, 0)
    center.Position = UDim2.new(0.5, 0, 0.5, 0)
    center.AnchorPoint = Vector2.new(0.5, 0.5)
    center.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    center.BorderSizePixel = 0
    center.Parent = holder
    round(center, 0.5)
end

-- Frost Melon icon: round pale-teal melon with green stripes, frost spark.
local function buildFrostMelonIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local melon = Instance.new("Frame")
    melon.Size = UDim2.new(0.78, 0, 0.78, 0)
    melon.Position = UDim2.new(0.5, 0, 0.55, 0)
    melon.AnchorPoint = Vector2.new(0.5, 0.5)
    melon.BackgroundColor3 = Color3.fromRGB(150, 210, 220)
    melon.BorderSizePixel = 0
    melon.Parent = holder
    round(melon, 0.5)
    -- Stripes
    for i = -1, 1 do
        local s = Instance.new("Frame")
        s.Size = UDim2.new(0.06, 0, 0.72, 0)
        s.Position = UDim2.new(0.5 + i * 0.18, 0, 0.55, 0)
        s.AnchorPoint = Vector2.new(0.5, 0.5)
        s.BackgroundColor3 = Color3.fromRGB(60, 130, 95)
        s.BorderSizePixel = 0
        s.Parent = melon
        round(s, 0.5)
    end
    -- Frost spark
    local spark = Instance.new("Frame")
    spark.Size = UDim2.new(0.22, 0, 0.22, 0)
    spark.Position = UDim2.new(0.7, 0, 0.25, 0)
    spark.AnchorPoint = Vector2.new(0.5, 0.5)
    spark.Rotation = 45
    spark.BackgroundColor3 = Color3.fromRGB(230, 245, 255)
    spark.BorderSizePixel = 0
    spark.Parent = holder
    round(spark, 0.15)
end

-- Root Sprout icon: low mound with a central green sprout and root tendrils.
local function buildRootSproutIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local mound = Instance.new("Frame")
    mound.Size = UDim2.new(0.82, 0, 0.4, 0)
    mound.Position = UDim2.new(0.5, 0, 0.78, 0)
    mound.AnchorPoint = Vector2.new(0.5, 0.5)
    mound.BackgroundColor3 = Color3.fromRGB(105, 70, 45)
    mound.BorderSizePixel = 0
    mound.Parent = holder
    round(mound, 0.4)
    -- Tendrils — three small slanted rectangles fanning out
    for i = -1, 1 do
        local t = Instance.new("Frame")
        t.Size = UDim2.new(0.12, 0, 0.38, 0)
        t.Position = UDim2.new(0.5 + i * 0.24, 0, 0.55, 0)
        t.AnchorPoint = Vector2.new(0.5, 0.5)
        t.Rotation = i * 25
        t.BackgroundColor3 = Color3.fromRGB(95, 65, 45)
        t.BorderSizePixel = 0
        t.Parent = holder
        round(t, 0.3)
    end
    -- Central sprout leaf
    local leaf = Instance.new("Frame")
    leaf.Size = UDim2.new(0.22, 0, 0.35, 0)
    leaf.Position = UDim2.new(0.5, 0, 0.32, 0)
    leaf.AnchorPoint = Vector2.new(0.5, 0.5)
    leaf.BackgroundColor3 = Color3.fromRGB(70, 150, 65)
    leaf.BorderSizePixel = 0
    leaf.Parent = holder
    round(leaf, 0.4)
    -- Glow seed at top
    local seed = Instance.new("Frame")
    seed.Size = UDim2.new(0.18, 0, 0.18, 0)
    seed.Position = UDim2.new(0.5, 0, 0.22, 0)
    seed.AnchorPoint = Vector2.new(0.5, 0.5)
    seed.BackgroundColor3 = Color3.fromRGB(200, 245, 130)
    seed.BorderSizePixel = 0
    seed.Parent = holder
    round(seed, 0.5)
end

-- Thorn Vine icon: green stalk with red thorn spikes along its length.
local function buildThornVineIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local stalk = Instance.new("Frame")
    stalk.Size = UDim2.new(0.12, 0, 0.85, 0)
    stalk.Position = UDim2.new(0.5, 0, 0.5, 0)
    stalk.AnchorPoint = Vector2.new(0.5, 0.5)
    stalk.BackgroundColor3 = Color3.fromRGB(55, 100, 50)
    stalk.BorderSizePixel = 0
    stalk.Parent = holder
    round(stalk, 0.4)
    -- Thorns alternating left/right
    for i, spec in ipairs({ {y=0.2, dir=-1}, {y=0.45, dir=1}, {y=0.7, dir=-1} }) do
        local thorn = Instance.new("Frame")
        thorn.Size = UDim2.new(0.22, 0, 0.14, 0)
        thorn.Position = UDim2.new(0.5 + spec.dir * 0.15, 0, spec.y, 0)
        thorn.AnchorPoint = Vector2.new(0.5, 0.5)
        thorn.Rotation = spec.dir * 30
        thorn.BackgroundColor3 = Color3.fromRGB(170, 55, 55)
        thorn.BorderSizePixel = 0
        thorn.Parent = holder
        round(thorn, 0.3)
    end
    local bud = Instance.new("Frame")
    bud.Size = UDim2.new(0.2, 0, 0.2, 0)
    bud.Position = UDim2.new(0.5, 0, 0.12, 0)
    bud.AnchorPoint = Vector2.new(0.5, 0.5)
    bud.BackgroundColor3 = Color3.fromRGB(180, 230, 130)
    bud.BorderSizePixel = 0
    bud.Parent = holder
    round(bud, 0.5)
end

-- Honey Hive icon: golden hive (3 stacked discs) with an entry hole.
local function buildHoneyHiveIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    for i, spec in ipairs({ {w=0.72, y=0.75}, {w=0.6, y=0.55}, {w=0.42, y=0.35} }) do
        local disc = Instance.new("Frame")
        disc.Size = UDim2.new(spec.w, 0, 0.2, 0)
        disc.Position = UDim2.new(0.5, 0, spec.y, 0)
        disc.AnchorPoint = Vector2.new(0.5, 0.5)
        disc.BackgroundColor3 = Color3.fromRGB(225, 175, 60)
        disc.BorderSizePixel = 0
        disc.Parent = holder
        round(disc, 0.4)
    end
    -- Entry hole
    local hole = Instance.new("Frame")
    hole.Size = UDim2.new(0.18, 0, 0.18, 0)
    hole.Position = UDim2.new(0.5, 0, 0.65, 0)
    hole.AnchorPoint = Vector2.new(0.5, 0.5)
    hole.BackgroundColor3 = Color3.fromRGB(50, 30, 10)
    hole.BorderSizePixel = 0
    hole.Parent = holder
    round(hole, 0.5)
    -- Drip
    local drip = Instance.new("Frame")
    drip.Size = UDim2.new(0.1, 0, 0.15, 0)
    drip.Position = UDim2.new(0.75, 0, 0.82, 0)
    drip.AnchorPoint = Vector2.new(0.5, 0.5)
    drip.BackgroundColor3 = Color3.fromRGB(255, 215, 100)
    drip.BorderSizePixel = 0
    drip.Parent = holder
    round(drip, 0.5)
end

-- Acorn Sniper icon: brown acorn with darker cap and a crosshair over it.
local function buildAcornSniperIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local body = Instance.new("Frame")
    body.Size = UDim2.new(0.5, 0, 0.55, 0)
    body.Position = UDim2.new(0.5, 0, 0.62, 0)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(190, 140, 75)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.4)
    local cap = Instance.new("Frame")
    cap.Size = UDim2.new(0.58, 0, 0.25, 0)
    cap.Position = UDim2.new(0.5, 0, 0.32, 0)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.BackgroundColor3 = Color3.fromRGB(100, 70, 35)
    cap.BorderSizePixel = 0
    cap.Parent = holder
    round(cap, 0.5)
    -- Crosshair (plus sign)
    local v = Instance.new("Frame")
    v.Size = UDim2.new(0.04, 0, 0.5, 0)
    v.Position = UDim2.new(0.5, 0, 0.62, 0)
    v.AnchorPoint = Vector2.new(0.5, 0.5)
    v.BackgroundColor3 = Color3.fromRGB(255, 230, 120)
    v.BorderSizePixel = 0
    v.Parent = holder
    local h = Instance.new("Frame")
    h.Size = UDim2.new(0.5, 0, 0.04, 0)
    h.Position = UDim2.new(0.5, 0, 0.62, 0)
    h.AnchorPoint = Vector2.new(0.5, 0.5)
    h.BackgroundColor3 = Color3.fromRGB(255, 230, 120)
    h.BorderSizePixel = 0
    h.Parent = holder
end

-- Lightning Radish icon: purple radish with a yellow lightning zigzag.
local function buildLightningRadishIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local body = Instance.new("Frame")
    body.Size = UDim2.new(0.72, 0, 0.62, 0)
    body.Position = UDim2.new(0.5, 0, 0.62, 0)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(195, 80, 165)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.5)
    -- Leaves
    for i = -1, 1 do
        local leaf = Instance.new("Frame")
        leaf.Size = UDim2.new(0.12, 0, 0.32, 0)
        leaf.Position = UDim2.new(0.5 + i * 0.14, 0, 0.22, 0)
        leaf.AnchorPoint = Vector2.new(0.5, 0.5)
        leaf.Rotation = i * 15
        leaf.BackgroundColor3 = Color3.fromRGB(80, 160, 70)
        leaf.BorderSizePixel = 0
        leaf.Parent = holder
        round(leaf, 0.4)
    end
    -- Lightning zigzag (3 angled rectangles)
    for i, spec in ipairs({ {x=0.42, y=0.55, rot=25}, {x=0.58, y=0.65, rot=-25}, {x=0.5, y=0.78, rot=25} }) do
        local zz = Instance.new("Frame")
        zz.Size = UDim2.new(0.08, 0, 0.18, 0)
        zz.Position = UDim2.new(spec.x, 0, spec.y, 0)
        zz.AnchorPoint = Vector2.new(0.5, 0.5)
        zz.Rotation = spec.rot
        zz.BackgroundColor3 = Color3.fromRGB(255, 240, 120)
        zz.BorderSizePixel = 0
        zz.Parent = holder
        round(zz, 0.2)
    end
end

-- Spore Puffball icon: green dome with scattered darker spots.
local function buildSporePuffballIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local dome = Instance.new("Frame")
    dome.Size = UDim2.new(0.78, 0, 0.55, 0)
    dome.Position = UDim2.new(0.5, 0, 0.5, 0)
    dome.AnchorPoint = Vector2.new(0.5, 0.5)
    dome.BackgroundColor3 = Color3.fromRGB(170, 200, 140)
    dome.BorderSizePixel = 0
    dome.Parent = holder
    round(dome, 0.5)
    -- Spots
    for _, spec in ipairs({ {x=0.4, y=0.42}, {x=0.58, y=0.54}, {x=0.48, y=0.62}, {x=0.63, y=0.4} }) do
        local spot = Instance.new("Frame")
        spot.Size = UDim2.new(0.1, 0, 0.1, 0)
        spot.Position = UDim2.new(spec.x, 0, spec.y, 0)
        spot.AnchorPoint = Vector2.new(0.5, 0.5)
        spot.BackgroundColor3 = Color3.fromRGB(90, 140, 80)
        spot.BorderSizePixel = 0
        spot.Parent = holder
        round(spot, 0.5)
    end
    -- Stalk
    local stalk = Instance.new("Frame")
    stalk.Size = UDim2.new(0.22, 0, 0.18, 0)
    stalk.Position = UDim2.new(0.5, 0, 0.82, 0)
    stalk.AnchorPoint = Vector2.new(0.5, 0.5)
    stalk.BackgroundColor3 = Color3.fromRGB(230, 220, 190)
    stalk.BorderSizePixel = 0
    stalk.Parent = holder
    round(stalk, 0.2)
end

-- Pepper Cannon icon: red pepper pointing right with a flame at its tip.
local function buildPepperCannonIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    -- Pepper body (elongated horizontal)
    local body = Instance.new("Frame")
    body.Size = UDim2.new(0.7, 0, 0.28, 0)
    body.Position = UDim2.new(0.45, 0, 0.55, 0)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(210, 55, 40)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.5)
    -- Stem (green nub)
    local stem = Instance.new("Frame")
    stem.Size = UDim2.new(0.12, 0, 0.14, 0)
    stem.Position = UDim2.new(0.12, 0, 0.55, 0)
    stem.AnchorPoint = Vector2.new(0.5, 0.5)
    stem.BackgroundColor3 = Color3.fromRGB(70, 140, 55)
    stem.BorderSizePixel = 0
    stem.Parent = holder
    round(stem, 0.3)
    -- Flame (orange blob at tip, plus small yellow inner)
    local flame = Instance.new("Frame")
    flame.Size = UDim2.new(0.28, 0, 0.35, 0)
    flame.Position = UDim2.new(0.85, 0, 0.55, 0)
    flame.AnchorPoint = Vector2.new(0.5, 0.5)
    flame.BackgroundColor3 = Color3.fromRGB(255, 140, 40)
    flame.BorderSizePixel = 0
    flame.Parent = holder
    round(flame, 0.5)
    local inner = Instance.new("Frame")
    inner.Size = UDim2.new(0.14, 0, 0.18, 0)
    inner.Position = UDim2.new(0.83, 0, 0.55, 0)
    inner.AnchorPoint = Vector2.new(0.5, 0.5)
    inner.BackgroundColor3 = Color3.fromRGB(255, 230, 100)
    inner.BorderSizePixel = 0
    inner.Parent = holder
    round(inner, 0.5)
end

-- Mushroom Mortar icon: big red cap with white spots and an arc trail overhead.
local function buildMushroomMortarIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    -- Cap (bigger dome)
    local cap = Instance.new("Frame")
    cap.Size = UDim2.new(0.82, 0, 0.46, 0)
    cap.Position = UDim2.new(0.5, 0, 0.58, 0)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.BackgroundColor3 = Color3.fromRGB(190, 45, 45)
    cap.BorderSizePixel = 0
    cap.Parent = holder
    round(cap, 0.5)
    -- Stem under cap
    local stem = Instance.new("Frame")
    stem.Size = UDim2.new(0.34, 0, 0.25, 0)
    stem.Position = UDim2.new(0.5, 0, 0.85, 0)
    stem.AnchorPoint = Vector2.new(0.5, 0.5)
    stem.BackgroundColor3 = Color3.fromRGB(240, 220, 190)
    stem.BorderSizePixel = 0
    stem.Parent = holder
    round(stem, 0.2)
    -- Cap spots
    for _, spec in ipairs({ {x=0.35, y=0.5}, {x=0.55, y=0.46}, {x=0.68, y=0.54} }) do
        local spot = Instance.new("Frame")
        spot.Size = UDim2.new(0.1, 0, 0.1, 0)
        spot.Position = UDim2.new(spec.x, 0, spec.y, 0)
        spot.AnchorPoint = Vector2.new(0.5, 0.5)
        spot.BackgroundColor3 = Color3.fromRGB(250, 245, 235)
        spot.BorderSizePixel = 0
        spot.Parent = holder
        round(spot, 0.5)
    end
    -- Arc above — three little balls tracing a lobbing trajectory
    for i, spec in ipairs({ {x=0.15, y=0.25}, {x=0.35, y=0.12}, {x=0.6, y=0.2} }) do
        local p = Instance.new("Frame")
        p.Size = UDim2.new(0.08, 0, 0.08, 0)
        p.Position = UDim2.new(spec.x, 0, spec.y, 0)
        p.AnchorPoint = Vector2.new(0.5, 0.5)
        p.BackgroundColor3 = Color3.fromRGB(255, 180, 80)
        p.BackgroundTransparency = 0.3 + (3 - i) * 0.15
        p.BorderSizePixel = 0
        p.Parent = holder
        round(p, 0.5)
    end
end

-- Publish each builder under the tower id used by towerDefs / TowerTypes /
-- TempTowers.Templates, so callers can dispatch by id without a switch.
TowerIcons.Power           = buildPowerIcon
TowerIcons.DoT             = buildDoTIcon
TowerIcons.CC              = buildCCIcon
TowerIcons.FrostMelon      = buildFrostMelonIcon
TowerIcons.RootSprout      = buildRootSproutIcon
TowerIcons.ThornVine       = buildThornVineIcon
TowerIcons.HoneyHive       = buildHoneyHiveIcon
TowerIcons.AcornSniper     = buildAcornSniperIcon
TowerIcons.LightningRadish = buildLightningRadishIcon
TowerIcons.SporePuffball   = buildSporePuffballIcon
TowerIcons.PepperCannon    = buildPepperCannonIcon
TowerIcons.MushroomMortar  = buildMushroomMortarIcon

return TowerIcons
