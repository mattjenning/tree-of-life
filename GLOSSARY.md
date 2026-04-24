# Tree of Life — Shared Glossary

Terms used in code, design conversation, and this doc should match.
Inconsistencies are flagged with ⚠️. Non-canonical aliases are listed under each entry — if you use one, I'll map it back to the right term.

---

## World & Progression

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Hub / Hub world**<br>*Aliases: lobby, overworld, base, home* | Overworld lobby — giant tree, canopy, platform with portals. Player spawns here between runs. | Hub.server, Client |
| **Run**<br>*Aliases: game, attempt, playthrough, session* | One playthrough from map 1 start to Pickle Lord defeat or heart death. Upgrades, luck, and reroll tokens reset each run. | WaveSystem, Hub.server |
| **Map**<br>*Aliases: level, arena, zone, world, area* | A TD arena. Three maps total: map 1 (Crook), map 2 (Climbing), map 3 (Canopy). Each has its own grid columns, heart, path, and stage geometry. | Config, WaveSystem, Client |
| **Stage**<br>*Aliases: Morning / Day / Dusk (map-1 names), chapter, round* | Progression level within a map — 3 stages per map, 5 waves each. Named Morning / Day / Dusk on map 1. Stage clear heals the heart and grants reroll tokens. | Config, WaveSystem |
| **Wave**<br>*Aliases: round, spawn, attack* | Single mob-spawn sequence. 5 waves per stage. Clearing a wave (all mobs dead) triggers an upgrade picker, except wave 5 which triggers the stage or boss sequence. | Config, WaveSystem |
| **Portal**<br>*Aliases: door, gate, entrance, warp* | Teleport entry from hub to map 1, or between maps. Stepping inside fires EnterPortal. | Hub.server, Portal.lua |
| **TD room**<br>*Aliases: room, arena, tower defense room, the room, battlefield* | Enclosed arena where waves run. | Hub.server, TdRoom.lua |
| **Staircase**<br>*Aliases: stairs, spiral stairs, steps* | Spiral geometry rising from map 2 floor; 120 steps, reveals progressively per stage unlock. | Map2.lua, Config |
| **Pedestal**<br>*Aliases: stand, shrine, platform, plinth* | Raised platform on map 2. Player interacts to open the permanent tower equip modal. Rises after map boss defeat. | Hub.server, Remotes |
| **Canopy**<br>*Aliases: treetop (map 3), leaves / foliage (hub tree parts)* | (1) Map 3 arena name. (2) Foliage parts on the hub tree that sway in wind. Context distinguishes them. | Hub.server, Tags |

---

## Enemies

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Mob**<br>*Aliases: enemy, creature, baddie, unit, food* | Any enemy entity. Types: Rotten Apple (basic), Sour Lemon (fast), Moldy Bread (tank), plus boss variants. Tagged `Mob`. | WaveSystem, MobFactory, Tags |
| **Heart**<br>*Aliases: core, base, objective, life crystal, EnemyEndPoint (code tag)* | Green sphere in the TD room center — the player's objective. Loses HP when mobs reach it; game over at 0. Tagged `EnemyEndPoint`. | WaveSystem, Hub.server, Tags |
| **Waypoint**<br>*Aliases: node, point, EnemyWaypoint (code tag)* | Node along the enemy path. Mobs move through waypoints in sequence toward the heart. Tagged `EnemyWaypoint`. | WaveSystem, Hub.server, Tags |
| **Spawn / EnemySpawn**<br>*Aliases: start, entry point, spawn point, origin* | Starting point where mobs enter the map. First waypoint of the path. Tagged `EnemySpawn`. | WaveSystem, Hub.server, Tags |
| **Path**<br>*Aliases: road, route, lane, track, enemy road* | Route mobs travel from spawn to heart. Occupies grid cells; towers cannot be placed on path cells. | Grid.lua, Hub.server |
| **Stage boss**<br>*Aliases: mini-boss, wave boss, wave-5 boss* | Large named mob spawned as the final enemy of wave 5 in stages 1–3. Spawns alongside the normal mob group, not solo. Examples: Mold King (map 1). | WaveSystem |
| **Map boss**<br>*Aliases: ⚠️ "final boss" (ambiguous — see note), area boss, named boss, solo boss* | Solo named boss encounter that triggers after stage 3 wave 5 clears. No normal mobs spawn with it. Defeating it rewards an aux tower. Examples: Mold King (map 1), Web Weaver (map 2), Canopy Bird (map 3). | WaveSystem, Config |
| **Pickle Lord / Run boss**<br>*Aliases: ⚠️ "final boss" (ambiguous — see note), endgame boss, last boss* | Ultimate boss encountered after all 3 map bosses are defeated. Drops the one permanent tower equipped next run. Not yet implemented. | CLAUDE.md, memory |

