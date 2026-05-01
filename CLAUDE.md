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

## Tests + lint

In-house test harness lives at `src/server/tests/` (a `tests` ModuleScript
with sibling test files). Tests run automatically on every server boot
via `src/server/RunTests.server.lua` — output appears in the Studio
server log alongside the Rojo connect line:
```
[Tests] ✓ 28 passed
```
Or on failure:
```
[Tests] ✗ 27 passed, 1 FAILED
[Tests]   • Rarity.ColorFor unknown: ...
```
Adding a new test file: drop a `.lua` under `src/server/tests/`, require
`script.Parent` for the framework, register cases with `Tests.test(name, fn)`,
then add one `require(... :WaitForChild("YourFile"))` line in
`RunTests.server.lua` so its registrations run.

Lint + format: `selene` and `stylua` configs at the project root.
Install once (`cargo install selene stylua --features luau` or grab
binaries). Run from project root:
- `stylua --check src/` — formatter (CI-friendly check mode)
- `selene src/` — linter
Both should pass before committing. The configs intentionally allow
the codebase's existing patterns (shadowing in do-blocks, `print` for
server logs, etc.).

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

5. **Client script is at the Luau 200-register ceiling.** Each top-level
   `local` in `TreeOfLife_Client.client.lua` consumes one register; hitting
   200 causes "Out of local registers" compile errors. Current footprint
   hovers around 187. When adding new GUI code: wrap decorators (UICorner,
   UIStroke, UIListLayout, etc.) in `do ... end` so their slots release
   after configuration. Bundle related labels/buttons into one table local
   rather than N separate locals (see `hudLabels` for the pattern).
   Long-term fix is to extract modals into sibling ModuleScripts via
   Rojo — not yet done because it requires restructuring src/client/ as
   a directory.

6. **Hub-ctx and WaveSystem-ctx are SEPARATE tables.** The hub server
   script (`TreeOfLife_Hub.server.lua`) and the wave-system server script
   (`TreeOfLife_WaveSystem.server.lua`) each create their own
   WaveContext table. Modules in `src/server/systems/` get setup'd by
   ONE of those scripts and only see THAT script's ctx. Modules that
   need fields from the OTHER script's ctx read them via
   `src/server/WaveCtxBridge.lua` — a singleton ModuleScript that
   WaveSystem populates at end-of-setup and consumers in any other
   server script require + read. Late-resolved (`local function
   waveCtx() return Bridge.ctx end` then `waveCtx().X`) so the
   reference survives a hot-reload of the producer. The `Infinite`
   system runs in Hub but needs `makeMob`/`getWaypoints`/`activeMobs`
   from WaveSystem — that's the canonical bridge use case. New
   cross-script consumers should follow the same pattern; do NOT
   try to write to the wrong ctx (it'll silently land on the wrong
   table and the other side reads nil).

7. **`Config.InfiniteArena` is the single source of truth for sweep
   tuning.** The live spawner (`server/systems/Infinite.lua`) AND the
   closed-form simulator (`server/systems/InfiniteSimulator.lua`) both
   read the same `MaxAutoRunWave / CycleStep / LoadoutMult / Pools_C1
   / Upgrade / MobBaseline / AutoRunAnchor / PowerCoreStats` from
   `shared/Config.lua`. Before this consolidation, those values lived
   as duplicated literals in BOTH files — every tuning pass had to be
   applied twice and forgetting one half silently shifted the
   sim-vs-real validation deltas, masking actual model gaps. **DO
   NOT add new sweep constants as literals in either file.** Add to
   `Config.InfiniteArena` and read via `Config.InfiniteArena.X`. New
   tuning pass = one edit, both consumers see it, validation harness
   stays meaningful.

## Refactor plan in progress

The codebase is being incrementally refactored. Phases:

- [x] Phase 1 (a+b) — Add shared modules (Remotes, Tags, Config) +
      migrate proof-of-concept usages.
