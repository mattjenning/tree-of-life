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

-- buildCoreIcon — shared spiky-gem silhouette for all three Core
-- archetypes (Power / Control / Support). Each Core uses the SAME
-- shape but a different palette so the player visually reads
-- "this is a Core" while the tint communicates which one. Per
-- Matthew 2026-04-27 (ControlCore/SupportCore wiring): "there's
-- no icon for controlcore in hotbar."
--
--   spikeColor — the 4 rotated spikes (full opacity, signature color)
--   coreColor  — the central gem (lighter shade for contrast)
local function buildCoreIcon(parent, spikeColor, coreColor)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    for i = 0, 3 do
        local spike = Instance.new("Frame")
        spike.Size = UDim2.fromScale(0.18, 0.65)
        spike.Position = UDim2.fromScale(0.5, 0.5)
        spike.AnchorPoint = Vector2.new(0.5, 0.5)
        spike.Rotation = i * 45
        spike.BackgroundColor3 = spikeColor
        spike.BorderSizePixel = 0
        spike.Parent = holder
        round(spike, 0.15)
    end
    local core = Instance.new("Frame")
    core.Size = UDim2.fromScale(0.32, 0.32)
    core.Position = UDim2.fromScale(0.5, 0.5)
    core.AnchorPoint = Vector2.new(0.5, 0.5)
    core.BackgroundColor3 = coreColor
    core.BorderSizePixel = 0
    core.Parent = holder
    round(core, 0.5)
    local hl = Instance.new("Frame")
    hl.Size = UDim2.fromScale(0.14, 0.14)
    hl.Position = UDim2.fromScale(0.42, 0.42)
    hl.AnchorPoint = Vector2.new(0.5, 0.5)
    hl.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    hl.BorderSizePixel = 0
    hl.Parent = holder
    round(hl, 0.5)
end

local function buildPowerIcon(parent)
    -- DPS Core — red spikes / cream gem (existing palette).
    buildCoreIcon(parent,
        Color3.fromRGB(255, 80, 70),
        Color3.fromRGB(255, 220, 180))
end

local function buildControlCoreIcon(parent)
    -- Control Core — purple spikes / lavender gem. Shares the
    -- DPS / Control / Support role-color triad with the loadout
    -- picker's role tags + admin tier-list role columns.
    buildCoreIcon(parent,
        Color3.fromRGB(180, 100, 230),
        Color3.fromRGB(230, 200, 255))
end

local function buildSupportCoreIcon(parent)
    -- Support Core — sky-blue spikes / pale-blue gem.
    buildCoreIcon(parent,
        Color3.fromRGB(80, 180, 240),
        Color3.fromRGB(200, 230, 255))
end

