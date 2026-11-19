use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::mcp::protocol::ToolResult;
use crate::sync::engine::SyncEngine;
use crate::sync::threading::html_to_text;
use crate::vector::search;
use crate::vector::store::VectorStore;

/// Prepare a query, run it, and collect mapped rows. Returns the SQL error as a
/// string instead of panicking — a malformed query or schema must surface as a
/// JSON-RPC tool error, never a panic that drops the MCP HTTP worker.
fn query_rows<P: rusqlite::Params>(
    conn: &Connection,
    sql: &str,
    params: P,
    map: impl FnMut(&rusqlite::Row) -> rusqlite::Result<Value>,
) -> std::result::Result<Vec<Value>, String> {
    let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
    let rows = stmt.query_map(params, map).map_err(|e| e.to_string())?;
    Ok(rows.filter_map(|r| r.ok()).collect())
}

/// Channel adapters store every message as inbound (sync_flow.rs), so mail the
/// user sent reads as received. The account's own address as sender says otherwise.
// ponytail: primary address only; aliases (another From on the same mailbox) still read inbound.
const INBOUND: &str = "CASE WHEN COALESCE(e.email_address, '') <> ''
         AND instr(lower(COALESCE(a.from_address, '')), lower(e.email_address)) > 0
    THEN 0 ELSE a.is_inbound END";

/// Bodies as an agent should get them: the plain part, or the HTML rendered to
/// text when there's no plain one. The HTML itself only on request — it is the
/// same text again plus markup, and inline `data:` images can make it 300× the size.
fn readable(plain: Option<String>, html: Option<String>, keep_html: bool) -> (Option<String>, Option<String>) {
    let plain = match plain.filter(|p| !p.trim().is_empty()) {
        Some(p) => Some(p),
        None => html.as_deref().filter(|h| !h.trim().is_empty()).map(html_to_text),
    };
    (plain, if keep_html { html } else { None })
}

fn empty(body: &Option<String>) -> bool {
    body.as_deref().is_none_or(|b| b.trim().is_empty())
}

/// A connected-mailbox message synced without its body (Microsoft, and older
/// mail) — fetch it from the provider, as the reading pane does. The fetch also
/// stores it, so call this with the connection unlocked.
fn hydrate(engine: &Arc<SyncEngine>, account: &str, key: &str) -> Option<(Option<String>, Option<String>)> {
    if account.starts_with("org_") {
        return None; // inbox2-hosted: the mirror has the body or the mail is sealed
    }
    let engine = engine.clone();
    let (account, key) = (account.to_string(), key.to_string());
    tauri::async_runtime::block_on(async move {
        let fetched = engine.interactive_provider(&account).ok()?.fetch_message(&key).await.ok()?;
        Some((fetched.body_plain, fetched.body_html))
    })
}

/// Most bodies a single read_conversation fetches from the provider.
// ponytail: fixed cap; a long un-synced thread shows the rest as empty until read again.
const MAX_HYDRATE: usize = 10;

fn is_reply_subject(subject: &str) -> bool {
    let s = subject.trim_start().to_ascii_lowercase();
    ["re:", "antw:", "aw:", "sv:"].iter().any(|p| s.starts_with(p))
}

/// Cut a reply at its quoted history: an "On … wrote:" / "Op … schreef" header
/// (possibly wrapped over three lines), or an Outlook "From:/Van:" block. None
/// when nothing was found. Forwards aren't passed in — their tail IS the content.
fn strip_quoted(body: &str) -> Option<String> {
    let lines: Vec<&str> = body.lines().collect();
    let is_from = |l: &str| l.starts_with("From:") || l.starts_with("Van:") || l.starts_with("*From:*");
    let is_sent = |l: &str| ["Sent:", "Date:", "Verzonden:", "Datum:", "*Sent:*"].iter().any(|p| l.starts_with(p));
    let cut = (0..lines.len()).find(|&i| {
        let l = lines[i].trim_start_matches('>').trim();
        let head = ["On ", "Op ", "Le ", "Am ", "El "].iter().any(|p| l.starts_with(p)) && {
            let span = lines[i..lines.len().min(i + 3)].join(" ");
            ["wrote:", "schreef", "a écrit", "schrieb", "escribió"].iter().any(|w| span.contains(w))
        };
        let outlook = l.starts_with("-----Original Message-----")
            || l.starts_with("-----Oorspronkelijk bericht-----")
            || (is_from(l) && lines.get(i + 1).is_some_and(|n| is_sent(n.trim())));
        head || outlook
    })?;
    // A reply that is nothing but the quote: leave it whole.
    if lines[..cut].iter().all(|l| l.trim().is_empty() || l.trim().starts_with("____")) {
        return None;
    }
    let kept = lines[..cut].join("\n");
    Some(format!("{}\n[quoted history trimmed; include_quoted: true for the full body]", kept.trim_end().trim_end_matches('_').trim_end()))
}

