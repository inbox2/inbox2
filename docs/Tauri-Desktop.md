# Tauri Desktop Client

Native macOS/Windows/Linux desktop app wrapping the React web UI via Tauri v2. Adds offline-capable external mailbox sync (IMAP, Gmail, Microsoft) with local SQLite storage and encrypted credentials.

## Architecture

```
ui/desktop/
├── package.json              # Tauri CLI + JS deps (@tauri-apps/api, plugin-sql)
├── yarn.lock
└── src-tauri/
    ├── Cargo.toml            # Rust deps (tauri 2.11, imap, rusqlite, aes-gcm, etc.)
    ├── Cargo.lock
    ├── tauri.conf.json       # Window config, build commands, icons
    ├── capabilities/
    │   └── default.json      # Permissions (core:default, window dragging, sql, opener)
    ├── icons/                # App icon (inbox2 cube) at all required sizes
    ├── migrations/
    │   ├── 001_create_schema.sql       # Local message/conversation mirror
    │   └── 002_external_sync.sql       # External accounts, folders, provider state, writeback queue
    └── src/
        ├── main.rs           # Entry point
        ├── lib.rs            # Tauri builder: plugins, setup (titlebar, sync engine), commands
        └── sync/
            ├── mod.rs        # Module exports
            ├── engine/       # Sync engine: mod.rs (accounts) + sync_flow, queues, runtime, calendar, conversation_actions
            ├── store.rs      # SQLite operations (WAL mode, shared with tauri-plugin-sql)
            ├── model.rs      # Data models: UnifiedMessage, UnifiedFlags, ExternalAccount, etc.
            ├── commands.rs   # Tauri IPC commands: add/remove account, start/stop sync, etc.
            ├── actions.rs    # Writeback action types (mark_read, archive, move, delete, etc.)
            ├── provider.rs   # ProviderAdapter trait: connect, list_folders, fetch, push_flags
            ├── crypto.rs     # AES-256-GCM credential encryption/decryption
            ├── error.rs      # SyncError enum
            └── adapters/
                ├── mod.rs
                ├── imap_adapter.rs       # Real IMAP adapter (CONDSTORE, QRESYNC, IDLE)
                ├── gmail_stub.rs         # Gmail OAuth stub (placeholder)
                └── microsoft_stub.rs     # Microsoft Graph stub (placeholder)
```

## How it works

The desktop app loads the same React frontend (`ui/web/dist`) in a Tauri webview. The frontend detects the Tauri environment via `window.__TAURI_INTERNALS__` (see `ui/web/src/lib/tauri.js`) and can use Tauri-specific features.

### Window chrome

