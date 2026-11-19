# Vector Search & MCP Agent Interface

Offline vector similarity search over email, plus a Model Context Protocol server that turns inbox2 into an agentic email platform. All inference and data stays on-device.

The MCP server is **hosted in-process by the Rust core** (the sync-engine process) and exposed over **loopback HTTP** — not a standalone stdio binary. It shares the engine's live DB connection and write-back queue, so agent-driven writes defer to the same sync engine the UI uses. The interface is therefore **UI-agnostic**: identical whether a Tauri window or a pure agent/MCP client is in front.

> **MX mail (2026-09-20):** inbox2-hosted mail is mirrored into local SQLite by the engine and read here through the `agent_conversations` / `agent_messages` views the read tools query. Protocol, rules (incl. sealed mail never reaching an agent) and status: [MX-Sync.md](MX-Sync.md).

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Tauri App                                                           │
│                                                                      │
│  ┌────────────┐   ┌─────────────┐   ┌──────────────────────────┐    │
│  │ React UI   │   │ Sync Engine │   │ AI Inference Engine      │    │
│  │ invoke()   │   │ IMAP/Gmail/ │   │ ONNX Runtime (ort)       │    │
│  │            │   │ Microsoft   │   │ sentiment · intent ·     │    │
│  │ vector_    │   │             │   │ embeddings (384-dim)     │    │
│  │  search    │   │ upsert_     │   └──────────┬───────────────┘    │
│  │  similar   │   │  synced_    │              │                    │
│  │  stats     │   │  message()  │     ┌────────▼────────┐          │
│  │  reindex   │   │   │         │     │ Embedder        │          │
│  └─────┬──────┘   │   │ enqueue │     │ (Arc<Mutex>)    │          │
│        │          │   ▼         │     └────────┬────────┘          │
│        │          │ embedding_  │              │                    │
│        │          │   queue     │     ┌────────▼────────┐          │
│  ┌─────▼──────────┴─────┐      │     │ Pipeline        │          │
│  │ SQLite (WAL mode)    │◄─────┘     │ poll 5s         │          │
│  │                      │            │ batch 50        │          │
│  │ messages             │◄───────────┤ chunk → embed   │          │
│  │ message_embeddings   │            │ → store BLOB    │          │
│  │ embedding_queue      │            └─────────────────┘          │
│  │ messages_fts (FTS5)  │                                         │
│  │ writeback_actions    │◄──┐  drained every 5s by Sync Engine    │
│  │ agents               │   │  → applied to provider              │
│  │ agent_audit_log      │   │                                     │
│  │ vector_settings      │   │ enqueue (defer writes)              │
│  └──────────▲───────────┘   │                                     │
│             │ live conn      │                                    │
│  ┌──────────┴───────────────┴──────┐                             │
│  │ MCP Server (in-core)            │  JSON-RPC 2.0 over HTTP      │
│  │  mcp::http  →  mcp::server      │  POST 127.0.0.1:8765/mcp    │
│  │                                 │                             │
│  │ initialize → Mcp-Session-Id     │  ◄── Claude Desktop /        │
│  │ tools/list · tools/call         │      Cursor / agents         │
│  │ resources/list · resources/read │  ──► search, read, archive,  │
│  │                                 │      trash, ...              │
│  │ Bearer-token auth · audit log   │  Permission tiers:           │
│  │ Agent sessions                  │  read │ read_write │ full    │
│  └─────────────────────────────────┘                             │
└───────────────────────────────────────────────────────────────────┘
```

The MCP server runs on its own thread inside the core process. Reads hit the
shared `Arc<Mutex<Connection>>` directly; writes do an optimistic local update
and **enqueue `writeback_actions`**, which the Sync Engine drains (every 5s) and
applies to the provider — the same write-back path the Tauri UI uses.

## File layout

```
src/
├── vector/
│   ├── mod.rs           # Module root
│   ├── chunker.rs       # HTML strip, text chunking, SHA-256 dedup hashes
│   ├── embedder.rs      # Wrapper around AIInferenceEngine::run_embedding()
│   ├── pipeline.rs      # Background tokio task — poll queue, chunk, embed, store
│   ├── search.rs        # Semantic, keyword (FTS5), and hybrid search (RRF)
│   ├── store.rs         # Embedding storage, queue management, settings, BLOB encoding
│   └── commands.rs      # Tauri IPC commands (vector_search, vector_stats, etc.)
└── mcp/
    ├── mod.rs           # Module root
    ├── protocol.rs      # JSON-RPC 2.0 types, MCP tool/resource definitions
    ├── server.rs        # Transport-agnostic JSON-RPC dispatch, agent sessions
    ├── http.rs          # Loopback HTTP transport (tiny_http), bearer-token auth
    ├── tools/           # 27 tool definitions + execution; writes → engine (write-back queue / outbox / MX action queue); attachments.rs
    ├── resources.rs     # 4 resource URIs (accounts, stats, conversations, messages)
    └── permissions.rs   # 3-tier permission model, agent registry, audit logging