pub(super) fn exec_search_messages(
    conn: &Arc<Mutex<Connection>>,
    _vector_store: &Arc<VectorStore>,
    params: &Value,
) -> ToolResult {
    let query = params["query"].as_str().unwrap_or("");
    let limit = params["limit"].as_u64().unwrap_or(20) as usize;
    let account = params["account_key"].as_str();
    let window = search::Window {
        after: params["after"].as_str(),
        before: params["before"].as_str(),
        newest_first: params["sort"].as_str() == Some("date"),
    };
    let with_junk = params["include_spam_trash"].as_bool() == Some(true);

    // Keyword search (FTS5) over connected mailboxes and, separately, the MX
    // mirror's own index (docs/MX-Sync.md) — through `agent_messages`, so sealed
    // mail can't match: an MCP client may be a cloud model.
    let run = |channel_query: &str, mx_query: Option<String>| -> Result<(Vec<Value>, Vec<Value>), String> {
        let channel = search::keyword_search(conn, channel_query, limit, account, window)
            .map_err(|e| e.to_string())?
            .into_iter()
            .filter_map(|r| serde_json::to_value(r).ok())
            .collect();
        let Some(fts) = mx_query else { return Ok((channel, Vec::new())) };
        let conn = conn.lock();
        let mx = query_rows(
            &conn,
            &format!(
                "SELECT a.key, a.conversation_key, a.subject, a.from_address, substr(COALESCE(a.body_plain, ''), 1, 800),
                        a.created_at, a.account_key, bm25(mx_messages_fts)
                 FROM mx_messages_fts f JOIN mx_messages m ON m.id = f.rowid JOIN agent_messages a ON a.key = m.key
                 JOIN agent_conversations c ON c.key = a.conversation_key
                 WHERE mx_messages_fts MATCH ?1 AND (?2 IS NULL OR a.account_key = ?2)
                   AND (?4 IS NULL OR m.created_at >= ?4) AND (?5 IS NULL OR m.created_at < ?5)
                   -- Spam and trash stay out by default: on a hosted domain they're most of
                   -- the mail, and every one matches the domain's own name through its recipient.
                   AND (?6 OR c.status NOT IN ('spam', 'trash'))
                 ORDER BY {} LIMIT ?3",
                if window.newest_first { "m.created_at DESC" } else { "bm25(mx_messages_fts)" }
            ),
            params![fts, account, limit as i64, window.after, window.before, with_junk],
            |row| {
                // Same fields as `search::SearchResult`.
                Ok(json!({
                    "message_key": row.get::<_, String>(0)?,
                    "conversation_key": row.get::<_, String>(1)?,
                    "subject": row.get::<_, Option<String>>(2)?,
                    "from_address": row.get::<_, Option<String>>(3)?,
                    "snippet": row.get::<_, String>(4)?.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(200).collect::<String>(),
                    "score": -row.get::<_, f64>(7)?,
                    "created_at": row.get::<_, Option<String>>(5)?,
                    "account_key": row.get::<_, Option<String>>(6)?,
                }))
            },
        )?;
        Ok((channel, mx))
    };
    let (mut channel, mut mx) = match run(query, crate::sync::store::mx::fts_query(query)) {
        Ok(found) => found,
        Err(e) => return ToolResult::error(e),
    };
    // Every word must match, so a natural multi-word query often finds nothing.
    // Then take mail matching any of the words, best first, and say so.
    let words: Vec<&str> = query.split_whitespace().collect();
    if channel.is_empty() && mx.is_empty() && words.len() > 1 && !words.iter().any(|w| matches!(*w, "OR" | "AND" | "NOT")) {
        let mx_any = crate::sync::store::mx::fts_query(query).map(|q| q.replace("* \"", "* OR \""));
        if let Ok((c, m)) = run(&words.join(" OR "), mx_any) {
            (channel, mx) = (c, m);
            for v in channel.iter_mut().chain(mx.iter_mut()) {
                v["matched"] = json!("any_word");
            }
        }
    }
    ToolResult::json(&merge(channel, mx, window.newest_first, limit))
}

