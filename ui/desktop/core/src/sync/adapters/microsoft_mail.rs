//! Microsoft 365 provider adapter — Microsoft Graph API (not IMAP).
//!
//! Ported from the JS `microsoft-sync.js`. Folder-based delta sync: each folder
//! carries its own opaque cursor (`@odata.deltaLink`, a URL). The adapter returns
//! `UnifiedMessage`s; threading/dedup/cleanup are owned by `SyncStore`.

use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::sync::adapters::util::{http_status_error, parse_json_response, sanitize};
use crate::sync::util::{header_value, json_array, json_bool};
use crate::sync::error::{Result, SyncError};
use crate::sync::model::*;
use crate::sync::oauth::TokenManager;
use crate::sync::provider::ProviderAdapter;
use crate::sync::store::SyncStore;

const GRAPH_API: &str = "https://graph.microsoft.com/v1.0";

/// Microsoft well-known folder ids, used both as Graph `move` `destinationId`
/// values (apply_action) and in the flag↔folder mapping (normalize/denormalize).
/// Single source of truth so the round-trip can't silently drift on a typo.
mod ms_folder {
    pub const INBOX: &str = "inbox";
    pub const ARCHIVE: &str = "archive";
    pub const TRASH: &str = "deleteditems";
    pub const JUNK: &str = "junkemail";
}
const DELTA_SELECT: &str = "id,subject,from,toRecipients,ccRecipients,\
receivedDateTime,sentDateTime,isRead,isDraft,flag,parentFolderId,\
internetMessageId,internetMessageHeaders,hasAttachments";

/// Hard cap on delta pages drained in one incremental sync, guarding against a
/// server returning a cyclic/non-terminating `@odata.nextLink`.
const MAX_DELTA_PAGES: u32 = 1000;

pub struct MicrosoftAdapter {
    capabilities: ProviderCapabilities,
    token: Arc<TokenManager>,
    store: Arc<SyncStore>,
    account_key: String,
    api_base: String,
}

impl MicrosoftAdapter {
    pub fn new(token: Arc<TokenManager>, store: Arc<SyncStore>, account_key: String) -> Self {
        Self {
            capabilities: ProviderCapabilities {
                push: false, // polling for now; subscriptions deferred
                incremental_sync: true,
                conditional_store: true,
                server_move: true,
                labels: false,
                custom_keywords: false,
                notify: false,
                raw: vec!["microsoft-graph".to_string()],
            },
            token,
            store,
            account_key,
            api_base: GRAPH_API.to_string(),
        }
    }

    #[cfg(test)]
    pub fn with_base(mut self, api_base: String) -> Self {
        self.api_base = api_base;
        self
    }

    async fn get_json(&self, url: &str) -> Result<Value> {
        let resp = self.token.request(reqwest::Method::GET, url, None).await?;
        parse_json_response("Graph", resp, |status, body| {
            if status == reqwest::StatusCode::GONE {
                return Some(SyncError::CursorExpired);
            }
            if body.is_some_and(|b| b.contains("syncStateNotFound")) {
                return Some(SyncError::CursorExpired);
            }
            None
        })
        .await
    }

    /// Resolve a URL: delta/next links are absolute; otherwise prefix the base.
    fn resolve(&self, path_or_url: &str) -> String {
        if path_or_url.starts_with("http") {
            path_or_url.to_string()
        } else {
            format!("{}{}", self.api_base, path_or_url)
        }
    }

    async fn fetch_avatar(&self) {
        let url = format!("{}/me/photo/$value", self.api_base);
        let resp = match self.token.request(reqwest::Method::GET, &url, None).await {
            Ok(r) if r.status().is_success() => r,
            Ok(r) => {
                log::debug!("avatar fetch: photo endpoint returned {}", r.status());
                return;
            }
            Err(e) => {
                log::debug!("avatar fetch failed: {e}");
                return;
            }
        };
        let ct = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("image/jpeg")
            .to_string();
        if let Ok(bytes) = resp.bytes().await {
            let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
            let data_uri = format!("data:{ct};base64,{b64}");
            if let Err(e) = self.store.set_account_avatar(&self.account_key, &data_uri) {
                log::warn!("storing account avatar failed: {e}");
            }
        }
    }

