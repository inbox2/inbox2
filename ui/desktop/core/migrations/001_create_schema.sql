-- Inbox2 Desktop — Local SQLite Schema
-- Mirrors the server schema for offline-first operation + external mailbox sync.

-- ═══════════════════════════════════════════════════════
-- Core tables (offline mirror of Rails API)
-- ═══════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS sync_state (
  id INTEGER PRIMARY KEY,
  organization_id TEXT NOT NULL,
  last_sync_at TEXT,
  last_cursor TEXT,
  status TEXT DEFAULT 'idle'
);

CREATE TABLE IF NOT EXISTS conversations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  organization_id TEXT NOT NULL,
  subject TEXT,
  -- Provider-native thread id (Gmail threadId / Microsoft conversationId);
  -- NULL for IMAP. Most reliable threading key when present.
  provider_thread_id TEXT,
  -- Lower-cased, prefix/tag-stripped subject used by the threading fallback
  -- so same-thread mail without headers/thread-ids still groups together.
  normalized_subject TEXT,
  from_address TEXT,
  to_address TEXT,
  status TEXT DEFAULT 'open',
  snippet TEXT,
  read INTEGER DEFAULT 0,
  has_attachment INTEGER DEFAULT 0,
  priority_urgent INTEGER DEFAULT 0,
  priority_important INTEGER DEFAULT 0,
  -- Explicitly triaged into the Eisenhower matrix. The "Later" quadrant has
  -- both priority flags false, indistinguishable from untriaged, so this marks
  -- a deliberate placement so it survives a refresh. Set whenever priority is
  -- applied, cleared when priority is cleared.
  priority_triaged INTEGER DEFAULT 0,
  -- Cached client-side AI thread summary (Tier B). ai_summary_msg_key holds the
  -- latest message key at generation time; when the thread's newest message
  -- changes, the summary is stale and regenerated. Avoids re-running the local
  -- LLM on every app launch.
  ai_summary TEXT,
  ai_summary_msg_key TEXT,
  -- Async triage + multi-level summaries (see core/src/ai_worker.rs). Computed by
  -- the TriageWorker off the sync path, not live in the Bridge. triage_label is a
  -- label slug: a built-in TriageLabel or a custom one (engine setting
  -- triage_labels). ai_summary_medium = a few lines, ai_summary_short = max 1
  -- line. ai_meta_msg_key is the newest message key at generation time for the
  -- triage+medium+short bundle; when the thread's newest message changes it's
  -- stale and re-enqueued (compare-and-set staleness guard).
  triage_label TEXT,
  -- Jev priority score, 0.0 (no attention) – 4.0 (urgent); NULL = not scored
  -- (no Jev key yet). UI: >= 3.5 Urgent chip, >= 2.5 High chip. docs/Triage.md.
  triage_priority REAL,
  ai_summary_medium TEXT,
  ai_summary_short TEXT,
  ai_meta_msg_key TEXT,
  -- Provenance: which stages ran, '+'-joined (e.g. 'rule:action',
  -- 'jev:jev-1.13.0', 'rule:action+jev:jev-1.13.0+model:openai:gpt-4o-mini' —
  -- the model: part names the summary engine), and which raw signals were
  -- present (comma-separated, e.g. 'noreply,utm,esp'), recorded even when the
  -- rules deferred to Jev. See core/src/sync/store/ai_triage.rs.
  triage_source TEXT,
  triage_signals TEXT,
  -- Space classification (gated by the space_classify_enabled
  -- engine setting). The slug of the org Space the local-channel classifier routed
  -- this thread into (Jev, docs/Triage.md).
  space_slug TEXT,
  -- 1 = the user moved this thread into space_slug by hand: re-filing (a Space
  -- list change) and the worker never overwrite it; "Re-run Jev" clears it.
  space_manual INTEGER NOT NULL DEFAULT 0,
  -- The thread's newest message key when the user set triage_label by hand
  -- (triage_source 'manual'). While it is still the newest message the worker
  -- keeps the label; a new message lets Jev/the rules re-judge it.
  label_manual_msg_key TEXT,
  -- Lore next-action fields (core/src/next_action.rs, docs/Triage.md): due date
  -- (YYYY-MM-DD), amount in minor units and its ISO 4217 currency, extracted by
  -- rules whenever the label is written; NULL when the label has none.
  next_action_due_on TEXT,
  next_action_amount_cents INTEGER,
  next_action_currency TEXT,
  -- Lore to-do title ("Pay Schiphol Privium membership invoice"), written by the
  -- summary lane with the summaries; NULL when no model ran or it gave none.
  next_action_title TEXT,
  -- Meta channels: which surface this conversation belongs to
  -- ('instagram'|'messenger'|'facebook'|'whatsapp'); NULL for email. The
  -- recipient id is the reply target (Messenger PSID / IG-scoped id / WhatsApp
  -- wa_id). cs_window_last_inbound_at is the timestamp of the customer's last
  -- inbound message, driving the WhatsApp/Meta 24h customer-service window.
  channel TEXT,
  -- Event kind for Meta conversations ('dm'|'comment'|'mention'|'postback');
  -- a Meta thread is single-kind (DMs thread separately from comments), so it
  -- lives on the conversation too — letting channel/kind sub-views filter here.
  kind TEXT,
  cs_recipient_id TEXT,
  cs_window_last_inbound_at TEXT,
  -- Meta channels: the sender's resolved profile photo (Graph User Profile API
  -- `profile_pic`), shown as the conversation/message avatar. NULL for email
  -- (Gravatar/initials handle those).
  from_avatar TEXT,
  created_at TEXT,
  updated_at TEXT,
  synced_at TEXT
);

CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  conversation_key TEXT NOT NULL,
  organization_id TEXT NOT NULL,
  from_address TEXT,
  to_address TEXT,
  cc_address TEXT,
  subject TEXT,
  body_plain TEXT,
  body_html TEXT,
  -- Space-joined filenames of this message's real (non-inline) attachments,
  -- folded into messages_fts so a search for a document name finds the mail
  -- that carried it. Populated at sync where the provider exposes filenames
  -- in the list payload (Gmail) and backfilled on open for the rest.
  attachment_names TEXT,
  -- Size in bytes of this message's LARGEST real attachment, for the
  -- `larger:5mb` / `smaller:` search filters ("has an attachment over 5MB" is
  -- exactly a max). Filled from the same payload as attachment_names, so it's
  -- NULL until that's known and 0 for a message with no attachments.
  -- ponytail: one number per message, not a local attachments table. Per-file
  -- rows only if someone needs "the file named X is over Y".
  attachment_max_size INTEGER,
  is_inbound INTEGER DEFAULT 1,
  is_draft INTEGER DEFAULT 0,
  message_id_header TEXT,
  in_reply_to TEXT,
  references_header TEXT,
  account_key TEXT,
  sentiment_label TEXT,
  sentiment_score REAL,
  intent_label TEXT,
  intent_score REAL,
  -- Meta channels: surface ('instagram'|'messenger'|'facebook'|'whatsapp';
  -- NULL for email) and the event kind ('dm'|'comment'|'mention'|'postback').
  channel TEXT,
  kind TEXT,
  -- Meta channels: outbound delivery state ('sent'|'delivered'|'read'|'failed')
  -- from status webhooks, and the latest reaction emoji on this message.
  delivery_status TEXT,
  reaction TEXT,
  -- WhatsApp media descriptors as JSON ([{id,mime,name}]) — fetched on demand
  -- via the Media API (download_attachment), since WA delivers media by id.
  meta_media TEXT,
  created_at TEXT,
  updated_at TEXT,
  synced_at TEXT,
  FOREIGN KEY (conversation_key) REFERENCES conversations(key)
);

CREATE TABLE IF NOT EXISTS tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  organization_id TEXT NOT NULL,
  name TEXT NOT NULL,
  color TEXT,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS conversation_tags (
  conversation_key TEXT NOT NULL,
  tag_key TEXT NOT NULL,
  PRIMARY KEY (conversation_key, tag_key),
  FOREIGN KEY (conversation_key) REFERENCES conversations(key),
  FOREIGN KEY (tag_key) REFERENCES tags(key)
);

CREATE TABLE IF NOT EXISTS memberships (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  organization_id TEXT NOT NULL,
  role TEXT NOT NULL,
  status TEXT NOT NULL,
  member_type TEXT DEFAULT 'human',
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  conversation_key TEXT NOT NULL,
  organization_id TEXT NOT NULL,
  body TEXT NOT NULL,
  author_key TEXT,
  created_at TEXT,
  updated_at TEXT,
  FOREIGN KEY (conversation_key) REFERENCES conversations(key)
);

-- Durable write-back for MX/org conversation actions — the inbox2-hosted
-- counterpart to writeback_actions (which covers external channels). Same
-- shape, same retry curve; the only difference is who drains it. These are
-- applied in JS against the Rails API, because that's where the org session
-- and the API client live — the Rust engine has no MX conversation client.
--
-- Replaces the old `pending_changes` table, which nothing ever read: it was
-- written on every local-first mutation as an "offline will catch up" promise
-- with no drain behind it, which is what let a failed "mark as spam" report
-- success and come back on the next poll.
--
-- Rows for one conversation are drained in insertion order, so a spam →
-- move-to-inbox sequence lands as the user performed it; no dedup needed.
CREATE TABLE IF NOT EXISTS mx_writeback_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  action TEXT NOT NULL,
  status TEXT DEFAULT 'pending',
  retry_count INTEGER DEFAULT 0,
  max_retries INTEGER DEFAULT 10,
  next_retry_at TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- ═══════════════════════════════════════════════════════
-- External mailbox sync (IMAP, Gmail, Microsoft)
-- Desktop-local only; credentials encrypted at rest.
-- ═══════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS external_accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  email_address TEXT NOT NULL,
  provider_type TEXT NOT NULL,
  host TEXT,
  port INTEGER,
  use_tls INTEGER DEFAULT 1,
  -- SMTP submission endpoint for IMAP accounts (Gmail/Microsoft send via their
  -- APIs and leave these NULL). smtp_use_tls: 1 = implicit TLS (port 465),
  -- 0 = STARTTLS (port 587).
  smtp_host TEXT,
  smtp_port INTEGER,
  smtp_use_tls INTEGER DEFAULT 1,
  auth_method TEXT DEFAULT 'plain',
  status TEXT DEFAULT 'disconnected',
  error_message TEXT,
  last_connected_at TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  avatar_url TEXT,
  -- Whether this account's credentials are mirrored to the zero-knowledge cloud
  -- vault (see docs/E2EE.md). Off by default; flipped on by the add-account toggle.
  cloud_backup_enabled INTEGER DEFAULT 0,
  -- Open tracking (docs/Open-Tracking.md): per-channel opt-in. When on, sends get
  -- a pixel injected client-side; opens are collected server-side and polled back.
  -- track_domain NULL = use the inbox2 default host (derived from the API base).
  open_tracking_enabled INTEGER DEFAULT 0,
  track_domain TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Tokens embedded in tracked outbound sends (docs/Open-Tracking.md). The poll
