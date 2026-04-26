# Pickle Lord — Final Run Boss Spec

The run boss after the Canopy Bird. Drops the permanent tower; ends the run.
Fight takes place ON map 3 (Canopy Nest), no map switch.

## Trigger / arena

- Fires after map-3 temp-tower picker is claimed
  (`BossRewardClaimed mapId=3` chains to Pickle Lord start, NOT directly into
  the permanent picker)
- Same map (Map 3 / Canopy Nest), no map switch
- Boss is OFF the platform edge — only head + shoulders visible
  (he's "as tall as the entire tree")
- Static — no movement

## Entrance set piece (full cinematic)

- Initial smash clears the platform: all branches, flowers, leaves wiped
- HALF the butterflies remain (count current, kill half)
- Cracked platform texture/decals at smash points
- Glowing green pickle-shard parts scattered (left from the club)
- Bright moonlight (lighting tween — high `ClockTime`, cool blue `Ambient`)
- Dark clouds + fog (`Lighting.FogEnd` compressed)
- Wind (gust SFX + camera shake; existing wind code on shared parts will swirl)

## Combat

- HP: **1,000,000**
- Smash attack every **20 game-seconds**:
  - Club rises (telegraph)
  - 40-stud-radius circle appears around the targeted player
    (math: 16 stud/s × 2.5s = 40 studs)
  - 3-second timer: 0.5s reaction + 2.5s to escape
  - Game speed forced to 1× during the smash window via existing
    `BossPhaseSpeedLock` bindable (lock + release on resolve)
  - On smash: any tower in circle → destroyed + stock returned to player.
    Player in circle → death → map fail (DEFEATED)
- **Range decay**: every 30 game-seconds, every player tower's effective range
  × 0.9. Stacks multiplicatively, **drives to 0** (no floor)

## Reward chain

```
bird dies
  → BossDefeated mapId=3
    → temp-tower picker
      → BossRewardClaimed mapId=3
        → start Pickle Lord encounter      ← NEW
          → Pickle Lord HP=0
            → PickleLordDefeated bindable
              → permanent tower picker
                → claimed
                  → run ENDS (VICTORY → hub)   ← NEW
```

## Files the build will touch (~600 lines)

| File | Change |
|---|---|
| `src/server/systems/PickleLordBoss.lua` | NEW system module (model, cinematic, smash, range decay, death) |
| `src/server/world/Map3.lua` | boss-arena variant (post-entrance: cracked platform, shards, half butterflies, moonlight) |
| `src/server/systems/PermanentTowers.lua` | chain `BossRewardClaimed mapId=3` → Pickle Lord start (currently chains to permanent picker directly) |
| `src/server/TreeOfLife_WaveSystem.server.lua` | speed-lock during smash, range-decay multiplier broadcast |
| `src/server/systems/Towers.lua` | apply per-tower range-decay multiplier inside `findTarget` |
| `src/client/TreeOfLife_Client/init.client.lua` | smash circle visualization (40-stud target ring on the floor) |
| `src/shared/Config.lua` | new `Config.Map3.PickleLord` block with all tunables |
| `src/shared/Remotes.lua` | `PlayPickleLordSmash`, `PlayPickleLordEntrance` events |

## Open questions to resolve early

1. **Pickle Lord geometry** — procedural like the bird, or a single big Block
   sized to "tree-tall" with a painted face?
2. **Range-decay attribute name + multiplication site** — Towers.lua's
   `findTarget` reads tower range; cleanest is a `RangeDecayMultiplier`
   player-attribute multiplied alongside `RangeBonusPct`. Decide whether
   it's a player attribute or a per-tower attribute (probably player —
   range decay applies uniformly across all the player's towers).
3. **Smash circle visual** — tagged Part on the floor with a UI ring, or 3D
   cylinder Part? (Part is simpler + visible regardless of camera)
4. **Victory screen** — game-over-LOSE path has a DEFEATED modal. Does it have
   a WIN variant or does the build need to add one?

## Tunables (initial values, all in Config.Map3.PickleLord)

```lua
PickleLord = {
    Hp                          = 1000000,
    SmashIntervalGameSec        = 20,
    SmashRadiusStuds            = 40,
    SmashTotalSec               = 3,        -- 0.5 reaction + 2.5 movement
    SmashReactionSec            = 0.5,
    RangeDecayIntervalGameSec   = 30,
    RangeDecayMultiplier        = 0.9,      -- multiplicative per tick (drives to 0, no floor)
    EntranceCinematicSec        = 5,        -- moonlight + smash + butterflies
    -- Visual
    BodyColor                   = Color3.fromRGB(60, 110, 50),  -- pickle green
    ClubColor                   = Color3.fromRGB(100, 180, 70),
    ShardColor                  = Color3.fromRGB(120, 230, 80),
    MoonlightAmbient            = Color3.fromRGB(70, 90, 130),
    FogEnd                      = 200,
}
```

## Smash flow detail

```
[every 20 game-seconds]
  1. Pick a player target (random or nearest — start with random)
  2. Telegraph: club rises, dramatic SFX
  3. Fire BossPhaseSpeedLock(lock) — gs forces to 1
  4. Spawn smash-circle Part on floor centered on player's CURRENT XZ position
     (40-stud radius cylinder, semi-transparent pickle-green, glows pulse)
  5. 3-second timer (3s wallclock since speed is locked at 1)
  6. ON RESOLVE:
     a. Walk Tags.Tower; for each owned tower whose XZ distance to
        circle-center <= 40 → destroy tower + increment player's <towerId>Stock
     b. Check player XZ distance to circle-center <= 40 → kill humanoid →
        triggers existing GameOver flow (DEFEATED banner)
     c. Despawn circle Part
     d. Fire BossPhaseSpeedLock(unlock) — gs returns to player's choice
  7. Resume 20-game-second wait until next smash
```

## Range decay flow detail

```
[every 30 game-seconds, while Pickle Lord alive]
  player:SetAttribute("RangeDecayMultiplier",
    (player:GetAttribute("RangeDecayMultiplier") or 1) * 0.9)

  [Towers.lua findTarget reads:]
  local range = data.range * (1 + RangeBonusPct/100) * (RangeDecayMultiplier or 1)
```

Ticks 1..N → 0.9, 0.81, 0.729, 0.656, 0.59, 0.531, 0.478, 0.43, 0.387, 0.349…
At 5 minutes (10 ticks) range is at 35% of original. At 10 minutes (20 ticks)
12%. Drives to 0 over time so the player MUST kill Pickle Lord under a hard
clock.

On `RunReset` / `SwitchMap` / `PickleLordDefeated`, clear the attribute back
to nil so the next run starts at full range.
