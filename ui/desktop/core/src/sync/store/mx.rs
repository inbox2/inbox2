//! The MX mirror — local copy of inbox2-hosted mail (docs/MX-Sync.md).
//!
//! Storage only: what a sync client (`sync::mx_sync`, next) applies, and the rules
//! that keep it correct no matter what order pages arrive in —
//!
//!   * **version guard** — a record is applied only if its `change_seq` is at
//!     least the held one, so backfill, delta and hydrate can race freely;
//!   * **settle guard** — a thread with a queued action keeps its optimistic local
//!     state; once the action has landed, server records are accepted again as
//!     soon as they *agree* with it (a page read before the write doesn't, and is
//!     held back for [`DONE_GRACE`]). Anything held back marks the thread for
//!     re-hydration, and the guard lapses after [`SETTLE_WINDOW`]: sync never
//!     depends on a queue row being cleaned up;
//!   * **full threads replace** — a page of whole threads (backfill, hydrate)
//!     deletes children it didn't list, so a missed tombstone cannot linger;
//!   * **reconcile** — the server's key list is the truth about what exists.
//!
//! Records are the API's JSON, stored verbatim in `payload`.

use rusqlite::{params, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::SyncStore;
use crate::sync::error::Result;

/// Bump when any `mx_*` table, index or trigger in the schema file changes shape.
/// An older database then drops the mirror and re-syncs it — see the schema file.
const MX_SCHEMA_VERSION: &str = "2";

/// Drop a mirror built by an older schema — atomically, so another connection to
/// the same file (the webview, a second instance, the CLI) sees the old tables or
/// none, never half. The queue of user actions is not part of the mirror and is
/// left alone. If the drop can't get the database (busy past the timeout), opening
/// the store fails rather than carrying on into a schema batch whose indexes name
/// columns the old tables don't have.
pub(super) fn reset_if_outdated(conn: &rusqlite::Connection) -> Result<()> {
    // Both reads fail on a brand-new database (no tables yet): nothing to reset.
    let held: Option<String> = conn
        .query_row("SELECT value FROM engine_settings WHERE key = 'mx_schema_version'", [], |r| r.get(0))
        .ok();
    let mirrored: bool = conn
        .query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'mx_conversations')", [], |r| r.get(0))
        .unwrap_or(false);
    if mirrored && held.as_deref() != Some(MX_SCHEMA_VERSION) {
        log::info!("[mx] mirror schema {held:?} → {MX_SCHEMA_VERSION}: dropping the local mirror, it will re-sync");
        conn.execute_batch(
            "BEGIN IMMEDIATE;
             DROP VIEW IF EXISTS agent_conversations; DROP VIEW IF EXISTS agent_messages;
             DROP TABLE IF EXISTS mx_messages_fts; DROP TABLE IF EXISTS mx_notes; DROP TABLE IF EXISTS mx_messages;
             DROP TABLE IF EXISTS mx_conversations; DROP TABLE IF EXISTS mx_directory; DROP TABLE IF EXISTS mx_sync_state;
             COMMIT;",
        )?;
    }
    Ok(())
}

pub(super) fn stamp_schema_version(conn: &rusqlite::Connection) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO engine_settings (key, value) VALUES ('mx_schema_version', ?1)",
        params![MX_SCHEMA_VERSION],
    )?;
    Ok(())
}

/// What local search indexes for one message: subject, people, and the body as
/// text (HTML rendered to text: block tags break words, entities decoded — a bare
/// `ammonia` strip glued "Reconi</p><p>Heeft" into one token and kept `&nbsp;`).
fn search_text(subject: Option<&str>, people: &[Option<&str>], plain: Option<&str>, html: Option<&str>) -> String {
    let body = match plain {
        Some(p) if !p.trim().is_empty() => p.to_string(),
        _ => html.map(crate::sync::threading::html_to_text).unwrap_or_default(),
    };
    let mut parts: Vec<&str> = subject.into_iter().chain(people.iter().flatten().copied()).collect();
    parts.push(&body);
    parts.join("\n")
}

/// `records` of a `sync/pull` or `sync/backfill` page.
#[derive(Debug, Default, Clone, Deserialize)]
pub struct MxRecords {
    #[serde(default)]
    pub conversations: Vec<Value>,
    #[serde(default)]
    pub messages: Vec<Value>,
    #[serde(default)]
    pub notes: Vec<Value>,
}

/// One entry of a pull's `deleted`.
#[derive(Debug, Clone, Deserialize)]
pub struct MxDeleted {
    #[serde(rename = "type")]
    pub record_type: String,
    pub id: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct MxSyncState {
    pub user_key: String,
    pub cursor: Option<String>,
    pub backfill_token: Option<String>,
    pub backfill_done: bool,
    pub reconciled_at: Option<String>,
    pub directory_at: Option<String>,
}

/// What a reconcile pass changed and what it still needs fetched.
#[derive(Debug, Default, PartialEq)]
pub struct MxReconcile {
    pub removed: usize,
    /// Threads the server has that are held here at an older version (or unhydrated).
    pub hydrate: Vec<String>,
    /// Threads the server has that aren't held at all. While history is still
    /// being read these are just "not backfilled yet" — the caller ignores them
    /// then, and hydrates them once backfill is complete.
    pub absent: Vec<String>,
}

/// How long a queued write-back shields its thread from server state. Long
/// enough for a retry or two; after that the server wins and the action, if it
/// ever lands, re-stamps the thread anyway.
const SETTLE_WINDOW: &str = "-15 minutes";

const SETTLING: &str = "EXISTS(SELECT 1 FROM mx_writeback_actions a
    WHERE a.conversation_id = ?1 AND a.org_id = ?2 AND a.status IN ('pending', 'sending')
      AND a.created_at > datetime('now', ?3))";

/// How long a *landed* action still vets incoming records — outlasts a pull that
/// was already in flight when the write landed (a request lives 60s at most). Kept
/// short on purpose: for this long a teammate's genuine counter-change (they
/// re-open what you archived) is held back too, then arrives by hydration.
const DONE_GRACE: &str = "-60 seconds";

/// Conversation actions (the bulk endpoint's `action_name`s) and the local state
/// each one means. The one place the optimistic write, the agreement check and
/// the queue agree on what an action does.
pub const MX_ACTIONS: &[(&str, Option<&str>, Option<bool>)] = &[
    ("archive", Some("archived"), None),
    ("trash", Some("trash"), None),
    ("spam", Some("spam"), None),
    ("open", Some("open"), None),
    ("mark_read", None, Some(true)),
    ("mark_unread", None, Some(false)),
    // Permanent, server-side only for threads already in trash/spam; queued after
    // a "trash" so the order makes it so. Reads as trash until the tombstone lands.
    ("delete", Some("trash"), None),
    // Lore's per-member tick (docs/TODO.md 48.11): neither status nor read moves, only
    // the member's `lore_done` flag in the payload (see `lore_intent`).
    ("lore_done", None, None),
    ("lore_undone", None, None),
];

fn lore_intent(action: &str) -> Option<bool> {
    match action {
        "lore_done" => Some(true),
        "lore_undone" => Some(false),
        _ => None,
    }
}

fn intent(action: &str) -> Option<(Option<&'static str>, Option<bool>)> {
    MX_ACTIONS.iter().find(|(name, ..)| *name == action).map(|(_, status, read)| (*status, *read))
}

/// A queued action claimed for sending: one request's worth.
#[derive(Debug, Clone, PartialEq)]
pub struct MxActionBatch {
    pub ids: Vec<i64>,
    pub org: String,
    pub action: String,
    pub conversations: Vec<String>,
}

/// `sending` rows older than this were abandoned by a killed process.
const STALE_SENDING: &str = "-120 seconds";
const ACTION_BATCH: usize = 100;