    /// Drain a delta sequence (initial or incremental) following `@odata.nextLink`
    /// pages until the terminal `@odata.deltaLink`. Returns
    /// (messages, deletions, delta_link, next_link). On a single page with a
    /// nextLink (initial-sync batching), returns that nextLink and no deltaLink.
    async fn drain_page(
        &self,
        url: &str,
        folder: &UnifiedFolder,
    ) -> Result<(Vec<(UnifiedMessage, ProviderMessageId)>, Vec<ProviderMessageId>, Option<String>, Option<String>)> {
        let data = self.get_json(url).await?;
        let mut messages = Vec::new();
        let mut deletions = Vec::new();

        for item in json_array(&data, "value") {
            let id = item.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_string();
            if id.is_empty() {
                continue;
            }
            if item.get("@removed").is_some() {
                deletions.push(ProviderMessageId {
                    uid: None,
                    mod_seq: None,
                    provider_id: Some(id),
                });
            } else if is_ghost_item(&item) {
                // Graph deltas occasionally carry an id-only shell (no sender, no
                // subject, no message-id, no date — not a mail item we can show).
                // Storing it would mint an empty conversation that the triage
                // worker and Bridge brief then announce as phantom mail.
                log::warn!("skipping ghost delta item in {}: {item}", folder.provider_name);
            } else {
                messages.push((
                    build_message(&item, folder),
                    ProviderMessageId { uid: None, mod_seq: None, provider_id: Some(id) },
                ));
            }
        }

        let next_link = data.get("@odata.nextLink").and_then(|v| v.as_str()).map(String::from);
        let delta_link = data.get("@odata.deltaLink").and_then(|v| v.as_str()).map(String::from);
        Ok((messages, deletions, delta_link, next_link))
    }
}

#[async_trait]
impl ProviderAdapter for MicrosoftAdapter {
    async fn connect(&mut self, _credentials: &ProviderCredentials) -> Result<ProviderCapabilities> {
        // Propagate the underlying error verbatim — `get_json` already
        // classifies it (401/403 → `HttpStatus`, refresh failure →
        // `TokenRefresh`, network → `Http`), so the engine can tell a
        // genuinely-expired sign-in (→ NeedsReauth) from a transient blip.
        // Blanket-wrapping every failure as `AuthFailed` here is what made every
        // error look like an expired token to the client.
        let url = format!("{}/me", self.api_base);
        self.get_json(&url).await?;
        self.fetch_avatar().await;
        Ok(self.capabilities.clone())
    }

    async fn disconnect(&mut self) -> Result<()> {
        Ok(())
    }

    fn capabilities(&self) -> &ProviderCapabilities {
        &self.capabilities
    }

    async fn list_folders(&mut self) -> Result<Vec<UnifiedFolder>> {
        let url = format!(
            "{}/me/mailFolders?$top=100&$select=id,displayName,totalItemCount,unreadItemCount",
            self.api_base
        );
        let data = self.get_json(&url).await?;
        let mut folders = Vec::new();

        for f in json_array(&data, "value") {
            let graph_id = f.get("id").and_then(|v| v.as_str()).unwrap_or_default();
            if graph_id.is_empty() {
                continue;
            }
            let display = f.get("displayName").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let role = WellKnownFolder::from_display_name(&display);
            let suffix = match &role {
                Some(r) => r.as_str().to_string(),
                None => sanitize(graph_id),
            };
            let key = format!("fld_ms_{}_{}", self.account_key, suffix);
            folders.push(UnifiedFolder {
                key,
                account_key: self.account_key.clone(),
                provider_name: if display.is_empty() { graph_id.to_string() } else { display },
                role,
                separator: None,
                flags: vec![graph_id.to_string()], // graph folder id
                uid_validity: None,
                highest_mod_seq: 0,
                last_synced_uid: 0,
                sync_cursor: None,
                sync_enabled: true,
            });
        }
        Ok(folders)
    }

    async fn initial_sync(
        &mut self,
        folder: &UnifiedFolder,
        batch_size: u32,
        continuation: Continuation,
    ) -> Result<FolderSyncResult> {
        let graph_id = folder.flags.first().cloned().unwrap_or_default();
        let url = match &continuation {
            Some(next) => self.resolve(next),
            None => format!(
                "{}/me/mailFolders/{}/messages/delta?$select={}&$top={}",
                self.api_base, graph_id, DELTA_SELECT, batch_size
            ),
        };

        let (messages, _deletions, delta_link, next_link) = self.drain_page(&url, folder).await?;

        let seen: HashSet<String> = messages
            .iter()
            .filter_map(|(_, pid)| pid.provider_id.clone())
            .collect();

        let has_more = next_link.is_some();
        Ok(FolderSyncResult {
            messages,
            seen_provider_ids: Some(seen),
            continuation: next_link,
            next_token: delta_link, // present only on the final page
            has_more,
            ..Default::default()
        })
    }

    async fn start_watching(
        &mut self,
        _folders: &[UnifiedFolder],
        _credentials: &ProviderCredentials,
        _tx: mpsc::UnboundedSender<ProviderEvent>,
    ) -> Result<()> {
        Ok(())
    }

    async fn stop_watching(&mut self) -> Result<()> {
        Ok(())
    }

    // ── Cloud push (Graph subscriptions) — see docs/Cloud-Push.md ───────────
    // The client creates the subscription with its own token, pointing notificationUrl
    // at our Rails backend. Graph POSTs change notifications (resource path + ids, no
    // content, plus the clientState secret) to Rails, which fans out a "go sync" signal.

