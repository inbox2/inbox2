# Android App — feature-set, layout & architecture

The native Android client (`ui/android/`): a Jetpack Compose shell over the **shared
Rust core** (`inbox2-core`, via UniFFI Kotlin bindings) and the **shared
`@inbox2/email-body` JS** (rendered in a `WebView`). It is a feature-by-feature port of
the iOS app — same core, same SQL, same FFI surface, same screen model — with only the
UI layer rebuilt (SwiftUI → Compose). Dark-first, design tokens identical to iOS.

Companion docs: [iOS-App.md](iOS-App.md) (the parity source), [Channels.md](Channels.md)
(the Rust sync engine), [Vector-MCP.md](Vector-MCP.md).

---

> **MX mail (2026-09-20):** inbox2-hosted mail is mirrored into local SQLite by the engine and read here through `cloud/MxMirror.kt` + the `mx…` reads in `data/InboxStore.kt`. Protocol, rules (incl. sealed mail never reaching an agent) and status: [MX-Sync.md](MX-Sync.md).

## 1. Architecture

```
┌─ Compose UI (ui/android/app) ─────────────────────────────┐
│  Screens + Components + theme                             │
│     reads ↓ (SQLite, direct)        writes ↓ (FFI)        │
├─ Data layer ──────────────────────────────────────────────┤
│  InboxStore (SQLite, read-only-ish)   EngineModel (FFI)   │
├─ Generated UniFFI bindings (uniffi/.../inbox2_core.kt) ───┤
│  InboxEngine object + EngineEventListener callback        │
├─ inbox2-core (Rust, ui/desktop/core) ─────────────────────┤
│  SyncEngine · SyncStore (SQLite) · adapters · rules       │
└────────────────────────────────────────────────────────────┘
```

**The split (identical to iOS/desktop):** the UI **reads conversations/messages
straight from the local SQLite `inbox2.db`** (`InboxStore`, a read-write handle used
SELECT-only over WAL) and only **writes through the Rust engine** (`EngineModel` →
`InboxEngine` FFI). The engine pushes `(event, payload_json)` to an
`EngineEventListener`; `EngineModel` bumps `dataVersion`; Compose screens re-query via
`LaunchedEffect(dataVersion, …)`.

**Two modules:**
- **`:inboxcore`** — wraps the Rust core. It points its `jniLibs` + `java` source dirs
  straight at what `ui/desktop/core/build-android-jni.sh` produces
  (`../desktop/target/android-jniLibs/<abi>/libinbox2_core.so` and
  `../desktop/target/uniffi-kotlin/uniffi/inbox2_core/inbox2_core.kt`), and depends on
  `net.java.dev.jna:jna` (the UniFFI runtime). Re-run that script after any Rust change.
- **`:app`** — the Compose app.

**Body rendering stays in JS.** `assets/email-body.js` (the bundled `@inbox2/email-body`)
runs inside a `WebView` for quote/signature collapse + remote-image blocking — the same
module the iOS `WKWebView` and the desktop iframe use. The only platform difference is
the host page's bridge: iOS uses `webkit.messageHandlers`, Android an
`addJavascriptInterface` object (`AndroidBridge`).

---

## 2. Build & run

Prerequisites: Android SDK + an NDK under `~/Library/Android/sdk`, JDK 17 (the driver
finds the Homebrew one), `cargo-ndk` + the Android Rust targets, and an AVD
(e.g. `Pixel_7_API_35`).

```sh
# one-time: rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#           cargo install cargo-ndk

bin/android core      # build inbox2-core for Android (3 ABIs) + Kotlin bindings
bin/android run       # boot emulator + build + install + launch
bin/android seed      # copy the desktop inbox2.db + .credential_key (real mail, no OAuth)
```

`bin/android` is the build/drive driver (the Android analog of the iOS XcodeBuildMCP /
simulator tooling): `core · build · boot · install · run · launch · stop · seed ·
screenshot · ui · tap · swipe · text · key · logcat · devices`. The same surface is
exposed as an **MCP server** at `ui/android/tools/android-mcp/` (registered in
`.mcp.json`) so an agent can drive the emulator the way it drives the iOS simulator.

Logs: `adb logcat -s com.inbox2.core` (the Rust core, via `android_logger`) and
`com.inbox2.engine` / `com.inbox2.store` (the Kotlin layer).

---

## 3. FFI surface

Identical to iOS (see [iOS-App.md §3](iOS-App.md)). The `mobile-ffi` UniFFI surface in
`inbox2-core/src/ffi.rs` generates `InboxEngine` + `EngineEventListener` + `OnDeviceLlm`
+ the `Ffi*` records for Kotlin exactly as for Swift. `EngineModel` (Kotlin) wraps it:
`StateFlow` `dataVersion`/`accounts`/`syncing`/`modelDownloads`, suspend helpers for
every write/bridge/model-manager call (off the IO dispatcher), and a one-shot device
profile at start (`os="android"`, `android_native_speech` from `SpeechRecognizer`, no
native LLM lane).

**Rust changes for Android** (`ui/desktop/core/Cargo.toml`):
- **Vendored OpenSSL** for the `android` target — `native-tls` (used by `imap`/`lettre`)
  has no system SSL there, unlike iOS/macOS (Secure Transport). `openssl-sys` with
  `features=["vendored"]` compiles it from source via the NDK clang.
- **Platform logging split** — `oslog` on Apple, `android_logger` (logcat) on Android,
  both gated on `mobile-ffi`; `init_logging` picks per `cfg(target_os)`.

---

## 4. Data layer — `InboxStore` (SQLite reads)

