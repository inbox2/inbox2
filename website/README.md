# website

The inbox2 marketing site — **React Router v7** (framework mode, SSR) deployed to
**Cloudflare** via the Cloudflare Vite plugin + Wrangler. A full component-based
port of the original static landing page.

## Stack

- **React Router v7** framework mode — file-based routing + SSR (`react-router.config.js` → `ssr: true`, `v8_viteEnvironmentApi`)
- **Cloudflare Workers** runtime via `@cloudflare/vite-plugin` (the successor to the Pages build pipeline); `workers/app.js` is the fetch entry, `wrangler.jsonc` the deploy config
- **CSS Modules + shared tokens** — global layers (`tokens` → `global` → `layout` → `effects`) + a `*.module.css` per component

## Layout

```
app/
  root.jsx                 document shell, fonts, .main wrapper, TopNav + Footer + SiteRuntime
  routes.js                route table (mirrors lib/nav.js internal links)
  routes/                  one SSR module per page: home, about, vision, download
  lib/
    nav.js                 TOP-NAV ROUTING RULES — single source for the header
    site-runtime.client.js client-only progressive enhancement (ported from ascii.js)
  styles/
    tokens.css             design variables (single source of truth)
    global.css             reset + typography utilities
    layout.css             bordered gutter|content|gutter grid + spacing helpers
    effects.css            runtime-driven classes (ascii tiles, feature tabs, quotes)
  components/
    Brand/                 Oxanium INBOX2 lockup (mark-right; tone light|dark)
    Button/                polymorphic link/button (cta, dark, fill, dark-fill)
    TopNav/ NavLinks       fixed scroll-reveal header, rendered from lib/nav.js
    Hero/                  full hero — nav, frosted block, hero grid, ASCII video bg
    OsBadges/              5 OS tiles with CSS boot animations (mac/win/linux/ios/android)
    Ascii/                 AsciiTile (video→glyphs) + AsciiShot (scroll-driven screenshot)
    Band/                  one bordered-grid section skeleton
    Section/               titled simple band (inner routes)
    Manifesto/             ownership manifesto, fade-to-light, data-driven
    Quote/ BigQuote/       scroll-fade pull quote + press-style big quote
    PlatformLogos/         "free native apps" download grid
    FeatureTabs/           auto-cycling feature tabs + ASCII screenshot
    Pricing/               3-tier Cloud MX pricing
    VisionCard/            open & offline-first link card
    Footer/                white highlight block + 4 link columns
    SiteRuntime/           mounts the client runtime on the client
    Icon/                  inline SVG icons
public/assets/             mark, icons, hero/pool/flow clips, app screenshots
```

## Top-nav routing rules

`app/lib/nav.js` is the single source of truth. Add an item there; for internal
links add a matching `route()` in `app/routes.js` and a module in `app/routes/`.
Current routes: `/` · `/about` · `/vision` · `/download`.

## Develop / build / deploy

```sh
yarn install --ignore-scripts   # --ignore-scripts avoids the transitive sharp postinstall
yarn dev                        # vite dev (Workers runtime emulated) → :5173
yarn build                      # react-router build → build/{client,server}
yarn deploy                     # build + wrangler deploy (uses build/server/wrangler.json)
```

> The animated ASCII overlays, OS-tile boot sequences, and feature-tab cycling
> are client-side — run `yarn dev` in a real browser to see them (they don't
> appear in headless/SSR-only renders).

## Screenshots and the product video

Every `public/assets/shots/*.webp` and `public/assets/video/tour*.mp4` is
generated, not hand-taken. Two scripts produce them; both are idempotent, so
rerun them whenever the app's UI moves.

```sh
# App screens — drives the DEV desktop app over the accessibility API.
python3 scripts/shots.py --seed        # rebuild + install the Brightfold demo DB
python3 scripts/shots.py               # every still, dark (Warm) + light
python3 scripts/shots.py --only inbox conversation --theme dark
python3 scripts/shots.py --video       # the looping tour, both themes

# Notification cards — the /notification page seeded from the URL hash,
# shot in headless Chromium against the running web dev server.
node scripts/uishots.mjs

# Phone screens (m-*.webp) — builds the iOS app for the simulator, seeds it with
# the same demo DB, drives the tab bar over idb. Both themes, like the desktop.
scripts/mobile-shots.sh
SKIP_BUILD=1 scripts/mobile-shots.sh
```

The phone stills come off the **simulator**, not the physical iPhone, which holds
real mail. The one thing the simulator will not do is a Live Activity —
ActivityKit refuses a push-token activity there — so the lock-screen card in the
Mobile section is drawn in CSS (`components/Mobile`, `LockScreen`) from
`ui/ios/Widgets/Inbox2Widgets.swift`. Change the card in the app and change it
there too.

`scripts/shots.py` talks to **`com.inbox2.desktop.dev`** only — the prod identity
(`/Applications/Inbox2.app`) holds real mail and is never touched. It needs
Accessibility + Screen Recording permission for the terminal, plus
`brew install cliclick webp ffmpeg`. `scripts/ax.swift` is the accessibility tree
dumper it drives with; osascript can read the same tree but costs one Apple Event
per attribute per node, which is a minute per query.

### Adding or changing a shot

- A screen is one function in `SHOTS` in `scripts/shots.py`. Navigate with the
  helpers (`go`, `go_channel`, `view`, `open_conversation`, `click`) and finish
  with `capture("<name>")` — the theme suffix is added for you.
- Controls are found by their **accessible name**, so an icon-only button needs
  an `aria-label` in `ui/web` before the script can reach it. Dump what is
  available with `swift scripts/ax.swift $(pgrep -f "Inbox2 Dev.app/Contents/MacOS")`.
- If a screen looks empty, add rows to `ui/desktop/scripts/seed_demo.py` rather
  than cropping the shot.
- The app resizes its own window (a modal, a view with its own minimum), which
  turns every cached coordinate into a click that lands on nothing and looks
  like a dead button. `to_chrome()` re-pins the window before each navigation —
  keep new navigation helpers going through it.
- `set_theme()` proves the switch took by sampling the window's corner
  brightness (needs Pillow) and aborts rather than writing one palette into the
  other theme's filenames. Without Pillow it trusts the click.
- Each run leaves the untouched 2x captures (3200x2000 PNG per screen) in
  `assets-src/shots/`. That directory is gitignored — the set is ~50MB — but it
  is what to re-crop or re-encode from instead of redriving the app. The tour's
  raw `.mov` is *not* kept: it is ~180MB a take and re-recording is one command.

### The dark/light switch

Both themes are captured for every screen: `<name>.webp` is the app's Warm dark
theme, `<name>-light.webp` its Light one. The floating switch
(`components/ShotThemeSwitch`) writes the choice to `localStorage` and
`lib/shotTheme.jsx` swaps the filename — so **a new screenshot must exist in both
themes or the light page will 404 the image**. `WindowFrame` and `Tour` resolve
their sources through `shotSrc()`; anything else that shows an app screen should
do the same.

The notification cards are deliberately exempt: that window is fixed light glass
in the product regardless of the app theme, so there is only one variant.

## TODO

- ESLint config mirroring ui/web (CSS Modules only, no inline styles)
- Wire the Cloudflare Pages/Workers deploy (this replaced the old static `website/` build)
