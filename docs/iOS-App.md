# iOS App — feature-set, layout & architecture

The native iOS client (`ui/ios/`): a SwiftUI shell over the **shared Rust core**
(`inbox2-core`, via UniFFI) and the **shared `@inbox2/email-body` JS** (rendered in
`WKWebView`). Dark-first, design tokens adapted from the desktop (violet-led; see
§6). This doc is the
reference for the feature-set + layout so the **Android port reuses the same core,
the same SQL, the same FFI surface, and the same screen model** — only the UI layer
(SwiftUI → Compose) is rebuilt.

Companion docs: [Desktop-Capabilities.md](Desktop-Capabilities.md) (parity baseline),
[iOS-Simulator.md](iOS-Simulator.md) (build/drive the simulator),
[Channels.md](Channels.md) (the Rust sync engine).

---

> **MX mail (2026-09-20):** inbox2-hosted mail is mirrored into local SQLite by the engine and read here through `Cloud/MxMirror.swift` + `Data/InboxStore+Mx.swift`. Protocol, rules (incl. sealed mail never reaching an agent) and status: [MX-Sync.md](MX-Sync.md).

## 1. Architecture

```
┌─ SwiftUI UI (ui/ios/Sources) ─────────────────────────────┐
│  Views + Components + Models + Managers                    │
│     reads ↓ (SQLite, direct)        writes ↓ (FFI)         │
├─ Data layer ──────────────────────────────────────────────┤
│  InboxStore (SQLite, read-only-ish)   EngineModel (FFI)    │
├─ Generated UniFFI bindings (inbox2_core.swift) ───────────┤
│  InboxEngine object + EngineEventListener callback         │
├─ inbox2-core (Rust, ui/desktop/core) ─────────────────────┤
│  SyncEngine · SyncStore (SQLite) · adapters · rules        │
└────────────────────────────────────────────────────────────┘
```

**The split (identical to desktop):** the UI **reads conversations/messages
straight from the local SQLite `inbox2.db`** and only **writes through the Rust
engine** (actions, send, add-account). This is the single most important thing to
replicate on Android — the read queries are plain SQL (see §4), the writes are FFI
calls (§3).

- **One DB, two in-process connections.** The Rust engine opens `inbox2.db` for
  read+write (WAL). The Swift `InboxStore` opens the *same file* read-write but
  issues SELECTs only, so reads always reflect the engine's committed writes. (A
  read-only handle trips on WAL shared-memory setup — don't use one.)
- **Events.** The engine pushes `(event, payload_json)` to an `EngineEventListener`
  callback. `EngineModel` bumps a `dataVersion` on `sync` / `new-message` /
  `calendar-changed`; views re-query via `.task(id:)`.
- **Body rendering stays in JS.** `Resources/email-body.js` (the bundled
  `@inbox2/email-body`) runs inside a `WKWebView` for quote/signature collapse +
  remote-image blocking — same module the desktop iframe uses.

**Project gen:** `ui/ios/project.yml` → `xcodegen generate` → `Inbox2.xcodeproj`.
Re-run xcodegen after adding files. Links `InboxCore.xcframework` (built by
`ui/desktop/core/build-ios-xcframework.sh`) + `Security`, `SystemConfiguration`,
`-lc++`, `-lsqlite3`. ATS allows local networking (OAuth dev calls).

---

## 2. Screens & layout

Root: `Inbox2App` → `ThemedRoot` (resolves theme) → `RootTabs`.
`RootTabs` is a `ZStack` of the active tab + a **floating capsule nav**
(`FloatingNavBar`): Inbox · **Lore** · **Compose** (center, violet, a
**`paperplane.fill`** glyph) · Calendar · Settings. Folder switching is a left
**slide-in drawer** (`FolderDrawer`) overlay owned by `RootTabs`; compose +
add-account are sheets.

**iPad (regular width) — `IPadShell`.** `RootTabs` swaps the floating nav for a
desktop-style `NavigationSplitView`. The **sidebar** is an **icon rail + panel**
(Outlook/Teams-style): a 56pt rail of section icons — Mail, Lore, Calendar, and
Settings at its foot (a **sheet**, also ⌘4, never a section) — beside the active
section's panel, styled after desktop's `InboxSidebar`/`NavGroup` (uppercase metallic
group headers, warm active row with a 3pt rail). Mail's panel = the folders (mailbox
+ triage, or a Meta account's sub-views; group header = the selected chip);
Calendar's = New event, a mini month, Coming up; Lore has none, so the column shrinks
to the rail. New message lives in the list header (and ⌘N), not the sidebar.
**Command palette** (`CommandPaletteView`, ⌘K or the ⌘ button on the rail): screens,
folders, account chips and actions (new message, new event, Lore panel, folders, touch
strip, calendar time zone), plus conversations from connected mailboxes and people as
you type; ranking in `Models/PaletteMatch.swift`, the last four commands on top.
**Touch strip** at the bottom (docs/Touch-Strip.md). **Calendar time zone**
(`CalendarTimeZone.swift`, in the calendar sidebar): the week, day, month and agenda in
another zone; all-day events keep their date. **Unified Inbox tree**: Inbox ▸ domain ▸
the address folders kept out of Inbox (shared addresses, plus addresses), names without
the domain; a tap opens that domain's chip with the folder selected.
There is one split view per section at every width, because iPadOS re-lays the window out in another orientation for its App Switcher snapshot and swapping split views during that pass aborted inside UIKit (2026-11-08). **Landscape (≥1100pt)**: rail, folders and list share the sidebar column, beside the reader; a hide-folders
button in the panel header leaves rail + list + reader, a button left of the INBOX
title brings the panel back (remembered). **Portrait**: two columns — a folder pick
slides the list over the panel (a plain swap, not a NavigationStack push: a stack in
a split column pushes over the whole column, rail included), back chevron in its
header; the chip survives the remounts via `SplitReader.channel`. Split views pin
`columnVisibility: .constant(.all)` — left automatic, iPadOS collapses the sidebar.
⌘N / ⌘1–4 are registered on the shell so they work from any sidebar page. The list column is the **unified
inbox list** (`InboxListView` with a `SplitReader`:
`open()` hands the thread to the shell instead of pushing, the open row is
highlighted, the hamburger is gone) | the **reader** (`MessageView(embedded:)`, no
back chevron). Archive/trash/snooze from the reader files the row and **advances to
its neighbour**, like desktop (the phone pops). **Lore** is a plain 340pt view beside
the reader, not an `.inspector` (opened from the reader toolbar, closed from the panel's top-right corner, or ⇧⌘L); the
choice persists where four panes fit (≥1300pt, 12.9"/13" landscape) and starts
closed on narrower layouts. Trap: LoreView's usual `.toolbar(.hidden)` must stay off in panel mode or the reader loses its bar and buttons. Lore/Calendar/Settings get a two-column split (sidebar + page).
**Calendar on iPad** follows desktop's calendar page: the sidebar's Calendar section
opens New event, a mini month that jumps the grid, and Coming up (tapping one opens
its detail); `CalendarView` swaps its month tab for a **Week** mode (`CalendarWeekView`,
iPad only, the default there) and moves the Upcoming / Day / Week switch into the
title bar: seven day columns on one 24-hour grid, built from
the Day view's shared pieces (`calendarOverlapFrames`, `CalendarEventBlock`,
`CalendarBlockedBlock`, `DayZoneBand`, `RangePress`), all-day chips per column, a
now line, long-press-drag to create, a day header opens Day mode, swipe pages
weeks. Sidebar ↔ view talk over `ChromeModel.calendarDay` / `calendarJump` /
`calendarCreateTick`. Not yet: desktop's per-calendar visibility checkboxes,
drag-to-move, the weekend-starts-Saturday rule.
Compact width (iPhone, narrow Split View) keeps the tab layout.

