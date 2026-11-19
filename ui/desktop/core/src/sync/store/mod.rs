use chrono::Utc;
use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::sync::Arc;

use crate::sync::crypto::CredentialEncryptor;
use crate::sync::error::{Result, SyncError};
use crate::sync::interactive::OutgoingMessage;
use crate::sync::model::*;

/// How long a `sending` outbox row may sit before it's treated as abandoned
/// (process crashed mid-send) and made eligible for a reclaim.
const STALE_SENDING_SECS: i64 = 120;

/// How long a *completed* write-back action is retained before cleanup reaps
/// it. During this window the sync-vs-writeback guard treats the action as
/// still settling, blocking the status/read mirror until the provider's flags
/// agree with the action's intent — closing the race where a pre-mutation sync
/// snapshot lands just after the write-back completes and resurrects the
/// thread. Comfortably outlasts an in-flight incremental sync (60s poll).
const WRITEBACK_SETTLE_GRACE_SECS: i64 = 180;
use crate::sync::{deletion, threading};

/// Thread-safe SQLite store for external sync state.
///
/// Opens a SEPARATE rusqlite connection to the same inbox2.db that the Tauri
/// SQL plugin uses. WAL mode allows concurrent reads from both connections.
pub struct SyncStore {
    conn: Arc<Mutex<Connection>>,
    encryptor: CredentialEncryptor,
    app_data_dir: std::path::PathBuf,
}

/// Result of upserting a synced message.
pub struct MessageUpsert {
    /// Conversation the message belongs to (for fine-grained refresh alerts).
    pub conversation_key: String,
    /// The message row's key (existing or freshly generated). Used by the Meta
    /// path to stamp the `channel`/`kind` columns after upsert.
    pub message_key: String,
    /// True if the message was newly inserted (vs a flag/label update).
    pub was_new: bool,
}


mod accounts;
mod ai_triage;
mod lore_triage;
mod calendar;
mod folders;
mod messages;
mod meta;
pub mod mx;
mod queue;
mod lore;
mod rules;
mod secrets;
pub mod tracking;
mod vault;

pub use ai_triage::{EvalSeedMessage, TriageInput, TriageMeta, TriageProgress};
pub use lore_triage::{LoreAutoSettings, LoreRetriage, LORE_RETRIAGE_MARKER};
pub use lore::{LoreTodo, LORE_SOURCE_MANUAL, LORE_SOURCE_VOICE};

impl SyncStore {
    pub fn new(db_path: &Path, app_data_dir: &Path) -> Result<Self> {
        // Ensure the app data directory exists before opening the database
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| SyncError::Other(format!("create db dir: {e}")))?;
        }
        // Decided before the open creates the file: the credential encryptor treats a
        // store without a database as fresh (Linux keyring fallback, crypto.rs).
        let fresh_store = !db_path.exists();
        let conn = Connection::open(db_path)?;
        // WAL allows concurrent readers + one writer across processes. busy_timeout
        // makes a contended write (e.g. two app instances both running schema
        // setup at startup) WAIT instead of immediately erroring with
        // SQLITE_BUSY — without it, startup contention used to fail the open and
        // trigger a throwaway-DB fallback (a data-diverging split-brain).
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; \
             PRAGMA foreign_keys=ON; \
             PRAGMA busy_timeout=5000; \
             PRAGMA synchronous=NORMAL; \
             PRAGMA wal_autocheckpoint=512; \
             PRAGMA journal_size_limit=8388608;",
        )?;
        // The MX mirror is a cache (docs/MX-Sync.md): when its table shapes change it
        // is dropped and re-synced rather than migrated. Must run before the schema
        // batch, whose indexes and triggers name the new columns.
        mx::reset_if_outdated(&conn)?;
        // Ensure schema exists — idempotent thanks to IF NOT EXISTS
        conn.execute_batch(include_str!("../../../migrations/001_create_schema.sql"))?;
        mx::stamp_schema_version(&conn)?;
        // Upgrade pre-existing dev databases: CREATE TABLE IF NOT EXISTS won't add
        // a column to an already-present table, so add it explicitly. The error
        // when the column already exists is expected and ignored.
        let _ = conn.execute("ALTER TABLE external_folders ADD COLUMN sync_cursor TEXT", []);
        // Local WhatsApp Lore (whatsapp_lore.rs): re-judge an ask that was edited or deleted.
        let _ = conn.execute("ALTER TABLE wa_lore ADD COLUMN ask_sig TEXT", []);
        let _ = conn.execute("ALTER TABLE wa_groups ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0", []);
        let _ = conn.execute("ALTER TABLE lore_entities ADD COLUMN removed_at TEXT", []);
        let _ = conn.execute("ALTER TABLE lore_entities ADD COLUMN merged_into TEXT", []);
        let _ = conn.execute("ALTER TABLE lore_entities ADD COLUMN name_locked INTEGER NOT NULL DEFAULT 0", []);
        let _ = conn.execute("ALTER TABLE lore_facts ADD COLUMN removed_at TEXT", []);
        // Queued drafts share the outbox with sends (see OutboxKind).
        let _ = conn.execute("ALTER TABLE outbox_messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'send'", []);
        let _ = conn.execute("ALTER TABLE outbox_messages ADD COLUMN draft_key TEXT", []);
        // `pending_changes` was written on every local-first mutation as an
        // "offline will catch up" queue that nothing ever drained — its rows
        // just accumulated (weeks of them, all synced=0) while the failures
        // they recorded were reported to the UI as successes. Replaced by
        // mx_writeback_actions (created by the schema batch above), which is
        // actually drained. Drop it rather than leave a table that lies.
        // Its rows are NOT migrated: they are stale by up to weeks and would
        // replay actions onto threads whose state has since moved on.
        let _ = conn.execute("DROP TABLE IF EXISTS pending_changes", []);
        // Provider identity captured at write-back enqueue (JSON), so a queued action
        // survives the message's provider-state row being pruned by a racing sync.
        let _ = conn.execute(
            "ALTER TABLE writeback_actions ADD COLUMN provider_snapshot TEXT",
            [],
        );
        // SMTP submission config for IMAP-account sends (added with the IMAP
        // interactive provider). Same idempotent-ALTER upgrade for existing DBs.
        // Open tracking per-channel opt-in (docs/Open-Tracking.md) — idempotent
        // ALTER for pre-existing DBs (new tracked_tokens/message_opens tables come
        // from the schema batch above).
        let _ = conn.execute(
            "ALTER TABLE external_accounts ADD COLUMN open_tracking_enabled INTEGER DEFAULT 0",
            [],
        );
        let _ = conn.execute("ALTER TABLE external_accounts ADD COLUMN track_domain TEXT", []);
        let _ = conn.execute("ALTER TABLE external_accounts ADD COLUMN smtp_host TEXT", []);
        let _ = conn.execute("ALTER TABLE external_accounts ADD COLUMN smtp_port INTEGER", []);
        let _ = conn.execute(
            "ALTER TABLE external_accounts ADD COLUMN smtp_use_tls INTEGER DEFAULT 1",
            [],
        );
        // Async triage + multi-level summary columns (added with the TriageWorker).
        // CREATE TABLE IF NOT EXISTS won't add columns to a pre-existing
        // conversations table, so add them explicitly; the error when they already
        // exist is expected and ignored. (The new ai_triage_queue / engine_settings
        // tables are created by the schema batch above.)
        // Explicit Eisenhower-matrix triage marker (so the "Later" quadrant,
        // which has no priority flags, survives a refresh).
        let _ = conn.execute(
            "ALTER TABLE conversations ADD COLUMN priority_triaged INTEGER DEFAULT 0",
            [],
        );
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN triage_label TEXT", []);
        // Jev priority score (docs/Triage.md).
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN triage_priority REAL", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN ai_summary_medium TEXT", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN ai_summary_short TEXT", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN ai_meta_msg_key TEXT", []);
        // Triage provenance (added with the heuristic-tuning telemetry).
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN triage_source TEXT", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN triage_signals TEXT", []);
        // Space classification (Jev; docs/Triage.md).
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN space_slug TEXT", []);
        // Manual triage (docs/Triage.md): a hand-placed Space / hand-set label sticks.
        let _ = conn.execute(
            "ALTER TABLE conversations ADD COLUMN space_manual INTEGER NOT NULL DEFAULT 0",
            [],
        );
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN label_manual_msg_key TEXT", []);
        // Lore next-action fields (docs/Triage.md "Next-action fields").
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN next_action_due_on TEXT", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN next_action_amount_cents INTEGER", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN next_action_currency TEXT", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN next_action_title TEXT", []);
        // Meta channels (Instagram/Messenger/WhatsApp): channel discriminator,
        // reply-target id, and the 24h customer-service window anchor. Same
        // idempotent-ALTER upgrade for existing DBs.
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN channel TEXT", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN kind TEXT", []);
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN cs_recipient_id TEXT", []);
        let _ = conn.execute(
            "ALTER TABLE conversations ADD COLUMN cs_window_last_inbound_at TEXT",
            [],
        );
        // Meta sender profile photo (Graph User Profile API profile_pic).
        let _ = conn.execute("ALTER TABLE conversations ADD COLUMN from_avatar TEXT", []);
        // Meta delivery state + reaction emoji (from webhook status/reaction events).
        let _ = conn.execute("ALTER TABLE messages ADD COLUMN delivery_status TEXT", []);
        let _ = conn.execute("ALTER TABLE messages ADD COLUMN reaction TEXT", []);
        // WhatsApp media descriptors (JSON), fetched on demand via the Media API.
        let _ = conn.execute("ALTER TABLE messages ADD COLUMN meta_media TEXT", []);
        let _ = conn.execute("ALTER TABLE messages ADD COLUMN channel TEXT", []);
        let _ = conn.execute("ALTER TABLE messages ADD COLUMN kind TEXT", []);
        // Per-calendar writability (Google accessRole owner/writer, Microsoft canEdit).
        // Defaults to 1 so existing rows stay actionable until the next calendar list
        // sync sets read-only calendars to 0 (gates event Edit/Delete in the clients).
        let _ = conn.execute("ALTER TABLE calendars ADD COLUMN is_writable INTEGER DEFAULT 1", []);
        // Video meetings the calendar's provider can mint for it (Google
        // conferenceProperties / Graph allowedOnlineMeetingProviders), comma-separated.
        // NULL until the next calendar-list sync, which the clients read as "unknown"
        // and fall back to guessing from the provider.
        let _ = conn.execute("ALTER TABLE calendars ADD COLUMN conference_providers TEXT", []);
        // Does this account OWN the calendar, or was it merely given write access to
        // someone else's (a transferred/shared calendar)? Defaults to 1 so existing
        // rows stay pickable until the next calendar-list sync answers properly.
        let _ = conn.execute("ALTER TABLE calendars ADD COLUMN is_owned INTEGER DEFAULT 1", []);
        // Triage defer counter: caps defer→reactivate loops so a thread that always
        // reports the model "unavailable" is finalized as poison instead of wedging the
        // "Catching up" bar forever.
        let _ = conn.execute("ALTER TABLE ai_triage_queue ADD COLUMN defer_count INTEGER DEFAULT 0", []);
        // Attachment filename search: persist a per-message space-joined list of
        // attachment filenames and fold it into the FTS index so a search for a
        // document name surfaces the mail that carried it. Two upgrade steps for
        // pre-existing dev DBs: (1) add the message column; (2) messages_fts is an
        // external-content FTS5 table with a fixed column list, so a new column
        // means dropping and recreating it + its triggers, then rebuilding from
        // the content table. Guard the rebuild on the column's absence so it runs
        // exactly once (fresh DBs already get the 5-column table from the batch
        // above and skip it).
        let _ = conn.execute("ALTER TABLE messages ADD COLUMN attachment_names TEXT", []);
        // Largest-attachment size (the `larger:`/`smaller:` search filters). Not
        // in the FTS table — it's a numeric comparison in the WHERE clause, so no
        // index rebuild is needed here.
        let _ = conn.execute(
            "ALTER TABLE messages ADD COLUMN attachment_max_size INTEGER",
            [],
        );
        // A meeting the summary lane read out of the body (docs/Meeting-Invites.md
        // "Detected meetings"): JSON `{title,start,end,location}`, floating wall clock.
        let _ = conn.execute("ALTER TABLE messages ADD COLUMN detected_meeting TEXT", []);
        if !table_has_column(&conn, "messages_fts", "attachment_names") {
            conn.execute_batch(
                "DROP TRIGGER IF EXISTS messages_ai;
                 DROP TRIGGER IF EXISTS messages_ad;
                 DROP TRIGGER IF EXISTS messages_au;
                 DROP TABLE IF EXISTS messages_fts;",
            )?;
            // Re-run the schema batch: its CREATE ... IF NOT EXISTS statements now
            // see the FTS objects missing and recreate them at the current
            // definition (with attachment_names); everything else is a no-op.
            conn.execute_batch(include_str!("../../../migrations/001_create_schema.sql"))?;
            conn.execute_batch("INSERT INTO messages_fts(messages_fts) VALUES('rebuild');")?;
        }
        // Widen the triage-queue partial index to also cover the stale-`processing`
        // reclaim branch of claim_next_triage_job (was pending/failed only). Drop +
        // recreate so existing DBs pick up the new predicate; CREATE IF NOT EXISTS
        // alone wouldn't replace an index that already exists with the old WHERE.
        // Gated on the stored index SQL: an unconditional drop+create here rebuilt
        // the index — O(queue rows) — on EVERY cold start (see the ⚠️ below).
        let index_is_current: bool = conn
            .query_row(
                "SELECT instr(sql, '''processing''') > 0 FROM sqlite_master \
                 WHERE type = 'index' AND name = 'idx_ai_triage_queue_priority'",
                [],
                |row| row.get(0),
            )
            .unwrap_or(false);
        if !index_is_current {
            let _ = conn.execute("DROP INDEX IF EXISTS idx_ai_triage_queue_priority", []);
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_ai_triage_queue_priority \
                 ON ai_triage_queue(status, priority DESC) \
                 WHERE status IN ('pending', 'failed', 'processing')",
                [],
            );
        }
        // Cloud credential-vault columns (see docs/E2EE.md). Idempotent ALTERs for
        // pre-existing dev DBs; fresh DBs already have them from the schema batch.
        // The vault_state table itself is created by the schema batch (IF NOT EXISTS).
        let _ = conn.execute(
            "ALTER TABLE external_accounts ADD COLUMN cloud_backup_enabled INTEGER DEFAULT 0",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE external_account_credentials ADD COLUMN backed_up_at TEXT",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE external_account_credentials ADD COLUMN backup_version INTEGER DEFAULT 0",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE external_account_credentials ADD COLUMN backup_dirty INTEGER DEFAULT 0",
            [],
        );
        let encryptor = CredentialEncryptor::for_store(app_data_dir, fresh_store)?;
        let store = Self {
            conn: Arc::new(Mutex::new(conn)),
            encryptor,
            app_data_dir: app_data_dir.to_path_buf(),
        };
        // One-time data backfills for DBs written by older code, gated behind a
        // persisted marker. Their "is it clean?" detection is a FULL-TABLE SCAN
        // (O(conversations): scrub loads + sanitizes every snippet; realign joins
        // the newest message per conversation), and `SyncStore::new` runs
        // SYNCHRONOUSLY on the app's main thread at launch (iOS: EngineModel.init
        // → InboxEngine::new). Running them every launch is a recurring cold-start
        // regression — "idempotent when clean" is NOT "cheap when clean". The
        // marker makes them run at most once, then O(1) on every later launch.
        //
        // ⚠️ Any NEW "runs-at-open" backfill/rebuild MUST be marker-gated the same
        // way (or gated on a cheap column/flag), or it re-slows every cold start.
        // Bump the marker suffix to force a one-time re-run after a data fix.
        const BACKFILL_MARKER: &str = "backfill_snippet_and_preview_v1";
        if store.get_engine_setting(BACKFILL_MARKER)?.is_none() {
            // Rebuild previews stored before the snippet sanitizer existed (leaked
            // CSS, invisible preheader padding).
            match store.scrub_dirty_snippets() {
                Ok(n) if n > 0 => log::info!("[store] rebuilt {n} dirty conversation snippets"),
                Err(e) => log::warn!("[store] snippet scrub failed: {e}"),
                _ => {}
            }
            // Realign conversation previews (sender + snippet) to each thread's
            // newest message for rows synced before the sync path refreshed them on
            // every new message.
            match store.realign_conversation_previews() {
                Ok(n) if n > 0 => log::info!("[store] realigned {n} stale conversation previews"),
                Err(e) => log::warn!("[store] preview realign failed: {e}"),
                _ => {}
            }
            // Mark done even if a step logged an error above: these are best-effort
            // cosmetic backfills, and re-scanning the whole table every launch to
            // retry them is the very slowness this guard exists to prevent.
            let _ = store.set_engine_setting(BACKFILL_MARKER, "1");
        }
        Ok(store)
    }

    /// Expose the shared connection for the vector subsystem.
    /// Both the sync engine and vector pipeline share a single WAL-mode connection.
    pub fn connection(&self) -> Arc<Mutex<Connection>> {
        self.conn.clone()
    }

    /// Checkpoint the WAL so the UI's separate read connection isn't scanning a
    /// perpetually-growing WAL (which made inbox reads take 2-4s instead of ms).
    ///
    /// PASSIVE, deliberately: a TRUNCATE/RESTART checkpoint takes an exclusive
    /// lock in its final phase, which blocks concurrent UI readers (busy_timeout
    /// up to 5s) — that traded a big-WAL stall for an intermittent checkpoint
    /// stall. PASSIVE never blocks readers or writers; it reclaims whatever
    /// frames no reader currently pins. Run frequently (every drain tick) it
    /// keeps the WAL bounded without ever stalling a read. `journal_size_limit`
    /// (set at open) caps the physical file so it doesn't stay large.
    /// Returns the WAL frame count still pending (for logging).
    pub fn checkpoint_wal(&self) -> Result<i64> {
        let conn = self.conn.lock();
        // wal_checkpoint(PASSIVE) returns (busy, log_frames, checkpointed_frames).
        let (_busy, log_frames): (i64, i64) = conn.query_row(
            "PRAGMA wal_checkpoint(PASSIVE)",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        Ok(log_frames)
    }

    pub fn generate_key(prefix: &str) -> String {
        format!("{}_{}", prefix, nanoid::nanoid!(21))
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Whether `table` already has `column`. Used to run the one-time messages_fts
/// rebuild exactly once when folding in the attachment_names column. Works for
/// FTS5 virtual tables too (PRAGMA table_info lists their user columns).
/// Returns false on any error so a probe failure never blocks the rebuild.
impl SyncStore {
    /// Conversation keys with a message matching an FTS5 `MATCH` expression, newest
    /// message first. For clients whose own SQLite lacks FTS5 (Android's platform
    /// library): they run the MATCH here — the core bundles SQLite with FTS5 — and
    /// finish the row read on their side.
    pub fn fts_conversation_keys(&self, match_expr: &str, limit: usize) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT m.conversation_key FROM messages_fts f
             JOIN messages m ON m.rowid = f.rowid
             WHERE messages_fts MATCH ?1
             GROUP BY m.conversation_key
             ORDER BY MAX(m.created_at) DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![match_expr, limit as i64], |r| r.get::<_, String>(0))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }
}

