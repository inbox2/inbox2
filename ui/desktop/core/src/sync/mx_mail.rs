//! Writes to inbox2-hosted mail that the bulk action queue doesn't cover:
//! drafts, sends, tags, Spaces and permanent delete. Everything is resolved
//! against the local mirror (docs/MX-Sync.md): the sender identity from the
//! member directory, tag and Space names from `mx_directory`, reply threads from
//! `mx_messages`. Sends and drafts are durable: they go through `mx_outbox`
//! (the channel outbox's counterpart) and retry with backoff; a draft keeps only
//! its latest version. Tags/Spaces write back into the mirror from the response
//! so local reads agree before the next pull.

use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};

use crate::sync::engine::SyncEngine;
use crate::sync::error::{Result, SyncError};
use crate::sync::interactive::OutgoingMessage;
use crate::sync::model::{ApiContext, OutboxKind, OutboxSendResult, OutboxStatus};
use crate::sync::mx_sync::{client, MxSyncOptions};

/// Attempts before a send gives up, like the channel outbox. (Retries are safe:
/// the API dedupes on the client-chosen Message-ID.)
const MX_SEND_RETRIES: u32 = 3;
/// How long a delivered row is kept so its caller can still read the outcome.
const MX_OUTBOX_RESULT_SECS: i64 = 600;
/// A `sending` row older than this was abandoned by a killed process.
const MX_OUTBOX_STALE_SECS: i64 = 120;

/// Folder names that are really conversation statuses, and the queued action
/// that puts a thread there.
const ROLE_ACTIONS: &[(&str, &str)] = &[
    ("inbox", "open"),
    ("open", "open"),
    ("archive", "archive"),
    ("archived", "archive"),
    ("trash", "trash"),
    ("spam", "spam"),
];

async fn mx_write(ctx: &ApiContext, method: reqwest::Method, org: &str, path: &str, body: &Value) -> Result<Value> {
    let url = format!("{}/orgs/{org}/{path}", ctx.api_base.trim_end_matches('/'));
    let resp = client().request(method, url).bearer_auth(&ctx.rails_jwt).json(body).send().await?;
    match resp.status().as_u16() {
        200..=299 => Ok(resp.json().await.unwrap_or(Value::Null)),
        401 => Err(SyncError::AuthFailed("inbox2 session expired".into())),
        code => {
            // The API's error text (send quota, validation) is what the caller needs.
            let detail: String = resp.text().await.unwrap_or_default().chars().take(300).collect();
            Err(SyncError::HttpStatus { code, context: format!("mx {path}: {detail}") })
        }
    }
}

impl SyncEngine {
    async fn mx_ctx(&self) -> Result<ApiContext> {
        self.api_context()
            .read()
            .await
            .clone()
            .filter(|c| !c.rails_jwt.is_empty())
            .ok_or_else(|| SyncError::AuthFailed("not signed in to inbox2".into()))
    }

