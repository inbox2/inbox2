# DropBlock

DropBlock is the falling-block mini-game that lives in the web app's inbox
empty-state and the Tauri desktop app. (**iOS no longer ships DropBlock** — the
iOS Bridge game is the native SceneKit shooter **NEON STRIKE**; see
[SpaceShooter.md](SpaceShooter.md).) This doc maps the source/feature surface and
how to regenerate the web/desktop build output.

## Source layout (single source of truth)

Everything is in `ui/web/`:

| File | Role |
|------|------|
| `src/components/DropBlock/engine.js` | Pure game logic (board, SRS, gravity, line/bomb/pac collapse). No DOM/React. |
| `src/components/DropBlock/DropBlock.jsx` | Canvas renderer + `requestAnimationFrame` loop + keyboard **and touch** input. |
| `src/components/DropBlock/DropBlock.module.css` | Styling, incl. the narrow-viewport (phone/WebView) layout. |
| `src/stores/dropBlockStore.js` | Zustand store; also `serializeGame()` / `hydrateGame()` for native resume. |
| `src/lib/dropBlockAudio.js` | Procedural Web-Audio synth (music + SFX, tempo control). |
| `public/dropblock/*.png`, `public/logo-mark.png` | Sprites (bomb, `pacman-{open,mid,closed}`, burst stickers). **Committed.** |
| `src/dropblock-embed.jsx` | Legacy standalone entry for a WebView bundle — **no longer wired into iOS** (kept, harmless). |
| `scripts/build-dropblock-embed.mjs` | Legacy esbuild bundler for that WebView HTML — **no longer used by iOS**. |

There is **one** implementation of the game, rendered by the web app and the Tauri
desktop app.

## Build outputs and how to regenerate them

There are **two** build outputs. Which one(s) you regenerate depends on where you
want your change to show up.

### 1. Web app + Tauri desktop → `ui/web/dist/`

The normal Vite build. The desktop (Tauri) app's `frontendDist` points at
`../web/dist`, so the desktop game *is* the web build — there is no separate
desktop artifact.

```sh
cd ui/web
yarn dev      # dev server, hot-reloads DropBlock changes live (web + `tauri dev`)
yarn build    # production build → ui/web/dist  (what the desktop app ships)
```

Nothing DropBlock-specific here: any change to the source files above is picked
up by the normal web/desktop build.

### 2. iOS — removed

iOS **no longer ships DropBlock.** The Bridge mini-game on iOS is now the native
SceneKit shooter **NEON STRIKE** (`ui/ios/Sources/Game/`; see
[SpaceShooter.md](SpaceShooter.md)). The old WebView path was removed:
`DropBlockGameView.swift`, the generated `ui/ios/Resources/dropblock-game.html`,
the `project.yml` pre-build bundling step, and the `bootstrap.sh` bundling step are
all gone — so a fresh `bootstrap.sh` no longer produces (or needs) the game HTML.

`src/dropblock-embed.jsx` and `scripts/build-dropblock-embed.mjs` remain in the web
repo (harmless; they'd let DropBlock be re-bundled for a WebView again), but
**nothing on iOS consumes their output** today.

## Input & platform behaviour

- **Touch** (mobile web): tap the left/right edge to move, tap the
  centre to rotate, tap-and-hold to soft-drop, swipe down to hard-drop. During a
  Pac-Man frenzy, swipes (4-way) or the tap zones steer it.
- **Keyboard** (desktop): arrows / Z-X / Space / Enter / Esc; `~` toggles debug
  (`b` = bomb next, `p` = Pac-Man next).
- **Desktop focus** (Tauri only): the game auto-pauses when the app window loses
  focus and resumes when it regains focus — unless you'd paused it yourself.

## Power-ups

Bomb (cross detonation) and Pac-Man (timed eating frenzy) drop in randomly
(`bombIn` / `pacIn` countdowns) and both fall ~1.69× faster than normal pieces,
show a faded ghost at their landing cell, and hold a 0.5 s beat before the next
piece spawns. See the source for the exact timings.
