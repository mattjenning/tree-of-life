--[[
    WaveContext.lua — Shared mutable-state table used by every extracted
    wave-system module. Mirrors the HubContext pattern established in
    Phase 2 for the hub file.

    WHY THIS MODULE EXISTS:
    TreeOfLife_WaveSystem.server.lua used to be a 2,837-line script where
    everything shared module-level locals (activeMobs, StageState,
    FinalBossState, WaveConfig, PhoenixGrace/Queue, etc.). Phase 3
    breaks it into focused modules under src/server/systems/. Those
    modules need to share state and call each other without:
      - Circular requires
      - Deep parameter threading (setup fns taking 10+ args)
      - Forward-decl globals that get resolved at function-definition
        time (the exact bug class Phase 1 removed)

    TreeOfLife_WaveSystem.server.lua creates ONE WaveContext table at
    startup, passes it to each module's `setup(ctx)` in dependency
    order. Each module reads the fields set by earlier modules and
    writes its own public outputs onto ctx. Later modules and the
    orchestrator itself call through ctx.functionName(...) for
    late-resolved lookups that survive extraction order.

    FIELDS (populated in setup order; this doc is the contract):

    Populated by the orchestrator BEFORE any module.setup runs:
      ctx.Tags, ctx.Remotes, ctx.Config          -- shared require handles
      ctx.WaveConfig                             -- local wave tuning table
      ctx.StageState                             -- mutable stage tracking
      ctx.Stages, ctx.WAVES, ctx.MOB_TYPES       -- static config tables
      ctx.FinalBossState                         -- mutable boss-fight state
      ctx.Speed                                  -- wrapper for gameSpeed so
                                                    extracted modules see
                                                    the current value even
                                                    after SetGameSpeed remote
                                                    mutates the upvalue

    After UpgradeCards.setup(ctx):
      ctx.generateCardsForPlayer(player, waveIndex) → payload
      ctx.applyUpgrade(player, upgrade)
      ctx.simulateOnePick(player)                -- used by DevSkipToBoss
      ctx.applyStunStackToOwnedTowers(player)    -- used by DevAddStun
      ctx.rollRarity, ctx.getTierColor           -- shared utilities
      ctx.RARITY_TO_SCORE                        -- rarity weight map

    After the remaining systems/ setups run, ctx also carries:
      ctx.findTarget                              (Targeting)
      ctx.spawnDamageNumber / fireBolt /
        spawnAoeBurst / spawnDetonatorBurst /
        applyHitEffects / spawnFireVFX /
        spawnPhoenixAOEFloorFire                  (Effects)
      ctx.updateTowers                            (Towers)
      ctx.activeMobs, ctx.makeMob                 (MobFactory)
      ctx.PhoenixGrace, ctx.PhoenixQueue,
        ctx.tryConsumePhoenix / capturePhoenixAOEMobs /
        processPhoenixQueue / tickPhoenixCooldowns (Phoenix)
      ctx.fireFinalBossPhase                      (FinalBoss)
      ctx.updateMobs                              (MobUpdate)
      ctx.damageMob                               (Damage)

    INVARIANTS:
      - No module reads a field before the producing module has run.
      - Fields are read via ctx.X at call time, not captured into
        module-level locals (late resolution is the whole point of the
        pattern — it lets Phoenix.capturePhoenixMob call ctx.damageMob
        even though Damage.setup runs 3 commits later).
      - setup() is the ONLY exported function per module. Modules are
        inert until setup() runs.
]]

local WaveContext = {}

--- Create a fresh, empty context. Called once at the top of the wave
--- system script. Fields are populated in-place by each module's setup.
function WaveContext.new(): {[string]: any}
    return {}
end

return WaveContext