-- worker asks Rails for opens on these; the token also lives in the sent
-- message's body_html, which is how a message row is correlated to its opens.
CREATE TABLE IF NOT EXISTS tracked_tokens (
  token TEXT PRIMARY KEY,
  account_key TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Opens synced from the Rails tracking/opens poll, keyed by the pixel token.
-- The secret behind a pixel token: the token in the mail is its hash, so a recipient
-- who holds the token can't read opens. Device-only (decided 2026-11-09): opens
-- read back on the device that sent the mail.
CREATE TABLE IF NOT EXISTS tracked_token_secrets (
  token TEXT PRIMARY KEY,
  secret TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS message_opens (
  token TEXT NOT NULL,
  opened_at TEXT NOT NULL,
  ip TEXT,
  geo_country TEXT,
  geo_city TEXT,
  proxied INTEGER NOT NULL DEFAULT 0,
  proxy_kind TEXT,
  user_agent TEXT,
  PRIMARY KEY (token, opened_at, ip)
);
CREATE INDEX IF NOT EXISTS idx_message_opens_token ON message_opens(token);

CREATE TABLE IF NOT EXISTS external_account_credentials (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_key TEXT NOT NULL UNIQUE,
  encrypted_data BLOB NOT NULL,
  nonce BLOB NOT NULL,
  -- Cloud-vault backup bookkeeping (see docs/E2EE.md). `backup_dirty` marks the
  -- row as needing (re)upload — set on create + token refresh, cleared once the
  -- engine drains it. `backup_version` mirrors the server blob_version.
  backed_up_at TEXT,
  backup_version INTEGER DEFAULT 0,
  backup_dirty INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (account_key) REFERENCES external_accounts(key) ON DELETE CASCADE
);

-- Single-row local state for the zero-knowledge credential vault (docs/E2EE.md).
-- Caches the two wrapped DEK copies + Argon params so the device can re-unlock at
-- boot via the OS-keychain copy without re-deriving from the password. The DEK
-- itself lives only in memory after unlock — never on disk in the clear.
-- `bound_user_id` ties the vault to one inbox2 identity so a sign-out / account
-- switch can invalidate it (preventing identity A's tokens leaking into B's vault).
CREATE TABLE IF NOT EXISTS vault_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  enabled INTEGER NOT NULL DEFAULT 0,
  vault_key TEXT,
  bound_user_id TEXT,
  device_wrapped_dek BLOB,
  device_wrapped_nonce BLOB,
  passphrase_wrapped_dek BLOB,
  passphrase_wrapped_nonce BLOB,
  argon_salt BLOB,
  argon_params TEXT,
  created_at TEXT,
  updated_at TEXT
);

-- App-level secrets (Rails auth token, third-party API keys), encrypted with the
-- same device-bound AES-256-GCM key as provider credentials. Durable + shared by
-- every engine client (desktop webview, CLI, daemon) — more portable and safer than
-- the webview's plaintext localStorage. See docs/Cloud-Push.md.
CREATE TABLE IF NOT EXISTS app_secrets (
  name TEXT PRIMARY KEY,
  encrypted_data BLOB NOT NULL,
  nonce BLOB NOT NULL,
  updated_at TEXT NOT NULL
);

-- Cloud push (Gmail/Office365) provider-subscription state. Tracks only the
-- provider-side subscription metadata (never tokens) so the engine knows when to
-- renew. Rails is the source of truth for the mapping; this is the local copy used
-- for renewal timing. See docs/Cloud-Push.md.
CREATE TABLE IF NOT EXISTS push_subscription_state (
  account_key TEXT PRIMARY KEY,
  rails_key TEXT,
  provider_subscription_id TEXT,
  client_state TEXT,
  expires_at TEXT,
  registered_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (account_key) REFERENCES external_accounts(key) ON DELETE CASCADE
);

-- Meta channels: local record of webhook-relay registration, for re-report
-- (Rails 30-day lease keep-alive) and teardown. Holds no Meta secrets.
CREATE TABLE IF NOT EXISTS meta_subscription_state (
  account_key TEXT PRIMARY KEY,
  -- JSON array of the cloud relay's public ids (mcs_…) so teardown can DELETE them.
  rails_keys TEXT,
  reported_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (account_key) REFERENCES external_accounts(key) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS external_folders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  account_key TEXT NOT NULL,
  provider_name TEXT NOT NULL,
  well_known_role TEXT,
  separator TEXT,
  flags TEXT,
  uid_validity INTEGER,
  highest_mod_seq INTEGER DEFAULT 0,
  last_synced_uid INTEGER DEFAULT 0,
  -- Opaque provider sync cursor (Gmail historyId, Microsoft deltaLink); NULL for IMAP.
  sync_cursor TEXT,
  last_sync_at TEXT,
  sync_enabled INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (account_key) REFERENCES external_accounts(key) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS message_provider_state (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_key TEXT NOT NULL,
  account_key TEXT NOT NULL,
  folder_key TEXT NOT NULL,
  provider_uid INTEGER,
  provider_mod_seq INTEGER,
  provider_message_id TEXT,
  flags TEXT,
  labels TEXT,
  raw_provider_flags TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (message_key) REFERENCES messages(key),
  FOREIGN KEY (account_key) REFERENCES external_accounts(key) ON DELETE CASCADE,
  FOREIGN KEY (folder_key) REFERENCES external_folders(key) ON DELETE CASCADE,
  UNIQUE(account_key, folder_key, provider_uid)
);

CREATE TABLE IF NOT EXISTS writeback_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  account_key TEXT NOT NULL,
  action_type TEXT NOT NULL,
  message_key TEXT,
  -- The message's conversation and its cross-device tag input
  -- (SyncStore::notification_tag_id) at enqueue time: they survive the message
  -- row being pruned, for the cross-device banner clear (docs/Cloud-Push.md).
  conversation_key TEXT,
  notification_tag_id TEXT,
  folder_key TEXT,
  target_folder_key TEXT,
  payload TEXT,
  -- Provider identity (uid/mod_seq/provider_id) captured at enqueue, JSON-encoded,
  -- so the action survives the message's provider-state row being pruned mid-flight.
  provider_snapshot TEXT,
  status TEXT DEFAULT 'pending',
  retry_count INTEGER DEFAULT 0,
  max_retries INTEGER DEFAULT 10,
  next_retry_at TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (account_key) REFERENCES external_accounts(key) ON DELETE CASCADE
);

-- Durable outbox for user-composed messages sent via provider APIs
-- (Gmail/Microsoft Graph). A send is persisted here first, then delivered by
-- the engine's outbox drain with exponential-backoff retry, so a transient
-- failure (offline, 429, 5xx) is retried instead of lost. `payload` is the
-- JSON-encoded OutgoingMessage (recipients, bodies, inline attachment bytes).
CREATE TABLE IF NOT EXISTS outbox_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  account_key TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT DEFAULT 'pending',
  retry_count INTEGER DEFAULT 0,
  max_retries INTEGER DEFAULT 10,
  next_retry_at TEXT,
  provider_message_id TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  -- 'send' or 'draft' (OutboxKind). A draft row is one saved version of the
  -- draft named by draft_key; only the latest pending version is kept.
  kind TEXT NOT NULL DEFAULT 'send',
  draft_key TEXT,
  FOREIGN KEY (account_key) REFERENCES external_accounts(key) ON DELETE CASCADE
);

-- The provider's id for each queued draft (Gmail draft id, Graph message id,
-- inbox2 draft key; IMAP finds its copy by Message-ID instead), so the next
-- saved version replaces that draft rather than adding another. `target` is the
-- account or org the draft lives in.
CREATE TABLE IF NOT EXISTS draft_refs (
  draft_key TEXT PRIMARY KEY,
  target TEXT NOT NULL,
  provider_draft_id TEXT,
  updated_at TEXT NOT NULL
);

-- Durable sends and drafts for inbox2-hosted orgs: the channel outbox's
-- counterpart (outbox_messages' account FK can't hold an org). `payload` is the
-- API request body, resolved at enqueue. NOT a mirror table: the mirror reset
-- (store/mx.rs reset_if_outdated) must never drop unsent mail.
CREATE TABLE IF NOT EXISTS mx_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  org_id TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'send',
  draft_key TEXT,
  payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  retry_count INTEGER NOT NULL DEFAULT 0,
  next_retry_at TEXT,
  result_id TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mx_outbox_due ON mx_outbox(status, next_retry_at);