- [x] Phase 2 — Break up the 3,800-line hub file. Hub orchestrator is
      now ~800 lines; world/* and systems/* hold the rest.
- [x] Phase 3 — Break up the 2,800-line wave system file. Wave
      orchestrator is now ~1,600 lines; systems/* holds mob /
      towers / effects / phoenix / upgrade cards / boss fights /
      dev-tower handlers. Further splitting would fight the
      forward-declared orchestrator state (waveRunToken, currentWave,
      runWave, etc.) — acceptable stopping point.
- [x] Phase 4 — TowerTypes consolidation: Core data in
      shared/TowerTypes, aux data in shared/TempTowers, client
      footprints sync from shared at startup. Adding a tower now = one
      shared-data entry + TowerBuilders model fn + one client-UI def.
- [x] Phase D — Rarity palette consolidated into shared/Rarity; hardcoded
      "SetGameSpeed" literals swapped for Remotes.Names.X. Plus the
      earlier Phase 1c-style migrations (grid / map2 / phoenix already
      in Config).
- [ ] Phase 5 — Map 2 gameplay parity: verify wave system end-to-end on
      map 2. (Second tower type validation landed via the aux tower
      roster — 9 temp towers all use the TowerTypes+TempTowers pattern.)
- [x] Phase 6 — Code-cleanup pass (mechanical):
      6a UDim2 modernization (selene 392 → 75) — `scripts/fix_udim2.py`
      6b Dead-code purge (selene 75 → 0) — unused requires, locals,
         loop-vars, redundant `if_same_then_else`, deprecated
         `Instance.new(Class, Parent)` form
      6c Debug-print cleanup — pruned per-event spew left over from
         click-selection / smash / target-change bug hunts
      6d Bundled 30 grid-config top-level locals in init.client.lua
         into `mapCfg[mapId]` — frees ~25 register slots from the 200
         Luau ceiling. Pattern: `mapCfg[N] = {centerX, centerZ, width,
         depth, floorY, cols, rows, colOffset, totalCols, minX, minZ}`.
- [x] Phase 7 — Test coverage for high-risk modules:
      Targeting (8 tests), Grid (8), MapRegistry (6), StatLedger (6).
      67 → 95 tests at server boot. Each module mocks ctx with table-
      based mobs / waypoints — no Roblox Instance creation needed.
- [x] Phase 8 — Magic numbers → Config + difficulty hook:
      Targeting / UpgradeCards / Ammo / Effects / PickleLordBoss
      tuning constants moved into shared/Config sections. Added
      `Workspace.RunDifficultyMult` attribute that MobFactory.makeMob
      reads after landmark rounding (defaults 1.0 = no change). Future
      difficulty-tier UI just sets the attribute.
- [x] Phase 9 — Killed 6 `if mapId == 1/2/3` dispatch chains via
      `shared/MapRegistry.lua`. Underground map (mapId 4) is now a
      one-row append. Fields: key, displayName, bossType,
      playsRewardCutscene, splitTargets, placeAllCenter,
      difficultySection.
- [x] Phase 10 — Extracted `shared/BBoxUtil.lua`:
      `worldAxisBounds(model)` and `worldAxisFloorY(model)` collapse
      three pasted descendant-8-corner sweeps (towerUnderScreenPos,
      SelectionVisuals, TowerPlacement re-seat). Click hit-test and
      visual cube can no longer drift apart.
- [x] Phase 11 — Stat capture for Infinite sandbox (Phase 1):
      `server/systems/StatLedger.lua` records per-tower DPS / stun /
      slow / knockback / loadout. Damage hooks live; stun / slow / kb
      hooks deferred until the sandbox UI consumes them. Run-end
      summary prints to the server log on RunReset.
- [x] Phase 12 — Pristine pass + Balance Studio polish:
      • `Config.InfiniteArena` consolidated — sweep tuning that lived
        duplicated in `Infinite.lua` AND `InfiniteSimulator.lua` now
        lives in shared/Config.lua only. Both consumers read from
        there (see convention #7).
      • Two latent forward-decl bugs fixed (CLAUDE.md convention #1):
        `InfiniteMonitorWindow.stripPower` (bit on tower-row click)
        and `Infinite.exit` (bit on STOP RUN). Hoisted forward-decls
        + verbose comments explaining the resolution-time rule.
      • LOAD RUN → LOAD RUNS: balance-version stamping on every saved
        sweep + pure helpers `Store.groupByBalanceVersion` +
        `Store.mergeByBalanceVersion`. BALANCE RESET bumps the version
        counter, persists, and stamps subsequent runs. LOAD RUNS
        renders one row per era.
      • Test coverage bumped 95 → 124+ runs at server boot:
        `tests/InfiniteSimulator.lua` (5 cases) +
        `tests/InfiniteRunHistoryStore.lua` (10 cases). Pure helpers
        only — no DataStore mocking required.
      • selene + dead-code clean: 1 error + 6 warnings → 0/0.
        Removed orphaned `thoughtFor / diffAuxIds / obsState /
        TOWER_THOUGHTS` from `InfiniteMonitorWindow` (consumers
        gone for ~2 weeks per git history).
- [x] Phase 13 — 5-new-tower polish + cleanup pass (2026-04-28):
      • Extracted `src/shared/TowerCardData.lua` — DESCRIPTIONS,
        FLAVOR, and buildHighlightRows were duplicated byte-for-byte
        between `TowerCard.lua` (story) and `TowerInfoCard.lua`
        (Balance Studio). Now one source of truth; ~120 lines × 2
        files of duplication eliminated.
      • Stale-comment purge — references to AUTO RUN button, AUX
        AUTO button, LONG AUTO admin slot updated to reflect their
        2026-04-28 removal/relocation into the SIMULATE menu. Old
        BlinkBerry "MAX_BLINKS_PER_MOB cap" header replaced with the
        new stat-tuning loop-prevention math (cap was reverted).
      • Test coverage bumped 158 → 170+: `tests/TempTowers.lua`
        added regression guards for BlinkBerry hard-nerf stats,
        all 3 aux Support buff towers' aura fields, BloodlinkVine
        link mechanic, and a generic "every Templates entry has a
        RoleByTowerId entry" guard. New `tests/InfiniteQueues.lua`
        (12 cases) covers buildAutoRunQueue / buildLongAutoQueue /
        buildFullAutoQueue / buildSelectAutoQueue — the helpers
        powering the SIMULATE menu's FULL AUTO and SELECT AUTO
        items. Helpers exposed on the Infinite module so tests
        and future tools can hit them without re-implementing.
      • `Config.SimCalibration.BlinkTransitCap` lifted from a
        hardcoded `* 0.5` literal in `InfiniteSimulator.lua` per
        Convention #7. Last sim-tuning magic-number cleaned.
      • `GetTagged ... :Parent:Destroy()` audit completed —
        zero hits across `src/`. Old TODO in Portal.lua resolved
        with the audit-completion note + the one-grep
        regression test.
      • Aura pre-pass comment refreshed in `Towers.lua` — was
        labelled "SupportCore aura"; now correctly documented as
        "any tower with auraRadius>0" (covers Cores + the 3 aux
        Support buff towers).
      • selene 0/0/0 throughout. Each cleanup landed as its own
        commit (Phase 13a-13d) for clean morning regression.
- [x] Phase 14 — Infinite Arena calibration sprint (2026-04-29 →
      2026-05-01, ea3-130 through ea3-140):
      Closed-form sim → real-game alignment work driven by sweep
      data, plus end-to-end overnight tooling and cleanup pass.

      ea3-130 — Per-tower-position aura model. Replaced the
        single-knob `AuraLocalCoverage` heuristic in
        `InfiniteSimulator.simulateWave` with placement-aware
        geometry. Each tower gets its OWN dpsMult/rangeMult based
        on which aura sources reach its slot
        (`cell_distance × CELL_SIZE ≤ auraRadius`). Global auras
        (radius 9999, SupportCore) automatically reach every slot;
        local auras (16-18) only reach geometric neighbors. The
        `AuraLocalCoverage` knob is bypassed in the production
        path; legacy `auraMultForLoadout` retained for backward
        compat + existing tests.

      ea3-131 — MushroomMortar 9th-pass nerf (damage 48→40,
        blastRadius 8→7, lobSeconds 2.2→2.5). Power-only 240-run
        pool showed Mortar S-tier at avgWave 13.8, +3.8 wave gap
        to next DPS. Three-axis trim (per-shell + splash area +
        lob accuracy) since prior 8 passes had under-shot
        predicted impact every time when isolated to one axis.

      ea3-132 — End-of-sweep tier list with stats + log cleanup.
        Server log now emits per-Core REAL cumulative tier list
        (with inline mechanic stats per tower:
        `formatTowerStatsLine`) at the end of every sweep.
        Sweep log spam gated behind `SWEEP_VERBOSE = false` —
        per-wave START/END / `[Sweep diag]` / cleared-prior-towers
        / reroll attempts / upgrade picks. Net log volume per
        sweep × 105: ~600 lines → ~150 lines.

      ea3-133/134 — SUPER CURVE × 495 overnight sweep mode. Two
        phases: (A) 3 Cores × FAILURE CURVE × 105 = 315; (B)
        TARGETED × 60 per Core (top-|delta| picks against the
        post-Phase-A validator). Same wave-1..28 force-failure
        pipeline throughout — no wave-30-cap saturation hiding
        top-end dominance. Per-combo checkpointing every 10 combos
        (preserves work on Studio crash). ~6.9 hours runtime.

      ea3-135 — Removed orphaned SUPER AUTORUN row + handler.
        Superseded by SUPER CURVE × 495.

      ea3-136 — SUPER CURVE × 495 HUD shows absolute progress
        ("SUPER CURVE A 10/495") instead of per-Core slice
        ("FAILURE CURVE 10/105"). Outer-sweep timing anchors so
        the progress bar countdown reflects the full ~7-hour run
        instead of resetting to ~1:27 at each Core boundary.

      ea3-137 — TowerInfoCard's "Max DPS" base/modified pattern
        fix. Pre-fix: white = modDmg×modFr, green parens =
        common-tier theoretical multi-target ceiling. Two
        semantics overloaded the green-paren slot, reading as
        "modified DPS is lower than base." Now: white = baseDps,
        green = modDps — same pattern as Damage/Range/FireRate.
        `computeTheoreticalDps` removed.

      ea3-138 — Heart-death recording. Captured the
        `ctx.onHeartOverkill` callback (fired by MobUpdate on
        killing blow) on both AUTORUN and FAILURE CURVE paths
        (was previously discarded — only the legacy enter()/exit()
        flow consumed it). Per-result fields:
        `heartHpAtKillingWaveStart` / `killingBlowOverkill` /
        `postKillThreatHp` / `theoreticalNextWaveHeartHp` (=
        `-(killingBlowOverkill + postKillThreatHp)`, the
        "virtual heart in an infinite-HP world" metric for
        boss-round delineation per Matthew). `computeFractionalWave`
        now returns `(finalWave, postKillThreatHp)` so the
        previously-discarded denominator data lands on result.

      ea3-139 — Dead-code removal pass. Removed orphaned
        ArenaSweepRunner.runFullCoverageSweep, SUPER AUTO server
        handler + Core-queue progression block, FULL AUTO server
        handler, InfiniteSuperAutoRun + InfiniteFullAutoRun
        Remote names, plus dead consumer branches
        (`autoRun.isSuperAuto` / `superAutoCoreQueue` cleanup
        sites + the "SUPER AUTO" / "TOWER SUPER" label switch).
        Net -198 lines. selene 0/0/0.

      ea3-140 — Drop "studs" suffix on TowerInfoCard's AOE/
        Knockback effect rows per `feedback_no_studs_unit.md`
        ("never say studs in card UI"). Caught during ea3-139
        cleanup audit.

Tooling helpers landed during cleanup:
- `scripts/fix_udim2.py` — selene-driven UDim2 sweeper (handles
  paren-balanced args, skips mixed-form calls).
- `scripts/fix_unused.py` — selene-driven loop-var + service-require
  cleaner (rename `i` → `_`, drop unused service requires, rename
  callback params to `_param`).
- `scripts/bundle_grid_locals.py` — one-shot rewrite of init.client's
  top-level grid locals into mapCfg[mapId]. Word-boundary regex with
  quote-context awareness so WaitForChild string args are left alone.

## Roadmap (post core-loop)

Forward feature roadmap. None of these are being built yet — listed
in rough priority order. Detailed specs live in the memory files
under `~/.claude/projects/D--Projects-Tree-of-Life/memory/`.

**Core-loop polish (active):**
1. Map 3 + Pickle Lord boss — playtest pass currently in progress.

**Meta-progression layer:**
2. **Seedlings** (`project_seedlings_attachments.md`) — persistent
   currency earned per run. Three uses: UNLOCK new attachments;
   at 10 seedlings earned the player UNLOCKS THE OPTION to add Core
   attachment slots (actual spend mechanic TBD); UPGRADE attachment
   rarity tiers. Schema room needed: per-player attachment unlock
   state, per-player Core slot count, and multi-attachment-per-Core
   support.
3. **Difficulty tiers** (`project_difficulty_levels.md`) — selectable
   difficulty levels on the FINITE core run ("climbing the tower").
   Higher tier = more seedlings. Likely HP/damage/wave-count
   multipliers, not new mechanics.

**World expansion:**
4. **Underground map** (`project_underground_map.md`) — next map after
   Canopy Nest. Concept-only; theme/mobs/boss TBD. Don't hardcode
   "3 maps total" anywhere — leave room for `mapId == 4`.

**Infinite mode (TWO phases):**
5. **Phase 1 — Balance/benchmark sandbox** (`project_infinite_arena.md`):
   internal tool for tier list + balance work. Standard scenarios
   (AOE / single-boss / mixed), scale waves until failure, capture
   DPS + stun/slow/knockback metrics, log tower combos used per run,
   flag broken combos. Treat as in-game test harness.
6. **Phase 2 — Public Infinite Arena**: leaderboard mode fed by 3
   saved Core-tower slots from winning runs. Narrative: "launch a
   tower to the pickle planet, Pickle Lord blocks the launch."

When adding code that touches map count, attachment slots, run rewards,
or stat capture: leave hooks for the items above instead of hardcoding
current behavior. (E.g., don't write `attachment` as a singular field
on the Core schema — make it a list. Don't hardcode `mapId <= 3` —
treat unknown mapIds as "no special handling.")

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
- Mark every user-directed question on its own blockquote line with a
  `Q:` prefix, like this:
  ```
  > Q: does this look right, or want me to try the other approach?
  ```
  Matthew reads on the Claude Windows desktop client, which does NOT
  render `**markdown bold**` — the asterisks just show through. The
  blockquote + `Q:` prefix is the only format that visibly stands out
  in that client. Don't use the `> Q:` format for anything other than
  real questions (no section labels, no callouts), or the skim signal
  is lost. Full rationale in memory under feedback_bold_questions.md.
- **Matthew tests while you build.** When something lands that's worth
  eyeballing in-game, drop a one-line `> T:` blockquote callout and
  keep going — DON'T stop and ask "ready to test?" That stalls flow.
  Example:
  ```
  > T: smoke-test the new WEAKEST mode + relocated CLOSE button
  ```
  Exception: for risky / major changes (state-publication refactors,
  wave-loop edits, anything that could break gameplay if one ref is
  missed) — pause with `> Q:` first instead. Full rationale in memory
  under feedback_test_in_parallel.md.
- **Recommendations get a `> R:` blockquote prefix** — same shape as
  `> Q:` and `> T:`, for actionable suggestions Matthew should consider
  but isn't required to act on. Use it for "next balance change to
  try," "refactor candidate I noticed," "tooling tweak that'd help,"
  etc. Plain-prose recommendations get buried inside paragraphs and
  the Windows desktop client doesn't render bold, so the blockquote +
  prefix is the only format that's actually skimmable for action items.
  Example:
  ```
  > R: bump MushroomMortar damage 40 → 55 to lift it off F-tier
       without touching the lob mechanic.
  ```
  Don't use `> R:` for section headers, observations, or framing — only
  concrete actionable suggestions. Full rationale in memory under
  feedback_recommendations.md.
- Prioritize practical examples.
- Verify facts against current sources when accuracy matters.
- Cite reputable sources when accuracy is critical.
- Always test after structural changes (the Lua scope rules bite hard).
- Commit small. Phase 1's commits are good models — one focused change per commit.
- The user's daughter Lily playtests on iPad — keep mobile precision in mind
  for any UI/interaction work.
- **Reach for diagnostic visualizations early.** When a bug resists one
  theory-driven fix — especially coordinate transforms, timing,
  replication, or "X doesn't match Y" — build a cheap on-screen
  indicator instead of guessing a second time. Yellow rings at click
  positions, "expected vs actual" HUD labels, short-lived 3D pulses
  at computed world points — 20-40 lines that make the bug visible in
  one screenshot. Much cheaper than another round-trip with the user.

## Roblox coordinate gotchas

- **For click→world raycasts, use `UserInputService:GetMouseLocation()`
  as the single source of truth.** `InputObject.Position` from
  InputBegan doesn't always agree with GetMouseLocation — empirically
  they can differ by tens of pixels in Y. Grabbing GetMouseLocation at
  click time gives consistent coords for the raycast, the debug
  overlay, and a custom cursor.
- Feed the GetMouseLocation vector directly to
  `Camera:ViewportPointToRay` — no GuiInset subtraction needed.
- `ScreenGui.IgnoreGuiInset = true` pins the Gui to screen space
  (includes topbar). Default `false` pins to viewport / below topbar.
  Match this to the coord source you're using — GetMouseLocation works
  with `IgnoreGuiInset = false`.
- Classic `Mouse.X` / `Mouse.Y` (from `Player:GetMouse()`) are the
  legacy API; prefer GetMouseLocation. Don't mix the two.
- A custom cursor (MouseIconEnabled = false + follower label driven by
  RenderStepped + GetMouseLocation) makes "where will this click
  actually land" visible — once that's trustworthy, use the same
  GetMouseLocation at click time and everything aligns.
- **Debug-visualization gotcha**: don't spawn a 3D ball at `hit.Position`
  to show where a raycast landed — if the hit is on a floor, half the
  ball is buried and the visible silhouette's apparent center sits a
  stud above the geometric center, reading as a ~50px screen offset
  that makes the ray look broken when it's fine. Use a thin vertical
  cylinder with its base at `hit.Position` instead, or round-trip the
  hit through `WorldToViewportPoint` and draw a 2D ring at the result.

## Don't change without asking

- Phoenix system mechanics (cooldowns, timing, AOE radius)
- Mob HP multipliers per wave
- Staircase geometry constants (radius, step count) — these were tuned visually
- Stage unlock fractions (currently 0.05/0.25/0.60/1.00 per stage)
