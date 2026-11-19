use parking_lot::Mutex;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::mcp::protocol::ToolResult;
use crate::sync::actions::WritebackQueue;
use crate::sync::engine::SyncEngine;
use crate::sync::error::SyncError;
use crate::sync::interactive::OutgoingMessage;
use crate::sync::model::OutboxSendResult;
use crate::sync::model::{ActionType, Quadrant};

pub(super) fn exec_mark_read_unread(
    conn: &Arc<Mutex<Connection>>,
    writeback: &Arc<WritebackQueue>,
    engine: &Arc<SyncEngine>,
    action: &str,
    params: &Value,
) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    let keys: Vec<String> = match params["message_keys"].as_array() {
        Some(arr) => arr.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
        None => return ToolResult::error("message_keys is required".into()),
    };
    if is_mx(conn, account_key) {
        // MX actions are per thread: map the messages to their conversations.
        let threads: Vec<String> = {
            let conn = conn.lock();
            let mut threads: Vec<String> = keys
                .iter()
                .filter_map(|k| {
                    conn.query_row("SELECT conversation_key FROM mx_messages WHERE key = ?1", params![k], |r| r.get(0))
                        .ok()
                })
                .collect();
            threads.sort();
            threads.dedup();
            threads
        };
        return mx_verb(engine, account_key, &threads, action, "updated", keys.len());
    }
    let read_val = if action == "mark_read" { 1 } else { 0 };
    let action_type = if action == "mark_read" {
        ActionType::MarkRead
    } else {
        ActionType::MarkUnread
    };

    // Optimistic local update so list/read tools and the UI reflect it now.
    {
        let conn = conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        for key in &keys {
            let _ = conn.execute(
                "UPDATE conversations SET read = ?1, updated_at = ?2
                 WHERE key IN (SELECT conversation_key FROM messages WHERE key = ?3)",
                params![read_val, now, key],
            );
        }
    }

    // Defer the provider write-back to the sync engine via its queue.
    let queued = enqueue_for_messages(writeback, account_key, &action_type, &keys);
    ToolResult::text(json!({ "updated": keys.len(), "writeback_queued": queued }).to_string())
}

pub(super) fn exec_archive(
    conn: &Arc<Mutex<Connection>>,
    writeback: &Arc<WritebackQueue>,
    engine: &Arc<SyncEngine>,
    params: &Value,
) -> ToolResult {
    apply_conversation_status(conn, writeback, engine, params, "archived", ActionType::Archive, "archived")
}

pub(super) fn exec_trash(
    conn: &Arc<Mutex<Connection>>,
    writeback: &Arc<WritebackQueue>,
    engine: &Arc<SyncEngine>,
    params: &Value,
) -> ToolResult {
    apply_conversation_status(conn, writeback, engine, params, "trash", ActionType::Trash, "trashed")
}

/// Flip `conversations.status` locally and enqueue a provider write-back action
/// for each synced message in those conversations. Shared by `archive` and
/// `trash`: both defer the real provider mutation to the sync engine's queue,
/// which the engine drains and applies (the provider is the source of truth on
/// conflict). This is the same write-back path the Tauri UI uses.
fn apply_conversation_status(
    conn: &Arc<Mutex<Connection>>,
    writeback: &Arc<WritebackQueue>,
    engine: &Arc<SyncEngine>,
    params: &Value,
    new_status: &str,
    action_type: ActionType,
    result_field: &str,
) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    let keys: Vec<String> = match params["conversation_keys"].as_array() {
        Some(arr) => arr.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
        None => return ToolResult::error("conversation_keys is required".into()),
    };
    if is_mx(conn, account_key) {
        return mx_verb(engine, account_key, &keys, action_type.as_str(), result_field, keys.len());
    }

    // Optimistic local status update + gather the synced message keys whose
    // provider state the engine needs to mutate.
    let mut message_keys: Vec<String> = Vec::new();
    {
        let conn = conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        let mut stmt = match conn.prepare(
            "SELECT DISTINCT m.key
             FROM messages m
             JOIN message_provider_state mps ON mps.message_key = m.key
             WHERE m.conversation_key = ?1 AND mps.account_key = ?2
               AND mps.provider_message_id IS NOT NULL",
        ) {
            Ok(s) => s,
            Err(e) => return ToolResult::error(e.to_string()),
        };
        for key in &keys {
            let _ = conn.execute(
                "UPDATE conversations SET status = ?1, updated_at = ?2 WHERE key = ?3",
                params![new_status, now, key],
            );
            if let Ok(rows) = stmt.query_map(params![key, account_key], |row| row.get::<_, String>(0)) {
                message_keys.extend(rows.filter_map(|r| r.ok()));
            }
        }
    }

    let queued = enqueue_for_messages(writeback, account_key, &action_type, &message_keys);

    let mut obj = serde_json::Map::new();
    obj.insert(result_field.to_string(), json!(keys.len()));
    obj.insert("writeback_queued".to_string(), json!(queued));
    ToolResult::text(Value::Object(obj).to_string())
}