-- ═══════════════════════════════════════════════════════
-- Calendar sync (Google Calendar, Microsoft Calendar)
-- Desktop-local only; synced directly from provider APIs.
-- ═══════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS calendars (
  key TEXT NOT NULL UNIQUE,
  account_key TEXT NOT NULL,
  name TEXT NOT NULL,
  color TEXT DEFAULT '#3B82F6',
  source TEXT NOT NULL,                 -- google | microsoft
  provider_id TEXT,
  sync_token TEXT,
  is_primary INTEGER DEFAULT 0,
  is_visible INTEGER DEFAULT 1,
  is_writable INTEGER DEFAULT 1,        -- owner/writer access (Google accessRole / MS canEdit); read-only calendars = 0
  conference_providers TEXT,            -- comma-separated 'meet'/'teams' this calendar can mint; '' = none, NULL = not synced yet
  is_owned INTEGER DEFAULT 1,           -- the account owns it (Google accessRole owner / Graph canShare); a calendar merely shared with write access = 0
  status TEXT DEFAULT 'active',
  last_synced_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS calendar_events (
  key TEXT NOT NULL UNIQUE,
  calendar_key TEXT NOT NULL,
  account_key TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  location TEXT,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  all_day INTEGER DEFAULT 0,
  timezone TEXT DEFAULT 'UTC',
  status TEXT DEFAULT 'confirmed',
  provider_id TEXT,
  provider_etag TEXT,
  ical_uid TEXT,
  recurrence_rule TEXT,
  recurring_event_key TEXT,
  original_start_at TEXT,
  organizer_email TEXT,
  organizer_name TEXT,
  metadata TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (calendar_key) REFERENCES calendars(key)
);

CREATE TABLE IF NOT EXISTS calendar_attendees (
  key TEXT NOT NULL UNIQUE,
  event_key TEXT NOT NULL,
  email TEXT NOT NULL,
  name TEXT,
  response_status TEXT DEFAULT 'needs_action',
  is_organizer INTEGER DEFAULT 0,
  is_optional INTEGER DEFAULT 0,
  FOREIGN KEY (event_key) REFERENCES calendar_events(key)
);

-- ═══════════════════════════════════════════════════════
-- Vector search + embeddings
-- ═══════════════════════════════════════════════════════

-- Embedding metadata and vector storage (one row per chunk).
-- Vectors stored as little-endian f32 BLOBs for zero-copy cosine similarity.
CREATE TABLE IF NOT EXISTS message_embeddings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_key TEXT NOT NULL,
  chunk_index INTEGER NOT NULL DEFAULT 0,
  chunk_text_hash TEXT NOT NULL,
  embedding BLOB NOT NULL,
  model_id TEXT NOT NULL DEFAULT 'all-MiniLM-L6-v2',
  dimensions INTEGER NOT NULL DEFAULT 384,
  created_at TEXT NOT NULL,
  UNIQUE(message_key, chunk_index),
  FOREIGN KEY (message_key) REFERENCES messages(key) ON DELETE CASCADE
);

-- Queue for incremental background embedding.
CREATE TABLE IF NOT EXISTS embedding_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_key TEXT NOT NULL UNIQUE,
  status TEXT DEFAULT 'pending',
  error_message TEXT,
  attempts INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (message_key) REFERENCES messages(key) ON DELETE CASCADE
);

-- Priority work queue for async triage classification + multi-level summaries.
-- One pending job per conversation (UNIQUE = idempotency). `priority` is the
-- conversation's updated_at (RFC3339, which sorts chronologically) so the worker
-- drains newest-first. Re-enqueue of an existing conversation bumps priority and
-- resets to pending in one statement (ON CONFLICT DO UPDATE) — that is the
-- re-classification trigger when a reply lands on an old thread. Completed jobs
-- are deleted (completed = removed), mirroring the embedding_queue lifecycle.
CREATE TABLE IF NOT EXISTS ai_triage_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_key TEXT NOT NULL UNIQUE,
  priority TEXT NOT NULL,
  status TEXT DEFAULT 'pending',
  error_message TEXT,
  attempts INTEGER DEFAULT 0,
  defer_count INTEGER DEFAULT 0,        -- times deferred (model unavailable/ambiguous); cap → finalize as poison
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (conversation_key) REFERENCES conversations(key) ON DELETE CASCADE
);

-- Core-owned engine settings (key/value). Distinct from vector_settings, which is
-- owned/seeded by the desktop vector subsystem and unreachable from mobile (no
-- VectorStore there). processing_window bounds how far back mail is classified/
-- summarized so the whole backlog isn't scanned on first sync. See
-- ProcessingWindow in core/src/triage.rs.
CREATE TABLE IF NOT EXISTS engine_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR IGNORE INTO engine_settings (key, value) VALUES
  ('processing_window', '1_month');

-- FTS5 for hybrid search (keyword + semantic via reciprocal rank fusion).
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
  subject, body_plain, from_address, to_address, attachment_names,
  content=messages, content_rowid=id
);

-- Keep FTS5 in sync with messages table automatically.
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, subject, body_plain, from_address, to_address, attachment_names)
  VALUES (new.id, new.subject, new.body_plain, new.from_address, new.to_address, new.attachment_names);
END;

CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, subject, body_plain, from_address, to_address, attachment_names)
  VALUES ('delete', old.id, old.subject, old.body_plain, old.from_address, old.to_address, old.attachment_names);
END;

CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, subject, body_plain, from_address, to_address, attachment_names)
  VALUES ('delete', old.id, old.subject, old.body_plain, old.from_address, old.to_address, old.attachment_names);
  INSERT INTO messages_fts(rowid, subject, body_plain, from_address, to_address, attachment_names)
  VALUES (new.id, new.subject, new.body_plain, new.from_address, new.to_address, new.attachment_names);
END;

-- Term dictionary for search's "did you mean …?" suggestion. fts5vocab is a
-- read-only view over messages_fts's own index: no extra storage, nothing to
-- populate, and it can't drift out of sync (an fts5 rebuild is picked up
-- automatically). Columns: term, doc (documents containing it), cnt.
CREATE VIRTUAL TABLE IF NOT EXISTS messages_vocab USING fts5vocab(messages_fts, 'row');