local function buildDoTIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Parent = parent
    local big = Instance.new("Frame")
    big.Size = UDim2.fromScale(0.55, 0.55)
    big.Position = UDim2.fromScale(0.5, 0.62)
    big.AnchorPoint = Vector2.new(0.5, 0.5)
    big.BackgroundColor3 = Color3.fromRGB(80, 200, 100)
    big.BorderSizePixel = 0
    big.Parent = holder
    round(big, 0.5)
    local tip = Instance.new("Frame")
    tip.Size = UDim2.fromScale(0.28, 0.28)
    tip.Position = UDim2.fromScale(0.5, 0.28)
    tip.AnchorPoint = Vector2.new(0.5, 0.5)
    tip.Rotation = 45
    tip.BackgroundColor3 = Color3.fromRGB(80, 200, 100)
    tip.BorderSizePixel = 0
    tip.Parent = holder
    round(tip, 0.15)
    local small = Instance.new("Frame")
    small.Size = UDim2.fromScale(0.22, 0.22)
    small.Position = UDim2.fromScale(0.78, 0.24)
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
    outer.Size = UDim2.fromScale(0.75, 0.75)
    outer.Position = UDim2.fromScale(0.5, 0.5)
    outer.AnchorPoint = Vector2.new(0.5, 0.5)
    outer.BackgroundColor3 = Color3.fromRGB(60, 130, 230)
    outer.BorderSizePixel = 0
    outer.Parent = holder
    round(outer, 0.5)
    local mid = Instance.new("Frame")
    mid.Size = UDim2.fromScale(0.5, 0.5)
    mid.Position = UDim2.fromScale(0.5, 0.5)
    mid.AnchorPoint = Vector2.new(0.5, 0.5)
    mid.BackgroundColor3 = Color3.fromRGB(30, 40, 80)
    mid.BorderSizePixel = 0
    mid.Parent = holder
    round(mid, 0.5)
    local inner = Instance.new("Frame")
    inner.Size = UDim2.fromScale(0.3, 0.3)
    inner.Position = UDim2.fromScale(0.5, 0.5)
    inner.AnchorPoint = Vector2.new(0.5, 0.5)
    inner.BackgroundColor3 = Color3.fromRGB(100, 180, 255)
    inner.BorderSizePixel = 0
    inner.Parent = holder
    round(inner, 0.5)
    local center = Instance.new("Frame")
    center.Size = UDim2.fromScale(0.1, 0.1)
    center.Position = UDim2.fromScale(0.5, 0.5)
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
    melon.Size = UDim2.fromScale(0.78, 0.78)
    melon.Position = UDim2.fromScale(0.5, 0.55)
    melon.AnchorPoint = Vector2.new(0.5, 0.5)
    melon.BackgroundColor3 = Color3.fromRGB(150, 210, 220)
    melon.BorderSizePixel = 0
    melon.Parent = holder
    round(melon, 0.5)
    -- Stripes
    for i = -1, 1 do
        local s = Instance.new("Frame")
        s.Size = UDim2.fromScale(0.06, 0.72)
        s.Position = UDim2.fromScale(0.5 + i * 0.18, 0.55)
        s.AnchorPoint = Vector2.new(0.5, 0.5)
        s.BackgroundColor3 = Color3.fromRGB(60, 130, 95)
        s.BorderSizePixel = 0
        s.Parent = melon
        round(s, 0.5)
    end
    -- Frost spark
    local spark = Instance.new("Frame")
    spark.Size = UDim2.fromScale(0.22, 0.22)
    spark.Position = UDim2.fromScale(0.7, 0.25)
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
    mound.Size = UDim2.fromScale(0.82, 0.4)
    mound.Position = UDim2.fromScale(0.5, 0.78)
    mound.AnchorPoint = Vector2.new(0.5, 0.5)
    mound.BackgroundColor3 = Color3.fromRGB(105, 70, 45)
    mound.BorderSizePixel = 0
    mound.Parent = holder
    round(mound, 0.4)
    -- Tendrils — three small slanted rectangles fanning out
    for i = -1, 1 do
        local t = Instance.new("Frame")
        t.Size = UDim2.fromScale(0.12, 0.38)
        t.Position = UDim2.fromScale(0.5 + i * 0.24, 0.55)
        t.AnchorPoint = Vector2.new(0.5, 0.5)
        t.Rotation = i * 25
        t.BackgroundColor3 = Color3.fromRGB(95, 65, 45)
        t.BorderSizePixel = 0
        t.Parent = holder
        round(t, 0.3)
    end
    -- Central sprout leaf
    local leaf = Instance.new("Frame")
    leaf.Size = UDim2.fromScale(0.22, 0.35)
    leaf.Position = UDim2.fromScale(0.5, 0.32)
    leaf.AnchorPoint = Vector2.new(0.5, 0.5)
    leaf.BackgroundColor3 = Color3.fromRGB(70, 150, 65)
    leaf.BorderSizePixel = 0
    leaf.Parent = holder
    round(leaf, 0.4)
    -- Glow seed at top
    local seed = Instance.new("Frame")
    seed.Size = UDim2.fromScale(0.18, 0.18)
    seed.Position = UDim2.fromScale(0.5, 0.22)
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
    stalk.Size = UDim2.fromScale(0.12, 0.85)
    stalk.Position = UDim2.fromScale(0.5, 0.5)
    stalk.AnchorPoint = Vector2.new(0.5, 0.5)
    stalk.BackgroundColor3 = Color3.fromRGB(55, 100, 50)
    stalk.BorderSizePixel = 0
    stalk.Parent = holder
    round(stalk, 0.4)
    -- Thorns alternating left/right
    for _, spec in ipairs({ {y=0.2, dir=-1}, {y=0.45, dir=1}, {y=0.7, dir=-1} }) do
        local thorn = Instance.new("Frame")
        thorn.Size = UDim2.fromScale(0.22, 0.14)
        thorn.Position = UDim2.fromScale(0.5 + spec.dir * 0.15, spec.y)
        thorn.AnchorPoint = Vector2.new(0.5, 0.5)
        thorn.Rotation = spec.dir * 30
        thorn.BackgroundColor3 = Color3.fromRGB(170, 55, 55)
        thorn.BorderSizePixel = 0
        thorn.Parent = holder
        round(thorn, 0.3)
    end
    local bud = Instance.new("Frame")
    bud.Size = UDim2.fromScale(0.2, 0.2)
    bud.Position = UDim2.fromScale(0.5, 0.12)
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
    for _, spec in ipairs({ {w=0.72, y=0.75}, {w=0.6, y=0.55}, {w=0.42, y=0.35} }) do
        local disc = Instance.new("Frame")
        disc.Size = UDim2.fromScale(spec.w, 0.2)
        disc.Position = UDim2.fromScale(0.5, spec.y)
        disc.AnchorPoint = Vector2.new(0.5, 0.5)
        disc.BackgroundColor3 = Color3.fromRGB(225, 175, 60)
        disc.BorderSizePixel = 0
        disc.Parent = holder
        round(disc, 0.4)
    end
    -- Entry hole
    local hole = Instance.new("Frame")
    hole.Size = UDim2.fromScale(0.18, 0.18)
    hole.Position = UDim2.fromScale(0.5, 0.65)
    hole.AnchorPoint = Vector2.new(0.5, 0.5)
    hole.BackgroundColor3 = Color3.fromRGB(50, 30, 10)
    hole.BorderSizePixel = 0
    hole.Parent = holder
    round(hole, 0.5)
    -- Drip
    local drip = Instance.new("Frame")
    drip.Size = UDim2.fromScale(0.1, 0.15)
    drip.Position = UDim2.fromScale(0.75, 0.82)
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
    body.Size = UDim2.fromScale(0.5, 0.55)
    body.Position = UDim2.fromScale(0.5, 0.62)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(190, 140, 75)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.4)
    local cap = Instance.new("Frame")
    cap.Size = UDim2.fromScale(0.58, 0.25)
    cap.Position = UDim2.fromScale(0.5, 0.32)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.BackgroundColor3 = Color3.fromRGB(100, 70, 35)
    cap.BorderSizePixel = 0
    cap.Parent = holder
    round(cap, 0.5)
    -- Crosshair (plus sign)
    local v = Instance.new("Frame")
    v.Size = UDim2.fromScale(0.04, 0.5)
    v.Position = UDim2.fromScale(0.5, 0.62)
    v.AnchorPoint = Vector2.new(0.5, 0.5)
    v.BackgroundColor3 = Color3.fromRGB(255, 230, 120)
    v.BorderSizePixel = 0
    v.Parent = holder
    local h = Instance.new("Frame")
    h.Size = UDim2.fromScale(0.5, 0.04)
    h.Position = UDim2.fromScale(0.5, 0.62)
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
    body.Size = UDim2.fromScale(0.72, 0.62)
    body.Position = UDim2.fromScale(0.5, 0.62)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(195, 80, 165)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.5)
    -- Leaves
    for i = -1, 1 do
        local leaf = Instance.new("Frame")
        leaf.Size = UDim2.fromScale(0.12, 0.32)
        leaf.Position = UDim2.fromScale(0.5 + i * 0.14, 0.22)
        leaf.AnchorPoint = Vector2.new(0.5, 0.5)
        leaf.Rotation = i * 15
        leaf.BackgroundColor3 = Color3.fromRGB(80, 160, 70)
        leaf.BorderSizePixel = 0
        leaf.Parent = holder
        round(leaf, 0.4)
    end
    -- Lightning zigzag (3 angled rectangles)
    for _, spec in ipairs({ {x=0.42, y=0.55, rot=25}, {x=0.58, y=0.65, rot=-25}, {x=0.5, y=0.78, rot=25} }) do
        local zz = Instance.new("Frame")
        zz.Size = UDim2.fromScale(0.08, 0.18)
        zz.Position = UDim2.fromScale(spec.x, spec.y)
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
    dome.Size = UDim2.fromScale(0.78, 0.55)
    dome.Position = UDim2.fromScale(0.5, 0.5)
    dome.AnchorPoint = Vector2.new(0.5, 0.5)
    dome.BackgroundColor3 = Color3.fromRGB(170, 200, 140)
    dome.BorderSizePixel = 0
    dome.Parent = holder
    round(dome, 0.5)
    -- Spots
    for _, spec in ipairs({ {x=0.4, y=0.42}, {x=0.58, y=0.54}, {x=0.48, y=0.62}, {x=0.63, y=0.4} }) do
        local spot = Instance.new("Frame")
        spot.Size = UDim2.fromScale(0.1, 0.1)
        spot.Position = UDim2.fromScale(spec.x, spec.y)
        spot.AnchorPoint = Vector2.new(0.5, 0.5)
        spot.BackgroundColor3 = Color3.fromRGB(90, 140, 80)
        spot.BorderSizePixel = 0
        spot.Parent = holder
        round(spot, 0.5)
    end
    -- Stalk
    local stalk = Instance.new("Frame")
    stalk.Size = UDim2.fromScale(0.22, 0.18)
    stalk.Position = UDim2.fromScale(0.5, 0.82)
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
    body.Size = UDim2.fromScale(0.7, 0.28)
    body.Position = UDim2.fromScale(0.45, 0.55)
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.BackgroundColor3 = Color3.fromRGB(210, 55, 40)
    body.BorderSizePixel = 0
    body.Parent = holder
    round(body, 0.5)
    -- Stem (green nub)
    local stem = Instance.new("Frame")
    stem.Size = UDim2.fromScale(0.12, 0.14)
    stem.Position = UDim2.fromScale(0.12, 0.55)
    stem.AnchorPoint = Vector2.new(0.5, 0.5)
    stem.BackgroundColor3 = Color3.fromRGB(70, 140, 55)
    stem.BorderSizePixel = 0
    stem.Parent = holder
    round(stem, 0.3)
    -- Flame (orange blob at tip, plus small yellow inner)
    local flame = Instance.new("Frame")
    flame.Size = UDim2.fromScale(0.28, 0.35)
    flame.Position = UDim2.fromScale(0.85, 0.55)
    flame.AnchorPoint = Vector2.new(0.5, 0.5)
    flame.BackgroundColor3 = Color3.fromRGB(255, 140, 40)
    flame.BorderSizePixel = 0
    flame.Parent = holder
    round(flame, 0.5)
    local inner = Instance.new("Frame")
    inner.Size = UDim2.fromScale(0.14, 0.18)
    inner.Position = UDim2.fromScale(0.83, 0.55)
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
    cap.Size = UDim2.fromScale(0.82, 0.46)
    cap.Position = UDim2.fromScale(0.5, 0.58)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.BackgroundColor3 = Color3.fromRGB(190, 45, 45)
    cap.BorderSizePixel = 0
    cap.Parent = holder
    round(cap, 0.5)
    -- Stem under cap
    local stem = Instance.new("Frame")
    stem.Size = UDim2.fromScale(0.34, 0.25)
    stem.Position = UDim2.fromScale(0.5, 0.85)
    stem.AnchorPoint = Vector2.new(0.5, 0.5)
    stem.BackgroundColor3 = Color3.fromRGB(240, 220, 190)
    stem.BorderSizePixel = 0
    stem.Parent = holder
    round(stem, 0.2)
    -- Cap spots
    for _, spec in ipairs({ {x=0.35, y=0.5}, {x=0.55, y=0.46}, {x=0.68, y=0.54} }) do
        local spot = Instance.new("Frame")
        spot.Size = UDim2.fromScale(0.1, 0.1)
        spot.Position = UDim2.fromScale(spec.x, spec.y)
        spot.AnchorPoint = Vector2.new(0.5, 0.5)
        spot.BackgroundColor3 = Color3.fromRGB(250, 245, 235)
        spot.BorderSizePixel = 0
        spot.Parent = holder
        round(spot, 0.5)
    end
    -- Arc above — three little balls tracing a lobbing trajectory
    for i, spec in ipairs({ {x=0.15, y=0.25}, {x=0.35, y=0.12}, {x=0.6, y=0.2} }) do
        local p = Instance.new("Frame")
        p.Size = UDim2.fromScale(0.08, 0.08)
        p.Position = UDim2.fromScale(spec.x, spec.y)
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
-- ───── 2026-04-28: 5 new tower icons (BlinkBerry / PaceFlower /
-- PowerSeed / SpyglassRoot / BloodlinkVine) per Matthew "generate
-- add pictures and flavor text for all towers if they're missing
-- it." Each is a flat-Frame composition matching the silhouette
-- vocabulary of the existing 9 — round body + accent shape +
-- highlight, no images or scripts.