A 1:1 Kotlin port of the iOS `InboxStore` (`android.database.sqlite`, read-write handle /
SELECT-only, WAL). Every query is ported verbatim: inbox (provider-folder join),
folder-role (Sent), triage-label, drafts, the Triaged cross-folder filter, FTS5 search
(`buildFtsMatch`: AND-ed quoted terms, `or`/`and`, trailing `*`), unread count, recent
activity, local rules/agents, outbox, frequency-ranked contacts (cached), calendar
(upcoming + window), writable calendars, and thread messages. Shared row models
(`Conversation`/`Message`/`CalendarEvent`/…), `MailAddress`, `RelativeTime`, and
`ConversationAction` (verb/reverse/title/icon/removesRow/restore) are ported verbatim.

---

## 5. Screens (Compose)

Root: `MainActivity` → `Inbox2Theme` → `RootTabs`. `RootTabs` is the shell: the active
tab + a floating capsule nav (`FloatingNavBar`) — Inbox · **Lore** · **compose**
(center, violet `paperplane`) · Calendar · Settings. Overlays (folder drawer, reader,
compose, add-account, model panel, mx sign-in) are state-driven; the floating nav hides
while any detail screen or multi-select edit mode is up. **`BackHandler`** pops
overlays/tabs in order so Android back behaves like the screen stack.

