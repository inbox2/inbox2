//! Lean in-process agent tools. Each maps to an engine action over the durable
//! write-back queue (channel mail/calendar). Domain-pool collaboration (assign /
//! notes / tags) goes through the Rails API on the client and is not covered here.
//! `catalog()` also renders the OpenAI function-calling schema.

use crate::sync::engine::SyncEngine;
use rusqlite::params;
use serde_json::{json, Value};

pub struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    pub parameters: Value,
    /// Destructive / outbound — the host should confirm before running.
    pub destructive: bool,
}

/// The tool catalog. Kept small with flat args so the on-device model selects well.
pub fn catalog() -> Vec<ToolSpec> {
    let conv = || {
        json!({
            "type": "object",
            "properties": { "conversationId": { "type": "string", "description": "Conversation id" } },
            "required": ["conversationId"]
        })
    };
    vec![
        ToolSpec {
            name: "read_email_aloud",
            description: "Read an email thread aloud — a short summary of the previous message (if any) plus a fuller summary of the latest message. Pass a conversationId, or a selector to pick one.",
            parameters: json!({
                "type": "object",
                "properties": {
                    "conversationId": { "type": "string", "description": "Conversation id to read; omit to use selector" },
                    "selector": {
                        "type": "string",
                        "enum": ["last_unread", "latest"],
                        "description": "Which conversation to read when no id is given: the most recent unread, or the most recent overall"
                    }
                }
            }),
            destructive: false,
        },
        ToolSpec { name: "mark_read", description: "Mark a conversation as read.", parameters: conv(), destructive: false },
        ToolSpec { name: "archive", description: "Archive a conversation.", parameters: conv(), destructive: false },
        ToolSpec { name: "trash", description: "Move a conversation to trash.", parameters: conv(), destructive: true },
        ToolSpec {
            name: "set_priority",
            description: "Set urgent/important flags on a conversation.",
            parameters: json!({
                "type": "object",
                "properties": {
                    "conversationId": { "type": "string" },
                    "urgent": { "type": "boolean" },
                    "important": { "type": "boolean" }
                },
                "required": ["conversationId"]
            }),
            destructive: false,
        },
        // NOTE: the Bridge agent must NEVER send or save on the user's behalf. The old
        // `send_reply` (enqueued a real send) and `rsvp` (fired to the provider) tools
        // were removed: replies are drafted to the Compose screen and meetings to the
        // New Event screen, where the user commits with Send / Add. See the intent
        // layer (`bridge/intent.rs`) and `agent::command`.
    ]
}

/// Execute a tool call by name with JSON args. Returns a short human/agent result.
pub async fn execute(engine: &SyncEngine, name: &str, args: &Value) -> Result<String, String> {
    match name {
        "mark_read" => conv_action(engine, args, "mark_read").await,
        "archive" => conv_action(engine, args, "archive").await,
        "trash" => conv_action(engine, args, "trash").await,
        "set_priority" => set_priority(engine, args).await,
        other => Err(format!("unknown tool: {other}")),
    }
}

fn conv_id(args: &Value) -> Result<String, String> {
    args.get("conversationId")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| "missing conversationId".into())
}

fn account_for_conversation(engine: &SyncEngine, conversation_key: &str) -> Option<String> {
    let conn = engine.store().connection();
    let conn = conn.lock();
    conn.query_row(
        "SELECT account_key FROM messages WHERE conversation_key = ?1 AND account_key IS NOT NULL LIMIT 1",
        params![conversation_key],
        |r| r.get(0),
    )
    .ok()
}

async fn conv_action(engine: &SyncEngine, args: &Value, action: &str) -> Result<String, String> {
    let ck = conv_id(args)?;
    let ak = account_for_conversation(engine, &ck).ok_or("conversation not found")?;
    engine
        .perform_conversation_action(&ak, std::slice::from_ref(&ck), action)
        .await
        .map_err(|e| e.to_string())?;
    Ok(format!("{action} done."))
}

async fn set_priority(engine: &SyncEngine, args: &Value) -> Result<String, String> {
    let ck = conv_id(args)?;
    let ak = account_for_conversation(engine, &ck).ok_or("conversation not found")?;
    let urgent = args.get("urgent").and_then(|v| v.as_bool()).unwrap_or(false);
    let important = args.get("important").and_then(|v| v.as_bool()).unwrap_or(false);
    engine
        .set_conversation_priority(&ak, std::slice::from_ref(&ck), urgent, important)
        .await
        .map_err(|e| e.to_string())?;
    Ok("Priority updated.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_exposes_no_send_or_save_tools() {
        // Safety rule: the Bridge agent must never send/save. Only local, reversible
        // mailbox ops are tools; replies + meetings are drafted to screen instead.
        let names: Vec<&str> = catalog().iter().map(|t| t.name).collect();
        for forbidden in ["send_reply", "rsvp", "create_event", "send"] {
            assert!(!names.contains(&forbidden), "forbidden tool {forbidden} is in the catalog");
        }
        // The expected local-only set.
        assert!(names.contains(&"mark_read") && names.contains(&"archive") && names.contains(&"trash"));
    }
}