fn table_has_column(conn: &Connection, table: &str, column: &str) -> bool {
    let Ok(mut stmt) = conn.prepare(&format!("PRAGMA table_info({table})")) else {
        return false;
    };
    let cols: Vec<String> = match stmt.query_map([], |r| r.get::<_, String>(1)) {
        Ok(rows) => rows.filter_map(|c| c.ok()).collect(),
        Err(_) => return false,
    };
    cols.iter().any(|c| c == column)
}

/// Map a row selected with [`SyncStore::ACCOUNT_COLUMNS`] into an
/// [`ExternalAccount`]. Shared by `get_account` and `list_accounts` so the
/// column→field projection lives in exactly one place.
fn row_to_external_account(row: &rusqlite::Row) -> rusqlite::Result<ExternalAccount> {
    Ok(ExternalAccount {
        key: row.get(0)?,
        display_name: row.get(1)?,
        email_address: row.get(2)?,
        provider_type: ProviderType::from_str(&row.get::<_, String>(3)?)
            .unwrap_or(ProviderType::Imap),
        host: row.get(4)?,
        port: row.get::<_, Option<i64>>(5)?.map(|p| p as u16),
        use_tls: row.get::<_, i32>(6)? != 0,
        smtp_host: row.get(7)?,
        smtp_port: row.get::<_, Option<i64>>(8)?.map(|p| p as u16),
        smtp_use_tls: row.get::<_, Option<i32>>(9)?.unwrap_or(1) != 0,
        auth_method: row.get(10)?,
        status: AccountStatus::from_str(&row.get::<_, String>(11)?),
        error_message: row.get(12)?,
        last_connected_at: row.get(13)?,
        sort_order: row.get(14)?,
        avatar_url: row.get(15)?,
    })
}