/// The two indexes' bm25 scores aren't comparable — corpus statistics differ, and
/// a large Gmail index outscored a hosted invoice 40 to 6 — so relevance merges
/// by rank: each source's best, then each one's second best, and so on.
fn merge(channel: Vec<Value>, mx: Vec<Value>, newest_first: bool, limit: usize) -> Vec<Value> {
    let mut all: Vec<(usize, Value)> = channel.into_iter().enumerate().chain(mx.into_iter().enumerate()).collect();
    if newest_first {
        all.sort_by(|a, b| b.1["created_at"].as_str().unwrap_or("").cmp(a.1["created_at"].as_str().unwrap_or("")));
    } else {
        all.sort_by_key(|(rank, _)| *rank);
    }
    all.into_iter().take(limit).map(|(_, v)| v).collect()
}

pub(super) fn exec_search_similar(conn: &Arc<Mutex<Connection>>, params: &Value) -> ToolResult {
    let message_key = required_str!(params, "message_key");
    let limit = params["limit"].as_u64().unwrap_or(10) as usize;

    match search::search_similar(conn, message_key, limit) {
        Ok(results) => ToolResult::json(&results),
        Err(e) => ToolResult::error(e.to_string()),
    }
}

pub(super) fn exec_read_message(conn: &Arc<Mutex<Connection>>, engine: &Arc<SyncEngine>, params: &Value) -> ToolResult {
    let key = required_str!(params, "message_key");
    let keep_html = params["include_html"].as_bool() == Some(true);
    let result: Option<Value> = conn
        .lock()
        .query_row(
            &format!(
                "SELECT a.key, a.conversation_key, a.from_address, a.to_address, a.cc_address,
                        a.subject, a.body_plain, a.body_html, {INBOUND}, a.is_draft,
                        a.message_id_header, a.created_at, a.account_key
                 FROM agent_messages a LEFT JOIN external_accounts e ON e.key = a.account_key
                 WHERE a.key = ?1"
            ),
            params![key],
            |row| {
                Ok(json!({
                    "key": row.get::<_, String>(0)?,
                    "conversation_key": row.get::<_, String>(1)?,
                    "from": row.get::<_, Option<String>>(2)?,
                    "to": row.get::<_, Option<String>>(3)?,
                    "cc": row.get::<_, Option<String>>(4)?,
                    "subject": row.get::<_, Option<String>>(5)?,
                    "body_plain": row.get::<_, Option<String>>(6)?,
                    "body_html": row.get::<_, Option<String>>(7)?,
                    "is_inbound": row.get::<_, i32>(8)? != 0,
                    "is_draft": row.get::<_, i32>(9)? != 0,
                    "message_id": row.get::<_, Option<String>>(10)?,
                    "created_at": row.get::<_, Option<String>>(11)?,
                    "account_key": row.get::<_, Option<String>>(12)?,
                }))
            },
        )
        .optional()
        .unwrap_or(None);

    let Some(mut msg) = result else {
        return ToolResult::error(format!("Message '{key}' not found"));
    };
    let mut plain = msg["body_plain"].as_str().map(String::from);
    let mut html = msg["body_html"].as_str().map(String::from);
    if empty(&plain) && empty(&html) {
        if let Some(fetched) = hydrate(engine, msg["account_key"].as_str().unwrap_or(""), key) {
            (plain, html) = fetched;
        }
    }
    let (plain, html) = readable(plain, html, keep_html);
    msg["body_plain"] = json!(plain);
    msg["body_html"] = json!(html);
    ToolResult::json(&msg)
}