| Screen | File | Layout / behavior |
|---|---|---|
| **Inbox** | `InboxListView` | In-content header (hamburger + big title that collapses on scroll), custom search field, **channels row** (Unified + per-account brand avatars), **filter pills** (All/Unread/**Triaged** — inbox2 has no flag concept; Triaged = any Eisenhower quadrant assigned), conversation list. Swipe → trash/archive (trailing) + read/unread (leading) with a 5s **undo toast** that **drops down from the top, just under the header** (`toastRow`: a circular action-icon badge + the past-tense label + Undo, in the shared **`GlowCapsule`** chrome — the same treatment as the floating nav). The bulk-action bar and the domain "Message sent" toast use the same `GlowCapsule`. Undo re-inserts the row at its original index. **Long-press row menu** (Select, mark read/unread, move-to-quadrant Triage submenu, archive/trash/spam) mirroring the reader overflow; in **Spam/Trash/Archive** it leads with **Move to Inbox** and drops the redundant same-folder removal item. **Multi-select edit mode** (Cancel / "n Selected" / Select All header + a bottom bulk-action bar that **replaces the floating nav in the same spot** — `RootTabs` hides the nav via `chrome.editing` — and **mirrors it exactly**: an intrinsic-width centered `GlowCapsule` of 48×48 icon buttons **Read / Archive / Triage / Trash** (same icon size/weight/spacing as the nav, accent-gradient glyphs, no red), swapping in a bulk **Move to Inbox** in restore folders; actions grouped by account over one `perform_action` per account). Pull-to-refresh kicks a sync. Title follows the selected folder. |
| **Folder drawer** | `FolderDrawer` (MobileChrome) | Mailboxes (Inbox/Sent/Drafts/**Outbox**/Archive/Trash) + **Triage** (Priority/Schedule/Delegate/Later/Important). Triage rows carry the **desktop Eisenhower quadrant colors + glyphs** (Priority 🔥 `#e06060`, Schedule `#6ea8d9`, Delegate `#d4a843`, Later `#6b7280`, Important `#d0b468`) — single source `MailFolder.tintHex`, mirroring the web `lib/priority.js`. Outbox lists queued/failed sends from `outbox_messages` with a per-row "Send now" retry on failures and **swipe-to-cancel** (delete a stuck send). |
| **Reader / thread** | `MessageView` + `MessageCard` | **Collapsible AI summary** panel, then a **stack of per-message cards** (newest expanded, older collapsed), each rendering the body via the self-sizing `MessageBodyWebView`. Per-card **Details** disclosure (From/To/Cc/Date) + **View source** sheet (`MessageSourceView`, raw headers + body). Per-message sentiment/intent badges. **Attachments** (fetched live) → tap downloads + Quick Look. **Show-images** banner. Actions bar: reply/reply-all/forward (→ compose prefilled) + archive/trash, overflow menu (Move to Inbox in spam/trash/archived, quadrant-move Triage submenu, spam). Mark-as-read honors the user's mode. The **floating nav hides** while reading (`ChromeModel`). |
| **Lore** (tab 1, was the Bridge) | `LoreView` + `Models/Lore.swift` | The open workload (docs/plans/lore.md §6; rules mirror web `lib/lore.js`). Rows = the unified inbox's own read (`InboxLoader`: every channel + every MX org's mirrored pool, inbox only) narrowed to threads with a Lore `triage_label`. A **Next-up** card (top item; **Open email** / **Open & reply** pushes `MessageView`, **Done**), then checklists — Do first (top 3 by `triage_priority` among pay/reply/work/meet), To pay, To reply, Work & requests, Meetings, To review, Read later, Waiting on others — with 44pt checkboxes and a full swipe = done. Done = **archive through `EngineModel.perform`**, the inbox swipe's router (local engine or MX). **My todos**: open `lore_todos` (core `lore_list_todos_json` / `lore_add_todo` / `lore_complete_todo`) with an inline **Add todo** row; voice `add_reminder` lands here too. **Handled for you** (fyi / receipt → Archive N, notification → Delete N) only acts on a press. Pull-to-refresh syncs; reloads on `dataVersion` / `cloud.revision`. **Voice is secondary**: a floating mic opens `BridgeView` as a sheet (brief, push-to-talk, car-mode toggle and the NEON STRIKE game button stay in its top bar); voice drafts present over that sheet. CarPlay is unchanged. |
| **Activity** | `ActivityView` | Live feed of recent inbound mail (gradient avatars, violet "Open" pills) → opens the thread. |
| **Calendar** | `CalendarView` | **Upcoming / Day / Calendar** `SegmentedTabs` toggle: agenda grouped by day (Today/Tomorrow/date), a **Day timeline** (`CalendarDayView`, below) **and a month grid** (‹ › + Today nav, per-day event dots, locale-first weekday row, day-detail list), color bars from the calendar, time + location; tap → `EventDetailSheet` (with **RSVP** Yes/Maybe/No on invites, and an ⋯ menu → **Edit** / **Delete event**). Header "+" → **New event sheet** (title, calendar picker, all-day, start/end, location; disabled when no writable calendar); the same sheet edits an existing event. |
| **Compose** | `ComposeView` | From (account picker), To/Cc/Bcc with **contact autocomplete**, Subject, body, **attachments** (fileImporter). Send → outbox FFI. Cancel with content → **Save Draft / Discard**. Resumes a `SavedDraft`. |
| **Add account** | `AddAccountView` | Google / Microsoft (**loopback OAuth**, §7) / IMAP (manual form). |
| **Settings** | `SettingsView` | Level-based menu (mirrors desktop): Preferences, **Connected accounts** (per-account ⋯ menu → **Reconnect** — pre-selects the account's provider and auto-starts its OAuth/IMAP flow — / **Remove**, with a confirm dialog; "+" top-right to add), **inbox2 mx** (the API team pool — see §10; the `mx` token renders in a **monospaced/code face** in both the menu row and the panel header via `AttributedString.inbox2mx`), Theme, Contacts, On-device AI (OpenAI key, **Jev by TypeSafe** key — validated with `validate_jev_key`, Keychain `typesafe_api_key`, pushed with `set_jev_key` at launch, 401 shown from `jevStatus`), **Triage & sync** (progress, window, **Labels** editor `TriageLabelsView` over `get/set_triage_labels`: built-in enable toggles with `fyi` locked, description/not-for edits, custom add/edit/delete), **Auto rules** (inline enable/disable toggle + **New/Edit rule** sheet with **multiple AND-ed conditions** incl. `has_attachment`; long-press a rule → Edit / Enable-Disable / Delete; "+" to add), App logs, Developer. Zero-states use the shared **illustrated empty-state** look (`SettingsInfo` `illustration:`): `es_accounts` (no accounts), `es_rules` (no rules); the **inbox2 mx** signed-out state leads with the **inbox2 brand cube** (`InboxLogoTile`). |
| Style guide / diagnostics | `StyleGuideView`, `RootView` | Dev-only token gallery + engine status. |

---

## 3. FFI surface (`inbox2-core/src/ffi.rs` → `InboxEngine`)

All writes + live provider calls go through these. Synchronous-blocking over an
owned tokio runtime (call off the main thread).

| Method | Purpose |
|---|---|
| `new(data_dir, listener)` | Open store under `data_dir/inbox2.db`, start poll + write-back loops, boot stored accounts. Events → `listener.on_event(event, payload_json)`. |
| `list_accounts_json() -> String` | Connected accounts (`ExternalAccount` JSON array). |
| `start_sync(account_key)` | Connect → list → incremental sync (coalesced). |
| `perform_action(account_key, [conversation_keys], action)` | archive/unarchive, trash/untrash, spam/unspam, mark_read/mark_unread, set_quadrant/clear_quadrant. Optimistic local commit + durable provider write-back. |
| `send_message(account, from, to, cc, bcc, subject, body_html, body_plain, [FfiAttachment])` | Enqueue to outbox + immediate delivery; returns JSON `OutboxSendResult`. |
| `fetch_message(account, message_key) -> String` | Live: full body + attachment metadata (`FetchedMessage` JSON). |
| `download_attachment(account, message_key, attachment_id) -> bytes` | Live attachment download. |
| `add_account(provider_type, email, display_name, auth_method, access/refresh token \| password, imap host/port/tls/smtp) -> key` | Create account + store creds + initial sync. |
| `remove_account(account_key)` | Disconnect adapter, deregister push, delete all local data (mail, calendars, creds, outbox, write-back queue). |
| `retry_outbox(account_key, outbox_key)` | Re-queue a failed/exhausted outbox send for immediate delivery. |
| `delete_outbox(account_key, outbox_key) -> Bool` | Cancel a queued/failed send by deleting its outbox entry. |
| `set_rule_enabled(rule_key, enabled) -> Bool` | Toggle a `local_rules` row's enabled flag. |
| `create_builtin_rule(name, conditions_json, action_json, account_key?, enabled) -> key` | Insert a built-in rule (JSON conditions + `perform_action`; `run_agent` stays desktop-only). |
| `update_builtin_rule(rule_key, name, conditions_json, action_json) -> Bool` | Edit a built-in rule's name/conditions/action (validated JSON). |
| `delete_rule(rule_key) -> Bool` | Delete a `local_rules` row by key. |
| `create_calendar_event(account_key, calendar_provider_id, draft_json) -> provider_event_id` | Create an event from a JSON `EventDraft`; provider write-through + re-sync. |
| `update_calendar_event(account_key, event_key, draft_json)` | Edit an event by local key (resolves provider ids); provider write-through + re-sync. |
| `delete_calendar_event(account_key, event_key)` | Delete an event by local key; provider write-through + immediate local removal. |
| `respond_to_event(account_key, event_key, response)` | RSVP (`accepted`/`declined`/`tentative`) by local event key; provider write-through. |
| `bridge_brief(config) / bridge_reply(config, transcript) / bridge_agent_turn(config, transcript) -> FfiBridgeReply` | Shared Bridge brief/reply/tool-turn. `FfiBridgeConfig{generation:"openai"\|"apple", openai_key?, model?, on_device_model?, concise, weather?}`; generation routed OpenAI (in-Rust) vs on-device (`OnDeviceLlm` callback = Swift `BridgeLLM`, which routes Apple Foundation Models ↔ Gemma/LiteRT). `concise`=terse headline brief (non-car mode); `weather`=short line the core appends to a *morning* brief. Both are brief-only (ignored by other calls + the triage worker). |
| `bridge_validate_openai(key) / bridge_openai_tts(key, text) -> bytes` | Validate the key (GET /v1/models); OpenAI `tts-1` MP3 synthesis. |
| `bridge_openai_transcribe(key, audio) -> String` | OpenAI STT (`gpt-4o-transcribe`, multipart) — the paid voice-input lane. |
| `set_device_profile(FfiDeviceProfile)` | One-shot at launch: `{os, os_major, os_minor, apple_intelligence, android_native_speech}`. Drives native-lane availability in the model manager. |
| `model_lanes(capability, has_valid_key) -> [FfiLaneInfo]` | The three lanes (native/free/openai) for `tts`\|`stt`\|`nlu`, with `{available, reason?, state, total_bytes, license}`. |
| `effective_lane(capability, user_pref, has_valid_key) -> String` | Resolve the lane to route to: `native`\|`free`\|`openai`\|`needs-download`. Pure (disk-stat only). |
| `model_download(id) / model_delete(id) / model_path(id) -> String?` | Start a resumable+sha256-verified download (progress via `model-download` events), delete it, or get the verified install dir for the native engine. |
| `shutdown()` | Disconnect + stop loops. |

The model manager (`inbox2-core/src/bridge/models`) is the single source of truth for
the three-lane Bridge: an embedded `models.json` manifest (one entry per capability ×
lane), a pure availability resolver, the pure `effective_lane` selection rule, and an
on-demand download manager. Free models are never bundled — they download into
`<data_dir>/models/<id>/` and emit `model-download` events (`{id, capability, lane,
state, received_bytes, total_bytes, error?}`) over the same listener bus.

Swift wrapper: `EngineModel` (`@MainActor ObservableObject`) exposes `accounts`,
`dataVersion`, `store: InboxStore`, and async helpers `perform / send / sync /
reload / fetchMessage / downloadAttachment / addAccount / removeAccount /
retryOutbox / deleteOutbox / setRuleEnabled / createBuiltinRule / updateBuiltinRule / deleteRule /
createCalendarEvent / updateCalendarEvent / deleteCalendarEvent / respondToEvent`, the Bridge helpers
(`bridgeBrief / bridgeReply / bridgeAgentTurn / bridgeValidateOpenAI / bridgeOpenAITTS`), and the model
manager (`modelLanes / effectiveLane / downloadModel / deleteModel / modelPath`, plus a published
`modelDownloads: [id: ModelDownload]` fed by `model-download` events and a one-shot `setDeviceProfile`
at engine start). `bcc`, os_log backend, and `FfiAttachment(filename, mimeType, data: Data)` are part
of this surface.

---

## 4. Data layer — `InboxStore` (SQLite reads)

Mirrors the desktop frontend SQL (`useInboxConversations`, `conversationDetail`,
`SearchResultsView`, `useCalendarEvents`, `useContactSuggestions`). Key reads:

- `conversations(accountKey?, folder, filter, query)` — routes by:
  - **search** (query non-empty) → FTS5 over `messages_fts` (`buildFtsMatch`: AND-ed
    quoted terms, `or`/`and`, trailing `*` for prefix; archived shown, trash/spam
    hidden).
  - **triaged** filter → cross-folder, any conversation with `priority_urgent` or
    `priority_important` set (an Eisenhower quadrant assigned).
  - **folder**: Inbox/Archive/Trash = `status` (open/archived/trash); Sent = folder-role
    join; Drafts = `is_draft`; **Triage** = match the per-account gmail label id
    (derived from `external_folders.key` suffix) against `message_provider_state.labels`.
  - else inbox status query, optional `read = 0` for Unread.
- `messages(conversationKey)` — thread, oldest first (incl. `sentiment_label`,
  `intent_label`).
- `conversation(key)`, `recentActivity(limit)`, `upcomingEvents(fromISO)`,
  `contacts()` (frequency-ranked, cached), `unreadCount(accountKey?)`.

Status constants: `ConvStatusValue` (open/archived/spam/trash, `inboxHidden`,
`discarded`). Timestamps are ISO-8601 text (all-day events are date-only) — see
`RelativeTime.parse`.

---

## 5. Models, managers, components

**Models** (`Models/`, `Data/InboxStore.swift`): `Conversation`, `Message`,
`CalendarEvent` (carries `accountKey` for RSVP write-back), `Contact`,
`AttachmentInfo`, `SavedDraft`, `ActivityEntry`, `OutboxItem` (parsed from
`outbox_messages` payload), `WritableCalendar` (create-event targets), `LocalRule`
(keyed, for toggle/create), enums `ConvStatus`, `OutboxStatusValue`
(pending/sending/sent/failed, mirrors Rust `OutboxStatus`), `InboxFilter`
(All/Unread/Triaged), `MailFolder` (.mailboxes incl. **.outbox** + .triage),
`MarkReadMode`. `MailAddress` parses `"Name <email>"` + lists; derives initials +
a stable color seed.

**Managers** (app-root `@StateObject`, injected via environment):
`EngineModel` (FFI + store), `ThemeManager` (Appearance system/dark/light/Soirée/Atelier/Groovebox,
persisted), `MarkReadManager` (4 Outlook modes + delay), `DraftStore` (local
drafts → UserDefaults JSON), `NotificationManager` (engine-event → local
notifications), `ChromeModel` (a detail-screen counter so pushed screens — e.g.
the reader — hide the floating nav), `VoiceEngineManager` (Bridge config: the
OpenAI key in Keychain + `keyValidated`, and a per-capability `BridgeLane`
preference — `native`/`free`/`openai` — for `BridgeCapability` `.stt/.tts/.nlu`,
migrated from the old `apple`/`openai` VoiceSource keys; default TTS = free
Kokoro, STT/NLU = native).

**Bridge voice** (`Audio/`) — three lanes per capability, each free lane behind a
compile guard so the app builds without the SDK and the lane falls back:
- **TTS** — `Speaker` routes per `EngineModel.effectiveLane("tts")`: `openai` (`tts-1`),
  `free` → `KokoroSpeaker` (sherpa-onnx, `#if BRIDGE_KOKORO`; manager-downloaded model,
  PCM → `WAVWriter` → metered playback), else Apple `AVSpeechSynthesizer`.
- **STT** — `ListeningManager` resolves the lane Swift-side: `native` Apple
  `SpeechAnalyzer`/`SpeechTranscriber` (iOS 26 — live partials, OS-managed model assets,
  no in-app download; replaced the old WhisperKit free lane), `openai` →
  `bridge_openai_transcribe` (records the clip, transcribes on release,
  `isTranscribing`). The barge-in `KeywordSpotter` still runs `SFSpeechRecognizer`.
- **NLU** — `BridgeBrain` maps `VoiceEngineManager` → `FfiBridgeConfig`; on-device
  generation goes to `BridgeLLM` (the `OnDeviceLlm` callback), which routes by the NLU
  pref: `free` → `LiteRTEngine` (Gemma via MediaPipe, `#if canImport(MediaPipeTasksGenAI)`,
  manager-downloaded `.task`), else `AppleLLM` (Apple Foundation Models, iOS 26+).

The three-lane catalog (manifest, availability, downloads, `.tar.bz2` extraction) lives
in the **Rust core** (`bridge/models`); `BridgeVoicePanel` renders it via `modelLanes` +
a per-free-lane download/delete card (`ByteCountFormatter` size, license, `model-download`
progress). Lanes absent from the manifest for a capability (e.g. STT free) render no pill.
Activating a free lane = adding its dependency in `ui/ios/project.yml` (see
docs/model-manager.md §6). Shared model ids live in `BridgeModelIDs`.

**Action sheets** (in their owning view files, not standalone — the Xcode project
uses explicit source lists): `NewEventSheet` + `EventDetailSheet` RSVP section
(`CalendarView`), `NewRuleSheet` + the account ⋯ Reconnect/Remove menu
(`SettingsView`).

**Components** (`Components/`): `AvatarRing` / `ChannelAvatar` (gradient-ring
avatars), `InboxLogoTile` (the inbox2 brand cube `ch-unified` on a light rounded
tile — the icon for the inbox2 mx sign-in / empty states), `ChannelsRow`,
`FilterPills`, `FloatingNavBar`, `GlowCapsule` (the `.glowCapsule(colors:)` floating
capsule chrome shared by the nav, the bulk-action bar, and the toasts), `FolderDrawer`, `ConversationRow`, `Avatar`,
`AIBadge` (sentiment/intent), `AISummaryPanel`, `EmptyState`, `InboxTag` +
`PressableStyle`/`FlowRow` (Primitives). Reader:
`MessageBodyWebView` (self-sizing WKWebView, posts content height + blocked count),
`MessageSourceView` (raw headers + body sheet), `ReaderView` (single-body demo).
`InsetCard` + `CardStyle` (a shared raised-card surface with top-glow + gradient
border, `.insetCard()` modifier) used by the reader cards, AI summary, calendar,
and conversation rows so the inset margin is consistent everywhere.

---

## 6. Design tokens (`Theme/Theme.swift`)

Adapted from `ui/web/src/styles/tokens.css` (Vista Aero × **violet** mobile
direction — iOS leads with violet, not the desktop's warm-tan). Everything is a
token; **no raw `.system(size:)` and no re-typed hexes** outside the token files.
`ThemePalette` (dark default + light) is injected via `@Environment(\.theme)`;
`StyleGuideView` (Settings → dev mode) is the live showcase / approval surface for
all of the below.

**Colors — `ThemePalette`:**

| Group | Tokens |
|-------|--------|
| Surfaces | `bgBase` · `bgPanel` · `bgSurface` · `bgRaised` · `bgElevated` · `bgInput` |
| Text | `textPrimary` · `textSecondary` · `textTertiary` · `textMuted` · `textLink` · `textSender` · `textWarm` |
| Accents | **`accentViolet`** (the lead app accent) · `accentPrimary` (steel) · `accentWarm` · `accentWarmBright` · `accentSuccess` · `accentWarning` · `accentDanger` · `accentPurple` · `accentAmber` · `accentTeal` |
| Borders | `borderDefault` · `borderSubtle` · `borderStrong` |
| Status | `statusOpen` · `statusPending` · `statusArchived` · `statusSnoozed` · `statusUrgent` · `statusAI` |
| Ring | `ringColors` (violet → pink → amber) + `ringGradient` (closed `AngularGradient`, the single source for the avatar ring + Bridge orb/spinner) |
| WebView CSS | `webBg` · `webText` · `webMuted` · `webLink` · `webQuoteBorder` · `webStatusBg` · `webStatusText` (**hex** strings — the reader needs CSS colors) |

**Themes:** `.dark`, `.light`, `.soiree`, `.atelier`, `.groovebox` (one `Appearance`
case each, picked in Settings › Theme). Soirée/Atelier swap `AppFont` to Jost +
Bodoni Moda; **Groovebox** (web `[data-theme-variant="groovebox"]` + `lib/groovebox.js`,
hex-for-hex) swaps it to Figtree + Rubik (OFL TTFs in `Resources/`, `UIAppFonts`) and
sets the opt-in Groovebox tokens — each defaults to the existing look, so other themes
are unchanged:

| Token | Groovebox treatment |
|-------|---------------------|
| `unreadLED` (`unread`) | LED-green `#5fd68a` unread dot + timestamp |
| `selectKeycap` | selected/active state (nav tab, `SegmentedTabs`/`FilterPills`, selected day, chosen option) = cream keycap (`#f6f2e9→#e4ded1`, 3pt `#a9a192` edge) |
| `primaryKeycap` / `secondaryKeycap` | primary/send = lavender radial dome (`#5a40a8` edge, `#1a1424` label); secondary = dark keycap (`#34343a→#26262b`, 2pt `#08080a` edge). Apply with `.keycapSurface(role, radius:) { existingBackground }` + `palette.keycapLabel(role, or:)` — a no-op returning the fallback in every other theme |
| `navTabColors` | rainbow tabs on the floating nav: Inbox coral, Lore mustard, Compose teal, Calendar lavender, Settings pink — icons tinted in their colour; the selected tab is the dark `secondaryKeycap` with a `#f3f0ea` label |
| `selectedRowFill` | selected rows = `#262233` + 1.5pt lavender ring, r14 |
| `solidChipInk` | `InboxTag`, recipient chips, calendar events/zones = solid pastel fill with `#141416` ink |
| `panelRadius` | `insetCard`, the inbox list well and settings groups become solid `bgPanel` panels with radius 20 (no glow/bevel) |
| `toggleTint` (`toggle`) | toggles teal `#44c2b3`; links keep the lavender accent |
| `calendarGridLine` / `calendarNowLine` | hour lines `rgba(148,121,216,0.25)`; now line mustard |
| `zoneTones` | calendar zone keys mapped to the pastels |
| `AppFont.section` | section headers in Rubik (`Faces.displaySections`) |
| `guidebookGrid` | page backdrop (`.pageBackground()`: inbox, settings, calendar, bridge) = `GrooveboxScene` (Canvas: `#2a2a2e` + violet 30° iso-grid, 64×37 cells, line alpha 0.22 behind content / 0.42 on the splash); content blocks over it sit on solid panels inset 12pt (`.grooveFramed()`, `insetCard`) and loose hint text on a solid capsule (`.grooveCapsule()`); the launch splash plays the full scene drawing itself in (`GrooveboxLaunchScene`, 1.6s, then holds) instead of the app-icon animation |

`Color(hex:)` and `Color(r:g:b:a:)` helpers live alongside. (Desktop-only ports
that were never used on iOS — `bgSidebar`, `bgHover`, `bgSelected`, `chromeGradient`,
`primaryButtonGradient(+Hover)` — have been removed.)

**Brand hues — `Theme/ChannelColor.swift`:** the canonical brand colors
(`electricBlue`/`electricBlueDeep` — BMW-i hero; `violet`/`violetDeep`) live here;
the per-channel `gradients` ramp (8 hues, deterministic per `accountKey`) and the
chrome/orb accents (`FloatingNavBar` Bridge-blue, `GlowCapsule.inboxAccent`,
`OrbView.kElectricBlue`) all reference them rather than re-typing hexes.
Helpers: `index/stops/gradient/base(for:in:)`.

**Type scale — `AppFont`** (SF Pro; `ui(size, weight)` is the factory, `mono(size,
weight)` for code/IDs/`mx`). Named steps:

| Token | Size / weight | Role |
|-------|---------------|------|
| `display` | 26 semibold | onboarding/empty-state hero, large glyphs |
| `title` | 22 semibold | screen + section titles (chain `.smallCaps()` for brand headers) |
| `xl` | 20 semibold | — |
| `title2` | 19 semibold | sub-headers, prominent nav/bulk icons |
| `lg` | 18 semibold | — |
| `title3` | 17 semibold | row headers (month/folder), back chevron |
| `body` | 17 regular | iOS default body — settings rows, list detail |
| `md` | 16 medium | — |
| `base` | 15 regular | — |
| `sm` | 14 regular | — |
| `xs` | 13 regular | — |
| `xs2` | 12 regular | — |
| `xs3` | 11 medium | smallest label |

Off-scale `AppFont.glyph(n)` (the renamed raw factory) survives only for icon glyphs / dynamic weights where no
baked-weight token fits (a 34pt settings icon, single 19/22pt icons, one
`active ? .semibold : .regular` nav label). The email body uses the desktop
EmailFrame stack exactly: `14px/1.5 -apple-system, BlinkMacSystemFont, 'Segoe UI',
Roboto, Helvetica, Arial, sans-serif`.

**Spacing & radii:** `Space` on a 4px grid (`s1`4 · `s2`8 · `s3`12 · `s4`16 ·
`s5`20 · `s6`24 · `s8`32); `Radius` (`xs`2 · `sm`3 · `md`5 · `lg`8 · `xl`12 ·
`full`9999).

**Component library — `Sources/Components/`** (each reads the active theme):

- `InboxButton` — `.primary` (**violet filled capsule**, white text on
  `[accentViolet, accentViolet 82%]` + violet glow; matches ActivityView's "Open" /
  the compose FAB), `.secondary` (elevated surface capsule), `.ghost` (text only).
- `InboxTag` (pill badge, dim accent fill — defaults to `accentPrimary`),
  `AIBadge` (sentiment/intent chips with `.sentiment`/`.intent` constructors).
- `InboxCard` (groove-bordered panel), `InboxTextField`, `SectionLabel`, `FormRow`
  (form rows), `FlowRow` (wrapping tag layout, iOS-16 `Layout`).
- `Avatar` (initials + deterministic tint), `AvatarRing` (gradient-ring avatar,
  spins while loading), `ChannelAvatar`, `InboxLogoTile` (brand cube on a light tile).
- `GlowCapsule` / `.glowCapsule(colors:)` — the shared floating-glass capsule chrome
  (FloatingNavBar, bulk-action bar, toasts), `GradientSpinner` (ring-gradient
  "generating" arc), `EmptyState` (ring-gradient hero illustrations).

**App icon** (`Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`,
single universal 1024). Same source SVG as desktop, but the treatment is the
**opposite** of the macOS Big Sur grid: iOS icons are **full-bleed, opaque, no
alpha** (iOS masks the corners itself), so the gradient ring must reach every
edge — no padding. Scale the SVG *up* so its squircle bleeds off the canvas, then
flatten alpha (the masked-away corners go card-purple, `#5E4AE3`):

```sh
# squircle 960/1024 → render at 1092 so it bleeds, center-crop to 1024, flatten
rsvg-convert -w 1092 -h 1092 inbox2-icon-ring-two.svg -o bleed.png
magick bleed.png -background '#5E4AE3' -gravity center -extent 1024x1024 -flatten -alpha off icon-1024.png
```

**Empty-state illustrations** (`Resources/Assets.xcassets/EmptyStates/es_*`). A
cohesive set of hero glyphs — SF-Symbol-style line art painted in the **ring
gradient** (`#a05cff → #ff5ca8 → #ff9d5c`) on the **`#090a0e`** base, so each one
floats seamlessly in dark and clips to a clean tile in light. Generated to match
the app rather than hand-drawn. The set: `es_inbox`, `es_search`, `es_drafts`,
`es_outbox`, `es_calendar`, `es_activity`, `es_explorer`, `es_messages`, `es_rules`,
`es_accounts`. `EmptyState` renders one as a 168pt hero (no SF-Symbol fallback);
`SettingsInfo` takes the same via `illustration:` (left-aligned, 104pt); the calendar
agenda/month "no events" cards use a compact (88–96pt) variant. Inline field hints
in the reader (no tags / assignees / notes) stay as plain text — a hero illustration
would overwhelm those compact bars.

**Brand label.** The product name **`inbox2 mx`** renders the `mx` token in a
monospaced (code) face via `AttributedString.inbox2mx(monoSize:weight:)` — the other
runs inherit the host `Text` font, so callers keep their sizing/smallCaps. Threaded
through `styled:` inits on `ScreenHeader` / `SettingsScaffold` / `SettingsMenuRow`
(the `String` inits are preserved, so no other caller changed).

---

## 7. OAuth onboarding (loopback)

Account onboarding goes through the **Rails OAuth proxy** (holds the client
secret; public, no inbox2 login needed). The proxy only allows **loopback**
redirects, so iOS uses the desktop's pattern:

1. `LoopbackServer` (NWListener) starts on an ephemeral 127.0.0.1 port.
2. `OAuthService.authorizeURL` GETs `/api/v1/auth/{google|microsoft}/authorize?
   redirect_uri=http://127.0.0.1:<port>/oauth-callback&state=…` → consent URL.
3. Consent shown in **SFSafariViewController** (Google blocks embedded WebViews);
   the listener catches the redirect → `code`.
4. `complete` POSTs `/auth/{provider}/token` → tokens, then reads the email
   (Google userinfo / MS Graph `/me`).
5. `EngineModel.addAccount(authMethod: "xoauth2", …)` stores it + syncs.

IMAP uses a manual form → `addAccount(authMethod: "plain", host/port/password)`.
Requires the dev Rails server with `GOOGLE_/MICROSOFT_CLIENT_ID/SECRET`. The live
consent round-trip is a manual verification step.

---

## 7a. Share extension — "Send to Inbox2"

A second target (`ShareExtension`, `com.apple.share-services`) lets the user share
files/photos/text from any app and **compose + send right in the share sheet** — the
Gmail/WhatsApp model. iOS forbids a share extension from launching its host app (only
Today widgets may), so we don't try; the extension does the work itself and never bounces
back to the source app.

**Why not just open the app?** The responder-chain `openURL:` hack is unreliable on
modern iOS (silently no-ops) and App-Store-risky. So the extension hosts its own compose
instead. It still can't reach the engine's encrypted connected-channel credentials from
its sandbox, which splits the send path:

- **Domain (mx) identity** → sends immediately from the extension via the **reused
  `CloudClient`** (create draft → upload attachments → send). Server-backed, app-independent.
- **Connected channel (Gmail/IMAP/Microsoft)** → the API can't send through these (their
  OAuth tokens are on-device only), so the extension writes a durable **`QueuedSend`** into
  the App Group; the app flushes it through the engine outbox on next foreground / background
  refresh (`ShareSync.drain`).

Flow:
1. `ShareViewController` copies each shared file into a per-send App Group dir (streamed via
   `loadFileRepresentation` → `ShareBridge.copyIn` — **never** `Data(contentsOf:)`, which
   would blow the extension's ~120 MB limit on a video), collects text/URL into the body,
   then hosts `ShareComposeView` (a `UIHostingController`).
2. `ShareComposeView` is a self-contained port of `ComposeView` using the same `Theme`
   tokens (From-identity picker, To/Cc/Bcc, Subject, body, attachment chips). On Send it
   routes per the table above.
3. The app mirrors the From-identity list + domain session token + API base into the App
   Group (`ShareBridge.Context`, written by `ShareSync.writeContext` on launch/foreground/
   change) so the extension's picker and direct domain send work.

**Code sharing (no duplication):** the domain send stack is pure SwiftUI/Foundation/Security
with zero engine coupling, so these files are compiled into **both** targets via
`project.yml` — `Theme.swift`, `AppConfig.swift`, `Log.swift`, `CloudClient.swift`, and the
extracted `CloudDTOs.swift` (the pure `Cloud*` DTOs + `OutgoingAttachment`, split out of
`CloudModels.swift`, whose engine-coupled `Conversation`/`Message` extensions stay app-only).
`Shared/ShareBridge.swift` is the App Group contract (also both targets).

Both targets declare the App Group entitlement (generated from `project.yml`
`entitlements.properties` — editing the `.entitlements` files alone is clobbered by
`xcodegen generate`; see `memory/project_ios_entitlement_portal_registration`). The app
embeds the extension (`dependencies: target: ShareExtension, embed: true`). Android does the
equivalent in-process — its `ACTION_SEND` filter opens the real `ComposeScreen`, which already
handles both engine and cloud sends, so no queue is needed there (see [Android-App.md](Android-App.md)).

---

## 8. Logging

`os.Logger` under subsystem **`com.inbox2.app`** (categories: engine, store, sync,
action, ui, reader) and the Rust core under **`com.inbox2.core`** (oslog backend,
`ffi::init_logging`, mobile-ffi only). View:
`xcrun simctl spawn <SIM> log show --last 60s --info --predicate 'subsystem == "com.inbox2.core" OR subsystem == "com.inbox2.app"' --style compact`.

Testing without OAuth: seed the simulator from the desktop store (DB + the
`.credential_key`) — see [iOS-Simulator.md](iOS-Simulator.md) /
`memory/project_ios_real_data`.

---

## 9. Feature parity & deferred

**Done (real data, verified in-sim):** inbox + per-channel/folder/filter, FTS5
search, threaded reader (collapsible AI summary, inline images, sentiment/intent,
quote/signature collapse, show-images, per-message details disclosure + raw view-
source), attachments (fetch/download/Quick Look), conversation actions + a glow undo toast,
**Move to Inbox** restore from Spam/Trash/Archive (row menu, reader overflow, and a
bulk action — `ConversationAction.restore(fromStatus:)` → unarchive/untrash/unspam,
undoable), swipe actions, a long-press row triage menu (read/quadrant move/
archive/trash/spam) mirroring the reader's overflow menu, multi-select edit mode with
bulk actions (account-grouped over the same `perform_action`), send (cc/bcc/attachments)
+ reply/forward, drafts, an Outbox folder (queued/failed send visibility read from
`outbox_messages`), contact autocomplete, mark-as-read modes, activity feed,
calendar agenda **+ month grid** (per-day event dots, day-detail), triage folders,
account onboarding (Google/Microsoft loopback OAuth + IMAP), themes, full logging.

**Done — FFI batch (Rust wrappers + xcframework rebuilt; live writes pending
user verification):** account **remove / reconnect** (Settings → Connected
accounts ⋯ menu), outbox manual **retry** ("Send now" on failed sends) **+ cancel**
(swipe-to-delete a stuck send), local-rules
**enable/disable + create + edit + delete** (toggle inline; New rule sheet builds a
built-in rule; long-press → Edit/Delete),
calendar event **create / edit / delete** (Calendar "+" or event ⋯ → New/Edit
sheet; ⋯ → Delete with confirm) **+ RSVP** (Yes/Maybe/No on invites). UI + bindings
verified in-sim; the live provider/destructive writes (create/edit/delete event,
remove account) are the user's to confirm.

Reconnect now **pre-selects the account's provider** and auto-starts its OAuth/IMAP
flow (Settings → Connected accounts ⋯ → Reconnect).

**Local-channel parity: complete.** Every desktop local-mailbox capability now has
an iOS equivalent — reading, search, the threaded reader, all conversation/triage
actions, send/drafts/outbox (incl. retry + cancel), contacts, calendar (agenda +
month, create/edit/delete, RSVP), auto-rules (create/edit/delete/toggle,
multi-condition incl. `has_attachment`), account add/remove and provider-preselecting
reconnect, themes, and logging. No known feature gap against the desktop's
local-channel surface remains.

**Notifications — server-free.** New mail raises a **local notification**
(`NotificationManager`, UNUserNotificationCenter) straight from the engine's
`new-message` event — no APNs, no Rails. While the app runs, the in-process engine
syncs + scans rules and fires banners directly. For delivery when the app isn't
foreground, a **`BGTaskScheduler` app-refresh** (`com.inbox2.refresh`, registered
via SwiftUI `.backgroundTask`) periodically wakes the app to `syncAllAndWait()`;
the post-sync rule scan emits `new-message`, which becomes a notification. This is
best-effort (iOS decides the cadence) — instant delivery while fully suspended or
terminated would still want APNs later, but no server infra is needed for the
common case.

**Notification action buttons.** Every new-mail notification (local channel
banner *and* the Rails APNs alert, which stamps `aps.category = "MAIL"` in
`MobilePushPayloadBuilder`) carries the `MAIL` category with **Archive / Trash /
Mark as read** — the desktop card's row minus Reply. They run **without opening
the app**: iOS launches or wakes the process in the background and calls the
`UNUserNotificationCenter` delegate, which has until its completion handler to
finish. The handler persists the action (`inbox2_pending_notification_actions`
in UserDefaults) and drains it at once through the existing routers — engine
`perform` for channels (durable: local state now, provider write-back queued +
retried), `cloud.perform` with the push's `organization_id` for MX. If the engine
or session isn't up yet (cold background launch) the queue is drained by
`Inbox2App`'s launch task instead, so an action is never lost.

**Unread widget (home screen, medium + large).** A stack of unread mail you work
through without opening the app: the newest unread on top with up to two cards under
it, and Read / Archive / In 3 h / Trash as glass buttons in their own colours; the large
size adds the "Move to" quadrants (Priority / Schedule / Delegate / Later). Quadrants are
channel-only and snooze is MX-only, so the button that doesn't apply to the top card is
dimmed. "Move to" also marks the thread read, because a thread on the stack is one
still to handle. The icon follows the chosen app icon (`BrandMark`). Flow:
`UnreadStackFeed` (app) writes the top six unread (channels + MX, newest first) into the
App Group (`UnreadStack`, `LiveActivity/UnreadStack.swift`) on every
`MailActivityManager.refresh`, and reloads the timeline only when the snapshot changes.
The buttons are `UnreadStackIntent`, a `LiveActivityIntent`, so they run in the app's
process: the card drops off the top at once, then the action goes through the
notification-action queue (snooze straight to the API). A handled thread stays out of the
stack for 180 s so a stale sync can't put it back. The widget itself only renders
(`Widgets/UnreadStackWidget.swift`).

**Mail Live Activity.** The EasyPark-style card: a lock-screen / Dynamic Island
Live Activity (`Inbox2Widgets` WidgetKit extension, `Widgets/Inbox2Widgets.swift`)
showing the newest unread message with inline **Archive / Read / Trash** buttons
and a "+N" unread pill; tapping opens the thread via `inbox2://conversation/<key>`
(`.onOpenURL` → `pendingConversationKey`). `LiveActivity/MailActivityAttributes.swift`
is compiled into both the app and the extension: the (empty) attributes, the
`ContentState` (the wire contract with Rails — keep field names in sync with
`MobilePushSender.live_activity_state`), and `MailActivityActionIntent`, a
`LiveActivityIntent` whose `perform()` iOS runs **in the app process** (launched in
the background if needed) — the extension never touches the engine; the
`INBOX2_WIDGET` condition compiles the app-side body out of the extension.
`Sources/MailLiveActivity.swift` (`MailActivityManager`) owns the card: `refresh()`
recomputes the newest unread across channels (SQLite, `filter: .unread`) and MX
(current org, `view: "Unread"`), updates the running card, ends it when nothing is
unread, and starts one only in the foreground (iOS forbids background starts);
called on foreground, on every `new-message`, after any conversation action
(`EngineModel.perform`, `CloudSession.markChanged`) and after the notification
queue drains. Cards for mail arriving while locked are push-started over APNs
([Cloud-Push.md](Cloud-Push.md) "Live Activity"): Rails sends the start itself
for MX mail; for channel mail the woken app, after its sync, finds the newest
unread and asks Rails to push-start a card with that content
(`PushRegistrar.requestLiveActivityStart`, once per message) — never a
placeholder, so the echo of your own archive/trash can't conjure a card. The
manager observes `activityUpdates` to adopt push-started cards and reports the
push-to-start token and each card's update token through
`PushRegistrar.reportLiveActivity`. A card button runs `MailActivityManager.perform`, which reuses the
notification-action queue and then advances the card. iOS ends any Live Activity
after 8 h; the next foreground or push-to-start recreates it. Needs
`NSSupportsLiveActivities` (project.yml) and the `inbox2` URL scheme.

**inbox2 mx mode — landed (read + write).** The API-backed team pool is now
a first-class mode: sign in (Settings → **inbox2 mx**), and it appears as a
channel in the inbox with live conversation list, threaded reader, actions
(archive/trash/spam/read), and threaded reply/send. See §10 for the architecture and
the remaining domain-only gaps (Sent/Drafts views, attachment upload, FAB new-thread,
tags/assignment, realtime).

**Still desktop-only (in progress):** the **vector / semantic search** surface. The
embedding pipeline (`ort` + `tokenizers` ONNX inference) lives in the desktop crate,
not `inbox2-core`, so the current xcframework can't run it — see [Vector-MCP.md](Vector-MCP.md).
The iOS-native path (in progress) is Apple's **NaturalLanguage** embeddings to
re-rank the existing FTS5 results on-device (no new native deps); the MCP agent
tooling stays desktop-driven.

---

## 10. inbox2 mx mode — the API-backed team pool

> User-facing name: **inbox2 mx** (`mx` in code font). "domain" persists only in
> internal/architectural references (the shared-domain pool served over the MX path).

A **second client mode** alongside the offline channels: the shared-domain unified
mailbox served by the **Rails API** (the "MX" path). Unlike channels (local SQLite,
written via FFI), **domain mail is always live from the REST API** — there is no
local cache. The two modes coexist; the domain shows up as just another **channel**
in the inbox row.

**Auth (`Sources/Cloud/`).** Bearer-token over `/api/v1` (no cookies/CSRF):
- `Keychain` — stores the session token (the only secret the cloud client holds).
- `CloudClient` (actor) — `POST /auth/login` (+ 2FA), `GET /account`, `logout`;
  mail read (`/orgs/:id/conversations`, `/conversations/:id`, `/views`, search) and
  write (`/conversations/bulk`, `PATCH …`, `POST /messages`). Generic request/decode
  + API-error extraction. Base URL overridable (`inbox2_cloud_api_base`).
- `CloudSession` (`@MainActor`) — auth state, signed-in user, orgs, active org;
  validates the stored token against `/account` on launch; 401 → signed out. Exposes
  domain-mail helpers that **map `CloudConversation`/`CloudMessage` → the shared
  `Conversation`/`Message`** so the existing rows/reader/compose render domain mail
  unchanged. The folder→`status` and verb→bulk-action translations live here.
- `CloudLoginView` + Settings → **inbox2 mx** (sign in / identity + org / out); the
  signed-out state leads with the inbox2 brand cube (`InboxLogoTile`).

**Jev triage metadata.** `CloudSession.syncTriageMeta()` (on sign-in / org switch and
every foreground) fetches each org's `triage-labels` (names for MX rows' custom-label
chips, `TriageLabelNames.byOrg`) and pushes the current org's classifiable `spaces` to
the engine as `set_space_taxonomy` objects. Rows show built-in label badges, a neutral
chip for custom slugs (name from the local or org list, else the title-cased slug) and
an **Urgent** (≥ 3.5) / **High** (≥ 2.5) chip from `triage_priority` — for both channel
(SQLite) and MX (`triage_label`/`triage_priority` on the conversation JSON) rows.

**Integration seam.** A domain thread's `accountKey` is its `org_…` id, so
`Conversation.isDomain` lets the inbox/reader/compose branch: domain channels read
via `cloud`, actions go to `cloud.perform` (translated verb), the reader loads
`cloud.messages`, and replies send via `cloud.send` (conversation-threaded; the
`ComposeDraft` carries `conversationId` + an explicit from address). Engine paths
are untouched — non-`org_` keys still route to the FFI. Quadrant triage is hidden for
domain (the pool uses tags/assignment, not quadrants).

Compose works for both modes through a unified **From-identity picker** (offline
accounts + `username@org.domain`); picking a domain identity routes the send to the
API, so new domain threads compose from the global FAB.

**Domain write/collaboration surface (all shipped):**
- **Tags** — read + editable in the reader (chips + a menu over the org palette).
- **Assignees** — read + editable (member-picker menu → `PUT assignees`).
- **Notes** — read + add (inline field → `POST notes`).
- **Attachments** on send — the draft lifecycle (create draft → multipart upload →
  send threaded to the draft's conversation → delete draft), now that the draft
  response carries `conversation_id`.
- **Snooze** — reader overflow + inbox row menu (Later today / Tomorrow / Next week).
- **Undo-send** — after a domain send, an inbox "Message sent · Undo" toast reverts
  it (the API now defers delivery by `Message::SEND_UNDO_WINDOW` so the cancel lands).
- **Schedule-send** — compose Send button → menu (Send now / Schedule send…) → a
  date picker. The API now has a real `scheduled_at` column + `wait_until` deferred
  delivery (cancel-send also cancels a future scheduled send).
- **Folders/views** — Inbox/Archive/Trash (status), **Sent** (`direction=outbound`),
  **Drafts** (the `/drafts` endpoint); the filter pills become the team-pool **views**
  (All / Mine / Unassigned / Unread) via the `assignee` filter.

These required matching **API additions** (committed in `api/`): `direction=outbound`
+ `assignee` filters on `conversations#index`; `conversation_id` on `MessageSerializer`;
`assignees` + `notes` on `ConversationDetailSerializer`; and deferring outbound
delivery so undo-send actually works.

**Remaining (each needs a decision / backend feature, not just iOS UI):**
- **Org-admin** — tag CRUD, routing-rule CRUD, member management, conversation
  merge/split. Power/admin features, lower priority for a mobile client.
- **Realtime** — fetch-on-open + pull-to-refresh today; would use ActionCable (or
  the APNs nudge) to push domain changes live. Server-side transport work.

---

## 11. Android port notes

Reuse, don't rebuild:
- **`inbox2-core`** via UniFFI Kotlin bindings — the exact same `InboxEngine`
  surface (§3). Run **`ui/desktop/core/build-android-jni.sh`** (the Android analog of
  `build-ios-xcframework.sh`) to produce the per-ABI `libinbox2_core.so` + the generated
  `inbox2_core.kt`; drop both into an `:inboxcore` module instead of an `.xcframework`.
- **The domain (MX) REST client** (§10) — port `CloudClient`/`CloudSession` to
  Kotlin (Ktor/Retrofit + the same endpoints); the token lives in the Android
  Keystore. The model-mapping contract (API → shared row models) is identical.
- **`@inbox2/email-body`** JS in an Android `WebView` (same bundle, same CSP +
  show-images flag).
- **The SQL** in §4 — port `InboxStore` to Android SQLite/Room verbatim; the schema
  + queries are identical.
- **Design tokens** (§6) → a Compose theme; same hex values.
- **OAuth** (§7) → Android Custom Tabs + a loopback listener (or the system browser
  + an intent), same Rails proxy + `add_account`.
- **`ConversationAction`** (`Models/ConversationAction.swift`) → a Kotlin enum/sealed
  class carrying the same `verb` / `reverse` / `title` / `icon` / `removesRow`, plus
  `restore(fromStatus:)` (archived→unarchive, trash→untrash, spam→unspam). This is the
  single source for the engine verb, the undo inverse, the toast badge glyph, and the
  "Move to Inbox" mapping — port it verbatim; the engine accepts the same `unspam`/
  `untrash`/`unarchive` verbs (org/MX threads map all three to `open`).

Rebuild in Jetpack Compose: the screen model (§2), the managers (§5), the row/card
components. The data-flow contract (read SQLite, write FFI, re-query on engine
events) is unchanged.

- **Bridge model manager** (`bridge/models`, §3) — the manifest, availability
  resolver, selection, and download manager are **already in the shared core**, so the
  Android client only adds the UI + audio I/O + the inference engines. At engine start
  call `set_device_profile{os:"android", android_native_speech:<has a SpeechRecognizer>}`
  — Android has **no native LLM lane**, so NLU shows only `free` (LiteRT) + `openai`, and
  on Android the `free` lane *is* the on-device path. Mirror `BridgeVoicePanel` as a
  Compose three-lane control (a `SegmentedTabs` equivalent) with the per-free-lane
  download/delete card driven by `model_lanes` + `model-download` events. Inference
  engines (slice 5): sherpa-onnx (TTS/STT) and LiteRT (NLU) via JNI; the manager hands
  back a verified `model_path(id)` directory. Map `BridgeLane`/`BridgeCapability` to a
  Kotlin enum 1:1; persist the per-capability lane preference like `VoiceEngineManager`.

**Parity notes for the three latest improvements** (web/desktop → iOS, now → Compose):
- **Floating glow chrome — one component.** `GlowCapsule` (a `ViewModifier` in
  `Components/MobileChrome.swift`, applied via `.glowCapsule(colors:)`) is the single
  source: a translucent `.ultraThinMaterial` **capsule**, an accent-gradient hairline
  border, a blurred copy of that gradient as a **glow halo** behind it, and a soft
  shadow. `FloatingNavBar`, the **bulk-selection bar**, the **undo toast** (with a
  neutral circular action-icon badge + title + Undo), and the domain **"Message sent ·
  Undo"** toast all apply it, so every floating affordance is literally the same chrome.
  The default accent is `GlowCapsule.inboxAccent` (the nav's inbox purple). The
  undo/send toasts **anchor to the top** (an `.overlay(alignment: .top)`, dropping in
  below the header); the selection bar stays bottom-anchored. In Compose: build one
  `Modifier` (translucent capsule `background` + gradient `border` + a blurred gradient
  layer behind) and apply it to the nav, the bar, and the toasts alike.
- **Undo restores position.** Undo re-inserts the conversation at its captured index
  (the desktop/web equivalent of "move the cursor back to the affected item"). iOS
  has no persistent list selection, so re-insertion *is* the restore; on Compose keep
  the same captured-index re-insert.
- **Move to Inbox.** Surfaced wherever the conversation's status is spam/trash/archived
  (`Conversation.isRestorable` / `restoreAction`) — row context menu, reader overflow,
  and the bulk bar (keyed off the folder via `folderRestoreAction`); the redundant
  same-folder removal item is hidden. The desktop's ⌘Z keyboard-undo fix (dropping the
  native Edit-menu Undo accelerator) is **desktop-only** — there's no keyboard-undo
  surface on mobile, so nothing to port there.
- **No flag concept.** inbox2 triages with the Eisenhower quadrants, not flags. There
  are no flag/unflag affordances; the third filter pill is **Triaged**
  (`InboxFilter.triaged` → `priority_urgent` OR `priority_important`), and every menu's
  "flag" slot is the quadrant Triage submenu. (`ConversationAction.flag/unflag` linger
  as inert enum cases — the engine still accepts the verb — but no UI dispatches them.)
- **Bulk bar replaces the nav.** Multi-select hides the floating nav (`chrome.editing`)
  and the bulk bar takes its exact spot, **mirroring it pixel-for-pixel**: the same
  `GlowCapsule`, intrinsic-width centered, 48×48 icon-only buttons at 19pt semibold in
  the nav's accent gradient (no labels, no destructive red) — order **Read / Archive /
  Triage / Trash** (+ Move to Inbox in restore folders). On Compose: drive nav
  visibility off the same editing flag and render the action bar in the nav's slot with
  the shared capsule modifier.

## 12. Car mode, CarPlay & morning weather

**Car mode** controls Bridge brief verbosity: **on → the full daily brief** (the
hands-free rundown), **off ("normal") → a terse one-or-two-sentence headline**. It is
brief-only — per-message read-aloud, tomorrow/week, and triage are unaffected.

- **Bluetooth-driven default.** `VoiceEngineManager` observes
  `AVAudioSession.routeChangeNotification` and sets `bluetoothConnected` when the output
  route is `bluetoothA2DP/HFP/LE/carAudio` (a car kit/headset). `effectiveCarMode =
  carPlayConnected || (carModeOverride ?? bluetoothConnected)` — i.e. connected → on,
  disconnected → off. The top-left toggle on `BridgeView` (`car`/`car.fill`, mirroring
  the top-right game button) sets `carModeOverride` for the current connection; the
  override is **reset whenever the Bluetooth connection flips**, so each drive starts on
  the Bluetooth default. Nothing is persisted.
- **Wiring.** `BridgeBrain.briefSpoken(…, weather:)` passes `concise: !effectiveCarMode`
  into `bridgeConfig`; the prewarm loop (`Inbox2App.startBriefPrewarm`) matches the same
  verbosity so a tap is a cache hit. The core (`bridge/brief.rs` `spoken_concise` /
  `agent.rs` verbosity-tagged cache key) does the actual shortening.
- **Morning weather.** `WeatherService.morningLine()` (`Cloud/`) fetches the short line
  from the Rails API (`GET /api/v1/weather`, IP-based, unauthenticated) only when the
  local hour < 12, swallowing any failure. The core appends it to the end of a morning
  brief; it lives *outside* the brief cache so a changing forecast never invalidates the
  composed text.

**CarPlay** (`Sources/CarPlay/CarPlaySceneDelegate.swift`). A
`CPTemplateApplicationSceneDelegate` presents a `CPListTemplate` — Daily brief / Tomorrow
/ Weekly highlights — each driving the shared `BridgeBrain` + `Speaker` and showing the
spoken text on a `CPInformationTemplate`. It can't read the SwiftUI environment, so it
reaches the shared `EngineModel`/`VoiceEngineManager`/`Speaker` via the `CarPlayLink`
weak statics (set from `Inbox2App`'s `.task`, the same pattern as `PushRegistrar`).
Connecting sets `voice.carPlayConnected = true`, forcing the full brief and disabling the
in-app toggle. The scene is declared in `project.yml` (`UISceneConfigurations` →
`CPTemplateApplicationSceneSessionRoleApplication`).

- **Entitlement.** CarPlay needs the **`com.apple.developer.carplay-driving-task`**
  managed entitlement (the template category that shows a dashboard icon with
  `CPListTemplate`/`CPInformationTemplate` — *not* `carplay-communication`, which is for
  full messaging/VoIP+SiriKit apps and shows no generic icon). It is **kept out of
  `Inbox2.entitlements` by default** (a commented one-liner in `project.yml`) because an
  ungranted managed entitlement breaks device code-signing.
- **Testing in the CarPlay Simulator.** The Simulator honors the entitlement straight
  from the entitlements file — **no Apple grant needed**. Uncomment the `project.yml`
  line, `xcodegen generate`, build for a simulator (`xcodebuild -sdk iphonesimulator`),
  install + launch, then Simulator → **I/O → External Displays → CarPlay**; the Inbox2
  icon appears on the CarPlay dashboard. Re-comment the line before
  `bin/ios-deploy-device` so device builds keep signing (a real device needs Apple to
  grant the entitlement first).

## 13. Meeting alarms

An opt-in "your meeting starts in 5 minutes" alarm — deliberately louder and more
insistent than a mail banner, because the failure it exists to prevent is noticing a
meeting after it started.

- **Everything is pre-scheduled.** `MeetingAlarms` (`Sources/MeetingAlarms.swift`)
  hands iOS a `UNCalendarNotificationTrigger` per upcoming meeting, ahead of time. The
  alarm therefore fires whether the app is running, backgrounded, killed, or hasn't been
  opened since — there is no server, no push, and nothing to go wrong at fire time. The
  app's only job is keeping that schedule in step with the calendar.
- **Alarm-like, within what a normal app gets.** A 25-second custom sound
  (`Resources/meeting-alarm.caf` — iOS *ignores* custom notification sounds longer than
  30s) plus `interruptionLevel = .timeSensitive`, which cuts through Focus / Do Not
  Disturb. It **cannot** beat the ring/silent switch; only a Critical Alert can, and
  that needs an entitlement Apple grants by written application. If you ever want that,
  it's `UNNotificationSound.criticalSoundNamed` + `.critical` — the rest of the
  machinery is unchanged. Note that on iPhone 15 Pro and later there is no mute switch:
  silent mode is the **Action Button** (or the Control Centre bell), which is the first
  thing to check when a banner arrives silently.
- **Entitlement.** `.timeSensitive` needs
  **`com.apple.developer.usernotifications.time-sensitive`** (declared in `project.yml`).
  Unlike CarPlay this is *self-service* — no Apple review — but the App ID still has to
  carry it, so the first device build after adding it fails with "Provisioning profile
  … doesn't include the Time Sensitive Notifications capability" until Xcode is signed
  in (**Xcode → Settings → Accounts**) and has regenerated the profile once. Without the
  entitlement iOS silently downgrades the alarm to a normal notification — it still
  rings, Focus just swallows it.
- **Reconcile, not bookkeeping.** `reconcile(engine:)` re-derives the whole desired set
  from SQLite and diffs it against `pendingNotificationRequests` (everything we own is
  prefixed `meeting-alarm:`). A meeting that moved is detected by comparing the pending
  trigger's own `nextTriggerDate()`, so it's re-armed rather than left firing at the old
  time; cancelled/deleted meetings simply stop appearing in the read and get dropped. It
  runs on foreground (`.active`), on every `engine.dataVersion` bump (the
  `calendar-changed` engine event lands there — self-throttled to 30s because mark-read
  bumps it too), from the BGAppRefresh task, and on any settings change.
- **What gets an alarm** — the rules live in `MeetingAlarmPlan` (`Models/`), kept pure
  and unit-tested (`Tests/MeetingAlarmPlanTests.swift`) because both failure directions
  are invisible in the field. Skipped: all-day events, meetings already started or
  inside the lead window (scheduling those would re-nag on every foreground), meetings
  the user declined (matched against the account addresses), individually muted ones,
  and anything past the **32** nearest — iOS keeps at most 64 pending local
  notifications per app and silently drops the rest; reconcile refills the tail.
- **Cancelling one.** The event detail sheet (`CalendarSheets.swift`) shows an alarm row
  for future timed meetings with Cancel / Restore — for the meeting that got called off
  but is still on the calendar. Muted keys live in UserDefaults (device-local; the event
  row belongs to the provider) and are pruned when they fall out of the agenda window.
- **Tapping one** opens the meeting: the notification carries `calendarEventKey`,
  `NotificationManager` republishes it as `pendingEventKey`, and `RootTabs` hands it to
  the existing `ChromeModel.pendingCalendarEventKey` route (Calendar tab → detail
  sheet). `initial: true` on that `onChange` so a cold-launch tap isn't lost.
- **Settings** — Settings → Preferences → Notifications: "Meeting alarm" (default
  **off**), the lead time (1/2/5/10/15/30 min, default 5), and **Test alarm**, which
  fires the real thing in 5s. The test isn't a debug affordance: without it you only
  discover the alarm doesn't work by missing a meeting.
- **Saying why it's silent.** `refreshSystemStatus()` reads `notificationSettings()` and
  renders a line under the toggles when iOS is blocking the alarm (notifications off,
  sounds off, Time Sensitive off) — each of which is invisible from inside the app and
  silently defeats the feature. It says *nothing* when everything is allowed; a
  permanent all-clear is noise on a settings screen.
- **The sound** is generated, not sourced: `bin/gen-alarm-sound.py` synthesizes a
  digital-alarm-clock buzzer (band-limited square wave at 3 kHz, three beeps then a
  1.5s pause) and repacks it as CAF via `afconvert`. Tune the constants at the top and
  re-run; there is no other source for the file. **Linear PCM (`LEI16`), not IMA4** —
  IMA4 is a listed-supported format and decodes fine in `afplay`, but a device build
  carrying it delivered the banner silently; 2 MB isn't worth re-litigating that. 44.1
  kHz because a square wave aliases audibly at 22 kHz.

## 14. Zones

A **zone** is a soft focus block on the user's own calendar ("Deep work · Project
Atlas, 16:00–18:00", "Prep: Q3 board review"). It **never** blocks time or marks anyone
busy — people can still book inside it. Zones live on the inbox2 API (user-scoped,
`/api/v1/account/zones` + `/account/zone-categories`, see docs/Calendar.md), so they only
exist with a cloud session: every zone surface checks `ZoneStore.enabled`.

- **Data.** `CloudZone` / `CloudZoneCategory` (`Cloud/CloudDTOs.swift`; `CloudZone`
  parses its millisecond ISO dates once in `init(from:)`) and `CloudClient` calls
  (`zoneCategories`, `zones(startISO:endISO:)`, `saveZone(id:body:)`, `deleteZone`,
  `saveZoneCategory(id:body:)`, `deleteZoneCategory`). The list returns
  **occurrences**: a repeating zone appears once per day it runs with
  `id = "zon_x@20260925T140000Z"`; `seriesId` groups them. `id` is the key everywhere
  (cache, dismissals, `zone-start:<id>` notifications, the Live Activity), so each day
  of a repeat alerts and is dismissed on its own. PATCH/DELETE take the occurrence id:
  a retime shifts the whole series by the same delta, a delete removes the series.
  `ZoneStore` (`Sources/Zones.swift`) is the one cache: `load(from:to:)` replaces the
  zones overlapping the window (so a delete elsewhere drops out); `refresh()` pulls
  −1d…+14d and re-arms alerts on sign-in and every foreground, and clears everything on
  sign-out. The calendar loads −30d…+90d plus each month grid it shows. The store keeps
  the union of loaded windows: a write that touches a repeating zone drops that series
  from the cache and re-fetches the union (capped at the API's 400 days), since the
  PATCH response is the series row, not its occurrences.
- **Colour.** `category.color` is always a palette key (blue/amber/violet/green/rose/
  teal). `ThemePalette.zoneTones` maps it per theme — dark tones on Dark/Soirée, deeper
  shades on Light/Atelier — via `p.zone(key)`. Fill = tone at 14% + 7% diagonal stripes
  (`ZoneFill`), outline = tone at 45% (85% while active), label text = tone mixed 35%
  toward `textPrimary`.
- **Calendar.** In the agenda and the month day list (`CalendarView.dayRows`), each
  timed event is nested in the first zone its start falls inside (`ZoneBlock`: category
  dot + name, zone name, time, note); zones with no events still show in time order,
  and zone-only days get their own agenda section. An active zone gets a "1:41 left"
  pill and a progress bar. Month cells draw a thin underline per zone category. Tapping
  a zone opens `ZoneSheet` (edit / delete). "+" asks New event / New zone when signed in.
- **Day timeline** (`Views/CalendarDayView.swift`, the "Day" segment; shares
  `selectedDay` with the month grid). A 24-row hour grid (56pt/hour, one `Canvas` for
  hour lines + dotted half-hours, hour labels double as `ScrollViewReader` anchors —
  opens at now−1h today, 08:00 otherwise), a header with ‹ › + Today (swipe left/right
  also pages days), an all-day strip above the grid, and an `accentDanger` now-line with
  a dot on today. Timed events are blocks positioned by start/end (22pt minimum), with
  overlapping ones split into columns per overlap cluster; channel tint like the agenda
  rows; tap → `EventDetailSheet`. Zones are drawn **behind** the events as full-width
  `ZoneFill` bands (outline 45%, 85% + "N left" pill when active); only the top-left
  label (category · name) takes touches and opens `ZoneSheet`, so the band stays a
  drag target. Rows map wall-clock hour/minute, so DST days still fit 24 rows. The view
  loads its own day of events and calls `ZoneStore.load` (±7d) only when
  `ZoneStore.covers(from:to:)` says the day isn't already fetched.
  **Drag to create:** a UIKit `UILongPressGestureRecognizer` (0.3 s, via
  `UIGestureRecognizerRepresentable` — SwiftUI's long press has no location) on the
  empty grid; once it begins the scroll view's pan can't, and `.scrollDisabled` holds it
  while selecting, so a normal swipe still scrolls. Dragging snaps to 15 minutes (a
  selection tick per slot), drawn as an accent rectangle with the live "09:00 – 10:30"
  label. On release the shared "New" dialog shows the range and offers New event (if a
  writable calendar exists) / New zone (if signed in); the sheet opens pre-filled via
  `NewEventSheet(…, initialStart:initialEnd:)` / `ZoneSheet(…, initialStart:initialEnd:)`.
  A third option, **Block time** (only for a drag range, and only signed in with an
  org — `BlockedTimeStore.enabled`), creates a blocked window at once with no sheet,
  matching the desktop's "Block time — Shown as busy, not an event".
- **Blocked time** (`Sources/BlockedTimeStore.swift`, `CloudBlockedTime` in
  `CloudDTOs.swift`; `CloudClient.blockedTimes/createBlockedTime/deleteBlockedTime` →
  `GET|POST /orgs/:org_id/blocked-times`, `DELETE …/:id`, the cloud session's current
  org). "Not available" windows that every free/busy read counts as busy (meet links,
  the scheduling assistant) but that aren't calendar events; the API returns only the
  member's own (docs/Calendar.md). The Day view loads the visible day's blocks
  (re-keyed on sign-in, org and day; silent on failure) and lays them out with the
  events (same overlap columns, above the zones) as neutral grey hatched blocks —
  `ZoneFill` in `textTertiary` with a stronger hatch over an opaque `bgBase`, so it
  follows every theme — labelled "Blocked" + the range. Tap → "Remove blocked time?"
  ("This window will become bookable and show as free again.") → DELETE. Errors land
  in the calendar's shared alert. Not shown in the agenda or month views.
  Not built: tap-to-create, auto-scroll while a selection reaches the edge, dragging
  existing events to move/resize.
- **Zone sheet.** Start is a date+time; End is a time of day that lands on the start's
  date, or the next day when it's at/before the start ("next day" hint) — so overnight
  zones work and length is capped at 24h by construction. Repeat: Never / Every day /
  Every weekday / Every week, with an optional "Until" last day (`repeat_until`,
  `YYYY-MM-DD`). Creates send `time_zone = TimeZone.current.identifier`. Editing a
  repeating zone says "Changes apply to all repeats"; delete reads "Delete all repeats".
- **Categories.** "Edit categories" under the chips pushes `ZoneCategoriesView`: colour
  dot + name, tap to rename/recolour (`ZoneCategorySheet`: name + one of the six palette
  swatches), "+" to add, swipe or long-press to delete. Deleting uncategorises its zones
  in the cache too (the API nullifies). There's no calendar settings screen on iOS, so
  the sheet is the only entry point.
- **Prep zones.** `EventDetailSheet` → "Prep zone" (30 min / 1 hour / 2 hours) creates
  "Prep: <title>" in the category named "Prep", ending at the meeting's start, with
  `anchor_event_id` = the event key and `anchor_minutes`. **It follows its meeting:**
  every calendar load (agenda, chart, month, and after each zone load) calls
  `ZoneStore.reconcileAnchors(events)`; an anchored, non-repeating zone whose event is
  loaded (the store already hides cancelled events) and whose start differs from the
  zone's end by a minute or more is PATCHed to `start − minutes … start`. An event that
  isn't loaded leaves the zone alone. Retiming an anchored zone by hand in the sheet
  clears its anchor, or the next reconcile would snap it back.
- **Alerts** (notify = true, "Zone alert" in the sheet, default on):
  - a pre-scheduled local notification at the start (`zone-start:<id>`, `.timeSensitive`,
    at most 16 pending — MeetingAlarms shares iOS's 64 cap): "You're in the zone:
    <name>" / "<Category> until HH:mm" + note;
    A refresh never removes a pending request whose zone starts within the next 5 s
    (too close to re-add safely, but it's about to fire);
  - `ZoneBanner`, a sticky card in `RootTabs`' top safe-area inset over every tab, with
    a live `Text(timerInterval:)` countdown, progress bar and "Done · Open calendar" —
    plain secondary-colour text links, not pills, so they're less tempting to click
    (still real `Button`s, 44pt targets; Open sets `ChromeModel.showCalendar`, which
    RootTabs turns into the Calendar tab). The Live Activity has the same two links
    (Open is a `Link` to `inbox2://calendar`, handled in `onOpenURL`). The card stays
    until Done: once the zone ends it shows "Zone ended" (no countdown, full bar).
    Overlapping zones → the one that started last (`ZoneStore.cardZone(at:)`, same as
    web). A zone seen running is "raised" (`inbox2_zone_raised`, id → end); only raised
    zones linger past their end, so one that ran entirely while the app was suspended
    gets no card. A raised card drops a day after its zone ends (the cache window);
  - a Live Activity (`LiveActivity/ZoneActivityAttributes.swift` +
    `ZoneLiveActivity` in the existing Inbox2Widgets bundle — no new target or
    entitlement). Started in the foreground only (no push-to-start), `staleDate` = zone
    end, ended on Done, on the zone ending while we're alive, or on the next foreground
    — the in-app card outlives it. While the app is alive a wake timer fires at the
    active zone's end or the next undismissed notify-zone's start, whichever is first,
    so the Live Activity and card switch on time.
  Done stores the zone id with its end in UserDefaults (`inbox2_zone_dismissed`, id →
  end, like web's `{id: endMs}`; entries drop once the zone has ended, no count cap) and
  ends the card, the banner and the Live Activity; editing a zone re-arms it. The Live Activity has its
  own **Done** (lock screen + expanded Dynamic Island): `ZoneDoneIntent`, a
  `LiveActivityIntent` beside `MailActivityActionIntent` that likewise runs in the app
  process (`#if !INBOX2_WIDGET` body) and calls `ZoneStore.dismiss(id:)` — same dismissed
  set, ends the activity directly, and only re-syncs alerts when the cache is loaded (a
  background launch has an empty cache, which would otherwise cancel every pending zone
  alert).
- **Cross-device dismissal.** Done is per occurrence and shared with the user's other
  devices (server `zone_dismissals`, docs/Calendar.md "Zones"):
  - **Out.** `ZoneStore.dismiss(id:)` applies it locally, queues it in
    `inbox2_zone_dismiss_pending` (id → end) and POSTs `/account/zone-dismissals
    {occurrence_id, end_at}` (`CloudClient.dismissZone`, idempotent). Failures stay
    queued and `refresh()` (every foreground) retries them first; 404/422 drop the entry,
    as does the zone ending. `ZoneDoneIntent` awaits the POST so a background launch
    isn't suspended mid-request (if the session is still restoring it just stays queued).
    The zone notification has no action button, so there's no third Done path.
  - **In.** The zone list's `dismissed: true` is merged into the local map on every
    `load`. A silent `zones_changed` push (`PushRegistrar`, handled before the engine
    guard since zones are cloud-only) applies its optional `dismissed` occurrence id at
    once, then `ZoneStore.syncFromPush` waits up to 5 s for the launch-time session
    restore and runs `refresh()` (refetch + re-arm). The completion handler fires when
    that finishes, or at 25 s regardless.
  - Local and remote dismissals share `markDismissed`: dismissed map, un-raise, end the
    Live Activity, and remove the `zone-start:<id>` notification, pending and delivered.