    /// Addresses this device's member can send as in `org`: their own mailboxes
    /// plus `username@` every org domain (what the web composer offers). The
    /// org's primary domain comes first: it's the default.
    pub fn mx_identities(&self, org: &str) -> Result<Vec<String>> {
        let conn = self.store().connection();
        let conn = conn.lock();
        let member: Option<String> = conn
            .query_row(
                "SELECT d.payload FROM mx_directory d JOIN mx_sync_state s ON s.organization_id = d.organization_id
                 WHERE d.organization_id = ?1 AND d.type = 'members' AND json_extract(d.payload, '$.user.id') = s.user_key",
                params![org],
                |r| r.get(0),
            )
            .optional()?;
        let member: Value = member.and_then(|p| serde_json::from_str(&p).ok()).unwrap_or_default();
        let primary: Option<String> = conn
            .query_row(
                "SELECT json_extract(payload, '$.domain') FROM mx_directory WHERE organization_id = ?1 AND type = 'organization'",
                params![org],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        let mut domains: Vec<String> = conn
            .prepare("SELECT json_extract(payload, '$.name') FROM mx_directory WHERE organization_id = ?1 AND type = 'domains' ORDER BY position")?
            .query_map(params![org], |r| r.get::<_, Option<String>>(0))?
            .filter_map(|r| r.ok().flatten())
            .collect();
        if let Some(p) = &primary {
            domains.retain(|d| d != p);
            domains.insert(0, p.clone());
        }
        let mut out: Vec<String> = Vec::new();
        if let Some(user) = member["user"]["username"].as_str() {
            out.extend(domains.iter().map(|d| format!("{user}@{d}")));
        }
        if let Some(mbs) = member["mailboxes"].as_array() {
            out.extend(mbs.iter().filter_map(|m| m["email_address"].as_str().map(String::from)));
        }
        let mut seen = std::collections::HashSet::new();
        out.retain(|a| seen.insert(a.to_ascii_lowercase()));
        Ok(out)
    }

    /// Queue a send of `msg` in `org`, or with `draft_key` a new version of that
    /// draft, and try it now. A reply (`reply_to_message_key`) lands in that
    /// message's thread, sent from whichever of the member's addresses the thread
    /// was addressed to. Everything that can be wrong with the request (unknown
    /// parent, a From the member can't use) fails here, before it is queued.
    pub async fn mx_compose(&self, org: &str, msg: OutgoingMessage, draft_key: Option<&str>) -> Result<OutboxSendResult> {
        let parent: Option<(String, String)> = match msg.reply_to_message_key.as_deref() {
            Some(key) => Some(
                self.store()
                    .connection()
                    .lock()
                    .query_row(
                        "SELECT conversation_key,
                                lower(COALESCE(json_extract(payload, '$.to_address'), '') || ' ' ||
                                      COALESCE(json_extract(payload, '$.cc_address'), '') || ' ' ||
                                      COALESCE(json_extract(payload, '$.from_address'), ''))
                         FROM mx_messages WHERE key = ?1 AND organization_id = ?2",
                        params![key, org],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    )
                    .optional()?
                    .ok_or_else(|| SyncError::Other(format!("message '{key}' not found in {org}")))?,
            ),
            None => None,
        };

        let identities = self.mx_identities(org)?;
        let from = if !msg.from_address.is_empty() {
            identities
                .iter()
                .find(|a| a.eq_ignore_ascii_case(&msg.from_address))
                .cloned()
                .ok_or_else(|| {
                    SyncError::Other(format!("can't send as '{}'; use one of: {}", msg.from_address, identities.join(", ")))
                })?
        } else {
            let addressed = parent
                .as_ref()
                .and_then(|(_, people)| identities.iter().find(|a| people.contains(&a.to_ascii_lowercase())));
            addressed
                .or(identities.first())
                .cloned()
                .ok_or_else(|| SyncError::Other(format!("no sending address for this member in {org}")))?
        };

        let mut body = json!({
            "from_address": from,
            "to_address": msg.to_address,
            "cc_address": msg.cc_address,
            "bcc_address": msg.bcc_address,
            "subject": msg.subject,
            "body_plain": msg.body_plain,
            "body_html": msg.body_html,
        });
        if let Some((conv, _)) = &parent {
            body["conversation_id"] = json!(conv);
            // The server threads the reply on the wire (In-Reply-To/References)
            // from the message named here.
            body["reply_to_message_id"] = json!(msg.reply_to_message_key);
        }
        // The Message-ID is chosen here and sent with every attempt: the API
        // answers a retried send with the message it already made, and upserts
        // a draft by it, so a lost response can't mean a second email or draft.
        let key = format!("mxo_{}", nanoid::nanoid!(21));
        // The org's primary domain, not the sender's: a draft that switches From
        // between domains must keep one identity or it would fork into two.
        let domain = identities
            .first()
            .and_then(|a| a.rsplit_once('@'))
            .map(|(_, d)| d.to_string())
            .unwrap_or_else(|| "inbox2.local".into());
        body["message_id_header"] = json!(format!("<{}@{domain}>", draft_key.unwrap_or(&key)));
        let key = self.mx_outbox_enqueue(&key, org, draft_key, &body)?;
        self.mx_outbox_drain().await;
        self.mx_outbox_result(&key)
    }

    /// Send an API request body the client already built (the CLI: threading,
    /// `attachment_keys`), durably: queued, retried, deduped by its Message-ID.
    /// Pending in the result means it will go out when the server is reachable.
    pub async fn mx_send(&self, org: &str, message: &Value) -> Result<OutboxSendResult> {
        if !message.is_object() {
            return Err(SyncError::Other("message must be an object".into()));
        }
        let mut body = message.clone();
        let key = format!("mxo_{}", nanoid::nanoid!(21));
        let domain = body["from_address"]
            .as_str()
            .and_then(|a| a.rsplit_once('@'))
            .map(|(_, d)| d.trim_end_matches('>').to_string())
            .unwrap_or_else(|| "inbox2.local".into());
        body["message_id_header"] = json!(format!("<{key}@{domain}>"));
        self.mx_outbox_enqueue(&key, org, None, &body)?;
        self.mx_outbox_drain().await;
        self.mx_pull_after_send(org, &key).await
    }

    /// Put a failed send back in the queue and try it now.
    pub async fn mx_outbox_retry(&self, key: &str) -> Result<OutboxSendResult> {
        let (org, changed): (Option<String>, usize) = {
            let conn = self.store().connection();
            let conn = conn.lock();
            let org = conn
                .query_row("SELECT org_id FROM mx_outbox WHERE key = ?1", params![key], |r| r.get(0))
                .optional()?;
            let changed = conn.execute(
                "UPDATE mx_outbox SET status = ?2, retry_count = 0, next_retry_at = NULL, error_message = NULL, updated_at = ?3
                 WHERE key = ?1 AND status = ?4",
                params![key, OutboxStatus::Pending.as_str(), chrono::Utc::now().to_rfc3339(), OutboxStatus::Failed.as_str()],
            )?;
            (org, changed)
        };
        let (Some(org), 1) = (org, changed) else {
            return Err(SyncError::Other(format!("'{key}' is not a failed send")));
        };
        self.mx_outbox_drain().await;
        self.mx_pull_after_send(&org, key).await
    }

    /// The outcome of a send, after one pull so a delivered copy mirrors.
    async fn mx_pull_after_send(&self, org: &str, key: &str) -> Result<OutboxSendResult> {
        let result = self.mx_outbox_result(key)?;
        if result.status == OutboxStatus::Sent {
            if let Ok(Some(state)) = self.store().mx_state(org) {
                if let Err(e) = self.mx_sync(org, &state.user_key, MxSyncOptions::default()).await {
                    log::warn!("[mx] {org}: pull after send failed: {e}");
                }
            }
        }
        Ok(result)
    }

    /// Persist one send, or the latest version of a draft: a version still
    /// waiting is overwritten in place and a failed one dropped. Returns the key
    /// of the row that holds it.
    fn mx_outbox_enqueue(&self, key: &str, org: &str, draft_key: Option<&str>, body: &Value) -> Result<String> {
        let now = chrono::Utc::now().to_rfc3339();
        let kind = if draft_key.is_some() { OutboxKind::Draft } else { OutboxKind::Send };
        let conn = self.store().connection();
        let mut conn = conn.lock();
        let tx = conn.transaction()?;
        if let Some(dk) = draft_key {
            let elsewhere: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM mx_outbox WHERE draft_key = ?1 AND org_id != ?2)",
                params![dk, org],
                |r| r.get(0),
            )?;
            if elsewhere {
                return Err(SyncError::Other(format!("draft '{dk}' belongs to another organization")));
            }
            tx.execute(
                "DELETE FROM mx_outbox WHERE draft_key = ?1 AND status = ?2",
                params![dk, OutboxStatus::Failed.as_str()],
            )?;
            let waiting: Option<String> = tx
                .query_row(
                    "SELECT key FROM mx_outbox WHERE draft_key = ?1 AND status = ?2
                       AND id = (SELECT MAX(id) FROM mx_outbox WHERE draft_key = ?1)",
                    params![dk, OutboxStatus::Pending.as_str()],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(waiting) = waiting {
                tx.execute(
                    "UPDATE mx_outbox SET payload = ?2, retry_count = 0, next_retry_at = NULL, error_message = NULL, updated_at = ?3
                     WHERE key = ?1",
                    params![waiting, body.to_string(), now],
                )?;
                tx.commit()?;
                return Ok(waiting);
            }
        }
        tx.execute(
            "INSERT INTO mx_outbox (key, org_id, kind, draft_key, payload, status, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
            params![key, org, kind.as_str(), draft_key, body.to_string(), OutboxStatus::Pending.as_str(), now],
        )?;
        tx.commit()?;
        Ok(key.to_string())
    }

