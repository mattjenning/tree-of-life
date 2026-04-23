--[[
    FinalBoss.lua — Final-boss (Pickle Lord) phase mini-game mechanics.

    When the boss HP crosses one of Config-driven thresholds (75%, 50%,
    25%) we:
      1. Begin a short windup (Config.finalBossWindupDuration seconds)
         where the boss stops + vibrates — gives the player reaction
         time. Client renders the vibration.
      2. When windup completes, fire BossPhase to all clients with
         4 tappable targets + a tap window.
      3. If the player taps all 4 within the window → BossTargetTap
         remote fires → grant bonusDamage for finalBossBonusDuration
         game-seconds.
      4. If the window expires with incomplete taps → BossPhaseMiss
         remote fires → BossWeb overlay + movement freeze for the player.

    Phases never overlap: the trigger check short-circuits if another
    phase is already windup-ing, tap-window-open, or pending.

    setup(ctx) reads:
      ctx.WaveConfig.finalBossPhaseThresholds / finalBossTargetsPerPhase
         / finalBossTargetWindow / finalBossWindupDuration
         / finalBossBonusDuration / finalBossBonusMultiplier
         / finalBossWebDuration
      ctx.StageState.finalBossActive   (guards remote handlers)
      ctx.gameSpeed                     (BossTargetTap: bonus expiry is game-time)

    And publishes:
      ctx.FinalBossState        (mutable table; hub resets fields on run reset)
      ctx.checkPhaseTrigger(mob, data)
         -- called from damageMob after each HP tick; triggers windup
            when a new threshold is crossed.
      ctx.tickPhaseWindup()
         -- called from updateMobs once per frame; fires BossPhase if a
            pending phase's windup has elapsed.

    BossTargetTap and BossPhaseMiss remote handlers are registered inside
    setup() and don't need to be called from the orchestrator.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local FinalBoss = {}

function FinalBoss.setup(ctx)
    local FinalBossState = {
        instance        = nil,   -- Part reference to the final boss while alive
        triggeredPhases = {},    -- set of threshold indices already fired
        lastPhaseFire   = 0,     -- os.clock() of the most recent BossPhase fire
        windupUntil     = 0,     -- os.clock() value; while now < this, boss is stopped + vibrating
        pendingPhase    = nil,   -- phase index to fire when windup completes (nil otherwise)
    }
    ctx.FinalBossState = FinalBossState

    -- getOrCreate guarantees the Remote exists in ReplicatedStorage before
    -- we return, so we don't need the orchestrator to pre-seed them via
    -- ensureRemote. FinalBoss.lua is fully self-contained on its remotes.
    local remoteBossPhase     = Remotes.getOrCreate(Remotes.Names.BossPhase,     "RemoteEvent")
    local remoteBossWindup    = Remotes.getOrCreate(Remotes.Names.BossWindup,    "RemoteEvent")
    local remoteBossWeb       = Remotes.getOrCreate(Remotes.Names.BossWeb,       "RemoteEvent")
    local remoteBossTargetTap = Remotes.getOrCreate(Remotes.Names.BossTargetTap, "RemoteEvent")
    local remoteBossPhaseMiss = Remotes.getOrCreate(Remotes.Names.BossPhaseMiss, "RemoteEvent")

    -- Called from damageMob after each HP tick. If the damaged mob is the
    -- active final boss and its HP fraction just crossed a new threshold,
    -- start the windup. Designed to NOT backfire earlier phases if the
    -- boss took a huge HP drop past multiple thresholds — walks the
    -- threshold list and picks the LOWEST (deepest) untriggered one.
    local function checkPhaseTrigger(mob, data)
        if mob ~= FinalBossState.instance then return end
        if data.hp <= 0 then return end

        local hpFrac = data.hp / data.maxHp
        local now = os.clock()
        -- A phase is "active" if it's either winding up OR the tap window is open.
        local windupActive = now < FinalBossState.windupUntil
        local tapWindowActive = (now - FinalBossState.lastPhaseFire) < ctx.WaveConfig.finalBossTargetWindow
        local phaseActive = windupActive or tapWindowActive or FinalBossState.pendingPhase ~= nil
        if phaseActive then return end

        -- Find the LOWEST threshold (deepest into HP) that's been met but
        -- not yet triggered.
        local fireIndex = nil
        for i, threshold in ipairs(ctx.WaveConfig.finalBossPhaseThresholds) do
            if hpFrac <= threshold and not FinalBossState.triggeredPhases[i] then
                fireIndex = i  -- keep overwriting; last one wins = deepest
            end
        end
        if not fireIndex then return end

        -- Mark every untriggered threshold up to and including this one
        -- as triggered, so we don't backfire earlier phases.
        for i = 1, fireIndex do
            FinalBossState.triggeredPhases[i] = true
        end
        -- Start the wind-up. Actual BossPhase (tap spots) fires later
        -- when tickPhaseWindup sees windupUntil has elapsed. Pass the
        -- boss position to the client so it knows where to launch
        -- spots FROM.
        FinalBossState.windupUntil  = now + ctx.WaveConfig.finalBossWindupDuration
        FinalBossState.pendingPhase = fireIndex
        remoteBossWindup:FireAllClients({
            phase        = fireIndex,
            duration     = ctx.WaveConfig.finalBossWindupDuration,
            bossPosition = mob.Position,
        })
    end

    -- Called once per frame from updateMobs. If a phase is pending and
    -- the wind-up has elapsed, fire BossPhase to all clients.
    local function tickPhaseWindup()
        if not FinalBossState.pendingPhase then return end
        local now = os.clock()
        if now < FinalBossState.windupUntil then return end

        local boss = FinalBossState.instance
        local bossPos = (boss and boss.Parent) and boss.Position or nil
        FinalBossState.lastPhaseFire = now
        remoteBossPhase:FireAllClients({
            phase         = FinalBossState.pendingPhase,
            targetCount   = ctx.WaveConfig.finalBossTargetsPerPhase,
            window        = ctx.WaveConfig.finalBossTargetWindow,
            bonusDuration = ctx.WaveConfig.finalBossBonusDuration,
            bossPosition  = bossPos,
            webDuration   = ctx.WaveConfig.finalBossWebDuration,
        })
        FinalBossState.pendingPhase = nil
    end

    -- Client fires once when ALL 4 blobs tapped in time → grants
    -- finalBossBonusDuration game-seconds of bonus damage. No stacking.
    remoteBossTargetTap.OnServerEvent:Connect(function(player)
        if not ctx.StageState.finalBossActive then return end
        local now = os.clock()
        -- Same correctness fix as the stun timer: bonus damage should last
        -- finalBossBonusDuration GAME-seconds. Divide by gameSpeed so the
        -- wallclock window shrinks proportionally at 2x/3x/5x/10x.
        local until_ = now + (ctx.WaveConfig.finalBossBonusDuration / ctx.gameSpeed)
        -- Don't shorten an existing longer bonus; otherwise extend.
        local existing = player:GetAttribute("BonusDamageUntil") or 0
        if existing < until_ then
            player:SetAttribute("BonusDamageUntil", until_)
        end
        print(("[Waves] %s completed boss minigame → %.1fs game-time bonus"):format(
            player.Name, ctx.WaveConfig.finalBossBonusDuration))
    end)

    -- Client fires this when the tap window expires without all spots tapped.
    -- Server broadcasts BossWeb back to that player for the web overlay and
    -- movement freeze. The client handles the actual movement block — server
    -- trusts it because the penalty is cosmetic/QoL, not a loophole.
    remoteBossPhaseMiss.OnServerEvent:Connect(function(player)
        if not ctx.StageState.finalBossActive then return end
        remoteBossWeb:FireClient(player, {
            duration = ctx.WaveConfig.finalBossWebDuration,
        })
        print(("[Waves] %s missed boss phase → webbed for %ds"):format(
            player.Name, ctx.WaveConfig.finalBossWebDuration))
    end)

    ctx.checkPhaseTrigger = checkPhaseTrigger
    ctx.tickPhaseWindup   = tickPhaseWindup
end

return FinalBoss