impl SyncStore {
    /// Ephemeral in-memory store. Used by unit tests and by the triage eval
    /// harness ([`crate::triage_eval`]), which seeds fixture threads through the
    /// real schema so the deterministic rules run exactly as in production. Uses
    /// a unique temp dir for the (unused) credential key so parallel uses don't
    /// collide.
    pub fn new_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA foreign_keys=ON;")?;
        conn.execute_batch(crate::SCHEMA_SQL)?;
        // A temp app-data dir for attachment paths etc. — but the encryptor uses
        // an ephemeral random key (NOT CredentialEncryptor::new), so an in-memory
        // test store never touches the OS keychain (which would prompt under the
        // os-keychain feature) or persist a key file.
        let data_dir = std::env::temp_dir().join(format!("inbox2_test_{}", nanoid::nanoid!(12)));
        std::fs::create_dir_all(&data_dir)
            .map_err(|e| SyncError::Other(format!("test data dir: {e}")))?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            encryptor: CredentialEncryptor::ephemeral(),
            app_data_dir: data_dir,
        })
    }

    /// Read a conversation's (status, read) — test helper for callers outside
    /// this module (e.g. engine tests) that can't reach the private `conn`.
    #[cfg(test)]
    pub(crate) fn conversation_status_read(&self, conversation_key: &str) -> (String, bool) {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT status, read FROM conversations WHERE key = ?1",
            params![conversation_key],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, i32>(1)? != 0)),
        )
        .unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn scrub_rebuilds_dirty_snippets_only() {
        let store = SyncStore::new_in_memory().unwrap();
        {
            let conn = store.conn.lock();
            // Dirty: a pre-sanitizer preview with a leaked CSS rule, whose
            // message body still has the real text past the truncation point.
            conn.execute(
                "INSERT INTO conversations (key, organization_id, snippet, updated_at)
                 VALUES ('cdirty', 'org', 'Vestiaire * { font-family: Arial; } Maybe', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, body_plain, created_at)
                 VALUES ('md', 'cdirty', 'org', 'Vestiaire * { font-family: Arial; } Maybe it''s time', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            // Clean: must be left untouched.
            conn.execute(
                "INSERT INTO conversations (key, organization_id, snippet, updated_at)
                 VALUES ('cclean', 'org', 'already clean', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
        }
        assert_eq!(store.scrub_dirty_snippets().unwrap(), 1);
        let (dirty, clean) = {
            let conn = store.conn.lock();
            let d: String = conn
                .query_row("SELECT snippet FROM conversations WHERE key='cdirty'", [], |r| r.get(0))
                .unwrap();
            let c: String = conn
                .query_row("SELECT snippet FROM conversations WHERE key='cclean'", [], |r| r.get(0))
                .unwrap();
            (d, c)
        };
        assert_eq!(dirty, "Vestiaire Maybe it's time");
        assert_eq!(clean, "already clean");
        // Second pass is a no-op — the scrub is a fixed point.
        assert_eq!(store.scrub_dirty_snippets().unwrap(), 0);
    }

    #[test]
    fn realign_repoints_preview_to_newest_message() {
        let store = SyncStore::new_in_memory().unwrap();
        {
            let conn = store.conn.lock();
            // Conversation frozen at its first message (old build behaviour):
            // sender + snippet from the thread-opener, updated_at already bumped
            // to a later reply from a *different* sender.
            conn.execute(
                "INSERT INTO conversations
                 (key, organization_id, from_address, snippet, updated_at)
                 VALUES ('cstale', 'org', 'Maya Chen <maya@example.com>',
                         'Kicking off — please review', '2024-01-02T13:49:00+00:00')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, from_address, body_plain, created_at)
                 VALUES ('m1', 'cstale', 'org', 'Maya Chen <maya@example.com>', 'Kicking off — please review', '2024-01-01T09:00:00+00:00')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, from_address, body_plain, created_at)
                 VALUES ('m2', 'cstale', 'org', 'Devin Park <devin@example.com>', 'All done — request closed out', '2024-01-02T13:49:00+00:00')",
                [],
            )
            .unwrap();
            // Already aligned to its newest message — must be left untouched.
            conn.execute(
                "INSERT INTO conversations (key, organization_id, from_address, snippet, updated_at)
                 VALUES ('cok', 'org', 'Sole Sender <s@a.ae>', 'only message', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, from_address, body_plain, created_at)
                 VALUES ('m3', 'cok', 'org', 'Sole Sender <s@a.ae>', 'only message', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
        }
        assert_eq!(store.realign_conversation_previews().unwrap(), 1);
        {
            let conn = store.conn.lock();
            let (from, snip): (String, String) = conn
                .query_row(
                    "SELECT from_address, snippet FROM conversations WHERE key='cstale'",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .unwrap();
            assert_eq!(from, "Devin Park <devin@example.com>");
            assert_eq!(snip, "All done — request closed out");
        }
        // Second pass is a no-op — the realignment is a fixed point.
        assert_eq!(store.realign_conversation_previews().unwrap(), 0);
    }

    #[test]
    fn late_body_backfill_repoints_preview_to_newest_message() {
        // The reported bug: a newer reply threads in body-less (lazy-load /
        // HTML-only), so the upsert advances the row's sender + timestamp but
        // keeps the prior message's snippet. When the body loads, the snippet
        // must repoint to it — the row showed the new sender but the OLD summary.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        // Older message with a body owns the preview.
        let mut m1 = dated(make_msg("<m1@x>", None, "Approval Request"), "2026-06-24T10:00:00+00:00");
        m1.from_address = "mohamed@example.com".into();
        m1.body_plain = Some("Kindly approve the VAT changes".into());
        store.upsert_synced_message(&acct, &folder, &m1, &gmail_pid("g1")).unwrap();

        // Newer reply arrives body-less: updated_at + from_address advance, but
        // the snippet can't yet (the upsert keeps the prior one).
        let mut m2 = dated(make_msg("<m2@x>", Some("<m1@x>"), "Re: Approval Request"), "2026-06-24T11:00:00+00:00");
        m2.from_address = "huzefa@example.com".into();
        m2.body_plain = None;
        m2.body_html = None;
        store.upsert_synced_message(&acct, &folder, &m2, &gmail_pid("g2")).unwrap();

        let read = |sql: &str| -> String {
            let conn = store.conn.lock();
            conn.query_row(sql, params![&acct], |r| r.get(0)).unwrap()
        };
        assert_eq!(read("SELECT from_address FROM conversations WHERE organization_id = ?1"), "huzefa@example.com");
        // Snippet still the older message's text at this point.
        assert_eq!(read("SELECT snippet FROM conversations WHERE organization_id = ?1"), "Kindly approve the VAT changes");

        // m2's body loads late — the backfill must repoint the snippet to it.
        let m2_key: String = {
            let conn = store.conn.lock();
            conn.query_row("SELECT key FROM messages WHERE message_id_header = '<m2@x>'", [], |r| r.get(0)).unwrap()
        };
        store.update_message_body(&m2_key, None, Some("We require additional time")).unwrap();
        assert_eq!(read("SELECT snippet FROM conversations WHERE organization_id = ?1"), "We require additional time");

        // An OLDER message's late body must NOT clobber the newest preview.
        let m1_key: String = {
            let conn = store.conn.lock();
            conn.query_row("SELECT key FROM messages WHERE message_id_header = '<m1@x>'", [], |r| r.get(0)).unwrap()
        };
        store.update_message_body(&m1_key, None, Some("Kindly approve the VAT changes (edited)")).unwrap();
        assert_eq!(read("SELECT snippet FROM conversations WHERE organization_id = ?1"), "We require additional time");
    }

    #[test]
    fn app_secret_round_trips_encrypted() {
        let store = SyncStore::new_in_memory().unwrap();
        assert_eq!(store.get_app_secret("rails_token").unwrap(), None);

        store.store_app_secret("rails_token", "ink_abc123").unwrap();
        assert_eq!(
            store.get_app_secret("rails_token").unwrap().as_deref(),
            Some("ink_abc123")
        );

        // Overwrite + delete.
        store.store_app_secret("rails_token", "ink_def456").unwrap();
        assert_eq!(
            store.get_app_secret("rails_token").unwrap().as_deref(),
            Some("ink_def456")
        );
        store.delete_app_secret("rails_token").unwrap();
        assert_eq!(store.get_app_secret("rails_token").unwrap(), None);
    }

    #[test]
    fn kv_namespaced_secret_is_disjoint_from_engine_managed() {
        let store = SyncStore::new_in_memory().unwrap();
        store.store_app_secret("rails_token", "ink_engine").unwrap();
        store.store_app_secret("kv:apollo_api_key", "apollo123").unwrap();

        // The webview's generic get_secret (kv: prefix) cannot reach the rails token.
        assert_eq!(store.get_app_secret("kv:rails_token").unwrap(), None);
        assert_eq!(
            store.get_app_secret("kv:apollo_api_key").unwrap().as_deref(),
            Some("apollo123")
        );
        assert_eq!(
            store.get_app_secret("rails_token").unwrap().as_deref(),
            Some("ink_engine")
        );
    }

    // Subject-normalization unit tests live in `threading.rs` alongside the
    // functions; the tests here exercise store-level threading/persistence.

    // ---- Test fixtures -----------------------------------------------------

    fn make_account(store: &SyncStore, email: &str, provider: ProviderType) -> String {
        store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: email.to_string(),
                email_address: email.to_string(),
                provider_type: provider,
                host: None,
                port: None,
                use_tls: true,
                smtp_host: None,
                smtp_port: None,
                smtp_use_tls: true,
                auth_method: AuthMethod::OAuth2.as_str().to_string(),
                status: AccountStatus::Disconnected,
                error_message: None,
                last_connected_at: None,
                sort_order: 0,
                avatar_url: None,
            })
            .unwrap()
    }

    fn make_folder(store: &SyncStore, account_key: &str, name: &str) -> String {
        let key = format!("fld_{}_{}", account_key, name);
        store
            .upsert_folder(&UnifiedFolder {
                key: key.clone(),
                account_key: account_key.to_string(),
                provider_name: name.to_string(),
                role: Some(WellKnownFolder::from_str(name)),
                separator: None,
                flags: vec![],
                uid_validity: None,
                highest_mod_seq: 0,
                last_synced_uid: 0,
                sync_cursor: None,
                sync_enabled: true,
            })
            .unwrap();
        key
    }

    fn make_msg(message_id: &str, in_reply_to: Option<&str>, subject: &str) -> UnifiedMessage {
        UnifiedMessage {
            key: String::new(),
            message_id: message_id.to_string(),
            subject: Some(subject.to_string()),
            from_address: "sender@example.com".to_string(),
            to_address: Some("me@example.com".to_string()),
            cc_address: None,
            in_reply_to: in_reply_to.map(String::from),
            references_header: None,
            provider_thread_id: None,
            body_plain: Some("body".to_string()),
            body_html: None,
            has_attachment: false,
            attachment_names: None,
            attachment_max_size: None,
            is_inbound: true,
            flags: UnifiedFlags::default(),
            labels: HashSet::new(),
            folders: HashSet::new(),
            date: None,
            internal_date: None,
        }
    }

    fn gmail_pid(id: &str) -> ProviderMessageId {
        ProviderMessageId {
            uid: None,
            mod_seq: None,
            provider_id: Some(id.to_string()),
        }
    }

    fn conv_count(store: &SyncStore, account_key: &str) -> i64 {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT COUNT(*) FROM conversations WHERE organization_id = ?1",
            params![account_key],
            |r| r.get(0),
        )
        .unwrap()
    }

    fn msg_count(store: &SyncStore, account_key: &str) -> i64 {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT COUNT(*) FROM messages WHERE account_key = ?1",
            params![account_key],
            |r| r.get(0),
        )
        .unwrap()
    }

    /// How many messages the FTS5 index matches for `query` — the same MATCH the
    /// keyword-search path runs, exercised here at the SQL level (keyword_search
    /// itself lives in the Tauri crate, but indexes this shared table).
    fn fts_match_count(store: &SyncStore, query: &str) -> i64 {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH ?1",
            params![query],
            |r| r.get(0),
        )
        .unwrap()
    }

    fn first_message_key(store: &SyncStore, account_key: &str) -> String {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT key FROM messages WHERE account_key = ?1 LIMIT 1",
            params![account_key],
            |r| r.get(0),
        )
        .unwrap()
    }

    // ---- Threading ---------------------------------------------------------

    #[test]
    fn threads_reply_into_existing_conversation_via_in_reply_to() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "Hello"), &gmail_pid("g1"))
            .unwrap();
        store
            .upsert_synced_message(
                &acct,
                &folder,
                &make_msg("<m2@x>", Some("<m1@x>"), "Re: Hello"),
                &gmail_pid("g2"),
            )
            .unwrap();

        // Two messages, one conversation (threaded).
        assert_eq!(msg_count(&store, &acct), 2);
        assert_eq!(conv_count(&store, &acct), 1);
    }

    // Provider search hits map back by provider id (Gmail) or by bare Message-ID
    // (Graph ids drift on a folder move), never across accounts.
    #[test]
    fn provider_search_hits_map_to_local_conversations() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let other = make_account(&store, "b@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");
        let other_folder = make_folder(&store, &other, "inbox");
        let c1 = store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "BTW Q3"), &gmail_pid("g1"))
            .unwrap()
            .conversation_key;
        let c2 = store
            .upsert_synced_message(&acct, &folder, &make_msg("<m2@x>", None, "Factuur"), &gmail_pid("g2"))
            .unwrap()
            .conversation_key;
        store
            .upsert_synced_message(&other, &other_folder, &make_msg("<m3@x>", None, "BTW"), &gmail_pid("g3"))
            .unwrap();

        let by_id = store.conversation_keys_for_hits(&acct, &["g1".into(), "g3".into()], &[]).unwrap();
        assert_eq!(by_id, vec![c1]);
        let by_mid = store.conversation_keys_for_hits(&acct, &["stale".into()], &["m2@x".into()]).unwrap();
        assert_eq!(by_mid, vec![c2]);
        assert!(store.conversation_keys_for_hits(&acct, &[], &[]).unwrap().is_empty());
    }

    #[test]
    fn known_provider_ids_spans_all_folders() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let inbox = make_folder(&store, &acct, "inbox");
        store
            .upsert_synced_message(&acct, &inbox, &make_msg("<m1@x>", None, "Hi"), &gmail_pid("g1"))
            .unwrap();
        store
            .upsert_synced_message(&acct, &inbox, &make_msg("<m2@x>", None, "Yo"), &gmail_pid("g2"))
            .unwrap();

        // The All-Mail skip-known filter relies on this seeing ids from every
        // folder (here the inbox) so it fetches only the archived-only delta.
        let known = store.known_provider_ids_for_account(&acct).unwrap();
        assert_eq!(known.len(), 2);
        assert!(known.contains(&"g1".to_string()));
        assert!(known.contains(&"g2".to_string()));
    }

    // ---- Attachment filename search ---------------------------------------

    #[test]
    fn fts_indexes_attachment_filenames_for_search() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        // The body/subject say nothing about the document, but the message
        // carries an attachment named "quarterly_budget.xlsx".
        let mut msg = make_msg("<m1@x>", None, "Please review");
        msg.attachment_names = Some("quarterly_budget.xlsx".to_string());
        store
            .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
            .unwrap();

        // FTS5's unicode61 tokenizer splits on '.'/'_', so a search for either
        // filename token finds the mail — alongside ordinary subject search.
        assert_eq!(fts_match_count(&store, "budget"), 1);
        assert_eq!(fts_match_count(&store, "quarterly"), 1);
        assert_eq!(fts_match_count(&store, "review"), 1);
        // An unrelated term still misses.
        assert_eq!(fts_match_count(&store, "invoice"), 0);
    }

    #[test]
    fn backfill_attachment_names_makes_message_searchable() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        // IMAP-style sync: no filenames known up front, so nothing to match yet.
        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "FYI"), &gmail_pid("g1"))
            .unwrap();
        assert_eq!(fts_match_count(&store, "contract"), 0);

        // Opening the message backfills the filename; the FTS update trigger
        // reindexes it so it's now findable by filename.
        let key = first_message_key(&store, &acct);
        store
            .backfill_attachment_names(&key, "signed_contract.pdf", Some(8_000_000))
            .unwrap();
        assert_eq!(fts_match_count(&store, "contract"), 1);

        // The size lands with the name — it's what `larger:5mb` filters on.
        let conn = store.conn.lock();
        let size: Option<i64> = conn
            .query_row(
                "SELECT attachment_max_size FROM messages WHERE key = ?1",
                [&key],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(size, Some(8_000_000));
    }

    #[test]
    fn html_only_mail_is_body_searchable() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");
        let html = "<table><tr><td>Aantal</td><td>Prijs</td></tr><tr><td>FiiO FD3</td><td>&euro;99,95</td></tr></table>";

        // Synced HTML-only (no text/plain part): body text is derived on insert.
        let mut m = make_msg("<m1@x>", None, "Je bestelling wordt verzonden");
        m.body_plain = None;
        m.body_html = Some(html.to_string());
        store.upsert_synced_message(&acct, &folder, &m, &gmail_pid("g1")).unwrap();
        assert_eq!(fts_match_count(&store, "fiio"), 1);

        // A lazily fetched body (Microsoft/IMAP headers-first) takes the same path.
        let key = first_message_key(&store, &acct);
        store.update_message_body(&key, Some("<p>Sennheiser HD600</p>"), None).unwrap();
        assert_eq!(fts_match_count(&store, "sennheiser"), 1);
        assert_eq!(fts_match_count(&store, "fiio"), 0);

        // Pre-fix rows (plain NULL, HTML present) are repaired by the paged backfill.
        store.conn.lock().execute("UPDATE messages SET body_plain = NULL", []).unwrap();
        assert_eq!(fts_match_count(&store, "sennheiser"), 0);
        let last = store.backfill_html_body_text(0, 200).unwrap();
        assert!(last.is_some());
        assert_eq!(store.backfill_html_body_text(last.unwrap(), 200).unwrap(), None);
        assert_eq!(fts_match_count(&store, "sennheiser"), 1);
    }

    #[test]
    fn filename_backfill_candidates_and_sentinel() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        // A message in an attachment-bearing thread, synced without filenames.
        let mut m = make_msg("<m1@x>", None, "Invoice attached");
        m.has_attachment = true;
        store.upsert_synced_message(&acct, &folder, &m, &gmail_pid("g1")).unwrap();

        // It's a backfill candidate (has_attachment thread, attachment_names NULL).
        let candidates = store.messages_needing_filename_backfill(100).unwrap();
        assert_eq!(candidates.len(), 1);
        let (cand_acct, cand_key) = &candidates[0];
        assert_eq!(cand_acct, &acct);

        // Recording the empty sentinel ("checked, none") drops it from the set so
        // an inline-only message isn't re-fetched on every launch.
        store.set_attachment_names(cand_key, "", None).unwrap();
        assert!(store.messages_needing_filename_backfill(100).unwrap().is_empty());
    }

    // ---- Notifications -----------------------------------------------------

    #[test]
    fn message_notification_suppressed_for_spam_conversation() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        // A batch where a non-spam message lands first (queuing a pending
        // notification), then a spam sibling threads into the same conversation
        // and drives its status to "spam" — mirroring the engine, which upserts
        // every message in a folder's result before building any notification.
        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "Champions deserve 50% off"), &gmail_pid("g1"))
            .unwrap();
        let mut spammy = make_msg("<m2@x>", Some("<m1@x>"), "Re: Champions deserve 50% off");
        spammy.flags.spam = true;
        store
            .upsert_synced_message(&acct, &folder, &spammy, &gmail_pid("g2"))
            .unwrap();
        assert_eq!(conv_count(&store, &acct), 1, "reply should thread, not split");

        // The earlier message's pending notification is suppressed — its
        // conversation is now spam and filtered out of the inbox list.
        assert!(store.message_notification(&acct, "g1").unwrap().is_none());

        // A genuinely-open conversation still notifies.
        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m3@x>", None, "Real mail"), &gmail_pid("g3"))
            .unwrap();
        assert!(store.message_notification(&acct, "g3").unwrap().is_some());
    }

    // ---- Threading: provider-native thread id ------------------------------

    #[test]
    fn threads_by_provider_thread_id_across_different_subjects() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        let mut a = make_msg("<a@x>", None, "Original subject");
        a.provider_thread_id = Some("thread-1".to_string());
        store
            .upsert_synced_message(&acct, &folder, &a, &gmail_pid("g1"))
            .unwrap();

        // Different subject, no shared headers — only the thread id links them.
        let mut b = make_msg("<b@x>", None, "A different subject entirely");
        b.provider_thread_id = Some("thread-1".to_string());
        store
            .upsert_synced_message(&acct, &folder, &b, &gmail_pid("g2"))
            .unwrap();

        assert_eq!(msg_count(&store, &acct), 2);
        assert_eq!(conv_count(&store, &acct), 1);
    }

    #[test]
    fn distinct_provider_threads_with_same_subject_stay_separate() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        let mut a = make_msg("<a@x>", None, "Master Data Ready for Testing");
        a.provider_thread_id = Some("thread-1".to_string());
        store
            .upsert_synced_message(&acct, &folder, &a, &gmail_pid("g1"))
            .unwrap();

        let mut b = make_msg("<b@x>", None, "Master Data Ready for Testing");
        b.provider_thread_id = Some("thread-2".to_string());
        store
            .upsert_synced_message(&acct, &folder, &b, &gmail_pid("g2"))
            .unwrap();

        // The provider deliberately split these; we must not re-merge by subject.
        assert_eq!(conv_count(&store, &acct), 2);
    }

    // ---- Threading: header + subject fallback (the IMAP / no-thread-id path).
    // These messages carry no provider_thread_id, so the engine threads on
    // References/In-Reply-To and then the normalized subject — exactly the path
    // an IMAP account takes.

    #[test]
    fn fallback_threads_via_references_header() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Imap);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<root@x>", None, "Spec"), &gmail_pid("u1"))
            .unwrap();

        // No In-Reply-To, different subject — only References links them.
        let mut follow = make_msg("<follow@x>", None, "Unrelated subject");
        follow.references_header = Some("<other@elsewhere> <root@x>".to_string());
        store
            .upsert_synced_message(&acct, &folder, &follow, &gmail_pid("u2"))
            .unwrap();

        assert_eq!(conv_count(&store, &acct), 1);
    }

    #[test]
    fn fallback_threads_same_subject_without_headers() {
        // The reported case: a reply between two people that lost its threading
        // headers. Same normalized subject + a shared participant (each is the
        // other's correspondent) re-threads them.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Imap);
        let folder = make_folder(&store, &acct, "inbox");

        let mut a = make_msg("<a@x>", None, "Master Data Ready for Testing");
        a.from_address = "mo@example.com".to_string();
        a.to_address = Some("mohamed@example.com".to_string());
        store
            .upsert_synced_message(&acct, &folder, &a, &gmail_pid("u1"))
            .unwrap();

        let mut b = make_msg("<b@x>", None, "RE: Master Data Ready for Testing");
        b.from_address = "mohamed@example.com".to_string();
        b.to_address = Some("mo@example.com".to_string());
        store
            .upsert_synced_message(&acct, &folder, &b, &gmail_pid("u2"))
            .unwrap();

        assert_eq!(conv_count(&store, &acct), 1);
    }

    #[test]
    fn fallback_same_subject_unrelated_participants_stay_separate() {
        // Two unrelated senders mailing the *same* recipient with a generic
        // shared subject must NOT merge — a common "to me" recipient is not a
        // thread. This is what keeps "Without subject" / "Invoice" blasts apart.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Imap);
        let folder = make_folder(&store, &acct, "inbox");

        let mut a = make_msg("<a@x>", None, "Invoice");
        a.from_address = "vendor-x@example.com".to_string();
        a.to_address = Some("me@example.com".to_string());
        store
            .upsert_synced_message(&acct, &folder, &a, &gmail_pid("u1"))
            .unwrap();

        let mut b = make_msg("<b@x>", None, "Invoice");
        b.from_address = "vendor-y@example.com".to_string();
        b.to_address = Some("me@example.com".to_string());
        store
            .upsert_synced_message(&acct, &folder, &b, &gmail_pid("u2"))
            .unwrap();

        assert_eq!(conv_count(&store, &acct), 2);
    }

    #[test]
    fn fallback_localized_prefix_threads_with_original() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Imap);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<a@x>", None, "Bericht"), &gmail_pid("u1"))
            .unwrap();
        // German reply prefix, no headers → still threads.
        store
            .upsert_synced_message(&acct, &folder, &make_msg("<b@x>", None, "AW: Bericht"), &gmail_pid("u2"))
            .unwrap();

        assert_eq!(conv_count(&store, &acct), 1);
    }

    #[test]
    fn fallback_substring_subjects_do_not_over_merge() {
        // Regression: the old substring LIKE merged any subject that contained
        // the other. Exact normalized matching keeps these apart.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Imap);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<a@x>", None, "Report"), &gmail_pid("u1"))
            .unwrap();
        store
            .upsert_synced_message(
                &acct,
                &folder,
                &make_msg("<b@x>", None, "Quarterly Report for the Board"),
                &gmail_pid("u2"),
            )
            .unwrap();

        assert_eq!(conv_count(&store, &acct), 2);
    }

    #[test]
    fn fallback_blank_subjects_do_not_collapse() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Imap);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<a@x>", None, ""), &gmail_pid("u1"))
            .unwrap();
        store
            .upsert_synced_message(&acct, &folder, &make_msg("<b@x>", None, ""), &gmail_pid("u2"))
            .unwrap();

        // Subjectless mail must not all pile into one conversation.
        assert_eq!(conv_count(&store, &acct), 2);
    }

    #[test]
    fn fallback_distinct_subjects_stay_separate() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Imap);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<a@x>", None, "Alpha"), &gmail_pid("u1"))
            .unwrap();
        store
            .upsert_synced_message(&acct, &folder, &make_msg("<b@x>", None, "Beta"), &gmail_pid("u2"))
            .unwrap();

        assert_eq!(conv_count(&store, &acct), 2);
    }

    // ---- Conversation timeline (drives inbox sort + date display) ----------

    fn dated(mut msg: UnifiedMessage, rfc3339: &str) -> UnifiedMessage {
        msg.date = Some(
            chrono::DateTime::parse_from_rfc3339(rfc3339)
                .unwrap()
                .with_timezone(&Utc),
        );
        msg
    }

    fn conv_updated_at(store: &SyncStore, account_key: &str) -> String {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT updated_at FROM conversations WHERE organization_id = ?1 LIMIT 1",
            params![account_key],
            |r| r.get(0),
        )
        .unwrap()
    }

    #[test]
    fn conversation_timeline_uses_message_date_not_sync_time() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        let msg = dated(make_msg("<m1@x>", None, "Hello"), "2020-01-02T03:04:05+00:00");
        store
            .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
            .unwrap();

        // updated_at must be the email's date, not the sync wall-clock.
        assert_eq!(conv_updated_at(&store, &acct), "2020-01-02T03:04:05+00:00");
    }

    #[test]
    fn newer_message_advances_conversation_updated_at() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(
                &acct,
                &folder,
                &dated(make_msg("<m1@x>", None, "Hello"), "2020-01-01T00:00:00+00:00"),
                &gmail_pid("g1"),
            )
            .unwrap();
        store
            .upsert_synced_message(
                &acct,
                &folder,
                &dated(
                    make_msg("<m2@x>", Some("<m1@x>"), "Re: Hello"),
                    "2021-06-15T12:00:00+00:00",
                ),
                &gmail_pid("g2"),
            )
            .unwrap();

        assert_eq!(conv_count(&store, &acct), 1);
        assert_eq!(conv_updated_at(&store, &acct), "2021-06-15T12:00:00+00:00");
    }

    #[test]
    fn older_message_does_not_regress_updated_at() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(
                &acct,
                &folder,
                &dated(make_msg("<m1@x>", None, "Hello"), "2021-06-15T12:00:00+00:00"),
                &gmail_pid("g1"),
            )
            .unwrap();
        // A late-arriving older reply must not pull the thread backwards.
        store
            .upsert_synced_message(
                &acct,
                &folder,
                &dated(
                    make_msg("<m2@x>", Some("<m1@x>"), "Re: Hello"),
                    "2020-01-01T00:00:00+00:00",
                ),
                &gmail_pid("g2"),
            )
            .unwrap();

        assert_eq!(conv_updated_at(&store, &acct), "2021-06-15T12:00:00+00:00");
    }

    #[test]
    fn flag_update_does_not_bump_conversation_updated_at() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(
                &acct,
                &folder,
                &dated(make_msg("<m1@x>", None, "Hello"), "2020-01-02T03:04:05+00:00"),
                &gmail_pid("g1"),
            )
            .unwrap();

        // Re-sync the same message with a changed (read) flag — this exercises
        // update_conversation_from_flags, which must NOT touch updated_at.
        let mut read_msg = dated(make_msg("<m1@x>", None, "Hello"), "2020-01-02T03:04:05+00:00");
        read_msg.flags.read = true;
        store
            .upsert_synced_message(&acct, &folder, &read_msg, &gmail_pid("g1"))
            .unwrap();

        assert_eq!(conv_updated_at(&store, &acct), "2020-01-02T03:04:05+00:00");
    }

    #[test]
    fn unrelated_message_creates_new_conversation() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "Hello"), &gmail_pid("g1"))
            .unwrap();
        store
            .upsert_synced_message(
                &acct,
                &folder,
                &make_msg("<m9@x>", None, "Totally different"),
                &gmail_pid("g9"),
            )
            .unwrap();

        assert_eq!(conv_count(&store, &acct), 2);
    }

    #[test]
    fn dedup_is_scoped_per_account() {
        // The same Message-ID in two accounts must NOT be merged.
        let store = SyncStore::new_in_memory().unwrap();
        let a = make_account(&store, "a@x.com", ProviderType::Gmail);
        let b = make_account(&store, "b@x.com", ProviderType::Gmail);
        let fa = make_folder(&store, &a, "inbox");
        let fb = make_folder(&store, &b, "inbox");

        store
            .upsert_synced_message(&a, &fa, &make_msg("<shared@x>", None, "Hi"), &gmail_pid("g1"))
            .unwrap();
        store
            .upsert_synced_message(&b, &fb, &make_msg("<shared@x>", None, "Hi"), &gmail_pid("g1"))
            .unwrap();

        assert_eq!(msg_count(&store, &a), 1);
        assert_eq!(msg_count(&store, &b), 1);
    }

    #[test]
    fn same_message_in_two_folders_is_one_message_two_provider_states() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let inbox = make_folder(&store, &acct, "inbox");
        let archive = make_folder(&store, &acct, "archive");

        store
            .upsert_synced_message(&acct, &inbox, &make_msg("<m1@x>", None, "Hi"), &gmail_pid("g1"))
            .unwrap();
        // Same Gmail message id under a second label/folder.
        store
            .upsert_synced_message(&acct, &archive, &make_msg("<m1@x>", None, "Hi"), &gmail_pid("g1"))
            .unwrap();

        assert_eq!(msg_count(&store, &acct), 1);
        let conn = store.conn.lock();
        let ps: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM message_provider_state WHERE account_key = ?1",
                params![acct],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(ps, 2);
    }

    // ---- Deletion / pruning ------------------------------------------------

    #[test]
    fn cascade_delete_removes_message_and_orphaned_conversation() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "Hi"), &gmail_pid("g1"))
            .unwrap();
        assert_eq!(conv_count(&store, &acct), 1);

        store
            .cascade_delete_message(&acct, &folder, &gmail_pid("g1"))
            .unwrap();

        assert_eq!(msg_count(&store, &acct), 0);
        assert_eq!(conv_count(&store, &acct), 0);
    }

    #[test]
    fn cascade_delete_keeps_conversation_with_remaining_messages() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "Hi"), &gmail_pid("g1"))
            .unwrap();
        store
            .upsert_synced_message(
                &acct,
                &folder,
                &make_msg("<m2@x>", Some("<m1@x>"), "Re: Hi"),
                &gmail_pid("g2"),
            )
            .unwrap();
        assert_eq!(conv_count(&store, &acct), 1);

        store
            .cascade_delete_message(&acct, &folder, &gmail_pid("g1"))
            .unwrap();

        // One message removed; conversation survives because g2 remains.
        assert_eq!(msg_count(&store, &acct), 1);
        assert_eq!(conv_count(&store, &acct), 1);
    }

    #[test]
    fn prune_unseen_removes_only_disappeared_messages() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        for id in ["g1", "g2", "g3"] {
            store
                .upsert_synced_message(
                    &acct,
                    &folder,
                    &make_msg(&format!("<{id}@x>"), None, id),
                    &gmail_pid(id),
                )
                .unwrap();
        }
        assert_eq!(msg_count(&store, &acct), 3);

        // Remote listing only still contains g1 and g3.
        let seen: HashSet<String> = ["g1", "g3"].iter().map(|s| s.to_string()).collect();
        let removed = store.prune_unseen_provider_ids(&acct, &folder, &seen).unwrap();

        assert_eq!(removed, 1);
        assert_eq!(msg_count(&store, &acct), 2);
    }

    // ---- Account row-mapping + status persistence --------------------------

    #[test]
    fn account_status_persists_through_get_and_list() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Microsoft);

        // Freshly created accounts are Disconnected and read back identically
        // through the shared row mapper.
        let got = store.get_account(&acct).unwrap().unwrap();
        assert_eq!(got.status, AccountStatus::Disconnected);
        assert_eq!(got.provider_type, ProviderType::Microsoft);
        assert_eq!(got.email_address, "a@x.com");

        // Each status survives a write/read cycle (exercises AccountStatus::from_str).
        for s in [
            AccountStatus::Connecting,
            AccountStatus::Connected,
            AccountStatus::Error,
            AccountStatus::Disconnected,
        ] {
            store.update_account_status(&acct, &s, None).unwrap();
            assert_eq!(store.get_account(&acct).unwrap().unwrap().status, s);
            // list_accounts uses the same mapper, so it must agree.
            let listed = store.list_accounts().unwrap();
            assert_eq!(listed.iter().find(|a| a.key == acct).unwrap().status, s);
        }
    }

    // ---- Conversation status reflects message flags ------------------------

    fn conv_status(store: &SyncStore, account_key: &str) -> String {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT status FROM conversations WHERE organization_id = ?1 LIMIT 1",
            params![account_key],
            |r| r.get(0),
        )
        .unwrap()
    }

    #[test]
    fn conversation_status_written_from_message_flags() {
        // Each flag combination must persist the ConversationStatus the enum
        // derives — the create path (find_or_create_conversation) and the update
        // path (update_conversation_from_flags) share this.
        for (flag_set, expected) in [
            (UnifiedFlags::default(), "open"),
            (UnifiedFlags { archived: true, ..Default::default() }, "archived"),
            (UnifiedFlags { spam: true, ..Default::default() }, "spam"),
            (UnifiedFlags { trashed: true, ..Default::default() }, "trash"),
        ] {
            let store = SyncStore::new_in_memory().unwrap();
            let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
            let folder = make_folder(&store, &acct, "inbox");
            let mut msg = make_msg("<m1@x>", None, "Hi");
            msg.flags = flag_set;
            store
                .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
                .unwrap();
            assert_eq!(conv_status(&store, &acct), expected);
        }
    }

    #[test]
    fn old_trashed_message_does_not_drag_thread_with_a_live_reply_into_trash() {
        // Gmail syncs INBOX before TRASH, so a thread holding one old trashed
        // message had that stale copy write the conversation status last and the
        // live reply vanished from the inbox. Only the newest status-bearing
        // message defines the thread.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let inbox = make_folder(&store, &acct, "inbox");
        let trash = make_folder(&store, &acct, "trash");

        let mut old = dated(make_msg("<old@x>", None, "Pitch"), "2026-08-04T07:30:00Z");
        old.provider_thread_id = Some("thread-1".to_string());
        old.flags = UnifiedFlags { trashed: true, ..Default::default() };
        let mut reply = dated(make_msg("<new@x>", None, "Fwd: Pitch"), "2026-08-19T11:43:43Z");
        reply.provider_thread_id = Some("thread-1".to_string());

        store.upsert_synced_message(&acct, &trash, &old, &gmail_pid("g1")).unwrap();
        assert_eq!(conv_status(&store, &acct), "trash");

        // The reply lands in the inbox — it is now the thread's newest message.
        store.upsert_synced_message(&acct, &inbox, &reply, &gmail_pid("g2")).unwrap();
        assert_eq!(conv_status(&store, &acct), "open");

        // …and the TRASH folder re-syncing the old copy right after must not
        // undo that.
        store.upsert_synced_message(&acct, &trash, &old, &gmail_pid("g1")).unwrap();
        assert_eq!(conv_status(&store, &acct), "open");

        // The newest message going to trash still trashes the thread.
        reply.flags = UnifiedFlags { trashed: true, ..Default::default() };
        store.upsert_synced_message(&acct, &trash, &reply, &gmail_pid("g2")).unwrap();
        assert_eq!(conv_status(&store, &acct), "trash");
    }

    #[test]
    fn older_inbox_reply_keeps_thread_open_when_newest_is_archived() {
        // Gmail shows a thread in the inbox while ANY message carries INBOX. Here the
        // newest reply was read + archived, then two older unread replies (backdated
        // Date headers) landed in the inbox — the thread stayed archived locally.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let inbox = make_folder(&store, &acct, "inbox");
        let all = make_folder(&store, &acct, "archive");
        let archived = UnifiedFlags { archived: true, read: true, ..Default::default() };

        let mut newest = dated(make_msg("<new@x>", None, "Release plan"), "2026-09-28T07:59:41Z");
        newest.provider_thread_id = Some("thread-1".to_string());
        newest.flags = archived.clone();
        let mut older = dated(make_msg("<old@x>", None, "Re: Release plan"), "2026-09-28T02:43:55Z");
        older.provider_thread_id = Some("thread-1".to_string());

        store.upsert_synced_message(&acct, &all, &newest, &gmail_pid("g1")).unwrap();
        assert_eq!(conv_status(&store, &acct), "archived");

        store.upsert_synced_message(&acct, &inbox, &older, &gmail_pid("g2")).unwrap();
        assert_eq!(conv_status(&store, &acct), "open", "an inbox copy reopens the thread");

        // The newest copy re-syncing (still archived) must not archive it again.
        store.upsert_synced_message(&acct, &all, &newest, &gmail_pid("g1")).unwrap();
        assert_eq!(conv_status(&store, &acct), "open");

        // Archived in Gmail: the inbox row goes first (inbox syncs first), then the
        // newest copy re-decides.
        store.cascade_delete_message(&acct, &inbox, &gmail_pid("g2")).unwrap();
        store.upsert_synced_message(&acct, &all, &newest, &gmail_pid("g1")).unwrap();
        assert_eq!(conv_status(&store, &acct), "archived");
    }

    #[test]
    fn newest_sent_reply_does_not_define_thread_status() {
        // A Sent copy always reports open/unarchived, so if your own last reply
        // defined the status, archiving the thread in Gmail would never stick.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let archive = make_folder(&store, &acct, "archive");
        let sent = make_folder(&store, &acct, "sent");

        let mut inbound = dated(make_msg("<in@x>", None, "Q"), "2026-08-01T09:00:00Z");
        inbound.provider_thread_id = Some("thread-1".to_string());
        inbound.flags = UnifiedFlags { archived: true, ..Default::default() };
        let mut mine = dated(make_msg("<mine@x>", None, "Re: Q"), "2026-08-02T09:00:00Z");
        mine.provider_thread_id = Some("thread-1".to_string());

        store.upsert_synced_message(&acct, &sent, &mine, &gmail_pid("g2")).unwrap();
        store.upsert_synced_message(&acct, &archive, &inbound, &gmail_pid("g1")).unwrap();

        assert_eq!(conv_status(&store, &acct), "archived");
    }

    #[test]
    fn has_attachment_flag_persists_to_conversation_and_is_sticky() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");
        let read = |s: &SyncStore| -> bool {
            let conn = s.conn.lock();
            conn.query_row(
                "SELECT has_attachment FROM conversations WHERE organization_id = ?1 LIMIT 1",
                params![acct],
                |r| Ok(r.get::<_, i64>(0)? != 0),
            )
            .unwrap()
        };

        // First message in the thread carries an attachment → flag set.
        let mut m1 = make_msg("<m1@x>", None, "Invoice");
        m1.has_attachment = true;
        store
            .upsert_synced_message(&acct, &folder, &m1, &gmail_pid("g1"))
            .unwrap();
        assert!(read(&store), "attachment message should flag the conversation");

        // A later attachment-less reply must NOT clear it (sticky per-thread).
        let m2 = make_msg("<m2@x>", Some("<m1@x>"), "Re: Invoice");
        assert!(!m2.has_attachment);
        store
            .upsert_synced_message(&acct, &folder, &m2, &gmail_pid("g2"))
            .unwrap();
        assert!(read(&store), "reply without attachment must not clear the flag");
    }

    #[test]
    fn has_attachment_backfills_existing_thread_on_resync() {
        // Resync re-fetches messages that already exist (deduped by Message-ID),
        // so the flag must be set on the existing-message path too — otherwise a
        // forced resync couldn't backfill threads synced before this was tracked.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");
        let read = |s: &SyncStore| -> bool {
            let conn = s.conn.lock();
            conn.query_row(
                "SELECT has_attachment FROM conversations WHERE organization_id = ?1 LIMIT 1",
                params![acct],
                |r| Ok(r.get::<_, i64>(0)? != 0),
            )
            .unwrap()
        };

        // Initial sync before attachments were tracked: flag stays off.
        let m = make_msg("<m1@x>", None, "Invoice");
        assert!(!m.has_attachment);
        store
            .upsert_synced_message(&acct, &folder, &m, &gmail_pid("g1"))
            .unwrap();
        assert!(!read(&store));

        // Resync: same message (same Message-ID), now parsed with the attachment.
        let mut again = make_msg("<m1@x>", None, "Invoice");
        again.has_attachment = true;
        store
            .upsert_synced_message(&acct, &folder, &again, &gmail_pid("g1"))
            .unwrap();
        assert!(read(&store), "resync of an existing message should backfill the flag");
    }

    #[test]
    fn message_notification_suppressed_for_trash_conversation() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        let mut trashed = make_msg("<m1@x>", None, "Old receipt");
        trashed.flags.trashed = true;
        store
            .upsert_synced_message(&acct, &folder, &trashed, &gmail_pid("g1"))
            .unwrap();

        assert_eq!(conv_status(&store, &acct), "trash");
        assert!(store.message_notification(&acct, "g1").unwrap().is_none());
    }

    #[test]
    fn message_notification_fires_for_archived_conversation() {
        // Archived is not hidden from the inbox notification path — only spam and
        // trash are suppressed.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        let mut archived = make_msg("<m1@x>", None, "Archived but notable");
        archived.flags.archived = true;
        store
            .upsert_synced_message(&acct, &folder, &archived, &gmail_pid("g1"))
            .unwrap();

        assert_eq!(conv_status(&store, &acct), "archived");
        assert!(store.message_notification(&acct, "g1").unwrap().is_some());
    }

    // ---- Credential store round-trip ---------------------------------------

    #[test]
    fn credentials_round_trip_through_encrypted_store() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);

        assert!(store.get_credentials(&acct).unwrap().is_none());

        store
            .store_credentials(
                &acct,
                &ProviderCredentials::OAuth2 {
                    username: "a@x.com".into(),
                    access_token: "tok".into(),
                    refresh_token: Some("refresh".into()),
                },
            )
            .unwrap();

        match store.get_credentials(&acct).unwrap().unwrap() {
            ProviderCredentials::OAuth2 { username, access_token, refresh_token } => {
                assert_eq!(username, "a@x.com");
                assert_eq!(access_token, "tok");
                assert_eq!(refresh_token.as_deref(), Some("refresh"));
            }
            _ => panic!("expected OAuth2 credentials"),
        }
    }

    /// Credentials that no longer decrypt must surface as `CredentialUnreadable`
    /// (→ `is_auth` → `NeedsReauth`), not as an opaque error the UI ignores. This is
    /// the 2026-08-03 failure exactly: a debug build minted a fresh master key, so
    /// every account's ciphertext became unreadable while the channels still showed
    /// `Connected` and sync just quietly stopped.
    #[test]
    fn rekeyed_store_reports_credentials_as_needing_reauth() {
        let dir = std::env::temp_dir().join(format!("inbox2_rekey_{}", nanoid::nanoid!(12)));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("inbox2.db");

        let acct = {
            let store = SyncStore::new(&db, &dir).unwrap();
            let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
            store
                .store_credentials(
                    &acct,
                    &ProviderCredentials::OAuth2 {
                        username: "a@x.com".into(),
                        access_token: "tok".into(),
                        refresh_token: Some("refresh".into()),
                    },
                )
                .unwrap();
            assert!(store.get_credentials(&acct).unwrap().is_some());
            acct
        };

        // The master key is regenerated underneath the untouched ciphertext.
        std::fs::write(dir.join(".credential_key"), [7u8; 32]).unwrap();

        let store = SyncStore::new(&db, &dir).unwrap();
        let err = store
            .get_credentials(&acct)
            .err()
            .expect("a mismatched key must fail, not return None or stale plaintext");
        assert!(
            matches!(err, SyncError::CredentialUnreadable(_)),
            "expected CredentialUnreadable, got: {err}"
        );
        assert!(err.is_auth(), "must flag the account NeedsReauth so the UI prompts");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- Sync-vs-writeback race --------------------------------------------

    /// (status, read) for the single conversation in the account.
    fn conv_status_read(store: &SyncStore, account_key: &str) -> (String, bool) {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT status, read FROM conversations WHERE organization_id = ?1 LIMIT 1",
            params![account_key],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, i32>(1)? != 0)),
        )
        .unwrap()
    }

    fn enqueue_pending(store: &SyncStore, account_key: &str, message_key: &str, action_type: ActionType) {
        store
            .enqueue_action(&WritebackAction {
                key: format!("wba_{action_type:?}"),
                account_key: account_key.to_string(),
                action_type,
                message_key: message_key.to_string(),
                folder_key: None,
                provider_snapshot: None,
                status: ActionStatus::Pending,
                retry_count: 0,
                max_retries: 10,
                next_retry_at: None,
                error_message: None,
            })
            .unwrap();
    }

    fn message_key_for(store: &SyncStore, account_key: &str) -> String {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT key FROM messages WHERE account_key = ?1 LIMIT 1",
            params![account_key],
            |r| r.get(0),
        )
        .unwrap()
    }

    fn conv_key_for(store: &SyncStore, account_key: &str) -> String {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT key FROM conversations WHERE organization_id = ?1 LIMIT 1",
            params![account_key],
            |r| r.get(0),
        )
        .unwrap()
    }

    #[test]
    fn set_conversation_status_updates_status_and_read_independently() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");
        let mut msg = make_msg("<m1@x>", None, "Hello");
        msg.flags.read = true;
        store
            .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
            .unwrap();
        let conv = conv_key_for(&store, &acct);
        let before = conv_updated_at(&store, &acct);

        // status-only: read is left untouched.
        store
            .set_conversation_status(&conv, Some(ConversationStatus::Trash), None)
            .unwrap();
        assert_eq!(conv_status_read(&store, &acct), ("trash".into(), true));

        // read-only: status is left untouched.
        store
            .set_conversation_status(&conv, None, Some(false))
            .unwrap();
        assert_eq!(conv_status_read(&store, &acct), ("trash".into(), false));

        // A status/read change is not new activity — updated_at must not move
        // (otherwise archiving would resort the inbox to wall-clock time).
        assert_eq!(conv_updated_at(&store, &acct), before);
    }

    #[test]
    fn sync_does_not_resurrect_archived_message_with_pending_writeback() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        // Message arrives, read and in the inbox (status "open").
        let mut msg = make_msg("<m1@x>", None, "Hello");
        msg.flags.read = true;
        store
            .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
            .unwrap();
        let msg_key = message_key_for(&store, &acct);

        // User archives: the action command optimistically sets the conversation
        // to "archived" (via the real centralized setter) and queues the
        // write-back; the provider hasn't been told yet.
        let conv_key = conv_key_for(&store, &acct);
        store
            .set_conversation_status(&conv_key, Some(ConversationStatus::Archived), None)
            .unwrap();
        enqueue_pending(&store, &acct, &msg_key, ActionType::Archive);

        // A concurrent sync pulls the *pre-mutation* provider state: still in
        // the inbox (archived=false) and now unread. Without the guard this
        // would flip the conversation back to open + unread.
        let mut stale = make_msg("<m1@x>", None, "Hello");
        stale.flags.read = false; // UNREAD still present on the server
        stale.flags.archived = false; // INBOX label not yet removed
        store
            .upsert_synced_message(&acct, &folder, &stale, &gmail_pid("g1"))
            .unwrap();

        // The optimistic archive must survive, and read must not flip.
        let (status, read) = conv_status_read(&store, &acct);
        assert_eq!(status, "archived", "archived thread was resurrected by sync");
        assert!(read, "read flag was clobbered back to unread by sync");
    }

    #[test]
    fn sync_updates_status_when_no_pending_writeback() {
        // Control: with no pending write-back, the sync DOES mirror provider
        // flags onto the conversation — proving the guard is conditional.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        let mut msg = make_msg("<m1@x>", None, "Hello");
        msg.flags.read = true;
        store
            .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
            .unwrap();

        // A genuine remote archive (no local action queued) must take effect.
        let mut archived = make_msg("<m1@x>", None, "Hello");
        archived.flags.read = true;
        archived.flags.archived = true;
        store
            .upsert_synced_message(&acct, &folder, &archived, &gmail_pid("g1"))
            .unwrap();

        let (status, _read) = conv_status_read(&store, &acct);
        assert_eq!(status, "archived", "remote archive should propagate locally");
    }

    /// Enqueue an action and immediately mark it completed (write-back applied
    /// to the provider). Returns its key.
    fn enqueue_completed(
        store: &SyncStore,
        account_key: &str,
        message_key: &str,
        action_type: ActionType,
    ) -> String {
        let key = format!("wba_done_{action_type:?}");
        store
            .enqueue_action(&WritebackAction {
                key: key.clone(),
                account_key: account_key.to_string(),
                action_type,
                message_key: message_key.to_string(),
                folder_key: None,
                provider_snapshot: None,
                status: ActionStatus::Pending,
                retry_count: 0,
                max_retries: 10,
                next_retry_at: None,
                error_message: None,
            })
            .unwrap();
        store
            .update_action_status(&key, &ActionStatus::Completed, 0, None, None)
            .unwrap();
        key
    }

    #[test]
    fn sync_does_not_resurrect_deleted_message_after_writeback_completes() {
        // The core bug: a message deleted from a channel disappeared, flickered
        // back, then vanished for good. The write-back (Gmail trash) completes
        // quickly, but a sync that snapshotted the *pre-mutation* state can be
        // in flight and land just after — the message still in the inbox,
        // trashed=false. Until the guard accounted for completed-but-unsettled
        // actions, that stale snapshot mirrored INBOX flags back onto the
        // conversation and resurrected it.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        // Message in the inbox (status "open").
        let mut msg = make_msg("<m1@x>", None, "Snapchat login");
        msg.flags.read = true;
        store
            .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
            .unwrap();
        let msg_key = message_key_for(&store, &acct);
        let conv_key = conv_key_for(&store, &acct);

        // User deletes: optimistic local Trash + write-back, which then COMPLETES
        // on the provider (Gmail trash/delete returned 200).
        store
            .set_conversation_status(&conv_key, Some(ConversationStatus::Trash), None)
            .unwrap();
        enqueue_completed(&store, &acct, &msg_key, ActionType::Trash);

        // A pre-mutation sync snapshot lands: still in the inbox, trashed=false.
        let mut stale = make_msg("<m1@x>", None, "Snapchat login");
        stale.flags.read = true;
        stale.flags.trashed = false;
        stale.flags.archived = false;
        store
            .upsert_synced_message(&acct, &folder, &stale, &gmail_pid("g1"))
            .unwrap();

        let (status, _read) = conv_status_read(&store, &acct);
        assert_eq!(
            status, "trash",
            "deleted thread was resurrected by a stale post-completion sync"
        );
    }

    /// Message key for a given Message-ID header on the account.
    fn message_key_for_header(store: &SyncStore, account_key: &str, message_id: &str) -> String {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT key FROM messages WHERE account_key = ?1 AND message_id_header = ?2",
            params![account_key, message_id],
            |r| r.get(0),
        )
        .unwrap()
    }

    #[test]
    fn sync_does_not_resurrect_archived_thread_via_unguarded_sibling() {
        // The reported bug: archive a thread, it disappears, then a sync makes it
        // reappear in the inbox, then a later sync removes it again. The mirror is
        // per-message and last-writer-wins, while archive is a thread-level verb.
        // A sibling message that has no write-back row of its own — a new reply, a
        // second folder copy under a different message_key, or a sibling whose
        // action already reaped — used to slip past the (then message-keyed) guard
        // and flip the whole conversation back to Open. The guard is now
        // conversation-scoped, so any settling write-back on the thread protects
        // every message in it.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        // A two-message thread, both read and in the inbox (status "open").
        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "Notulen"), &gmail_pid("g1"))
            .unwrap();
        store
            .upsert_synced_message(
                &acct,
                &folder,
                &make_msg("<m2@x>", Some("<m1@x>"), "Re: Notulen"),
                &gmail_pid("g2"),
            )
            .unwrap();
        assert_eq!(conv_count(&store, &acct), 1, "messages must thread into one conversation");

        // User archives the thread: optimistic Archived + a write-back enqueued for
        // m1 only. m2 has no live action of its own (its action already reaped, or
        // it never had a provider-state row at archive time).
        let conv_key = conv_key_for(&store, &acct);
        let m1_key = message_key_for_header(&store, &acct, "<m1@x>");
        store
            .set_conversation_status(&conv_key, Some(ConversationStatus::Archived), None)
            .unwrap();
        enqueue_pending(&store, &acct, &m1_key, ActionType::Archive);

        // A pre-mutation sync re-pulls the *sibling* m2: still in the inbox,
        // archived=false. With a message-keyed guard this had no matching action
        // and the mirror flipped the conversation back to Open.
        let mut stale_sibling = make_msg("<m2@x>", Some("<m1@x>"), "Re: Notulen");
        stale_sibling.flags.read = true;
        stale_sibling.flags.archived = false;
        store
            .upsert_synced_message(&acct, &folder, &stale_sibling, &gmail_pid("g2"))
            .unwrap();

        assert_eq!(
            conv_status_read(&store, &acct).0,
            "archived",
            "an unguarded sibling sync resurrected the archived thread"
        );
    }

    #[test]
    fn completed_writeback_stops_blocking_once_provider_flags_agree() {
        // Once the provider's flags reflect the action's intent, the guard must
        // release: the mirror is then a no-op for the action, and genuine later
        // provider changes must propagate again.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        let mut msg = make_msg("<m1@x>", None, "Hello");
        msg.flags.read = true;
        store
            .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
            .unwrap();
        let msg_key = message_key_for(&store, &acct);
        let conv_key = conv_key_for(&store, &acct);

        store
            .set_conversation_status(&conv_key, Some(ConversationStatus::Archived), None)
            .unwrap();
        enqueue_completed(&store, &acct, &msg_key, ActionType::Archive);

        // Provider has now settled to archived=true: flags AGREE with intent, so
        // the mirror runs (still archived) and the guard is released.
        let mut settled = make_msg("<m1@x>", None, "Hello");
        settled.flags.read = true;
        settled.flags.archived = true;
        store
            .upsert_synced_message(&acct, &folder, &settled, &gmail_pid("g1"))
            .unwrap();
        assert_eq!(conv_status_read(&store, &acct).0, "archived");

        // A subsequent genuine remote un-archive must now propagate — proving the
        // completed action no longer blocks the mirror.
        let mut reopened = make_msg("<m1@x>", None, "Hello");
        reopened.flags.read = true;
        reopened.flags.archived = false;
        store
            .upsert_synced_message(&acct, &folder, &reopened, &gmail_pid("g1"))
            .unwrap();
        assert_eq!(
            conv_status_read(&store, &acct).0,
            "open",
            "settled action should no longer block a genuine remote change"
        );
    }

    #[test]
    fn failed_writeback_does_not_block_mirror() {
        // A permanently failed write-back never reached the provider, so the
        // provider's flags are the truth and the mirror must run.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");

        let mut msg = make_msg("<m1@x>", None, "Hello");
        msg.flags.read = true;
        store
            .upsert_synced_message(&acct, &folder, &msg, &gmail_pid("g1"))
            .unwrap();
        let msg_key = message_key_for(&store, &acct);
        let conv_key = conv_key_for(&store, &acct);

        store
            .set_conversation_status(&conv_key, Some(ConversationStatus::Trash), None)
            .unwrap();
        let key = enqueue_completed(&store, &acct, &msg_key, ActionType::Trash);
        store
            .update_action_status(&key, &ActionStatus::Failed, 10, None, Some("boom"))
            .unwrap();

        // Provider still has the message in the inbox; with the action failed,
        // local state must fall back to the provider truth.
        let mut provider = make_msg("<m1@x>", None, "Hello");
        provider.flags.read = true;
        store
            .upsert_synced_message(&acct, &folder, &provider, &gmail_pid("g1"))
            .unwrap();
        assert_eq!(conv_status_read(&store, &acct).0, "open");
    }

    #[test]
    fn cleanup_retains_completed_actions_within_settle_grace() {
        // Cleanup must keep just-completed actions (the guard relies on them) and
        // only reap those past the settle grace.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);

        let recent = enqueue_completed(&store, &acct, "msg_recent", ActionType::Trash);
        let stale = enqueue_completed(&store, &acct, "msg_stale", ActionType::Archive);
        // Backdate the stale action's updated_at well past the grace window.
        {
            let conn = store.conn.lock();
            conn.execute(
                "UPDATE writeback_actions SET updated_at = ?1 WHERE key = ?2",
                params!["2000-01-01T00:00:00+00:00", stale],
            )
            .unwrap();
        }

        let deleted = store.delete_completed_actions().unwrap();
        assert_eq!(deleted, 1, "only the stale completed action should be reaped");

        let conn = store.conn.lock();
        let remaining: Vec<String> = conn
            .prepare("SELECT key FROM writeback_actions ORDER BY key")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(remaining, vec![recent], "recent completed action must survive");
    }

    #[test]
    fn syncing_sent_copy_does_not_resurrect_archived_thread() {
        // Regression: an archived thread must not reappear in the inbox when its
        // Sent copy is (re)synced. A Sent message always reports archived=false
        // (its folder role isn't Archive), so mirroring its flags would flip the
        // conversation back to Open. The Sent/Drafts folders are excluded from
        // the status mirror precisely to prevent this.
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let inbox = make_folder(&store, &acct, "inbox");
        let sent = make_folder(&store, &acct, "sent");

        // Inbound message lands in the inbox → conversation Open.
        store
            .upsert_synced_message(&acct, &inbox, &make_msg("<m1@x>", None, "Project"), &gmail_pid("g1"))
            .unwrap();

        // The thread gets archived (remote archive mirrored from the Archive copy).
        let mut archived = make_msg("<m1@x>", None, "Project");
        archived.flags.archived = true;
        store
            .upsert_synced_message(&acct, &inbox, &archived, &gmail_pid("g1"))
            .unwrap();
        assert_eq!(conv_status_read(&store, &acct).0, "archived");

        // A Sent reply threads into the same conversation. Its folder is Sent, so
        // its archived=false flags must NOT drag the conversation back to Open.
        let mut reply = make_msg("<m2@x>", Some("<m1@x>"), "Re: Project");
        reply.flags.read = true;
        store
            .upsert_synced_message(&acct, &sent, &reply, &gmail_pid("g2"))
            .unwrap();

        assert_eq!(
            conv_status_read(&store, &acct).0,
            "archived",
            "syncing the Sent reply must not resurrect the archived thread"
        );
    }

    // ---- Account deletion --------------------------------------------------

    fn provider_state_count(store: &SyncStore, account_key: &str) -> i64 {
        let conn = store.conn.lock();
        conn.query_row(
            "SELECT COUNT(*) FROM message_provider_state WHERE account_key = ?1",
            params![account_key],
            |r| r.get(0),
        )
        .unwrap()
    }

    #[test]
    fn delete_account_removes_all_scoped_rows() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let other = make_account(&store, "b@y.com", ProviderType::Gmail);
        let folder = make_folder(&store, &acct, "inbox");
        let other_folder = make_folder(&store, &other, "inbox");
        store
            .upsert_synced_message(&acct, &folder, &make_msg("<m1@x>", None, "Hi"), &gmail_pid("g1"))
            .unwrap();
        store
            .upsert_synced_message(&other, &other_folder, &make_msg("<m2@y>", None, "Yo"), &gmail_pid("g2"))
            .unwrap();

        store.delete_account(&acct).unwrap();

        // The deleted account's rows are all gone, across every scoped table.
        assert_eq!(msg_count(&store, &acct), 0);
        assert_eq!(conv_count(&store, &acct), 0);
        assert_eq!(provider_state_count(&store, &acct), 0);
        assert!(store.get_account(&acct).unwrap().is_none());

        // The untouched account is fully intact (no over-broad deletion).
        assert_eq!(msg_count(&store, &other), 1);
        assert_eq!(conv_count(&store, &other), 1);
        assert!(store.get_account(&other).unwrap().is_some());
    }

    // ---- Attachment path safety --------------------------------------------

    #[test]
    fn message_attachment_path_strips_traversal() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let msg_dir = store
            .resolve_attachment_cache_dir(&acct)
            .unwrap()
            .join("msg_1");

        // A malicious filename must not escape the per-message cache dir.
        for evil in ["../../etc/passwd", "/etc/passwd", "../escape.txt"] {
            let path = store.message_attachment_path(&acct, "msg_1", evil);
            assert!(
                path.starts_with(&msg_dir),
                "{evil} escaped the cache dir: {}",
                path.display()
            );
            assert_eq!(path.parent().unwrap(), msg_dir);
        }
    }

    #[test]
    fn cache_message_attachment_writes_under_message_dir() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let path = store
            .cache_message_attachment(&acct, "msg_1", "report.pdf", b"hello")
            .unwrap();
        assert!(path.ends_with("report.pdf"));
        // Namespaced by message so same-named files on different messages differ.
        assert_eq!(path.parent().unwrap().file_name().unwrap(), "msg_1");
        assert_eq!(std::fs::read(&path).unwrap(), b"hello");
    }

    // ---- Outbox ------------------------------------------------------------

    fn make_outbox_entry(account_key: &str, to: &str) -> OutboxMessage {
        OutboxMessage {
            key: format!("obx_{to}"),
            account_key: account_key.to_string(),
            kind: OutboxKind::Send,
            draft_key: None,
            message: OutgoingMessage {
                from_address: "me@x.com".into(),
                to_address: to.into(),
                cc_address: None,
                bcc_address: None,
                subject: Some("Hi".into()),
                body_html: None,
                body_plain: Some("body".into()),
                attachments: Vec::new(),
                ..Default::default()
            },
            status: OutboxStatus::Pending,
            retry_count: 0,
            max_retries: 10,
            next_retry_at: None,
            provider_message_id: None,
            error_message: None,
        }
    }

    #[test]
    fn local_event_row_is_replaced_by_the_synced_copy() {
        use crate::sync::calendar::{UnifiedCalendar, UnifiedEvent};
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        store
            .upsert_calendar(
                &acct,
                "google",
                &UnifiedCalendar {
                    key: "cal1".into(),
                    provider_id: "primary".into(),
                    name: "Me".into(),
                    color: "#fff".into(),
                    is_primary: true,
                    is_writable: true,
                    is_owned: true,
                    conference_providers: vec![],
                },
            )
            .unwrap();
        // What create_calendar_event writes the moment the provider accepts it.
        let mut ev = UnifiedEvent {
            provider_id: "gid1".into(),
            title: "Standup".into(),
            start_at: "2026-09-16T10:00:00+02:00".into(),
            end_at: "2026-09-16T11:00:00+02:00".into(),
            status: "confirmed".into(),
            ..Default::default()
        };
        store.upsert_event(&acct, "cal1", &ev).unwrap();

        // The resync a moment later, carrying what only the provider knows.
        ev.title = "Standup".into();
        ev.etag = Some("etag-1".into());
        ev.location = Some("https://meet.google.com/abc-defg-hij".into());
        store.upsert_event(&acct, "cal1", &ev).unwrap();

        // The engine resolves that same calendar_key from the provider id it
        // created against; without a match there is no row to draw.
        assert_eq!(
            store.calendar_key_for_provider_id(&acct, "primary").unwrap().as_deref(),
            Some("cal1")
        );

        let conn = store.conn.lock();
        let (rows, location): (i64, Option<String>) = conn
            .query_row(
                "SELECT (SELECT COUNT(*) FROM calendar_events WHERE account_key = ?1), location
                 FROM calendar_events WHERE account_key = ?1",
                params![acct],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        // One event, not the user's copy plus the provider's.
        assert_eq!(rows, 1);
        assert_eq!(location.as_deref(), Some("https://meet.google.com/abc-defg-hij"));
    }

    #[test]
    fn calendar_conference_providers_roundtrip() {
        use crate::sync::calendar::UnifiedCalendar;
        let store = SyncStore::new_in_memory().unwrap();
        let cal = |key: &str, providers: Vec<String>| UnifiedCalendar {
            key: key.into(),
            provider_id: "pid".into(),
            name: "Calendar".into(),
            color: "#fff".into(),
            is_primary: true,
            is_writable: true,
            is_owned: true,
            conference_providers: providers,
        };
        store.upsert_calendar("acc", "google", &cal("c1", vec!["meet".into()])).unwrap();
        // A mailbox that can mint nothing is a real answer, not "unknown".
        store.upsert_calendar("acc", "microsoft", &cal("c2", vec![])).unwrap();

        let back = store.get_calendars_for_account("acc").unwrap();
        let c1 = back.iter().find(|c| c.key == "c1").unwrap();
        let c2 = back.iter().find(|c| c.key == "c2").unwrap();
        assert_eq!(c1.conference_providers, vec!["meet".to_string()]);
        assert!(c2.conference_providers.is_empty());

        // The list is re-read from the provider on every sync, so an upsert
        // must overwrite it — not leave yesterday's answer standing.
        store.upsert_calendar("acc", "google", &cal("c1", vec![])).unwrap();
        let back = store.get_calendars_for_account("acc").unwrap();
        assert!(back.iter().find(|c| c.key == "c1").unwrap().conference_providers.is_empty());
    }

    #[test]
    fn outbox_enqueue_then_pending_roundtrips_payload() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        store
            .enqueue_outbox(&make_outbox_entry(&acct, "you@x.com"))
            .unwrap();

        let pending = store.get_pending_outbox(&acct).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].message.to_address, "you@x.com");
        assert_eq!(pending[0].status, OutboxStatus::Pending);
    }

    #[test]
    fn outbox_mark_sent_hides_from_pending_and_cleans_up() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let entry = make_outbox_entry(&acct, "you@x.com");
        store.enqueue_outbox(&entry).unwrap();

        store
            .update_outbox_status(&entry.key, &OutboxStatus::Sent, 0, None, Some("pmid_1"), None)
            .unwrap();

        // Sent entries are no longer eligible for delivery...
        assert!(store.get_pending_outbox(&acct).unwrap().is_empty());
        // ...but remain listable (with the provider id) until cleanup.
        let listed = store.list_outbox(&acct).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].status, OutboxStatus::Sent);
        assert_eq!(listed[0].provider_message_id.as_deref(), Some("pmid_1"));

        assert_eq!(store.delete_sent_outbox().unwrap(), 1);
        assert!(store.list_outbox(&acct).unwrap().is_empty());
    }

    #[test]
    fn outbox_claim_is_exclusive_and_hides_from_pending() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let entry = make_outbox_entry(&acct, "you@x.com");
        store.enqueue_outbox(&entry).unwrap();

        // First claim wins; a racing second claim loses (no double-send).
        assert!(store.claim_outbox_for_send(&entry.key).unwrap());
        assert!(!store.claim_outbox_for_send(&entry.key).unwrap());

        // A freshly-claimed ('sending') entry is not handed out again by the
        // drain query until it goes stale.
        assert!(store.get_pending_outbox(&acct).unwrap().is_empty());
    }

    #[test]
    fn outbox_backoff_retry_excludes_until_window_then_includes() {
        let store = SyncStore::new_in_memory().unwrap();
        let acct = make_account(&store, "a@x.com", ProviderType::Gmail);
        let entry = make_outbox_entry(&acct, "you@x.com");
        store.enqueue_outbox(&entry).unwrap();

        // A future retry window hides the entry from the pending drain.
        let future = (Utc::now() + chrono::Duration::seconds(120)).to_rfc3339();
        store
            .update_outbox_status(
                &entry.key,
                &OutboxStatus::Pending,
                1,
                Some(&future),
                None,
                Some("temporary failure"),
            )
            .unwrap();
        assert!(store.get_pending_outbox(&acct).unwrap().is_empty());

        // A past window makes it eligible again, error message preserved.
        let past = (Utc::now() - chrono::Duration::seconds(1)).to_rfc3339();
        store
            .update_outbox_status(&entry.key, &OutboxStatus::Pending, 1, Some(&past), None, Some("temporary failure"))
            .unwrap();
        let pending = store.get_pending_outbox(&acct).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].retry_count, 1);
        assert_eq!(pending[0].error_message.as_deref(), Some("temporary failure"));
    }

    #[test]
    fn reauth_prompt_claim_is_rate_limited_per_account() {
        let store = SyncStore::new_in_memory().unwrap();

        // First failure prompts; every later sync tick within the window is quiet.
        assert!(store.claim_reauth_prompt("acct-a"));
        assert!(!store.claim_reauth_prompt("acct-a"));

        // The budget is per account, not global.
        assert!(store.claim_reauth_prompt("acct-b"));

        // Once the cooldown lapses (stamp aged past the window), it prompts again.
        let stale = (Utc::now() - chrono::Duration::seconds(301)).to_rfc3339();
        store.set_engine_setting("reauth_prompted_at:acct-a", &stale).unwrap();
        assert!(store.claim_reauth_prompt("acct-a"));
    }
}