    fn mx_outbox_result(&self, key: &str) -> Result<OutboxSendResult> {
        let row = self
            .store()
            .connection()
            .lock()
            .query_row(
                "SELECT status, result_id, error_message FROM mx_outbox WHERE key = ?1",
                params![key],
                |r| {
                    Ok(OutboxSendResult {
                        outbox_key: key.to_string(),
                        status: OutboxStatus::from_str(&r.get::<_, String>(0)?),
                        provider_message_id: r.get(1)?,
                        error_message: r.get(2)?,
                    })
                },
            )
            .optional()?;
        // Only a draft version is ever removed early: a newer save of the same
        // draft replaced it. Say so rather than erroring (which invites a retry).
        Ok(row.unwrap_or_else(|| OutboxSendResult {
            outbox_key: key.to_string(),
            status: OutboxStatus::Deleted,
            provider_message_id: None,
            error_message: Some("superseded by a newer version of this draft".into()),
        }))
    }

    /// Deliver every due `mx_outbox` row, oldest first. Stops at the first
    /// transient failure (the server or the link is down), like `mx_drain`.
    /// Runs on the engine's 5s beat and right after each enqueue.
    pub async fn mx_outbox_drain(&self) -> usize {
        let Ok(ctx) = self.mx_ctx().await else { return 0 };
        let now = chrono::Utc::now();
        let stale = (now - chrono::Duration::seconds(MX_OUTBOX_STALE_SECS)).to_rfc3339();
        let keep_results = (now - chrono::Duration::seconds(MX_OUTBOX_RESULT_SECS)).to_rfc3339();
        let now_s = now.to_rfc3339();
        let keys: Vec<String> = {
            let conn = self.store().connection();
            let conn = conn.lock();
            // Delivered rows linger a while so the call that queued one can still
            // read its outcome after a concurrent drain.
            let _ = conn.execute(
                "DELETE FROM mx_outbox WHERE status = ?1 AND updated_at <= ?2",
                params![OutboxStatus::Sent.as_str(), keep_results],
            );
            let mut stmt = match conn.prepare(
                "SELECT key FROM mx_outbox
                 WHERE (status = ?1 AND (next_retry_at IS NULL OR next_retry_at <= ?2)) OR (status = ?3 AND updated_at <= ?4)
                 ORDER BY id",
            ) {
                Ok(s) => s,
                Err(_) => return 0,
            };
            stmt.query_map(params![OutboxStatus::Pending.as_str(), now_s, OutboxStatus::Sending.as_str(), stale], |r| r.get(0))
                .map(|rows| rows.filter_map(|r| r.ok()).collect())
                .unwrap_or_default()
        };

        let mut delivered = 0;
        for key in keys {
            if !self.mx_outbox_claim(&key, &stale) {
                continue;
            }
            // Read after claiming: a draft version saved in between is the one sent.
            let row: Option<(String, String, Option<String>, String, u32)> = self
                .store()
                .connection()
                .lock()
                .query_row(
                    "SELECT org_id, kind, draft_key, payload, retry_count FROM mx_outbox WHERE key = ?1",
                    params![key],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
                )
                .optional()
                .unwrap_or(None);
            let Some((org, kind, draft_key, payload, retries)) = row else { continue };
            let body: Value = serde_json::from_str(&payload).unwrap_or_default();
            let is_draft = OutboxKind::from_str(&kind) == OutboxKind::Draft;
            let attempt = if is_draft {
                mx_write(&ctx, reqwest::Method::POST, &org, "drafts", &body)
                    .await
                    .map(|v| v["draft"]["id"].as_str().unwrap_or_default().to_string())
            } else {
                mx_write(&ctx, reqwest::Method::POST, &org, "messages", &body)
                    .await
                    .map(|v| v["message"]["id"].as_str().unwrap_or_default().to_string())
            };
            let conn = self.store().connection();
            let conn = conn.lock();
            let stamp = chrono::Utc::now().to_rfc3339();
            match attempt {
                Ok(id) => {
                    let _ = conn.execute(
                        "UPDATE mx_outbox SET status = ?2, result_id = ?3, error_message = NULL, updated_at = ?4 WHERE key = ?1",
                        params![key, OutboxStatus::Sent.as_str(), id, stamp],
                    );
                    // Older versions of this draft are moot now.
                    if let Some(dk) = &draft_key {
                        let _ = conn.execute(
                            "DELETE FROM mx_outbox WHERE draft_key = ?1 AND id < (SELECT id FROM mx_outbox WHERE key = ?2)",
                            params![dk, key],
                        );
                    }
                    delivered += 1;
                }
                Err(e) => {
                    // A draft version a newer one has replaced isn't retried: it
                    // would overwrite the newer draft.
                    let superseded = draft_key.is_some()
                        && conn
                            .execute(
                                "DELETE FROM mx_outbox WHERE key = ?1
                                   AND EXISTS (SELECT 1 FROM mx_outbox o WHERE o.draft_key = mx_outbox.draft_key AND o.id > mx_outbox.id)",
                                params![key],
                            )
                            .is_ok_and(|n| n == 1);
                    if superseded {
                        continue;
                    }
                    let budget = if is_draft { 10 } else { MX_SEND_RETRIES };
                    let give_up = e.is_permanent() || retries + 1 >= budget;
                    let next = (chrono::Utc::now()
                        + chrono::Duration::seconds(crate::sync::retry::next_backoff_secs(retries + 1)))
                    .to_rfc3339();
                    let status = if give_up { OutboxStatus::Failed } else { OutboxStatus::Pending };
                    let _ = conn.execute(
                        "UPDATE mx_outbox SET status = ?2, retry_count = ?3, next_retry_at = ?4, error_message = ?5, updated_at = ?6
                         WHERE key = ?1",
                        params![key, status.as_str(), retries + 1, next, e.to_string(), stamp],
                    );
                    log::warn!("[mx] outbox {key} ({kind}) failed{}: {e}", if give_up { ", giving up" } else { "" });
                    if !give_up {
                        break;
                    }
                }
            }
        }
        delivered
    }