    async fn create_push_subscription(&mut self, config: &PushSubConfig) -> Result<PushSubInfo> {
        let notification_url = config
            .microsoft_notification_url
            .as_deref()
            .ok_or_else(|| SyncError::Other("push config missing microsoft_notification_url".into()))?;

        // Per-subscription secret echoed back in every notification (we verify it).
        let client_state = random_client_state();
        // Mail subscriptions max out at ~4230 minutes; stay safely under it.
        let expiration = (chrono::Utc::now() + chrono::Duration::minutes(4000)).to_rfc3339();

        let url = format!("{}/subscriptions", self.api_base);
        let body = serde_json::json!({
            // created → new mail; updated → read-state/move; deleted → removal.
            // Gives delete/read parity with Gmail's INBOX history watch. The push is
            // a content-free nudge regardless of changeType, so the receiver is unchanged.
            "changeType": "created,updated,deleted",
            "notificationUrl": notification_url,
            "resource": "/me/mailFolders('inbox')/messages",
            "expirationDateTime": expiration,
            "clientState": client_state,
        });
        let resp = self
            .token
            .request(reqwest::Method::POST, &url, Some(&body))
            .await?;
        let status = resp.status();
        if !status.is_success() {
            let b = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Graph subscribe", status, &b));
        }
        let data: Value = resp.json().await?;
        Ok(PushSubInfo {
            provider_subscription_id: data.get("id").and_then(|v| v.as_str()).map(str::to_string),
            client_state: Some(client_state),
            expires_at: data
                .get("expirationDateTime")
                .and_then(|v| v.as_str())
                .map(str::to_string),
        })
    }

    async fn renew_push_subscription(
        &mut self,
        config: &PushSubConfig,
        existing: &PushSubInfo,
    ) -> Result<PushSubInfo> {
        let Some(id) = existing.provider_subscription_id.as_deref() else {
            // No id to renew → create a fresh subscription.
            return self.create_push_subscription(config).await;
        };
        let expiration = (chrono::Utc::now() + chrono::Duration::minutes(4000)).to_rfc3339();
        let url = format!("{}/subscriptions/{id}", self.api_base);
        let body = serde_json::json!({ "expirationDateTime": expiration });
        let resp = self
            .token
            .request(reqwest::Method::PATCH, &url, Some(&body))
            .await?;
        let status = resp.status();
        if status == reqwest::StatusCode::NOT_FOUND {
            // Subscription lapsed server-side → create anew.
            return self.create_push_subscription(config).await;
        }
        if !status.is_success() {
            let b = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Graph renew", status, &b));
        }
        let data: Value = resp.json().await?;
        Ok(PushSubInfo {
            provider_subscription_id: Some(id.to_string()),
            client_state: existing.client_state.clone(),
            expires_at: data
                .get("expirationDateTime")
                .and_then(|v| v.as_str())
                .map(str::to_string),
        })
    }

    async fn delete_push_subscription(&mut self, existing: &PushSubInfo) -> Result<()> {
        let Some(id) = existing.provider_subscription_id.as_deref() else {
            return Ok(());
        };
        let url = format!("{}/subscriptions/{id}", self.api_base);
        let resp = self
            .token
            .request(reqwest::Method::DELETE, &url, None)
            .await?;
        let status = resp.status();
        if !status.is_success() && status != reqwest::StatusCode::NOT_FOUND {
            let b = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Graph unsubscribe", status, &b));
        }
        Ok(())
    }

    async fn incremental_sync(
        &mut self,
        folder: &UnifiedFolder,
        cursor: &SyncCursor,
    ) -> Result<FolderSyncResult> {
        let mut url = match cursor.token.as_deref() {
            Some(t) => t.to_string(),
            None => return Err(SyncError::CursorExpired),
        };

        let mut all_messages = Vec::new();
        let mut all_deletions = Vec::new();
        let mut next_token = None;

        // Drain all delta pages until the terminal deltaLink. Bounded by
        // MAX_DELTA_PAGES so a server that returns a cyclic/repeating nextLink
        // (or never terminates) can't spin forever or accumulate unboundedly —
        // we bail out and let the next sync resume from the last cursor.
        let mut pages = 0u32;
        loop {
            pages += 1;
            if pages > MAX_DELTA_PAGES {
                log::warn!(
                    "Graph delta for {} exceeded {} pages; stopping (will resume next sync)",
                    folder.provider_name,
                    MAX_DELTA_PAGES
                );
                break;
            }
            let (mut msgs, mut dels, delta_link, next_link) = self.drain_page(&url, folder).await?;
            all_messages.append(&mut msgs);
            all_deletions.append(&mut dels);
            match (next_link, delta_link) {
                (Some(next), _) => url = self.resolve(&next),
                (None, Some(delta)) => {
                    next_token = Some(delta);
                    break;
                }
                (None, None) => break,
            }
        }

        Ok(FolderSyncResult {
            messages: all_messages,
            deletions: all_deletions,
            next_token,
            ..Default::default()
        })
    }