/// User text → an FTS5 query that can't be a syntax error: every word quoted (so
/// `AND`, `-`, `:` and friends are just characters) and prefix-matched. `None` when
/// nothing searchable is left.
pub fn fts_query(input: &str) -> Option<String> {
    let words: Vec<String> = input
        .split_whitespace()
        .map(|w| w.replace('"', ""))
        .filter(|w| w.chars().any(char::is_alphanumeric))
        .map(|w| format!("\"{w}\"*"))
        .collect();
    (!words.is_empty()).then(|| words.join(" "))
}

fn text<'a>(v: &'a Value, field: &str) -> Option<&'a str> {
    v.get(field).and_then(Value::as_str)
}

fn seq(v: &Value) -> i64 {
    v.get("change_seq").and_then(Value::as_i64).unwrap_or(0)
}

impl SyncStore {
    /// Start (or resume) mirroring `org` as `user_key`. A different user than the
    /// one the mirror was built for wipes it first: visibility is per member.
    pub fn mx_begin(&self, org: &str, user_key: &str) -> Result<MxSyncState> {
        if let Some(state) = self.mx_state(org)? {
            if state.user_key == user_key {
                return Ok(state);
            }
        }
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        wipe(&tx, org)?;
        tx.execute(
            "INSERT INTO mx_sync_state (organization_id, user_key) VALUES (?1, ?2)",
            params![org, user_key],
        )?;
        tx.commit()?;
        Ok(MxSyncState { user_key: user_key.to_string(), ..Default::default() })
    }