    /// Claim a row for delivery. Drafts: a version waits while another version
    /// of the same draft is in flight (two concurrent saves would create two
    /// drafts), and only the newest version is ever claimed.
    fn mx_outbox_claim(&self, key: &str, stale: &str) -> bool {
        let now = chrono::Utc::now().to_rfc3339();
        self.store()
            .connection()
            .lock()
            .execute(
                "UPDATE mx_outbox SET status = ?3, updated_at = ?2
                 WHERE key = ?1 AND (status = ?4 OR (status = ?3 AND updated_at <= ?5))
                   AND NOT (draft_key IS NOT NULL AND EXISTS (
                         SELECT 1 FROM mx_outbox o WHERE o.draft_key = mx_outbox.draft_key AND o.key != mx_outbox.key
                           AND ((o.status = ?3 AND o.updated_at > ?5) OR (o.id > mx_outbox.id AND o.status IN (?3, ?4)))))",
                params![key, now, OutboxStatus::Sending.as_str(), OutboxStatus::Pending.as_str(), stale],
            )
            .map(|n| n == 1)
            .unwrap_or(false)
    }

    /// Add or remove one tag (by key or name) on each thread. Sent as a single
    /// add/remove, never a whole set, so a stale mirror can't undo a teammate's
    /// tag; the response's full set is written back into the mirror.
    pub async fn mx_tag(&self, org: &str, threads: &[String], tag: &str, add: bool) -> Result<()> {
        let tag_id = self.mx_directory_key(org, "tags", tag)?;
        let ctx = self.mx_ctx().await?;
        let body = if add { json!({ "add_tag_ids": [tag_id] }) } else { json!({ "remove_tag_ids": [tag_id] }) };
        for thread in threads {
            let resp = mx_write(&ctx, reqwest::Method::PUT, org, &format!("conversations/{thread}/tags"), &body).await?;
            self.mx_mirror_field(org, thread, "$.tags", &resp["conversation"]["tags"])?;
        }
        Ok(())
    }