/// Enqueue one write-back action per message; returns how many were queued.
fn enqueue_for_messages(
    writeback: &Arc<WritebackQueue>,
    account_key: &str,
    action_type: &ActionType,
    message_keys: &[String],
) -> usize {
    let mut queued = 0;
    for mk in message_keys {
        match writeback.enqueue(account_key, action_type.clone(), mk, None, None) {
            Ok(_) => queued += 1,
            Err(e) => log::warn!("MCP write-back enqueue failed for {mk}: {e}"),
        }
    }
    queued
}

// Priority is propagated to the provider as triage (quadrant) *labels* via the
// engine's interactive path (`set_quadrant:*`), not the write-back queue's
// per-message ActionType set — so unlike archive/trash this drives the provider
// synchronously in-core, mirroring the Tauri `set_priority` command.
pub(super) fn exec_set_priority(
    conn: &Arc<Mutex<Connection>>,
    engine: &Arc<SyncEngine>,
    params: &Value,
) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    if let Some(refused) = refuse_mx(conn, account_key) {
        return refused;
    }
    let keys: Vec<String> = match params["conversation_keys"].as_array() {
        Some(arr) => arr.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
        None => return ToolResult::error("conversation_keys is required".into()),
    };
    let urgent = params["urgent"].as_bool().unwrap_or(false);
    let important = params["important"].as_bool().unwrap_or(false);

    // Optimistic local update.
    {
        let conn = conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        for key in &keys {
            let _ = conn.execute(
                "UPDATE conversations SET priority_urgent = ?1, priority_important = ?2,
                 updated_at = ?3 WHERE key = ?4",
                params![urgent as i32, important as i32, now, key],
            );
        }
    }

    // Propagate to the provider as the matching quadrant label, mirroring the
    // Tauri `set_priority` command. `perform_action` is async, so drive it to
    // completion on the engine's runtime (we're on the sync MCP-HTTP thread).
    let action = Quadrant::from_priority(urgent, important).set_verb();
    let engine = engine.clone();
    let account = account_key.to_string();
    let conv_keys = keys.clone();
    let sync_result: Result<(), SyncError> = tauri::async_runtime::block_on(async move {
        let provider = engine.interactive_provider(&account)?;
        for conv in &conv_keys {
            let ids = engine.store().provider_ids_for_conversation(&account, conv)?;
            if !ids.is_empty() {
                provider.perform_action(&ids, &action).await?;
            }
        }
        Ok(())
    });

    let mut obj = serde_json::Map::new();
    obj.insert("updated".to_string(), json!(keys.len()));
    match sync_result {
        Ok(()) => {
            obj.insert("provider_synced".to_string(), json!(true));
        }
        Err(e) => {
            log::warn!("MCP set_priority provider sync failed: {e}");
            obj.insert("provider_synced".to_string(), json!(false));
            obj.insert("provider_error".to_string(), json!(e.to_string()));
        }
    }
    ToolResult::text(Value::Object(obj).to_string())
}

// ── Engine-driven writes ────────────────────────────────────────────────────
// Everything below goes through the sync engine's own entry points (the ones the
// window and the mobile apps call), run to completion on its runtime.

