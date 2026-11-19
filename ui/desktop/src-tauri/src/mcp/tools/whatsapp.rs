//! WhatsApp for agents: the same read-only queries the WhatsApp tab runs over
//! WhatsApp Desktop's own database (docs/Local-WhatsApp.md). Read only; sending
//! stays in the app.

use serde_json::{json, Value};

use crate::mcp::protocol::ToolResult;
use crate::whatsapp::{wa_chats, wa_messages, wa_search};

/// Unix ms as local RFC 3339, so "tomorrow at three" in a chat reads against the right day.
fn local(ms: i64) -> Option<String> {
    use chrono::TimeZone;
    chrono::Local.timestamp_millis_opt(ms).single().map(|t| t.to_rfc3339())
}

fn limit(params: &Value, default: i64) -> i64 {
    params["limit"].as_i64().unwrap_or(default).clamp(1, 500)
}

pub(super) fn exec_chats(params: &Value) -> ToolResult {
    let query = params["query"].as_str().unwrap_or("").to_lowercase();
    let limit = limit(params, 50) as usize;
    match tauri::async_runtime::block_on(wa_chats()) {
        Ok(chats) => ToolResult::json(
            &chats
                .iter()
                .filter(|c| query.is_empty() || c.name.to_lowercase().contains(&query))
                .take(limit)
                .map(|c| {
                    json!({
                        "chat_id": c.id, "name": c.name, "is_group": c.is_group, "archived": c.archived,
                        "unread": c.unread, "last_text": c.last_text, "last_at": local(c.last_at),
                    })
                })
                .collect::<Vec<_>>(),
        ),
        Err(e) => ToolResult::error(e),
    }
}

pub(super) fn exec_messages(params: &Value) -> ToolResult {
    let Some(chat_id) = params["chat_id"].as_i64() else {
        return ToolResult::error("chat_id is required".into());
    };
    // wa_messages takes any id; only a chat the list shows (not removed, not hidden) is readable.
    // ponytail: loads the chat list per call; a by-id lookup if that gets slow.
    match tauri::async_runtime::block_on(wa_chats()) {
        Ok(chats) if chats.iter().any(|c| c.id == chat_id) => {}
        Ok(_) => return ToolResult::error("No such chat".into()),
        Err(e) => return ToolResult::error(e),
    }
    let page = wa_messages(chat_id, params["before"].as_i64(), None, Some(limit(params, 50)));
    match tauri::async_runtime::block_on(page) {
        Ok(page) => ToolResult::json(&json!({
            "has_earlier": page.has_earlier,
            "messages": page.messages.iter().map(|m| json!({
                "id": m.id, "at": local(m.at), "from_me": m.from_me, "sender": m.sender, "text": m.text,
                "attachment": m.media.as_ref().and_then(|a| a.name.clone().or(a.title.clone())),
            })).collect::<Vec<_>>(),
        })),
        Err(e) => ToolResult::error(e),
    }
}

pub(super) fn exec_search(params: &Value) -> ToolResult {
    let query = required_str!(params, "query").to_string();
    match tauri::async_runtime::block_on(wa_search(query, Some(limit(params, 50)))) {
        Ok(hits) => ToolResult::json(
            &hits
                .iter()
                .map(|h| {
                    json!({
                        "id": h.id, "chat_id": h.chat_id, "chat_name": h.chat_name, "is_group": h.is_group,
                        "from_me": h.from_me, "sender": h.sender, "at": local(h.at), "text": h.text,
                    })
                })
                .collect::<Vec<_>>(),
        ),
        Err(e) => ToolResult::error(e),
    }
}