pub(super) fn exec_read_conversation(conn: &Arc<Mutex<Connection>>, engine: &Arc<SyncEngine>, params: &Value) -> ToolResult {
    let key = required_str!(params, "conversation_key");
    let guard = conn.lock();
    let conn = &*guard;

    // Get conversation metadata
    let conv: Option<Value> = conn
        .query_row(
            "SELECT key, subject, from_address, to_address, status, read,
                    priority_urgent, priority_important, created_at, organization_id
             FROM agent_conversations WHERE key = ?1",
            params![key],
            |row| {
                Ok(json!({
                    "key": row.get::<_, String>(0)?,
                    "subject": row.get::<_, Option<String>>(1)?,
                    "from": row.get::<_, Option<String>>(2)?,
                    "to": row.get::<_, Option<String>>(3)?,
                    "status": row.get::<_, String>(4)?,
                    "read": row.get::<_, i32>(5)? != 0,
                    "urgent": row.get::<_, i32>(6)? != 0,
                    "important": row.get::<_, i32>(7)? != 0,
                    "created_at": row.get::<_, Option<String>>(8)?,
                    "account_key": row.get::<_, String>(9)?,
                }))
            },
        )
        .optional()
        .unwrap_or(None);

    let Some(conv) = conv else {
        return ToolResult::error(format!("Conversation '{key}' not found"));
    };

    // Get all messages in the thread
    let messages: Vec<Value> = match query_rows(
        conn,
        &format!(
            "SELECT a.key, a.from_address, a.to_address, a.cc_address, a.subject,
                    a.body_plain, {INBOUND}, a.created_at, a.body_html, a.account_key
             FROM agent_messages a LEFT JOIN external_accounts e ON e.key = a.account_key
             WHERE a.conversation_key = ?1 ORDER BY a.created_at"
        ),
        params![key],
        |row| {
            Ok(json!({
                "key": row.get::<_, String>(0)?,
                "from": row.get::<_, Option<String>>(1)?,
                "to": row.get::<_, Option<String>>(2)?,
                "cc": row.get::<_, Option<String>>(3)?,
                "subject": row.get::<_, Option<String>>(4)?,
                "body_plain": row.get::<_, Option<String>>(5)?,
                "is_inbound": row.get::<_, i32>(6)? != 0,
                "created_at": row.get::<_, Option<String>>(7)?,
                "body_html": row.get::<_, Option<String>>(8)?,
                "account_key": row.get::<_, Option<String>>(9)?,
            }))
        },
    ) {
        Ok(msgs) => msgs,
        Err(e) => return ToolResult::error(e),
    };
    drop(guard); // hydrate() writes the fetched bodies back through the store

    let mut messages = messages;
    let mut fetched = 0;
    for m in messages.iter_mut() {
        let mut plain = m["body_plain"].as_str().map(String::from);
        let mut html = m["body_html"].as_str().map(String::from);
        if empty(&plain) && empty(&html) && fetched < MAX_HYDRATE {
            fetched += 1;
            let (account, mkey) = (m["account_key"].as_str().unwrap_or(""), m["key"].as_str().unwrap_or(""));
            if let Some(bodies) = hydrate(engine, account, mkey) {
                (plain, html) = bodies;
            }
        }
        let obj = m.as_object_mut().expect("row is an object");
        obj.remove("body_html");
        obj.remove("account_key");
        obj.insert("body_plain".into(), json!(readable(plain, html, false).0));
    }

    // Each reply re-quotes the whole thread (plus every signature and legal
    // disclaimer); the earlier messages are already in this list.
    if params["include_quoted"].as_bool() != Some(true) {
        for m in messages.iter_mut().skip(1) {
            let reply = m["subject"].as_str().is_some_and(is_reply_subject);
            if let (true, Some(body)) = (reply, m["body_plain"].as_str()) {
                if let Some(cut) = strip_quoted(body) {
                    m["body_plain"] = Value::String(cut);
                }
            }
        }
    }
    let result = json!({
        "conversation": conv,
        "messages": messages,
        "message_count": messages.len(),
    });
    ToolResult::json(&result)
}