> ⚠️ **"Final boss" is ambiguous** — the code flag `isFinal = true` is on the **map boss**; in conversation "final boss" usually means **Pickle Lord**. Canonical split: **map boss** (per-map solo) vs. **run boss** (Pickle Lord). "Final boss" is an alias for both; context required.

> ⚠️ **Bare "boss" is ambiguous.** Always qualify: stage boss / map boss / run boss.

---

## Towers

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Tower**<br>*Aliases: turret, gun, defense, structure* | Player-placed defensive structure that fires at mobs. Has damage, range, fire rate, ammo, and targeting mode. Tagged `Tower`. | WaveSystem, Hub.server, Client, TowerTypes |
| **Core tower**<br>*Aliases: ⚠️ Power tower / Power (code name), starter tower, main tower, your tower, the tower* | The red-gem cylinder starter tower. Called `Power` in code; called **Core** in design conversation and UI. The only tower with persistent stock across maps. | TowerTypes, Hub.server, Client |
| **Aux tower**<br>*Aliases: ⚠️ temp tower / TempTower (code name), temporary tower, bonus tower, reward tower* | One of the 9 temporary towers earned as map boss rewards. Called `TempTower` in code; called **aux** or **auxiliary** in design conversation. No persistent stock. | TempTowers, TempTowerRewards |
| **Permanent tower**<br>*Aliases: persistent tower, meta tower, run-carry tower, DataStore tower* | Tower earned from the run boss (Pickle Lord). Persists in DataStore across runs. One equipped at a time. | PermanentTowers, Hub.server |
| **Tower footprint**<br>*Aliases: size, area, tiles, occupied cells* | Grid cells (width × depth) a tower occupies at placement. Core = 4×4 cells. | TowerTypes, Client |
| **Grid cell / Cell**<br>*Aliases: tile, square, slot, grid square* | Unit square in the placement grid (2 studs per cell). States: open, path, heart, occupied. | Grid.lua, Config, Client |
| **Placement ghost**<br>*Aliases: preview, shadow, ghost, outline, silhouette, tower preview* | Semi-transparent tower preview that follows the cursor before placement. Red = invalid, green = valid. | Client |
| **Range circle**<br>*Aliases: attack radius, range ring, range indicator, range preview* | Visual ring drawn around a tower at its attack radius. Shown when a tower is selected. | Client |

> ⚠️ **Core/Power and Aux/Temp are a code/design split.** Code uses `Power` and `TempTower`; design conversation and UI use **Core** and **Aux**. Don't mix them in the same sentence.

---

