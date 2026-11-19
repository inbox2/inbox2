# MX Sync — local mirror of inbox2-hosted mail

Status: **built on every client** (2026-09-20; step log at the bottom). See "What is left".

## The gap

Channel mail (Gmail/Office365/IMAP/Meta) lives in the client's SQLite and is available to
everything local: FTS, vector search, the MCP server, local rules, the triage worker, Bridge.
MX mail does not. Every client (desktop, iOS, Android, CLI) reads MX live over REST. The
scaffolding for a mirror exists and is dead: the local `conversations`/`messages`/`tags`/
`memberships`/`notes` tables (`ui/desktop/core/migrations/001_create_schema.sql`), the
`localData.js` read path (always returns null — nothing fills the tables), and
`SyncController` (`sync/pull` + `sync/push`, zero callers). Only `mx_writeback_actions` is live.

Goal: the device holds a complete, current copy of every MX record the member may see —
mail **and** the directory around it (org, domains, mailboxes, members, tags, spaces, triage
labels, views) — so the app is fully usable offline and MX mail is first-class for local
search, MCP and agents.

## Decisions (2026-09-20, Waseem)

- **D1 — the sync client lives in the Rust core** (`inbox2-core`), one implementation for
  desktop, iOS, Android and the CLI. The browser build has no SQLite and stays on REST.
- **D2 — depth: all mail.** Backfill runs newest-first in the background until history is
  complete. (Supersedes the 90-day rolling window picked earlier the same day.) An engine
  setting `mx_sync_window_days` (default 0 = unlimited) is the escape hatch for small devices.
- **D3 — the directory syncs too**, so an offline client can still render tabs, spaces,
  labels, assignee names and From identities.
- **D4 — sealed (E2EE) mail is stored decrypted in the local mirror.** See "Sealed mail".
- **D5 — `sync/push` is deleted.** Writes replay the real REST endpoints (validation,
  activity events, broadcasts) through the write-back queue; a generic column-push bypasses them.
- **D6 — every step is reviewed by Codex before it is committed.**

## Protocol

Borrowed from Graph delta / ActiveSync: an initial enumeration, then an opaque forward
cursor, plus a periodic reconcile that makes the whole thing self-healing.

### Change tracking (Postgres)

- One global sequence `sync_change_seq`. Two columns on every synced table:
  `change_seq bigint` (the row's version) and `change_xid bigint` (the writing transaction,
  `pg_current_xact_id()`; bigint because schema.rb cannot dump an `xid8` column).
- Stamped by a **trigger** (`BEFORE INSERT OR UPDATE`), not a model callback: the bulk
  endpoint, merge, membership suspend and the GDPR scrub all use `update_all`
  (`conversations_controller.rb:213-238, 383-384`) and would be invisible to callbacks.
- **Child tables bump their parent** (statement-level `AFTER` triggers over transition tables,
  so a 10k-row `update_all` bumps each distinct parent once; guarded with `pg_trigger_depth()`
  and a no-op when the parent row is already gone): `conversation_tags`,
  `conversation_assignees`, `conversation_accesses` → conversation; `attachments` → message;
  `note_reactions` → note. `messages` and `notes` also bump their conversation, which makes
  `conversations.change_seq` the **thread version** (used by reconcile).
- Deletes: `AFTER DELETE` writes `sync_tombstones(organization_id, record_type, record_key,
  parent_key, change_seq, change_xid)`. `parent_key` is the thread a deleted message/note
  belonged to, so visibility can be re-applied to it. Retained 90 days; each org's newest
  expired tombstone is kept as its watermark, and an older cursor is healed by reconcile.