    async fn apply_action(
        &mut self,
        action: &WritebackAction,
        provider_state: &ProviderMessageId,
    ) -> Result<()> {
        let id = provider_state
            .provider_id
            .as_deref()
            .ok_or_else(|| SyncError::Other("Graph action: missing message id".into()))?;
        let base = &self.api_base;

        let (method, url, body): (reqwest::Method, String, Option<Value>) = match &action.action_type {
            ActionType::MarkRead => (
                reqwest::Method::PATCH,
                format!("{base}/me/messages/{id}"),
                Some(serde_json::json!({ "isRead": true })),
            ),
            ActionType::MarkUnread => (
                reqwest::Method::PATCH,
                format!("{base}/me/messages/{id}"),
                Some(serde_json::json!({ "isRead": false })),
            ),
            ActionType::Flag => (
                reqwest::Method::PATCH,
                format!("{base}/me/messages/{id}"),
                Some(serde_json::json!({ "flag": { "flagStatus": "flagged" } })),
            ),
            ActionType::Unflag => (
                reqwest::Method::PATCH,
                format!("{base}/me/messages/{id}"),
                Some(serde_json::json!({ "flag": { "flagStatus": "notFlagged" } })),
            ),
            ActionType::Archive => (
                reqwest::Method::POST,
                format!("{base}/me/messages/{id}/move"),
                Some(serde_json::json!({ "destinationId": ms_folder::ARCHIVE })),
            ),
            ActionType::Unarchive => (
                reqwest::Method::POST,
                format!("{base}/me/messages/{id}/move"),
                Some(serde_json::json!({ "destinationId": ms_folder::INBOX })),
            ),
            ActionType::Trash => (
                reqwest::Method::POST,
                format!("{base}/me/messages/{id}/move"),
                Some(serde_json::json!({ "destinationId": ms_folder::TRASH })),
            ),
            ActionType::Move { target_folder } => (
                reqwest::Method::POST,
                format!("{base}/me/messages/{id}/move"),
                Some(serde_json::json!({ "destinationId": target_folder })),
            ),
            // Plain DELETE only moves to Deleted Items; permanentDelete is gone.
            ActionType::Delete => (reqwest::Method::POST, format!("{base}/me/messages/{id}/permanentDelete"), None),
            // A label is an Outlook category. Graph replaces the whole list on
            // PATCH, so read it first and write it back with the one change.
            ActionType::AddLabel { label } | ActionType::RemoveLabel { label } => {
                let url = format!("{base}/me/messages/{id}");
                let resp = self
                    .token
                    .request(reqwest::Method::GET, &format!("{url}?$select=categories"), None)
                    .await?;
                if resp.status() == reqwest::StatusCode::NOT_FOUND {
                    return Ok(());
                }
                if !resp.status().is_success() {
                    return Err(SyncError::HttpStatus {
                        code: resp.status().as_u16(),
                        context: format!("Graph read categories {}", resp.status()),
                    });
                }
                let current: Value = resp.json().await?;
                let mut categories: Vec<String> = current["categories"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|c| c.as_str().map(String::from)).collect())
                    .unwrap_or_default();
                categories.retain(|c| !c.eq_ignore_ascii_case(label));
                if matches!(action.action_type, ActionType::AddLabel { .. }) {
                    categories.push(label.clone());
                }
                (reqwest::Method::PATCH, url, Some(serde_json::json!({ "categories": categories })))
            }
            // Interactive verbs (spam/quadrant) are applied via the
            // InteractiveProvider path in engine.process_writeback, never here.
            ActionType::Interactive { .. } => return Ok(()),
        };

        let resp = self.token.request(method, &url, body.as_ref()).await?;
        let status = resp.status();
        if status.is_success() || status == reqwest::StatusCode::NOT_FOUND {
            Ok(())
        } else if status == reqwest::StatusCode::PRECONDITION_FAILED {
            Err(SyncError::WriteConflict)
        } else {
            // Preserve the status code (see Gmail check_writeback) so the drain
            // classifies auth/permanent/transient instead of blindly retrying.
            let body = resp.text().await.unwrap_or_default();
            Err(http_status_error("Graph writeback", status, &body))
        }
    }

    fn normalize_flags(&self, provider_flags: &ProviderFlags) -> UnifiedFlags {
        let mut f = UnifiedFlags::default();
        if let Some(ref folder) = provider_flags.folder {
            match folder.to_lowercase().as_str() {
                ms_folder::ARCHIVE => f.archived = true,
                ms_folder::TRASH | "deleted items" => f.trashed = true,
                ms_folder::JUNK | "junk e-mail" => f.spam = true,
                _ => {}
            }
        }
        f
    }

    fn denormalize_flags(&self, unified: &UnifiedFlags, _folder: Option<&str>) -> ProviderFlags {
        // Microsoft represents archive/trash/spam state as the message's parent
        // folder — the inverse of `normalize_flags`, which derives those flags
        // from `folder`. A message lives in exactly one folder, so resolve to the
        // single most-specific destination (the well-known folder ids used as
        // `destinationId` in `apply_action`). read/flagged/draft have no `folder`
        // representation and are pushed via `apply_action` (PATCH) instead.
        let folder = if unified.trashed {
            ms_folder::TRASH
        } else if unified.spam {
            ms_folder::JUNK
        } else if unified.archived {
            ms_folder::ARCHIVE
        } else {
            ms_folder::INBOX
        };
        ProviderFlags {
            folder: Some(folder.to_string()),
            ..Default::default()
        }
    }
}