## Upgrades & Cards

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Upgrade**<br>*Aliases: buff, bonus, perk, power-up, stat boost* | A stat or special-effect bonus applied to towers. Categories: stat (damage / range / fire rate), special (Stun, Knockback, AOE, Detonator, Slow, Chain), ammo. | WaveSystem, UpgradeCards, Client |
| **Upgrade card**<br>*Aliases: ⚠️ mod card, card, buff card, stat card* | A single option tile in the upgrade picker — shows icon, name, description, rarity color stripe. | Client, UpgradeCards |
| **Tower card**<br>*Aliases: ⚠️ card, reward card, boss reward card* | A single option tile in the temp tower picker (different modal from upgrade picker). Uses the same visual style as upgrade cards. | Client, TempTowerRewards |
| **Upgrade picker**<br>*Aliases: card picker, upgrade modal, upgrade screen, post-wave screen* | The 3-card modal displayed after each non-boss wave clear. Player picks one upgrade card. | Client, WaveSystem |
| **Temp tower picker**<br>*Aliases: tower reward screen, boss reward screen, loot picker, map boss reward* | 3-card modal shown after a map boss defeat. Rewards one aux tower (tower cards). Distinct from the upgrade picker. | Hub.server, TempTowerRewards |
| **Rarity**<br>*Aliases: tier, quality, grade* | Quality tier of a card or attachment: Common, Rare, Exceptional, Legendary, Mythical. Affects stat scaling and card color. | TempTowers, UpgradeCards, Config |
| **Rarity palette**<br>*Aliases: rarity colors, tier colors, color scheme* | The shared color scheme for rarity tiers. Source of truth is `RARITY_TIERS` in UpgradeCards.lua. | UpgradeCards, Client |
| **Reroll / Reroll token**<br>*Aliases: refresh, re-draw, shuffle, redo, reroll charge* | Lets the player discard the current 3 upgrade cards and draw 3 new ones. Earned from stage-boss clears, duplicate temp towers, and selling towers. | WaveSystem, UpgradeCards, Remotes |
| **Dud**<br>*Aliases: duplicate, waste, repeat, junk card* | A temp tower card whose rarity is already owned; auto-converted to a reroll token instead of appearing in the picker. | TempTowers, TempTowerRewards |
| **Run luck**<br>*Aliases: luck score, luck meter, luck rating, RUN LUCK (UI label)* | Normalized meter (0–5) showing upgrade card quality vs. statistical average. 2.71 = exactly average; displayed in the dev panel. | Client, WaveSystem |

**Rarity color palette** (use these exact colors everywhere):

| Rarity | Color |
|--------|-------|
| Common | Gray |
| Rare | Blue |
| Exceptional | Purple |
| Legendary | Orange |
| Mythical | Pink |

> ⚠️ **Upgrade card vs. tower card vs. bare "card."** Use **upgrade card** for the stat/effect picks after waves. Use **tower card** for the aux tower picks after map bosses. Bare "card" is an alias for either — context should disambiguate, but prefer the full name.

> ⚠️ **Rarity "Rare" = blue, not green.** An old code comment had it wrong. Authoritative source: `RARITY_TIERS` in `UpgradeCards.lua`.

---

## Attachments

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Attachment**<br>*Aliases: mod, modifier, passive, equip, ability, power-up* | A persistent tower modifier earned from boss defeats. One equipped per tower at a time; persists in DataStore. | AttachmentStore, Attachments, WaveSystem |
| **Phoenix**<br>*Aliases: phoenix grace, grace, safety net, AOE capture* | Attachment that captures mobs near the heart in an AOE burn, holds them 10 s, then releases them staggered. Grants 5 s grace (invulnerability) on trigger. Cooldown scales by rarity. | Phoenix.lua, Config |
| **Detonator**<br>*Aliases: bomb, chain explosion, explode-on-death* | Attachment causing mobs to explode on death, chaining damage to nearby mobs recursively. | Damage system |
| **PowerCore**<br>*Aliases: power boost, damage boost, core boost* | Raw damage-boost attachment applicable to any tower type. | TowerTypes (referenced) |
| **Seedlings**<br>*Aliases: seeds, upgrade currency, meta currency* | Future currency for upgrading attachments one rarity tier at a time. Persists across runs. Not yet coded. | memory |

---