- **Per-member state in a thread (Lore's `lore_member_dones`, 48.11):** a member-scoped row never
  reaches a mirror as its own record. The table is a `SyncTriggers::BUMPS` child, so a tick re-stamps
  the conversation; each member's next pull re-serializes the thread with their own `lore_done`
  (`Current.membership`, the same way private labels work). Teammates get a version bump and an
  unchanged payload. Local writes use the action queue verbs `lore_done` / `lore_undone`
  (`conversations/bulk`), which touch only `$.lore_done` in the payload.
- Tracked tables: conversations, messages, notes. Existing rows are **not** seeded (no
  boot-time UPDATE over the big tables): `NULL` means "unchanged since sync existed" and is
  covered by backfill.
- **The directory is not change-tracked.** Tags, members, domains, mailboxes, spaces, triage
  labels and views are small and already have member-scoped `index` endpoints; the client
  re-lists them (start, hourly, and on a `sync` hint with `scope: "directory"`) and stores the
  payloads. Seven more trigger sets would buy nothing a re-list doesn't.
- `schema.rb` cannot express triggers. They are installed by an idempotent
  `SyncTriggers.ensure!`, called from the migration and from a `load_schema` hook (so
  `db:schema:load` / `db:test:prepare` / fresh installs get them). A spec asserts the
  triggers exist in the test DB so a silent absence fails the suite.

### Commit-order safety

`nextval` is taken mid-transaction; commit order can differ. Two concurrent inbound mails are
enough: B (seq 6) commits and is pulled, then A (seq 5) commits behind the cursor and is lost.
So **the cursor walks transactions, not the sequence**: it is `(change_xid, change_seq)`, and a
pull only returns rows with `change_xid < pg_snapshot_xmin(pg_current_snapshot())` — every
transaction below that horizon has finished, so the set is complete and stable. A drained
pull parks the cursor at the horizon. `sync/head` is simply "the horizon now".
`change_seq` stays the per-record version: a row lock serializes writers, so it is monotonic
per row even when transaction ids are not. Sync reads are always served from the primary (there is no replica today; if
one appears, these endpoints stay pinned to the writer). Cost: a long-open transaction delays mirror freshness (never loses data).
New-mail latency does not depend on it: the cable/push signal names the conversation and the
client hydrates that thread directly.

### Endpoints (all under `/api/v1/orgs/:org_id/sync`, scoped by `visible_conversations`)

- `GET head` — the cursor for "now"; recorded before a first backfill.
- `GET pull?since=<cursor>&limit=` — forward delta. One `UNION ALL` of
  `(type, id, change_xid, change_seq)` over the tracked tables + tombstones, horizon-filtered,
  keyset-ordered, then
  batch-loaded through the normal Alba serializers. Every message/note page also carries its
  parent conversation (the local FK requires it). Pages are capped by bytes as well as rows.
  → `{ cursor, has_more, records: {conversations, messages, notes, tags, …}, deleted: [{type,key}] }`.
  Records are full current state — upserts are idempotent.
  **Visibility loss is a delete:** conversation candidates come from the whole org, and any
  changed conversation the member can no longer see is returned in `deleted` instead of
  `records` (grant/assignee/access rows bump the conversation, so revocation shows up here
  immediately). This discloses opaque keys of same-org threads only — accepted.
  `since` older than the tombstone watermark → `cursor_expired: true`; the client reconciles,
  refreshes the directory in full, and resumes from `head`.
  A deleted message/note is reported only while its thread is still visible to the member;
  a deleted thread is one tombstone and the client cascades.
- `GET backfill?before=<token>&limit=` — history enumeration, newest-first by last activity
  `(updated_at DESC, id DESC)` keyset, each conversation with its messages + notes nested
  (the detail serializer). Independent of `change_seq`.
- `GET keys` — `[[conversation_key, change_seq], …]` for every visible conversation. The
  client deletes locals not listed (visibility lost, missed tombstone) and re-hydrates any
  whose thread version differs or is missing (visibility gained, drift) via `sync/threads`.
  Runs at start and hourly. This replaces any "reset" signal.
- `GET threads?ids[]=` — up to 50 whole threads in the same record shapes as pull/backfill.
  Not `conversations#show`: its serializer carries no `change_seq`/`domain_id`, so a thread
  hydrated from it would sit at version 0 and be re-fetched by every reconcile. `missing`
  names keys the member can't see (the client drops them); `remaining` is what didn't fit.

### Apply rules (client)

- **Version guard:** never apply a record whose `change_seq` is lower than the local copy's
  (`NULL` = 0). Backfill and delta can then race freely; the delta replays everything that
  changed while backfill ran.
- A conversation arriving in `pull` that is not held locally (visibility gained: shared,
  assigned, domain granted) is hydrated via `sync/threads`. A page of whole threads (backfill
  or hydrate) **replaces** each thread's message/note set, so deleted children cannot linger —
  but only for threads where that page is the newest word (the thread version covers its
  children; an older page must not prune what a newer delta added).
- The member's own membership row changing triggers an immediate reconcile (domain scope moved).
- A conversation tombstone cascades to local messages/notes *still pointing at it* — merge
  re-parents children at lower seqs first, so they survive (conformance-tested across a page
  boundary).

Client order on first run: record `cursor = head` → directory (the `index` endpoints) →
backfill newest-first → forward delta from the recorded cursor.

### Signals

`organization_<key>` cable already fires on inbound + send. Every successful API write also
sends `{type: "sync", scope: "mail" | "directory"}` (`BaseController#broadcast_sync_hint`,
debounced 1s per org+scope per process) so teammates' archives/reads arrive without waiting
for the poll. A hint carries no data; a lost one costs a poll interval. Desktop
forwards the cable event to the core; mobile pulls on push wake + foreground; everyone polls
(60s foreground) as the failsafe.

## Local store

**MX mail lives in its own tables** (`mx_conversations`, `mx_messages`, `mx_notes`,
`mx_directory`, `mx_sync_state` — `ui/desktop/core/migrations/001_create_schema.sql`), not in
the `conversations`/`messages` tables channel mail uses. The first plan was a shared table
with a `source` column plus an audit of every reader. The audit found **~400 SQL statements
in 39 files across Rust, JS, Swift, Kotlin and Python** reading those tables on the
assumption that every row is channel mail — the triage worker would re-judge mail the server
already triaged (on the user's own Jev key), local rules would double-fire against server
rules, unread badges would double-count (the "two halves" trap), the unified inbox would show
MX twice. Filtering 400 statements is a diff nobody can review, and every future query is one
forgotten predicate away from the same bug. Separate tables invert the default: **nothing sees
MX mail unless it asks to**, and each consumer that should (the inbox lists, search, MCP,
Bridge, vector) opts in on purpose, in its own step.

- `payload` holds the API's serialized record verbatim; read paths hand it back as-is, so the
  schema cannot drift from the serializers (and mobile decodes it with the JSON models it
  already has). Real columns exist only to list, filter and order: `domain_key`, `status`,
  `read`, `space_slug`, `triage_label`, `updated_at`, …
- `change_seq` is the held version; `hydrated` marks a thread whose full child set has been
  fetched. `sealed` flags ciphertext payloads.
- `mx_directory(organization_id, type, key, position, payload)` — domains, mailboxes,
  members, tags, spaces, triage labels, views; each listing replaced whole, server order kept.
- `mx_sync_state` — cursor, backfill token/done, reconcile + directory timestamps, and the
  `user_key` the mirror was built for. A different user on the same device wipes the org's
  rows first (visibility is per member).
- The store layer is `sync/store/mx.rs`: `mx_begin`, `mx_apply`, `mx_apply_deleted`,
  `mx_reconcile`, `mx_drop_threads`, `mx_directory_replace`, `mx_wipe`.
- **Coverage marker:** the UI serves a list from the mirror only when the mirror covers it
  (`backfill_done`, or the query is a first page the newest-first backfill has already
  passed). "Known empty" and "not synced yet" are different states — today's
  `rows.length === 0 → null` conflates them.
- Local schema upgrades keep the idempotent-ALTER pattern, but MX sync refuses to start
  unless `PRAGMA table_info` shows every column it writes (a silently failed ALTER must not
  produce rows missing `source`/`organization_id`).

## Writes

`SyncEngine::mx_action(org, threads, action)` — archive / trash / spam / open / mark_read /
mark_unread: written to the mirror at once (columns **and** `payload`, via `json_set`, so
every reader sees it), queued in `mx_writeback_actions`, and sent by `mx_drain` to the real
`conversations/bulk` endpoint (validation, activity events and broadcasts stay server-side).
Offline is not a failure; transient errors retry on the shared backoff curve.

- **One owner.** The queue is the engine's on every platform. The webview's own drain
  (`mxWriteback.js`) is deleted; rows it had queued are the same table and columns and are
  simply taken over. Claims are one `UPDATE … RETURNING` (two drainers can't both get a row);
  an abandoned `sending` claim is reclaimed after 120s (a request lives 60s at most).
- **Batching keeps each thread's order:** a claim takes every due row with the oldest row's
  org + action, but only rows that are the oldest unfinished action for their thread — "spam,
  then move to inbox" still lands in that order.
- **Refused** (4xx other than 401/408/429) or out of retries → `failed`, kept for inspection,
  and the thread is marked `hydrated = 0` so the optimistic state gives way to the server's.
  `updated` short of what was sent → the whole batch re-fetches.
- **Settle guard.** While an action is queued the thread keeps its optimistic state. After it
  lands, for 60s only records that *agree* with it are accepted — a page read before the write
  must not undo it on screen. Anything held back marks the thread for re-hydration; the guard
  lapses after 15 min regardless, so sync never depends on a queue row being cleaned up.
- The engine run loop drains every 5s and runs `mx_tick` (a pass for every mirrored org) every
  60s. Sending mail while offline is out of scope (compose stays online).

## Desktop wiring

- Tauri commands `mx_sync` / `mx_action` / `mx_forget` (`src-tauri/src/sync/commands/mx.rs`),
  routed over the engine bus in client mode like every other sync command.
- `lib/mxMirror.js` tells the engine which orgs to mirror (sign-in), kicks a pass on cable
  hints (`orgLiveMail`: `new_message`, and the any-write `sync` hint; `scope: "directory"` also
  re-lists the directory and reconciles), and forgets every org on sign-out. The inbox lists
  refresh on the engine's `mx-sync` event — after the pull, not before it.
- `lib/localData.js` reads the `mx_*` tables and returns the payloads verbatim, so
  `localFirstApi` callers can't tell the mirror from the endpoint. It answers only for a
  **complete** mirror (`backfill_done`) **built for the signed-in user**; server-only filters
  (`view_id`, `direction`, `is_draft`, `mentioned`, `assignee`) and un-hydrated threads return
  `null` → the API. `null` never means "empty". Demo mode scrubs the parsed payloads (the
  SQL-row scrubber can't see inside a JSON string). Search and unread counts stay on the API.
- `src/lib/__tests__/localData.test.js` runs that SQL against real SQLite (`node:sqlite`) and
  the engine's real schema file.

## Mobile (iOS + Android)

One FFI surface (`core/src/ffi.rs`): `set_cloud_session`, `mx_sync`, `mx_tick`, `mx_action`,
`mx_forget`, `mx_set_domain_keys`. The engine has no bearer on mobile until
`set_cloud_session` hands it one; it persists it (encrypted app secrets) and rehydrates on the
next launch, which is what lets `mx_tick` work in a cold push-wake process.

- **Reads** go straight to SQLite like channel mail does — `InboxStore+Mx.swift` /
  `InboxStore.kt` return *response-shaped* JSON spliced from the payloads, and the existing
  cloud DTOs decode it. Android's SQL uses plain columns only: minSdk 26's system SQLite has
  no JSON functions (the engine's bundled one does, and wrote the columns).
- **`MxMirror`** (`Cloud/MxMirror.swift`, `cloud/MxMirror.kt`) tells the engine which orgs to
  mirror and runs passes on sign-in, every foreground, and every push wake — mobile has no
  socket. `CloudSession` asks it first and falls back to the API on `nil`: list (status /
  read / domain), thread, tags, members. Search, Sent and the assignee views stay with the API.
  Actions (`perform`, `markRead`) go to `mx_action`, so archive / read work offline.
- Sign-out → `mx_forget` for every org: the mail leaves the device with the session.
- Sealed mail on mobile (built 2026-11-09): `mx_unlock_identity` opens the identity key with the
  password (Argon2id + secretbox, cost capped), `mx_unlock_org` opens every grant from `e2ee/my-grants` and
  calls `mx_set_domain_keys`. The identity key is kept only behind Face ID / fingerprint
  (`SealedKeychain.swift`, `SealedKeys.kt`) and asked for when a thread with locked mail opens.
  Phones read opened text from `mx_messages.plain`. Recovery phrases stay on the web.

## Search, agents, CLI

- **Local full-text search.** `mx_messages_fts` (external-content FTS5 over
  `mx_messages.search_text`: subject, people, body with HTML stripped). `SyncStore::mx_search`
  and `localData.searchLocal` — offline, and it reaches sealed mail once opened, which the
  server can never index. User text is quoted word-by-word (`fts_query` / `ftsQuery`) so it can
  never be an FTS syntax error. Trash and spam never match, like the server.
- **Agents (MCP).** The views `agent_conversations` / `agent_messages` are channel mail ∪ the
  MX mirror, and **the one place the sealed rule is enforced for agents**: an MCP client can be
  a cloud model, so a sealed message is never in them — opened or not — and neither is any
  thread containing one (its subject came out of a sealed header). The MCP read tools
  (`list_conversations`, `read_conversation`, `read_message`, `search_messages`,
  `list_accounts`) query the views; nothing agent-facing reads `mx_*` directly. A sealed
  message arriving later removes its thread from every subsequent agent query.
- **CLI.** A mirrored org is an account (`provider_type = inbox2`); its threads merge into the
  lists, messages read from `payload` / `plain`, and actions go to the `mx_action` RPC (restore
  verbs map to `open`).
- Not opted in: the Bridge brief/voice, the on-device triage worker (server Jev is
  authoritative for MX), local rules (MX has server rules), vector embeddings, unread badges
  (the server count stays — a mirror can be mid-backfill).

## The mirror is a cache

`mx_*` tables are never ALTERed. Change the schema file, bump `MX_SCHEMA_VERSION`
(`store/mx.rs`), and an older database drops the mirror atomically and re-syncs. Queued
actions (`mx_writeback_actions`) are user intent, not cache, and are never dropped.

## What is left

Checked against the code on 2026-11-09.

- **Verify on devices: partly done.** The mirror has been in use on Waseem's own devices since;
  the foreign-cursor recovery of 2026-11-05 (`d2b0bf40`: a cursor issued by another database
  restarts at the horizon with `cursor_expired`, after the Pushleft restore reset transaction
  ids) came from a symptom seen on them. There has been no soak on a second person's device.
- Opt-ins deliberately not taken (list above) — each is its own decision.
- Stale text elsewhere: Feature-Spec 16.7 still recommends PowerSync and says sync is
  desktop-only, and `docs/TODO.md` section 35 still names `/sync/push`. The routes are
  `sync/head|pull|backfill|keys|threads`. (This bullet used to say 16.7 describes `sync/push`;
  it does not name it.)

## Sealed mail (D4)

Stored decrypted locally. Rationale: E2EE.md's claim is about what the *server* durably
holds; it already lists local decrypted FTS as the only search for sealed mail and defers
local-at-rest. Channel mail already sits in the same SQLite in plaintext. Conditions:

1. Honest scope: the DB file is plain SQLite. The keychain protects credentials, not this
   file. Protection is OS disk encryption — strong on iOS/Android, **user-dependent on
   desktop** (FileVault/BitLocker may be off). SQLCipher with a keychain-held key is the
   upgrade if a customer requires it; not built now.
2. `sealed = 1` rows **never go to a cloud AI lane** (OpenAI summaries, the user's Jev key,
   cloud agents). On-device lanes only. This is the real way plaintext would leave the device.
3. The DB is excluded from device/cloud backups (iOS `isExcludedFromBackup`, Android backup rules).
4. Sign-out, identity switch, or losing the domain grant wipes the org's local rows.
5. **Ordering:** sealed rows are mirrored as the ciphertext bundle; plaintext appears only once
   the member has unlocked on this device and the engine holds a domain key.

**How it works (step 6).** `sync/seal.rs` opens sealed mail — decrypt only, interop-locked to
the producers and tested against fixtures *they* sealed (`core/testdata/sealed_by_go.json`
from `mta/internal/seal`, `sealed_by_js.json` from libsodium.js), plus wrong-key / tampered /
changed-AAD / swapped-parts refusals. The webview, which holds the identity key, hands the
unlocked domain keypairs to the engine (`mx_set_domain_keys`; `[]` on lock); the engine opens
what is mirrored at once and new mail as each pass brings it. Opened text goes in
`mx_messages.plain` (`{header, body}`); **`payload` stays ciphertext, verbatim**, so
API-shaped reads are unchanged and the webview keeps decrypting what it renders. A sealed
thread's null list columns (subject / sender / snippet) are filled from its newest opened
message. Opened text is kept only while the sealed bundle is byte-identical.

- **Keys:** memory only, one copy in the engine's map (`DomainKey` is neither `Clone` nor
  `Debug`), used in place under the lock, zeroized on drop. Cleared on lock, on `mx_forget`
  (sign-out / org removed / access lost) and before a mirror built for another user is wiped.
  **They never cross the engine bus**: a second app instance or the CLI simply doesn't feed
  the host engine — the host's own webview does.
- **Losing access:** visibility loss removes the threads (reconcile / pull deletes), and the
  plaintext goes with the rows. A grant revoked while visibility remains leaves already-opened
  text in place — the same as any mail client that already showed it to you.
- **Consumers** (search, MCP, Bridge — step 9) read `plain`, and must honour `sealed = 1`:
  never to a cloud AI lane.
- A wire-format weakness found on the way (header/body interchangeable under one AAD) is
  mitigated here and written up in docs/E2EE.md.

## Steps (each: build → tests → Codex review → commit)

1. **Server protocol** — migration + triggers + tombstones, `pull`/`backfill`/`keys`,
   delete `push`, request specs.
2. **Core schema + store layer** — the `mx_*` tables and `store/mx.rs` (the reader audit
   turned into the separate-tables decision; consumers opt in from step 5 on).
3. **Core `mx_sync`** — pull/backfill/reconcile/apply, conformance tests against a fake server.
4. **Core write-back drain + settle guard.**
5. **Desktop wiring** — Tauri commands, `localData` on the mirror, cable kick, JS drain removed.
6. **Unseal in core + sealed gating.**
7. **iOS**, 8. **Android**, 9. **CLI/MCP + docs.**

## Step log

- **2026-09-20 — plan reviewed by Codex** (18 findings). Folded in: statement-level child
  bumps + depth guard, primary-only reads, visibility loss as a delete, directory scoped by
  the existing index endpoints, version guard + hydrate-replaces-thread, `cursor_expired`,
  coverage marker, atomic write-back claim, sealed ordering, schema-column assertion.
  Rejected with reason: "`visible_to` leaks across tenants" (the scope runs on
  `current_organization.conversations`; `.or` keeps the shared org predicate), "prod won't run
  the migration" (misread — incremental migrations self-apply via `db:prepare`), "identical
  keys across orgs" (keys are global nanoids), "version the endpoint" (zero callers exist).
- **2026-09-20 — step 1 (server protocol) built.** `SyncTriggers` (27 triggers), migration
  `20260920000001` (concurrent indexes, idempotent, no DDL transaction), `SyncController`
  `head`/`pull`/`backfill`/`keys`, `sync/push` deleted, tombstone prune job, sync hint.
  Verified: full suite green; `schema.rb` load ≡ migrate-from-zero (27 triggers both ways;
  the one diff, `auto_submitted` column order, predates this work); migration re-run is a no-op.
  Codex review of the diff — cursor/horizon logic confirmed sound; fixed: deleted
  message/note keys leaked across visibility (`parent_key`), prune watermark was global not
  per-org, backfill loaded bodies before budgeting, parent-bump lock ordering, blocking index
  build, debounce hitting Postgres-backed cache, incomplete `down`. Rejected: xid8 overflowing
  bigint (2^63 transactions). **Known ceilings:** `MessageSerializer` runs 2 link queries per
  *tracked* message (pre-existing; batch if backfill of send-heavy orgs is slow); open/click
  rows don't bump their message (stats refresh on hydrate); one giant thread is served whole.
- **2026-09-20 — step 1 stress-tested before shipping** (`api/script/mx_sync_stress.rb`: 8
  writers making real commits while a client pulls). The protocol converged exactly every
  run — nothing missing, stale, or held after deletion. The triggers, though, caused **155
  deadlocks per 1200 writes** (no-trigger baseline: 1). Two causes, both fixed: the parent
  lock was `FOR UPDATE`, which conflicts with the `KEY SHARE` every child insert holds on its
  thread (→ `FOR NO KEY UPDATE`, 155 → 50); and the bulk endpoint's `update_all` locked
  threads in heap order against the triggers' id order (→ `Conversation.update_all_in_order`,
  50 → 2, 51s → 5.6s). **Rule: any new statement that writes several conversations goes
  through `update_all_in_order`.** Second Codex pass: invisible parents now also report as
  gone; the migration drops an INVALID leftover index before rebuilding. Rejected: byte
  budget ignoring JSON overhead (a soft cap by design), hint-map growth (2 entries per org).
- **2026-09-20 — step 2 (local store) built.** Reader audit → separate `mx_*` tables (see
  "Local store"). `store/mx.rs` with 16 tests: payload verbatim, channel tables untouched,
  version guard, settle guard, hydrate flagging, full-thread pages pruning children (and *not*
  when stale), merge across a page boundary, reconcile, per-user wipe, org isolation.
  Found while testing: hydrating from `conversations#show` would store version 0 forever →
  added `sync/threads` (server) and folded hydrate into `mx_apply`. Core suite 437 green.
  Codex review — fixed: `mx_wipe` left the previous user's queued actions behind (they then
  shielded threads from the new mirror); `mx_begin` wasn't atomic; reconcile could delete a
  thread a delta delivered while the key listing was being fetched (→ `applied_at` +
  `listing_started`); reconcile re-hydrated forever when the *listing* was the stale side;
  the settle guard could freeze a thread (→ lapses after 15 min, ignores `failed`, and marks
  the thread for re-hydration so a no-op write-back can't strand what was held back);
  org predicates on every upsert/lookup/delete; `sync/threads` now returns ids past its cap
  in `remaining`. Rejected: composite `(org, key)` primary keys (keys are global nanoids; the
  org predicate covers a hostile page), equal-version re-parenting (records are current
  state, both pages agree), "threads budget ignores children" (it sizes them in SQL).
- **2026-09-20 — step 3 (sync client) built.** `sync/mx_sync.rs`: `SyncEngine::mx_sync`, one
  bounded resumable pass (head → directory → delta → backfill → reconcile → hydrate); 13
  fake-server tests (wiremock) plus `live_end_to_end`, an ignored test run against a real
  local API — mirrored 29 threads / 42 messages / 43 directory rows matching the server's own
  count, a second pass moved nothing, and a real `PATCH read` reached the mirror through
  trigger → horizon cursor → delta. **Found by a test:** an un-mocked route 404'd and the
  client took it as "org lost" and wiped the mirror — any missing route or old server would
  have erased all local mail. Now a wipe needs the org to 404 *while the same base + token
  still answers `/account`*. Codex review — fixed: reconcile's removal half now runs mid-
  backfill (revoked mail doesn't wait for history; only "absent" threads wait), one API
  context snapshot per pass, non-advancing pagination is an error not a loop (pull, backfill,
  keys), `remaining` kept when a hydrate batch stalls, the live test's write is localhost-
  only. Rejected: per-org locks (one process-wide pass lock is a marked ceiling), spooling
  the key listing (5 MB at 118k threads). Core suite 453 green.
- **2026-09-20 — steps 4 + 5 (write-back in the core, desktop wiring) built** as one change,
  so the queue never had two owners or none. See "Writes" and "Desktop wiring". A mistake
  worth recording: a grep missed `main.jsx`'s dynamic `import('./lib/mxWriteback.js')`, so the
  JS drain looked never-started and a "retire legacy rows" step was added — which would have
  discarded real, recent actions. Removed; the engine takes the rows over as they are.
  Codex review — fixed: a user switch without a sign-out kept serving the previous user's
  mirror (→ `localData` requires `user_key` = signed-in user; `watch` re-kicks every org),
  watch/forget races (serialized), an unbounded kick loop, a partly-applied bulk action
  leaving threads locally wrong (→ re-fetch), and the agreement window cut from 180s to 60s.
  Rejected: duplicate send after stale reclaim (actions are set-state; a request can't outlive
  the reclaim window), per-org change events (every list already refreshed on any new mail).
  Core 464 · web 881 · lint 0 errors · desktop crate + web build green.
- **2026-09-20 — step 6 (sealed mail) built.** See "Sealed mail → How it works". Codex
  security review — fixed: keys survived `mx_forget` over the RPC path and a user switch (→
  one `SyncEngine::mx_forget`, keys cleared before another user's mirror is wiped, the webview
  always reports the full current key set); header/body swap accepted (→ refused; protocol
  fix recorded in E2EE.md); opened text kept when only the header was re-sealed (→ whole
  bundle compared); **domain secret keys were being sent over the shared engine bus** (→ never;
  client-mode instances don't feed keys); unopenable mail could starve openable mail behind it
  (→ paged by key). Rejected: wiping plaintext on lock (D4 accepts plaintext at rest; lock is
  not revocation), size caps on bundles (pages are already byte-budgeted by our own server).
  Core 470 · web 881 · desktop crate + web build green.
- **2026-09-20 — steps 7–9 (mobile, search, agents, CLI) built.** See "Mobile", "Search,
  agents, CLI", "The mirror is a cache". iOS `BUILD SUCCEEDED`, Android `BUILD SUCCESSFUL`
  (xcframework + cargo-ndk core rebuilt, bindings regenerated). Codex review — it confirmed
  the agent views keep sealed mail from MCP clients (dynamically: a sealed message arriving
  later removes the thread); fixed: **a sign-out during a running pass left that user's mail on
  disk** (→ `mx_forget` wipes, waits out the pass, wipes again; the pass checks
  `still_mirrored` before applying each page — tested with a slow server), the cache reset
  swallowed a failed `DROP` and carried on into a mixed schema (→ one `BEGIN IMMEDIATE`
  transaction, a failure fails the open), MCP search appending MX hits after a full channel
  page (→ merged newest-first), CLI sorting mixed timestamp spellings as text, swallowing
  every `OperationalError`, one bad payload costing the whole list, and no optimistic write on
  MX rows; mobile lists now go 200 deep like the channel lists. Rejected: "cold FCM wake has
  no bearer" (the engine persists and rehydrates it — existing test), Swift-6 strictness
  (project isn't on it), main-actor Keychain read (existing pattern in `restore`).
  Core 473 · web 882 · CLI 103 · desktop crate, web build, iOS and Android builds green.
