--[[
    WaveCtxBridge.lua — singleton ModuleScript that bridges
    WaveSystem-ctx to consumers running in OTHER server scripts.

    WHY THIS EXISTS:
    The Hub script and the WaveSystem script each create their own
    WaveContext table. ModuleScripts under server/systems/ get setup'd
    by ONE of those two scripts and only see THAT script's ctx. Most
    of the time that's fine — DevRemotes lives in Hub and reads
    Hub-published fields, MobFactory lives in WaveSystem and reads
    WaveSystem-published fields.

    The Infinite Studio breaks this rule: it lives in Hub (because it
    needs Map4-side state like map4Heart / MAP4_PLAYER_SPAWN_CF that
    Hub publishes), but it ALSO needs WaveSystem-side functions like
    makeMob / getWaypoints / activeMobs / clearAllMobs. Without this
    bridge, Hub.ctx.makeMob is nil and the spawner crashes on first
    invocation.

    Lua's `require` cache makes ModuleScripts singletons across an
    entire game-server's script ecosystem, so anything written to
    Bridge.ctx by one script is visible to any other script that
    requires the module.

    USAGE:
      Producer (TreeOfLife_WaveSystem.server.lua, end of setup):
          local WaveCtxBridge = require(script.Parent:WaitForChild("WaveCtxBridge"))
          WaveCtxBridge.ctx = ctx

      Consumer (any module running outside the wave system script):
          local WaveCtxBridge = require(...:WaitForChild("WaveCtxBridge"))
          local waveCtx = WaveCtxBridge.ctx
          if waveCtx then
              waveCtx.makeMob(...)
          end

    Always nil-check `Bridge.ctx` — the consumer may run before
    the wave system finishes setup. Standard pattern in Infinite.lua's
    spawner: nil-check + warn + early-return.
]]

local Bridge = {}

-- Set ONCE by TreeOfLife_WaveSystem after its full setup chain completes.
-- Consumers read Bridge.ctx.X (where X is any field MobFactory / Targeting /
-- etc. published onto the wave context).
Bridge.ctx = nil

return Bridge