## Status Effects & Combat

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Stun**<br>*Aliases: freeze, stop, lock, stun stack* | Freezes a mob in place; rotating star icon shows above it. Stacks additively. Triggered by StunChance attribute (default 5%). | WaveSystem, Effects.lua |
| **Knockback**<br>*Aliases: push, shove, repel, slide* | Pushes a mob backward along its path for 0.25 s. Default trigger chance 5%. | WaveSystem, Effects.lua |
| **AOE / Area burst**<br>*Aliases: splash, area damage, explosion, radius, burst, splash damage* | Damage radius effect from certain towers or mobs. VFX duration is wall-clock (not game-speed scaled). | WaveSystem, Effects.lua |
| **Zone / Ground patch**<br>*Aliases: DOT cloud, area, puddle, patch, damage zone, lingering effect* | Stationary damage-over-time area left by certain aux towers (Honey Hive, Spore Puffball). Persists until wave ends. | Zones.lua, WaveSystem |
| **Damage number**<br>*Aliases: floating text, damage pop, hit number, DPS pop* | Floating text billboard showing damage dealt; rises from mob ~1 s then fades. | Effects.lua, Client |
| **Bonus damage**<br>*Aliases: damage boost, double damage, damage buff, ×2 buff* | Temporary ×2 multiplier granted by completing a boss phase challenge. Lasts 5 s wall-clock. | FinalBoss.lua, WaveSystem |
| **BonusDamageUntil**<br>*Aliases: (code attribute — no spoken alias)* | Timestamp attribute storing when the bonus damage expires. | WaveSystem |

---

## Boss Mechanics

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Phase**<br>*Aliases: ⚠️ stage (ambiguous), mechanic, minigame, challenge, encounter* | A milestone during the map/run boss fight triggered at HP thresholds. Each phase spawns a tappable-target minigame. | FinalBoss.lua, Remotes |
| **Tappable target**<br>*Aliases: target, blob, dot, orb, circle, click target, button* | Clickable UI element spawned during a boss phase. 4 per phase; 4 s window. Success grants bonus damage; failure applies a penalty. | FinalBoss.lua, Client |
| **Windup**<br>*Aliases: warning, telegraph, charge-up, tell* | Boss stop-and-vibrate warning animation (1.2 s) before launching phase targets or an attack. | FinalBoss.lua, Remotes |
| **Web / Web projectile**<br>*Aliases: spider web, silk, thread, trap, SpiderWeb (code tag)* | Projectile fired by Web Weaver every 15 s. Player taps it to cancel; missed webs lock the targeted tower for 3 s. Tagged `SpiderWeb`. | CanopySpiderBoss, Tags, Config |
| **Dive / Dive target**<br>*Aliases: swoop, bird attack, bird strike, BirdDiveMark (code tag)* | Attack by Canopy Bird every 12 s: hovers over a random tower, spawns a tappable dive-target. Tap to cancel and deal 500 bonus damage; miss shaves 10 MaxShots from the tower. Tagged `BirdDiveMark`. | BirdBoss.lua, Config, Tags |

> ⚠️ **"Phase" vs. "stage."** Phase = a boss fight milestone. Stage = a map progression level (3 per map). Don't use them interchangeably.

---

## Ammo & Inventory

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Ammo**<br>*Aliases: bullets, shots, energy, charges, fuel* | Ammunition for towers. Each shot consumes one unit. Towers stop firing at 0. Recharged by picking up ammo piles. | WaveSystem, Ammo.lua, Client |
| **Pip**<br>*Aliases: dot, unit, ammo unit, bar segment, ammo count* | Display unit for ammo (1 pip = 10 shots). Used in HUD labels and the carrying-ammo indicator. | Client |
| **Ammo pile / Pickup**<br>*Aliases: ammo crate, ammo drop, supply, collectible, AmmoPile (code tag)* | Collectible item in the TD room. Player holds E to accumulate. Tagged `AmmoPile`. | Ammo.lua, Hub.server, Tags |
| **Max carry / Carrying capacity**<br>*Aliases: inventory size, max ammo, carry limit, capacity* | Maximum ammo pips a player can hold at once. Attributes: `CarryingAmmo` (current) and `MaxCarry` (limit). | Hub.server, Client |