```

The server is started from `lib.rs` setup (`mcp::http::spawn`) using the sync
engine's live `store().connection()` and `writeback()`. There is no separate
binary — the headless sync daemon will start the same `mcp::http::spawn`, giving
identical agent access without a window.

## Vector search

### Embedding pipeline

New messages are automatically embedded. The flow:

```
Sync adapter fetches message
  ↓
SyncStore::upsert_synced_message()
  ├── INSERT INTO messages
  └── INSERT OR IGNORE INTO embedding_queue (status='pending')
                ↓
EmbeddingPipeline::run()  [background tokio task, polls every 5s]
  ├── Check vector_settings['embedding_enabled']
  ├── Check embedder.is_ready() (ONNX models loaded?)
  └── Fetch batch of 50 pending items
       ↓ for each message:
      Chunker::chunk_message()
        ├── Extract text: prefer body_plain, fallback ammonia::strip(body_html)
        ├── Prepend metadata: "From: {from} | Subject: {subject} | "
        ├── If ≤ 2000 chars → single chunk
        └── Otherwise → split on paragraph/sentence/word boundaries
                         with 20% overlap (400 chars)
       ↓ for each chunk:
      SHA-256 hash → dedup check (skip if same hash already embedded)
       ↓
      AIInferenceEngine::run_embedding(chunk_text)
        → tokenize → ONNX encoder → mean-pool → L2-normalize → 384-dim Vec<f32>
       ↓
      VectorStore::store_embedding()
        → serialize Vec<f32> to little-endian BLOB
        → INSERT INTO message_embeddings
       ↓
      Mark embedding_queue item 'completed'
```

Failed embeddings increment an `attempts` counter (max 3 retries before giving up).

### Chunking strategy

| Parameter | Value | Rationale |
|---|---|---|
| Max chunk size | 2000 chars (~512 tokens) | Model context window limit |
| Overlap | 400 chars (20%) | Preserve context across boundaries |
| Break priority | Paragraph → sentence → word | Semantic coherence |
| Metadata prefix | `From: {from} \| Subject: {subject} \|` | Improves retrieval on sender/subject queries |
| Dedup | SHA-256 of chunk text | Skip re-embedding unchanged content |

Most emails are a single chunk. Long threads or forwarded chains get split.

### Vector storage

Embeddings are stored as little-endian `f32` BLOBs in the `message_embeddings` table — same SQLite file, same WAL connection, transactionally consistent with message data. At 384 dimensions × 4 bytes × 10K messages ≈ 15 MB.

```sql
CREATE TABLE message_embeddings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_key TEXT NOT NULL,
  chunk_index INTEGER NOT NULL DEFAULT 0,   -- 0 for single-chunk messages
  chunk_text_hash TEXT NOT NULL,            -- SHA-256 for dedup
  embedding BLOB NOT NULL,                 -- 1536 bytes (384 × f32)
  model_id TEXT NOT NULL DEFAULT 'all-MiniLM-L6-v2',
  dimensions INTEGER NOT NULL DEFAULT 384,
  created_at TEXT NOT NULL,
  UNIQUE(message_key, chunk_index)
);
```

### Search algorithms

Three search modes, all callable via Tauri IPC or MCP tools:

**Semantic search** — brute-force cosine similarity over all embeddings. O(N) scan, ~50–100ms on Apple Silicon for 200K vectors. Returns results deduplicated by conversation (best chunk per thread).

**Keyword search** — SQLite FTS5 with `MATCH`. Kept in sync with `messages` via triggers (`messages_ai`, `messages_au`, `messages_ad`). Escapes FTS5 operators to prevent injection.

**Hybrid search** — reciprocal rank fusion (RRF) combining both. The `vector_search` Tauri command uses this with `alpha=0.6` (60% semantic, 40% keyword).

```
RRF score = α / (k + semantic_rank + 1) + (1 − α) / (k + keyword_rank + 1)
where k = 60 (standard RRF constant)
```

Both result sets are over-fetched at 3× the requested limit, fused by message key, sorted by combined score, and truncated.

### What the search screen actually searches (2026-10-07)

The search screen on every client (web `SearchResultsView.jsx`, iOS `InboxListView`, Android `InboxState`) doesn't use the hybrid search above. It merges three sources:

1. **MX mail → the server** (`GET /orgs/:id/search`). `messages.search_vector` is one document per message: headers + body + the text of every attachment, built with the `'simple'` config because most of this mail is Dutch and English stemming mangles it (`Message::SEARCH_VECTOR_SQL`). Each new PDF attachment gets `ExtractAttachmentTextJob` (`pdftotext`, 50-page cap; scans have no text layer, and there's no OCR). Drafts never match, and sealed mail has no vector because the server holds no plaintext. Before this, server search only covered the conversation subject/snippet/addresses plus attachment filenames, so body words never matched.
2. **Channel mail → local FTS5** (`messages_fts`): subject, body, addresses and attachment **filenames**. Attachment content isn't indexed locally on purpose: it would mean downloading every attachment.
3. **Channel mail → the provider's own index** (`InteractiveProvider::search_conversations`: Gmail `messages.list?q=`, Graph `$search`). One request per account. It reads inside attachments, which is how "btw nummer sizio" finds a thread where "nummer" appears only in the attached PDF. Hits map back to local conversations through `message_provider_state` (Gmail id), or through the Message-ID for Graph, whose ids change when a message moves folder (`SyncStore::conversation_keys_for_hits`). Conversations not synced locally are dropped. All history is synced, so these are rare. IMAP and Meta return nothing. Exposed as the Tauri command `provider_search` and FFI `provider_search_json`. It only runs for plain-text queries (our filter operators aren't the provider's). Local rows render first, provider hits are appended. Mobile caches hits per query, because the list reloads on every sync event.

### FTS5 triggers

The `messages_fts` virtual table stays in sync with `messages` automatically:

```sql
-- Insert: index new message
CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, subject, body_plain, from_address, to_address)
  VALUES (new.id, new.subject, new.body_plain, new.from_address, new.to_address);
