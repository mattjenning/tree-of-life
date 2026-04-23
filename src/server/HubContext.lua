--[[
    HubContext.lua — Shared mutable-state table used by every extracted
    hub module.

    WHY THIS EXISTS:
    The hub used to be one 3,800-line file where everything shared
    module-level locals (tdRoom, gridState, Map2Stage, treeBase, etc.).
    Phase 2 broke that file into focused modules under world/ and
    systems/. Those modules need to share state without resorting to:

      - Circular requires (Roblox Lua doesn't handle them well)
      - Forward-declared globals (exactly the bug class Phase 1 removed)
      - Deep parameter threading (every setup function taking 12 args)

    Instead, TreeOfLife_Hub.server.lua creates ONE HubContext table at
    startup, passes it to each module's `setup(ctx)` function in the
    correct dependency order, and each module writes the public fields
    it owns onto ctx. Later modules read from ctx to wire up their
    own handlers.

    FIELDS (populated in setup order):

    After Grid.setup(ctx):
      ctx.gridState      -- 2D table [col][row] → "open"|"path"|"heart"|...
      ctx.cellToWorld    -- function(col, row) → Vector3

    After HubWorld.setup(ctx):
      ctx.hub            -- Model (parent for hub-world geometry)
      ctx.treeBase       -- Vector3 anchor for the giant tree
      ctx.trunkSurfaceZ  -- number, used by Portal for spawn placement

    After TdRoom.setup(ctx):
      ctx.tdRoom         -- Model (parent for TD-room geometry + towers)
      ctx.floor          -- Part, TD floor (tweened by StageVisuals)
      ctx.rc             -- Vector3, room center (for grid math)

    After Map2.setup(ctx):
      ctx.map2Room                -- Model
      ctx.map2Heart               -- Part
      ctx.MAP2_PLAYER_SPAWN_CF    -- CFrame
      ctx.MAP2_AMMO_SW_POS        -- Vector3
      ctx.MAP2_AMMO_SE_POS        -- Vector3
      ctx.Map2Stage               -- namespace table with:
                                  --   .stairParts       (array)
                                  --   .bushLobes        (array)
                                  --   .fireflies        (array)
                                  --   .baseStairTotalHeight
                                  --   .stairStepCount
                                  --   .stageUnlockFractions

    After StageVisuals.setup(ctx) + Map2StageVisuals.setup(ctx):
      ctx.cancelLightingTweens    -- function() — called by DevRemotes
      ctx.tweenStageLighting      -- function(stage)
      ctx.applyMap2StageVisuals   -- function(stage, animate)
      ctx.applyMap2Stage1OnEntry  -- function() — called by Portal

    After Ammo.setup(ctx):
      ctx.ammoPiles               -- array of {glow, prompt, ...}
      ctx.wireTowerLoadPrompt     -- function(tower) — called by tower placer

    Portal.setup(ctx) and DevRemotes.setup(ctx) are pure consumers —
    they attach handlers and don't add new fields.

    INVARIANTS:
      - No module reads a field before the producing module has run.
      - Field reads use ctx.fieldName (never cached into a local at
        module scope, because that capture happens at require time,
        before setup has run).
      - setup() is the ONLY exported function per module. No other
        side effects on require — modules are inert until setup() runs.
]]

local HubContext = {}

--- Create a fresh, empty context. Called once at the top of the hub
--- server script. Fields are populated in-place by each module's setup.
function HubContext.new(): {[string]: any}
    return {}
end

return HubContext
