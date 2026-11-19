//! `list_attachments` / `get_attachment`. No attachment bytes live on this
//! device: channel mail fetches them from the provider (as the reader does), MX
//! mail from the Rails API via the `download_url` in its mirrored payload.
//! Sealed MX mail is refused the same way `agent_messages` hides it.

use base64::Engine;
use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::mcp::protocol::ToolResult;
use crate::sync::engine::SyncEngine;
use crate::sync::interactive::AttachmentRef;

/// Largest file returned inline. Base64 in a JSON-RPC body grows it by a third,
/// and most MCP hosts cap a tool result well below that.
// ponytail: hard cap, not chunked reads. Add a byte-range param if agents need bigger files.
const MAX_BYTES: u64 = 10 * 1024 * 1024;

enum Source {
    /// inbox2-hosted: the payload's `attachments` array.
    Mx(Vec<Value>),
    /// A connected mailbox: go through its provider.
    Channel(String),
}

fn locate(conn: &Arc<Mutex<Connection>>, message_key: &str) -> Result<Source, String> {
    let conn = conn.lock();
    // The thread rule of `agent_messages`, applied here too: a message is hidden when it is sealed
    // or when any message of its thread is (an unsealed reply quotes a sealed subject line).
    let mx: Option<(i64, Option<String>)> = conn
        .query_row(
            "SELECT m.sealed OR EXISTS (SELECT 1 FROM mx_messages s
                                        WHERE s.conversation_key = m.conversation_key AND s.sealed = 1),
                    json_extract(m.payload, '$.attachments')
               FROM mx_messages m WHERE m.key = ?1",
            params![message_key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    if let Some((hidden, atts)) = mx {
        if hidden != 0 {
            // Same answer as for a key that doesn't exist: agents don't learn sealed mail is there.
            return Err(format!("Message '{message_key}' not found"));
        }
        let atts = atts.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        return Ok(Source::Mx(atts));
    }
    conn.query_row(
        "SELECT account_key FROM messages WHERE key = ?1",
        params![message_key],
        |r| r.get::<_, String>(0),
    )
    .optional()
    .map_err(|e| e.to_string())?
    .map(Source::Channel)
    .ok_or_else(|| format!("Message '{message_key}' not found"))
}

/// Where one attachment's bytes come from.
enum Fetch {
    Mx(String),
    Channel(String),
}

/// MX attachments are addressed by the key at the end of their download URL.
/// One without a URL has no stored bytes yet and isn't listed.
fn mx_refs(atts: &[Value]) -> Vec<(AttachmentRef, String)> {
    atts.iter()
        .filter_map(|a| {
            let url = a["download_url"].as_str()?;
            let id = url.rsplit('/').next()?.to_string();
            Some((
                AttachmentRef {
                    attachment_id: id,
                    filename: a["filename"].as_str().unwrap_or("attachment").to_string(),
                    mime_type: a["content_type"].as_str().unwrap_or("application/octet-stream").to_string(),
                    size: a["size_bytes"].as_u64().unwrap_or(0),
                },
                url.to_string(),
            ))
        })
        .collect()
}

fn channel_refs(engine: &Arc<SyncEngine>, account: &str, message_key: &str) -> Result<Vec<AttachmentRef>, String> {
    let engine = engine.clone();
    let (account, key) = (account.to_string(), message_key.to_string());
    tauri::async_runtime::block_on(async move {
        let provider = engine.interactive_provider(&account)?;
        Ok::<_, crate::sync::error::SyncError>(provider.fetch_message(&key).await?.attachments)
    })
    .map_err(|e| e.to_string())
}

/// Channel attachments are listed by position ("1", "2", …), not provider id:
/// Gmail mints a new attachmentId on every fetch, so an id from
/// `list_attachments` never matched the refetch in `get_attachment` (and each
/// one cost ~300 characters of context). MIME part order is stable.
fn positional(refs: Vec<AttachmentRef>) -> Vec<AttachmentRef> {
    refs.into_iter()
        .enumerate()
        .map(|(i, r)| AttachmentRef { attachment_id: (i + 1).to_string(), ..r })
        .collect()
}

/// A positional id, or a raw provider id from an older client. Returns the
/// provider's current ref, whose id is the one to download with.
fn pick_channel(refs: Vec<AttachmentRef>, id: &str) -> Option<AttachmentRef> {
    if let Ok(n) = id.parse::<usize>() {
        if n >= 1 && n <= refs.len() {
            return refs.into_iter().nth(n - 1);
        }
    }
    refs.into_iter().find(|r| r.attachment_id == id)
}

pub(super) fn exec_list_attachments(
    conn: &Arc<Mutex<Connection>>,
    engine: &Arc<SyncEngine>,
    params: &Value,
) -> ToolResult {
    let key = required_str!(params, "message_key");
    let refs = match locate(conn, key) {
        Ok(Source::Mx(atts)) => Ok(mx_refs(&atts).into_iter().map(|(r, _)| r).collect()),
        Ok(Source::Channel(account)) => channel_refs(engine, &account, key).map(positional),
        Err(e) => Err(e),
    };
    match refs {
        Ok(refs) => ToolResult::json(&refs),
        Err(e) => ToolResult::error(e),
    }
}

pub(super) fn exec_get_attachment(
    conn: &Arc<Mutex<Connection>>,
    engine: &Arc<SyncEngine>,
    params: &Value,
) -> ToolResult {
    let key = required_str!(params, "message_key");
    let id = required_str!(params, "attachment_id");

    // Resolve the metadata first: it proves the id belongs to this message and
    // gives the size to check before anything is downloaded.
    let found = match locate(conn, key) {
        Ok(Source::Mx(atts)) => {
            mx_refs(&atts).into_iter().find(|(r, _)| r.attachment_id == id).map(|(r, url)| (r, Fetch::Mx(url)))
        }
        Ok(Source::Channel(account)) => match channel_refs(engine, &account, key) {
            Ok(refs) => pick_channel(refs, id).map(|r| (r, Fetch::Channel(account))),
            Err(e) => return ToolResult::error(e),
        },
        Err(e) => return ToolResult::error(e),
    };
    let Some((meta, from)) = found else {
        return ToolResult::error(format!("Attachment '{id}' not found on message '{key}'"));
    };
    if meta.size > MAX_BYTES {
        return ToolResult::error(format!(
            "'{}' is {} bytes; get_attachment returns files up to {MAX_BYTES} bytes",
            meta.filename, meta.size
        ));
    }
    let engine = engine.clone();
    // The provider's own id for this fetch, not the positional one the agent passed.
    let (key_owned, id_owned) = (key.to_string(), meta.attachment_id.clone());
    let data = tauri::async_runtime::block_on(async move {
        match from {
            Fetch::Mx(url) => engine.mx_download_attachment(&url).await,
            Fetch::Channel(account) => {
                engine.interactive_provider(&account)?.download_attachment(&key_owned, &id_owned).await
            }
        }
    });
    let data: Vec<u8> = match data {
        Ok(d) => d,
        Err(e) => return ToolResult::error(e.to_string()),
    };
    if data.len() as u64 > MAX_BYTES {
        return ToolResult::error(format!("'{}' is over {MAX_BYTES} bytes", meta.filename));
    }

    let info = json!({ "filename": meta.filename, "mime_type": effective_mime(&meta), "size": data.len() });
    // The URI names the attachment by the id the agent used, not the provider's long one.
    let meta = AttachmentRef { attachment_id: id.to_string(), ..meta };
    ToolResult { content: vec![json!({ "type": "text", "text": info.to_string() }), content_block(key, &meta, data)], is_error: None }
}

/// Senders often label everything `application/octet-stream`; the client then
/// saves a PDF as `.bin`. The filename's extension says what it is.
fn effective_mime(meta: &AttachmentRef) -> String {
    let mime = meta.mime_type.to_ascii_lowercase();
    if mime != "application/octet-stream" {
        return mime;
    }
    let ext = meta.filename.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "txt" => "text/plain",
        "csv" => "text/csv",
        "eml" => "message/rfc822",
        "ics" => "text/calendar",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// Images as `image` blocks (models can look at them), text as text, anything
/// else (PDF, Office, zip) as a base64 embedded resource.
fn content_block(message_key: &str, meta: &AttachmentRef, data: Vec<u8>) -> Value {
    let mime = effective_mime(meta);
    let b64 = || base64::engine::general_purpose::STANDARD.encode(&data);
    if matches!(mime.as_str(), "image/png" | "image/jpeg" | "image/gif" | "image/webp") {
        return json!({ "type": "image", "data": b64(), "mimeType": mime });
    }
    let uri = format!("inbox2://messages/{message_key}/attachments/{}", meta.attachment_id);
    let textual = mime.starts_with("text/")
        || matches!(mime.as_str(), "application/json" | "application/xml" | "application/csv" | "message/rfc822");
    if textual {
        if let Ok(text) = std::str::from_utf8(&data) {
            return json!({ "type": "resource", "resource": { "uri": uri, "mimeType": mime, "text": text } });
        }
    }
    json!({ "type": "resource", "resource": { "uri": uri, "mimeType": mime, "blob": b64() } })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::events::NullSink;
    use crate::sync::store::SyncStore;

    fn setup() -> (Arc<Mutex<Connection>>, Arc<SyncEngine>) {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let engine = Arc::new(SyncEngine::new(store, Arc::new(NullSink)));
        let conn = engine.store().connection();
        {
            let c = conn.lock();
            // c1 is a sealed thread (m_sealed plus an unsealed reply), c2 an open one.
            c.execute("INSERT INTO mx_conversations (key, organization_id, payload) VALUES ('c1', 'org_1', '{}'), ('c2', 'org_1', '{}')", []).unwrap();
            let payload = json!({ "attachments": [
                { "filename": "a.pdf", "content_type": "application/pdf", "size_bytes": 4,
                  "download_url": "/api/v1/orgs/org_1/attachments/att_1" },
                { "filename": "pending.bin", "content_type": "application/octet-stream", "size_bytes": 9,
                  "download_url": null },
            ]});
            for (key, conv, sealed) in [("m_open", "c2", 0), ("m_sealed", "c1", 1), ("m_reply", "c1", 0)] {
                c.execute(
                    "INSERT INTO mx_messages (key, conversation_key, organization_id, sealed, payload)
                     VALUES (?1, ?2, 'org_1', ?3, ?4)",
                    params![key, conv, sealed, payload.to_string()],
                )
                .unwrap();
            }
        }
        (conn, engine)
    }

    #[test]
    fn lists_mx_attachments_with_content_and_hides_sealed_mail() {
        let (conn, engine) = setup();
        let r = exec_list_attachments(&conn, &engine, &json!({ "message_key": "m_open" }));
        let list: Vec<Value> = serde_json::from_str(r.first_text()).unwrap();
        assert_eq!(list.len(), 1, "only the attachment with stored bytes");
        assert_eq!(list[0]["attachment_id"], "att_1");
        assert_eq!(list[0]["filename"], "a.pdf");

        let r = exec_list_attachments(&conn, &engine, &json!({ "message_key": "m_sealed" }));
        assert_eq!(r.is_error, Some(true));
        assert!(r.first_text().contains("not found"));
        let r = exec_get_attachment(&conn, &engine, &json!({ "message_key": "m_sealed", "attachment_id": "att_1" }));
        assert!(r.first_text().contains("not found"));

        // The unsealed reply in the sealed thread is hidden the same way, bytes included.
        let r = exec_list_attachments(&conn, &engine, &json!({ "message_key": "m_reply" }));
        assert_eq!(r.is_error, Some(true));
        assert!(r.first_text().contains("not found"));
        let r = exec_get_attachment(&conn, &engine, &json!({ "message_key": "m_reply", "attachment_id": "att_1" }));
        assert!(r.first_text().contains("not found"));
    }

    #[test]
    fn channel_ids_are_positional_and_resolve_to_the_fresh_provider_id() {
        let r = |id: &str| AttachmentRef { attachment_id: id.into(), filename: id.into(), mime_type: "x".into(), size: 1 };
        let listed = positional(vec![r("ANGjdJ_first"), r("ANGjdJ_second")]);
        assert_eq!(listed[1].attachment_id, "2");
        // A refetch minted new provider ids; "2" still means the second part.
        let fresh = vec![r("ANGjdJ_new1"), r("ANGjdJ_new2")];
        assert_eq!(pick_channel(fresh.clone(), "2").unwrap().attachment_id, "ANGjdJ_new2");
        assert_eq!(pick_channel(fresh.clone(), "ANGjdJ_new1").unwrap().attachment_id, "ANGjdJ_new1");
        assert!(pick_channel(fresh.clone(), "3").is_none());
        assert!(pick_channel(fresh, "0").is_none());
    }

    #[test]
    fn content_blocks_by_type() {
        let meta = |mime: &str| AttachmentRef {
            attachment_id: "a".into(),
            filename: "f".into(),
            mime_type: mime.into(),
            size: 3,
        };
        assert_eq!(content_block("m", &meta("image/png"), b"png".to_vec())["type"], "image");
        assert_eq!(content_block("m", &meta("text/plain"), b"hey".to_vec())["resource"]["text"], "hey");
        let pdf = content_block("m", &meta("application/pdf"), b"%PD".to_vec());
        assert_eq!(pdf["resource"]["blob"], "JVBE");
        assert_eq!(pdf["resource"]["uri"], "inbox2://messages/m/attachments/a");
        let scan = AttachmentRef { filename: "10-02-2011.PDF".into(), ..meta("application/octet-stream") };
        assert_eq!(content_block("m", &scan, b"%PD".to_vec())["resource"]["mimeType"], "application/pdf");
    }
}