// ── Free helpers ─────────────────────────────────────────────────────────

/// Random per-subscription secret echoed back in every Graph notification, used
/// to verify a webhook genuinely corresponds to a subscription we created.
fn random_client_state() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Format a Graph emailAddress object as "Name <addr>" / "addr".
fn format_address(addr: &Value) -> String {
    let name = addr.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let address = addr.get("address").and_then(|v| v.as_str()).unwrap_or("");
    if !name.is_empty() && !address.is_empty() {
        format!("{name} <{address}>")
    } else if !address.is_empty() {
        address.to_string()
    } else {
        name.to_string()
    }
}

fn recipients(msg: &Value, key: &str) -> Option<String> {
    let list = msg.get(key)?.as_array()?;
    let joined = list
        .iter()
        .filter_map(|r| r.get("emailAddress"))
        .map(format_address)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(", ");
    if joined.is_empty() {
        None
    } else {
        Some(joined)
    }
}

/// Build a UnifiedMessage from a Graph message resource. Flags derive from the
/// message properties plus the containing folder's role.
/// A delta item that carries an id but none of the fields that make it a mail
/// message we could ever display or thread. Real messages always have at least
/// one of these (they're all in the delta `$select`).
fn is_ghost_item(msg: &Value) -> bool {
    let has_str = |k: &str| msg.get(k).and_then(|v| v.as_str()).map_or(false, |s| !s.is_empty());
    !has_str("internetMessageId")
        && !has_str("subject")
        && !has_str("receivedDateTime")
        && !has_str("sentDateTime")
        && msg.get("from").and_then(|f| f.get("emailAddress")).is_none()
}