pub(super) fn exec_list_conversations(conn: &Arc<Mutex<Connection>>, params: &Value) -> ToolResult {
    let status = params["status"].as_str();
    let account = params["account_key"].as_str();
    let limit = params["limit"].as_u64().unwrap_or(50) as i32;
    let offset = params["offset"].as_u64().unwrap_or(0) as i32;

    let conn = conn.lock();
    let sql = match (status, account) {
        (Some(_), Some(_)) => {
            "SELECT key, subject, from_address, to_address, status, snippet, read,
                    priority_urgent, priority_important, created_at, updated_at, organization_id
             FROM agent_conversations WHERE status = ?1 AND organization_id = ?2
             ORDER BY updated_at DESC LIMIT ?3 OFFSET ?4"
        }
        (Some(_), None) => {
            "SELECT key, subject, from_address, to_address, status, snippet, read,
                    priority_urgent, priority_important, created_at, updated_at, organization_id
             FROM agent_conversations WHERE status = ?1
             ORDER BY updated_at DESC LIMIT ?2 OFFSET ?3"
        }
        (None, Some(_)) => {
            "SELECT key, subject, from_address, to_address, status, snippet, read,
                    priority_urgent, priority_important, created_at, updated_at, organization_id
             FROM agent_conversations WHERE organization_id = ?1
             ORDER BY updated_at DESC LIMIT ?2 OFFSET ?3"
        }
        (None, None) => {
            "SELECT key, subject, from_address, to_address, status, snippet, read,
                    priority_urgent, priority_important, created_at, updated_at, organization_id
             FROM agent_conversations ORDER BY updated_at DESC LIMIT ?1 OFFSET ?2"
        }
    };

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(e) => return ToolResult::error(e.to_string()),
    };

    let map_row = |row: &rusqlite::Row| -> rusqlite::Result<Value> {
        Ok(json!({
            "key": row.get::<_, String>(0)?,
            "subject": row.get::<_, Option<String>>(1)?,
            "from": row.get::<_, Option<String>>(2)?,
            "to": row.get::<_, Option<String>>(3)?,
            "status": row.get::<_, String>(4)?,
            "snippet": row.get::<_, Option<String>>(5)?,
            "read": row.get::<_, i32>(6)? != 0,
            "urgent": row.get::<_, i32>(7)? != 0,
            "important": row.get::<_, i32>(8)? != 0,
            "created_at": row.get::<_, Option<String>>(9)?,
            "updated_at": row.get::<_, Option<String>>(10)?,
            "account_key": row.get::<_, String>(11)?,
        }))
    };

    let rows = match (status, account) {
        (Some(s), Some(a)) => stmt.query_map(params![s, a, limit, offset], map_row),
        (Some(s), None) => stmt.query_map(params![s, limit, offset], map_row),
        (None, Some(a)) => stmt.query_map(params![a, limit, offset], map_row),
        (None, None) => stmt.query_map(params![limit, offset], map_row),
    };
    let results: Vec<Value> = match rows {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => return ToolResult::error(e.to_string()),
    };

    ToolResult::json(&results)
}

