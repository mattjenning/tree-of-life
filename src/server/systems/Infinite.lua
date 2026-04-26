--[[
    Infinite.lua — Phase 1 of the Infinite Arena (balance/benchmark
    sandbox per project_infinite_arena.md).

    OWNS:
    - Hub-portal entry handler (called from HubWorld.Touched): teleports
      into Map4, fires SwitchMap (noAutoWaves=true) so the wave system
      knows we're on map 4 without kicking off WAVES[1], grants the
      default tower stock, starts the spawner.
    - Return-portal lazy build inside Map4 (touch → exit + summary).
    - 3-wave loop spawner: every run cycles AOE / Combined / Solo by
      wave % 3, with RunDifficultyMult ramping geometrically per wave.
    - Heart-death listener: on Health <= 0, prints
        "failed at wave N (testType)" + StatLedger.summary(),
      then auto-returns the player to the hub.

    NOT YET:
    - Full UI for tweaking ramp constants live (today: read from
      Config.Map4.Difficulty)
    - Per-scenario damage / status separators in StatLedger summary
    - Multi-player Infinite (today assumes one player at a time)

    setup(ctx) reads:
      ctx.MAP4_PLAYER_SPAWN_CF / ctx.HUB_SPAWN_CF
      ctx.map4Heart, ctx.map4Room
      ctx.makeMob, ctx.activeMobs, ctx.clearAllMobs
      ctx.statLedger
      ctx.StageState  (we set currentMapId=4 on entry)

    Publishes:
      ctx.enterInfinite(player, scenarioName)
      ctx.exitInfinite(player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Remotes  = require(Shared:WaitForChild("Remotes"))
local Config   = require(Shared:WaitForChild("Config"))
local GameTime = require(Shared:WaitForChild("GameTime"))

local Infinite = {}

-- Cinematic timing
local ENTRY_FADE_OUT_SEC = 0.8
local EXIT_FADE_OUT_SEC  = 0.6

-- Lazy-wired return portal
local returnPortalSetup = false

------------------------------------------------------------
-- Run state. Single-player at a time; multi-player Infinite is
-- a future expansion (would require per-player StageState).
------------------------------------------------------------
local State = {
    active        = false,
    activePlayer  = nil :: Player?,
    -- Wave counter: ramps continuously across the 3-test loop. Wave 1
    -- is AOE-easy; by wave 30 we're in late-stage SoloTarget hell.
    -- Last reached + last test type land in the run-end summary
    -- ("failed at wave 12 (AOE)").
    wave          = 0,
    spawnerToken  = 0,    -- bumped on stop() so live coroutines can detect abort
    heartConn     = nil :: RBXScriptConnection?,
}

------------------------------------------------------------
-- 3-wave loop. Every run cycles through these test types in order;
-- the wave counter ramps continuously so wave 1 is AOE-easy and wave
-- 30 is Solo-target-very-hard.
--
--   waveIndex % 3 == 1 → AOE      — many basic mobs in tight clumps.
--                                    Exercises splash, Detonator
--                                    chains, knockback.
--   waveIndex % 3 == 2 → Combined — basic + fast + tank mixed.
--                                    Exercises target-priority +
--                                    overall DPS.
--   waveIndex % 3 == 0 → Solo     — one big tank-type mob, HP-scaled
--                                    by RunDifficultyMult. Exercises
--                                    sustained DPS + stun value.
--
-- Each test function returns a list of {mobType, count} pairs.
------------------------------------------------------------
local TEST_TYPES = {
    AOE = function(wave)
        return {
            { mobType = "basic", count = 10 + wave * 2 },
        }
    end,

    Combined = function(wave)
        return {
            { mobType = "basic", count = 6 + wave },
            { mobType = "fast",  count = 3 + math.floor(wave / 2) },
            { mobType = "tank",  count = 1 + math.floor(wave / 4) },
        }
    end,

    Solo = function(wave)
        -- One tank per wave (sometimes 2 at higher rounds for cap-size
        -- testing). RunDifficultyMult drives HP scaling.
        return {
            { mobType = "tank", count = 1 + math.floor(wave / 8) },
        }
    end,
}

-- Wave-mod → test-type name, as a frozen lookup so the spawner is
-- a single dispatch and the heart-death summary can name the test
-- the player failed on (e.g. "failed at wave 12 (AOE)").
local TEST_BY_MOD = { [1] = "AOE", [2] = "Combined", [0] = "Solo" }
local function testTypeForWave(wave: number): string
    return TEST_BY_MOD[wave % 3] or "Combined"
end

------------------------------------------------------------
-- Default tower loadout granted on Infinite entry. Generous so
-- the player can mix-and-match for any scenario without leaving
-- to the hub for stock.
------------------------------------------------------------
local LOADOUT = {
    PowerStock        = 5,
    RootSproutStock   = 4,
    FrostMelonStock   = 4,
    ThornVineStock    = 4,
    HoneyHiveStock    = 3,
    AcornSniperStock  = 3,
    LightningRadishStock = 3,
    SporePuffballStock   = 3,
    PepperCannonStock    = 3,
    MushroomMortarStock  = 3,
    RerollTokens      = 5,
    CarryingAmmo      = 0,
}

local function grantLoadout(player: Player)
    for attr, val in pairs(LOADOUT) do
        player:SetAttribute(attr, val)
    end
    -- Mark "stock granted" so the client unhides the hotbar via the
    -- standard plumbing (TreeOfLife_Hub watches HasBeenGrantedStock).
    player:SetAttribute("HasBeenGrantedStock", true)
end

------------------------------------------------------------
-- Return portal (built lazily on first entry).
------------------------------------------------------------
local function setupReturnPortal(map4Room: Model, spawnCF: CFrame, exitCallback: (Player) -> ())
    if returnPortalSetup then return end
    returnPortalSetup = true
    local pos = spawnCF.Position + Vector3.new(6, -3, 0)
    local outerRing = Instance.new("Part")
    outerRing.Name = "ReturnPortalOuterRing"
    outerRing.Shape = Enum.PartType.Cylinder
    outerRing.Anchored = true
    outerRing.CanCollide = false
    outerRing.Size = Vector3.new(0.3, 14, 14)
    outerRing.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
    outerRing.Material = Enum.Material.Neon
    outerRing.Color = Color3.fromRGB(80, 220, 100)
    outerRing.Transparency = 0.35
    outerRing.Parent = map4Room

    local disc = Instance.new("Part")
    disc.Name = "ReturnPortalDisc"
    disc.Shape = Enum.PartType.Cylinder
    disc.Anchored = true
    disc.CanCollide = false
    disc.Size = Vector3.new(0.4, 10, 10)
    disc.CFrame = CFrame.new(pos + Vector3.new(0, 0.1, 0))
              * CFrame.Angles(0, 0, math.rad(90))
    disc.Material = Enum.Material.Neon
    disc.Color = Color3.fromRGB(60, 255, 110)
    disc.Transparency = 0.15
    disc.Parent = map4Room

    local labelAnchor = Instance.new("Part")
    labelAnchor.Name = "ReturnLabelAnchor"
    labelAnchor.Anchored = true
    labelAnchor.CanCollide = false
    labelAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
    labelAnchor.Transparency = 1
    labelAnchor.CFrame = CFrame.new(pos + Vector3.new(0, 6, 0))
    labelAnchor.Parent = map4Room
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.fromOffset(220, 50)
    billboard.LightInfluence = 0
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 200
    billboard.Parent = labelAnchor
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "RETURN TO HUB"
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 28
    label.TextColor3 = Color3.fromRGB(220, 255, 230)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.4
    label.Parent = billboard

    local lastExitAt = {}
    disc.Touched:Connect(function(other)
        if not other or not other.Parent then return end
        if other.Name ~= "HumanoidRootPart" then return end
        local player = Players:GetPlayerFromCharacter(other.Parent)
        if not player then return end
        local now = os.clock()
        if now - (lastExitAt[player.UserId] or 0) < 1.0 then return end
        lastExitAt[player.UserId] = now
        exitCallback(player)
    end)
    print("[Infinite] return portal wired in pickle dimension")
end

function Infinite.setup(ctx)
    local function getHubSpawnCF(): CFrame
        return ctx.HUB_SPAWN_CF or CFrame.new(0, 5, 5)
    end
    local function getMap4SpawnCF(): CFrame
        return ctx.MAP4_PLAYER_SPAWN_CF or CFrame.new(8000, 105, 0)
    end

    local enterRemote = Remotes.getOrCreate(Remotes.Names.EnterInfinite, "RemoteEvent")
    local exitRemote  = Remotes.getOrCreate(Remotes.Names.ExitInfinite, "RemoteEvent")
    local pickRemote  = Remotes.getOrCreate(Remotes.Names.PickInfiniteScenario, "RemoteEvent")
    local roundRemote = Remotes.getOrCreate(Remotes.Names.InfiniteRoundUpdate, "RemoteEvent")
    -- Pre-create the picker remote so HubWorld can FireClient on it.
    Remotes.getOrCreate(Remotes.Names.ShowInfiniteScenarioPicker, "RemoteEvent")

    local function teleportTo(player: Player, cf: CFrame)
        local character = player.Character
        if not character then return end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        hrp.CFrame = cf
    end

    ------------------------------------------------------------
    -- Spawner loop. Cycles through the 3 test types every 3 waves,
    -- ramping RunDifficultyMult each wave. Stops when State.active
    -- flips false (heart death / manual exit).
    ------------------------------------------------------------
    local function spawnWave(testType: string, wave: number)
        local fn = TEST_TYPES[testType]
        if not fn then return end
        local groups = fn(wave)
        local waypoints = ctx.getWaypoints()
        if not waypoints or #waypoints == 0 then
            warn("[Infinite] no waypoints — map 4 not active?")
            return
        end
        for _, group in ipairs(groups) do
            for _ = 1, group.count do
                if not State.active then return end
                local mob = ctx.makeMob(group.mobType, waypoints, 1.0)
                if mob then
                    mob:SetAttribute("MapId", 4)
                end
                -- Tiny stagger between mobs in a group so they don't
                -- spawn in the exact same frame (= same Position).
                task.wait(0.08)
            end
        end
    end

    local function startSpawnerLoop(myToken: number)
        task.spawn(function()
            local diff = (Config.Map4 and Config.Map4.Difficulty) or {}
            local intervalSec = diff.IntervalSec or 8
            local hpPerRound = diff.HpPerRound or 1.10
            while State.active and State.spawnerToken == myToken do
                State.wave = State.wave + 1
                local testType = testTypeForWave(State.wave)
                -- Set the run-difficulty multiplier BEFORE spawning so
                -- MobFactory.makeMob picks it up (mob HP ramps per wave).
                Workspace:SetAttribute("RunDifficultyMult",
                    math.pow(hpPerRound, State.wave - 1))
                if State.activePlayer then
                    roundRemote:FireClient(State.activePlayer, {
                        wave     = State.wave,
                        testType = testType,
                    })
                end
                print(("[Infinite] wave %d (%s, HpMult=%.2f)"):format(
                    State.wave, testType,
                    Workspace:GetAttribute("RunDifficultyMult") or 1))
                spawnWave(testType, State.wave)
                if not State.active or State.spawnerToken ~= myToken then break end
                GameTime.adaptiveWait(intervalSec, function()
                    return State.active and State.spawnerToken == myToken
                end)
            end
        end)
    end

    local function stopSpawner()
        State.active = false
        State.spawnerToken = State.spawnerToken + 1
        if State.heartConn then
            State.heartConn:Disconnect()
            State.heartConn = nil
        end
        Workspace:SetAttribute("RunDifficultyMult", 1.0)
        if ctx.clearAllMobs then ctx.clearAllMobs() end
    end

    local function exit(player: Player)
        if not player or not player.Parent then return end
        -- Run-end summary BEFORE we tear state down. Headline = which
        -- wave the heart died on + which test type was running:
        -- "failed at wave 12 (AOE)". Then the per-tower stat ledger
        -- summary follows.
        if State.wave > 0 then
            print(("[Infinite] -------- run summary -------- failed at wave %d (%s)"):format(
                State.wave, testTypeForWave(State.wave)))
        else
            print("[Infinite] -------- run summary -------- (no waves run)")
        end
        if ctx.statLedger then
            print(ctx.statLedger.summary())
            ctx.statLedger.reset()
        end
        stopSpawner()
        State.activePlayer = nil
        State.wave = 0
        -- Restore StageState to map 1 (hub default) so the wave system's
        -- getHeart / getWaypoints stop resolving to Map4. Fire SwitchMap
        -- with noAutoWaves so we don't kick off a wave on map 1 either.
        local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        if switchMapBindable then
            switchMapBindable:Fire({
                mapId = 1,
                mapName = "Crook of the Tree",
                noAutoWaves = true,
            })
        end
        exitRemote:FireClient(player, {
            fadeOutSec = EXIT_FADE_OUT_SEC,
            holdSec    = 0.3,
            fadeInSec  = 0.6,
        })
        task.delay(EXIT_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getHubSpawnCF())
        end)
        print(("[Infinite] %s returned to hub"):format(player.Name))
    end

    local function hookHeartDeath()
        if State.heartConn then State.heartConn:Disconnect() end
        local heart = ctx.map4Heart
        if not heart then return end
        State.heartConn = heart:GetAttributeChangedSignal("Health"):Connect(function()
            if not State.active then return end
            local hp = heart:GetAttribute("Health") or 0
            if hp <= 0 and State.activePlayer then
                print("[Infinite] heart at 0 — ending run")
                exit(State.activePlayer)
            end
        end)
    end

    local function enter(player: Player, _scenario: string?)
        -- Legacy `scenario` arg is ignored — every run cycles through
        -- AOE / Combined / Solo by wave % 3. The arg is kept on the
        -- API shape so future loadout-panel handlers can pass extra
        -- payload (loadout list, slider value, A/B mode flag) without
        -- a remote-shape change.
        if not player or not player.Parent then return end
        if State.active then
            -- Reject overlapping enters; current architecture is single-player.
            warn(("[Infinite] %s tried to enter while a run was active"):format(player.Name))
            return
        end

        State.active        = true
        State.activePlayer  = player
        State.wave          = 0
        State.spawnerToken  = State.spawnerToken + 1
        local myToken = State.spawnerToken

        -- Switch the wave system's active map to 4 via SwitchMap
        -- bindable. Hub-ctx.StageState ≠ WaveSystem-ctx.StageState
        -- (separate scripts, separate context tables) — we need the
        -- bindable's published handler to write WaveSystem's state
        -- so getHeart / getWaypoints / mob update / tower fire all
        -- resolve to Map4.
        --
        -- noAutoWaves=true short-circuits the wave system's 6.5s
        -- auto-runWave so it doesn't kick off regular WAVES[1]
        -- spawning on top of our custom Infinite spawner.
        local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        if switchMapBindable then
            switchMapBindable:Fire({
                mapId = 4,
                mapName = "Pickle Swamp",
                noAutoWaves = true,
            })
        else
            warn("[Infinite] SwitchMap bindable missing — wave system not booted yet?")
        end

        -- Reset the stat ledger so this run's stats start clean.
        if ctx.statLedger then ctx.statLedger.reset() end

        -- Heart full HP at run start (in case prior run damaged it
        -- and the heart wasn't auto-restored).
        if ctx.map4Heart then
            local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
            ctx.map4Heart:SetAttribute("Health", maxHp)
        end

        -- Lazy-build the return portal (first entry only).
        if ctx.map4Room then
            setupReturnPortal(ctx.map4Room, getMap4SpawnCF(), exit)
        end

        -- Cinematic + teleport.
        enterRemote:FireClient(player, {
            fadeOutSec = ENTRY_FADE_OUT_SEC,
            holdSec    = 0.4,
            fadeInSec  = 0.8,
        })
        task.delay(ENTRY_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getMap4SpawnCF())
            grantLoadout(player)
            hookHeartDeath()
            startSpawnerLoop(myToken)
        end)
        print(("[Infinite] %s entered the pickle dimension (3-wave loop)"):format(
            player.Name))
    end

    -- Loadout-panel handler. Future payload (loadout list, slider
    -- value, A/B mode flag) is captured but not yet acted on; the
    -- scenario name is informational since every run cycles all 3
    -- test types via wave % 3.
    pickRemote.OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= "table" then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s entered loadout panel but Infinite is locked"):format(player.Name))
            return
        end
        enter(player, payload.scenario)
    end)

    -- Player leaving mid-run cleanup: stop the spawner, clear mobs,
    -- print summary. Otherwise the spawner keeps spawning into an
    -- empty map4 with no audience until the heart eventually dies.
    Players.PlayerRemoving:Connect(function(player)
        if State.activePlayer == player then
            print(("[Infinite] %s left mid-run — tearing down"):format(player.Name))
            if State.wave > 0 then
                print(("[Infinite] -------- run summary -------- "
                    .. "(player left at wave %d / %s)"):format(
                    State.wave, testTypeForWave(State.wave)))
                if ctx.statLedger then
                    print(ctx.statLedger.summary())
                    ctx.statLedger.reset()
                end
            end
            stopSpawner()
            State.activePlayer = nil
            State.wave = 0
        end
    end)

    ctx.enterInfinite = enter
    ctx.exitInfinite  = exit

    print("[Infinite] system online (Workspace.InfiniteUnlocked = "
        .. tostring(Workspace:GetAttribute("InfiniteUnlocked")) .. ")")
end

return Infinite
