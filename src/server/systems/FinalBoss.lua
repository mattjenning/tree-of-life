--[[
    FinalBoss.lua — Final-boss phase mini-game mechanics.

    When the boss HP crosses one of Config-driven thresholds (80%, 50%,
    25%) we IMMEDIATELY (per-trigger):
      1. Fire BossWindup to all clients (boss vibrates briefly, gives
         reaction time before the dots appear).
      2. After Config.finalBossWindupDuration game-seconds, fire BossPhase:
         4 tappable dots with a tap window.
      3. If the player taps all 4 within the window → BossTargetTap remote
         PUSHES a new entry to the player's rolling bonus-damage stack:
         (expiresAt, extraPct). Each entry is its own clock.
      4. If the window expires → BossPhaseMiss → no penalty.

    Per-trigger model — phases NEVER queue or block each other:
      The previous queue-and-drain design (one phase at a time, others
      wait their turn) failed at high game speed: the player's DPS could
      drop the boss past 50% and 25% during phase 1's tap window, and the
      delayed "next phase" would fire AFTER the boss had already passed
      both thresholds. Net effect: phases firing at 80/30/0% instead of
      80/50/25%.

      New design: each threshold crossing kicks off its own task that runs
      windup → BossPhase → speed lock → safety release independently.
      Multiple sets of dots can be on screen simultaneously; the player
      can tap whichever they reach. Fires at the right HP every time.

    Bonus-damage rolling stack (per Matthew, 2026-04):
      Each successful tap adds a NEW entry to the player's stack with its
      own expiresAt. Tower damage multiplier while ≥1 entry is live =
      finalBossBonusMultiplier + sum(extraPcts of active entries).

      Example: phase 1 tap @ 25% speed → entry A (5s, 0.25). During A,
      damage mult = 2.0 + 0.25 = ×2.25. Phase 2 tap 3s later @ 38% →
      pushes entry B (5s, 0.38). For 2s of overlap, mult = 2.0 + 0.25 +
      0.38 = ×2.63 ("100% + 25% + 38%" in player notation). When A
      expires, mult drops to 2.0 + 0.38 = ×2.38. When B expires, no
      bonus → ×1.0. Replaces the prior single (until, extraPct) pair
      where re-tapping clobbered the existing bonus.

    setup(ctx) reads:
      ctx.WaveConfig.finalBossPhaseThresholds / finalBossTargetsPerPhase /
         finalBossTargetWindow / finalBossWindupDuration /
         finalBossBonusDuration / finalBossBonusMultiplier /
         finalBossWebDuration
      ctx.StageState.finalBossActive   (guards remote handlers)
      ctx.gameSpeed                     (BossTargetTap: bonus expiry is game-time)

    Publishes:
      ctx.FinalBossState        (mutable; resetFinalBossState wipes it)
      ctx.checkPhaseTrigger(mob, data)
         -- called from damageMob after each HP tick; fires phases for
            every threshold the boss has just crossed below.
      ctx.tickPhaseWindup()
         -- legacy no-op kept for MobUpdate's existing call site. The
            per-trigger model owns its windup timer per-task.
      ctx.bonusDamageMult(player)
         -- Towers.lua calls per-shot. Returns (multiplier, hasBonus).
            Lazily prunes expired stack entries.
      ctx.clearPlayerBonus(player)
         -- Dev-reset hooks call this to wipe the player's stack.

    BossTargetTap and BossPhaseMiss remote handlers are registered inside
    setup() and don't need to be called from the orchestrator.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Remotes  = require(Shared:WaitForChild("Remotes"))
local GameTime = require(Shared:WaitForChild("GameTime"))

local FinalBoss = {}

function FinalBoss.setup(ctx)
    local FinalBossState = {
        instance        = nil,   -- Part reference to the final boss while alive
        triggeredPhases = {},    -- set of threshold indices already fired (per boss instance)
        bonusEntries    = {},    -- [player] = { {expiresAt, extraPct}, ... } rolling stack
        -- Ordered FIFO array of {released = bool, fn = release-closure}.
        -- Each phase fire pushes one entry; tap-success pops the OLDEST
        -- (table.remove(arr, 1)) so cleared dots restore game speed; the
        -- safety timer pops self on timeout if the player never taps.
        activeLocks     = {},
        windupUntil     = 0,     -- LATEST end-time across all active windups; MobUpdate freezes the boss while now < this
    }
    ctx.FinalBossState = FinalBossState

    -- Canonical reset: every spawn-fresh-boss / SwitchMap / GameOver path
    -- routes through here. Releases any speed locks currently held by
    -- in-flight phase tasks (otherwise a reset mid-windup would leak the
    -- 1× lock and pin gs at 1× indefinitely). Also wipes the bonus stack
    -- so a new run starts cold.
    ctx.resetFinalBossState = function()
        for _, entry in ipairs(FinalBossState.activeLocks) do
            if entry and not entry.released then
                entry.released = true
                entry.fn()
            end
        end
        FinalBossState.instance        = nil
        FinalBossState.triggeredPhases = {}
        FinalBossState.bonusEntries    = {}
        FinalBossState.activeLocks     = {}
        FinalBossState.windupUntil     = 0
    end

    local remoteBossPhase     = Remotes.getOrCreate(Remotes.Names.BossPhase,     "RemoteEvent")
    local remoteBossWindup    = Remotes.getOrCreate(Remotes.Names.BossWindup,    "RemoteEvent")
    local _remoteBossWeb      = Remotes.getOrCreate(Remotes.Names.BossWeb,       "RemoteEvent")
    local remoteBossTargetTap = Remotes.getOrCreate(Remotes.Names.BossTargetTap, "RemoteEvent")
    local remoteBossPhaseMiss = Remotes.getOrCreate(Remotes.Names.BossPhaseMiss, "RemoteEvent")

    -- Per-trigger phase fire. Spawned as its own task; multiple can run
    -- in parallel without coordinating. Each owns its speed-lock release.
    local function startPhase(phaseIdx, bossMob)
        local windupSec = ctx.WaveConfig.finalBossWindupDuration / GameTime.speed()
        local now = os.clock()
        -- MobUpdate.lua's "freeze the boss during windup" check reads
        -- FinalBossState.windupUntil. Track the LATEST end-time across
        -- every active windup so the boss stays frozen while ANY phase
        -- is still in its vibrate stage. When the latest windup elapses,
        -- now < windupUntil flips false and the boss resumes pathing.
        local thisWindupEnd = now + windupSec
        if thisWindupEnd > FinalBossState.windupUntil then
            FinalBossState.windupUntil = thisWindupEnd
        end
        remoteBossWindup:FireAllClients({
            phase        = phaseIdx,
            duration     = windupSec,
            bossPosition = bossMob.Position,
        })
        task.spawn(function()
            task.wait(windupSec)
            -- Boss died during windup? skip the fire — don't strew dots
            -- over the death-cinematic / temp-tower picker.
            if FinalBossState.instance ~= bossMob or not bossMob.Parent then return end
            local bossPos = bossMob.Position
            remoteBossPhase:FireAllClients({
                phase         = phaseIdx,
                targetCount   = ctx.WaveConfig.finalBossTargetsPerPhase,
                window        = ctx.WaveConfig.finalBossTargetWindow,
                bonusDuration = ctx.WaveConfig.finalBossBonusDuration,
                bossPosition  = bossPos,
                webDuration   = ctx.WaveConfig.finalBossWebDuration,
            })
            -- Each fire grabs its own speed lock and pushes it onto the
            -- FIFO array. Tap-success pops the OLDEST entry (clearing a
            -- set of dots restores one tier of speed); safety timer
            -- catches the case where the player never finishes a tap
            -- window. Idempotent via `released` flag — the safety + the
            -- tap-pop can race without double-releasing.
            local entry = { released = false, fn = GameTime.lockSpeed() }
            table.insert(FinalBossState.activeLocks, entry)
            local safetySec = (ctx.WaveConfig.finalBossTargetWindow or 4)
                            + (ctx.WaveConfig.finalBossWebDuration or 0)
                            + 1.0
            task.delay(safetySec, function()
                if not entry.released then
                    entry.released = true
                    entry.fn()
                end
                for i, e in ipairs(FinalBossState.activeLocks) do
                    if e == entry then
                        table.remove(FinalBossState.activeLocks, i)
                        break
                    end
                end
            end)
        end)
    end

    -- Called from damageMob after each HP tick. For every untriggered
    -- threshold the boss has just passed below, fire that phase
    -- IMMEDIATELY. No queue, no blocking, no gating on whether other
    -- phases are already up. At 10× DPS the player can drop past all 3
    -- in one tick — this fires all 3 in parallel, each with its own
    -- windup + tap window.
    local function checkPhaseTrigger(mob, data)
        if mob ~= FinalBossState.instance then return end
        if data.hp <= 0 then return end
        local hpFrac = data.hp / data.maxHp
        for i, threshold in ipairs(ctx.WaveConfig.finalBossPhaseThresholds) do
            if hpFrac <= threshold and not FinalBossState.triggeredPhases[i] then
                FinalBossState.triggeredPhases[i] = true
                startPhase(i, mob)
            end
        end
    end

    -- Legacy hook: MobUpdate calls this every frame. The pre-overlap
    -- model used it to fire windups whose timer just expired. Now each
    -- fire owns its own task.delay, so this is a no-op kept for the
    -- existing call site.
    local function tickPhaseWindup() end

    -- Towers.lua calls this each shot. Returns (multiplier, hasBonus).
    -- multiplier = finalBossBonusMultiplier + sum(active extraPcts) when
    -- hasBonus is true; otherwise (1.0, false). Lazily prunes expired
    -- entries so the stack doesn't grow unbounded over a long fight.
    local function bonusDamageMult(player)
        local entries = FinalBossState.bonusEntries[player]
        if not entries then return 1.0, false end
        local now = os.clock()
        local i = 1
        while i <= #entries do
            if entries[i].expiresAt <= now then
                table.remove(entries, i)
            else
                i = i + 1
            end
        end
        if #entries == 0 then
            FinalBossState.bonusEntries[player] = nil
            return 1.0, false
        end
        local sumExtras = 0
        for _, e in ipairs(entries) do
            sumExtras = sumExtras + e.extraPct
        end
        return ctx.WaveConfig.finalBossBonusMultiplier + sumExtras, true
    end
    ctx.bonusDamageMult = bonusDamageMult

    -- Dev hook: clear a player's stack on full reset. Used by
    -- DevRemotes.RunReset and DevTowerHandlers.ResetCooldowns.
    local function clearPlayerBonus(player)
        FinalBossState.bonusEntries[player] = nil
    end
    ctx.clearPlayerBonus = clearPlayerBonus

    -- Tap success: PUSH a new entry to the player's rolling stack. Each
    -- entry expires on its own clock; multiplier = base + sum(active
    -- extraPcts) while ≥1 entry is live. Per Matthew's 2026-04 design,
    -- this is the chained-bonus model: phase 1 + phase 2 overlap reaches
    -- a higher peak than either alone, and the bonus decays in chunks
    -- as each entry's window expires.
    remoteBossTargetTap.OnServerEvent:Connect(function(player, payload)
        if not ctx.StageState.finalBossActive then return end
        local now = os.clock()
        local durationSec = ctx.WaveConfig.finalBossBonusDuration / ctx.gameSpeed
        local bonusPct = 0
        if type(payload) == "table" and type(payload.bonusPct) == "number" then
            bonusPct = math.clamp(payload.bonusPct, 0, 100)
        end
        local entries = FinalBossState.bonusEntries[player]
        if not entries then
            entries = {}
            FinalBossState.bonusEntries[player] = entries
        end
        table.insert(entries, {
            expiresAt = now + durationSec,
            extraPct  = bonusPct / 100,
        })
        -- Pop the oldest active speed lock — clearing a set of dots
        -- restores one tier of game speed. With overlapping phases the
        -- player has to clear them all to fully recover (FIFO: oldest
        -- lock first); safety timer cleans up any phase the player
        -- never completes. Per Matthew (2026-04): "return to previous
        -- speed after the dots are cleared."
        local lockEntry = table.remove(FinalBossState.activeLocks, 1)
        if lockEntry and not lockEntry.released then
            lockEntry.released = true
            lockEntry.fn()
        end
        print(("[Waves] %s tapped boss minigame → +%.1fs bonus, +%d%% speed (stack depth: %d, locks remaining: %d)"):format(
            player.Name, durationSec, bonusPct, #entries, #FinalBossState.activeLocks))
    end)

    -- Tap window expired without all dots tapped. No penalty in current
    -- design — kept wired so future iterations can reinstate one without
    -- reshuffling the connection graph.
    remoteBossPhaseMiss.OnServerEvent:Connect(function(player)
        if not ctx.StageState.finalBossActive then return end
        print(("[Waves] %s missed boss phase — no bonus, no penalty"):format(player.Name))
    end)

    ctx.checkPhaseTrigger = checkPhaseTrigger
    ctx.tickPhaseWindup   = tickPhaseWindup
end

return FinalBoss
