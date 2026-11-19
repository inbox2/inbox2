use inbox2_core::sync::model::{ConversationStatus, EmbeddingStatus};
use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::mcp::protocol::ResourceDefinition;

/// All available MCP resource definitions.
pub fn resource_definitions() -> Vec<ResourceDefinition> {
    vec![
        ResourceDefinition {
            uri: "inbox2://accounts".into(),
            name: "Connected Accounts".into(),
            description: "List of all connected email accounts with status".into(),
            mime_type: "application/json".into(),
        },
        ResourceDefinition {
            uri: "inbox2://stats".into(),
            name: "Inbox Statistics".into(),
            description: "Unread count, message count, embedding queue depth".into(),
            mime_type: "application/json".into(),
        },
        ResourceDefinition {
            uri: "inbox2://conversations/{key}".into(),
            name: "Conversation".into(),
            description: "Full email thread with all messages".into(),
            mime_type: "application/json".into(),
        },
        ResourceDefinition {
            uri: "inbox2://messages/{key}".into(),
            name: "Message".into(),
            description: "Single email message with full content".into(),
            mime_type: "application/json".into(),
        },
    ]
}

/// Read a resource by URI.
pub fn read_resource(conn: &Arc<Mutex<Connection>>, uri: &str) -> Result<Value, String> {
    if uri == "inbox2://accounts" {
        return read_accounts(conn);
    }
    if uri == "inbox2://stats" {
        return read_stats(conn);
    }
    if let Some(key) = uri.strip_prefix("inbox2://conversations/") {
        return read_conversation(conn, key);
    }
    if let Some(key) = uri.strip_prefix("inbox2://messages/") {
        return read_message(conn, key);
    }
    Err(format!("Unknown resource URI: {uri}"))
}

fn read_accounts(conn: &Arc<Mutex<Connection>>) -> Result<Value, String> {
    let conn = conn.lock();
    let mut stmt = conn
        .prepare(
            "SELECT key, display_name, email_address, provider_type, status
             FROM external_accounts ORDER BY sort_order",
        )
        .map_err(|e| e.to_string())?;
    let accounts: Vec<Value> = stmt
        .query_map([], |row| {
            Ok(json!({
                "key": row.get::<_, String>(0)?,
                "display_name": row.get::<_, String>(1)?,
                "email_address": row.get::<_, String>(2)?,
                "provider_type": row.get::<_, String>(3)?,
                "status": row.get::<_, String>(4)?,
            }))
        })
        .map_err(|e| e.to_string())?
        .filter_map(|r| r.ok())
        .collect();
    Ok(json!(accounts))
}

fn read_stats(conn: &Arc<Mutex<Connection>>) -> Result<Value, String> {
    let conn = conn.lock();
    let count = |sql: &str| -> i64 {
        conn.query_row(sql, [], |row| row.get(0)).unwrap_or(0)
    };
    let count1 = |sql: &str, p: &str| -> i64 {
        conn.query_row(sql, params![p], |row| row.get(0)).unwrap_or(0)
    };
    Ok(json!({
        "accounts": count("SELECT COUNT(*) FROM external_accounts"),
        "conversations": count("SELECT COUNT(*) FROM conversations"),
        "messages": count("SELECT COUNT(*) FROM messages"),
        "unread_conversations": count1("SELECT COUNT(*) FROM conversations WHERE read = 0 AND status = ?1", ConversationStatus::Open.as_str()),
        "embeddings": count("SELECT COUNT(*) FROM message_embeddings"),
        "embedding_queue_pending": count1("SELECT COUNT(*) FROM embedding_queue WHERE status = ?1", EmbeddingStatus::Pending.as_str()),
        "calendar_events": count("SELECT COUNT(*) FROM calendar_events"),
    }))
}

fn read_conversation(conn: &Arc<Mutex<Connection>>, key: &str) -> Result<Value, String> {
    let conn = conn.lock();
    let conv: Option<Value> = conn
        .query_row(
            "SELECT key, subject, from_address, status, read, created_at
             FROM agent_conversations WHERE key = ?1",
            params![key],
            |row| {
                Ok(json!({
                    "key": row.get::<_, String>(0)?,
                    "subject": row.get::<_, Option<String>>(1)?,
                    "from": row.get::<_, Option<String>>(2)?,
                    "status": row.get::<_, String>(3)?,
                    "read": row.get::<_, i32>(4)? != 0,
                    "created_at": row.get::<_, Option<String>>(5)?,
                }))
            },
        )
        .optional()
        .map_err(|e| e.to_string())?;

    let Some(conv) = conv else {
        return Err(format!("Conversation '{key}' not found"));
    };

    let mut stmt = conn
        .prepare(
            "SELECT key, from_address, to_address, subject, body_plain, created_at
             FROM agent_messages WHERE conversation_key = ?1 ORDER BY created_at",
        )
        .map_err(|e| e.to_string())?;
    let messages: Vec<Value> = stmt
        .query_map(params![key], |row| {
            Ok(json!({
                "key": row.get::<_, String>(0)?,
                "from": row.get::<_, Option<String>>(1)?,
                "to": row.get::<_, Option<String>>(2)?,
                "subject": row.get::<_, Option<String>>(3)?,
                "body_plain": row.get::<_, Option<String>>(4)?,
                "created_at": row.get::<_, Option<String>>(5)?,
            }))
        })
        .map_err(|e| e.to_string())?
        .filter_map(|r| r.ok())
        .collect();

    Ok(json!({
        "conversation": conv,
        "messages": messages,
    }))
}

fn read_message(conn: &Arc<Mutex<Connection>>, key: &str) -> Result<Value, String> {
    let conn = conn.lock();
    conn.query_row(
        "SELECT key, conversation_key, from_address, to_address, cc_address,
                subject, body_plain, body_html, is_inbound, created_at, account_key
         FROM agent_messages WHERE key = ?1",
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
                "created_at": row.get::<_, Option<String>>(9)?,
                "account_key": row.get::<_, Option<String>>(10)?,
            }))
        },
    )
    .optional()
    .map_err(|e| e.to_string())?
    .ok_or_else(|| format!("Message '{key}' not found"))
}