    /// Move threads to a status folder (inbox/archive/trash/spam, via the action
    /// queue) or into a Space by key, slug or name. Spaces are hosted mail's
    /// folders.
    pub async fn mx_move(&self, org: &str, threads: &[String], folder: &str) -> Result<()> {
        let lowered = folder.to_ascii_lowercase();
        if let Some((_, action)) = ROLE_ACTIONS.iter().find(|(name, _)| *name == lowered) {
            return self.mx_action(org, threads, action).await;
        }
        let space_id = self.mx_directory_key(org, "spaces", folder)?;
        let ctx = self.mx_ctx().await?;
        for thread in threads {
            let resp = mx_write(&ctx, reqwest::Method::PUT, org, &format!("conversations/{thread}/space"), &json!({ "space_id": space_id })).await?;
            let space = &resp["conversation"]["space"];
            self.mx_mirror_field(org, thread, "$.space", space)?;
            self.store().connection().lock().execute(
                "UPDATE mx_conversations SET space_slug = ?3 WHERE key = ?1 AND organization_id = ?2",
                params![thread, org, space["slug"].as_str()],
            )?;
        }
        Ok(())
    }

    /// Permanently delete threads: trash them, then delete. Both ride the action
    /// queue in order, and the server only destroys what is already in trash.
    pub async fn mx_delete(&self, org: &str, threads: &[String]) -> Result<()> {
        self.mx_action(org, threads, "trash").await?;
        self.mx_action(org, threads, "delete").await
    }

