use parking_lot::Mutex;
use rusqlite::Connection;
use serde_json::Value;
use std::sync::Arc;

use crate::mcp::permissions::PermissionLevel;
use crate::sync::actions::WritebackQueue;
use crate::sync::engine::SyncEngine;
use crate::vector::store::VectorStore;

/// Extract a required string argument, early-returning a `ToolResult` error from
/// the calling handler if it's missing. Replaces the
/// `match params["k"].as_str() { Some(v) => v, None => return ... }` pattern.
macro_rules! required_str {
    ($params:expr, $key:literal) => {
        match $params[$key].as_str() {
            Some(v) => v,
            None => return crate::mcp::protocol::ToolResult::error(concat!($key, " is required").into()),
        }
    };
}

mod attachments;
mod definitions;
mod read;
mod whatsapp;
mod write;

pub use definitions::tool_definitions;

/// Required permission level for each tool. Every advertised tool (see
/// [`tool_definitions`]) is listed; an unknown tool falls through to `Full`
/// (the most restrictive requirement) as a safe default.
/// Keep this in sync with [`tool_definitions`] and [`execute_tool`].
pub fn tool_permission(name: &str) -> PermissionLevel {
    match name {
        // Read-only
        "search_messages" | "search_similar" | "read_message" | "read_conversation"
        | "list_conversations" | "list_accounts" | "list_folders" | "get_calendar_events"
        | "get_contact_context" | "list_attachments" | "get_attachment" | "whatsapp_chats"
        | "whatsapp_messages" | "whatsapp_search" => PermissionLevel::Read,

        // Write
        "mark_read" | "mark_unread" | "archive" | "set_priority" | "compose_draft" | "add_tag"
        | "remove_tag" | "move_to_folder" | "create_calendar_event" => PermissionLevel::ReadWrite,

        // Privileged — may require approval (see `needs_approval`). Anything that
        // puts mail in someone else's inbox or destroys it lives here.
        "trash" | "send_message" | "create_conversation" | "delete" => PermissionLevel::Full,

        _ => PermissionLevel::Full,
    }
}

/// The MCP tool annotations (spec `ToolAnnotations`), so clients (Claude Code, Gluon) tell reads from writes without
/// guessing from names. `readOnlyHint` comes from [`tool_permission`], so the two cannot drift. A write is
/// `destructiveHint` unless it only adds (a draft, a tag, a new conversation, a sent message); a flag, a move, an
/// archive or a removed tag changes what was there. Idempotence and open-world are left at the spec's defaults (reads
/// may fetch from the provider, and a repeated flag still syncs).
pub fn tool_annotations(name: &str) -> Value {
    if tool_permission(name) == PermissionLevel::Read {
        return serde_json::json!({ "readOnlyHint": true });
    }
    let additive = matches!(name, "compose_draft" | "add_tag" | "create_conversation" | "send_message" | "create_calendar_event");
    serde_json::json!({ "readOnlyHint": false, "destructiveHint": !additive })
}