    /// One batch of re-deriving `search_text` for plaintext HTML-only MX mail
    /// indexed before [`search_text`] rendered HTML properly. Same paging contract
    /// as `backfill_html_body_text`: the last id visited, `None` once exhausted.
    pub fn mx_reindex_html_search_text(&self, after: i64, limit: usize) -> Result<Option<i64>> {
        let rows: Vec<(i64, String)> = {
            let conn = self.conn.lock();
            let mut stmt = conn.prepare(
                "SELECT id, payload FROM mx_messages
                 WHERE id > ?1 AND sealed = 0 AND COALESCE(json_extract(payload, '$.body_plain'), '') = ''
                 ORDER BY id LIMIT ?2",
            )?;
            let rows = stmt.query_map(params![after, limit as i64], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        let Some(&(last, _)) = rows.last() else { return Ok(None) };
        let texts: Vec<(i64, String)> = rows
            .iter()
            .filter_map(|(id, payload)| {
                let v: Value = serde_json::from_str(payload).ok()?;
                text(&v, "body_html")?;
                Some((*id, search_text(text(&v, "subject"), &[text(&v, "from_address"), text(&v, "to_address"), text(&v, "cc_address")],
                                       None, text(&v, "body_html"))))
            })
            .collect();
        let conn = self.conn.lock();
        for (id, indexed) in texts {
            conn.execute("UPDATE mx_messages SET search_text = ?1 WHERE id = ?2", params![indexed, id])?;
        }
        Ok(Some(last))
    }

    pub fn mx_state(&self, org: &str) -> Result<Option<MxSyncState>> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT user_key, cursor, backfill_token, backfill_done, reconciled_at, directory_at
                 FROM mx_sync_state WHERE organization_id = ?1",
                params![org],
                |r| {
                    Ok(MxSyncState {
                        user_key: r.get(0)?,
                        cursor: r.get(1)?,
                        backfill_token: r.get(2)?,
                        backfill_done: r.get::<_, i64>(3)? != 0,
                        reconciled_at: r.get(4)?,
                        directory_at: r.get(5)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn mx_set_cursor(&self, org: &str, cursor: &str) -> Result<()> {
        self.conn.lock().execute(
            "UPDATE mx_sync_state SET cursor = ?2 WHERE organization_id = ?1",
            params![org, cursor],
        )?;
        Ok(())
    }

    /// `token = None` means history is complete.
    pub fn mx_set_backfill(&self, org: &str, token: Option<&str>) -> Result<()> {
        self.conn.lock().execute(
            "UPDATE mx_sync_state SET backfill_token = ?2, backfill_done = ?3 WHERE organization_id = ?1",
            params![org, token, token.is_none() as i64],
        )?;
        Ok(())
    }

    /// Apply one page. `full_threads` = every conversation in it came with its
    /// whole message/note set (`sync/backfill`, `sync/threads`): children the page
    /// doesn't list are deleted, so a missed tombstone cannot linger. A delta page
    /// is `false`, and a thread first seen there stays `hydrated = 0`.
    /// Returns the threads that still need hydrating.
    pub fn mx_apply(&self, org: &str, records: &MxRecords, full_threads: bool) -> Result<Vec<String>> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let mut current = Vec::new();
        for c in &records.conversations {
            if upsert_conversation(&tx, org, c, full_threads)? {
                current.extend(text(c, "id"));
            }
        }
        for m in &records.messages {
            upsert_child(&tx, org, "mx_messages", m)?;
        }
        for n in &records.notes {
            upsert_child(&tx, org, "mx_notes", n)?;
        }
        if full_threads {
            // Only for threads this page is the newest word on: the thread version
            // covers its children, so an older page must not prune what a newer
            // delta already added.
            for (table, listed) in [("mx_messages", &records.messages), ("mx_notes", &records.notes)] {
                let listed: std::collections::HashSet<&str> = listed.iter().filter_map(|v| text(v, "id")).collect();
                for thread in &current {
                    let held: Vec<String> = tx
                        .prepare(&format!("SELECT key FROM {table} WHERE conversation_key = ?1"))?
                        .query_map(params![thread], |r| r.get(0))?
                        .collect::<rusqlite::Result<_>>()?;
                    for gone in held.iter().filter(|k| !listed.contains(k.as_str())) {
                        tx.execute(&format!("DELETE FROM {table} WHERE key = ?1"), params![gone])?;
                    }
                }
            }
        }
        let pending = unhydrated(&tx, org)?;
        tx.commit()?;
        Ok(pending)
    }

    /// Threads `sync/threads` reported as not visible: gone, whatever we held.
    pub fn mx_drop_threads(&self, org: &str, keys: &[String]) -> Result<()> {
        let deleted: Vec<MxDeleted> =
            keys.iter().map(|k| MxDeleted { record_type: "conversation".into(), id: k.clone() }).collect();
        self.mx_apply_deleted(org, &deleted)
    }

    pub fn mx_apply_deleted(&self, org: &str, deleted: &[MxDeleted]) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        for d in deleted {
            let table = match d.record_type.as_str() {
                // Cascades to the children still pointing at it. A merge re-parents
                // its children at lower cursor positions, so they survive.
                "conversation" => "mx_conversations",
                "message" => "mx_messages",
                "note" => "mx_notes",
                _ => continue,
            };
            tx.execute(
                &format!("DELETE FROM {table} WHERE key = ?1 AND organization_id = ?2"),
                params![d.id, org],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// `server` is the complete `sync/keys` listing: `(thread key, version)`;
    /// `listing_started` is [`SyncStore::mx_now`] taken before fetching its first
    /// page. Rows applied since then are left alone — they may postdate the listing.
    pub fn mx_reconcile(&self, org: &str, server: &[(String, i64)], listing_started: &str) -> Result<MxReconcile> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let held: std::collections::HashMap<String, (i64, bool)> = tx
            .prepare("SELECT key, change_seq, hydrated FROM mx_conversations WHERE organization_id = ?1")?
            .query_map(params![org], |r| Ok((r.get(0)?, (r.get(1)?, r.get::<_, i64>(2)? != 0))))?
            .collect::<rusqlite::Result<_>>()?;
        let listed: std::collections::HashSet<&str> = server.iter().map(|(k, _)| k.as_str()).collect();

        let mut out = MxReconcile::default();
        for key in held.keys().filter(|k| !listed.contains(k.as_str())) {
            out.removed += tx.execute(
                "DELETE FROM mx_conversations WHERE key = ?1 AND organization_id = ?2 AND applied_at < ?3",
                params![key, org, listing_started],
            )?;
        }
        for (key, version) in server {
            match held.get(key) {
                // Held at this version or newer (the listing can be the stale side).
                Some((held_version, true)) if held_version >= version => {}
                Some(_) => out.hydrate.push(key.clone()),
                None => out.absent.push(key.clone()),
            }
        }
        tx.execute(
            "UPDATE mx_sync_state SET reconciled_at = ?2 WHERE organization_id = ?1",
            params![org, chrono::Utc::now().to_rfc3339()],
        )?;
        tx.commit()?;
        Ok(out)
    }

    /// Replace one directory listing (`type` = "domains", "tags", …) wholesale.
    pub fn mx_directory_replace(&self, org: &str, kind: &str, items: &[Value]) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM mx_directory WHERE organization_id = ?1 AND type = ?2", params![org, kind])?;
        for (position, item) in items.iter().enumerate() {
            let Some(key) = text(item, "id") else { continue };
            tx.execute(
                "INSERT OR REPLACE INTO mx_directory (organization_id, type, key, position, payload)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![org, kind, key, position as i64, item.to_string()],
            )?;
        }
        tx.execute(
            "UPDATE mx_sync_state SET directory_at = ?2 WHERE organization_id = ?1",
            params![org, chrono::Utc::now().to_rfc3339()],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Sign-out, identity switch, or a lost grant: the org's mail leaves the device.
    pub fn mx_wipe(&self, org: &str) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        wipe(&tx, org)?;
        tx.commit()?;
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn mx_count_for_test(&self, table: &str) -> i64 {
        self.conn.lock().query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0)).unwrap()
    }

    #[cfg(test)]
    pub(crate) fn mx_first_thread_status_for_test(&self, org: &str) -> String {
        self.conn.lock().query_row(
            "SELECT status FROM mx_conversations WHERE organization_id = ?1 ORDER BY key LIMIT 1",
            params![org], |r| r.get(0)).unwrap()
    }

    #[cfg(test)]
    pub(crate) fn mx_make_actions_due_for_test(&self) {
        self.conn.lock().execute("UPDATE mx_writeback_actions SET next_retry_at = datetime('now', '-1 second')", []).unwrap();
    }

    #[cfg(test)]
    pub(crate) fn mx_first_thread_for_test(&self, org: &str) -> (String, i64) {
        self.conn.lock().query_row(
            "SELECT key, read FROM mx_conversations WHERE organization_id = ?1 ORDER BY key LIMIT 1",
            params![org], |r| Ok((r.get(0)?, r.get(1)?))).unwrap()
    }

    /// Apply `action` to `threads` locally — columns and payload, so every reader
    /// sees it at once — and queue it for the server. Unknown actions are refused.
    pub fn mx_enqueue_action(&self, org: &str, threads: &[String], action: &str) -> Result<()> {
        let Some((status, read)) = intent(action) else {
            return Err(crate::sync::error::SyncError::Other(format!("unknown mx action: {action}")));
        };
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        for key in threads {
            if let Some(status) = status {
                tx.execute(
                    "UPDATE mx_conversations SET status = ?3, payload = json_set(payload, '$.status', ?3)
                     WHERE key = ?1 AND organization_id = ?2",
                    params![key, org, status],
                )?;
            }
            if let Some(read) = read {
                tx.execute(
                    "UPDATE mx_conversations SET read = ?3,
                       payload = json_set(payload, '$.read', json(CASE ?3 WHEN 1 THEN 'true' ELSE 'false' END))
                     WHERE key = ?1 AND organization_id = ?2",
                    params![key, org, read as i64],
                )?;
            }
            if let Some(done) = lore_intent(action) {
                tx.execute(
                    "UPDATE mx_conversations SET payload = json_set(payload, '$.lore_done', json(CASE ?3 WHEN 1 THEN 'true' ELSE 'false' END))
                     WHERE key = ?1 AND organization_id = ?2",
                    params![key, org, done as i64],
                )?;
            }
            tx.execute(
                "INSERT INTO mx_writeback_actions (org_id, conversation_id, action, status, next_retry_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, 'pending', datetime('now'), datetime('now'), datetime('now'))",
                params![org, key, action],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Claim the next request's worth of due actions: the oldest due row, plus
    /// every other due row with the same org + action — but only rows that are the
    /// oldest unfinished action for their thread, so "spam, then move to inbox"
    /// still lands in that order. Claiming is one UPDATE: two drainers can't both
    /// get a row.
    pub fn mx_claim_actions(&self) -> Result<Option<MxActionBatch>> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        tx.execute(
            "UPDATE mx_writeback_actions SET status = 'pending'
             WHERE status = 'sending' AND updated_at < datetime('now', ?1)",
            params![STALE_SENDING],
        )?;
        let due = "a.status = 'pending' AND (a.next_retry_at IS NULL OR a.next_retry_at <= datetime('now'))
             AND NOT EXISTS (SELECT 1 FROM mx_writeback_actions e
                             WHERE e.conversation_id = a.conversation_id AND e.id < a.id
                               AND e.status IN ('pending', 'sending'))";
        let head: Option<(String, String)> = tx
            .query_row(
                &format!("SELECT a.org_id, a.action FROM mx_writeback_actions a WHERE {due} ORDER BY a.id LIMIT 1"),
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let Some((org, action)) = head else {
            tx.commit()?; // the stale-claim reset above still counts
            return Ok(None);
        };
        let rows: Vec<(i64, String)> = tx
            .prepare(&format!(
                "UPDATE mx_writeback_actions SET status = 'sending', updated_at = datetime('now')
                 WHERE id IN (SELECT a.id FROM mx_writeback_actions a
                              WHERE {due} AND a.org_id = ?1 AND a.action = ?2 ORDER BY a.id LIMIT ?3)
                 RETURNING id, conversation_id"
            ))?
            .query_map(params![org, action, ACTION_BATCH as i64], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        tx.commit()?;
        let (ids, conversations) = rows.into_iter().unzip();
        Ok(Some(MxActionBatch { ids, org, action, conversations }))
    }

    /// Landed. Kept as `done` for [`DONE_GRACE`] so the settle guard can vet pages
    /// that were read before the write; older `done` rows are reaped here.
    pub fn mx_actions_done(&self, ids: &[i64]) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        for id in ids {
            tx.execute(
                "UPDATE mx_writeback_actions SET status = 'done', updated_at = datetime('now') WHERE id = ?1",
                params![id],
            )?;
        }
        tx.execute(
            "DELETE FROM mx_writeback_actions WHERE status = 'done' AND updated_at < datetime('now', ?1)",
            params![DONE_GRACE],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Didn't land. Transient → back to `pending` on the shared backoff curve.
    /// Permanent (or out of retries) → `failed`, kept for inspection, and the
    /// thread is marked for re-hydration so the optimistic state gives way to the
    /// server's.
    pub fn mx_actions_failed(&self, ids: &[i64], error: &str, permanent: bool) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        for id in ids {
            let (retries, max): (u32, u32) = tx.query_row(
                "SELECT retry_count, max_retries FROM mx_writeback_actions WHERE id = ?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            let retries = retries + 1;
            if permanent || retries >= max {
                tx.execute(
                    "UPDATE mx_writeback_actions SET status = 'failed', retry_count = ?2, error_message = ?3,
                       updated_at = datetime('now') WHERE id = ?1",
                    params![id, retries, error],
                )?;
                tx.execute(
                    "UPDATE mx_conversations SET hydrated = 0
                     WHERE key = (SELECT conversation_id FROM mx_writeback_actions WHERE id = ?1)",
                    params![id],
                )?;
            } else {
                tx.execute(
                    "UPDATE mx_writeback_actions SET status = 'pending', retry_count = ?2, error_message = ?3,
                       next_retry_at = datetime('now', ?4), updated_at = datetime('now') WHERE id = ?1",
                    params![id, retries, error, format!("+{} seconds", crate::sync::retry::next_backoff_secs(retries))],
                )?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// These threads' local state may be wrong (a bulk action the server only
    /// partly applied): fetch them again. One the server no longer shows is dropped.
    pub fn mx_mark_unhydrated(&self, org: &str, threads: &[String]) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        for key in threads {
            tx.execute(
                "UPDATE mx_conversations SET hydrated = 0 WHERE key = ?1 AND organization_id = ?2",
                params![key, org],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Sealed messages of `org` not opened yet, in key order after `after`:
    /// `(message key, sealed bundle)`. Paged by key so a run of mail no held key
    /// fits can't hide openable mail behind it.
    pub fn mx_unopened(&self, org: &str, after: &str, limit: usize) -> Result<Vec<(String, Value)>> {
        let conn = self.conn.lock();
        let rows: Vec<(String, String)> = conn
            .prepare(
                "SELECT key, json_extract(payload, '$.sealed') FROM mx_messages
                 WHERE organization_id = ?1 AND sealed = 1 AND plain IS NULL AND key > ?2
                   AND json_extract(payload, '$.sealed') IS NOT NULL ORDER BY key LIMIT ?3",
            )?
            .query_map(params![org, after, limit as i64], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows.into_iter().filter_map(|(k, s)| serde_json::from_str(&s).ok().map(|v| (k, v))).collect())
    }

    /// Store opened mail, and give each touched thread the list columns the server
    /// can't (a sealed thread's subject / sender / snippet are null in its payload):
    /// taken from its newest opened message. `payload` stays ciphertext, verbatim.
    pub fn mx_store_opened(&self, org: &str, opened: &[(String, Value, Value)]) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        for (key, header, body) in opened {
            let indexed = search_text(text(header, "subject"), &[text(header, "from"), text(header, "to"), text(header, "cc")],
                                      text(body, "plain"), text(body, "html"));
            tx.execute(
                "UPDATE mx_messages SET plain = ?3, search_text = ?4 WHERE key = ?1 AND organization_id = ?2",
                params![key, org, serde_json::json!({ "header": header, "body": body }).to_string(), indexed],
            )?;
        }
        tx.execute(
            "UPDATE mx_conversations SET
               subject = COALESCE(subject, (SELECT json_extract(m.plain, '$.header.subject') FROM mx_messages m
                  WHERE m.conversation_key = mx_conversations.key AND m.plain IS NOT NULL ORDER BY m.created_at DESC LIMIT 1)),
               from_address = COALESCE(from_address, (SELECT json_extract(m.plain, '$.header.from') FROM mx_messages m
                  WHERE m.conversation_key = mx_conversations.key AND m.plain IS NOT NULL ORDER BY m.created_at DESC LIMIT 1)),
               snippet = COALESCE(snippet, (SELECT json_extract(m.plain, '$.header.snippet') FROM mx_messages m
                  WHERE m.conversation_key = mx_conversations.key AND m.plain IS NOT NULL ORDER BY m.created_at DESC LIMIT 1))
             WHERE organization_id = ?1 AND subject IS NULL
               AND key IN (SELECT conversation_key FROM mx_messages WHERE organization_id = ?1 AND plain IS NOT NULL)",
            params![org],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Full-text search over the mirror: threads with a message matching every word
    /// (prefix-matched), newest first, as list payloads. Trash and spam never match,
    /// like the server's search. Works offline, and reaches opened sealed mail.
    pub fn mx_search(&self, org: &str, query: &str, limit: usize) -> Result<Vec<String>> {
        let Some(fts) = fts_query(query) else { return Ok(Vec::new()) };
        let conn = self.conn.lock();
        let rows = conn
            .prepare(
                "SELECT c.payload FROM mx_conversations c
                 WHERE c.organization_id = ?1 AND c.status NOT IN ('trash', 'spam')
                   AND c.key IN (SELECT m.conversation_key FROM mx_messages_fts f
                                 JOIN mx_messages m ON m.id = f.rowid
                                 WHERE mx_messages_fts MATCH ?2 AND m.organization_id = ?1)
                 ORDER BY c.updated_at DESC, c.key DESC LIMIT ?3",
            )?
            .query_map(params![org, fts, limit as i64], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// Every org with a mirror on this device, and whose view of it.
    pub fn mx_watched(&self) -> Result<Vec<(String, String)>> {
        let conn = self.conn.lock();
        let rows = conn
            .prepare("SELECT organization_id, user_key FROM mx_sync_state ORDER BY organization_id")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// The local clock in the format `applied_at` uses.
    pub fn mx_now() -> String {
        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Micros, true)
    }
}

fn wipe(tx: &Transaction, org: &str) -> Result<()> {
    for table in ["mx_conversations", "mx_directory", "mx_sync_state"] {
        tx.execute(&format!("DELETE FROM {table} WHERE organization_id = ?1"), params![org])?;
    }
    // Unsent actions were the previous user's; they can't be replayed as anyone
    // else, and left behind they would shield these threads from the new mirror.
    tx.execute("DELETE FROM mx_writeback_actions WHERE org_id = ?1", params![org])?;
    Ok(())
}

/// True when the record was applied (not held back by either guard).
fn upsert_conversation(tx: &Transaction, org: &str, c: &Value, full_thread: bool) -> Result<bool> {
    let Some(key) = text(c, "id") else { return Ok(false) };
    // Settle guard: a queued action owns this thread's state until it lands.
    let mut settling: bool =
        tx.query_row(&format!("SELECT {SETTLING}"), params![key, org, SETTLE_WINDOW], |r| r.get(0))?;
    if !settling {
        // The newest action that just landed: a record that disagrees with it was
        // read before the write and must not undo it on screen.
        let landed: Option<String> = tx
            .query_row(
                "SELECT action FROM mx_writeback_actions
                 WHERE conversation_id = ?1 AND org_id = ?2 AND status = 'done' AND updated_at > datetime('now', ?3)
                 ORDER BY id DESC LIMIT 1",
                params![key, org, DONE_GRACE],
                |r| r.get(0),
            )
            .optional()?;
        if let Some((status, read)) = landed.as_deref().and_then(intent) {
            settling = status.is_some_and(|s| text(c, "status") != Some(s))
                || read.is_some_and(|r| c.get("read").and_then(Value::as_bool) != Some(r))
                || landed.as_deref().and_then(lore_intent).is_some_and(|d| c.get("lore_done").and_then(Value::as_bool) != Some(d));
        }
    }
    if settling {
        // Whatever this page carried is fetched again once the action lands.
        tx.execute(
            "UPDATE mx_conversations SET hydrated = 0 WHERE key = ?1 AND organization_id = ?2",
            params![key, org],
        )?;
        return Ok(false);
    }
    // Backfill may hand over a thread from before change tracking (version 0);
    // the guard's `>=` lets equal versions through so that still refreshes.
    let applied = tx.execute(
        "INSERT INTO mx_conversations
           (key, organization_id, domain_key, status, read, subject, from_address, to_address, snippet,
            space_slug, triage_label, triage_priority, created_at, updated_at, change_seq, hydrated, payload,
            applied_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
         ON CONFLICT(key) DO UPDATE SET
           domain_key = excluded.domain_key, status = excluded.status, read = excluded.read,
           subject = excluded.subject, from_address = excluded.from_address,
           to_address = excluded.to_address, snippet = excluded.snippet,
           space_slug = excluded.space_slug, triage_label = excluded.triage_label,
           triage_priority = excluded.triage_priority, created_at = excluded.created_at,
           updated_at = excluded.updated_at, change_seq = excluded.change_seq,
           hydrated = MAX(hydrated, excluded.hydrated), payload = excluded.payload,
           applied_at = excluded.applied_at
         WHERE excluded.change_seq >= mx_conversations.change_seq
           AND excluded.organization_id = mx_conversations.organization_id",
        params![
            key,
            org,
            text(c, "domain_id"),
            text(c, "status"),
            c.get("read").and_then(Value::as_bool).unwrap_or(false) as i64,
            text(c, "subject"),
            text(c, "from_address"),
            text(c, "to_address"),
            text(c, "snippet"),
            c.get("space").and_then(|s| text(s, "slug")),
            text(c, "triage_label"),
            c.get("triage_priority").and_then(Value::as_f64),
            text(c, "created_at"),
            text(c, "updated_at"),
            seq(c),
            full_thread as i64,
            c.to_string(),
            SyncStore::mx_now(),
        ],
    )?;
    Ok(applied > 0)
}

/// A message or note. Skipped when its thread isn't held — the server always
/// ships the parent alongside, so that only happens for a thread the settle
/// guard or a concurrent delete kept out, and reconcile picks it up.
fn upsert_child(tx: &Transaction, org: &str, table: &str, v: &Value) -> Result<()> {
    let (Some(key), Some(thread)) = (text(v, "id"), text(v, "conversation_id")) else { return Ok(()) };
    let parent: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM mx_conversations WHERE key = ?1 AND organization_id = ?2)",
        params![thread, org],
        |r| r.get(0),
    )?;
    if !parent {
        return Ok(());
    }
    if table == "mx_messages" {
        let sealed = text(v, "encryption_scheme").is_some_and(|s| s != "none");
        // A sealed payload has nothing to index; its text arrives when it is opened.
        let indexed = (!sealed).then(|| {
            search_text(text(v, "subject"), &[text(v, "from_address"), text(v, "to_address"), text(v, "cc_address")],
                        text(v, "body_plain"), text(v, "body_html"))
        });
        tx.execute(
            "INSERT INTO mx_messages (key, conversation_key, organization_id, is_draft, sealed, created_at, change_seq, payload, search_text)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(key) DO UPDATE SET
               conversation_key = excluded.conversation_key, is_draft = excluded.is_draft,
               sealed = excluded.sealed, created_at = excluded.created_at,
               change_seq = excluded.change_seq,
               -- Opened text belongs to one sealed bundle — header and body both. Any
               -- re-seal (an edited draft, a rotated key) must be opened again; an
               -- untouched bundle (a read flag flipped) must not be.
               plain = CASE WHEN json_extract(excluded.payload, '$.sealed') IS json_extract(mx_messages.payload, '$.sealed')
                            THEN mx_messages.plain END,
               search_text = CASE WHEN excluded.sealed = 1
                                   AND json_extract(excluded.payload, '$.sealed') IS json_extract(mx_messages.payload, '$.sealed')
                                  THEN mx_messages.search_text ELSE excluded.search_text END,
               payload = excluded.payload
             WHERE excluded.change_seq >= mx_messages.change_seq
               AND excluded.organization_id = mx_messages.organization_id",
            params![
                key,
                thread,
                org,
                v.get("is_draft").and_then(Value::as_bool).unwrap_or(false) as i64,
                sealed as i64,
                text(v, "created_at"),
                seq(v),
                v.to_string(),
                indexed,
            ],
        )?;
    } else {
        tx.execute(
            "INSERT INTO mx_notes (key, conversation_key, organization_id, created_at, change_seq, payload)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(key) DO UPDATE SET
               conversation_key = excluded.conversation_key, created_at = excluded.created_at,
               change_seq = excluded.change_seq, payload = excluded.payload
             WHERE excluded.change_seq >= mx_notes.change_seq
               AND excluded.organization_id = mx_notes.organization_id",
            params![key, thread, org, text(v, "created_at"), seq(v), v.to_string()],
        )?;
    }
    Ok(())
}

fn unhydrated(tx: &Transaction, org: &str) -> Result<Vec<String>> {
    let keys = tx
        // Not the ones still settling: hydrating them now would only be held back again.
        .prepare(&format!(
            "SELECT key FROM mx_conversations c WHERE organization_id = ?2 AND hydrated = 0
               AND NOT {}",
            SETTLING.replace("?1", "c.key")
        ))?
        .query_map(params![rusqlite::types::Null, org, SETTLE_WINDOW], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(keys)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const ORG: &str = "org_a";

    #[test]
    fn html_search_text_decodes_entities_and_breaks_blocks() {
        let t = search_text(None, &[], None, Some("<p>factuur&nbsp;(factuurnummer:&nbsp;1213167)</p><p>Reconi</p><p>Heeft</p>"));
        assert!(!t.contains("&nbsp;") && t.contains("1213167") && !t.contains("ReconiHeeft"), "{t}");
    }

    fn store() -> SyncStore {
        let s = SyncStore::new_in_memory().unwrap();
        s.mx_begin(ORG, "usr_1").unwrap();
        s
    }

    fn conv(key: &str, seq: i64, status: &str) -> Value {
        json!({"id": key, "change_seq": seq, "status": status, "read": false, "subject": "Hi",
               "domain_id": "dom_1", "space": {"slug": "sales"}, "updated_at": "2026-09-20T10:00:00Z"})
    }

    fn msg(key: &str, thread: &str, seq: i64) -> Value {
        json!({"id": key, "conversation_id": thread, "change_seq": seq, "body_plain": "hello",
               "encryption_scheme": "none", "is_draft": false, "created_at": "2026-09-20T10:00:00Z"})
    }

    fn page(conversations: Vec<Value>, messages: Vec<Value>) -> MxRecords {
        MxRecords { conversations, messages, notes: vec![] }
    }

    fn one<T: rusqlite::types::FromSql>(s: &SyncStore, sql: &str) -> T {
        s.conn.lock().query_row(sql, [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn rows_the_old_js_drain_queued_are_taken_over_as_they_are() {
        // Same table, same columns, SQLite datetime('now') stamps: whatever the
        // webview's drain hadn't landed yet is simply the engine's to send now.
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![]), true).unwrap();
        s.conn.lock().execute(
            "INSERT INTO mx_writeback_actions (org_id, conversation_id, action, status, retry_count, max_retries, next_retry_at, created_at, updated_at)
             VALUES ('org_a', 'conv_1', 'spam', 'pending', 2, 10, datetime('now'), datetime('now'), datetime('now'))", []).unwrap();
        let batch = s.mx_claim_actions().unwrap().unwrap();
        assert_eq!((batch.action.as_str(), batch.conversations), ("spam", vec!["conv_1".to_string()]));
    }

    #[test]
    fn lore_done_flips_the_payload_and_a_stale_page_cannot_undo_it() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![]), true).unwrap();
        s.mx_enqueue_action(ORG, &["conv_1".into()], "lore_done").unwrap();
        assert_eq!(one::<i64>(&s, "SELECT json_extract(payload, '$.lore_done') FROM mx_conversations"), 1);
        assert_eq!(one::<String>(&s, "SELECT status FROM mx_conversations"), "open");

        // Landed, then a page read before the write: held back by the settle guard.
        let batch = s.mx_claim_actions().unwrap().unwrap();
        s.mx_actions_done(&batch.ids).unwrap();
        let mut stale = conv("conv_1", 2, "open");
        stale["lore_done"] = json!(false);
        s.mx_apply(ORG, &page(vec![stale], vec![]), true).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT json_extract(payload, '$.lore_done') FROM mx_conversations"), 1);

        s.mx_enqueue_action(ORG, &["conv_1".into()], "lore_undone").unwrap();
        assert_eq!(one::<i64>(&s, "SELECT json_extract(payload, '$.lore_done') FROM mx_conversations"), 0);
    }

    #[test]
    fn stores_the_payload_verbatim_and_the_list_columns() {
        let s = store();
        let c = conv("conv_1", 5, "open");
        s.mx_apply(ORG, &page(vec![c.clone()], vec![msg("msg_1", "conv_1", 4)]), true).unwrap();

        let payload: String = one(&s, "SELECT payload FROM mx_conversations");
        assert_eq!(serde_json::from_str::<Value>(&payload).unwrap(), c);
        assert_eq!(one::<String>(&s, "SELECT domain_key || '/' || space_slug FROM mx_conversations"), "dom_1/sales");
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_messages WHERE conversation_key = 'conv_1'"), 1);
    }

    #[test]
    fn never_touches_the_channel_tables() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![msg("msg_1", "conv_1", 1)]), true).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT (SELECT COUNT(*) FROM conversations) + (SELECT COUNT(*) FROM messages)"), 0);
    }

    #[test]
    fn version_guard_ignores_an_older_record_arriving_late() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 9, "archived")], vec![]), true).unwrap();
        // A backfill page read before the archive, applied after the delta.
        s.mx_apply(ORG, &page(vec![conv("conv_1", 3, "open")], vec![]), true).unwrap();
        assert_eq!(one::<String>(&s, "SELECT status FROM mx_conversations"), "archived");
    }

    #[test]
    fn settle_guard_keeps_optimistic_state_while_an_action_is_queued() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![]), true).unwrap();
        s.conn.lock().execute_batch(
            "UPDATE mx_conversations SET status = 'archived';
             INSERT INTO mx_writeback_actions (org_id, conversation_id, action, created_at, updated_at)
             VALUES ('org_a', 'conv_1', 'archive', datetime('now'), datetime('now'));").unwrap();

        // Held back — and not offered for hydration while it would only be held back again.
        let pending = s.mx_apply(ORG, &page(vec![conv("conv_1", 2, "open")], vec![]), false).unwrap();
        assert_eq!(one::<String>(&s, "SELECT status FROM mx_conversations"), "archived");
        assert!(pending.is_empty());

        // The action lands as a server no-op (no new stamp): what was held back is
        // still fetched, because the thread was marked for hydration.
        s.conn.lock().execute("DELETE FROM mx_writeback_actions", []).unwrap();
        assert_eq!(s.mx_apply(ORG, &MxRecords::default(), false).unwrap(), vec!["conv_1"]);
        s.mx_apply(ORG, &page(vec![conv("conv_1", 3, "archived")], vec![]), true).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT change_seq * 10 + hydrated FROM mx_conversations"), 31);
    }

    #[test]
    fn an_action_changes_columns_and_payload_at_once_and_is_queued() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![]), true).unwrap();
        s.mx_enqueue_action(ORG, &["conv_1".into()], "archive").unwrap();
        s.mx_enqueue_action(ORG, &["conv_1".into()], "mark_read").unwrap();
        assert_eq!(one::<String>(&s, "SELECT status || read || json_extract(payload, '$.status') || json_extract(payload, '$.read') FROM mx_conversations"), "archived1archived1");
        assert!(s.mx_enqueue_action(ORG, &["conv_1".into()], "explode").is_err());
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_writeback_actions"), 2);
    }

    #[test]
    fn claims_batch_by_action_but_keep_each_threads_order() {
        let s = store();
        let keys: Vec<String> = ["conv_a", "conv_b"].iter().map(|k| k.to_string()).collect();
        s.mx_apply(ORG, &page(keys.iter().map(|k| conv(k, 1, "open")).collect(), vec![]), true).unwrap();
        s.mx_enqueue_action(ORG, &keys, "spam").unwrap();
        s.mx_enqueue_action(ORG, &["conv_a".into()], "open").unwrap(); // changed their mind about a

        let first = s.mx_claim_actions().unwrap().unwrap();
        assert_eq!((first.action.as_str(), first.conversations.clone()), ("spam", keys.clone()));
        // `open` for conv_a must wait for its `spam` — and nobody else can claim the batch.
        assert_eq!(s.mx_claim_actions().unwrap(), None);

        s.mx_actions_done(&first.ids).unwrap();
        let second = s.mx_claim_actions().unwrap().unwrap();
        assert_eq!((second.action.as_str(), second.conversations), ("open", vec!["conv_a".to_string()]));
    }

    #[test]
    fn a_transient_failure_backs_off_and_a_permanent_one_gives_way_to_the_server() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![]), true).unwrap();
        s.mx_enqueue_action(ORG, &["conv_1".into()], "archive").unwrap();

        let batch = s.mx_claim_actions().unwrap().unwrap();
        s.mx_actions_failed(&batch.ids, "503", false).unwrap();
        assert_eq!(one::<String>(&s, "SELECT status || retry_count FROM mx_writeback_actions"), "pending1");
        assert_eq!(s.mx_claim_actions().unwrap(), None, "not due until the backoff elapses");

        s.conn.lock().execute("UPDATE mx_writeback_actions SET next_retry_at = datetime('now', '-1 second')", []).unwrap();
        let batch = s.mx_claim_actions().unwrap().unwrap();
        s.mx_actions_failed(&batch.ids, "422 No conversations found", true).unwrap();
        assert_eq!(one::<String>(&s, "SELECT status FROM mx_writeback_actions"), "failed");
        assert_eq!(s.mx_apply(ORG, &MxRecords::default(), false).unwrap(), vec!["conv_1"]); // re-fetch the truth
    }