---

## UI Elements

| Term | Definition | Where it appears |
|------|-----------|-----------------|
| **Splash screen**<br>*Aliases: title screen, intro screen, start screen, opening screen* | Opening title screen ("Tree of Life") shown on first entry. Auto-dismisses after fade. Fired by ShowSplash remote. | Client, Hub.server |
| **Hotbar**<br>*Aliases: tower bar, action bar, toolbar, tray, tower tray, inventory bar* | Tower-stock button bar along the bottom. Shows each tower type with its current stock count (e.g., `×3`). | Client, WaveSystem, Hub.server |
| **Wave HUD**<br>*Aliases: HUD, info bar, status bar, top bar, wave info, wave counter* | Top-of-screen strip: map name, stage, wave number, mob count. Shows countdown during auto-start and "DEFEAT" lock on game over. | Client, WaveSystem |
| **Tower HUD / Target-mode panel**<br>*Aliases: tower panel, tower info card, targeting panel, tower stats, tower menu, info card* | Modal that opens when a placed tower is clicked. Shows stats (damage, range, fire rate, ammo) and targeting-priority buttons. | Client |
| **Starter picker**<br>*Aliases: tower select, class select, starting tower screen, loadout screen* | Modal at run start to choose the initial (Core) tower. Only non-temp-reward towers appear here. | Client, Hub.server |
| **Stage clear banner**<br>*Aliases: stage complete screen, stage cleared modal, between-stage screen, stage modal* | Modal shown after clearing a stage (stages 1–2 only). Displays stage numbers, grants reroll tokens, auto-continues after ~2.5 s. Stage 3 skips this — goes straight to the map boss. | WaveSystem, Client |
| **Game over modal**<br>*Aliases: end screen, results screen, win/lose screen, game over screen* | End-of-run screen showing WIN / LOSE, waves survived, and killer boss name if applicable. | Client, WaveSystem |
| **Dev panel**<br>*Aliases: debug panel, cheat panel, dev menu, developer panel, debug menu* | Collapsible debug UI with shortcuts: skip wave, skip to boss, teleport, toggle ammo/balance. Collapses after click on mobile. | Client |
| **Leaf message**<br>*Aliases: story message, narrative popup, flavor text, leaf notification, leaf popup* | Narrative flavor text with leaf animation, shown at story beats. Fired by LeafMessage remote. | WaveSystem, Hub.server |
| **Carrying-ammo indicator**<br>*Aliases: ammo indicator, ammo display, carry indicator, ammo HUD* | HUD label showing current ammo pips / max carry. Visible when player holds ammo. | Client |

---

## Shared Modules Quick Reference

| File | What lives there |
|------|-----------------|
| `src/shared/Config.lua` | All tuning values: grid dimensions, wave HP multipliers, boss stats, attachment cooldowns, etc. |
| `src/shared/Remotes.lua` | Single source of truth for every RemoteEvent and BindableEvent name. |
| `src/shared/Tags.lua` | CollectionService tag constants (`Mob`, `Tower`, `EnemyEndPoint`, `AmmoPile`, etc.). |

---

## Canonical Terms vs. Aliases at a Glance

For the six confirmed ambiguities — if you say one of these, I'll treat it as the canonical term in parentheses.

| If you say… | I'll treat it as… |
|-------------|------------------|
| "final boss" | **map boss** or **run boss** (I'll ask if unclear) |
| "boss" (unqualified) | will ask: stage boss / map boss / run boss? |
| "Power tower," "Power" | **Core tower** (design) / `Power` (code) |
| "temp tower," "TempTower" | **aux tower** (design) / `TempTower` (code) |
| "mod card," bare "card" | **upgrade card** (after waves) or **tower card** (after map boss) |
| "room," "arena," "tower defense room" | **TD room** |