fn conversation_keys(params: &Value) -> Option<Vec<String>> {
    params["conversation_keys"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
}

/// Whether `account_key` is an inbox2-hosted org mirrored here rather than a
/// connected mailbox.
fn is_mx(conn: &Arc<Mutex<Connection>>, account_key: &str) -> bool {
    conn.lock()
        .query_row("SELECT 1 FROM mx_sync_state WHERE organization_id = ?1", params![account_key], |_| Ok(()))
        .is_ok()
}

/// Tools with no inbox2-hosted path. An org key would otherwise match no rows
/// and report success having changed nothing.
fn refuse_mx(conn: &Arc<Mutex<Connection>>, account_key: &str) -> Option<ToolResult> {
    is_mx(conn, account_key).then(|| {
        ToolResult::error(format!(
            "'{account_key}' is an inbox2-hosted organization; this tool works on connected mailboxes only"
        ))
    })
}

/// An MX conversation action through the engine's queue (optimistic locally,
/// then POSTed; queued and retried if the server is unreachable).
fn mx_verb(engine: &Arc<SyncEngine>, org: &str, threads: &[String], verb: &str, field: &str, count: usize) -> ToolResult {
    let (engine, org, threads, verb) = (engine.clone(), org.to_string(), threads.to_vec(), verb.to_string());
    match tauri::async_runtime::block_on(async move { engine.mx_action(&org, &threads, &verb).await }) {
        Ok(()) => ToolResult::text(json!({ field: count, "queued": true }).to_string()),
        Err(e) => ToolResult::error(e.to_string()),
    }
}

fn outcome(result: Result<(), SyncError>, field: &str, count: usize) -> ToolResult {
    match result {
        Ok(()) => ToolResult::text(json!({ field: count, "writeback_queued": true }).to_string()),
        Err(e) => ToolResult::error(e.to_string()),
    }
}

/// Build the outgoing message from tool arguments. From is the account's own
/// address (bare: Graph 400s on `Name <addr>`).
fn outgoing(engine: &Arc<SyncEngine>, account_key: &str, params: &Value, reply_to: Option<&str>) -> Result<OutgoingMessage, String> {
    let account = engine
        .store()
        .get_account(account_key)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("Account '{account_key}' not found"))?;
    let text = |k: &str| params[k].as_str().filter(|s| !s.is_empty()).map(String::from);
    Ok(OutgoingMessage {
        from_address: account.email_address,
        to_address: text("to").ok_or("to is required")?,
        cc_address: text("cc"),
        bcc_address: text("bcc"),
        subject: text("subject"),
        body_html: text("body_html"),
        body_plain: text("body_plain").or_else(|| text("body")),
        reply_to_message_key: reply_to.map(String::from),
        ..Default::default()
    })
}

/// Hosted-mail send or draft. `from` is optional: the engine picks the address
/// the thread was sent to, else the member's default.
fn mx_compose(engine: &Arc<SyncEngine>, org: &str, params: &Value, reply_to: Option<&str>, draft_key: Option<&str>) -> ToolResult {
    let text = |k: &str| params[k].as_str().filter(|s| !s.is_empty()).map(String::from);
    let Some(to) = text("to") else {
        return ToolResult::error("to is required".into());
    };
    let msg = OutgoingMessage {
        from_address: text("from").unwrap_or_default(),
        to_address: to,
        cc_address: text("cc"),
        bcc_address: text("bcc"),
        subject: text("subject"),
        body_html: text("body_html"),
        body_plain: text("body_plain").or_else(|| text("body")),
        reply_to_message_key: reply_to.map(String::from),
        ..Default::default()
    };
    let (engine, org, dk) = (engine.clone(), org.to_string(), draft_key.map(String::from));
    match tauri::async_runtime::block_on(async move { engine.mx_compose(&org, msg, dk.as_deref()).await }) {
        Ok(result) => queued_result(&result, draft_key),
        Err(e) => ToolResult::error(e.to_string()),
    }
}

/// A queued send/draft's outcome. `status` is `sent` once delivered, `pending`
/// while queued (offline, or retrying), `failed` when it gave up. Drafts echo
/// their `draft_key`: pass it back to replace that draft with a newer version.
fn queued_result(result: &OutboxSendResult, draft_key: Option<&str>) -> ToolResult {
    let mut v = serde_json::to_value(result).unwrap_or_default();
    if let Some(dk) = draft_key {
        v["draft_key"] = json!(dk);
    }
    ToolResult::json(&v)
}

pub(super) fn exec_compose_draft(conn: &Arc<Mutex<Connection>>, engine: &Arc<SyncEngine>, params: &Value) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    let reply_to = params["reply_to_message"].as_str();
    // Saving again under the same key replaces the draft; only the latest
    // version is kept, queued or delivered.
    let draft_key = params["draft_key"]
        .as_str()
        .filter(|k| !k.is_empty())
        .map(String::from)
        .unwrap_or_else(|| format!("drf_{}", nanoid::nanoid!(21)));
    if is_mx(conn, account_key) {
        return mx_compose(engine, account_key, params, reply_to, Some(&draft_key));
    }
    let msg = match outgoing(engine, account_key, params, reply_to) {
        Ok(m) => m,
        Err(e) => return ToolResult::error(e),
    };
    let (engine, account, dk) = (engine.clone(), account_key.to_string(), draft_key.clone());
    match tauri::async_runtime::block_on(async move { engine.enqueue_draft(&account, &dk, msg).await }) {
        Ok(result) => queued_result(&result, Some(&draft_key)),
        Err(e) => ToolResult::error(e.to_string()),
    }
}