-- BlinkBerry — purple berry with a teleport echo.
local function buildBlinkBerryIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1); holder.BackgroundTransparency = 1; holder.Parent = parent
    -- Echo (faded ghost)
    local echo = Instance.new("Frame")
    echo.Size = UDim2.fromScale(0.55, 0.55)
    echo.Position = UDim2.fromScale(0.30, 0.55); echo.AnchorPoint = Vector2.new(0.5, 0.5)
    echo.BackgroundColor3 = Color3.fromRGB(150, 90, 220); echo.BackgroundTransparency = 0.5
    echo.BorderSizePixel = 0; echo.Parent = holder; round(echo, 0.5)
    -- Berry
    local berry = Instance.new("Frame")
    berry.Size = UDim2.fromScale(0.62, 0.62)
    berry.Position = UDim2.fromScale(0.62, 0.55); berry.AnchorPoint = Vector2.new(0.5, 0.5)
    berry.BackgroundColor3 = Color3.fromRGB(180, 100, 235); berry.BorderSizePixel = 0
    berry.Parent = holder; round(berry, 0.5)
    -- Stem
    local stem = Instance.new("Frame")
    stem.Size = UDim2.fromScale(0.08, 0.18)
    stem.Position = UDim2.fromScale(0.62, 0.20); stem.AnchorPoint = Vector2.new(0.5, 0.5)
    stem.BackgroundColor3 = Color3.fromRGB(80, 100, 50); stem.BorderSizePixel = 0
    stem.Parent = holder; round(stem, 0.3)
    -- Highlight
    local hl = Instance.new("Frame")
    hl.Size = UDim2.fromScale(0.14, 0.14)
    hl.Position = UDim2.fromScale(0.52, 0.42); hl.AnchorPoint = Vector2.new(0.5, 0.5)
    hl.BackgroundColor3 = Color3.fromRGB(255, 255, 255); hl.BorderSizePixel = 0
    hl.Parent = holder; round(hl, 0.5)
