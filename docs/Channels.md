# Channels — external mailbox sync

"Channels" are the per-account adapters that sync an external mailbox (Gmail,
Office 365 / Microsoft Graph, or any IMAP server) into the desktop client's local
SQLite database. All of this runs in the **Rust/Tauri backend** behind one
provider-agnostic interface — the React UI never talks to a provider directly; it
reads the synced data straight from SQLite and reacts to events the engine emits.

> Mail for a connected **domain** (the MX path) is a different system — it lands
> in PostgreSQL via the API. Channels are the per-user **client-side** path:
> fully offline, stored in the desktop app's SQLite, never touching the API
> except to proxy OAuth (see [OAuth](#oauth--token-refresh)).

- Code: `ui/desktop/src-tauri/src/sync/`
- Schema: `ui/desktop/src-tauri/migrations/001_create_schema.sql`
- Live e2e harness: `ui/desktop/src-tauri/src/bin/sync_check.rs` (see [Running the live e2e test](#running-the-live-e2e-test))

---

## Architecture

```
                         ┌───────────────────────────────────────────┐
  React UI (webview)     │            Rust sync engine                │
  ──────────────────     │  ─────────────────────────────────────    │
  reads SQLite directly  │  SyncEngine (engine/)                    │
  via tauri-plugin-sql   │   • 60s poll loop + 5s write-back loop     │
        ▲                │   • connect → list → initial/incremental   │
        │ Tauri events   │   • drives every provider through ONE      │
        │ (sync,         │     trait: ProviderAdapter                 │
        │  new-message,  │                                            │
        │  calendar-     │   ProviderAdapter (provider.rs)            │
        │  changed)      │   ├── ImapAdapter      (imap_adapter.rs)   │
        │                │   ├── GmailAdapter     (gmail_mail.rs)     │
  invoke() commands ────▶│   └── MicrosoftAdapter (microsoft_mail.rs) │
  (start_sync, fetch_    │                                            │
   message, send_…)      │   TokenManager (oauth.rs) — OAuth refresh  │
        │                │   SyncStore (store.rs) — threading, dedup, │
        │                │     cursors, write-back queue, integrity   │
        ▼                │   CalendarAdapter (calendar.rs)            │
   shared SQLite  ◀──────│   InteractiveProvider (interactive.rs)     │
   (inbox2.db)           └───────────────────────────────────────────┘
```

The engine is **provider-agnostic**: it never branches on provider type. Each
provider implements `ProviderAdapter` and the engine drives all of them through
identical code paths. Adding a provider = adding one adapter.

### The two seams that keep it generic

1. **Opaque cursor.** A folder's sync position is an opaque `String` the provider
   defines. IMAP encodes a UID; Gmail uses a `historyId`; Microsoft a `deltaLink`
   URL. The engine just stores and replays it.
2. **The store owns mailbox logic.** Adapters return `UnifiedMessage`s; the store
   (`store.rs`) does conversation threading, dedup, orphan cleanup, and write-back
   queueing. Adapters never write to the message tables.

---

## The provider interface

`ProviderAdapter` (`src/sync/provider.rs`):

| Method | Purpose | IMAP | Gmail | Microsoft |
|--------|---------|------|-------|-----------|
| `connect` | auth + report `ProviderCapabilities` | TLS + LOGIN/XOAUTH2 + CAPABILITY | `GET /users/me/profile` | `GET /me` |
| `list_folders` | folders/labels → well-known roles | LIST + SPECIAL-USE | `labels.list` | `mailFolders` |
| `initial_sync(folder, batch, continuation)` | one batch of a full sync | `UID FETCH from:*` | `messages.list` + `messages.get(full)` | `messages/delta` |
| `incremental_sync(folder, cursor)` | changes since cursor | `UID FETCH 1:* (CHANGEDSINCE)` | `history.list(startHistoryId)` | `GET {deltaLink}` |
| `apply_action(action, provider_id)` | write-back | `UID STORE`/`MOVE`; labels → folder COPY/EXPUNGE | `messages.modify`/`trash` | `PATCH`/`move` |
| `start_watching` / `stop_watching` | push | IMAP IDLE | no-op (poll) | no-op (poll) |
| `normalize_flags` / `denormalize_flags` | provider flags ↔ `UnifiedFlags` | flags | labels | isRead/flag/folder |

Two parallel interfaces sit alongside it:

- **`InteractiveProvider`** (`interactive.rs`) — user-initiated, on-demand:
  `fetch_message` (body + inline `cid:` images), `download_attachment`,
  `get_message_source`, `send_message`, `perform_action` (conversation actions +
  triage/quadrant labels). Exposed as Tauri commands; kept separate so the sync
  trait stays lean. All three providers implement it: Gmail/Microsoft over their
  HTTP APIs, and **`ImapInteractive`** by opening its own short-lived IMAP
  connections (`UID FETCH … BODY.PEEK[]`, MIME-parsed via `mime.rs`) for reads
  and an **SMTP** submission (the `lettre` crate) for `send_message`.
- **`CalendarAdapter`** (`calendar.rs`) — Google Calendar and Microsoft Graph
  calendars, driven on the same 60s poll tick as mail.

---

## Engine lifecycle (start → run → shutdown)

The engine's start and stop are wired in `ui/desktop/src-tauri/src/lib.rs`
`setup()` / the `RunEvent` handler, and logged with a clear start↔stop pair so a
client log file shows exactly when the engine came up and went down.

**Start.**

1. **Open the store** — `SyncStore::new(inbox2.db)`. The connection sets
   `journal_mode=WAL`, `foreign_keys=ON`, **`busy_timeout=5000`**, and
   `synchronous=NORMAL`. `busy_timeout` lets two instances contending at startup
   (both running schema setup) *wait out* the lock instead of failing with
   `SQLITE_BUSY`. The open is **retried 3×**; on genuine failure (corrupt DB,
   disk full, permissions) the app shows a **native blocking error dialog with a
   Restart button (`rfd`) and exits — it never falls back to a throwaway tmp DB**
   (that silently diverged data into a file the rest of the app couldn't see —
   the "No accounts connected" split-brain). Logs `Sync store opened at …`.
2. **Bus election** (`sync::ipc::start_or_attach`) — exactly one engine across
   the desktop app and the CLI daemon. The winner is **HOST** (runs the engine +
   sync loop, serves the `engine.sock` bus, broadcasts events); a loser is a
   **CLIENT** (relays the host's events to its webview and routes sync-control
   RPCs to the host, so the two never double-sync). Both still open the *same*
   `inbox2.db`. Logs `Engine: elected HOST …` or `… attaching as client`.
3. **Run loop + boot** (host only) — `run()` is spawned (logs
   `sync run loop started (60s poll, 5s write-back drain)`) and
   `boot_all_accounts()` connects every stored account (logs
   `boot: connecting N account(s)` → `boot: complete`).

**Shutdown.** On `RunEvent::ExitRequested`, `graceful_shutdown()` (guarded by a
`Once`) tears every pipeline down — `Exit` force-terminates, so `Drop` impls
won't run, and a surviving engine would keep `engine.sock` and split-brain the
next launch:

- `engine.shutdown()` — notify the run loop to stop, then **`try_lock`** each
  adapter to disconnect (idle disconnect bounded by a 2s timeout). It uses
  `try_lock`, not `lock`: a sync mid-batch holds the adapter lock across its
  network I/O, so waiting would hang exit for a whole fetch (and freeze the UI,
  since exit runs on the main thread). A busy adapter is left to the OS.
- Release `engine.sock` when we're the host.
- Kill the AI sidecar child processes (Apple Foundation Models bridge, native
  LLM) — their `Drop` won't fire under a force exit.

Every step logs (`[shutdown] …` / `Shutdown: …`), ending with
`Lifecycle: graceful shutdown complete`.

### Failure & restart semantics

| Situation | What happens |
|-----------|--------------|
| **DB can't open** | 3× retry, then a fatal native dialog with **Restart**; never a tmp-DB fallback. |
| **Quit mid-sync** | Instant — `shutdown` `try_lock`s past the in-flight batch. On restart the partial messages are already persisted, but the folder cursor only advances on a *full* drain, so Gmail/MS **re-page that folder from the start (deduped, no duplicates)** and IMAP **resumes from `last_synced_uid`**. No loss, no dupes. |
| **Error mid-sync** | The sync returns `Err` → `failed` event, slot released, status → `Error`; completed batches persist, the cursor doesn't advance. The 60s poll retries. Cursor-expiry (`history.list` 404 / Microsoft `410`) and IMAP `UIDVALIDITY` change are special-cased into a clean full re-sync. |

---

## How a sync runs (`engine/sync_flow.rs`)

`connect_and_sync(account_key)`:

1. **Claim the sync slot** (`try_begin_sync`) — see *Concurrency* below. If a
   sync is already running for this account, return immediately (no-op).
2. Emit `started`; `connect()` → capabilities; status → `connected`.
3. `list_folders()` → persist; mark Inbox/Sent/Drafts/Archive/Trash as
   `sync_enabled`. **Inbox is ordered first** (`order_inbox_first`) so the view
   the user is most likely watching fills first.
4. For each enabled folder, `sync_folder()` (emits `folder-started`):
   - **No cursor stored** → `initial_sync_folder`: loop `initial_sync(folder,
     batch_size, continuation)`, persisting messages each batch; the provider
     returns the next `continuation` (pageToken / nextLink / next UID). The page
     size **ramps** — `25, 25, 50`, then `200` (`INITIAL_PAGE_RAMP` /
     `initial_page_size`) — so the newest messages paint fast, then throughput
     wins. Each non-empty batch emits `folder-progress`. After the folder is
     fully drained, prune messages whose provider id wasn't in the
     `seen_provider_ids` set (the equivalent of "remotely deleted"); emit
     `folder-complete`.
   - **Cursor stored** → `incremental_sync_folder`: apply new/changed messages,
     `cascade_delete` the `deletions`, persist the new cursor; emit
     `folder-complete` (with `added`/`deleted`).
5. `sync_calendars()` — list calendars, full/delta sync each.
6. Release the slot (`end_sync`); emit `completed` (with folder/message totals +
   `elapsedSecs`) or `failed` (with `error`).

The **run loop** (`run()`, spawned at startup in `lib.rs`) keeps it warm: a 60s
tick re-syncs enabled folders + calendars (`poll_all_accounts`), a 5s tick drains
the write-back queue, and a channel handles push/reconnect events.

On launch the engine boots every stored account (`boot_all_accounts` in `lib.rs`
setup) and the UI also calls `start_sync`; both go through `connect_and_sync`, so
the slot coalesces the duplicate triggers into one sync (see below).

### Local actions: optimistic write + write-back

A user action on an external-account conversation (archive/trash/spam,
mark-read/unread, the `un*` reverses, priority) flows through **one** path —
`perform_conversation_action` / `set_conversation_priority` in `engine/conversation_actions.rs` — which
is the **single source of truth** for local state:

1. **Apply optimistically to SQLite up front**, before any network call.
   `local_state_for_action` (`model.rs`) maps the verb to a
   `(ConversationStatus, read)` change; `store.set_conversation_status` writes it
   (status/read only — never `updated_at`, so triage doesn't resort the inbox to
   wall-clock time). Priority uses `set_conversation_priority` the same way.
2. **Enqueue the provider write-back** (`writeback_actions`) and kick the 5s
   drain for an instant apply when connected; it retries with backoff otherwise.

Frontend callers (`useConversationActions`, `useUnifiedInbox`,
`SearchResultsView`, `NotificationPage`) **only update their in-memory list** for
instant feedback and call `performAction`/`setPriority` — they do **not** write
SQLite directly. Keeping persistence in one Rust path is why every view stays
consistent; an earlier split where the unified inbox skipped the local write let a
sync re-query resurrect just-archived/-deleted mail.

**The sync guard.** Because the optimistic local change lands before the
write-back round-trips, a concurrent sync can still pull the *pre-mutation*
provider state (a just-archived message still carrying `INBOX`, a just-deleted one
not yet in `TRASH`). `upsert_synced_message` therefore **skips
`update_conversation_from_flags` when a pending/in-progress `writeback_actions` row
exists for that message** — the local intent wins until the write-back completes,
after which a later sync sees the settled provider state and naturally agrees.
This is the inbound complement to step 1: step 1 stops the action from being lost,
the guard stops a racing sync from undoing it. (Provider→local conflicts in the
*other* direction — a write-back that fails because the server already changed —
are handled by `WriteConflict` → `handle_conflict`, "server wins".)

### Sends: the local sent copy

A send is durable (`outbox_messages` → `enqueue_send` → immediate attempt, then
the 5s drain with backoff), but the provider's own copy of it only reaches SQLite
when the **Sent** folder next syncs — minutes later. So the instant a send
succeeds, `record_sent_copy` (`engine/queues.rs`) writes the message into the
store itself, through the same `upsert_synced_message` the sync path uses: it
threads onto the parent conversation, bumps the thread, and emits the ordinary
`folder-complete` data-change event, so web/iOS/Android refresh the open thread
the usual way. The message is in the thread before the swoosh finishes.

The provider's copy then has to **merge into that row** rather than appear beside
it. `upsert_synced_message` resolves an existing message in three steps:

1. **`message_id_header`** — the RFC 5322 id. `enqueue_send` mints one per send
   (from the sender's domain) and `build_mime_message` writes it into the MIME,
   so IMAP/SMTP round-trips match here.
2. **`provider_message_id`** — the id the send returned (Gmail `messages.id`,
   Meta message id). Gmail and Graph rewrite the Message-ID they were handed, so
   for them this is the match that counts.
3. **The un-synced-outgoing heuristic** — same account, Sent folder, same
   subject + recipient, within 15 minutes, on a message row no provider sync has
   ever claimed. This is the only handle left for Graph's `sendMail`, which
   returns no id *and* re-writes the Message-ID. (Because of that, a sent copy
   recorded without a provider id deliberately gets **no** `message_provider_state`
   row — our Message-ID is not a provider handle and must never be written back
   to the API as one.)

On a match the row adopts the provider's Message-ID and the conversation adopts
the provider thread id, so later replies thread against what the recipient
actually received. Accounts with no Sent folder (Meta channels) record nothing —
there is no server copy to reconcile with.

### Concurrency: one sync per account, never the map across I/O

Two locks, deliberately separate:

- **`accounts` map** (`tokio::Mutex<HashMap<_, AccountState>>`) — the registry.
  Only ever held *briefly*: look up an account, clone what's needed, drop it.
- **Per-account adapter lock** (`AccountState.adapter: Arc<Mutex<Box<dyn
  ProviderAdapter>>>`). Network I/O (connect, list_folders, every sync batch,
  apply_action) holds *only this* lock, cloned out of the map via
  `adapter_handle()`. So a long-running sync never blocks the map — `shutdown`
  (clear-data), `add_account`, and status/diagnostics queries stay responsive
  mid-sync. (Holding the map across I/O previously deadlocked destroy-data and
  stalled adding a second account.)

- **Sync slot** (`syncing: parking_lot::Mutex<HashSet<account_key>>`).
  `try_begin_sync` atomically inserts; a caller that doesn't win **skips**. All
  sync paths — `connect_and_sync`, `poll_all_accounts`, and push-driven syncs in
  `handle_event` — claim it, so per account they serialize instead of racing. A
  second concurrent full sync would re-page every folder from the start,
  duplicating batches (the symptom: non-monotonic `folder-progress` totals).
  `syncing_accounts()` reads this set to answer "is anything syncing?" without
  touching the map.

### The sync-lifecycle event backbone

The engine emits **one `sync` bus event per phase** (`sync_event`); everything
the UI shows about syncing derives from it (no separate sync-state/progress/log
channels). Phases and their payloads:

| Phase | When | Key fields |
|-------|------|-----------|
| `started` | sync claimed the slot | `accountKey` |
| `folder-started` | entering a folder | `folderKey`, `folderName` |
| `folder-progress` | each initial-sync batch | `batch`, `added`, `synced` (running total), `conversationKeys` |
| `folder-complete` | folder drained | `synced`; initial: `batches`; incremental: `added`, `deleted` |
| `completed` | sync finished OK | `folders`, `messages`, `elapsedSecs` |
| `failed` | sync errored | `error` |

Every event also carries a monotonic **`seq`** and an **`at`** epoch-ms stamp.

`ui/web/src/lib/syncEvents.js` is the frontend contract: `isSyncStart`/`isSyncEnd`
drive the "Syncing…" indicator, `isDataChange` (folder-progress, or
folder-complete that actually changed something) drives `useSyncRefresh`'s
push-based list/detail refresh, and `formatSyncLogLine` renders the Sync Console
log. The same phases are written to the Rust log (`[sync] …` prefix) so a client
log file reads as one coherent story per run.

**Buffer + backfill (so the Console shows the *whole* run).** The engine retains
a bounded ring buffer (1000) of every emitted `sync` event. The
`SyncConsole` mounts after setup — so a sync already underway has emitted
`started`/`folder-started` before anyone subscribed live. On mount the UI calls
the **`get_sync_log`** command (bus-routed) to backfill the buffer, deduped
against the live stream by `seq`, so it reconstructs the full history rather than
only what arrived after it opened. Console entries carry `t` (from `at`) and are
sorted by it, so a backfilled (older) event lands in order even when it arrives
after a newer live one. The "Syncing…" indicator is likewise seeded on mount from
`get_syncing_accounts`, covering a sync that started before the webview loaded.

### Data model (SQLite — `001_create_schema.sql`)

| Table | Holds |
|-------|-------|
| `external_accounts` | account row (provider, host/port, SMTP submission host/port, status, avatar) |
| `external_account_credentials` | AES-256-GCM encrypted tokens (`crypto.rs`) |
| `external_folders` | folders/labels + sync state (`uid_validity`, `highest_mod_seq`, `last_synced_uid`, **`sync_cursor`**) |
| `messages` / `conversations` | the unified mailbox the UI renders |
| `message_provider_state` | per-(account, folder) provider id/flags for one message |
| `writeback_actions` | queued mutations w/ exponential-backoff retry |
| `calendars` / `calendar_events` / `calendar_attendees` | calendar data |

`calendar_events.metadata` is a JSON blob the adapters fill with what the unified
event struct has no column for:

| Key | Google | Microsoft |
|-----|--------|-----------|
| `attendees` | `attendees[]` → `{email, name, responseStatus, organizer}` | `attendees[]`, `status.response` normalised |
| `htmlLink` / `webLink` | `htmlLink` | `webLink` |
| `conference` | `conferenceData` — the **video** entry point (or legacy `hangoutLink`), plus `conferenceSolution.name` and `conferenceId` | `onlineMeeting.joinUrl` (or the deprecated flat `onlineMeetingUrl`), labelled from `onlineMeetingProvider` |

`conference` is `{ url, label, code }` and is what the client's Join button
prefers over scraping the description — see
[Notifications.md § Join links](Notifications.md#join-links-componentsmeetingprovidericonmeetingproviderjs).
Note it is **not** necessarily the host's own brand: a Zoom or Webex add-on
inside Google Calendar writes its own solution into `conferenceData`. Graph omits
the online-meeting fields unless they're in `$select` (`MS_EVENT_SELECT`);
Google returns `conferenceData` in the default event resource.

A message is deduped to **one `messages` row per `(account, Message-ID)`**, with
**one `message_provider_state` row per folder/label** it appears in. So a Gmail
message under two labels = 1 message + 2 provider-state rows (this is why
`provider_states` is usually slightly higher than `messages`).

---

## OAuth & token refresh

`TokenManager` (`oauth.rs`) holds the access/refresh tokens, and on a `401`
refreshes, persists the new tokens to the encrypted store, and retries once.
Refresh is **local-first**:

1. **Direct (preferred):** when the host has supplied the provider's OAuth
   client credentials — `SyncEngine::set_oauth_client`, or
   `load_oauth_clients_from_env` reading `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`
   and `MICROSOFT_CLIENT_ID`/`MICROSOFT_CLIENT_SECRET` (runtime env, with
   compile-time `option_env!` fallback) — refresh POSTs straight to
   `oauth2.googleapis.com/token` / `login.microsoftonline.com/.../token`.
   No Rails involved. In debug desktop builds, `setup.rs::load_dev_oauth_clients`
   additionally picks the values up from the repo's `api/.env` so `tauri dev`
   just works. The credentials persist in the encrypted store (so seeded mobile
   stores inherit them).
2. **Rails proxy fallback:** with no client credentials stored, refresh goes via
   `/api/v1/auth/{google,microsoft}/refresh` as before (no JWT required — the
   endpoint is public).

The **proxy is still required for first auth** (building the consent URL +
exchanging the code). The frontend hands the engine the proxy base + JWT via
`set_api_context` on boot.

Failure classification (both paths): a **4xx** (`invalid_grant` = revoked/expired
refresh token) → `SyncError::TokenRefresh` → the engine flags the account
`needs_reauth` (sticky; UI alerts and offers Reconnect). The alert is
rate-limited in the core — `SyncStore::claim_reauth_prompt` returns true at most
once per account per 5 minutes and stamps `engine_settings.reauth_prompted_at:<key>`,
so a dead token no longer re-prompts on every sync tick, foreground and app
launch (the clients' in-memory "already alerted" sets reset on every relaunch,
which is what made it nag). Exposed as the `claim_reauth_prompt` FFI method and
Tauri command; the passive surfaces (channel dot, inbox banner, Settings badge)
ignore it and stay accurate, and Reconnect lives in Settings › Connected accounts. A **5xx/429** is
transient → `SyncError::Http`, retried on the next sync. The proxy passes the
provider's 4xx through verbatim (it used to wrap everything in a 502, which made
a dead token look like a proxy outage). Providers may **rotate refresh tokens**
(Microsoft always does) — both paths persist a returned `refresh_token`.

---

## Peculiarities & gotchas

These are the non-obvious behaviors that were hard-won; don't regress them.

- **Per-account isolation.** Dedup and threading are scoped `AND account_key = ?`.
  The same `Message-ID` may legitimately exist in two connected accounts and must
  not be merged (`store.rs` `upsert_synced_message` / `find_conversation_by_message_id`).
- **Cursor persisted only after a folder fully syncs.** During a batched initial
  sync the provider cursor (`historyId`/`deltaLink`) is written only on the final
  batch (`next_token` is `None` until `has_more == false`). Persisting mid-sync
  would advance past unfetched messages and lose them until the cursor expires.
- **Re-listing folders must not wipe the cursor.** `upsert_folder`'s `ON CONFLICT`
  updates only metadata; sync-state columns (`uid_validity`, `highest_mod_seq`,
  `last_synced_uid`, `sync_cursor`) are preserved. Otherwise every reconnect would
  force a full resync.
- **NULL-uid dedup.** Gmail/Microsoft have no UID, so `provider_uid` is `NULL` and
  the `(account, folder, provider_uid)` unique constraint never fires. The store
  branches to dedup on `provider_message_id` instead (partial index
  `idx_msg_provider_state_gmail_mid`).
- **Cursor expiry → full resync.** Gmail `history.list` 404 and Microsoft delta
  `410`/`syncStateNotFound` map to `SyncError::CursorExpired`; the engine clears
  the cursor and re-runs `initial_sync` (same path as IMAP `UIDVALIDITY` change).
- **Microsoft and IMAP bodies are lazy.** The Graph delta `$select` doesn't
  include the body; IMAP `initial_sync` likewise fetches headers + flags only
  (`BODY.PEEK[HEADER]`, never `[TEXT]`) so a full-mailbox sync doesn't pull every
  attachment's bytes. Both have no body until opened (`fetch_message`, which
  persists the body to the local store on first fetch). Every client must trigger
  this on thread open: the desktop does it in its preview path, and the CLI
  hydrates body-less messages via the `fetch_message` RPC in `_hydrate_thread`
  (alongside attachment resolution). For IMAP, `fetch_message` re-fetches the
  whole message (`BODY.PEEK[]`), MIME-parses it (`mime.rs`) into plain/html +
  attachment parts (IMAP-style part ids like `2`, `2.1`), and inlines `cid:`
  images as data URIs; `download_attachment` re-parses and returns the part's
  transfer-decoded bytes.
- **IMAP has no labels — they're folders.** `AddLabel` COPYs the message into a
  same-named folder (created if missing) so it lives in both places (true label
  semantics); `RemoveLabel` locates the copy in the label folder by Message-ID
  (its UID differs from the source) and EXPUNGEs it. Triage/quadrant verbs map
  to `inbox2/<Name>` folders the same way.
- **IMAP send is SMTP, not IMAP.** IMAP can't send, so `ImapInteractive::
  send_message` submits via SMTP (`lettre`, blocking transport on a
  `spawn_blocking` thread; XOAUTH2 for OAuth2 accounts, PLAIN/LOGIN otherwise).
  The submission host/port live in `external_accounts.smtp_host`/`smtp_port`/
  `smtp_use_tls`; when the add-account form leaves them blank they're derived
  from the IMAP host (`imap.x` → `smtp.x`, implicit TLS on 465). Gmail/Microsoft
  leave these `NULL` and send via their APIs.
- **Calendar deltaLink seeding.** Microsoft full calendar sync uses
  `calendarView` (expands recurrences); afterward it issues a throwaway
  `events/delta?$top=1` just to obtain the first `deltaLink` for future syncs.
- **Cloud push (Gmail/Office365).** Realtime delivery is implemented via Rails-backed
  Gmail Pub/Sub `users.watch` + Microsoft Graph `/subscriptions` — the client creates the
  provider subscription pointing at our backend, which fans a content-free "go sync" signal
  back over ActionCable. The OAuth token never leaves the device. See
  [Cloud-Push.md](Cloud-Push.md). The adapters' `push` capability stays `false` (that flag
  drives IMAP IDLE); cloud push uses separate `create/renew/delete_push_subscription`
  methods, and **60s polling remains the fallback** when push is off or unconfigured.
  Two provider quirks: (1) **Gmail allows only one active watch per mailbox** — a stale
  watch from a prior session 400s with "call /stop then try again" (no distinct error
  code, so we string-match the message), so `create_push_subscription` calls `/stop` and
  retries once. (2) **Microsoft subscribes with `changeType: "created,updated,deleted"`**
  (not just `created`) so deletes and read-state/move changes push in realtime too,
  matching Gmail's INBOX-history watch; the nudge stays content-free regardless.
- **Frontend is a thin bridge.** `ui/web/src/lib/sync-manager.js` only forwards
  Tauri events (`sync`→indicator/refresh/console, `new-message`→notification,
  `calendar-changed`) onto its bus; `lib/providers/index.js` is an `invoke()` shim
  over the interactive commands. UI reads mail/calendar straight from SQLite.

---

## Testing

| Layer | Where | Network | Run |
|-------|-------|---------|-----|
| Unit / wiremock | `#[cfg(test)]` in each adapter + `store.rs` | mocked HTTP, in-memory SQLite | `cargo test` |
| IMAP integration | `tests/imap_integration.rs` | live GreenMail | see below (ignored by default) |
| Frontend | `ui/web` vitest `unit` project | none | `yarn vitest run --project unit` |
| Live e2e | `src/bin/sync_check.rs` | **real provider, real tokens** | see below |

`cargo test` runs ~73 real adapter/store/oauth tests (wiremock + in-memory DB) and
honestly reports the 8 IMAP integration tests as **ignored** (they need a server).
CI (`.github/workflows/ci.yml`) runs everything, including the IMAP tests against a
GreenMail container.

### IMAP integration tests (GreenMail)

GreenMail is a tiny multi-arch test IMAP server (zero config, arm64-native — Dovecot
images were either amd64-only or 2.4-config-incompatible). Any user authenticates
with password `testpass`; the self-signed cert requires the insecure-TLS env flag.

```sh
docker compose -f docker/docker-compose.yml --profile test up -d   # GreenMail on 3143/3993
INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 \
  IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 \
  cargo test --manifest-path ui/desktop/src-tauri/Cargo.toml --test imap_integration -- --ignored
docker compose -f docker/docker-compose.yml --profile test down -v
```

`INBOX2_IMAP_ACCEPT_INVALID_CERTS=1` disables TLS verification in the adapter
(`build_tls_connector`) — **test/CI only; never set in production.**

---

## Running the live e2e test

`sync-check` drives the **real** engine (same adapters, store, threading, calendar
code as the app) against a **throwaway** SQLite DB using your **actual stored
tokens**, then reports sync integrity. It's the only way to catch real-provider
regressions that wiremock can't (token refresh, provider quirks, threading/dedup at
scale).

It is **safe**: read-only on the live DB, syncs into a temp DB it deletes on exit.

### Prerequisites

1. The desktop app has been run and at least one account connected (so the live DB
   at `~/Library/Application Support/com.inbox2.desktop/inbox2.db` has accounts +
   encrypted tokens, alongside its `.credential_key`).
2. For accounts whose access token has expired (they last ~1h), the Rails API must
   be running on `:4000` so the tool can refresh via the proxy. The refresh
   endpoint skips auth, so no JWT is needed.

### Run

```sh
cd ui/desktop/src-tauri
cargo build --bin sync_check

# All accounts, refreshing expired tokens via the proxy:
./target/debug/sync_check --api-base http://localhost:4000/api/v1

# One account, keep the temp DB to inspect, JSON report:
./target/debug/sync_check \
  --account waseem@sadiq.nl \
  --api-base http://localhost:4000/api/v1 \
  --keep-db --json
```

Flags:

| Flag | Meaning |
|------|---------|
| `--source-dir <dir>` | live app-data dir (default macOS path above) |
| `--account <email\|key>` | sync just one account |
| `--api-base <url>` | Rails proxy base for token refresh (e.g. `http://localhost:4000/api/v1`) |
| `--jwt <token>` | proxy JWT (or `INBOX2_JWT`); optional — the refresh endpoint skips auth |
| `--keep-db` | don't delete the temp DB; print its path |
| `--json` | emit the integrity report as JSON |

A full mailbox fetch is slow (every message is fetched `format=full` on first
sync) — expect minutes per large account.

### Output

```
• alice@example.com   [gmail] … OK in 729.0s — 14 folders, 2 calendars
• bob@example.net     [gmail] … OK in 144.4s —  9 folders, 0 calendars
• carol@example.org   [gmail] … OK in  95.2s —  9 folders, 1 calendar

── totals ───────────────────────────────
  folders               32  (12 sync-enabled, 12 with cursor)
  conversations         5093
  messages              9614
  provider states       9615
  calendar events       319
── integrity (want 0) ───────────────────
  orphan provider rows  0
  msgs w/o conversation 0
  msgs w/o provider st. 0
  duplicate Message-IDs 0
  events w/o calendar   0

✓ integrity OK — no violations
```

### Integrity invariants (`SyncStore::integrity_report`)

The tool exits non-zero if any of these is non-zero:

- **orphan provider rows** — a `message_provider_state` row pointing at a missing
  message.
- **msgs w/o conversation** — a message not linked to a conversation (threading
  failure).
- **msgs w/o provider state** — a message with no provider-state row.
- **duplicate Message-IDs** — the same `Message-ID` stored twice within one account
  (dedup failure).
- **events w/o calendar** — a calendar event referencing a missing calendar.

It also reports `sync-enabled folders` vs `folders with cursor` — these should be
equal (every enabled folder completed an initial sync and saved its resume point).

Re-run it whenever tokens rotate or after changing any channel code; same input →
same clean report.