/// `send_message` (optionally a reply) and `create_conversation` (never one).
/// Durable: a failed first attempt stays in the outbox and retries.
pub(super) fn exec_send(conn: &Arc<Mutex<Connection>>, engine: &Arc<SyncEngine>, params: &Value, allow_reply: bool) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    let reply_to = if allow_reply { params["in_reply_to"].as_str() } else { None };
    if is_mx(conn, account_key) {
        return mx_compose(engine, account_key, params, reply_to, None);
    }
    let msg = match outgoing(engine, account_key, params, reply_to) {
        Ok(m) => m,
        Err(e) => return ToolResult::error(e),
    };
    let (engine, account) = (engine.clone(), account_key.to_string());
    match tauri::async_runtime::block_on(async move { engine.enqueue_send(&account, msg).await }) {
        Ok(result) => ToolResult::json(&result),
        Err(e) => ToolResult::error(e.to_string()),
    }
}

pub(super) fn exec_tag(conn: &Arc<Mutex<Connection>>, engine: &Arc<SyncEngine>, params: &Value, add: bool) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    let tag = required_str!(params, "tag");
    let Some(keys) = conversation_keys(params) else {
        return ToolResult::error("conversation_keys is required".into());
    };
    let mx = is_mx(conn, account_key);
    let (engine, account, tag_owned, k) = (engine.clone(), account_key.to_string(), tag.to_string(), keys.clone());
    let result = tauri::async_runtime::block_on(async move {
        if mx {
            engine.mx_tag(&account, &k, &tag_owned, add).await
        } else {
            engine.tag_conversations(&account, &k, &tag_owned, add).await
        }
    });
    outcome(result, if add { "tagged" } else { "untagged" }, keys.len())
}

pub(super) fn exec_move_to_folder(conn: &Arc<Mutex<Connection>>, engine: &Arc<SyncEngine>, params: &Value) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    let folder = required_str!(params, "folder");
    let Some(keys) = conversation_keys(params) else {
        return ToolResult::error("conversation_keys is required".into());
    };
    let mx = is_mx(conn, account_key);
    // Trash is the Full-tier `trash` tool's (IMAP expunges it): a ReadWrite
    // agent mustn't reach it by calling it a move.
    let into_trash = if mx {
        folder.eq_ignore_ascii_case("trash")
    } else {
        engine
            .resolve_folder(account_key, folder)
            .is_ok_and(|f| f.role == Some(crate::sync::model::WellKnownFolder::Trash))
    };
    if into_trash {
        return ToolResult::error("moving to trash is the trash tool's job (it needs the full permission level)".into());
    }
    let (engine, account, folder_owned, k) = (engine.clone(), account_key.to_string(), folder.to_string(), keys.clone());
    let result = tauri::async_runtime::block_on(async move {
        if mx {
            engine.mx_move(&account, &k, &folder_owned).await
        } else {
            engine.move_conversations(&account, &k, &folder_owned).await
        }
    });
    outcome(result, "moved", keys.len())
}

pub(super) fn exec_delete(conn: &Arc<Mutex<Connection>>, engine: &Arc<SyncEngine>, params: &Value) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    let Some(keys) = conversation_keys(params) else {
        return ToolResult::error("conversation_keys is required".into());
    };
    let mx = is_mx(conn, account_key);
    // inbox2 connects Gmail with gmail.modify; permanent delete needs the full
    // mail scope, and the 403 would flag the account for re-auth.
    let gmail = !mx
        && engine
            .store()
            .get_account(account_key)
            .ok()
            .flatten()
            .is_some_and(|a| a.provider_type == crate::sync::model::ProviderType::Gmail);
    if gmail {
        return ToolResult::error("Gmail accounts can't be permanently deleted from here (inbox2 doesn't hold that scope); use trash — Gmail empties it after 30 days".into());
    }
    let (engine, account, k) = (engine.clone(), account_key.to_string(), keys.clone());
    let result = tauri::async_runtime::block_on(async move {
        if mx {
            engine.mx_delete(&account, &k).await
        } else {
            engine.perform_conversation_action(&account, &k, "delete").await
        }
    });
    outcome(result, "deleted", keys.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::events::NullSink;
    use crate::sync::store::SyncStore;

    #[test]
    fn inbox2_hosted_orgs_route_or_refuse_but_never_fake_success() {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let engine = Arc::new(SyncEngine::new(store, Arc::new(NullSink)));
        let conn = engine.store().connection();
        conn.lock()
            .execute("INSERT INTO mx_sync_state (organization_id, user_key) VALUES ('org_1', 'usr_1')", [])
            .unwrap();
        let writeback = engine.writeback().clone();

        // archive has an MX path: it goes to the MX action queue.
        let r = exec_archive(&conn, &writeback, &engine, &json!({ "account_key": "org_1", "conversation_keys": ["c1"] }));
        assert_eq!(r.is_error, None, "{}", r.first_text());
        assert!(r.first_text().contains("queued"));

        // Drafts take the MX path (here: no member directory, so no sender, not a
        // channel-account lookup); set_priority has none and says so.
        let r = exec_compose_draft(&conn, &engine, &json!({ "account_key": "org_1", "to": "a@b.c", "subject": "s", "body": "b" }));
        assert!(r.first_text().contains("no sending address"), "{}", r.first_text());
        let r = exec_set_priority(&conn, &engine, &json!({ "account_key": "org_1", "conversation_keys": ["c1"], "urgent": true, "important": true }));
        assert!(r.first_text().contains("inbox2-hosted"));
    }
}