fn build_message(msg: &Value, folder: &UnifiedFolder) -> UnifiedMessage {
    let graph_id = msg.get("id").and_then(|v| v.as_str()).unwrap_or_default();

    // internetMessageHeaders lookup (case-insensitive), for threading.
    let header = |name: &str| header_value(msg.get("internetMessageHeaders"), name);

    let message_id = msg
        .get("internetMessageId")
        .and_then(|v| v.as_str())
        .map(String::from)
        .or_else(|| header("message-id"))
        .unwrap_or_else(|| format!("<graph-{graph_id}@outlook.com>"));

    let from = msg
        .get("from")
        .and_then(|f| f.get("emailAddress"))
        .map(format_address)
        .unwrap_or_default();

    let parse_graph_date = |key: &str| {
        msg.get(key)
            .and_then(|v| v.as_str())
            .and_then(|s| {
                chrono::DateTime::parse_from_rfc3339(s)
                    .ok()
                    .map(|dt| dt.with_timezone(&chrono::Utc))
            })
    };
    let date = parse_graph_date("receivedDateTime").or_else(|| parse_graph_date("sentDateTime"));
    // Graph's receipt time, used as the date fallback for parity with the other
    // adapters (Graph dates parse reliably, so this rarely differs from `date`).
    let internal_date = parse_graph_date("receivedDateTime");

    let read = json_bool(msg, "isRead").unwrap_or(true);
    let flagged = msg
        .get("flag")
        .and_then(|f| f.get("flagStatus"))
        .and_then(|v| v.as_str())
        .map(|s| s == "flagged")
        .unwrap_or(false);
    let draft = json_bool(msg, "isDraft").unwrap_or(false);

    let flags = UnifiedFlags {
        read,
        flagged,
        draft,
        trashed: folder.role == Some(WellKnownFolder::Trash),
        spam: folder.role == Some(WellKnownFolder::Spam),
        archived: folder.role == Some(WellKnownFolder::Archive),
    };

    // Body is usually not in the delta $select; populated on demand later.
    let (body_plain, body_html) = match msg.get("body") {
        Some(b) => {
            let content = b.get("content").and_then(|v| v.as_str()).map(String::from);
            match b.get("contentType").and_then(|v| v.as_str()) {
                Some("html") => (None, content),
                _ => (content, None),
            }
        }
        None => (None, None),
    };

    UnifiedMessage {
        key: String::new(),
        message_id,
        subject: msg.get("subject").and_then(|v| v.as_str()).map(String::from),
        from_address: from,
        to_address: recipients(msg, "toRecipients"),
        cc_address: recipients(msg, "ccRecipients"),
        in_reply_to: header("in-reply-to"),
        references_header: header("references"),
        body_plain,
        body_html,
        // Graph reports this directly (requested in the $select). It can be true
        // for inline-only images too, but that's an acceptable over-count for a
        // list indicator and avoids a per-message attachments fetch.
        has_attachment: json_bool(msg, "hasAttachments").unwrap_or(false),
        // Graph's list exposes only hasAttachments, not filenames; they backfill
        // into the search index on first open (see ffi fetch_message).
        attachment_names: None,
        attachment_max_size: None,
        is_inbound: true,
        flags,
        labels: HashSet::new(),
        folders: HashSet::new(),
        date,
        internal_date,
        provider_thread_id: msg.get("conversationId").and_then(|v| v.as_str()).map(String::from),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::RwLock;
    use wiremock::matchers::{body_partial_json, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn adapter_for(server: &MockServer) -> MicrosoftAdapter {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let account_key = store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: "M".into(),
                email_address: "u@outlook.com".into(),
                provider_type: ProviderType::Microsoft,
                host: None,
                port: None,
                use_tls: true,
                smtp_host: None,
                smtp_port: None,
                smtp_use_tls: true,
                auth_method: AuthMethod::OAuth2.as_str().into(),
                status: AccountStatus::Disconnected,
                error_message: None,
                last_connected_at: None,
                sort_order: 0,
                avatar_url: None,
            })
            .unwrap();
        let creds = ProviderCredentials::OAuth2 {
            username: "u@outlook.com".into(),
            access_token: "tok".into(),
            refresh_token: Some("r".into()),
        };
        let token = Arc::new(TokenManager::new(
            account_key.clone(),
            ProviderType::Microsoft,
            store.clone(),
            Arc::new(RwLock::new(None)),
            &creds,
        ));
        MicrosoftAdapter::new(token, store, account_key).with_base(format!("{}/v1.0", server.uri()))
    }

    fn inbox_folder() -> UnifiedFolder {
        UnifiedFolder {
            key: "fld_ms_a_inbox".into(),
            account_key: "a".into(),
            provider_name: "Inbox".into(),
            role: Some(WellKnownFolder::Inbox),
            separator: None,
            flags: vec!["AAMk-inbox".into()],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        }
    }

    #[tokio::test]
    async fn create_push_subscription_posts_subscription_and_returns_state() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1.0/subscriptions"))
            .and(body_partial_json(serde_json::json!({
                "changeType": "created,updated,deleted",
                "notificationUrl": "https://host.ts.net/api/v1/push/microsoft",
                "resource": "/me/mailFolders('inbox')/messages",
            })))
            .respond_with(ResponseTemplate::new(201).set_body_json(serde_json::json!({
                "id": "graph-sub-123",
                "expirationDateTime": "2026-06-08T00:00:00Z"
            })))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let config = PushSubConfig {
            push_enabled: true,
            gmail_topic: None,
            microsoft_notification_url: Some("https://host.ts.net/api/v1/push/microsoft".into()),
        };
        let info = adapter.create_push_subscription(&config).await.unwrap();
        assert_eq!(info.provider_subscription_id.as_deref(), Some("graph-sub-123"));
        // A random clientState was generated and will be echoed back for verification.
        assert_eq!(info.client_state.as_ref().map(|s| s.len()), Some(32));
        assert_eq!(info.expires_at.as_deref(), Some("2026-06-08T00:00:00Z"));
    }

    #[tokio::test]
    async fn renew_push_subscription_patches_existing_id() {
        let server = MockServer::start().await;
        Mock::given(method("PATCH"))
            .and(path("/v1.0/subscriptions/graph-sub-123"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "graph-sub-123",
                "expirationDateTime": "2026-06-11T00:00:00Z"
            })))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let config = PushSubConfig {
            push_enabled: true,
            microsoft_notification_url: Some("https://host.ts.net/api/v1/push/microsoft".into()),
            ..Default::default()
        };
        let existing = PushSubInfo {
            provider_subscription_id: Some("graph-sub-123".into()),
            client_state: Some("keepme".into()),
            expires_at: Some("2026-06-08T00:00:00Z".into()),
        };
        let info = adapter.renew_push_subscription(&config, &existing).await.unwrap();
        assert_eq!(info.provider_subscription_id.as_deref(), Some("graph-sub-123"));
        assert_eq!(info.client_state.as_deref(), Some("keepme")); // preserved across renew
        assert_eq!(info.expires_at.as_deref(), Some("2026-06-11T00:00:00Z"));
    }

    fn graph_msg(id: &str, message_id: &str, is_read: bool) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "subject": format!("subject {id}"),
            "isRead": is_read,
            "isDraft": false,
            "from": { "emailAddress": { "name": "Alice", "address": "alice@x.com" } },
            "toRecipients": [ { "emailAddress": { "address": "me@x.com" } } ],
            "internetMessageId": message_id,
            "internetMessageHeaders": [ { "name": "Message-ID", "value": message_id } ],
            "receivedDateTime": "2024-01-01T10:00:00Z"
        })
    }

    // ── Pure helpers ─────────────────────────────────────────────────────

    #[test]
    fn role_mapping_handles_display_names() {
        assert_eq!(WellKnownFolder::from_display_name("Inbox"), Some(WellKnownFolder::Inbox));
        assert_eq!(WellKnownFolder::from_display_name("Sent Items"), Some(WellKnownFolder::Sent));
        assert_eq!(
            WellKnownFolder::from_display_name("Deleted Items"),
            Some(WellKnownFolder::Trash)
        );
        assert_eq!(WellKnownFolder::from_display_name("Junk Email"), Some(WellKnownFolder::Spam));
        assert_eq!(WellKnownFolder::from_display_name("Project X"), None);
    }

    #[test]
    fn build_message_maps_graph_fields() {
        let trash = UnifiedFolder { role: Some(WellKnownFolder::Trash), ..inbox_folder() };
        let m = build_message(&graph_msg("g1", "<m1@x>", false), &trash);
        assert_eq!(m.message_id, "<m1@x>");
        assert_eq!(m.from_address, "Alice <alice@x.com>");
        assert_eq!(m.to_address.as_deref(), Some("me@x.com"));
        assert!(!m.flags.read); // isRead false
        assert!(m.flags.trashed); // folder role = Trash
    }

    #[test]
    fn extract_flags_default_read_when_missing() {
        let msg = serde_json::json!({ "id": "g2" });
        let m = build_message(&msg, &inbox_folder());
        assert!(m.flags.read); // isRead defaults to true
        assert!(!m.flags.trashed);
    }

    #[tokio::test]
    async fn flag_denormalize_then_normalize_roundtrips_via_folder() {
        // Microsoft encodes archive/trash/spam as the parent folder, so
        // denormalize → normalize must round-trip those three flags. (read/
        // flagged have no folder representation and go via apply_action.)
        let server = MockServer::start().await;
        let adapter = adapter_for(&server);

        // Each flag must denormalize to exactly its `ms_folder` constant (the
        // value also used as the Graph `move` destinationId) and normalize back —
        // a typo in one of the constants would break this round-trip.
        for (unified, expected) in [
            (UnifiedFlags { archived: true, ..Default::default() }, ms_folder::ARCHIVE),
            (UnifiedFlags { trashed: true, ..Default::default() }, ms_folder::TRASH),
            (UnifiedFlags { spam: true, ..Default::default() }, ms_folder::JUNK),
        ] {
            let pf = adapter.denormalize_flags(&unified, None);
            assert_eq!(
                pf.folder.as_deref(),
                Some(expected),
                "destination folder must be the ms_folder constant"
            );
            let back = adapter.normalize_flags(&pf);
            assert_eq!(back.archived, unified.archived);
            assert_eq!(back.trashed, unified.trashed);
            assert_eq!(back.spam, unified.spam);
        }

        // A message with none of those flags belongs in the inbox.
        let pf = adapter.denormalize_flags(&UnifiedFlags::default(), None);
        assert_eq!(pf.folder.as_deref(), Some(ms_folder::INBOX));
        let back = adapter.normalize_flags(&pf);
        assert!(!back.archived && !back.trashed && !back.spam);
    }

    // ── list_folders ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn list_folders_maps_roles_and_keys() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1.0/me/mailFolders"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "value": [
                    { "id": "AAMk1", "displayName": "Inbox", "totalItemCount": 5 },
                    { "id": "AAMk2", "displayName": "Deleted Items", "totalItemCount": 2 },
                    { "id": "AAMk3", "displayName": "Project X", "totalItemCount": 1 },
                ]
            })))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let folders = adapter.list_folders().await.unwrap();
        assert_eq!(folders.len(), 3);
        let inbox = folders.iter().find(|f| f.role == Some(WellKnownFolder::Inbox)).unwrap();
        assert_eq!(inbox.flags.first().map(String::as_str), Some("AAMk1"));
        assert!(folders.iter().any(|f| f.role == Some(WellKnownFolder::Trash)));
        // Unknown folder → no role, keyed by sanitized id.
        assert!(folders.iter().any(|f| f.role.is_none() && f.provider_name == "Project X"));
    }

    // ── initial_sync ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn initial_sync_paginates_via_nextlink_then_deltalink() {
        let server = MockServer::start().await;
        let delta_link = format!("{}/v1.0/delta-cursor", server.uri());
        let next_link = format!("{}/v1.0/page2", server.uri());

        // Page 1: the start delta query path.
        Mock::given(method("GET"))
            .and(path("/v1.0/me/mailFolders/AAMk-inbox/messages/delta"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "value": [ graph_msg("g1", "<m1@x>", true), graph_msg("g2", "<m2@x>", false) ],
                "@odata.nextLink": next_link,
            })))
            .mount(&server)
            .await;
        // Page 2 (absolute nextLink) → terminal deltaLink.
        Mock::given(method("GET"))
            .and(path("/v1.0/page2"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "value": [ graph_msg("g3", "<m3@x>", true) ],
                "@odata.deltaLink": delta_link,
            })))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let folder = inbox_folder();

        let r1 = adapter.initial_sync(&folder, 100, None).await.unwrap();
        assert_eq!(r1.messages.len(), 2);
        assert!(r1.has_more);
        assert!(r1.next_token.is_none());
        let cont = r1.continuation.clone().unwrap();

        let r2 = adapter.initial_sync(&folder, 100, Some(cont)).await.unwrap();
        assert_eq!(r2.messages.len(), 1);
        assert!(!r2.has_more);
        assert_eq!(r2.next_token.as_deref(), Some(delta_link.as_str()));
        assert_eq!(r2.messages[0].1.provider_id.as_deref(), Some("g3"));
    }

    // ── incremental_sync ─────────────────────────────────────────────────

    #[tokio::test]
    async fn incremental_sync_handles_added_removed_and_new_deltalink() {
        let server = MockServer::start().await;
        let new_delta = format!("{}/v1.0/delta-v2", server.uri());
        Mock::given(method("GET"))
            .and(path("/v1.0/delta-v1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "value": [
                    graph_msg("g10", "<m10@x>", true),
                    { "id": "g11", "@removed": { "reason": "deleted" } },
                ],
                "@odata.deltaLink": new_delta,
            })))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let folder = inbox_folder();
        let cursor = SyncCursor {
            token: Some(format!("{}/v1.0/delta-v1", server.uri())),
            ..Default::default()
        };
        let r = adapter.incremental_sync(&folder, &cursor).await.unwrap();
        assert_eq!(r.messages.len(), 1);
        assert_eq!(r.deletions.len(), 1);
        assert_eq!(r.deletions[0].provider_id.as_deref(), Some("g11"));
        assert_eq!(r.next_token.as_deref(), Some(new_delta.as_str()));
    }

    #[tokio::test]
    async fn incremental_sync_410_is_cursor_expired() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1.0/delta-old"))
            .respond_with(ResponseTemplate::new(410))
            .mount(&server)
            .await;
        let mut adapter = adapter_for(&server);
        let folder = inbox_folder();
        let cursor = SyncCursor {
            token: Some(format!("{}/v1.0/delta-old", server.uri())),
            ..Default::default()
        };
        assert!(matches!(
            adapter.incremental_sync(&folder, &cursor).await.unwrap_err(),
            SyncError::CursorExpired
        ));
    }

    #[tokio::test]
    async fn incremental_sync_no_cursor_is_expired() {
        let server = MockServer::start().await;
        let mut adapter = adapter_for(&server);
        let folder = inbox_folder();
        assert!(matches!(
            adapter.incremental_sync(&folder, &SyncCursor::default()).await.unwrap_err(),
            SyncError::CursorExpired
        ));
    }

    // ── apply_action ─────────────────────────────────────────────────────

    fn action(t: ActionType) -> WritebackAction {
        WritebackAction {
            key: "act".into(),
            account_key: "a".into(),
            action_type: t,
            message_key: "msg".into(),
            folder_key: None,
            provider_snapshot: None,
            status: ActionStatus::Pending,
            retry_count: 0,
            max_retries: 10,
            next_retry_at: None,
            error_message: None,
        }
    }

    fn ms_pid(id: &str) -> ProviderMessageId {
        ProviderMessageId { uid: None, mod_seq: None, provider_id: Some(id.into()) }
    }

    #[tokio::test]
    async fn apply_action_mark_read_patches() {
        let server = MockServer::start().await;
        Mock::given(method("PATCH"))
            .and(path("/v1.0/me/messages/g1"))
            .and(body_partial_json(serde_json::json!({ "isRead": true })))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .expect(1)
            .mount(&server)
            .await;
        let mut adapter = adapter_for(&server);
        adapter.apply_action(&action(ActionType::MarkRead), &ms_pid("g1")).await.unwrap();
    }

    #[tokio::test]
    async fn apply_action_trash_moves_to_deleteditems() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1.0/me/messages/g1/move"))
            .and(body_partial_json(serde_json::json!({ "destinationId": "deleteditems" })))
            .respond_with(ResponseTemplate::new(201).set_body_json(serde_json::json!({})))
            .expect(1)
            .mount(&server)
            .await;
        let mut adapter = adapter_for(&server);
        adapter.apply_action(&action(ActionType::Trash), &ms_pid("g1")).await.unwrap();
    }

    #[tokio::test]
    async fn labels_are_outlook_categories_read_then_written_whole() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1.0/me/messages/g1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "categories": ["Red", "Invoices"] })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/v1.0/me/messages/g1"))
            .and(body_partial_json(serde_json::json!({ "categories": ["Red", "Invoices", "Travel"] })))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/v1.0/me/messages/g1"))
            .and(body_partial_json(serde_json::json!({ "categories": ["Red"] })))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .expect(1)
            .mount(&server)
            .await;
        let mut adapter = adapter_for(&server);
        adapter.apply_action(&action(ActionType::AddLabel { label: "Travel".into() }), &ms_pid("g1")).await.unwrap();
        adapter.apply_action(&action(ActionType::RemoveLabel { label: "invoices".into() }), &ms_pid("g1")).await.unwrap();
    }
}
