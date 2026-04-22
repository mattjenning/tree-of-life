# Tree of Life — Project Context for Claude Code

## What this project is

A Roblox tower defense game called "Tree of Life," being built collaboratively
by Matthew (Technical Director) and his 9-year-old daughter Lily (Art
Director, embedded playtester on iPad). Single-player, mobile-first.

**One-line pitch:** Climb a giant tree and defend its branches from food gone
bad, using towers, parkour, and the occasional pickle-powered exosuit.

## Repository layout

```
src/
  server/
    TreeOfLife_Hub.server.lua          # 3,800+ lines — hub world, TD room, map 2, ammo, player flow
    TreeOfLife_WaveSystem.server.lua   # 2,800+ lines — waves, mobs, towers, Phoenix, upgrades
    AttachmentStore.lua                # Persistent attachment data
  client/
    TreeOfLife_Client.client.lua       # 1,500+ lines — UI, hotbar, dev panel, modals
  shared/
    Remotes.lua                        # Single source of truth for all RemoteEvent / BindableEvent names
    Tags.lua                           # CollectionService tag constants
    Config.lua                         # Game-wide tuning values (grid, waves, towers, map 2, phoenix)
```

## Build system

Rojo serves files in `src/` to Roblox Studio. The Studio plugin must be
connected for live sync. Workflow:
1. `rojo serve` in a terminal
2. Studio: Plugins → Rojo → Connect
3. Edit files in VS Code or Claude Code
4. Auto-syncs to Studio in ~1s
5. F5 in Studio to playtest

## Key architectural conventions

1. **Lua resolves free variables at function-DEFINITION time, not call time.**
   This has bitten us multiple times. Functions that reference module-level
   locals must be defined AFTER those locals. Don't add forward-decl shims;
   restructure instead. See the comment block at the top of TreeOfLife_Hub.

2. **The hub file has hard dependency layers.** Stage lighting (L5) must
   stay above DevReset (L6) because DevReset calls cancelLightingTweens.
   See the layer comment at the top of TreeOfLife_Hub for the full list.

3. **Map 1 + Map 2 share one global grid.** Cols 0-59 are map 1; cols 60+
   are map 2. The Map2Stage namespace gathers stage-progression state
   (bush lobes, firefly list, staircase parts) so the StageAdvanced handler
   can drive them.

4. **Use shared modules for new constants.** When adding a new RemoteEvent,
   tag, or magic number, put it in src/shared/. Don't hardcode strings.

## Refactor plan in progress

The codebase is being incrementally refactored. Phases:

- [x] Phase 1a — Add shared modules (Remotes, Tags, Config). DONE.
- [x] Phase 1b — Migrate proof-of-concept usages. DONE.
- [ ] Phase 1c — Bulk migrate remaining string literals and magic numbers
      to use shared modules. NEXT.
- [ ] Phase 2 — Break up the 3,800-line hub file into focused modules:
      world/HubWorld.lua, world/TdRoom.lua, world/Map2.lua, world/Portal.lua,
      systems/Grid.lua, systems/StageVisuals.lua, systems/Map2StageVisuals.lua,
      systems/Ammo.lua, systems/DevRemotes.lua
- [ ] Phase 3 — Break up the 2,800-line wave system file similarly.
- [ ] Phase 4 — Tower system abstraction: src/shared/TowerTypes.lua so
      adding new tower types is just a table entry + optional model builder.
- [ ] Phase 5 — Map 2 gameplay parity: verify wave system end-to-end on
      map 2, add second tower type to validate TowerTypes pattern.

## Current outstanding gameplay issues

1. **Map 2 staircase doesn't grow between stages** — diagnostic prints
   added to applyMap2StageVisuals (TreeOfLife_Hub around line 2230-2330).
   Need to confirm whether stageAdvancedBindable fires for map 2 or if
   the per-part rise animation isn't matching unlockStages correctly.

2. **Skip wave on map 2** — recent fix added gameOverFired = false to
   SwitchMap handler; needs end-to-end verification.

3. **Phoenix attachment system** — works on map 1, not yet validated on map 2.

## Working style preferences

- Be direct. Ask clarifying questions when needed.
- Prioritize practical examples.
- Verify facts against current sources when accuracy matters.
- Cite reputable sources when accuracy is critical.
- Always test after structural changes (the Lua scope rules bite hard).
- Commit small. Phase 1's commits are good models — one focused change per commit.
- The user's daughter Lily playtests on iPad — keep mobile precision in mind
  for any UI/interaction work.

## Don't change without asking

- Phoenix system mechanics (cooldowns, timing, AOE radius)
- Mob HP multipliers per wave
- Staircase geometry constants (radius, step count) — these were tuned visually
- Stage unlock fractions (currently 0.05/0.25/0.60/1.00 per stage)