end

-- PaceFlower — yellow petals around a gold center, with a subtle
-- speed-blur ring (fire-rate aura).
local function buildPaceFlowerIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1); holder.BackgroundTransparency = 1; holder.Parent = parent
    -- Aura ring
    local ring = Instance.new("Frame")
    ring.Size = UDim2.fromScale(0.92, 0.92)
    ring.Position = UDim2.fromScale(0.5, 0.5); ring.AnchorPoint = Vector2.new(0.5, 0.5)
    ring.BackgroundColor3 = Color3.fromRGB(255, 220, 80); ring.BackgroundTransparency = 0.7
    ring.BorderSizePixel = 0; ring.Parent = holder; round(ring, 0.5)
    -- 6 petals
    for i = 0, 5 do
        local p = Instance.new("Frame")
        p.Size = UDim2.fromScale(0.22, 0.46)
        p.Position = UDim2.fromScale(0.5, 0.5); p.AnchorPoint = Vector2.new(0.5, 0.5)
        p.Rotation = i * 60
        p.BackgroundColor3 = Color3.fromRGB(255, 210, 90); p.BorderSizePixel = 0
        p.Parent = holder; round(p, 0.5)
    end
    -- Center
    local c = Instance.new("Frame")
    c.Size = UDim2.fromScale(0.30, 0.30)
    c.Position = UDim2.fromScale(0.5, 0.5); c.AnchorPoint = Vector2.new(0.5, 0.5)
    c.BackgroundColor3 = Color3.fromRGB(220, 140, 40); c.BorderSizePixel = 0
    c.Parent = holder; round(c, 0.5)