pub(super) fn exec_list_accounts(conn: &Arc<Mutex<Connection>>) -> ToolResult {
    let conn = conn.lock();
    match query_rows(
        &conn,
        "SELECT key, display_name, email_address, provider_type, status, last_connected_at
         FROM external_accounts ORDER BY sort_order",
        [],
        |row| {
            Ok(json!({
                "key": row.get::<_, String>(0)?,
                "display_name": row.get::<_, String>(1)?,
                "email_address": row.get::<_, String>(2)?,
                "provider_type": row.get::<_, String>(3)?,
                "status": row.get::<_, String>(4)?,
                "last_connected_at": row.get::<_, Option<String>>(5)?,
            }))
        },
    ) {
        Ok(mut accounts) => {
            // inbox2-hosted orgs mirrored on this device (docs/MX-Sync.md); their key
            // is the `account_key` on MX threads in the other read tools.
            let orgs = query_rows(
                &conn,
                // Your own mailboxes, and the domains whose mail the org holds — a
                // thread here can be addressed to any of them.
                "SELECT s.organization_id, json_extract(d.payload, '$.name'), s.backfill_done,
                        (SELECT json_extract(m.payload, '$.email_addresses') FROM mx_directory m
                          WHERE m.organization_id = s.organization_id AND m.type = 'members'
                            AND json_extract(m.payload, '$.user.id') = s.user_key),
                        (SELECT json_group_array(json_extract(n.payload, '$.name')) FROM mx_directory n
                          WHERE n.organization_id = s.organization_id AND n.type = 'domains')
                 FROM mx_sync_state s LEFT JOIN mx_directory d
                   ON d.organization_id = s.organization_id AND d.type = 'organization'",
                [],
                |row| {
                    let list = |i| -> rusqlite::Result<Value> {
                        Ok(row.get::<_, Option<String>>(i)?.and_then(|j| serde_json::from_str(&j).ok()).unwrap_or(json!([])))
                    };
                    let addresses = list(3)?;
                    Ok(json!({
                        "key": row.get::<_, String>(0)?,
                        "display_name": row.get::<_, Option<String>>(1)?,
                        "email_address": addresses.get(0).cloned().unwrap_or(Value::Null),
                        "email_addresses": addresses,
                        "domains": list(4)?,
                        "provider_type": "inbox2",
                        "status": if row.get::<_, i64>(2)? != 0 { "connected" } else { "syncing" },
                        "last_connected_at": Value::Null,
                    }))
                },
            );
            accounts.extend(orgs.unwrap_or_default());
            ToolResult::json(&accounts)
        }
        Err(e) => ToolResult::error(e),
    }
}

pub(super) fn exec_list_folders(conn: &Arc<Mutex<Connection>>, params: &Value) -> ToolResult {
    let account_key = required_str!(params, "account_key");
    let conn = conn.lock();
    // An inbox2-hosted org has no folders: its move targets are the status
    // folders and its Spaces, and its tags live beside them.
    let is_mx = conn
        .query_row("SELECT 1 FROM mx_sync_state WHERE organization_id = ?1", params![account_key], |_| Ok(()))
        .is_ok();
    if is_mx {
        let mut out: Vec<Value> = ["inbox", "archive", "trash", "spam"]
            .iter()
            .map(|r| json!({ "key": r, "name": r, "kind": "status" }))
            .collect();
        let dir = query_rows(
            &conn,
            "SELECT key, json_extract(payload, '$.name'), json_extract(payload, '$.slug'),
                    CASE type WHEN 'spaces' THEN 'space' ELSE 'tag' END
             FROM mx_directory WHERE organization_id = ?1 AND type IN ('spaces', 'tags')
             ORDER BY type, position",
            params![account_key],
            |row| {
                Ok(json!({
                    "key": row.get::<_, String>(0)?,
                    "name": row.get::<_, Option<String>>(1)?,
                    "slug": row.get::<_, Option<String>>(2)?,
                    "kind": row.get::<_, String>(3)?,
                }))
            },
        );
        match dir {
            Ok(rows) => out.extend(rows),
            Err(e) => return ToolResult::error(e),
        }
        return ToolResult::json(&out);
    }
    match query_rows(
        &conn,
        "SELECT key, provider_name, well_known_role, sync_enabled, last_sync_at
         FROM external_folders WHERE account_key = ?1 ORDER BY provider_name",
        params![account_key],
        |row| {
            Ok(json!({
                "key": row.get::<_, String>(0)?,
                "name": row.get::<_, String>(1)?,
                "role": row.get::<_, Option<String>>(2)?,
                "sync_enabled": row.get::<_, i32>(3)? != 0,
                "last_sync_at": row.get::<_, Option<String>>(4)?,
            }))
        },
    ) {
        Ok(folders) => ToolResult::json(&folders),
        Err(e) => ToolResult::error(e),
    }
}

/// `2023-01-01` or any RFC 3339 instant, as RFC 3339 UTC; None if neither.
fn rfc3339(s: &str) -> Option<String> {
    let at = chrono::DateTime::parse_from_rfc3339(s).map(|d| d.with_timezone(&chrono::Utc)).ok().or_else(|| {
        chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok().map(|d| d.and_hms_opt(0, 0, 0).unwrap().and_utc())
    })?;
    Some(at.to_rfc3339())
}

