# VOXEL STRIKE — native voxel destruction shooter (Android Bridge)

A first-person, fully-destructible **blocky voxel world** launched from the **Bridge**
screen on Android. It is the Android counterpart to iOS's **NEON STRIKE**
(`docs/SpaceShooter.md`) — same *integration* spirit (a self-contained arcade game opened
from the Bridge, resume to prefs) but a **deliberately opposite look and genre**: where
NEON STRIKE is a dark SceneKit synthwave space shooter, VOXEL STRIKE is a bright daytime
Minecraft-lineage voxel world you blow apart to find a hidden golden egg.

Unlike DropBlock (a shared React/WebView game), VOXEL STRIKE is **native Kotlin + OpenGL
ES 2** and **Android-only**: real GPU rasterisation of a chunk-meshed voxel grid, a free-fly
camera, a switchable arsenal, and cheap "connectivity + grid gravity" destruction — no
physics engine.

## Source layout (`ui/android/app/src/main/java/com/inbox2/app/game/`)

| File | Role |
|------|------|
| `VoxelWorld.kt` | The `128×64×128` grid in one flat `ByteArray` (material id per cell). Seeded hash-noise heightmap generation (`Hash` value-noise), the buried golden egg, the **3D-DDA `raycast`**, `carveSphere` (the blast), and `computeUnsupported` (the ground-up support flood-fill). |
| `VoxelMesher.kt` / `ChunkMesh.kt` | Face-culled greedy-ish mesher. World is split into `16×64×16` chunks; each owns one interleaved `[x,y,z, r,g,b]` VBO and is re-meshed only when a destruction pass dirties it. Only solid↔air/water boundary faces are emitted; interior faces never reach the GPU. Classic cheap-light face shading (top brightest, bottom darkest). |
| `Weapons.kt` | The four-weapon power curve (`PISTOL → ROCKET → HEAVY → BOMB`) — each differs only in carve radius, fire cadence, projectile speed, and its Higgsfield sprite. |
| `Biomes.kt` | The 10 level themes (`Biome` + `Biomes.forLevel`). Each re-colours the five terrain roles, swaps the sky + distance fog, and reshapes the heightmap. |
| `VoxelGame.kt` | **The simulation.** Free-fly camera (yaw/pitch + WASD-style joystick + float/sink), projectiles fired *exactly along the view vector*, the destruction state machine, grid gravity, the golden-egg → next-level loop, score, and the Compose `Hud` snapshot. `update(dt)` runs on the GL thread. |
| `VoxelRenderer.kt` | `GLSurfaceView.Renderer`. Per-frame: pump input/sim, re-mesh ≤5 dirty chunks, draw all chunk VBOs + a dynamic overlay buffer (projectile tracers + pulsing egg highlight) with a flat-colour + distance-fog shader. **No back-face culling** (every emitted face is a boundary face; depth-test keeps it correct — culling only risked winding-dependent see-through). |
| `GameSurfaceView.kt` | Minimal GLES2 `GLSurfaceView` host; input is handled by the Compose layer. |
| `VoxelStrikeScreen.kt` | The full-screen Compose overlay: hosts the surface via `AndroidView`, decodes the Higgsfield sprites (`GameArt`), and switches between the start / playing / level-complete panels. Saves the resume snapshot on dispose. |
| `GameControls.kt` | In-game HUD + touch controls: look-drag layer, crosshair, level/score, egg-proximity bar, weapon selector (the four sprites), move joystick, float ▲ / dig ▼ / FIRE hold-buttons, and the equipped-weapon art. |
| `GamePersistence.kt` | Small resume blob (current level/score + best) in `SharedPreferences` (`voxelstrike`) — no live voxels. |

## World model & destruction

`+X` right, `+Y` up, `−Z` "north". The grid is one flat array, `idx = (y*SZ + z)*SX + x`.
Generation: two octaves of seeded value noise → a heightmap; columns fill **bedrock (y=0,
immovable) → stone → dirt → grass top**, with **water** below sea level and **sand** at the
shoreline. One **golden-egg** voxel is buried below an inland surface, deeper each level.

Destruction is cheap and fake — not physics:
1. **Carve** — a weapon hit removes a sphere of voxels (radius per weapon); bedrock/water are spared.
2. **Support** — `computeUnsupported` BFS-floods support from the bedrock through 6-connected solids; anything not reached is unsupported. Runs **off the GL thread** on a single worker; the result is applied back on the GL thread (a `physicsBusy` gate guarantees writes never race the meshing/BFS reads, and new impacts queue while busy).
3. **Gravity** — unsupported voxels fall straight down one cell per ~1/14 s tick until they land, re-meshing the affected chunks as they go.