/// Create an event on a connected Google/Microsoft calendar: the same engine call
/// the calendar's own "New event" makes.
// ponytail: no guests, so nothing is mailed to anyone and the tool stays ReadWrite.
// Guests would make it a Full-tier tool (it sends invitations).
pub(super) fn exec_create_calendar_event(
    conn: &Arc<Mutex<Connection>>,
    engine: &Arc<SyncEngine>,
    params: &Value,
) -> ToolResult {
    let account = required_str!(params, "account_key").to_string();
    for key in ["title", "start_at", "end_at"] {
        if params[key].as_str().is_none_or(str::is_empty) {
            return ToolResult::error(format!("{key} is required"));
        }
    }
    let text = |key: &str| params[key].as_str().map(String::from);
    let all_day = params["all_day"].as_bool().unwrap_or(false);
    // The adapters read a missing zone as UTC, and Graph takes the wall clock: 14:00+01:00
    // without a zone would land at 14:00 UTC there.
    if !all_day && text("timezone").is_none_or(|z| z.parse::<chrono_tz::Tz>().is_err()) {
        return ToolResult::error("timezone is required for a timed event: an IANA zone such as Europe/Amsterdam".into());
    }
    // Graph keeps the wall clock and drops the offset, so the offset must be the zone's own.
    if !all_day {
        use chrono::Offset;
        let tz: chrono_tz::Tz = text("timezone").unwrap_or_default().parse().unwrap_or(chrono_tz::UTC);
        for key in ["start_at", "end_at"] {
            let Ok(at) = chrono::DateTime::parse_from_rfc3339(params[key].as_str().unwrap_or("")) else {
                return ToolResult::error(format!("{key} must be RFC 3339 with an offset, such as 2026-12-11T16:00:00+01:00"));
            };
            if at.with_timezone(&tz).offset().fix() != *at.offset() {
                return ToolResult::error(format!("{key} has an offset that is not {tz}'s at that time"));
            }
        }
    }
    let draft = crate::sync::calendar::EventDraft {
        title: text("title").unwrap_or_default(),
        start_at: text("start_at").unwrap_or_default(),
        end_at: text("end_at").unwrap_or_default(),
        description: text("description"),
        location: text("location"),
        timezone: text("timezone"),
        all_day,
        ..Default::default()
    };
    // The named calendar, else the account's primary one.
    let calendar: Option<String> = conn
        .lock()
        .query_row(
            "SELECT provider_id FROM calendars
              WHERE account_key = ?1 AND coalesce(is_writable, 1) = 1 AND (?2 IS NULL OR name = ?2)
              ORDER BY is_primary DESC, coalesce(is_owned, 1) DESC LIMIT 1",
            params![account, params["calendar"].as_str()],
            |r| r.get(0),
        )
        .ok();
    let Some(calendar) = calendar else {
        return ToolResult::error("No writable calendar found for this account".into());
    };
    let engine = engine.clone();
    let acct = account.clone();
    match tauri::async_runtime::block_on(async move { engine.create_calendar_event(&acct, &calendar, draft).await }) {
        Ok(id) => ToolResult::json(&json!({ "key": format!("cev_{account}_{id}"), "provider_id": id })),
        Err(e) => ToolResult::error(e.to_string()),
    }
}