pub(super) fn exec_get_calendar_events(
    conn: &Arc<Mutex<Connection>>,
    engine: &Arc<SyncEngine>,
    params: &Value,
) -> ToolResult {
    let start = required_str!(params, "start");
    let end = required_str!(params, "end");
    let account = params["account_key"].as_str().map(String::from);
    let (Some(min), Some(max)) = (rfc3339(start), rfc3339(end)) else {
        return ToolResult::error("start and end must be YYYY-MM-DD or RFC 3339".into());
    };

    // Both paths return the same shape and the same overlap rule as the provider
    // APIs: an event matches when it starts before `end` and ends after `start`.
    let event = |key: String, acct: &str, cal: Option<String>, e: &crate::sync::calendar::UnifiedEvent| {
        json!({
            "key": key,
            "title": e.title,
            "description": e.description,
            "location": e.location,
            "start_at": e.start_at,
            "end_at": e.end_at,
            "all_day": e.all_day,
            "timezone": e.timezone,
            "status": e.status,
            "organizer": e.organizer_email,
            "account_key": acct,
            "calendar": cal,
        })
    };

    // The local mirror only holds `time_window()`; outside it, ask the provider.
    let (win_min, win_max) = crate::sync::calendar::time_window();
    let at = |s: &str| chrono::DateTime::parse_from_rfc3339(s).unwrap();
    if at(&min) < at(&win_min) || at(&max) > at(&win_max) {
        let engine = engine.clone();
        let fetched = tauri::async_runtime::block_on(async move {
            engine.fetch_calendar_events(account.as_deref(), &min, &max).await
        });
        return match fetched {
            Ok((events, failed)) => ToolResult::json(&json!({
                "source": "provider",
                "events": events.iter().map(|(acct, cal, e)| {
                    // Same key the sync would store it under.
                    event(format!("cev_{acct}_{}", e.provider_id), acct, Some(cal.clone()), e)
                }).collect::<Vec<_>>(),
                "failed_calendars": failed,
            })),
            Err(e) => ToolResult::error(e.to_string()),
        };
    }

    // Stored times are the provider's own strings (mixed UTC offsets, bare dates
    // for all-day), so compare as instants, not text.
    let conn = conn.lock();
    let events = query_rows(
        &conn,
        "SELECT e.key, e.account_key, c.name, e.title, e.description, e.location, e.start_at,
                e.end_at, e.all_day, e.timezone, e.status, e.organizer_email
         FROM calendar_events e
         LEFT JOIN calendars c ON c.key = e.calendar_key
         WHERE julianday(e.start_at) < julianday(?2) AND julianday(e.end_at) > julianday(?1)
           AND (?3 IS NULL OR e.account_key = ?3)
         ORDER BY julianday(e.start_at)",
        params![min, max, account],
        |row| {
            let ev = crate::sync::calendar::UnifiedEvent {
                title: row.get(3)?,
                description: row.get(4)?,
                location: row.get(5)?,
                start_at: row.get(6)?,
                end_at: row.get(7)?,
                all_day: row.get::<_, i32>(8)? != 0,
                timezone: row.get::<_, Option<String>>(9)?.unwrap_or_default(),
                status: row.get::<_, Option<String>>(10)?.unwrap_or_default(),
                organizer_email: row.get(11)?,
                ..Default::default()
            };
            let acct: String = row.get(1)?;
            Ok(event(row.get(0)?, &acct, row.get(2)?, &ev))
        },
    );
    match events {
        Ok(events) => ToolResult::json(&json!({ "source": "local", "events": events, "failed_calendars": [] })),
        Err(e) => ToolResult::error(e),
    }
}