-- Attachment text extraction (opt-in, significantly increases storage).
CREATE TABLE IF NOT EXISTS attachment_text (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_key TEXT NOT NULL,
  attachment_id TEXT NOT NULL,
  filename TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  extracted_text TEXT,
  extraction_method TEXT,
  status TEXT DEFAULT 'pending',
  created_at TEXT NOT NULL,
  UNIQUE(message_key, attachment_id),
  FOREIGN KEY (message_key) REFERENCES messages(key) ON DELETE CASCADE
);

-- Settings for the vector/agent subsystem.
CREATE TABLE IF NOT EXISTS vector_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR IGNORE INTO vector_settings (key, value) VALUES
  ('embedding_enabled', 'true'),
  ('attachment_ingestion_enabled', 'false'),
  -- Semantic-embedding history bound (own, wider than the 1-month triage window).
  -- Keyword/FTS search covers all mail regardless; this only limits which mail is
  -- embedded for vector search, so a deep archive sync doesn't embed everything.
  ('embedding_window', '1_year'),
  ('embedding_batch_size', '50'),
  ('embedding_model', 'all-MiniLM-L6-v2'),
  ('mcp_server_enabled', 'true'),
  ('mcp_permission_default', 'read'),
  ('agent_auto_approve', 'false'),
  ('agentic_filters_enabled', 'false');

-- ═══════════════════════════════════════════════════════
-- Agent system (MCP interface)
-- ═══════════════════════════════════════════════════════

-- Registered agents (MCP clients that have connected).
CREATE TABLE IF NOT EXISTS agents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  permission_level TEXT NOT NULL DEFAULT 'read',
  auto_approve INTEGER DEFAULT 0,
  default_account_key TEXT,
  is_active INTEGER DEFAULT 1,
  rate_limit_rpm INTEGER DEFAULT 60,
  last_connected_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Audit log of every agent tool call.
CREATE TABLE IF NOT EXISTS agent_audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_key TEXT NOT NULL,
  action_type TEXT NOT NULL,
  action_params TEXT,
  result_summary TEXT,
  status TEXT NOT NULL,
  error_message TEXT,
  duration_ms INTEGER,
  created_at TEXT NOT NULL
);

-- Pending approval queue (human-in-the-loop for privileged ops).
CREATE TABLE IF NOT EXISTS agent_approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  agent_key TEXT NOT NULL,
  action_type TEXT NOT NULL,
  action_params TEXT,
  status TEXT DEFAULT 'pending',
  user_note TEXT,
  expires_at TEXT,
  resolved_at TEXT,
  created_at TEXT NOT NULL
);