END;

-- Delete: remove from index
CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, ...)
  VALUES ('delete', old.id, ...);
END;

-- Update: delete old + insert new
CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, ...) VALUES ('delete', old.id, ...);
  INSERT INTO messages_fts(rowid, ...) VALUES (new.id, ...);
END;
```

### Tauri commands

| Command | Parameters | Description |
|---|---|---|
| `vector_search` | `query`, `limit?` (20), `account_key?` | Hybrid search (semantic + keyword, alpha=0.6) |
| `vector_search_similar` | `message_key`, `limit?` (10) | Find messages similar to a given one |
| `vector_stats` | — | Embedding counts, queue depth |
| `vector_reindex` | — | Clear all embeddings, re-queue every message |
| `get_vector_setting` | `key` | Read a setting from `vector_settings` |
| `set_vector_setting` | `key`, `value` | Write a setting |

## MCP server

### Overview

The MCP server exposes email data and actions over the Model Context Protocol. It is **hosted in-process by the Rust core** and speaks JSON-RPC 2.0 over **HTTP** — MCP Streamable HTTP, JSON-only (the server pushes no notifications, so there is no SSE stream).

Why HTTP and not stdio: a stdio MCP server is a point-to-point pipe established when the *host* (Claude Desktop/Cursor) spawns it as a child process — its lifecycle is owned by the host and it serves exactly one client. That is incompatible with a persistent core that runs the sync engine and serves agents on demand. HTTP lets the always-on core host the endpoint, share its live DB connection and write-back queue, and serve multiple clients.

### Transport & endpoint

| Property | Value |
|---|---|
| Method / path | `POST /mcp` (also `GET /health`) |
| Bind address | `127.0.0.1:8765` (loopback only) |
| Port override | `INBOX2_MCP_PORT` env var |
| Auth | `Authorization: Bearer <token>` |
| Token location | `<app_data_dir>/mcp-token` (generated once on first run) |
| Protocol | Dual-era. **2026-07-28** (stateless): each request carries `_meta` `io.modelcontextprotocol/protocolVersion` / `clientInfo` / `clientCapabilities`, and the `MCP-Protocol-Version`, `Mcp-Method` and (for `tools/call`/`resources/read`) `Mcp-Name` headers must match the body (`=?base64?…?=` decoded) or it's `400` + `-32020`. Unknown version → `400` + `-32022` with `data.supported`; unknown method → `404` + `-32601`. `server/discover` answers versions, capabilities and `instructions`. Every result has `resultType: "complete"` and `_meta.io.modelcontextprotocol/serverInfo`; list results add `ttlMs`/`cacheScope`. **Legacy** (2025-11-25 … 2024-11-05): `initialize` returns an `Mcp-Session-Id` header that later requests echo. |
| Agent identity | Modern: the `_meta` clientInfo name, per request. Legacy: the `initialize` clientInfo name, via the session. Either way it's self-reported; the bearer token is the gate. |
| `GET`/`DELETE /mcp` | `405`: no SSE stream, no sessions to end |

The server starts with the core (`mcp::http::spawn` in `lib.rs` setup) when `vector_settings.mcp_server_enabled` is `'true'`. A fresh install has no such row, so the server is off until the Settings card turns it on (`setup::maybe_start_mcp`). No build step, no separate process, no `--db` argument — it uses the engine's live connection.

### Settings card

Settings › On-device AI, bottom right: **Connect an AI agent** (`components/McpConnectCard`, desktop only). It has the on/off switch, a copy-paste `claude mcp add` command and a JSON config for other apps (shown with the token masked, copied whole), and the connected agents with a Read only / Read and change / Full access control each (`mcp_set_agent_access`). Full access also sets `auto_approve`: nothing in the app asks a person to approve, so without it Full would act like Read and change. Tauri commands: `mcp_info`, `mcp_set_enabled`, `mcp_set_agent_access` (`src-tauri/src/mcp/commands.rs`).

### Configuration in an MCP host

Point an HTTP/remote-capable MCP client at the endpoint with the bearer token:

```json
{
  "mcpServers": {
    "inbox2": {
      "url": "http://127.0.0.1:8765/mcp",
      "headers": { "Authorization": "Bearer <contents of mcp-token>" }
    }
  }
}
```

Hosts that only speak stdio need a thin stdio→HTTP bridge (not currently shipped).

### Protocol flow

```
Agent opens HTTP connection
  ↓