pub(super) fn exec_get_contact_context(conn: &Arc<Mutex<Connection>>, params: &Value) -> ToolResult {
    let email = required_str!(params, "email_address");
    let conn = conn.lock();
    let pattern = format!("%{email}%");

    let conversations: Vec<Value> = match query_rows(
        &conn,
        "SELECT DISTINCT c.key, c.subject, c.status, c.updated_at, c.organization_id
         FROM conversations c
         JOIN messages m ON m.conversation_key = c.key
         WHERE m.from_address LIKE ?1 OR m.to_address LIKE ?1 OR m.cc_address LIKE ?1
         ORDER BY c.updated_at DESC
         LIMIT 50",
        params![pattern],
        |row| {
            Ok(json!({
                "conversation_key": row.get::<_, String>(0)?,
                "subject": row.get::<_, Option<String>>(1)?,
                "status": row.get::<_, String>(2)?,
                "last_activity": row.get::<_, Option<String>>(3)?,
                "account_key": row.get::<_, String>(4)?,
            }))
        },
    ) {
        Ok(convs) => convs,
        Err(e) => return ToolResult::error(e),
    };

    let msg_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM messages
             WHERE from_address LIKE ?1 OR to_address LIKE ?1 OR cc_address LIKE ?1",
            params![pattern],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let result = json!({
        "email_address": email,
        "total_messages": msg_count,
        "conversations": conversations,
    });
    ToolResult::json(&result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_gmail_outlook_and_dutch_quote_headers() {
        let gmail = "Thanks.\r\n\r\nOn Mon, Sep 16, 2019 at 11:22 AM Zijlstra, O.M. (Oscar) <\r\noscar@rvo.nl> wrote:\r\n> old";
        assert_eq!(strip_quoted(gmail).unwrap().lines().next(), Some("Thanks."));
        let dutch = "Prima\r\nOp ma 16 sep. 2019 om 11:21 schreef X:\r\n> old";
        assert!(strip_quoted(dutch).unwrap().starts_with("Prima\n[quoted"));
        let outlook = "Ja\r\n________________________________\r\nFrom: A\r\nSent: Tuesday\r\nold";
        assert!(strip_quoted(outlook).unwrap().starts_with("Ja\n[quoted"));
        let van = "Graag gedaan\r\n\r\nVan: Waseem [mailto:w@s.nl]\r\nVerzonden: dinsdag\r\nold";
        assert!(strip_quoted(van).unwrap().starts_with("Graag gedaan\n[quoted"));
        let french = "Merci\n\nLe mar. 16 juin 2026 à 00:28, Waseem <w@e.me> a écrit :\n\nold";
        assert!(strip_quoted(french).unwrap().starts_with("Merci\n[quoted"));
        assert_eq!(strip_quoted("no quote here"), None);
        assert_eq!(strip_quoted("On Mon X wrote:\n> only a quote"), None);
    }

    #[test]
    fn reply_subjects_and_html_fallback() {
        assert!(is_reply_subject("RE: wbso"));
        assert!(!is_reply_subject("Fwd: WBSO-aanvragen"));
    }

    #[test]
    fn merge_interleaves_by_rank_not_raw_score() {
        let hit = |k: &str, score: f64, at: &str| json!({"message_key": k, "score": score, "created_at": at});
        let gmail = vec![hit("g1", 40.0, "2023-01-01"), hit("g2", 30.0, "2023-02-01")];
        let mx = vec![hit("x1", 6.0, "2026-09-28")];
        let keys = |v: Vec<Value>| v.iter().map(|r| r["message_key"].as_str().unwrap().to_string()).collect::<Vec<_>>();
        assert_eq!(keys(merge(gmail.clone(), mx.clone(), false, 2)), ["g1", "x1"]);
        assert_eq!(keys(merge(gmail, mx, true, 3)), ["x1", "g2", "g1"]);
    }
}

#[cfg(test)]
mod body_tests {
    use super::*;

    #[test]
    fn readable_prefers_plain_and_renders_html_only_mail() {
        let (p, h) = readable(Some("hi".into()), Some("<p>hi</p>".into()), false);
        assert_eq!((p.as_deref(), h), (Some("hi"), None));
        let (p, h) = readable(None, Some("<p>a</p><p>b</p>".into()), false);
        assert_eq!(p.as_deref(), Some("a\n\nb"));
        assert!(h.is_none());
        let (_, h) = readable(Some(" ".into()), Some("<p>x</p>".into()), true);
        assert_eq!(h.as_deref(), Some("<p>x</p>"));
        assert!(empty(&Some("  ".into())) && empty(&None));
    }
}