end

-- PowerSeed — red seed with three radiating sparks (damage aura).
local function buildPowerSeedIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1); holder.BackgroundTransparency = 1; holder.Parent = parent
    -- Sparks (3 thin spokes)
    for i = 0, 2 do
        local s = Instance.new("Frame")
        s.Size = UDim2.fromScale(0.08, 0.78)
        s.Position = UDim2.fromScale(0.5, 0.5); s.AnchorPoint = Vector2.new(0.5, 0.5)
        s.Rotation = i * 60 + 30
        s.BackgroundColor3 = Color3.fromRGB(255, 130, 80); s.BackgroundTransparency = 0.4
        s.BorderSizePixel = 0; s.Parent = holder; round(s, 0.5)
    end
    -- Seed body (teardrop-ish via small + large rounded combo)
    local seed = Instance.new("Frame")
    seed.Size = UDim2.fromScale(0.50, 0.62)
    seed.Position = UDim2.fromScale(0.5, 0.55); seed.AnchorPoint = Vector2.new(0.5, 0.5)
    seed.BackgroundColor3 = Color3.fromRGB(220, 60, 50); seed.BorderSizePixel = 0
    seed.Parent = holder; round(seed, 0.5)
    -- Highlight
    local hl = Instance.new("Frame")
    hl.Size = UDim2.fromScale(0.14, 0.18)
    hl.Position = UDim2.fromScale(0.40, 0.42); hl.AnchorPoint = Vector2.new(0.5, 0.5)
    hl.BackgroundColor3 = Color3.fromRGB(255, 200, 180); hl.BorderSizePixel = 0
    hl.Parent = holder; round(hl, 0.5)