Legacy (handshake era). A 2026-07-28 client skips initialize and sends _meta +
routing headers on every request instead; same dispatch from tools/list down.

POST /mcp  initialize({ clientInfo: { name: "claude-desktop" } })
  → Register/touch agent in `agents` table
  → Open a session, return `Mcp-Session-Id` header
  → Assign permission level (default: 'read')
  → Return capabilities + server info
  ↓
POST /mcp  tools/list                    (Mcp-Session-Id: ses_…)
  → Return 23 tool definitions with JSON Schema input specs
  ↓
POST /mcp  tools/call({ name: "archive", arguments: {…} })
  → Resolve agent from session id
  → Check agent permission (level ≥ required)
  → Execute tool: optimistic local SQLite update + enqueue writeback_actions
  → Log to agent_audit_log (tool, params, result summary, duration_ms)
  → Return ToolResult ({ archived, writeback_queued })
  ↓
[ Sync Engine drains writeback_actions every 5s → applies to provider ]
```

### Tools

**Read-only** (permission: `read`):

| Tool | Parameters | Returns |
|---|---|---|
| `search_messages` | `query` (req), `limit?`, `account_key?`, `after?`, `before?`, `sort?` (`relevance`/`date`), `include_spam_trash?` | Keyword search results (FTS5). Connected-mailbox and inbox2-hosted hits merge by rank, not bm25 score — the two indexes' scores aren't comparable |
| `search_similar` | `message_key` (req), `limit?` | Semantically similar messages |
| `read_message` | `message_key` (req) | Full message content (from, to, cc, subject, body, dates) |
| `read_conversation` | `conversation_key` (req) | Thread metadata + all messages in order |
| `list_conversations` | `status?`, `account_key?`, `limit?`, `offset?` | Paginated conversation list |
| `list_accounts` | — | All connected email accounts with status |
| `list_folders` | `account_key` (req) | Folders/labels for an account |
| `get_calendar_events` | `start` (req), `end` (req), `account_key?` | Events in date range, all calendars. Inside the synced window (180 days back → 1 year ahead) reads SQLite; outside it fetches live from Google/Microsoft (`SyncEngine::fetch_calendar_events`, nothing stored) Both paths return `{source: local|provider, events, failed_calendars}`, each event with its `calendar` name and the same `cev_<account>_<id>` key, matched half-open as instants (stored times keep provider offsets, so SQL compares `julianday`, not text) |
| `get_contact_context` | `email_address` (req) | All conversations + message count for a contact |
| `list_attachments` | `message_key` (req) | `[{ attachment_id, filename, mime_type, size }]` |
| `get_attachment` | `message_key` (req), `attachment_id` (req) | A text block with the metadata, then the file: `image` block for png/jpeg/gif/webp, embedded `resource` with `text` for text types, else embedded `resource` with base64 `blob`. 10 MB cap. |
| `whatsapp_chats` | `query?` (part of a name), `limit?` | WhatsApp chats on this Mac (`whatsapp::wa_chats`, the query the WhatsApp tab runs; docs/Local-WhatsApp.md): `chat_id`, name, unread, last text, local time. macOS only; an error when WhatsApp Desktop's database is not readable |
| `whatsapp_messages` | `chat_id` (req), `limit?`, `before?` (message id) | A chat's newest messages, oldest first, times local; `has_earlier` + `before` page backwards |
| `whatsapp_search` | `query` (req), `limit?` | Message text across all chats, every word must appear (the tab's LIKE scan) |

Search, read and the `inbox2://` conversation/message resources go through the `agent_conversations`/`agent_messages` views, so they cover inbox2-hosted mail and never sealed mail. `search_messages` also matches attachment filenames.