| Screen | File | Notes |
|---|---|---|
| **Inbox** | `InboxScreen` | hamburger + title, search, channels row (Unified + per-account + **mx** when signed in), filter pills (All/Unread/Triaged), conversation list. Swipe → archive/restore (trailing) + toggle-read (leading) with a 5s **glow undo toast** dropping from the top. **Long-press → multi-select**: the **bulk-action bar replaces the nav** in the same spot (Read/Archive/Triage/Trash, account-grouped over one `perform_action`; Move-to-Inbox in restore folders). Outbox folder → queued/failed sends with retry + cancel. |
| **Folder drawer** | `FolderDrawer` | Mailboxes (Inbox/Sent/Drafts/Outbox/Archive/Trash) + Triage quadrants (with the desktop Eisenhower tints/glyphs). |
| **Reader** | `ReaderScreen` | Collapsible AI summary, a stack of per-message cards (newest expanded), each rendering the body via the self-sizing `MessageBodyWebView` (shared `email-body.js`), sentiment/intent badges, show-images banner, reply/reply-all/forward + archive/trash. |
| **Compose** | `ComposeScreen` | From picker, To/Cc/Bcc, Subject, body, attachments, send → outbox FFI (or the cloud API for a domain identity). Pre-loaded attachments arrive via `ComposePrefill.initialAttachments` (e.g. a share-in). |
| **Calendar** | `CalendarScreen` | Upcoming/Calendar `SegmentedTabs`; agenda grouped by day with per-calendar color bars. (Month grid is the documented follow-up.) |
| **Settings** | `SettingsScreen` | Connected accounts (+remove, + add → OAuth/IMAP), **inbox2 mx** sign-in/identity/out, On-device AI, Auto rules, App logs, About. |
| **Add account** | `AddAccountScreen` | Google / Microsoft (loopback OAuth) / IMAP form. |
| **Lore** (tab 1, was the Bridge) | `LoreScreen` + `engine/Lore.kt` | Port of iOS `LoreView` (same rules as web `lib/lore.js`). Rows = `InboxState.reload` in unified mode (local channels + every MX org pool, inbox only) narrowed to Lore-labelled threads: Next-up card (Open → reader overlay, Done), bucket checklists with 44dp checkboxes + swipe-left = done (`InboxState.applyAction` → `performRouted`, the inbox's own archive path), **My todos** (`lore_todos` via `EngineModel.loreTodos/addLoreTodo/completeLoreTodo`) with an Add-todo field, and suggest-only **Handled for you** (Archive N / Delete N). Pull-to-refresh syncs. A floating mic opens `BridgeScreen` as an overlay (`onClose` adds an ✕ beside the VOXEL STRIKE button). Android Auto keeps `BridgeCarScreen`. |
| **Bridge** | `BridgeScreen` | The assistant, now opened from Lore's mic: a **Compose-canvas orb** (the Android alternative to the iOS Metal sphere) + a daily brief via the shared Rust bridge. |
| **On-device AI** | `ModelPanelScreen` | The three-lane (Device/Free/OpenAI) model panel per capability, rendered from the shared Rust model manager (`model_lanes`), with free-lane download/delete + live progress. |

**Share target ("Send to inbox2").** `MainActivity` declares `ACTION_SEND` +
`ACTION_SEND_MULTIPLE` intent filters (`*/*`, which also matches `text/plain`) and is
`launchMode="singleTop"`. `consumeShare(intent)` (in `onCreate` + `onNewIntent`) pulls
`EXTRA_STREAM` (Uri / `ArrayList<Uri>`) + `EXTRA_TEXT`/`EXTRA_SUBJECT` and stashes a
`PendingShare` on `ShareTarget.pending` (a `MutableStateFlow`, mirroring
`NotificationHelper.tappedConversation` so a cold-launch share survives until the
composition exists). `RootTabs` collects it, reads each content-URI's bytes off the main
thread (same `contentResolver` path the in-compose picker uses), and opens `ComposeScreen`
with `ComposePrefill(subject, body = sharedText, initialAttachments)`. No FFI change —
`engine.send` / the cloud draft upload already take attachment bytes. (iOS equivalent: a
share-extension target — see [iOS-App.md](iOS-App.md) §7a.)

---

## 6. Design tokens (`theme/`)

`ThemePalette` (dark/light), `AppFont`, `Space`, `Radius`, `ChannelColor` — ported 1:1
from iOS `Theme.swift`/`ChannelColor.swift` with the **same hex values**. iOS leads with
SF Pro; Android uses the platform sans at the same sizes/weights. The `glowCapsule`
modifier (shared by the nav, bulk bar, and toasts), `insetCard`, `FilterPills`,
`SegmentedTabs`, `ScreenHeader`, `AvatarRing`/`ChannelAvatar`, `InboxTag`/`AIBadge`,
`ConversationRow`, and `EmptyState` mirror the iOS components. SF-Symbol names carried by
the shared models are mapped to Material icons via `SfIcon`.

### Themes

`Appearance` = System / Dark / Light / **Soirée** / **Atelier** / **Groovebox** (iOS
ThemeManager, same raw keys). The Light ramp carries the iOS a4560ef6 values (`#f2f2f7` base, `#1d1d1f`
ink, `#0069d9` accent, `#d70015` danger, white panels + inputs). Atelier/Soirée are the
quiet-luxury pair with the same hex values as `Theme.swift`: `accentViolet` carries the
theme accent, the ring is brushed gold, `onAccent` (dark label on Soirée's gold) and
`floatFill` (the glow-capsule fill for nav/bulk bar/toasts) are the two extra palette
fields, and `AppFont.luxe` swaps the faces to **Jost** (UI) + **Bodoni Moda** (title
tier: `display`/`title`/`xl`) — the same variable TTFs iOS bundles, in `res/font/`, with
the weights registered through `FontVariation`. The `AppFont` styles are getters over a
Compose state so a switch recomposes in place. System-bar icon style is pinned to the
palette (`enableEdgeToEdge` re-run on `isDark`), the Android analog of iOS's
window-level `overrideUserInterfaceStyle`.

**Groovebox** (a toy synth on a guidebook grid) ports web `tokens.css`
`[data-theme-variant="groovebox"]` hex-for-hex: near-black islands (`#0a0a0b` page,
`#121214` panels), lavender `#a68cf0` accent with a dark `onAccent` label, teal checked
controls, mustard warning, coral danger, a coral→mustard→teal→lavender ring.
`AppFont.groovebox` swaps in **Figtree** (UI) + **Rubik** bold (title tier) from
`res/font/` and makes `Radius` rounder (`sm/md/lg/xl` = 6/9/14/20, web's scale). The
toy-synth treatments ride one nullable palette field, `groove: GrooveStyle?` (null on
every other theme, so they're untouched): the selected nav tab and active `FilterPills`
are a cream keycap, `PillButton` is the lavender dome, filled `AeroIconButton`s are dark
keycaps (all via `Modifier.keycap` in `Chrome.kt`, drawn in-bounds so clipping parents
keep the hard bottom edge), `InboxTag`/`AIBadge` are solid pastel chips with dark ink,
unread dots are LED green, and a checked multi-select row is a `#262233` fill inside a
1.5dp lavender ring. The launch splash draws the guidebook scene in
(`GrooveboxScene.kt`, a port of web `lib/groovebox.js`: grid fades up, then the outlined
objects one by one, 1.6s — `MainActivity` floors the splash to that under Groovebox).
The finished scene is also the page ground (`Modifier.pageGround()`) behind the inbox
list (header, search and channel strips stay on solid `bgBase` bars; edit mode stays
solid) and the Bridge screen. Shared atoms carry the rest: `insetCard` is a solid
20dp panel, `SegmentedTabs` and calendar `ChoiceChip`s select with the cream keycap,
`inboxSwitchColors()` (on every `Switch`) turns teal, `pastelChip` + `GrooveStyle.pastel()`
snap channel/calendar colours to the nearest pastel. The calendar draws events as solid
pastel blocks with dark ink, violet hour lines, a mustard now-line and an LED-green
today; the composer puts each field in a `#1b1b1f` well with pastel recipient chips and
a dome send key; the Bridge orb and audio bars run the pastel rainbow with dark-keycap
controls; Settings groups its rows on solid 20dp panels (`SettingsGroup`) under Rubik
section labels (`AppFont.label`). Readability pass (from the iOS phone build): content
blocks sit on solid `#121214` panels (`Modifier.groovePanel()`: 20dp, 12dp from the screen
edges) so the grid only shows in gutters, and the page grid runs at 0.22 alpha (`pageGrid`;
the splash keeps 0.42). Events are full-opacity pastels with `#141416` ink; ended ones
take a muted fill (pastel 45% into `#2a2a2e`, `#b4b0b8` ink) instead of a fade.
`GrooveStyle.eventFill` picks the pastel from the account's channel-order slot shifted by
the calendar colour, so accounts and calendars vary; month dots and load bars use the
same mapping on a `#1b1b1f` track. Groovebox `textMuted` is `#85818c` (not web's
`#5d5a63`) so small secondary text on panels holds contrast.

### App icon picker

Settings › Theme › App icon offers the same four icons as iOS and desktop (Classic
— the default — Rising sun, Venn, Graffiti). Android has no `setAlternateIconName`, so the
launcher entry is an `<activity-alias>` per icon (`.IconSun`, `.IconVennlight`,
`.IconGraffiti`, `.IconClassic`) and `AppIconOption.select` enables the chosen one and
disables the rest via `PackageManager.setComponentEnabledSetting`. Consequences worth
knowing:

- The alias state **is** the stored preference — nothing in SharedPreferences mirrors it,
  and `AppIconOption.current` reads it back (an untouched component reports
  `COMPONENT_ENABLED_STATE_DEFAULT`, which means "what the manifest says", so only the
  default alias counts as enabled there).
- `MAIN`/`LAUNCHER` therefore lives on the aliases, not on `MainActivity` — which keeps
  its `SEND` share filters and stays the target of `am start -n com.inbox2.app/.MainActivity`.
- Enable-then-disable order matters: with all aliases briefly disabled, a launcher that
  rescans in that window drops the home-screen shortcut. `DONT_KILL_APP` keeps the
  process alive across the switch.
- Artwork comes from `brand/make-alt-icons.py`: an adaptive-icon foreground per option in
  `mipmap-xxxhdpi/` (the tile fills the middle 72dp of the 108dp canvas, the only part the
  launcher mask is guaranteed to show, so the gradient rim survives), the matching
  `mipmap-anydpi-v26/ic_launcher_<name>.xml`, and a flat 128px preview in
  `drawable-nodpi/app_icon_<name>.png` for the picker row (Compose's `painterResource`
  cannot load an `AdaptiveIconDrawable`). The application icon points at the default
  (`@mipmap/ic_launcher_sun`) so the task switcher can't drift from the launcher.

---

## 7. OAuth onboarding (loopback)

Ported 1:1 from iOS `OAuthService`: a `ServerSocket` on `127.0.0.1` captures the
`GET /oauth-callback?code=…` redirect (the only redirect the Rails proxy allows); consent
is shown in a **Custom Tab** (the system browser, required by Google). Then token
exchange + email lookup, and `engine.addAccount(authMethod="xoauth2")`. IMAP uses a
manual form → `addAccount(authMethod="plain")`. Requires the dev Rails server with the
client IDs; the live consent round-trip is a manual verification step.

---

## 8. inbox2 mx mode (the API-backed team pool)

A second client mode alongside the offline channels (see [iOS-App.md §10](iOS-App.md)).
`CloudClient` (HttpURLConnection + kotlinx.serialization) + `CloudSession` are ported
from the iOS Swift; the token lives in `SharedPreferences` (a production build would use
the Android Keystore, as iOS uses the Keychain). `CloudConversation`/`CloudMessage` map
to the shared `Conversation`/`Message`, so a domain thread (`accountKey` = `org_…`)
renders through the same inbox/reader/compose, branching on `Conversation.isDomain`:
reads via `cloud`, actions via `cloud.perform` (verb→bulk-action translated), replies via
`cloud.send`. Sign in from Settings → **inbox2 mx**; the active org shows as the **mx**
channel in the inbox.

### Zones

A zone is a soft focus block on the calendar ("Deep work · Project Atlas, 16:00–18:00",
"Prep: Q3 board review"). It never blocks time or marks the user busy: people can
still book meetings inside it. Zones live on the inbox2 account
(`/api/v1/account/zones` + `/zone-categories`, user-scoped), so every zone surface is
hidden without a cloud session.

- **Data**: `CloudZone`/`CloudZoneCategory` (`CloudModels.kt`), `CloudClient.zones/saveZone/deleteZone/zoneCategories`.
  `CloudSession` keeps `zoneCategories` + `upcomingZones` (yesterday to +14 days), which the alarms
  and the in-app card use. `refreshZones()` runs on sign-in and on every foreground.
  `zoneRevision` bumps on each edit, and the calendar then re-fetches its own window.
  The list endpoint returns **occurrences**: a repeating zone comes back once per day it runs,
  with `id` = `zon_x@20260925T140000Z` and `series_id` = the series key. `id` is the identity
  everywhere (list keys, the dismissed set, alarm data URIs, notification ids), so each
  occurrence alerts separately. PATCH/DELETE go to the occurrence id: a retime shifts the
  whole series by the same delta, and a delete removes the whole series.
- **Colour**: a category's `color` is always a palette key (blue/amber/violet/green/rose/teal).
  `ThemePalette.zoneColors` gives a shade per theme, and `theme.zone(key)` resolves it. Fill is
  14% plus 7% diagonal stripes (`Modifier.zoneFill`), the outline is 45%, and label text is the
  colour lerped toward `textPrimary` (`ui/screens/Zones.kt`).
- **Calendar**: in the agenda and the month grid's day list, a zone is a tinted block that
  wraps the events *starting* inside it (`dayEntries`). A zone with no events still shows
  in time order. A zone running now gets a stronger outline, an "N left" pill and a progress
  bar. Month cells show one thin underline per zone. **+** offers New event / New zone.
  Tapping a zone opens `ZoneSheet` (edit/delete). The sheet has **Repeat** (Never / Every day /
  Every weekday / Every week) with an optional **Until** date. It sends `time_zone`
  (`ZoneId.systemDefault()`) on create. An end time at or before the start rolls to the
  next day (an overnight zone), and a zone can last at most 24h. Editing a repeat says
  "Changes apply to all repeats", and its delete reads "Delete all repeats".
- **Categories**: "Edit categories" under the category chips opens `ZoneCategoriesSheet`. It
  lists the categories with their colour dots and lets you add one (name + one of the six
  palette keys), rename, recolour, or delete it. A deleted category's zones stay, uncategorised.
- **Prep zone**: the event detail sheet has a **Prep zone** row (30 min / 1 hour / 2 hours).
  It adds "Prep: <title>" in the "Prep" category, ending at the meeting's start, with
  `anchor_event_id` = the event id and `anchor_minutes`. `CalendarScreen` runs
  `CloudSession.reconcileAnchoredZones(zones, events)` whenever either list loads. An anchored
  zone whose event is loaded (cancelled events never are) but starts somewhere else gets
  PATCHed to `[start - minutes, start]`. If the event isn't loaded, the zone is left alone.
- **Alerts** (`notify/ZoneAlerts.kt`): `reconcile()` arms two alarms per `notify` zone, one at
  the start and one at the end, and cancels both for zones that went away. The alarms are
  `setExactAndAllowWhileIdle` when `AlarmManager.canScheduleExactAlarms()` is true (the manifest
  declares `SCHEDULE_EXACT_ALARM`, but not `USE_EXACT_ALARM`). Otherwise they fall back to
  `setAndAllowWhileIdle`, which is inexact and can arrive minutes late, longer in Doze.
  `ZoneAlarmReceiver` posts an ongoing notification on the "Zones" channel (high importance,
  no badge) with a count-down chronometer to the zone's end. The end alarm re-posts it under the
  same id as **"Zone ended: <name>"**, with no chronometer, still ongoing and still showing Done.
  There is no `setTimeoutAfter`. It is a product decision that the alert stays until the user
  clears it. An alarm that fires late still posts, in whatever state the zone is in by then
  (running or ended), unless the zone is dismissed. **Done** (or swiping it away) records the
  zone id as dismissed in SharedPreferences. Each posted alert is also recorded in a `shown` set.
  `ActiveZoneCard` (sticky above every tab in `RootTabs`) reads both sets. It shows a running
  notify zone, or an ended one whose alert was posted, until Done. An ended one has a
  "Zone ended" label, no countdown and a full progress bar. The `shown` check stops a zone that
  ended unseen (say yesterday) from popping up. When zones overlap, the card shows the one that
  started most recently, as web does. The card's **Open calendar** (switches to the calendar tab)
  and **Done** are deliberately plain text links: borderless `TextButton`s in `textSecondary`,
  which keep the 48dp touch target, so Done isn't an easy tap. The notification is posted *untagged*, because
  `SyncWorker.reconcileNotifications` treats tags as conversation keys. `reconcile()` also caches
  the zones it arms (running, upcoming, and ended-but-not-Done) as JSON in SharedPreferences
  (id, name, category name, note, start, end). The same receiver handles `BOOT_COMPLETED` /
  `MY_PACKAGE_REPLACED` (`RECEIVE_BOOT_COMPLETED`) and re-arms from that cache
  (`rearmFromCache`): start and end alarms, plus a re-post for zones already started, since
  notifications don't survive a reboot. So alarms survive a reboot without opening the app.
- **Cross-device dismissal**: Done on any device clears the card everywhere. `ZoneAlerts.dismiss(id, endMs)`
  (card or notification action) marks the occurrence dismissed locally, cancels its notification
  and both alarms, and adds `id\nendMs` to a `pending_dismissals` set in SharedPreferences.
  It then enqueues `ZoneSyncWorker`, a network-constrained one-shot WorkManager job. The POST
  runs there, not in the BroadcastReceiver. The worker POSTs each pending entry to
  `POST /account/zone-dismissals {occurrence_id, end_at}` (idempotent), removing entries as they
  land, and returns `retry` if any fail. `CloudSession.refreshZones()` flushes the same queue first,
  so on app start and foreground any leftovers are retried. Remote dismissals arrive two ways. A zone list item
  with `dismissed: true` is merged into the dismissed set inside `reconcile()`, which excludes it
  from the armed set, so its alarms and notification get cancelled and the card hides. An FCM
  data message `type: "zones_changed"` (sent after any zone/category/dismissal write) with an
  optional `dismissed: <occurrence_id>` is handled by `FcmService`: `applyRemoteDismissal()`
  runs immediately, then `ZoneAlerts.remoteChanged` is bumped. If `RootTabs` is collecting that
  flow (the UI is loaded), it calls `cloud.zonesChanged()` (refetch, re-arm, calendar re-fetch).
  Otherwise `FcmService` enqueues `ZoneSyncWorker`, which fetches categories and the same
  yesterday-to-+14-days window with the stored token and runs `reconcile()`. The worker is not
  expedited (minSdk 26 would need a foreground notification), so a push-driven re-arm with the
  app closed may wait a little. The dismissal itself is applied inside the push.
  **Edits un-dismiss.** The server deletes a zone's dismissals when the zone is edited, so it alerts again.
  Locally, a successful PATCH (`saveZone` with an id, or a prep-zone retime in
  `reconcileAnchoredZones`) calls `ZoneAlerts.forgetSeries(seriesKey)`. That drops every dismissed
  and pending entry whose id is the series key or starts with `<seriesKey>@`. On fetch, `reconcile()`
  also removes a locally dismissed id that the server reports `dismissed: false`, unless its POST is
  still pending: another device edited it.

---

## 9. On-device AI

The three-lane Bridge model manager (manifest, availability, selection, downloads) is in
the **shared Rust core**, so Android only adds the UI + audio I/O + inference engines.
- **Model panel** (`ModelPanelScreen`): renders `model_lanes` per capability with the
  free-lane download/delete card (live progress from `model-download` events). Downloads
  are real (the Rust resumable + sha256-verified downloader).
- **NLU**: `BridgeLLM` implements the `OnDeviceLlm` callback; `LiteRtEngine` runs the
  downloaded Gemma `.task` via MediaPipe `LlmInference` (`com.google.mediapipe:tasks-genai`),
  wrapping the prompt in the **Gemma chat template** (`<start_of_turn>user…<end_of_turn>
  <start_of_turn>model`) exactly as iOS does — the `-it` model needs the turn markers.
  `isAvailable()` is true once the model is on disk, else the core falls back to OpenAI —
  the iOS fallback contract.
- **AI config**: the NLU generation config is one source of truth (`engine/BridgeConfig.kt`,
  iOS `VoiceEngineManager.bridgeConfig`), pushed to the engine at **app startup**
  (`RootTabs` `LaunchedEffect`, iOS `Inbox2App.task(id:)`), on Bridge open, and whenever
  the lane/key changes in `ModelPanelScreen` — so the background triage worker always
  classifies on the same model the Bridge speaks with, even if the Bridge is never opened.
- **TTS** (`audio/Speaker`): `openai` → `bridge_openai_tts` (tts-1 MP3) via MediaPlayer;
  `native` → Android `TextToSpeech` with **per-sentence language routing** (ML Kit on-device
  language ID + `BreakIterator`, the Android counterpart to iOS `NaturalLanguage`) so a
  mixed-language brief reads each run in a matching installed voice; `free` (Kokoro/sherpa)
  degrades to native TTS until the sherpa-onnx engine is wired (graceful). The engine is
  warmed on Bridge open (iOS `warmUpVoiceOnce`).
- **STT** (`audio/ListeningManager`): `native` → Android `SpeechRecognizer` (live);
  `openai` → record a 16 kHz WAV (`AudioRecord`) → `bridge_openai_transcribe`; `free`
  (WhisperKit) is iOS-only → falls back to native.
- **Voice loop** (`BridgeScreen`): a mic button drives listen → `bridge_reply`
  (on-device LiteRT or OpenAI per the resolved NLU lane) → speak, with a transcript view;
  plus the daily brief. A null FFI reply (core still booting) shows a "starting up" status
  and **retries once after 1.5 s** rather than speaking an error (iOS `.notReady`).

**Remaining native wiring** (documented): the **sherpa-onnx** TTS (Kokoro) / STT engines
for the free lane (the manager already hands back the verified `model_path(id)`; Android
falls back to native TTS/STT meanwhile). Android has no native LLM lane, so the free
(LiteRT) lane *is* the on-device NLU path; STT's free lane on Android should be a
sherpa-onnx model (the manifest's WhisperKit free STT is iOS-only — a core-manifest
follow-up).

---

## 10. Parity status

**Done & verified in-emulator (seeded store):** the read split (SQLite read / FFI write,
re-query on events) with a live IMAP sync; inbox + per-channel/folder/filter; FTS5
search; threaded reader with the shared `email-body` WebView (quote/signature collapse +
remote-image blocking); conversation actions + glow undo toast; swipe actions;
long-press multi-select + the nav-replacing bulk bar; Move-to-Inbox; Outbox (retry +
cancel); compose/reply/forward → outbox; calendar agenda; settings + connected accounts;
the Bridge orb + daily brief; the three-lane model panel with working downloads; account
onboarding (OAuth loopback + IMAP); the inbox2 mx client + sign-in. Android-native back
via `BackHandler`.

Also done since the first cut: **local notifications** + WorkManager background sync;
the **calendar month grid** (per-channel multi-dots, adjacent-month days, multi-day
bucketing) + event create/edit/delete sheets + invite-gated **RSVP** (selected state) +
delete confirmation; the **auto-rules editor**; reader **attachments** + **view-source**;
and the on-device AI **voice loop** with **LiteRT (Gemma)** NLU.

Closed in the parity pass (iOS feature-by-feature):
- **Reader**: mark-as-read modes (immediate/dwell/on-leave/never), the overflow menu
  (spam/snooze/quadrant/Move-to-Inbox), per-message Details disclosure + collapsed
  preview, reply quoting + domain `conversationId`, AI-summary sparkles + bullets,
  sentiment/intent **AIBadge** icons.
- **Inbox**: long-press row context menu, the bulk **Triage** quadrant submenu (+ restore
  folders keeping all actions), pull-to-refresh, search-clear, unread count in the title.
- **Theme switcher** (System/Dark/Light — the Light palette is now reachable), the
  **app-icon picker**, **Activity feed**, **launch splash**, onboarding **mx sign-in**.
- **Settings panels**: Preferences (mark-read mode/delay), Contacts, App-logs viewer,
  Developer diagnostics, per-account **Reconnect** + remove confirmation; mono-`mx` label.
- **Compose**: domain-identity picker, contact autocomplete, attachments, Save-draft/
  resume (DraftStore).
- **inbox2 mx collaboration**: tags/assignees/notes reader bars, the Mine/Unassigned/
  Unread pool views, drafts/Sent folders, snooze/schedule-send/undo-send/upload endpoints,
  HTML send — full `CloudClient`/`CloudModels`/`CloudSession` surface.
- **Voice/AI**: tomorrow/week-highlight follow-ups, HF-token field, OpenAI-key validation.
- **Visual**: ~30 SF-symbol→Material mappings, the bundled `es_*` empty-state hero art.
- **Bug fixes**: cloud 2FA (`totp_code`) + bulk (`action_name`) param mismatches.

**Pending live verification** (needs external services, not code): the OAuth consent
round-trip, the inbox2 mx read/write path (dev Rails), and on-device LiteRT generation
(the 555 MB Gemma model + a real device; the emulator lacks a `SpeechRecognizer`, so the
native STT lane falls back to OpenAI there).

Also closed: OpenAI **TTS voice picker**, domain **schedule-send** (createDraft +
scheduleSend) and the **send-undo** toast, and **Drafts-folder** local-draft resume.

### Notifications: action buttons + the ongoing card (2026-09-25)

Closed from the TODO below (iOS 2026-09-13 `NotificationManager.swift` +
`MailLiveActivity.swift`):

- **Action buttons.** Every new-mail notification carries **Mark as read / Archive /
  Trash** (Trash last) inline on the card — `NotificationHelper.postNewMessage` adds
  them; `notify/NotificationActions.kt` is the iOS `PendingAction` queue: the
  `NotificationActionReceiver` persists the action (same SharedPreferences key as iOS)
  + drops the banner, an expedited `NotificationActionWorker` drains it through the
  same routers the UI uses (engine `perform` for channels, `CloudSession.perform` when
  the UI session is up, else one bare `CloudClient.bulk` with the stored bearer for
  MX), and `MainActivity` drains again after the engine boots. MX pushes are data-only
  now (`MobilePushPayloadBuilder.fcm_message`) so `FcmService` posts them through the
  same path with `organization_id` for routing.
- **The ongoing card** (`NotificationHelper.refreshOngoing`): the Android counterpart
  of the Mail Live Activity — one silent, non-dismissable notification on its own
  `inbox2_mail_live` channel with the newest unread thread (channels via SQLite + the
  active MX org), the three buttons and a "+N more unread" line; advances after each
  action, cancelled when nothing is unread. Refreshed from `RootTabs`
  (`dataVersion`/`revision`), after every `SyncWorker` sync (`afterSync`), after a
  drain and on each new-mail post. `setRequestPromotedOngoing(true)` +
  `POST_PROMOTED_NOTIFICATIONS` promote it to an Android 16 Live Update; no
  push-to-start plumbing (the FCM wake already runs the sync that refreshes it).

### Inbox + reader parity pass (2026-09-25)

Closed: **A2** snooze (row menu + reader ⋯ for domain threads, `InboxState.snooze` /
`onSnoozed`), **A3** invite-banner tap → calendar detail + "View" after "Added to
calendar" (`onOpenEvent` → `RootTabs.pendingEventKey` → `CalendarScreen.openEventKey`,
`InboxStore.event(key)`), **A4** body links open the in-app browser
(`MessageBodyWebView.shouldOverrideUrlLoading` → `InAppBrowserScreen`: back/forward/
reload-stop, lock + host, share, open-in-system, close, ring progress bar; mailto/tel/sms
go to the system), **A6** Forward on the row menu (`forwardPrefill` over the latest
message), **A9** the "Couldn't load your inbox" state (`InboxStore.lastReadError` — a
failed read no longer passes for an empty inbox), **A10** "Keep typing" / "Searching…"
instead of the inbox behind an active search, **A11** the nav hides while the search
field is open.

**Search was broken on Android and nobody could tell.** Android's platform SQLite has no
FTS5 module (`no such module: fts5`), so every `messages_fts MATCH` failed and the
inbox showed "No results" for any query; A9's error state is what surfaced it. The MATCH
now runs in the Rust core (`fts_conversation_keys_json` — the core bundles SQLite with
FTS5 and owns the index), and `InboxStore.searchFTS` joins the returned keys locally
(`ftsKeys` hook set by `EngineModel`). iOS keeps its local MATCH (system SQLite has FTS5).

### Parity pass, second half (2026-09-26)

Closed: **A1** meeting alarms (`notify/MeetingAlarms.kt` — see "Meeting alarms" below),
**A5** pinch-zoom + one-finger pan of the email body (`settings.builtInZoomControls`,
`onScaleChanged` scales the card height like iOS's `baseHeight × zoomScale`), **A7** a
separate read-aloud voice per lane ("Same as Bridge" leads; `VoicePrefs.readerTtsVoice`/
`readerNativeVoiceId`, `Speaker.speak(reader = true)`), **A8** the sign-in "Advanced"
Server URL field (`AppConfig.load/setApiBase`, same pref key as iOS, loaded in
`Inbox2App.onCreate` before the engine boots), **A12** the ongoing card carries the
unread number (`setNumber`) for launchers that show one — a numeric badge API doesn't
exist on Android, so the rest of A12 is a platform divergence, **A13** the dev style
guide (`StyleGuideScreen`, Developer › Style guide, live appearance switch), **B1/B2**
themes (above), **B3** the inbox rows in a recessed well under a column header with the
loaded count (`InboxScreen.wellRow` / `ColumnHeader`), **B4** the big header collapses
into a pinned compact bar once it scrolls past (`rememberLazyListState` +
`derivedStateOf`), **B5** the launch splash follows the selected app icon (cube tile /
graffiti mural / sun stage / venn, scrim + ring loading bar; the cube is flat here, iOS
spins a SceneKit one), **B6** per-type attachment glyphs at the iOS 24pt size (Material
file icons — Android has no UIDocumentInteractionController-style native icon).

### Meeting alarms

`notify/MeetingAlarms.kt` is the iOS `MeetingAlarms` + `MeetingAlarmPlan` port. Every
alarm is an `AlarmManager.setAlarmClock` (exact without the exact-alarm permission,
fires in Doze, shows the upcoming-alarm icon) whose `MeetingAlarmReceiver` posts a
HIGH notification on the `inbox2_meeting_alarm` channel with the shared 25 s buzzer
(`res/raw/meeting_alarm.m4a`, the same piezo pattern `bin/gen-alarm-sound.py` makes for
iOS, AAC-encoded) on the ALARM stream; the channel asks to bypass DND (honoured when the
user allows inbox2 there). `plan()` keeps the iOS rules (timed meetings only, lead time
ahead of now, declined ones skipped, muted ones skipped, nearest 32). `reconcile` runs on
foreground/sync (`SyncWorker.afterSync`), on every `dataVersion` bump (throttled 30 s)
and on settings changes; the armed plan is cached so `BOOT_COMPLETED` /
`MY_PACKAGE_REPLACED` re-arm from the on-disk store without booting the engine.
Preferences: toggle, "Alarm at" (1/2/5/10/15/30 min), "Test alarm" (5 s), the footer and
a system-status line when notifications/the channel are off or DND would block it. The
event sheet has the Cancel/Restore alarm row; tapping the alarm opens the event
(`NotificationHelper.tappedEvent` → Calendar tab → detail).

### Parity TODO — iOS changes since the last pass

Running list; each item names the iOS source of truth and the Android pieces. Clear an
item when it ships. **Empty as of 2026-09-26.** Two passes are closed: the 2026-09-25
static inventory (every iOS commit since 2026-06-25 that didn't touch `ui/android`) and
the 2026-09-26 behaviour-level pass over the calendar, composer, settings and Bridge flows
(full source read on both sides, 45 items). What that second pass changed:

- **Calendar**: the Day timeline + Block time (above); a tapped chart day filters the
  ±30-day set so past days show; quick-RSVP failures alert; the event sheet has a
  "With" attendees field (Bridge names resolved against contacts), a separate end date
  (multi-day events), end ≥ start validation, a read-only calendar when editing, and the
  iOS default start (next hour, at least 09:00, on the day in view); prep-zone row only
  for meetings that haven't started; a hand-retimed prep zone unhooks from its meeting
  (`saveZone(clearAnchor)`) and the reconcile skips repeating zones, all-day events and
  sub-minute drift; a zone category can be deselected; "next day" hint + multi-line note;
  categories delete from their row.
- **Composer**: system back asks Save draft / Discard / Keep editing; Bcc survives a
  saved draft; domain replies send from the receiving address (`fromEmailOverride`); a
  sent or scheduled reply marks the thread read; the default From re-resolves when
  domain identities load late and rows read "email · org"; multi-select file/photo
  pickers; attach failures say so; chips show sizes; sentence capitalisation; a send
  spinner and "Couldn't send (status)".
- **Settings**: rules can't save an empty text condition; rule + label deletes confirm
  (desktop-only rules deletable from their card); triage caption + current date; the mx
  panel checks the session, shows avatar/email, a Domain(s) section and sign-out
  feedback; device-link cancel isn't an error; sign-in keyboards/autofill, 2FA lock,
  validation, "Waiting for approval…"; IMAP defaults to 465 with implicit TLS, keyboards,
  validation, host hint; reconnect goes straight to the account's provider (IMAP form
  for IMAP) with Try again and friendly errors, providers disabled while connecting;
  collaboration tags/assignees toggle with checkmarks, notes show their author; a
  visible DEV MODE button; logs with refresh, copied tick and level colours.
- **Bridge**: hold-to-talk (press starts, release finishes; a press during
  transcription cancels), live level bars + partial transcript + the orb waveform on the
  mic/speech level, "I didn't catch that" instead of silence (empty transcript, native
  errors, sub-0.1 s clips), briefs stop speech and reset the command dialog and can't
  overlap, the brief button stops speech while it talks, follow-ups fade after 60 s and
  a "Tomorrow & weekly highlights" link summons them (hidden during triage catch-up),
  "Composing your brief… / Transcribing… / Speaking · lane" status, spoken attendee
  names matched to contacts, mic requested before the first brief so barge-in works over
  it, the OpenAI key is validated before it's saved and shown masked (HF + Jev keys
  masked too), unavailable lanes are dimmed with the core's reason, picking Qwen/Gemma
  switches the lane to Free and refreshes the triage worker, model cards show a readable
  name.

**Remaining (intentional divergences):** the **sherpa-onnx** TTS (Kokoro) / STT engines
for the free lane (§9 — native TTS/STT + OpenAI cover the path meanwhile, incl. the free
Kokoro voice picker which waits on that engine); the Metal orb (a Compose-canvas orb
stands in); **NEON STRIKE** stays iOS-only — Android ships its own **VOXEL STRIKE**
(`game/`, [VoxelStrike.md](VoxelStrike.md)); the share sheet is a plain `ACTION_SEND`
target rather than an in-sheet composer; the reconnect prompt lives in Settings only
(67cc60c5). Live verification of OAuth consent + the inbox2 mx read/write path still
needs the dev Rails running.

## 11. Car mode & Android Auto

**Car mode** controls Bridge brief verbosity: **on → the full daily brief**, **off
("normal") → a terse headline**. Brief-only (per-message read-aloud / triage unaffected).
The `FfiBridgeConfig` carries `concise` + `weather?`; `nluBridgeConfig(engine, prefs,
concise, weather)` sets them, and the core (`bridge/brief.rs`) does the shortening +
morning-weather append. The shared `bridgeReplyText()` (`engine/BridgeConfig.kt`) maps a
reply to spoken text for both the phone screen and the car screen.

- **Bluetooth-driven default** (`BridgeScreen`): an `AudioDeviceCallback` tracks
  `bluetoothConnected` (output device `TYPE_BLUETOOTH_A2DP/SCO`); `carMode =
  carModeOverride ?: bluetoothConnected`. The top-left `ScreenHeader` `leading` toggle
  (`car`/`car.fill`) sets `carModeOverride` for the current connection, reset when the BT
  connection flips. The daily-brief tap passes `concise = !carMode`. Mirrors iOS
  `VoiceEngineManager` (minus the CarPlay term — Android Auto runs in a separate screen).
- **Morning weather**: `cloud/WeatherService.morningLine()` (OkHttp/`HttpURLConnection`)
  hits `GET /api/v1/weather` only when the local hour < 12, best-effort.

**Android Auto** (`car/`). `BridgeCarAppService` (`CarAppService`) → `BridgeCarSession` →
`BridgeCarScreen`, a `ListTemplate` of Daily brief / Tomorrow / Weekly highlights. Each
row reuses the **process-wide `EngineModel.get()`** singleton (same engine as the UI +
`SyncWorker`), builds `nluBridgeConfig(concise = false)` (a car is always the full brief),
calls `engine.bridgeBrief/…`, and speaks via its own `Speaker` (Android Auto can launch
standalone with no phone UI, so it can't share the phone's Composable `Speaker`).

- **Dependency**: `androidx.car.app` (`libs.versions.toml` `car-app`).
- **Manifest**: a `<service>` with the `androidx.car.app.CarAppService` action +
  `androidx.car.app.category.MESSAGING`, the `androidx.car.app.minCarApiLevel` meta-data,
  and `com.google.android.gms.car.application` → `res/xml/automotive_app_desc.xml`.
- **Host validator**: `ALLOW_ALL_HOSTS_VALIDATOR` on debug, the library's Google-signed
  allow-list on release.
- **Testing**: drive via the Desktop Head Unit (DHU). Google restricts which app
  categories may ship on Auto, so a production listing needs an approved category +
  review; dev/DHU works now.