- **macOS**: `TitleBarStyle::Overlay` set in Rust (`lib.rs` setup) — native traffic lights overlaid on content, no visible title bar
- **Windows / Linux**: `Overlay` is macOS-only, so `setup.rs` drops the decorations instead (`set_decorations(false)`) and the chrome bar's right end carries minimize / maximize / close (`components/Chrome/WindowControls.jsx`, shown when `hasOwnWindowControls()`); a double-click on the bar maximizes. Close goes through `CloseRequested` → the quit confirm. The app menu is not set there either (it would draw a menu bar inside the window), so ⌘W/⌘Q accelerators are macOS-only.
- **Windows (verified 2026-11-07 on a Windows 11 26H2 ARM64 VM, the x64 build under emulation)**: undecorated window with its own controls, double-click maximize, the custom new-mail card with working actions, `inbox2-dev://` deep links to the running instance, second launch focusing the first, and the credential key in Credential Manager (`credential-key.com.inbox2.desktop`, no `.credential_key` file) all work. Two Windows-only paths: the unread badge is an overlay icon drawn on a canvas (`hooks/useDockBadge.js`, `setBadgeCount` is a no-op on Windows), and the tray popover opens above the icon because the taskbar sits at the bottom (`tray.rs` flips when the icon is in the lower half of the screen). Windows also never delivers the `Focused(false)` event that hides the popover elsewhere (keyboard focus sits in the WebView2 child), so after showing it `tray.rs` polls `is_focused()` every 150 ms and hides it once it stops being the active window. The installer bundles the Visual C++ runtime DLLs beside the exe (`tauri.windows.conf.json`), without which a clean Windows exits the app at once; see `docs/Desktop-Release.md`. Acrylic could not be judged in the VM (no GPU composition).
- **Linux keyring**: the credential key lives in the Secret Service (gnome-keyring / KWallet) like on macOS. When that fails (no daemon, no default collection — a fresh KDE session in a container died with "No default store has been set"), `core/sync/crypto.rs` falls back to the owner-only `.credential_key` file on a fresh store (no `.credential_keyring` marker and no `inbox2.db` yet, so installs from before the marker count as keyring-keyed) and keeps using it from then on. A store that already took its key from the keyring is marked with `.credential_keyring` and never falls back (the failure surfaces as `KeychainLocked` and is retried), so an outage cannot strand credentials encrypted with the keyring key.
- **Linux deep links**: the `.deb` desktop entry comes from `src-tauri/deb/inbox2.desktop` (`bundle.linux.deb.desktopTemplate`), whose `Exec` line carries `%u`. Tauri's default template registers the `x-scheme-handler` MIME type but passes no URL argument, so `inbox2://` links opened the app without the callback (found 2026-11-07 on Kubuntu 26.04). The listener logs every delivered URL as `[deep-link]`.
- **Linux tray**: the appindicator backend emits no click events, so the tray is a menu (Open Inbox2 / Quit Inbox2) and the `/tray` popover is not built (`tray.rs`). Wayland can't position popup windows: the new-mail card falls back to the system notification (see `docs/Notifications.md`).
- **Dark theme**: Forced via `set_theme(Theme::Dark)` in setup
- **Drag region**: The app's chrome bar uses `onMouseDown={startDrag}` which calls `getCurrentWindow().startDragging()` from `@tauri-apps/api/window`. This is more reliable than `data-tauri-drag-region` across multiple screens on macOS
- **Auth pages**: An invisible 36px drag strip at the top (only visible in Tauri via `[data-tauri]` CSS selector)
- **Traffic light padding**: 78px left padding on the chrome bar when `[data-tauri]` is set
- **Background throttling is off** (`"backgroundThrottling": "disabled"` on the main window, which sets WKWebView's `inactiveSchedulingPolicy` to none on macOS 14+). With the default policy WebKit suspends a webview it considers inactive. The ActionCable socket then stays "open" but no frames arrive, and new MX mail (`OrganizationChannel`) and push resyncs (`PushSyncChannel`) never reach the app, while the badge and the 30s failsafe still move. This was found on 2026-09-19: the desktop had logged no broadcast all day, though the server delivered each one. The new-mail popup (`/notification`, hidden between alerts) opens no sockets at all (`AuthProvider` skips PushSync and the org streams there).

### External mailbox sync

The sync engine runs in the Rust backend, not in the webview. It:

1. Connects to external IMAP/Gmail/Microsoft accounts
2. Lists and maps folders to well-known roles (inbox, sent, drafts, archive, trash, spam)
3. Incrementally syncs messages using CONDSTORE/QRESYNC for efficiency
4. Stores everything in local SQLite (WAL mode for concurrent reads)
5. Encrypts credentials at rest with AES-256-GCM
6. Queues writeback actions (mark read, archive, move, delete) for async push to the provider

It starts in `lib.rs` `setup()` (open store → elect bus host → spawn run loop +
boot accounts) and is torn down on `RunEvent::ExitRequested` by
`graceful_shutdown()` — which stops the engine (non-blocking even mid-sync),
releases the `engine.sock`, and kills the AI sidecar processes, all logged. The
full sync flow — lifecycle, the one-sync-per-account concurrency model, the
`sync` event backbone (+ Console backfill), and the failure/restart semantics —
is documented in **[docs/Channels.md](Channels.md)** ("Engine lifecycle" and
"How a sync runs").

### Tauri IPC commands

Exposed via `tauri::generate_handler!` in `lib.rs`:

| Command | Description |
|---------|-------------|
| `add_external_account` | Register a new IMAP/Gmail/Microsoft account |
| `remove_external_account` | Disconnect and remove an account |
| `list_external_accounts` | List all configured accounts with status |
| `start_sync` | Begin syncing an account |
| `stop_sync` | Stop syncing an account |
| `get_sync_status` | Poll sync progress/errors |
| `get_syncing_accounts` | Keys of accounts with a sync in flight (seeds the "Syncing…" indicator on mount) |
| `get_sync_log` | Recent `sync` events for the Sync Console to backfill on mount |
| `get_account_diagnostics` | Adapter/poll state + local-DB counts for the Sync Console |
| `queue_writeback_action` | Queue a flag/move/delete action |
| `list_external_folders` | List folders for an account |
| `clear_local_data` | Shut down, wipe the local DB + caches, and restart the app |

### Permissions (capabilities)

`src-tauri/capabilities/default.json` grants:

- `core:default` — standard Tauri APIs
- `core:window:allow-start-dragging` — programmatic window drag
- `core:window:allow-minimize`, `core:window:allow-toggle-maximize` — the chrome bar's window controls on Windows/Linux
- `sql:default` — SQLite plugin
- `opener:default` — open URLs in default browser

## Running

```sh
cd ui/desktop

# Development (starts Vite dev server automatically if not already running)
yarn dev

# Production build
yarn build
```

The `beforeDevCommand` in `tauri.conf.json` checks if port 4173 is already in use (e.g., from `bin/dev`) before starting Vite.

## Side-by-side Dev & Prod builds

Two identities can be installed and **run at the same time** — one for real mail,
one with demo data and a golden "DEV" badge on the icon:

| | Prod | Dev |
|---|---|---|
| Bundle identifier | `com.inbox2.desktop` | `com.inbox2.desktop.dev` |
| App name | **Inbox2** | **Inbox2 Dev** (golden badge) |
| Data dir | `~/Library/Application Support/com.inbox2.desktop` | `…/com.inbox2.desktop.dev` |
| Keychain credential key | service `com.inbox2.desktop` | service `com.inbox2.desktop.dev` |
| Data | your real accounts | the demo/seed database |
| How you run it | `/Applications/Inbox2.app` | `yarn dev` (or `yarn install:app:dev`) |

Because the data dir, Keychain entry, single-instance lock, and IPC bus socket
all key off the identifier, distinct identifiers give each build a fully
independent universe — they don't see each other's mail and both can run at once.

### Which API each bundle talks to

A bundled `.app` is **not** same-origin with anything. Its webview runs on the
custom scheme (`tauri://localhost`), so a relative `/api/v1` resolves against a
scheme no HTTP client can reach — and `window.location.origin` is useless as an
API base for the same reason. `yarn dev` hides this, because there the webview is
`http://localhost:4173` and the Vite proxy forwards `/api` for free.

So each bundle bakes its API origin at build time, via its own
`beforeBuildCommand`:

| Build | `VITE_API_ORIGIN` |
|---|---|
| `tauri.conf.json` (prod) | `https://api.inbox2.com` |
| `tauri.dev.conf.json` (dev) | `http://localhost:4000` |
| `yarn dev` | unset — the Vite proxy handles it (`INBOX2_API_ORIGIN` picks the target) |

Frontend code must read the base through **`apiBaseUrl()`** in
`lib/apiOrigin.js`, never `window.location.origin` — that helper prefers
`API_ORIGIN` and falls back to the location origin only for the genuinely
same-origin cases (dev proxy, in-cluster web).

Because the bundle is cross-origin, the API has to allow it: `Rack::Cors` in
`api/config/application.rb` always permits the desktop webview origins alongside
`FRONTEND_URL` (which accepts a comma-separated list). Desktop auth is a Bearer
token from the engine's encrypted store, not the session cookie, so no cookie
work is needed.

### How the identifier is threaded

The identifier must agree in two places:

- **Runtime** — the GUI's DB path comes from Tauri's `app_data_dir()`, set by the
  `identifier` field in the config. `tauri.dev.conf.json` overrides it to
  `com.inbox2.desktop.dev` (also overrides `productName`, the `icons-dev/` icon
  set, the deep-link scheme `inbox2-dev`, and disables updater artifacts).
- **Compile time** — `BUNDLE_ID` in `core/src/lib.rs` (used by the Keychain
  service in `crypto.rs`, `default_data_dir()`, MCP, and the headless binaries)
  reads `INBOX2_BUNDLE_ID` via `option_env!`, defaulting to `com.inbox2.desktop`.
  `core/build.rs` emits `rerun-if-env-changed` so switching identities forces a
  recompile. The `dev` npm script sets `INBOX2_BUNDLE_ID=com.inbox2.desktop.dev`.

### Scripts

```sh
# Dev loop — golden "Inbox2 Dev", demo data (com.inbox2.desktop.dev)
yarn dev
yarn dev:prod          # run the dev loop against the PROD identity/data instead

# Install a signed app into /Applications (macOS, Developer ID signed)
yarn install:app       # Inbox2      → /Applications/Inbox2.app      (real mail)
yarn install:app:dev   # Inbox2 Dev  → /Applications/Inbox2 Dev.app  (demo data)

# Fill the DEV identity with the fake demo database (see "Demo environment")
python3 scripts/seed_demo.py --install --dev

# One-time: empty the prod data dir so Inbox2.app starts clean for real mail
#   (the demo DB is preserved in the dev dir). Quit all Inbox2 apps first.
scripts/use-real-data.sh
```

**Quit `yarn dev` before `yarn install:app`.** A release build and the watcher
contend for the same Cargo artifact lock, and the build just appears to hang.

`scripts/install-local.mjs` builds for the current Mac, Developer-ID-signs it
(`APPLE_SIGNING_IDENTITY`, default = the project owner's cert — override with your
own; `-` for ad-hoc), strips the quarantine bit, and copies the `.app` into
`/Applications`. The prod identity is stamped with `bin/version` and carries the
release updater config, so a local install auto-updates off
`api.inbox2.com/downloads/desktop` like a shipped one (see
[Desktop-Release.md](Desktop-Release.md)). Notarization is skipped — a locally-built, locally-signed app
launches without it. A stable Developer ID signature keeps the Keychain ACL
stable, so stored mailbox credentials aren't re-prompted across rebuilds.

### Regenerating the prod app icon

Source art is a single SVG (`~/Desktop/visuals/inbox2/inbox2-icon-ring-two.svg`
— a gradient-ring squircle). `tauri icon <1024.png>` regenerates every file in
`src-tauri/icons/` (`.icns`/`.ico`/PNG sizes + Windows `Square*Logo.png`); it
also emits stray `android/`, `ios/`, `64x64.png` the desktop build doesn't use —
delete them.

**macOS Big Sur grid — leave the padding.** macOS renders the icon inside a
fixed grid: the rounded-rect body must occupy **824px of the 1024 canvas** (~100px
transparent margin each side). Art that fills edge-to-edge renders visibly
*larger* than neighboring Dock icons. Our SVG's own squircle spans 960/1024, so
scale it down before feeding `tauri icon`:

```sh
# squircle 960/1024 → render at 879 so the squircle lands at 824, center on transparent 1024
rsvg-convert -w 879 -h 879 inbox2-icon-ring-two.svg -o art879.png
magick art879.png -background none -gravity center -extent 1024x1024 icon-1024.png
cd ui/desktop && yarn tauri icon icon-1024.png
rm -rf src-tauri/icons/{android,ios,64x64.png}
python3 scripts/make-dev-icons.py     # re-stamp the DEV set from the new prod art
```

Then relaunch `yarn dev` — its Dock icon reads `icons-dev/`, so the prod-icon
change isn't visible until `make-dev-icons.py` reruns (below).

### The golden DEV icon

`src-tauri/icons-dev/` is the prod icon **stamped with a gold "DEV" corner
badge** — the base art is never resampled (no border, no size/brightness drift).
Regenerate with `python3 scripts/make-dev-icons.py`, which composites the badge
directly onto each native prod asset (the `.icns` is rebuilt from the per-size
iconset slices, so the macOS Dock stays pixel-faithful to prod).

A `tauri dev` run is a bare binary, not an `.app`, so macOS ignores `bundle.icon`
and would show a generic Dock icon. `setup.rs::apply_dev_dock_icon` (called from
`apply_window_chrome` only when `BUNDLE_ID` ends in `.dev`) sets the Dock icon at
runtime from the embedded `icons-dev/icon.png`, so `yarn dev` shows the golden
badge too. The installed `.app`s carry their own `.icns` and are unaffected.

## Demo environment (screen recordings)

The point of the dev identity is that videos never show real mail. A full demo
environment is two halves plus one real account, all under
`com.inbox2.desktop.dev`:

**1. Local channels — the fake half.** `scripts/seed_demo.py --install --dev`
builds a fresh SQLite DB from the canonical schema and swaps it into the dev data
dir (the previous one is renamed `inbox2.db.bak_<timestamp>`, never deleted). It
seeds the fictional studio **Brightfold** across five connected channels — Gmail,
Outlook, WhatsApp, Instagram, Messenger — with read/unread mix, replies,
reactions, attachments, all four triage quadrants, a dense Explorer graph and a
couple of weeks of calendar events.

**Screenshots and attachments.** Threads carry inline artwork the way real mail
does — an app mockup, a bar chart, a logo-lockup sheet, a packaging dieline — all
SVG data-URI for the same `img-src data: blob:` reason as above, plus two threads
with a genuinely remote photo so the blocked-images banner fires here too.
Attachments are filenames + sizes on the message (`attachment_names`,
`attachment_max_size`): 11 conversations get a paperclip, and `has:attachment`,
`larger:10mb`, `smaller:200kb`, `type:pdf` and `filename:` all return real
results. **The reading pane's attachment chips will not appear** — those come
from a live `fetchMessage` call to the provider, and the demo accounts have no
credentials. There is no local attachments table to seed instead; the bytes only
ever exist provider-side.

Dates anchor to **now**, not a constant, so nothing reads as two months stale on
camera. Pin them with `INBOX2_SEED_NOW=2026-06-26T17:30:00Z` when you need a
reproducible build.

`app_secrets` are carried over from whatever DB is already in the target dir, so
re-seeding between takes doesn't log the dev app out of MX.

**2. MX — the hosted half.** `cd api && bin/rails demo:brightfold` builds the
same studio as an inbox2-hosted org against your local Rails:

| | |
|---|---|
| Org / domain | `Brightfold` / `brightfold.com` (status `receiving_mail`) |
| Team | 6 members, login `sam` / `aria` / `noor` / `jonas` / `mina` / `rafa`, password `password123` |
| Mailboxes | 6 personal + `hello@` `new-business@` `billing@` `support@` `press@` |
| Mail | ~99 conversations / ~109 messages over 9 weeks, ~31 unread |
| Newsletters | 6 hand-authored HTML marketing emails — product update, dark gallery, e-commerce (German), event, editorial serif, swatch promo (French) |
| Also | 7 tags, 5 spaces (staffed), 4 routing rules, system views |

The newsletters exist because a demo made only of prose mail doesn't exercise the
reader — table layouts, dark templates, image grids and non-Latin copy are what
show it off.

**Artwork is inline SVG data-URI, except where it deliberately isn't.** The
reader's iframe runs `img-src data: blob:` and blocks remote images until the
reader consents, so art built on remote `<img>` tags needs the network and
renders as broken frames without it. Three newsletters (Kessler, DesignOps,
Paperhouse) carry one **remote** hero anyway — otherwise the "images blocked /
Show images" banner can never fire on camera. Each is laid out to still read as
a finished email with its hero missing, and every remote `<img>` carries explicit
`width`/`height` so consenting doesn't jump the card. The other three render
fully offline.

The domain split is deliberate: **`brightfold.com` is MX**, **`brightfold.co` is
the local channels**. Same company, same people, same clients on both sides — no
address appears twice. The task is idempotent (it rebuilds thread bodies in
place), so edit the tables and re-run.

`bin/rails demo:purge_e2e` drops leftover `e2e-console-*.test` domains that
console e2e runs leave behind; `bin/rails demo:reset` destroys the org and
rebuilds from scratch.

**3. One real account.** Connect a throwaway Google account in the dev app
normally. It lives in the dev identity's own Keychain entry
(`com.inbox2.desktop.dev`), so it can never touch prod credentials.

Prerequisites: local Rails on `:4000` (`bin/rails db:migrate` first — a pending
migration 500s every request, including `/up`), and the dev bundle built after
the `VITE_API_ORIGIN` wiring above, or it can't reach local MX at all.

**Attachments need Garage.** `demo:brightfold` puts real files (including a
hand-built valid PDF) on the five threads whose copy says there's an attachment,
and uploads the bytes to the local object store. It degrades cleanly: with no
Garage the rows still exist, so the chips and the row paperclip render and only
the download is unavailable — the task prints which of the two you got. The
herdr `garage :4900` pane brings it up and runs `bin/garage-init`; see below.

## Menu bar item (macOS tray)

A template icon in the menu bar (the app-icon box with the 2 knocked out — `brand/inbox2-tray-template.svg` → `src-tauri/icons/tray-template.png`, alpha only, the system tints it). Clicking it toggles a popover: the five newest unread threads with their summaries, "Coming up", and the month with the same day-hover preview the calendar sidebar has. It follows the selected theme. Design canvas: "inbox2 menu bar widget".

- **Rust — `src-tauri/src/tray.rs`.** `tray::init` builds the `TrayIcon` (Tauri `tray-icon` feature). A left click lazily creates the `tray` window on the web app's `/tray` route, places it under the icon, shows + focuses it and emits `tray-opened`; `WindowEvent::Focused(false)` hides it again. `tray_set_title` sets the text beside the icon, `tray_hide` closes the popover from the page. The window is on the window-state denylist and in `capabilities/default.json` (it needs `sql` + events).
- **A non-activating NSPanel that may become key.** Opening the popover must not activate inbox2 — as a plain window it did, and every click on the menu bar dragged the main window to the front. So `tray.rs` converts it with tauri-nspanel and shows it with `panel.show()` (order front + make key, no activation). The notification popup's swizzle makes every `RawNSPanel` refuse key status; this panel is let through by identity (`commands::KEYABLE_PANEL`), because resign-key is what closes it and Escape needs a key window. A click on the icon while it is open blurs it on mouse-down, so the click's mouse-up is swallowed for 400ms (`SETTLE`) rather than reopening it.
- **Wider than it looks.** The window is 620px and transparent; the 360px card sits at its right edge so `MiniCalendar`'s `DayPeek` has a gutter to fly out into (a webview can't draw outside its window). A mousedown on the gutter hides the popover. The widths in `tray.rs` and `TrayPage.module.css` must agree.
- **Web — `pages/tray/TrayPage.jsx`.** Reads its own data on every `tray-opened`: `lib/trayData.js#fetchLatestUnread` (local channels from SQLite with the unread badge's exact inbox test, MX through the local-first API with `read=false`), and the calendar rail's `fetchEventsInRange`. It reuses `MiniCalendar`, `EventListItem`, `Avatar`, `IconButton`, `Button`. Opening a thread / the calendar is handed to the main window over `notification-navigate`: a `date` opens that day in day view, and an `eventId` (a "Coming up" row) also routes to the calendar's `/:orgSlug/calendar/:eventId` deep link so the event's detail popup opens — keyed on the navigation as well as the id, so asking for the same meeting twice reopens it. Rows with a join link (`fetchEventsInRange` → `meeting`, from `detectMeeting`) get a **Join** button that opens the link directly; mark-read / archive go through `runNotificationAction` and echo the badge change to the main window via `unread-adjust`.
- **The title is driven from the main window** (`hooks/useTrayTitle.js` → `lib/trayTitle.js`, mounted beside `useDockBadge`), because the hidden tray webview is suspended by WebKit. Format: unread count, plus — within an hour of it — the next meeting, Outlook-style: `12 · Standup · in 10m`.
- **`/tray` and `/notification` are "aux windows"** (`lib/auxWindow.js`): no command palette, notifiers, activity float or realtime sockets.
- **Event colours are shared** (`lib/calendarColors.js`): the full calendar assigns a pastel per calendar and records the map in localStorage (`CALENDAR_PASTELS`); the sidebar/rail `DayPeek` and the popover look it up, and `DayPeek` draws the same solid fill + dark ink as the grid. Before this the grid was pastel while the day preview tinted the provider's own colour.
- **Known gaps:** calendar data is local-channel only, like the calendar rail (MX calendars aren't in SQLite) — that covers both "Coming up" and the meeting in the title; no compose / new-event buttons (the main window has no event to open either); the title format isn't a setting yet; no colour in the menu bar text (a template icon + plain title can't carry the calendar's colour square from the mockup).

## Testing

```sh
# Start the GreenMail test IMAP server (root compose, `test` profile)
docker compose -f docker/docker-compose.yml --profile test up -d

# Run integration tests
INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 \
  IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 \
  cargo test --manifest-path ui/desktop/src-tauri/Cargo.toml --test imap_integration -- --ignored

# Test credentials: testuser / testpass
```

## Build config

Key settings in `tauri.conf.json`:

| Setting | Value | Notes |
|---------|-------|-------|
| `productName` | Inbox2 | App name in menubar/dock |
| `identifier` | com.inbox2.desktop | macOS bundle ID |
| `frontendDist` | `../web/dist` | Built React app |
| `devUrl` | `http://localhost:4173` | Vite dev server |
| `window size` | 1440 x 900 | Default, min 900 x 600 |
| `decorations` | true | Native frame (overlay on macOS) |

## Dependencies

### Rust (Cargo.toml)

| Crate | Purpose |
|-------|---------|
| `tauri` 2.11 | App framework |
| `tauri-plugin-sql` | SQLite access from JS |
| `tauri-plugin-log` | Structured logging |
| `tauri-plugin-opener` | Open URLs |
| `imap` 2.4 | IMAP protocol client |
| `native-tls` | TLS for IMAP |
| `rusqlite` 0.31 | Direct SQLite (sync engine) |
| `aes-gcm` 0.10 | Credential encryption |
| `tokio` | Async runtime |
| `parking_lot` | Fast RwLock |
| `mailparse` | Email header parsing |
| `chrono` | Timestamps |

### JavaScript (package.json)

| Package | Purpose |
|---------|---------|
| `@tauri-apps/api` | Window, IPC, system APIs |
| `@tauri-apps/plugin-sql` | SQLite from JS side |
| `@tauri-apps/cli` | Build tooling (dev dep) |

## Demo seed data

`ui/desktop/scripts/seed_demo.py` builds a fresh `inbox2.db` from the canonical
schema (`core/migrations/001_create_schema.sql`) and fills it with on-brand fake
data for a fictional studio "Brightfold" running five channels (Gmail, Outlook,
WhatsApp, Instagram, Messenger). It exists so every screen looks alive for demo
recordings.

```sh
python3 ui/desktop/scripts/seed_demo.py            # build only -> /tmp/inbox2-seed/inbox2.db
python3 ui/desktop/scripts/seed_demo.py --install  # build + swap into the desktop data dir
```

What it covers, and the contract each screen imposes:

- **Unified inbox + per-channel** — ~80 threads, read/unread mix, replies,
  reactions, attachments. A conversation only surfaces if it has a
  `message_provider_state` row pointing at the account's `well_known_role='inbox'`
  folder, so the script always creates folder + messages + mps per conversation.
- **Triage (Eisenhower matrix)** — all four quadrants are populated. The matrix
  buckets purely on the three priority booleans (`priority_urgent`,
  `priority_important`, `priority_triaged` = the "Later" marker), **not** on
  `triage_label` (see `EisenhowerMatrix.jsx` / `useUnifiedInbox.js`).
- **Reading-pane AI** — `triage_label` chips + `ai_summary_short`/`_medium` on the
  AI-classified threads (the eight `TriageLabel` values from `core/src/triage.rs`).
- **Explorer (Command Center graph)** — the local graph is computed client-side
  from **email conversations only** (`channel IS NULL`); a sender needs ≥2
  conversations to become a contact node and `to_address` drives mailbox nodes
  (see `useExplorerGraph.js`). The script uses a recurring-contact roster spread
  across several mailboxes so the graph is dense with real edges (~22 contact
  nodes).
- **Calendar** — ~3 weeks of events around the anchored "today".

`--install` is non-destructive: it refuses to run while the desktop app is open
(it holds the DB + WAL), renames the live `inbox2.db{,-wal,-shm}` to
`*.bak_<timestamp>` before copying the seed in, and carries `app_secrets` over
from the previous DB so the engine/session still authenticates. Pass `--force`
to install anyway (not recommended while the app runs). The "now" anchor and
roster live at the top of the script — edit there to extend the dataset.

## Drag out of the window

Attachments and WhatsApp media drag out of Inbox2 into Finder, Mail and other apps as real files (`tauri-plugin-drag` + `@crabnebula/tauri-plugin-drag`, capability `drag:default`).

- macOS starts a drag only inside the mouse event, so nothing may be awaited once it begins. The page
  finds the file ahead, on hover (`ui/web/src/lib/dragOut.js`: `prepareFile` / `dragFile`); a lookup
  that finds nothing isn't remembered, so the next hover looks again.
- **Attachment chip** (`MessageDetails`): the file in the per-message attachment cache
  (`attachment_cache_path`). Hover only looks it up — nothing downloads for a drag. An attachment
  not on this Mac yet refuses the drag with a shake ("Open it once, then you can drag it out");
  opening it (or Save as / Forward) caches it, and from then on it drags.
- **WhatsApp media**: the file in WhatsApp's container (docs/Local-WhatsApp.md).
- Drag pictures: a photo is its own picture; anything else uses the app icon (`drag_fallback_icon`).

**Export as .eml** (the message's actions menu, `lib/mailDrag.js exportEml`): a save dialog on desktop
(`save_attachment_as`), a download on web. Local channels save the provider's raw source (attachments
included); MX keeps no raw MIME, so `buildEml` writes headers + plain/HTML bodies and embeds each
attachment (fetched, sealed ones decrypted) as a multipart/mixed part. Which path is decided by the
thread's provider type, not the route's org.