    #[test]
    fn an_abandoned_claim_is_reclaimed() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![]), true).unwrap();
        s.mx_enqueue_action(ORG, &["conv_1".into()], "archive").unwrap();
        s.mx_claim_actions().unwrap().unwrap(); // …and the process dies
        assert_eq!(s.mx_claim_actions().unwrap(), None);
        s.conn.lock().execute("UPDATE mx_writeback_actions SET updated_at = datetime('now', '-10 minutes')", []).unwrap();
        assert!(s.mx_claim_actions().unwrap().is_some());
    }

    #[test]
    fn after_an_action_lands_only_records_that_agree_with_it_are_accepted() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![]), true).unwrap();
        s.mx_enqueue_action(ORG, &["conv_1".into()], "archive").unwrap();
        let batch = s.mx_claim_actions().unwrap().unwrap();
        // Still in flight: held back whatever it says.
        s.mx_apply(ORG, &page(vec![conv("conv_1", 5, "archived")], vec![]), false).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT change_seq FROM mx_conversations"), 1);
        s.mx_actions_done(&batch.ids).unwrap();

        // A page read before the write landed, applied after: must not un-archive.
        s.mx_apply(ORG, &page(vec![conv("conv_1", 4, "open")], vec![]), false).unwrap();
        assert_eq!(one::<String>(&s, "SELECT status FROM mx_conversations"), "archived");
        // The write's own stamp agrees, and goes in.
        s.mx_apply(ORG, &page(vec![conv("conv_1", 6, "archived")], vec![]), false).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT change_seq FROM mx_conversations"), 6);
    }

    #[test]
    fn settle_guard_lapses_and_ignores_failed_actions() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_old", 1, "open"), conv("conv_failed", 1, "open")], vec![]), true).unwrap();
        s.conn.lock().execute_batch(
            "INSERT INTO mx_writeback_actions (org_id, conversation_id, action, status, created_at, updated_at) VALUES
               ('org_a', 'conv_old', 'archive', 'pending', datetime('now', '-1 hour'), 'x'),
               ('org_a', 'conv_failed', 'archive', 'failed', datetime('now'), 'x');").unwrap();
        s.mx_apply(ORG, &page(vec![conv("conv_old", 2, "spam"), conv("conv_failed", 2, "spam")], vec![]), false).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_conversations WHERE status = 'spam'"), 2);
    }

    #[test]
    fn a_thread_first_seen_in_a_delta_needs_hydrating() {
        let s = store();
        let pending = s.mx_apply(ORG, &page(vec![conv("conv_new", 4, "open")], vec![]), false).unwrap();
        assert_eq!(pending, vec!["conv_new"]);

        let hydrated = page(vec![conv("conv_new", 4, "open")], vec![msg("msg_a", "conv_new", 2), msg("msg_b", "conv_new", 3)]);
        assert!(s.mx_apply(ORG, &hydrated, true).unwrap().is_empty());
        assert!(s.mx_apply(ORG, &MxRecords::default(), false).unwrap().is_empty());
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_messages"), 2);

        // A later delta touching the row must not un-hydrate it.
        s.mx_apply(ORG, &page(vec![conv("conv_new", 6, "open")], vec![]), false).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT hydrated FROM mx_conversations"), 1);
    }

    #[test]
    fn a_full_thread_page_deletes_children_the_server_no_longer_has() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open"), conv("conv_other", 1, "open")],
            vec![msg("msg_keep", "conv_1", 1), msg("msg_gone", "conv_1", 1), msg("msg_other", "conv_other", 1)]), true).unwrap();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 2, "open")], vec![msg("msg_keep", "conv_1", 1)]), true).unwrap();
        assert_eq!(one::<String>(&s, "SELECT group_concat(key) FROM (SELECT key FROM mx_messages ORDER BY key)"), "msg_keep,msg_other");
    }

    #[test]
    fn a_stale_full_thread_page_does_not_prune_newer_children() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![msg("msg_1", "conv_1", 1)]), true).unwrap();
        // Delta: a reply lands (thread now v7). Then a backfill page read earlier arrives.
        s.mx_apply(ORG, &page(vec![conv("conv_1", 7, "open")], vec![msg("msg_reply", "conv_1", 6)]), false).unwrap();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![msg("msg_1", "conv_1", 1)]), true).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_messages"), 2);
    }

    #[test]
    fn threads_the_server_refuses_are_dropped() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![msg("msg_1", "conv_1", 1)]), true).unwrap();
        s.mx_drop_threads(ORG, &["conv_1".to_string()]).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT (SELECT COUNT(*) FROM mx_conversations) + (SELECT COUNT(*) FROM mx_messages)"), 0);
    }

    #[test]
    fn merge_survives_a_page_boundary() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_src", 1, "open"), conv("conv_dst", 1, "open")],
            vec![msg("msg_1", "conv_src", 1)]), true).unwrap();
        // Page 1: the message, re-parented. Page 2: the source's tombstone.
        s.mx_apply(ORG, &page(vec![conv("conv_dst", 5, "open")], vec![msg("msg_1", "conv_dst", 4)]), false).unwrap();
        s.mx_apply_deleted(ORG, &[MxDeleted { record_type: "conversation".into(), id: "conv_src".into() }]).unwrap();
        assert_eq!(one::<String>(&s, "SELECT conversation_key FROM mx_messages WHERE key = 'msg_1'"), "conv_dst");
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_conversations"), 1);
    }

    #[test]
    fn deleting_a_thread_takes_its_children() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![msg("msg_1", "conv_1", 1)]), true).unwrap();
        s.mx_apply_deleted(ORG, &[MxDeleted { record_type: "conversation".into(), id: "conv_1".into() }]).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_messages"), 0);
    }

    #[test]
    fn a_child_without_its_thread_is_skipped_not_an_fk_error() {
        let s = store();
        s.mx_apply(ORG, &page(vec![], vec![msg("msg_orphan", "conv_missing", 1)]), false).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_messages"), 0);
    }

    #[test]
    fn reconcile_removes_the_unlisted_and_asks_for_the_changed() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_same", 3, "open"), conv("conv_stale", 3, "open"),
            conv("conv_revoked", 3, "open")], vec![msg("msg_r", "conv_revoked", 1)]), true).unwrap();

        let listing = [("conv_same".to_string(), 3), ("conv_stale".to_string(), 8), ("conv_new".to_string(), 1)];
        let plan = s.mx_reconcile(ORG, &listing, &SyncStore::mx_now()).unwrap();
        assert_eq!(plan.removed, 1);
        assert_eq!((plan.hydrate, plan.absent), (vec!["conv_stale".to_string()], vec!["conv_new".to_string()]));
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_messages"), 0); // went with conv_revoked
        assert!(s.mx_state(ORG).unwrap().unwrap().reconciled_at.is_some());
    }

    #[test]
    fn reconcile_spares_what_arrived_after_the_listing_and_trusts_newer_local_versions() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_ahead", 9, "open")], vec![]), true).unwrap();
        let listing_started = SyncStore::mx_now();
        // While the key pages were being fetched, a delta delivered a new thread.
        s.mx_apply(ORG, &page(vec![conv("conv_fresh", 12, "open")], vec![]), true).unwrap();

        let plan = s.mx_reconcile(ORG, &[("conv_ahead".into(), 7)], &listing_started).unwrap();
        assert_eq!(plan, MxReconcile::default()); // nothing removed, nothing re-fetched
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_conversations"), 2);
    }

    #[test]
    fn opened_mail_is_stored_beside_the_ciphertext_and_names_the_thread() {
        let s = store();
        let mut thread = conv("conv_sealed", 1, "open");
        for f in ["subject", "from_address", "snippet"] { thread[f] = Value::Null; }
        let mut m = msg("msg_s", "conv_sealed", 1);
        m["encryption_scheme"] = json!("sealed_box_v1");
        m["sealed"] = json!({"body_ciphertext": "AAAA", "sealed_dek": "BBBB"});
        s.mx_apply(ORG, &page(vec![thread], vec![m.clone()]), true).unwrap();

        let pending = s.mx_unopened(ORG, "", 10).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].1["sealed_dek"], "BBBB");

        s.mx_store_opened(ORG, &[("msg_s".into(), json!({"subject": "Term sheet", "from": "ann@x.test", "snippet": "see attached"}), json!({"plain": "hello"}))]).unwrap();
        assert!(s.mx_unopened(ORG, "", 10).unwrap().is_empty());
        assert_eq!(one::<String>(&s, "SELECT subject || '|' || from_address || '|' || snippet FROM mx_conversations"), "Term sheet|ann@x.test|see attached");
        assert_eq!(one::<String>(&s, "SELECT json_extract(plain, '$.body.plain') FROM mx_messages"), "hello");
        // The API-shaped payload is untouched: still ciphertext, still no subject.
        assert_eq!(one::<String>(&s, "SELECT json_extract(payload, '$.sealed.body_ciphertext') FROM mx_messages"), "AAAA");

        // Re-delivered unchanged (a read flag flipped): stays opened. Re-sealed: opened again.
        m["change_seq"] = json!(2);
        s.mx_apply(ORG, &page(vec![], vec![m.clone()]), false).unwrap();
        assert!(s.mx_unopened(ORG, "", 10).unwrap().is_empty());
        m["change_seq"] = json!(3);
        m["sealed"]["header_ciphertext"] = json!("re-sealed header, same body");
        s.mx_apply(ORG, &page(vec![], vec![m]), false).unwrap();
        assert_eq!(s.mx_unopened(ORG, "", 10).unwrap().len(), 1);
    }

    #[test]
    fn a_mirror_from_an_older_schema_is_dropped_and_rebuilt_but_queued_actions_survive() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("inbox2.db");
        {
            // What a device that ran an earlier mirror build has on disk.
            let s = SyncStore::new(&path, dir.path()).unwrap();
            s.mx_begin(ORG, "usr_1").unwrap();
            s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![msg("msg_1", "conv_1", 1)]), true).unwrap();
            s.mx_enqueue_action(ORG, &["conv_1".into()], "archive").unwrap();
            let conn = s.conn.lock();
            conn.execute_batch(
                "DROP TABLE mx_messages_fts; DROP TABLE mx_messages;
                 CREATE TABLE mx_messages (key TEXT PRIMARY KEY, conversation_key TEXT NOT NULL, organization_id TEXT NOT NULL, payload TEXT NOT NULL);
                 UPDATE engine_settings SET value = '1' WHERE key = 'mx_schema_version';").unwrap();
        }
        let s = SyncStore::new(&path, dir.path()).expect("an older mirror must not brick the store");
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM pragma_table_info('mx_messages') WHERE name = 'search_text'"), 1);
        assert_eq!(one::<i64>(&s, "SELECT (SELECT COUNT(*) FROM mx_conversations) + (SELECT COUNT(*) FROM mx_sync_state)"), 0);
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_writeback_actions"), 1, "user intent is not cache");

        // Same version next time: nothing is dropped.
        s.mx_begin(ORG, "usr_1").unwrap();
        drop(s);
        let s = SyncStore::new(&path, dir.path()).unwrap();
        assert!(s.mx_state(ORG).unwrap().is_some());
    }

    #[test]
    fn search_finds_words_in_bodies_html_and_opened_sealed_mail_and_survives_odd_input() {
        let s = store();
        let mut plain = msg("msg_plain", "conv_a", 1);
        plain["subject"] = json!("Quarterly forecast");
        plain["body_plain"] = json!("The pipeline numbers look healthy.");
        let mut html = msg("msg_html", "conv_b", 1);
        html["body_plain"] = Value::Null;
        html["body_html"] = json!("<style>.x{color:red}</style><p>Your <b>invoice</b> is attached</p>");
        let mut sealed = msg("msg_sealed", "conv_c", 1);
        sealed["encryption_scheme"] = json!("sealed_box_v1");
        sealed["body_plain"] = Value::Null;
        sealed["sealed"] = json!({"body_ciphertext": "AAAA"});
        let mut junk = msg("msg_junk", "conv_d", 1);
        junk["body_plain"] = json!("pipeline of spam");
        s.mx_apply(ORG, &page(vec![conv("conv_a", 1, "open"), conv("conv_b", 1, "open"), conv("conv_c", 1, "archived"),
                                   conv("conv_d", 1, "spam")], vec![plain, html, sealed, junk]), true).unwrap();
        let found = |q: &str| -> Vec<String> {
            s.mx_search(ORG, q, 10).unwrap().iter().map(|p| serde_json::from_str::<Value>(p).unwrap()["id"].as_str().unwrap().to_string()).collect()
        };

        assert_eq!(found("pipeline"), vec!["conv_a"], "spam never matches");
        assert_eq!(found("forecast pipe"), vec!["conv_a"], "every word, prefix-matched");
        assert_eq!(found("invoice"), vec!["conv_b"], "HTML-only mail is indexed as text");
        assert!(found("color").is_empty(), "…without its CSS");
        assert!(found("merger").is_empty(), "sealed mail is not searchable while sealed");

        s.mx_store_opened(ORG, &[("msg_sealed".into(), json!({"subject": "Merger terms"}), json!({"plain": "strictly confidential"}))]).unwrap();
        assert_eq!(found("merger confidential"), vec!["conv_c"], "…and is once opened (archived mail matches)");

        for odd in ["", "   ", "\"", "AND OR NOT", "a:b -c (d", "*"] {
            let _ = s.mx_search(ORG, odd, 10).expect("never a syntax error");
        }
        s.mx_apply_deleted(ORG, &[MxDeleted { record_type: "conversation".into(), id: "conv_a".into() }]).unwrap();
        assert!(found("pipeline").is_empty(), "a deleted thread leaves the index");
        assert!(s.mx_search("org_other", "invoice", 10).unwrap().is_empty());
    }

    #[test]
    fn agents_never_see_sealed_mail_even_once_it_is_opened() {
        let s = store();
        let mut sealed = msg("msg_sealed", "conv_sealed", 1);
        sealed["encryption_scheme"] = json!("sealed_box_v1");
        sealed["sealed"] = json!({"body_ciphertext": "AAAA"});
        let mut html_only = msg("msg_html", "conv_open", 1);
        html_only["body_plain"] = Value::Null;
        html_only["body_html"] = json!("<p>Invoice attached</p>");
        html_only["from_address"] = json!("billing@x.test");
        // An unsealed reply inside the sealed thread: the thread rule must hide it too,
        // because `read_message` looks keys up in `agent_messages` directly.
        let reply_in_sealed_thread = msg("msg_reply", "conv_sealed", 2);
        s.mx_apply(ORG, &page(vec![conv("conv_open", 1, "open"), conv("conv_sealed", 1, "open")], vec![html_only, sealed, reply_in_sealed_thread]), true).unwrap();
        s.mx_store_opened(ORG, &[("msg_sealed".into(), json!({"subject": "Merger terms"}), json!({"plain": "strictly confidential"}))]).unwrap();
        // The engine's own readers can use it…
        assert_eq!(s.mx_search(ORG, "merger", 10).unwrap().len(), 1);

        // …an agent (possibly a cloud model) cannot: not the message, not the thread
        // whose subject came out of the sealed header, not by search.
        assert_eq!(one::<String>(&s, "SELECT group_concat(key) FROM agent_conversations"), "conv_open");
        assert_eq!(one::<String>(&s, "SELECT group_concat(key) FROM agent_messages"), "msg_html");
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_messages_fts f JOIN mx_messages m ON m.id = f.rowid
                                   JOIN agent_messages a ON a.key = m.key WHERE mx_messages_fts MATCH '\"merger\"*'"), 0);
        // What they do get is usable: HTML-only mail reads as text, in the channel shape.
        // (the fallback text is the indexed text, so it leads with the subject/people lines).
        assert_eq!(one::<String>(&s, "SELECT (body_plain LIKE '%Invoice attached%') || '|' || from_address || '|' || account_key FROM agent_messages"),
                   "1|billing@x.test|org_a");
    }

    #[test]
    fn sealed_messages_are_flagged() {
        let s = store();
        let mut m = msg("msg_s", "conv_1", 1);
        m["encryption_scheme"] = json!("sealed_box_v1");
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![m]), true).unwrap();
        assert_eq!(one::<i64>(&s, "SELECT sealed FROM mx_messages"), 1);
    }

    #[test]
    fn directory_listings_are_replaced_whole_and_keep_server_order() {
        let s = store();
        s.mx_directory_replace(ORG, "tags", &[json!({"id": "tag_b"}), json!({"id": "tag_a"})]).unwrap();
        s.mx_directory_replace(ORG, "tags", &[json!({"id": "tag_c"})]).unwrap();
        s.mx_directory_replace(ORG, "domains", &[json!({"id": "dom_1"})]).unwrap();
        assert_eq!(one::<String>(&s, "SELECT group_concat(key) FROM mx_directory WHERE type = 'tags' ORDER BY position"), "tag_c");
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_directory"), 2);
    }

    #[test]
    fn a_different_user_starts_from_an_empty_mirror() {
        let s = store();
        s.mx_apply(ORG, &page(vec![conv("conv_1", 1, "open")], vec![msg("msg_1", "conv_1", 1)]), true).unwrap();
        s.mx_set_cursor(ORG, "12.34").unwrap();
        s.mx_set_backfill(ORG, None).unwrap();

        assert_eq!(s.mx_begin(ORG, "usr_1").unwrap().cursor.as_deref(), Some("12.34")); // same user resumes
        s.conn.lock().execute(
            "INSERT INTO mx_writeback_actions (org_id, conversation_id, action, created_at, updated_at)
             VALUES ('org_a', 'conv_1', 'archive', datetime('now'), 'x')", []).unwrap();
        let fresh = s.mx_begin(ORG, "usr_2").unwrap();
        assert_eq!(fresh, MxSyncState { user_key: "usr_2".into(), ..Default::default() });
        assert_eq!(one::<i64>(&s, "SELECT (SELECT COUNT(*) FROM mx_conversations) + (SELECT COUNT(*) FROM mx_messages)
                                      + (SELECT COUNT(*) FROM mx_writeback_actions)"), 0);
    }

    #[test]
    fn orgs_are_kept_apart() {
        let s = store();
        s.mx_begin("org_b", "usr_1").unwrap();
        s.mx_apply(ORG, &page(vec![conv("conv_a", 1, "open")], vec![]), true).unwrap();
        s.mx_apply("org_b", &page(vec![conv("conv_b", 1, "open")], vec![]), true).unwrap();
        s.mx_apply_deleted("org_b", &[MxDeleted { record_type: "conversation".into(), id: "conv_a".into() }]).unwrap();
        // A key is global, but a page for one org can never rewrite another's row.
        s.mx_apply("org_b", &page(vec![conv("conv_a", 99, "spam")], vec![msg("msg_x", "conv_a", 1)]), true).unwrap();
        s.mx_reconcile("org_b", &[], &SyncStore::mx_now()).unwrap();
        assert_eq!(one::<String>(&s, "SELECT group_concat(key || ':' || status) FROM mx_conversations"), "conv_a:open");
        assert_eq!(one::<i64>(&s, "SELECT COUNT(*) FROM mx_messages"), 0);
    }
}