**Attachments** have no local copy. Channel mail: `list_attachments` calls the provider's `fetch_message` and `get_attachment` its `download_attachment`, the same calls the reader makes, so both hit the network. MX mail: the list is read from the mirrored payload's `attachments` (an entry without a `download_url` has no stored bytes yet and isn't listed; its id is the last segment of that URL), and the bytes come from `SyncEngine::mx_download_attachment`, which only accepts a server-relative URL so the session bearer can't go to another host. A sealed MX message answers "not found", like a key that doesn't exist.

**Write** (permission: `read_write`):

| Tool | Parameters |
|---|---|
| `compose_draft` | `account_key`, `to`, `cc?`, `bcc?`, `subject`, `body`, `body_html?`, `reply_to_message?`, `draft_key?` — queued (see **Queued sends and drafts** below); returns the `OutboxSendResult` plus `draft_key`. Delivered as Gmail `drafts.create`/`drafts.update`, Graph delete-old + `POST /me/messages`, IMAP expunge-old-by-Message-ID + `APPEND` `\Draft` |
| `mark_read` / `mark_unread` | `account_key`, `message_keys[]` |
| `archive` | `account_key`, `conversation_keys[]` |
| `add_tag` / `remove_tag` | `account_key`, `conversation_keys[]`, `tag` — Gmail: an existing *user* label, matched by name (unknown → error); Microsoft: an Outlook category (read-modify-write of `categories`); IMAP: a same-named folder copy. System folders (INBOX, TRASH, …) are refused — tagging one is a trash/delete by the back door — and so is an IMAP `remove_tag` of the folder the message lives in (it would expunge the message) |
| `move_to_folder` | `account_key`, `conversation_keys[]`, `folder` (key, role or name) — trash is refused (that's the Full-tier `trash` tool; a ReadWrite agent mustn't reach it by calling it a move); other role folders use their verb (`archive`/`spam`/`unarchive`); any other folder is a `Move` to its provider id (Gmail label id / Graph folder id from `flags[0]`, IMAP mailbox name) and archives the thread locally. Gmail's `Move` now also drops `INBOX`, like Gmail's own Move-to |
| `create_calendar_event` | `account_key`, `title`, `start_at`, `end_at` (req); `timezone` (IANA, req unless `all_day`: the adapters read a missing zone as UTC), `all_day?`, `description?`, `location?`, `calendar?` (name) | `SyncEngine::create_calendar_event` on the named calendar, else the account's primary writable one. Google/Microsoft accounts only. No guests on purpose: nothing is mailed, so it stays ReadWrite (guests would make it Full) |
| `set_priority` | `account_key`, `conversation_keys[]`, `urgent`, `important` |

**Privileged** (permission: `full`, requires approval unless auto-approve is on):

| Tool | Parameters |
|---|---|
| `send_message` | `account_key`, `to`, `cc?`, `bcc?`, `subject`, `body_html?`, `body_plain?` (or `body`), `in_reply_to?` (a message key; threaded via `hydrate_reply_context`) — `SyncEngine::enqueue_send`, the durable outbox; returns the `OutboxSendResult` |
| `create_conversation` | Same as `send_message` without `in_reply_to`: a new thread |
| `trash` | `account_key`, `conversation_keys[]` |
| `delete` | `account_key`, `conversation_keys[]` — permanent provider delete (`ActionType::Delete`; Graph `permanentDelete` — plain `DELETE` only moves to Deleted Items), local status `trash` until the next sync drops it. **Refused for Gmail**: inbox2 connects Gmail with `gmail.modify`, permanent delete needs the full `mail.google.com` scope, and the 403 would flag the account for re-auth |

### Queued sends and drafts

Sends and drafts never go straight to a provider: they are durable rows, attempted immediately and retried with backoff (offline, 429, 5xx), for connected mailboxes and inbox2-hosted orgs alike.

| | Connected mailbox | inbox2-hosted org |
|---|---|---|
| Queue | `outbox_messages` (`kind` = `send`/`draft`, `draft_key`) | `mx_outbox` (same columns; `payload` is the API request body, resolved at enqueue). Not a mirror table, so the mirror reset never drops it |
| Retry safety | Gmail/Graph/IMAP sends have no idempotency key (hence 3 attempts) | Every attempt carries a client-chosen `message_id_header` (`<mxo_…@domain>` for a send, `<draft_key@domain>` for a draft). `messages#create` answers a repeat with the message it already made (409 if that Message-ID is someone else's); `drafts#create` upserts by it, replacing every field (so a version can clear a Cc) — 409 if it was sent since. DB-enforced by the unique `(organization_id, message_id_header)` index |
| Drained by | `process_outbox` on the engine's 5s beat | `mx_outbox_drain` on the same beat |
| Send budget | 3 attempts (a send isn't idempotent) | 3 attempts |
| Draft budget | 10 attempts (a draft save replaces, so retrying is safe) | 10 attempts |

**Delivery rules** (both queues; they came out of a Codex review): a drain re-reads the row *after* claiming it, so a version saved in between is the one delivered; only the newest version of a draft is ever claimable, and none while another is in flight; a failed version that a newer one superseded is deleted, not retried over it (the check and the requeue are one transaction, and a new save only ever overwrites the *newest* pending row); a draft's completion (mark sent + `draft_refs` + dropping older versions) is one transaction; a `draft_key` belongs to one account/org and is refused elsewhere; a delivered MX row is kept 10 min so its caller can read the outcome, and a caller whose draft version was superseded gets `deleted` + "superseded", not an error. An MX draft's Message-ID uses the org's primary domain, so switching From between domains doesn't fork it. A replayed MX send re-enqueues `OutboundDeliveryJob` (idempotent: it skips published destinations), closing a crash between saving the row and enqueueing delivery. IMAP replaces a draft with `UID EXPUNGE` of the old copy only (UIDPLUS); without UIDPLUS the old copy is left `\Deleted` rather than expunging the whole Drafts folder. A lost response (or a crash before the local commit) can't fork a draft either: Gmail and Graph also look the draft up by its stable Message-ID before writing — Gmail `drafts.list?q=rfc822msgid:` (update the first, delete any extras), Graph `mailFolders/drafts/messages?$filter=internetMessageId eq` (delete them all, then create from MIME, which keeps the Message-ID; every Graph draft is created from MIME for that reason).

**A draft keeps only its latest version.** `compose_draft` returns a `draft_key`; saving again with it (a) overwrites the version still waiting in the queue, if any, rather than adding one (and drops a failed one), and (b) once delivered, replaces the previous draft at the provider instead of adding a second: `draft_refs` maps `draft_key` → the provider's draft id (Gmail draft id, Graph message id; IMAP matches on the draft's stable `Message-ID` `<draft_key@domain>`; inbox2 needs no ref, the server upserts by that Message-ID). A version whose predecessor is still in flight waits (the claim refuses it), so two saves can never both create a draft. Draft rows don't appear in the UI's sends list (`list_outbox` is `kind = 'send'`).

**From** is always the account's own bare address (Graph rejects `Name <addr>`).

**inbox2-hosted orgs** (an `account_key` from `mx_sync_state`, as `list_accounts` shows them) are resolved against the local mirror (`core/src/sync/mx_mail.rs`):

| Tool | Hosted-mail path |
|---|---|
| `archive`, `trash`, `mark_read`/`mark_unread` | `SyncEngine::mx_action` — the durable MX action queue (message keys map to their threads) |
| `compose_draft` / `send_message` / `create_conversation` | `mx_compose` → `POST orgs/:org/drafts` or `POST orgs/:org/messages` (the server's undo window + E2EE sealing apply as for any client), through `mx_outbox` (below). A reply (`reply_to_message` / `in_reply_to`) sets `conversation_id` from `mx_messages` and `reply_to_message_id`, from which the API sets `In-Reply-To`/`References`. **From**: optional `from`, checked against `mx_identities` — `username@` every org domain (primary first, like the web composer) plus the member's mailboxes, all read from `mx_directory`; unset, the identity the parent was addressed to, else the primary. Request errors (unknown parent, a From the member can't use) fail before queueing |
| `add_tag` / `remove_tag` | `mx_tag`: tag by key or name from `mx_directory` `tags`; `PUT conversations/:id/tags` with `add_tag_ids`/`remove_tag_ids` — one tag, never the whole set, so a stale mirror can't undo a teammate's tag — then the response's tags are written back into the mirror |
| `move_to_folder` | `mx_move`: `inbox`/`archive`/`spam` → the action queue (`trash` refused as above); anything else is a Space by key, slug or name → `PUT conversations/:id/space`, mirrored back (`$.space`, `space_slug`) |
| `delete` | `mx_delete`: queues `trash` then `delete`. The API's bulk `delete` (added for this) destroys only threads already in trash/spam — the rule `empty` uses — so it can't purge live team mail in one call |
| `list_folders` | The status folders, then the org's Spaces and tags (`kind`: `status`/`space`/`tag`) |
| `set_priority` | Refused with an explicit error: priority is a channel-mailbox label concept |

Before this, the write tools matched no rows for an org key and reported success.

**Write-back semantics.** `archive`, `trash`, and `mark_read`/`mark_unread` do *not* mutate the provider directly. They update local state optimistically and enqueue one `writeback_actions` row per affected message; the Sync Engine drains the queue (every 5s) and applies the change to Gmail/IMAP/Microsoft, with the provider winning on conflict. Their results include a `writeback_queued` count. This is the same queue the Tauri UI uses, so an agent and the window stay consistent.

`set_priority` is the exception: priority maps to triage (quadrant) *labels*, which the write-back queue's `ActionType` set doesn't model. It updates local state and then drives the provider **synchronously** via the engine's interactive path (`perform_action("set_quadrant:…")`) — the same call the Tauri `set_priority` command makes — running it to completion on the engine's runtime from the MCP thread. The result reports `provider_synced` (and `provider_error` if the provider call failed; the local change still stands).

### Resources

| URI | Description |
|---|---|
| `inbox2://accounts` | Connected accounts list |
| `inbox2://stats` | Unread count, message count, embedding queue depth |
| `inbox2://conversations/{key}` | Full thread with all messages |
| `inbox2://messages/{key}` | Single message with full content |

### Permission model

Three tiers, enforced on every `tools/call`:

| Level | Can do | Can't do |
|---|---|---|
| `read` | Search, read messages/threads, list accounts/folders, calendar, contacts | Any mutation |
| `read_write` | Above + compose drafts, mark read, archive, tag, move, set priority | Send, delete |
| `full` | Everything, including send, create_conversation, trash and delete | — |

`tools/list` also carries each tool's MCP `annotations`, derived from the same tier (`tools::tool_annotations`, so
the two cannot drift): `read` tools are `readOnlyHint: true`; the others `readOnlyHint: false` and
`destructiveHint: true` unless they only add (compose_draft, add_tag, create_conversation, send_message). Idempotence
and open-world stay at the spec's defaults: reads may fetch from the provider, and a repeated flag still syncs. Clients that only call tools a server
marks read-only (Gluon Desktop's pull, Claude Code's read-only modes) can then read the mailbox without the person
allowing each tool by hand.

New agents auto-register at the default level from `vector_settings['mcp_permission_default']` (default: `read`).

**Auto-approve**: Privileged tools (`send_message`, `create_conversation`, `trash`, `delete`) normally require human approval. Two overrides:

- **Global**: `vector_settings['agent_auto_approve'] = 'true'` — all agents skip approval
- **Per-agent**: `agents.auto_approve = 1` — trusted agent skips approval, others still gated

The audit log records every tool call regardless of approval status.

### Agent registration & audit

On first connection, an agent is auto-registered in the `agents` table with key `agt_{nanoid}`. Subsequent connections update `last_connected_at`.

Every tool call is logged to `agent_audit_log`:

| Column | Content |
|---|---|
| `agent_key` | Which agent |
| `action_type` | Tool name (`search_messages`, `archive`, etc.) |
| `action_params` | JSON of call parameters |
| `result_summary` | First 500 chars of result |
| `status` | `success`, `denied`, or `error` |
| `duration_ms` | Wall-clock execution time |
| `created_at` | Timestamp |

## Database schema (new tables)

All tables added to `migrations/001_create_schema.sql` with `CREATE TABLE IF NOT EXISTS` — applied idempotently on app startup.

### Vector tables

| Table | Purpose | Key columns |
|---|---|---|
| `message_embeddings` | Embedding vectors | `message_key`, `chunk_index`, `embedding` (BLOB), `chunk_text_hash` |
| `embedding_queue` | Background processing queue | `message_key` (unique), `status`, `attempts` (max 3) |
| `messages_fts` | FTS5 virtual table | `subject`, `body_plain`, `from_address`, `to_address` |
| `attachment_text` | Extracted attachment text (future) | `message_key`, `filename`, `extracted_text`, `status` |
| `vector_settings` | Key-value settings | `key` (PK), `value` |

### Agent tables

| Table | Purpose | Key columns |
|---|---|---|
| `agents` | Registered MCP clients | `key`, `name`, `permission_level`, `auto_approve`, `rate_limit_rpm` |
| `agent_audit_log` | Tool call audit trail | `agent_key`, `action_type`, `action_params`, `status`, `duration_ms` |
| `agent_approvals` | Pending human-in-the-loop approvals | `agent_key`, `action_type`, `status` (pending/approved/rejected) |
| `agent_workflows` | Multi-step workflow state persistence | `agent_key`, `workflow_type`, `state` (JSON), `trigger_cron` |
| `agent_templates` | Reusable email templates | `agent_key`, `template_type`, `body_template`, `variables` (JSON) |

### Default settings

| Key | Default | Purpose |
|---|---|---|
| `embedding_enabled` | `true` | Toggle background embedding pipeline |
| `attachment_ingestion_enabled` | `false` | Enable attachment text extraction (increases storage) |
| `embedding_batch_size` | `50` | Messages per pipeline batch |
| `embedding_model` | `all-MiniLM-L6-v2` | Model identifier (stored with embeddings for version tracking) |
| `mcp_server_enabled` | `true` | Consulted at startup: the HTTP server starts only when this is `'true'`. Switched live from Settings › On-device AI › **Connect an AI agent** (`mcp_set_enabled`): on starts the server if it isn't running, off closes a gate in `mcp::http` so every request gets 503 until it's back on. |
| `mcp_permission_default` | `read` | Default permission for new agents |
| `agent_auto_approve` | `false` | Skip approval for privileged agent actions |

## Integration with existing systems

### Sync engine → embedding queue

`SyncStore::upsert_synced_message()` enqueues every new message:

```rust
if was_new {
    conn.execute(
        "INSERT OR IGNORE INTO embedding_queue (message_key, status, created_at, updated_at)
         VALUES (?1, 'pending', ?2, ?3)",
        params![message_key, now, now],
    );
}
```

### Shared AI engine

`AIInferenceEngine` is wrapped in `Arc<Mutex<>>` and shared between:
- **AIState** (Tauri commands: `ai_sentiment`, `ai_intent`, `ai_embedding`)
- **VectorState** (Tauri commands: `vector_search`, etc.)
- **EmbeddingPipeline** (background worker)

All three acquire the lock, run inference, and release. The pipeline processes batches of 50 — each embedding takes ~50–100ms, so a batch holds the lock for ~2–5 seconds.

### Startup sequence (lib.rs)

```
1.  SyncStore::new(db_path)         → open WAL connection, run schema
2.  SyncEngine::new(store)          → create sync loop
3.  spawn sync engine               → background task
4.  boot stored accounts            → connect + sync all accounts
5.  AIInferenceEngine::new()        → create (not yet warmed up)
6.  Arc<Mutex<engine>>              → share between AIState + VectorState
7.  (if mcp_server_enabled='true')
    McpServer::new(engine)          → in-core MCP, shares engine conn + queue
8.  mcp::http::spawn(server, …)     → HTTP transport on its own thread (:8765)
9.  VectorStore::new(conn)          → wrap shared DB connection
10. EmbeddingPipeline::new(50)      → create with batch size
11. spawn pipeline.run()            → background task (polls every 5s)
12. Register Tauri commands         → 6 vector commands added
```

## Performance

| Operation | Latency | Notes |
|---|---|---|
| Embed one message | 50–100ms | Single ONNX inference (Apple Silicon) |
| Embed batch of 50 | 2–5s | Sequential; pipeline runs every 5s |
| Semantic search (10K msgs) | ~20ms | Brute-force cosine similarity |
| Semantic search (200K msgs) | ~100ms | O(N) scan, upgradeable to ANN |
| FTS5 keyword search | <10ms | SQLite built-in |
| Hybrid search | ~120ms | Semantic + keyword + RRF fusion |
| MCP tool call | 1–50ms | Direct SQLite query |
| Embedding storage | ~15 MB / 10K msgs | 384-dim × f32 BLOBs |

## Future work

- **sqlite-vec ANN index** — replace brute-force scan for >100K message mailboxes
- **Attachment ingestion** — PDF/Office/text extraction behind `attachment_ingestion_enabled` toggle
- **Approval workflow UI** — Tauri modal for human-in-the-loop on privileged agent actions
- **Event notifications** — broadcast channel from sync engine → MCP notifications on new mail
- **Agent-to-agent handoff** — pipeline support (triage agent → specialist → human review)
- **RAG context builder** — MCP tool to assemble token-budgeted context from vector search + contacts + calendar
- **Scheduled workflows** — cron-based agent triggers via `agent_workflows.trigger_cron`