    /// The `key` of a tag/Space named by key, slug or (case-insensitive) name.
    fn mx_directory_key(&self, org: &str, kind: &str, wanted: &str) -> Result<String> {
        self.store()
            .connection()
            .lock()
            .query_row(
                "SELECT key FROM mx_directory WHERE organization_id = ?1 AND type = ?2
                   AND (key = ?3 OR lower(json_extract(payload, '$.name')) = lower(?3)
                        OR lower(COALESCE(json_extract(payload, '$.slug'), '')) = lower(?3))
                 ORDER BY position LIMIT 1",
                params![org, kind, wanted],
                |r| r.get(0),
            )
            .optional()?
            .ok_or_else(|| SyncError::Other(format!("no {} named '{wanted}' in {org}", kind.trim_end_matches('s'))))
    }

    #[cfg(test)]
    fn mx_thread_json(&self, org: &str, thread: &str, path: &str) -> Result<Value> {
        let raw: Option<String> = self
            .store()
            .connection()
            .lock()
            .query_row(
                "SELECT json_extract(payload, ?3) FROM mx_conversations WHERE key = ?1 AND organization_id = ?2",
                params![thread, org, path],
                |r| r.get(0),
            )
            .optional()?
            .ok_or_else(|| SyncError::Other(format!("conversation '{thread}' not found in {org}")))?;
        Ok(raw.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null))
    }

    fn mx_mirror_field(&self, org: &str, thread: &str, path: &str, value: &Value) -> Result<()> {
        self.store().connection().lock().execute(
            "UPDATE mx_conversations SET payload = json_set(payload, ?3, json(?4)) WHERE key = ?1 AND organization_id = ?2",
            params![thread, org, path, value.to_string()],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::events::NullSink;
    use crate::sync::store::SyncStore;
    use std::sync::Arc;
    use wiremock::matchers::{body_partial_json, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    const ORG: &str = "org_1";

    async fn engine(server: &MockServer) -> SyncEngine {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let engine = SyncEngine::new(store, Arc::new(NullSink));
        engine.set_api_context(format!("{}/api/v1", server.uri()), "ink_tok".into()).await;
        let conn = engine.store().connection();
        let c = conn.lock();
        c.execute("INSERT INTO mx_sync_state (organization_id, user_key) VALUES (?1, 'usr_me')", params![ORG]).unwrap();
        let dir = |kind: &str, key: &str, payload: Value| {
            c.execute(
                "INSERT INTO mx_directory (organization_id, type, key, payload) VALUES (?1, ?2, ?3, ?4)",
                params![ORG, kind, key, payload.to_string()],
            )
            .unwrap();
        };
        dir("organization", ORG, json!({ "domain": "acme.com" }));
        dir("domains", "dom_1", json!({ "name": "other.io" }));
        dir("domains", "dom_2", json!({ "name": "acme.com" }));
        dir("members", "mbr_me", json!({ "user": { "id": "usr_me", "username": "sam" },
                                          "mailboxes": [{ "email_address": "support@acme.com" }] }));
        dir("members", "mbr_other", json!({ "user": { "id": "usr_x", "username": "kim" }, "mailboxes": [] }));
        dir("tags", "tag_1", json!({ "name": "Urgent" }));
        dir("spaces", "spc_1", json!({ "name": "Sales", "slug": "sales" }));
        c.execute(
            "INSERT INTO mx_conversations (key, organization_id, payload) VALUES ('conv_1', ?1, ?2)",
            params![ORG, json!({ "tags": [{ "id": "tag_0" }] }).to_string()],
        )
        .unwrap();
        c.execute(
            "INSERT INTO mx_messages (key, conversation_key, organization_id, payload)
             VALUES ('msg_1', 'conv_1', ?1, ?2)",
            params![ORG, json!({ "to_address": "Support <SUPPORT@acme.com>", "from_address": "c@cust.com" }).to_string()],
        )
        .unwrap();
        drop(c);
        engine
    }

    #[tokio::test]
    async fn identities_put_the_primary_domain_first_then_mailboxes() {
        let server = MockServer::start().await;
        let engine = engine(&server).await;
        assert_eq!(engine.mx_identities(ORG).unwrap(), ["sam@acme.com", "sam@other.io", "support@acme.com"]);
    }

    #[tokio::test]
    async fn a_reply_threads_and_sends_from_the_address_it_was_sent_to() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(format!("/api/v1/orgs/{ORG}/messages")))
            .and(body_partial_json(json!({ "conversation_id": "conv_1", "reply_to_message_id": "msg_1", "from_address": "support@acme.com" })))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "message": { "id": "msg_2" } })))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path(format!("/api/v1/orgs/{ORG}/drafts")))
            .and(body_partial_json(json!({ "from_address": "sam@acme.com" })))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "draft": { "id": "msg_d" } })))
            .expect(1)
            .mount(&server)
            .await;
        let engine = engine(&server).await;
        let reply = OutgoingMessage {
            to_address: "c@cust.com".into(),
            body_plain: Some("hi".into()),
            reply_to_message_key: Some("msg_1".into()),
            ..Default::default()
        };
        let sent = engine.mx_compose(ORG, reply, None).await.unwrap();
        assert_eq!((sent.status, sent.provider_message_id.as_deref()), (OutboxStatus::Sent, Some("msg_2")));
        let fresh = OutgoingMessage { to_address: "x@y.z".into(), ..Default::default() };
        engine.mx_compose(ORG, fresh, Some("drf_1")).await.unwrap();

        let spoof = OutgoingMessage { from_address: "ceo@acme.com".into(), to_address: "x@y.z".into(), ..Default::default() };
        assert!(engine.mx_compose(ORG, spoof, None).await.is_err());
    }

    #[tokio::test]
    async fn tags_send_the_whole_set_and_spaces_resolve_by_name() {
        let server = MockServer::start().await;
        Mock::given(method("PUT"))
            .and(path(format!("/api/v1/orgs/{ORG}/conversations/conv_1/tags")))
            .and(body_partial_json(json!({ "add_tag_ids": ["tag_1"] })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "conversation": { "tags": [{ "id": "tag_0" }, { "id": "tag_1" }] } })))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("PUT"))
            .and(path(format!("/api/v1/orgs/{ORG}/conversations/conv_1/space")))
            .and(body_partial_json(json!({ "space_id": "spc_1" })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "conversation": { "space": { "id": "spc_1", "slug": "sales" } } })))
            .expect(1)
            .mount(&server)
            .await;
        let engine = engine(&server).await;
        engine.mx_tag(ORG, &["conv_1".into()], "urgent", true).await.unwrap();
        assert_eq!(engine.mx_thread_json(ORG, "conv_1", "$.tags").unwrap().as_array().unwrap().len(), 2);
        engine.mx_move(ORG, &["conv_1".into()], "Sales").await.unwrap();
        assert!(engine.mx_tag(ORG, &["conv_1".into()], "Nope", true).await.is_err());
    }

    fn outbox(engine: &SyncEngine) -> Vec<(String, String, String)> {
        let conn = engine.store().connection();
        let c = conn.lock();
        let mut stmt = c.prepare("SELECT status, COALESCE(draft_key, ''), json_extract(payload, '$.body_plain') FROM mx_outbox ORDER BY id").unwrap();
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, Option<String>>(2)?.unwrap_or_default())))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    }

    // The CLI's prebuilt body: kept whole, given a Message-ID, and a failed send
    // goes out again on retry.
    #[tokio::test]
    async fn prebuilt_send_keeps_its_fields_and_retries_after_failing() {
        let server = MockServer::start().await;
        let engine = engine(&server).await;
        Mock::given(method("POST")).and(path(format!("/api/v1/orgs/{ORG}/messages")))
            .respond_with(ResponseTemplate::new(422).set_body_json(json!({ "errors": [{ "message": "nope" }] })))
            .up_to_n_times(1).mount(&server).await;
        let body = json!({ "from_address": "Me <me@acme.com>", "to_address": "x@y.z", "attachment_keys": ["att_1"] });
        let failed = engine.mx_send(ORG, &body).await.unwrap();
        assert_eq!(failed.status, OutboxStatus::Failed);

        Mock::given(method("POST")).and(path(format!("/api/v1/orgs/{ORG}/messages")))
            .and(body_partial_json(json!({ "attachment_keys": ["att_1"],
                "message_id_header": format!("<{}@acme.com>", failed.outbox_key) })))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "message": { "id": "msg_9" } })))
            .expect(1).mount(&server).await;
        let sent = engine.mx_outbox_retry(&failed.outbox_key).await.unwrap();
        assert_eq!((sent.status, sent.provider_message_id.as_deref()), (OutboxStatus::Sent, Some("msg_9")));
        assert!(engine.mx_outbox_retry(&failed.outbox_key).await.is_err());  // only a failed row retries
    }

    // Offline (no session): sends and drafts queue instead of failing, and a
    // draft keeps only its latest version. Once online, the draft is created
    // once and later versions update that same draft.
    #[tokio::test]
    async fn offline_sends_and_drafts_queue_and_drafts_keep_only_the_latest() {
        let server = MockServer::start().await;
        let engine = engine(&server).await;
        engine.set_api_context(format!("{}/api/v1", server.uri()), String::new()).await;
        let msg = |body: &str| OutgoingMessage { to_address: "x@y.z".into(), body_plain: Some(body.into()), ..Default::default() };

        let r = engine.mx_compose(ORG, msg("send me"), None).await.unwrap();
        assert_eq!(r.status, OutboxStatus::Pending);
        engine.mx_compose(ORG, msg("v1"), Some("drf_1")).await.unwrap();
        engine.mx_compose(ORG, msg("v2"), Some("drf_1")).await.unwrap();
        assert_eq!(
            outbox(&engine),
            [("pending".into(), "".into(), "send me".into()), ("pending".into(), "drf_1".into(), "v2".into())]
        );

        Mock::given(method("POST")).and(path(format!("/api/v1/orgs/{ORG}/messages")))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "message": { "id": "msg_9" } })))
            .expect(1).mount(&server).await;
        // Every version upserts under the draft's one Message-ID.
        Mock::given(method("POST")).and(path(format!("/api/v1/orgs/{ORG}/drafts")))
            .and(body_partial_json(json!({ "body_plain": "v2", "message_id_header": "<drf_1@acme.com>" })))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "draft": { "id": "msg_d" } })))
            .expect(1).mount(&server).await;
        Mock::given(method("POST")).and(path(format!("/api/v1/orgs/{ORG}/drafts")))
            .and(body_partial_json(json!({ "body_plain": "v3", "message_id_header": "<drf_1@acme.com>" })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "draft": { "id": "msg_d" } })))
            .expect(1).mount(&server).await;
        engine.set_api_context(format!("{}/api/v1", server.uri()), "ink_tok".into()).await;
        assert_eq!(engine.mx_outbox_drain().await, 2);
        let r = engine.mx_compose(ORG, msg("v3"), Some("drf_1")).await.unwrap();
        assert_eq!((r.status, r.provider_message_id.as_deref()), (OutboxStatus::Sent, Some("msg_d")));
    }
}