end

-- SpyglassRoot — brown spyglass tube with a cyan lens (range aura).
local function buildSpyglassRootIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1); holder.BackgroundTransparency = 1; holder.Parent = parent
    -- Tube (rotated rectangle)
    local tube = Instance.new("Frame")
    tube.Size = UDim2.fromScale(0.78, 0.26)
    tube.Position = UDim2.fromScale(0.5, 0.55); tube.AnchorPoint = Vector2.new(0.5, 0.5)
    tube.Rotation = -30
    tube.BackgroundColor3 = Color3.fromRGB(140, 90, 50); tube.BorderSizePixel = 0
    tube.Parent = holder; round(tube, 0.4)
    -- Wide eyepiece
    local eye = Instance.new("Frame")
    eye.Size = UDim2.fromScale(0.32, 0.36)
    eye.Position = UDim2.fromScale(0.78, 0.32); eye.AnchorPoint = Vector2.new(0.5, 0.5)
    eye.BackgroundColor3 = Color3.fromRGB(90, 60, 30); eye.BorderSizePixel = 0
    eye.Parent = holder; round(eye, 0.5)
    -- Lens (cyan glow)
    local lens = Instance.new("Frame")
    lens.Size = UDim2.fromScale(0.20, 0.24)
    lens.Position = UDim2.fromScale(0.78, 0.32); lens.AnchorPoint = Vector2.new(0.5, 0.5)
    lens.BackgroundColor3 = Color3.fromRGB(120, 220, 240); lens.BorderSizePixel = 0
    lens.Parent = holder; round(lens, 0.5)
    -- Lens highlight
    local hl = Instance.new("Frame")
    hl.Size = UDim2.fromScale(0.06, 0.08)
    hl.Position = UDim2.fromScale(0.74, 0.28); hl.AnchorPoint = Vector2.new(0.5, 0.5)
    hl.BackgroundColor3 = Color3.fromRGB(255, 255, 255); hl.BorderSizePixel = 0
    hl.Parent = holder; round(hl, 0.5)
