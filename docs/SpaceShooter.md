# NEON STRIKE — native SceneKit space shooter (iOS Bridge)

A vertical-scrolling 3D arcade space shooter (Star Fox × R-Type) launched from the
**Bridge** cockpit on iOS. It replaced the DropBlock launcher on iOS; **DropBlock
remains a web/desktop game** (`ui/web/src/components/DropBlock/`) — it was only removed
from the iOS client.

Unlike DropBlock (a shared React/WebView game), NEON STRIKE is **native SceneKit** and
**iOS-only**: real Metal rendering, no WebView/JS bridge, Codable resume. The retro
"yesterday's pixels" look comes from a low-resolution drawable upscaled with
nearest-neighbour filtering + flat-shaded neon materials + a constrained synthwave palette.

## Source layout (`ui/ios/Sources/Game/`)

| File | Role |
|------|------|
| `GameState.swift` | `GameStatus`, observable `GameModel` (HUD surface), `GameSnapshot` Codable resume blob, `GamePersistence` (UserDefaults: `inbox2_spaceshooter_state`, `inbox2_spaceshooter_best`). |
| `Palette.swift` | `Synth` neon palette + flat (`.lambert`) / self-lit (`.constant`) material helpers. |
| `Textures.swift` | Procedural grid / nebula / dot textures (so the game looks complete without external art). |
| `Biomes.swift` | 4 biomes (NEON CITY / CRYSTAL CANYON / REACTOR / SUN GRID) — grid + backdrop + fog + star colours. |
| `ShipKit.swift` | Procedural low-poly ship builder: composes primitives → `flattenedClone`; `fighter`/`saucer`/`drone`. |
| `ShipSpecs.swift` | Data catalogs: 3 player ships, ~10 enemy types, 4 bosses (stats + `make` closures). |
| `Explosions.swift` | One-shot `SCNParticleSystem` bursts (kills / hits / bomb). |
| `Vec.swift` | Minimal `SCNVector3` math. |
| `GameScene.swift` | **The engine.** Owns the `SCNScene` (camera, lights, fog, biome background) and drives gameplay from `renderer(_:updateAtTime:)` — spawning, AI, weapons, collisions, scoring, lives, level/biome progression. Publishes summary stats to `GameModel` on the main thread. |
| `SpaceShooterGameView.swift` | `SpaceShooterGameScreen` (start / game-over overlays, close, resume) + `GameHUD` + `SpaceShooterSceneView` (the low-res `SCNView` host + drag/tap input). |

## World model

`+X` right, `+Y` screen-up, **`−Z` forward** (into the distance / top of screen). The
player flies on the X/Y screen-plane near `z≈0`; enemies spawn at far `−Z` and advance
toward `+Z`. Player bullets travel `−Z`; enemy fire travels toward the player. Camera is
over-the-shoulder (`(0,8.5,18)` via an `SCNLookAtConstraint`).

## Controls

Drag anywhere to fly (relative pan deltas → world units), **auto-fire** is continuous,
**tap** drops a bomb (also a HUD bomb button). Weapon level (1–4) widens the fire pattern;
power-ups: weapon / shield / bomb / extra-life / score.

## Retro rendering

`SCNView.contentScaleFactor` is lowered so the Metal drawable is ~300px tall and
`layer.magnificationFilter = .nearest`, giving the chunky pixel upscale; `antialiasingMode
= .none`. Materials are `.lambert` with neon `emission`; one magenta key + one cyan rim
light + low ambient + `FogExp2`-style distance fog. (An optional `SCNTechnique`
palette-quantize Metal post-pass is a possible future polish — the baked palette already
reads synthwave.)

## Resume

`GameSnapshot` (small stable fields only — no live entities) is saved to UserDefaults on
background (`scenePhase`) and on close, and restored on open; the scene rebuilds clean and
the spawner resumes from `levelTime`. Game-over clears the snapshot. Best score persists.

## Bridge integration

`Sources/Views/BridgeView.swift` top-right button → `.fullScreenCover { SpaceShooterGameScreen() }`.
The button uses the ring-gradient `gamecontroller.fill` SF Symbol.

## Art

In-game textures are procedural (`Textures.swift`); the Bridge button is the ring-gradient
`gamecontroller.fill` SF Symbol. To swap in Higgsfield biome backdrops/FX later, drop
`Resources/sx-*.png` and load them in `Biomes.swift` / `Textures.swift`.

## Build / run

The game is native Swift — no JS bundle step (the old DropBlock `preBuildScript` was
removed from `project.yml`; `bootstrap.sh` no longer bundles it). After adding/removing
Swift, `.metal`, or resource files: `cd ui/ios && xcodegen generate`, then build.

```sh
cd ui/ios && xcodegen generate
# then build/run on a simulator (XcodeBuildMCP build_run_sim, or open Inbox2.xcodeproj)
```

To test past onboarding without OAuth, seed the simulator's store from the desktop DB:
`sqlite3 <desktop>/inbox2.db ".backup '/tmp/seed.db'"` → copy to the app container's
`Documents/inbox2/inbox2.db` along with `.credential_key` (see docs/iOS-Simulator.md).