-- Workflow state persistence (multi-step agent workflows).
CREATE TABLE IF NOT EXISTS agent_workflows (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  agent_key TEXT NOT NULL,
  workflow_type TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT '{}',
  status TEXT DEFAULT 'running',
  current_step TEXT,
  trigger_cron TEXT,
  last_run_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Reusable email templates for agent-composed messages.
CREATE TABLE IF NOT EXISTS agent_templates (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  agent_key TEXT,
  name TEXT NOT NULL,
  template_type TEXT NOT NULL DEFAULT 'reply',
  subject_template TEXT,
  body_template TEXT NOT NULL,
  variables TEXT,
  created_at TEXT NOT NULL
);

-- ═══════════════════════════════════════════════════════
-- Agentic filters (local CLI agents — see docs/Agentic-Filters.md)
-- These are OUTBOUND processes we invoke, distinct from the inbound
-- MCP `agents` table above. Do not conflate the two.
-- ═══════════════════════════════════════════════════════

-- Locally-installed CLI agents we can invoke (one row per adapter id).
CREATE TABLE IF NOT EXISTS local_agents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  adapter_id TEXT NOT NULL UNIQUE,   -- maps to AgentAdapter::id, e.g. 'claude-code'
  display_name TEXT NOT NULL,
  binary_path TEXT,                  -- resolved path on PATH, null if not installed
  version TEXT,
  enabled INTEGER NOT NULL DEFAULT 0,
  last_detected_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Triage rules over local-channel mail (Tier 0 static + Tier 1 gate + run_agent action).
CREATE TABLE IF NOT EXISTS local_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  account_key TEXT,                  -- null = all local channels
  conditions TEXT NOT NULL,          -- JSON: [{field, op, value}]
  ai_gate TEXT,                      -- JSON: {labels|prompt, threshold} or null
  action TEXT NOT NULL,              -- JSON: {type:'run_agent', adapter_id, task, permission_mode, timeout_s}
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Durable record AND work queue for agent invocations.
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  rule_key TEXT,                     -- null for ad-hoc/test runs
  message_key TEXT NOT NULL,
  account_key TEXT NOT NULL,
  adapter_id TEXT NOT NULL,
  task TEXT NOT NULL,
  permission_mode TEXT NOT NULL,     -- 'allowlist' | 'approval_first' | 'full_auto'
  status TEXT NOT NULL DEFAULT 'pending', -- pending|awaiting_approval|running|succeeded|failed|timeout
  attempts INTEGER NOT NULL DEFAULT 0,
  timeout_s INTEGER NOT NULL DEFAULT 120, -- per-run hard timeout (seconds)
  scratch_dir TEXT,
  result_json TEXT,
  exit_code INTEGER,
  cost_usd REAL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  error TEXT,
  started_at TEXT,
  finished_at TEXT,
  duration_ms INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_agent_runs_status ON agent_runs(status);
CREATE INDEX IF NOT EXISTS idx_agent_runs_message ON agent_runs(message_key);
CREATE INDEX IF NOT EXISTS idx_local_rules_enabled ON local_rules(enabled);

-- Lore todos with no email behind them (docs/plans/lore.md §6): added by voice
-- (`add_reminder`) or the "+ Add todo" row; done = done_at set.
CREATE TABLE IF NOT EXISTS lore_todos (
  id TEXT PRIMARY KEY,               -- ltd_<nanoid>
  title TEXT NOT NULL,
  created_at TEXT NOT NULL,
  done_at TEXT,
  source TEXT NOT NULL DEFAULT 'manual' -- 'manual' | 'voice'
);

-- What Lore's "Send to…" made in another app (docs/plans/lore.md, TODO 48.12). Shown
-- as a chip on the item; the item stays open until someone ticks it.
CREATE TABLE IF NOT EXISTS lore_sent (
  id TEXT PRIMARY KEY,               -- lsn_<nanoid>
  item_key TEXT NOT NULL,            -- the Lore item's uid (mx:<id> | local:<key> | …)
  connection_name TEXT NOT NULL,
  reference TEXT,                    -- TUL-412, #88
  url TEXT,
  sent_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lore_sent_item ON lore_sent(item_key);

-- Lore ontology for local channels (docs/Ontology.md, core/src/ontology.rs): the
-- organizations, people, products and projects mined from channel mail (never
-- mx_* rows), facts with their verbatim quote, and the threads that mention them.
CREATE TABLE IF NOT EXISTS lore_entities (
  id TEXT PRIMARY KEY,               -- ent_<nanoid>
  kind TEXT NOT NULL,                -- organization | person | product | project
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,     -- people seen as senders: their address
  email_domain TEXT,
  address TEXT,
  first_seen_at TEXT,
  last_seen_at TEXT,
  mention_count INTEGER NOT NULL DEFAULT 0,
  -- Edits remembered so the miner does not undo them (docs/Ontology.md "Editing").
  removed_at TEXT,
  merged_into TEXT,
  name_locked INTEGER NOT NULL DEFAULT 0,
  UNIQUE (kind, normalized_name)
);
CREATE TABLE IF NOT EXISTS lore_facts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_id TEXT NOT NULL REFERENCES lore_entities(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,                -- attribute | relation
  name TEXT NOT NULL,                -- attribute name, or works_at | client_of | uses | about
  value TEXT,
  related_entity_id TEXT REFERENCES lore_entities(id) ON DELETE CASCADE,
  quote TEXT,                        -- verbatim from the mail; NULL for header facts
  conversation_key TEXT,
  message_key TEXT,
  confidence REAL NOT NULL DEFAULT 1.0,
  grounding REAL NOT NULL DEFAULT 1.0,
  support INTEGER NOT NULL DEFAULT 1,
  fingerprint TEXT NOT NULL,         -- identical facts collapse and gain support
  created_at TEXT NOT NULL,
  removed_at TEXT,
  UNIQUE (entity_id, fingerprint)
);
CREATE TABLE IF NOT EXISTS lore_mentions (
  entity_id TEXT NOT NULL REFERENCES lore_entities(id) ON DELETE CASCADE,
  conversation_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (entity_id, conversation_key)
);
CREATE INDEX IF NOT EXISTS idx_lore_mentions_conv ON lore_mentions(conversation_key);

-- Lore items from local WhatsApp (desktop, macOS; src-tauri/src/whatsapp_lore.rs):
-- one row per chat with an ask, judged from WhatsApp Desktop's own database
-- (read-only, never copied). The ask = the unanswered messages that need the
-- owner since their last reply. Done = a reply the model judged complete, or a
-- tick in Lore; a newer ask reopens it. Ontology rows for a chat use
-- conversation_key 'wa:<chat_id>'.
CREATE TABLE IF NOT EXISTS wa_lore (
  chat_id INTEGER PRIMARY KEY,       -- ZWACHATSESSION.Z_PK
  chat_name TEXT NOT NULL,
  is_group INTEGER NOT NULL DEFAULT 0,
  avatar TEXT,                       -- container-relative path (wamedia://)
  ask_from_id INTEGER NOT NULL,      -- first message of the ask (opens the chat there)
  ask_through_id INTEGER NOT NULL,   -- newest message of the ask that was judged
  ask_at TEXT NOT NULL,              -- when that newest message was sent
  sender TEXT,                       -- who asked (groups)
  label TEXT,
  priority REAL,
  title TEXT,
  summary TEXT,
  next_action_due_on TEXT,
  next_action_amount_cents INTEGER,
  next_action_currency TEXT,
  status TEXT NOT NULL DEFAULT 'open', -- open | done
  done_reason TEXT,                  -- reply | tick
  done_at TEXT,
  reply_checked_id INTEGER NOT NULL DEFAULT 0, -- newest own reply already judged
  ask_sig TEXT,                      -- the ask's change marker (count + Z_OPT sum): an edit or delete re-judges it
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lore_facts_related ON lore_facts(related_entity_id);
-- Local WhatsApp groups Lore tracks (desktop): Jev decides which groups are
-- business (source 'ai'); the person can flip it on the group's Lore page
-- (source 'user', never re-judged). A tracked group's to-dos — everyone's, not
-- only the owner's — live in wa_group_todos, written from the user's text lane.
CREATE TABLE IF NOT EXISTS wa_groups (
  chat_id INTEGER PRIMARY KEY,       -- ZWACHATSESSION.Z_PK
  chat_name TEXT NOT NULL,
  avatar TEXT,
  business INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'ai', -- ai | user
  todo_through_id INTEGER NOT NULL DEFAULT 0, -- newest message read into the to-do list
  ignored INTEGER NOT NULL DEFAULT 0, -- the person keeps this group out of Lore entirely (never read)
  judged_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS wa_group_todos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  summary TEXT,
  owner TEXT,                        -- who has to do it ('You' = the owner)
  mine INTEGER NOT NULL DEFAULT 0,
  from_id INTEGER NOT NULL,          -- the message that raised it (opens the chat there)
  at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open', -- open | done
  done_reason TEXT,                  -- chat (the chat shows it done) | tick
  done_at TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_wa_group_todos_chat ON wa_group_todos(chat_id, status);
-- A tracked group's day summary (text lane), written when the person opens that
-- day on the group's Lore page; rewritten only once newer messages of the day exist.
CREATE TABLE IF NOT EXISTS wa_group_summaries (
  chat_id INTEGER NOT NULL,
  day TEXT NOT NULL,                 -- the person's local date, YYYY-MM-DD
  through_id INTEGER NOT NULL,       -- newest message the summary covers
  messages INTEGER NOT NULL,
  summary TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (chat_id, day)
);

-- ═══════════════════════════════════════════════════════
-- Indexes
-- ═══════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_conversations_org ON conversations(organization_id);
-- Inbox list orders by updated_at DESC within an org/account and LIMITs 200.
-- This composite lets SQLite walk in updated_at order and stop early instead of
-- sorting every conversation in the account (the dominant read-path cost once
-- archive sync grew the message/folder-state tables).
CREATE INDEX IF NOT EXISTS idx_conversations_org_updated ON conversations(organization_id, updated_at);
-- Bare updated_at: triage_progress counts the processing window without an org
-- filter, which the composite index above can't serve.
CREATE INDEX IF NOT EXISTS idx_conversations_updated ON conversations(updated_at);
CREATE INDEX IF NOT EXISTS idx_conversations_status ON conversations(status);
CREATE INDEX IF NOT EXISTS idx_conversations_provider_thread ON conversations(organization_id, provider_thread_id);
CREATE INDEX IF NOT EXISTS idx_conversations_normalized_subject ON conversations(organization_id, normalized_subject);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_key);
CREATE INDEX IF NOT EXISTS idx_messages_account ON messages(account_key);
CREATE INDEX IF NOT EXISTS idx_messages_message_id ON messages(message_id_header);
CREATE INDEX IF NOT EXISTS idx_mx_writeback_pending ON mx_writeback_actions(status, next_retry_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_external_accounts_status ON external_accounts(status);
CREATE INDEX IF NOT EXISTS idx_external_folders_account ON external_folders(account_key);
CREATE INDEX IF NOT EXISTS idx_external_folders_role ON external_folders(account_key, well_known_role);
CREATE INDEX IF NOT EXISTS idx_msg_provider_state_message ON message_provider_state(message_key);
CREATE INDEX IF NOT EXISTS idx_msg_provider_state_acct_folder ON message_provider_state(account_key, folder_key);
CREATE INDEX IF NOT EXISTS idx_msg_provider_state_provider_mid ON message_provider_state(provider_message_id);
CREATE INDEX IF NOT EXISTS idx_msg_provider_state_uid ON message_provider_state(account_key, folder_key, provider_uid);
CREATE INDEX IF NOT EXISTS idx_msg_provider_state_gmail_mid ON message_provider_state(account_key, folder_key, provider_message_id) WHERE provider_uid IS NULL;
CREATE INDEX IF NOT EXISTS idx_writeback_pending ON writeback_actions(status, next_retry_at) WHERE status IN ('pending', 'in_progress');
CREATE INDEX IF NOT EXISTS idx_writeback_account ON writeback_actions(account_key);
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox_messages(status, next_retry_at) WHERE status IN ('pending', 'sending');
CREATE INDEX IF NOT EXISTS idx_outbox_account ON outbox_messages(account_key);
CREATE INDEX IF NOT EXISTS idx_cal_account ON calendars(account_key);
CREATE INDEX IF NOT EXISTS idx_cal_events_calendar ON calendar_events(calendar_key);
CREATE INDEX IF NOT EXISTS idx_cal_events_range ON calendar_events(start_at, end_at);
CREATE INDEX IF NOT EXISTS idx_cal_events_provider ON calendar_events(provider_id);
CREATE INDEX IF NOT EXISTS idx_cal_events_ical ON calendar_events(ical_uid);
CREATE INDEX IF NOT EXISTS idx_cal_events_account ON calendar_events(account_key);
CREATE INDEX IF NOT EXISTS idx_cal_attendees_event ON calendar_attendees(event_key);

-- Vector / embedding indexes
CREATE INDEX IF NOT EXISTS idx_embeddings_message ON message_embeddings(message_key);
CREATE INDEX IF NOT EXISTS idx_embedding_queue_status ON embedding_queue(status) WHERE status IN ('pending', 'failed');
-- Drain the triage queue newest-first; partial index keeps it tight. Includes
-- 'processing' so the stale-reclaim branch of claim_next_triage_job is covered.
CREATE INDEX IF NOT EXISTS idx_ai_triage_queue_priority ON ai_triage_queue(status, priority DESC) WHERE status IN ('pending', 'failed', 'processing');

-- Agent indexes
CREATE INDEX IF NOT EXISTS idx_audit_agent ON agent_audit_log(agent_key);
CREATE INDEX IF NOT EXISTS idx_audit_created ON agent_audit_log(created_at);
CREATE INDEX IF NOT EXISTS idx_approvals_pending ON agent_approvals(status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_workflows_agent ON agent_workflows(agent_key);
CREATE INDEX IF NOT EXISTS idx_workflows_status ON agent_workflows(status) WHERE status = 'running';

-- Bridge daily-brief announce tracking. Remembers, per triage category, the last
-- set of conversations we announced (a signature of their keys) and when — so the
-- brief only re-announces an unchanged urgent/important category in the morning.
CREATE TABLE IF NOT EXISTS bridge_announce (
  category     TEXT PRIMARY KEY,   -- 'urgent' | 'important'
  signature    TEXT NOT NULL,
  announced_at TEXT
);

-- ═══════════════════════════════════════════════════════
-- MX mirror (docs/MX-Sync.md) — inbox2-hosted mail, synced from the Rails API.
--
-- Deliberately NOT the `conversations`/`messages` tables above. ~400 statements
-- across the core, Tauri, web, iOS, Android and the CLI read those assuming every
-- row is channel mail: the triage worker would re-judge mail the server already
-- triaged, local rules would double-fire, unread badges would double-count. With
-- separate tables nothing sees MX mail unless it asks to — the safe default — and
-- a consumer that should (search, MCP, Bridge) opts in on purpose.
--
-- `payload` is the API's serialized record, verbatim: read paths hand it back
-- as-is, so this schema cannot drift from the serializers. The real columns exist
-- only for listing, filtering and ordering.
--
-- THE MIRROR IS A CACHE. These tables are never ALTERed: change them here, bump
-- MX_SCHEMA_VERSION in store/mod.rs, and an older database drops and re-syncs
-- them. (`mx_writeback_actions`, further up, is user intent — not part of this.)
-- ═══════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS mx_conversations (
  key TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL,
  domain_key TEXT,
  status TEXT,
  read INTEGER NOT NULL DEFAULT 0,
  subject TEXT,
  from_address TEXT,
  to_address TEXT,
  snippet TEXT,
  space_slug TEXT,
  triage_label TEXT,
  triage_priority REAL,
  created_at TEXT,
  updated_at TEXT,
  -- The server's thread version (bumped by any change to the thread or its
  -- children). Never apply a record older than the one held.
  change_seq INTEGER NOT NULL DEFAULT 0,
  -- 1 once the thread's full message/note set has been fetched (backfill or
  -- hydrate). A row that arrived alone in a delta — a thread newly shared with
  -- this member — is 0 until hydrated.
  hydrated INTEGER NOT NULL DEFAULT 0,
  -- When this device last applied the row (local clock). Reconcile only removes
  -- rows applied before its key listing began — a thread that arrived while the
  -- listing was being fetched isn't in it, and isn't gone either.
  applied_at TEXT NOT NULL DEFAULT '',
  payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mx_conv_list ON mx_conversations(organization_id, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_mx_conv_domain ON mx_conversations(organization_id, domain_key, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_mx_conv_unhydrated ON mx_conversations(organization_id) WHERE hydrated = 0;

CREATE TABLE IF NOT EXISTS mx_messages (
  id INTEGER PRIMARY KEY,   -- a stable rowid for mx_messages_fts (a TEXT key's implicit rowid is not)
  key TEXT NOT NULL UNIQUE,
  conversation_key TEXT NOT NULL REFERENCES mx_conversations(key) ON DELETE CASCADE,
  organization_id TEXT NOT NULL,
  is_draft INTEGER NOT NULL DEFAULT 0,
  -- E2EE: the payload carries the ciphertext bundle, not plaintext. Sealed rows
  -- never go to a cloud AI lane (docs/MX-Sync.md "Sealed mail").
  sealed INTEGER NOT NULL DEFAULT 0,
  -- A sealed message, opened on this device: {"header": {...}, "body": {...}}.
  -- `payload` keeps the ciphertext bundle verbatim (so API-shaped reads are
  -- unchanged); this is what local search / MCP / Bridge read. NULL until a
  -- domain key is held. Decision D4: plaintext at rest, like channel mail.
  plain TEXT,
  -- What local search indexes: subject, people and body text (HTML stripped).
  -- NULL for a sealed message until it is opened.
  search_text TEXT,
  created_at TEXT,
  change_seq INTEGER NOT NULL DEFAULT 0,
  payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mx_msg_thread ON mx_messages(conversation_key, created_at);
CREATE INDEX IF NOT EXISTS idx_mx_msg_unopened ON mx_messages(organization_id) WHERE sealed = 1 AND plain IS NULL;

-- Local full-text search over the mirror — works offline, and covers sealed mail
-- once opened (which the server can never index).
CREATE VIRTUAL TABLE IF NOT EXISTS mx_messages_fts USING fts5(search_text, content=mx_messages, content_rowid=id);
CREATE TRIGGER IF NOT EXISTS mx_messages_fts_ai AFTER INSERT ON mx_messages BEGIN
  INSERT INTO mx_messages_fts(rowid, search_text) VALUES (new.id, new.search_text);
END;
CREATE TRIGGER IF NOT EXISTS mx_messages_fts_ad AFTER DELETE ON mx_messages BEGIN
  INSERT INTO mx_messages_fts(mx_messages_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
END;
CREATE TRIGGER IF NOT EXISTS mx_messages_fts_au AFTER UPDATE OF search_text ON mx_messages BEGIN
  INSERT INTO mx_messages_fts(mx_messages_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
  INSERT INTO mx_messages_fts(rowid, search_text) VALUES (new.id, new.search_text);
END;

CREATE TABLE IF NOT EXISTS mx_notes (
  key TEXT PRIMARY KEY,
  conversation_key TEXT NOT NULL REFERENCES mx_conversations(key) ON DELETE CASCADE,
  organization_id TEXT NOT NULL,
  created_at TEXT,
  change_seq INTEGER NOT NULL DEFAULT 0,
  payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mx_note_thread ON mx_notes(conversation_key, created_at);

-- Everything around the mail: domains, mailboxes, members, tags, spaces, triage
-- labels, views, the org itself. Small, re-listed whole from the index endpoints.
CREATE TABLE IF NOT EXISTS mx_directory (
  organization_id TEXT NOT NULL,
  type TEXT NOT NULL,
  key TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0,  -- the server's list order
  payload TEXT NOT NULL,
  PRIMARY KEY (organization_id, type, key)
);

CREATE TABLE IF NOT EXISTS mx_sync_state (
  organization_id TEXT PRIMARY KEY,
  -- Whose view of the org this is. Visibility is per member, so a different
  -- user on the same device starts from an empty mirror.
  user_key TEXT NOT NULL,
  cursor TEXT,
  backfill_token TEXT,
  backfill_done INTEGER NOT NULL DEFAULT 0,
  reconciled_at TEXT,
  directory_at TEXT
);

-- ═══════════════════════════════════════════════════════
-- What local AI agents may read (the MCP server's read tools).
--
-- Channel mail plus the MX mirror, in one shape — and the ONE place the sealed-mail
-- rule is enforced for agents: an MCP client can be a cloud model, so a sealed
-- (E2EE) message is never in these views, opened or not, and neither is any thread
-- that contains one (its subject line came out of a sealed header). Anything that
-- hands mail to an agent reads these, never `mx_*` directly. docs/MX-Sync.md.
--
-- Dropped and recreated each boot so a changed definition takes effect. (They use
-- json_extract: the engine's bundled SQLite has it; the Android system SQLite the
-- Kotlin UI reads with does not, and never queries these.)
-- ═══════════════════════════════════════════════════════
DROP VIEW IF EXISTS agent_conversations;
CREATE VIEW agent_conversations AS
  SELECT key, subject, from_address, to_address, status, snippet, read,
         priority_urgent, priority_important, created_at, updated_at, organization_id
    FROM conversations
  UNION ALL
  SELECT c.key, c.subject, c.from_address, c.to_address, c.status, c.snippet, c.read,
         0, 0, c.created_at, c.updated_at, c.organization_id
    FROM mx_conversations c
   WHERE NOT EXISTS (SELECT 1 FROM mx_messages s WHERE s.conversation_key = c.key AND s.sealed = 1);

DROP VIEW IF EXISTS agent_messages;
CREATE VIEW agent_messages AS
  SELECT key, conversation_key, from_address, to_address, cc_address, subject, body_plain, body_html,
         is_inbound, is_draft, message_id_header, created_at, account_key
    FROM messages
  UNION ALL
  SELECT m.key, m.conversation_key,
         json_extract(m.payload, '$.from_address'), json_extract(m.payload, '$.to_address'),
         json_extract(m.payload, '$.cc_address'), json_extract(m.payload, '$.subject'),
         -- HTML-only mail has no plain part; the indexed text is the readable version.
         COALESCE(NULLIF(json_extract(m.payload, '$.body_plain'), ''), m.search_text),
         json_extract(m.payload, '$.body_html'),
         COALESCE(json_extract(m.payload, '$.is_inbound'), 1), m.is_draft,
         json_extract(m.payload, '$.message_id'), m.created_at, m.organization_id
    FROM mx_messages m
   -- The thread rule, not just the row rule: `read_message` looks a key up here
   -- directly, so an unsealed reply in a sealed thread must be absent too.
   WHERE m.sealed = 0
     AND NOT EXISTS (SELECT 1 FROM mx_messages s WHERE s.conversation_key = m.conversation_key AND s.sealed = 1);