end

-- BloodlinkVine — three linked red rings (mob-link mechanic).
local function buildBloodlinkVineIcon(parent)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.fromScale(1, 1); holder.BackgroundTransparency = 1; holder.Parent = parent
    local positions = {
        { 0.30, 0.65 },
        { 0.50, 0.35 },
        { 0.72, 0.65 },
    }
    for _, p in ipairs(positions) do
        local outer = Instance.new("Frame")
        outer.Size = UDim2.fromScale(0.34, 0.34)
        outer.Position = UDim2.fromScale(p[1], p[2]); outer.AnchorPoint = Vector2.new(0.5, 0.5)
        outer.BackgroundColor3 = Color3.fromRGB(180, 40, 60); outer.BorderSizePixel = 0
        outer.Parent = holder; round(outer, 0.5)
        local inner = Instance.new("Frame")
        inner.Size = UDim2.fromScale(0.55, 0.55)
        inner.Position = UDim2.fromScale(0.5, 0.5); inner.AnchorPoint = Vector2.new(0.5, 0.5)
        inner.BackgroundColor3 = Color3.fromRGB(28, 32, 44); inner.BorderSizePixel = 0
        inner.Parent = outer; round(inner, 0.5)
    end
    -- Connecting droplet between left+mid
    for _, pair in ipairs({ {0.40, 0.50}, {0.61, 0.50} }) do
        local d = Instance.new("Frame")
        d.Size = UDim2.fromScale(0.10, 0.10)
        d.Position = UDim2.fromScale(pair[1], pair[2]); d.AnchorPoint = Vector2.new(0.5, 0.5)
        d.BackgroundColor3 = Color3.fromRGB(220, 80, 90); d.BorderSizePixel = 0
        d.Parent = holder; round(d, 0.5)
    end
end

TowerIcons.Power           = buildPowerIcon
TowerIcons.ControlCore     = buildControlCoreIcon
TowerIcons.SupportCore     = buildSupportCoreIcon
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
TowerIcons.BlinkBerry      = buildBlinkBerryIcon
TowerIcons.PaceFlower      = buildPaceFlowerIcon
TowerIcons.PowerSeed       = buildPowerSeedIcon
TowerIcons.SpyglassRoot    = buildSpyglassRootIcon
TowerIcons.BloodlinkVine   = buildBloodlinkVineIcon

return TowerIcons