/// Execute a tool call against the local database.
pub fn execute_tool(
    conn: &Arc<Mutex<Connection>>,
    vector_store: &Arc<VectorStore>,
    writeback: &Arc<WritebackQueue>,
    engine: &Arc<SyncEngine>,
    name: &str,
    params: &Value,
) -> crate::mcp::protocol::ToolResult {
    use crate::mcp::protocol::ToolResult;
    match name {
        "search_messages" => read::exec_search_messages(conn, vector_store, params),
        "search_similar" => read::exec_search_similar(conn, params),
        "read_message" => read::exec_read_message(conn, engine, params),
        "read_conversation" => read::exec_read_conversation(conn, engine, params),
        "list_conversations" => read::exec_list_conversations(conn, params),
        "list_accounts" => read::exec_list_accounts(conn),
        "list_folders" => read::exec_list_folders(conn, params),
        "get_calendar_events" => read::exec_get_calendar_events(conn, engine, params),
        "get_contact_context" => read::exec_get_contact_context(conn, params),
        "list_attachments" => attachments::exec_list_attachments(conn, engine, params),
        "get_attachment" => attachments::exec_get_attachment(conn, engine, params),
        "mark_read" | "mark_unread" => write::exec_mark_read_unread(conn, writeback, engine, name, params),
        "archive" => write::exec_archive(conn, writeback, engine, params),
        "trash" => write::exec_trash(conn, writeback, engine, params),
        "set_priority" => write::exec_set_priority(conn, engine, params),
        "compose_draft" => write::exec_compose_draft(conn, engine, params),
        "send_message" => write::exec_send(conn, engine, params, true),
        "create_conversation" => write::exec_send(conn, engine, params, false),
        "add_tag" => write::exec_tag(conn, engine, params, true),
        "remove_tag" => write::exec_tag(conn, engine, params, false),
        "move_to_folder" => write::exec_move_to_folder(conn, engine, params),
        "delete" => write::exec_delete(conn, engine, params),
        "create_calendar_event" => write::exec_create_calendar_event(conn, engine, params),
        "whatsapp_chats" => whatsapp::exec_chats(params),
        "whatsapp_messages" => whatsapp::exec_messages(params),
        "whatsapp_search" => whatsapp::exec_search(params),
        _ => ToolResult::error(format!("Unknown tool '{name}'")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::engine::SyncEngine;
    use crate::sync::events::NullSink;
    use crate::sync::store::SyncStore;
    use serde_json::json;

    fn deps() -> (
        Arc<Mutex<Connection>>,
        Arc<VectorStore>,
        Arc<WritebackQueue>,
        Arc<SyncEngine>,
    ) {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let engine = Arc::new(SyncEngine::new(store, Arc::new(NullSink)));
        let conn = engine.store().connection();
        let writeback = engine.writeback().clone();
        let vector_store = Arc::new(VectorStore::new(conn.clone()));
        (conn, vector_store, writeback, engine)
    }

    /// The bug this guards against: a tool advertised in `tool_definitions()` but
    /// missing a dispatch arm in `execute_tool`, which silently fell through to
    /// the unknown-tool sentinel. Validation errors are fine; reaching the
    /// `Unknown tool` catch-all means the arm is missing.
    #[test]
    fn every_advertised_tool_has_a_dispatch_arm() {
        let (conn, vs, wb, engine) = deps();
        for def in tool_definitions() {
            let result = execute_tool(&conn, &vs, &wb, &engine, &def.name, &json!({}));
            let text = result.first_text();
            assert!(
                !text.contains("Unknown tool"),
                "advertised tool '{}' has no dispatch arm: {text}",
                def.name
            );
        }
    }

    #[test]
    fn tool_permission_tiers() {
        assert_eq!(tool_permission("read_message"), PermissionLevel::Read);
        assert_eq!(tool_permission("search_messages"), PermissionLevel::Read);
        assert_eq!(tool_permission("mark_read"), PermissionLevel::ReadWrite);
        assert_eq!(tool_permission("set_priority"), PermissionLevel::ReadWrite);
        assert_eq!(tool_permission("trash"), PermissionLevel::Full);
        assert_eq!(tool_permission("send_message"), PermissionLevel::Full);
        assert_eq!(tool_permission("create_conversation"), PermissionLevel::Full);
        assert_eq!(tool_permission("compose_draft"), PermissionLevel::ReadWrite);
        assert_eq!(tool_permission("whatsapp_messages"), PermissionLevel::Read);
        assert_eq!(tool_permission("create_calendar_event"), PermissionLevel::ReadWrite);
        // Unknown tools default to the most restrictive requirement.
        assert_eq!(tool_permission("anything_else"), PermissionLevel::Full);
    }

    /// Local reads compare instants, not text: a `+02:00` event at 09:00 is 07:00Z.
    #[test]
    fn calendar_events_local_overlap_and_shape() {
        use crate::sync::calendar::{UnifiedCalendar, UnifiedEvent};
        let (conn, vs, wb, engine) = deps();
        let day = (chrono::Utc::now() + chrono::Duration::days(10)).format("%Y-%m-%d").to_string();
        let cal = UnifiedCalendar {
            key: "cal_x".into(),
            provider_id: "p".into(),
            name: "Work".into(),
            color: "#000".into(),
            is_primary: true,
            is_writable: true,
            is_owned: true,
            conference_providers: vec![],
        };
        engine.store().upsert_calendar("acc_a", "google", &cal).unwrap();
        let ev = UnifiedEvent {
            provider_id: "e1".into(),
            title: "Standup".into(),
            start_at: format!("{day}T09:00:00+02:00"),
            end_at: format!("{day}T10:00:00+02:00"),
            ..Default::default()
        };
        engine.store().upsert_event("acc_a", "cal_x", &ev).unwrap();

        let call = |start: &str, end: &str| {
            let r = execute_tool(&conn, &vs, &wb, &engine, "get_calendar_events",
                &json!({ "start": format!("{day}T{start}Z"), "end": format!("{day}T{end}Z") }));
            serde_json::from_str::<Value>(&r.first_text()).unwrap()
        };
        let hit = call("07:30:00", "07:45:00");
        assert_eq!(hit["source"], "local");
        assert_eq!(hit["events"][0]["calendar"], "Work");
        assert_eq!(hit["events"][0]["key"], "cev_acc_a_e1");
        // Half-open, like the provider APIs: ending exactly at `start` is no overlap.
        assert_eq!(call("08:00:00", "09:00:00")["events"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn timed_event_needs_an_iana_timezone() {
        let (conn, vs, wb, engine) = deps();
        let mut args = json!({ "account_key": "acc_a", "title": "T",
            "start_at": "2026-12-11T16:00:00+01:00", "end_at": "2026-12-11T17:00:00+01:00" });
        for zone in [None, Some("CET+1")] {
            if let Some(z) = zone { args["timezone"] = json!(z); }
            let r = execute_tool(&conn, &vs, &wb, &engine, "create_calendar_event", &args);
            assert!(r.first_text().contains("timezone is required"), "{}", r.first_text());
        }
        args["timezone"] = json!("Europe/Amsterdam");
        let r = execute_tool(&conn, &vs, &wb, &engine, "create_calendar_event", &args);
        assert!(r.first_text().contains("No writable calendar"), "{}", r.first_text());
        // 16:00 UTC is not 16:00 in Amsterdam: the offset must be the zone's own.
        args["start_at"] = json!("2026-12-11T16:00:00Z");
        let r = execute_tool(&conn, &vs, &wb, &engine, "create_calendar_event", &args);
        assert!(r.first_text().contains("start_at has an offset"), "{}", r.first_text());
    }

    #[test]
    fn read_tools_validate_required_params() {
        let (conn, vs, wb, engine) = deps();
        let r = execute_tool(&conn, &vs, &wb, &engine, "read_message", &json!({}));
        assert_eq!(r.is_error, Some(true));
        assert!(r.first_text().contains("message_key is required"));
    }
}