Hitting the golden egg with **any** weapon wins the level → score flourish → `nextLevel()`
regenerates from the next seed with the egg buried deeper. Score is `Σ radius²` per blast
(+ a level bonus), so the four weapons read as a clear power curve.

## Biomes (per-level theming)

Every level looks like a different world; the mechanics never change. `Biomes.forLevel(level)`
cycles through 10 themes — a `Biome` re-colours the five terrain roles (surface/ side /
subsoil / deep / rim / liquid + bedrock), swaps the **sky colour + distance fog** (read by
the renderer each frame), and reshapes the heightmap (base height / amplitude / sea level,
and whether it has liquid at all). The egg stays gold everywhere; the biome name shows on the
HUD and the level-complete panel teases the next world.

| # | Biome | Look |
|---|-------|------|
| 1 | GRASSLAND | green hills, blue sky, lakes (the default) |
| 2 | ARCHIPELAGO | high sea, green islands + sandy beaches, cyan sky |
| 3 | ASTEROID | black void sky, grey rock, no liquid |
| 4 | DESERT | tan dunes, hazy sky, no water |
| 5 | TUNDRA | snow caps, ice water, pale sky |
| 6 | VOLCANO | basalt, glowing lava seas, ashen sky |
| 7 | TOXIC SWAMP | mossy ground, radioactive green sludge |
| 8 | ALIEN | purple rock, teal pools, magenta sky |
| 9 | CANDY | pastel pink/caramel blocks |
| 10 | OBSIDIAN VOID | near-black glass, purple-energy pools, gold veins |

Add/Reorder by editing the `Biomes.all` list — no other code changes.

## Controls

Drag anywhere (not on a control) to look (yaw/pitch, pitch clamped). Left **joystick** moves
relative to facing (forward uses the full view vector, so pitching down lets you fly into the
holes you dig). **▲ float / ▼ dig** raise/lower. **FIRE** is a hold-button (auto-fires at the
weapon's cadence; a latched request makes a single fast tap fire reliably). The **weapon
selector** row switches weapons. Shots are raycast along the exact camera forward.

## Art (Higgsfield)

The voxel world is **fully procedural/GPU** — no textures. Only the **weapon + egg sprites**
are Higgsfield art (Recraft 4.1), keyed to transparent and stored under
`ui/android/app/src/main/assets/game/` (`weapon_pistol|rocket|heavy|bomb.png`, `egg.png`).
They double as the HUD selector icons and the equipped-weapon overlay. To reskin, drop new
PNGs at those paths (referenced by `Weapon.asset`). Regenerate via the Higgsfield MCP with a
flat chroma background, then `magick … -fuzz 28% -transparent <corner> -trim -resize 512`.

## Integration & resume

`BridgeScreen.kt` adds a top-right `gamecontroller.fill` button (ring-gradient electric-blue)
that flips `game = true` in `RootTabs.kt`, which presents `VoxelStrikeScreen` as a fade-in
full-screen overlay over everything (and hides the floating nav). `BackHandler` closes it.
The resume snapshot (level/score/best) saves on dispose and restores on the start panel as
**CONTINUE · LEVEL n** vs **NEW GAME**.

## Threading

`GLSurfaceView` renders on its own GL thread. **All world mutation runs on the GL thread**:
input intents are written from the UI thread (`@Volatile` + a small lock for look deltas);
level (re)gen is queued (`pendingStart`) and pumped at the top of `update()` so it never
races the renderer; only the support flood-fill is offloaded to a worker, gated so reads and
writes never overlap. `onSurfaceCreated` re-marks every chunk dirty so an EGL-context
recreation (app background/return) cleanly re-uploads all VBOs.

## Build / run

Pure app-layer Kotlin — no Rust/core change. After adding/removing files just rebuild:

```sh
bin/android build      # or: android_build (Gradle only — fast)
bin/android install
bin/android launch
```

Reach it: Bridge tab (Explorer) → top-right game-controller button → DROP IN. To test past
onboarding without OAuth, `bin/android seed` (copies the desktop `inbox2.db`) — seed with the
app **stopped** (a live WAL otherwise shadows the pushed DB).

## Known cosmetics (v1)

Viewed at a grazing top-down angle, single-voxel terrace steps show their dirt side-faces as
thin vertical slivers (correct, but reads as "grass noise"). A future pass could add real
ambient occlusion / greedy face merging. No audio/menus/networking/enemies in v1.
