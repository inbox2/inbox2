//! Gmail provider adapter — Gmail REST API (not IMAP).
//!
//! Ported from the JS `gmail-sync.js`. The adapter only talks to the Gmail API
//! and returns `UnifiedMessage`s; conversation threading, dedup, and orphan
//! cleanup are owned by `SyncStore`. Folders map from Gmail labels: system
//! labels → well-known roles, user labels → `Other(name)`. The opaque sync
//! cursor is the mailbox `historyId`.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine;
use futures_util::future::try_join_all;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::sync::adapters::util::{
    decode_rfc2047, http_status_error, parse_json_response, sanitize,
};
use crate::sync::mime::is_inline_part;
use crate::sync::util::{header_value, json_array};
use crate::sync::error::{Result, SyncError};
use crate::sync::model::*;
use crate::sync::oauth::TokenManager;
use crate::sync::provider::ProviderAdapter;
use crate::sync::store::SyncStore;

const GMAIL_API: &str = "https://gmail.googleapis.com/gmail/v1";
const USERINFO_URL: &str = "https://www.googleapis.com/oauth2/v3/userinfo";

/// Max concurrent `messages.get` requests during sync. Gmail bills per-message
/// `get` at 5 quota units against a 250 units/user/sec budget, so ~12 in flight
/// stays well under the rate limit while turning a serialized per-message fetch
/// into a near-pipelined one (the single biggest initial-sync speedup).
const FETCH_CONCURRENCY: usize = 12;

/// Minimum wall-clock span per `FETCH_CONCURRENCY`-wide fetch chunk.
///
/// Concurrency alone bounds *in-flight* requests, not *throughput*: once a chunk
/// completes the next launches immediately, so a fast network drives gets far
/// past the per-user budget. A 12-wide chunk spends `12 * 5 = 60` quota units;
/// pacing each chunk to span ≥350ms caps the average draw at ~60 / 0.35 ≈ 170
/// units/sec — under Gmail's 250 units/user/sec limit, with headroom for the
/// concurrent `messages.list` calls. Without this, a large initial backfill
/// (e.g. thousands of Sent messages) bursts past the limit and Gmail returns a
/// 403 `userRateLimitExceeded` mid-sync.
const FETCH_CHUNK_MIN_INTERVAL: Duration = Duration::from_millis(350);

/// Sleep so at least [`FETCH_CHUNK_MIN_INTERVAL`] has elapsed since `started`.
/// Adaptive: a network-bound chunk that already took longer sleeps nothing, so
/// pacing never slows a sync below what the rate limit actually requires.
async fn pace_chunk(started: Instant) {
    if let Some(rem) = FETCH_CHUNK_MIN_INTERVAL.checked_sub(started.elapsed()) {
        tokio::time::sleep(rem).await;
    }
}

/// Synthetic folder-id marker for Gmail's "All Mail". Gmail has no Archive label —
/// archiving just drops `INBOX` and the message lives only in All Mail — so we
/// model All Mail as an `Archive`-role folder whose listing omits `labelIds`.
/// This sentinel sits in `UnifiedFolder.flags[0]` where a real label id normally
/// goes; the sync paths branch on the `Archive` role, never on this string, so it
/// only needs to be a stable, non-colliding folder-key component.
const ALL_MAIL_FOLDER_ID: &str = "__ALL_MAIL__";

/// Gmail system label IDs live in the shared [`crate::sync::adapters::gmail_labels`]
/// module so other adapters (the interactive write-back path) reuse them. Aliased
/// as `label` here to keep the existing `label::UNREAD` call sites terse.
use crate::sync::adapters::gmail_labels as label;

/// Gmail system labels → well-known folder roles. `None` = a category label that
/// is neither a folder nor a flag (skipped).
fn label_role(label_id: &str) -> Option<Option<WellKnownFolder>> {
    match label_id {
        "INBOX" => Some(Some(WellKnownFolder::Inbox)),
        "SENT" => Some(Some(WellKnownFolder::Sent)),
        "DRAFT" => Some(Some(WellKnownFolder::Drafts)),
        "SPAM" => Some(Some(WellKnownFolder::Spam)),
        "TRASH" => Some(Some(WellKnownFolder::Trash)),
        "CATEGORY_PERSONAL" | "CATEGORY_SOCIAL" | "CATEGORY_PROMOTIONS"
        | "CATEGORY_UPDATES" | "CATEGORY_FORUMS" => None, // categories: skip
        _ => Some(None), // user label → no role
    }
}

/// Labels that represent flags, not folders.
fn is_flag_label(label_id: &str) -> bool {
    matches!(label_id, "UNREAD" | "STARRED" | "IMPORTANT")
}

pub struct GmailAdapter {
    capabilities: ProviderCapabilities,
    token: Arc<TokenManager>,
    store: Arc<SyncStore>,
    account_key: String,
    api_base: String,
    userinfo_url: String,
    /// Captured at the start of a full sync; emitted as the new cursor when the
    /// sync completes. Avoids advancing the historyId past unfetched messages.
    pending_history_id: Option<u64>,
    /// Provider ids already held (account-wide for All Mail, this folder
    /// otherwise), cached for the duration of an initial sync. `initial_sync` is called once per page, so without this the
    /// skip-known filter would reload every provider-state row on every page —
    /// O(pages × mailbox) on a deep archive. Populated on the first page, reused
    /// across the rest, cleared when the folder finishes.
    initial_known: Option<std::collections::HashSet<String>>,
}

impl GmailAdapter {
    pub fn new(token: Arc<TokenManager>, store: Arc<SyncStore>, account_key: String) -> Self {
        Self {
            capabilities: ProviderCapabilities {
                push: false, // polling for now; Pub/Sub push deferred
                incremental_sync: true,
                conditional_store: false,
                server_move: false,
                labels: true,
                custom_keywords: false,
                notify: false,
                raw: vec!["gmail-api".to_string()],
            },
            token,
            store,
            account_key,
            api_base: GMAIL_API.to_string(),
            userinfo_url: USERINFO_URL.to_string(),
            pending_history_id: None,
            initial_known: None,
        }
    }

    /// Test helper: point the adapter at a mock server.
    #[cfg(test)]
    pub fn with_bases(mut self, api_base: String, userinfo_url: String) -> Self {
        self.api_base = api_base;
        self.userinfo_url = userinfo_url;
        self
    }

    // ── HTTP helpers ─────────────────────────────────────────────────────

    async fn get_json(&self, url: &str) -> Result<Value> {
        let resp = self.token.request(reqwest::Method::GET, url, None).await?;
        parse_json_response("Gmail", resp, |status, _body| {
            (status == reqwest::StatusCode::NOT_FOUND).then(|| SyncError::Http("404".into()))
        })
        .await
    }

    async fn current_history_id(&self) -> Option<u64> {
        let url = format!("{}/users/me/profile", self.api_base);
        self.get_json(&url)
            .await
            .ok()
            .and_then(|v| v.get("historyId").and_then(parse_u64))
    }

    /// Fetch a message and build a UnifiedMessage. `full` fetches the body;
    /// otherwise only metadata (headers + labels) is fetched.
    async fn fetch_message(&self, id: &str, full: bool) -> Result<(UnifiedMessage, ProviderMessageId)> {
        let format = if full { "full" } else { "metadata" };
        let url = format!("{}/users/me/messages/{id}?format={format}", self.api_base);
        let msg = self.get_json(&url).await?;
        Ok((build_message(&msg, id), ProviderMessageId {
            uid: None,
            mod_seq: None,
            provider_id: Some(id.to_string()),
        }))
    }

    /// Fetch a message for an incremental delta, tolerating a 404. Gmail's
    /// history feed can reference a message that was expunged before we get to
    /// it; a raw 404 here must not abort the whole folder sync, or the cursor
    /// never advances and genuinely-new mail sitting after the tombstone in the
    /// delta never arrives. Treat a vanished message as absent.
    async fn fetch_message_lenient(
        &self,
        id: &str,
        full: bool,
    ) -> Result<Option<(UnifiedMessage, ProviderMessageId)>> {
        match self.fetch_message(id, full).await {
            Ok(m) => Ok(Some(m)),
            Err(SyncError::Http(ref s)) if s.contains("404") => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Incremental catch-up for the synthetic All-Mail folder. Re-walk All Mail
    /// newest-first, fetching only ids we don't already hold, and stop as soon as
    /// a page is entirely known — i.e. we've reached already-synced mail. This
    /// cheaply catches messages auto-archived without ever hitting the inbox
    /// (usually stopping on page 1). Returns no seen-set (partial view → no
    /// orphan-prune) and a fresh historyId token so the folder stays incremental.
    async fn all_mail_incremental(&mut self) -> Result<FolderSyncResult> {
        let known: HashSet<String> = self
            .store
            .known_provider_ids_for_account(&self.account_key)
            .unwrap_or_default()
            .into_iter()
            .collect();

        let mut messages = Vec::new();
        let mut page_token: Option<String> = None;
        // Bound the walk so a pathological mailbox can't page forever; newest mail
        // is at the front, so the loop normally breaks after the first page.
        for _ in 0..20 {
            let mut url = format!("{}/users/me/messages?q=-in:chats&maxResults=100", self.api_base);
            if let Some(ref t) = page_token {
                url.push_str(&format!("&pageToken={t}"));
            }
            let list = self.get_json(&url).await?;
            let ids: Vec<String> = list
                .get("messages")
                .and_then(|m| m.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|m| m.get("id").and_then(|v| v.as_str()).map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            if ids.is_empty() {
                break;
            }
            let fresh: Vec<String> =
                ids.iter().filter(|id| !known.contains(*id)).cloned().collect();
            // A whole page of already-known ids means we've reached synced mail.
            if fresh.is_empty() {
                break;
            }
            for chunk in fresh.chunks(FETCH_CONCURRENCY) {
                let started = Instant::now();
                let fetched =
                    try_join_all(chunk.iter().map(|id| self.fetch_message_lenient(id, true)))
                        .await?;
                messages.extend(fetched.into_iter().flatten());
                pace_chunk(started).await;
            }
            match list.get("nextPageToken").and_then(|v| v.as_str()) {
                Some(t) => page_token = Some(t.to_string()),
                None => break,
            }
        }

        let next_token = self.current_history_id().await.map(|h| h.to_string());
        Ok(FolderSyncResult {
            messages,
            next_token,
            ..Default::default()
        })
    }

    // ── Avatar (best effort) ─────────────────────────────────────────────

    async fn fetch_avatar(&self) {
        let resp = match self.token.request(reqwest::Method::GET, &self.userinfo_url, None).await {
            Ok(r) if r.status().is_success() => r,
            Ok(r) => {
                log::debug!("avatar fetch: userinfo returned {}", r.status());
                return;
            }
            Err(e) => {
                log::debug!("avatar fetch failed: {e}");
                return;
            }
        };
        if let Ok(v) = resp.json::<Value>().await {
            if let Some(pic) = v.get("picture").and_then(|p| p.as_str()) {
                if let Err(e) = self.store.set_account_avatar(&self.account_key, pic) {
                    log::warn!("storing account avatar failed: {e}");
                }
            }
        }
    }
}

#[async_trait]
impl ProviderAdapter for GmailAdapter {
    async fn connect(&mut self, _credentials: &ProviderCredentials) -> Result<ProviderCapabilities> {
        // Validate the token with a lightweight call. Propagate the underlying
        // error verbatim — `get_json` already classifies it (401/403 →
        // `HttpStatus`, refresh failure → `TokenRefresh`, network → `Http`), so
        // the engine can tell a genuinely-expired sign-in (→ NeedsReauth) from a
        // transient blip. Blanket-wrapping every failure as `AuthFailed` here is
        // what made every error look like an expired token to the client.
        let url = format!("{}/users/me/profile", self.api_base);
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
        let url = format!("{}/users/me/labels", self.api_base);
        let data = self.get_json(&url).await?;
        let mut folders = Vec::new();

        for label in json_array(&data, "labels") {
            let label_id = label.get("id").and_then(|v| v.as_str()).unwrap_or_default();
            if label_id.is_empty() || is_flag_label(label_id) {
                continue;
            }
            let role = match label_role(label_id) {
                Some(role) => role,        // system folder (Some) or user label (None)
                None => continue,           // category label: skip
            };
            let label_type = label.get("type").and_then(|v| v.as_str()).unwrap_or("");
            // Keep known system folders and user labels only.
            if role.is_none() && label_type != "user" {
                continue;
            }
            let name = label
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or(label_id)
                .to_string();
            let key = format!(
                "fld_gmail_{}_{}",
                self.account_key,
                sanitize(label_id)
            );
            folders.push(UnifiedFolder {
                key,
                account_key: self.account_key.clone(),
                provider_name: name,
                role,
                separator: None,
                flags: vec![label_id.to_string()], // provider label id
                uid_validity: None,
                highest_mod_seq: 0,
                last_synced_uid: 0,
                sync_cursor: None,
                sync_enabled: true,
            });
        }

        // Synthetic "All Mail" folder so archived mail (which carries no INBOX
        // label and lives in no other synced label) is pulled down and becomes
        // searchable. Role = Archive, which the engine syncs by default; the
        // initial/incremental paths detect that role and list All Mail (no
        // labelIds) instead of a label. `sync_enabled` is (re)decided by the
        // engine from the role, so its value here is just a default.
        folders.push(UnifiedFolder {
            key: format!("fld_gmail_{}_{}", self.account_key, sanitize(ALL_MAIL_FOLDER_ID)),
            account_key: self.account_key.clone(),
            provider_name: "All Mail".to_string(),
            role: Some(WellKnownFolder::Archive),
            separator: None,
            flags: vec![ALL_MAIL_FOLDER_ID.to_string()],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        });

        Ok(folders)
    }

    async fn initial_sync(
        &mut self,
        folder: &UnifiedFolder,
        batch_size: u32,
        continuation: Continuation,
    ) -> Result<FolderSyncResult> {
        let label_id = folder.flags.first().cloned().unwrap_or_default();
        // All Mail (archive) is a synthetic folder: list every message instead of
        // one label. Gmail returns All Mail when no `labelIds` are given (Spam and
        // Trash excluded by default); `-in:chats` drops Google Chat threads.
        let is_all_mail = folder.role == Some(WellKnownFolder::Archive);

        // On the first batch, capture the mailbox historyId so we can resume
        // incrementally from a point that precedes anything synced this run.
        if continuation.is_none() {
            self.pending_history_id = self.current_history_id().await;
        }

        let mut url = if is_all_mail {
            format!(
                "{}/users/me/messages?q=-in:chats&maxResults={}",
                self.api_base, batch_size
            )
        } else {
            format!(
                "{}/users/me/messages?labelIds={}&maxResults={}",
                self.api_base, label_id, batch_size
            )
        };
        if let Some(ref token) = continuation {
            url.push_str(&format!("&pageToken={token}"));
        }
        let list = self.get_json(&url).await?;

        let ids: Vec<String> = list
            .get("messages")
            .and_then(|m| m.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|m| m.get("id").and_then(|v| v.as_str()).map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        let next_page = list
            .get("nextPageToken")
            .and_then(|v| v.as_str())
            .map(String::from);
        // resultSizeEstimate is Gmail's (rough) total for the label — use it as
        // the progress-bar denominator. Only trust the first batch's value.
        let total_estimate = if continuation.is_none() {
            list.get("resultSizeEstimate")
                .and_then(|v| v.as_u64())
                .map(|n| n as u32)
        } else {
            None
        };

        let seen: HashSet<String> = ids.iter().cloned().collect();
        // Fetch only ids we don't already hold. All Mail: anything known in any
        // folder (INBOX/SENT/…), so the archive is a small delta, not a
        // re-download. Other folders: ids already stored in this folder, so an
        // initial sync cut short (Gmail quota, 2026-10-13) resumes instead of
        // re-fetching the same bodies every retry and never finishing.
        // ponytail: known messages keep their stored flags on a re-run; the
        // history cursor picks up changes from here on.
        // `seen` stays the full page so the orphan prune keeps rows still listed.
        // Loaded once on the first page and reused across pages (initial_sync is
        // called per page).
        if continuation.is_none() {
            let known = if is_all_mail {
                self.store.known_provider_ids_for_account(&self.account_key)
            } else {
                self.store
                    .known_provider_ids_for_folder(&self.account_key, &folder.key)
            };
            self.initial_known = Some(known.unwrap_or_default().into_iter().collect());
        }
        let known = self.initial_known.get_or_insert_with(HashSet::new);
        // New rows fetched this page become "known" so a later page (or a
        // sibling already in this page) doesn't re-fetch them.
        let fetch_ids: Vec<String> =
            ids.iter().filter(|id| !known.contains(*id)).cloned().collect();
        for id in &fetch_ids {
            known.insert(id.clone());
        }
        // Fetch the page's message bodies concurrently (in bounded chunks) rather
        // than one blocking round-trip at a time. Order doesn't matter — the store
        // threads/dedups by message-id. The first error aborts the batch (`?`).
        let mut messages = Vec::with_capacity(fetch_ids.len());
        for chunk in fetch_ids.chunks(FETCH_CONCURRENCY) {
            let started = Instant::now();
            let fetched =
                try_join_all(chunk.iter().map(|id| self.fetch_message(id, true))).await?;
            messages.extend(fetched);
            pace_chunk(started).await;
        }

        let has_more = next_page.is_some();
        let next_token = if has_more {
            None
        } else {
            self.pending_history_id.take().map(|h| h.to_string())
        };
        // Free the per-run known-id cache once the folder finishes paging.
        if !has_more {
            self.initial_known = None;
        }

        Ok(FolderSyncResult {
            messages,
            seen_provider_ids: Some(seen),
            continuation: next_page,
            next_token,
            has_more,
            total_estimate,
            ..Default::default()
        })
    }

    async fn start_watching(
        &mut self,
        _folders: &[UnifiedFolder],
        _credentials: &ProviderCredentials,
        _tx: mpsc::UnboundedSender<ProviderEvent>,
    ) -> Result<()> {
        // Push (Cloud Pub/Sub) deferred; polling drives sync.
        Ok(())
    }

    async fn stop_watching(&mut self) -> Result<()> {
        Ok(())
    }

    // ── Cloud push (Pub/Sub) — see docs/Cloud-Push.md ───────────────────────
    // The client owns the token and calls users.watch pointing at a Pub/Sub topic
    // owned by our cloud infra. Google publishes {emailAddress, historyId} to that
    // topic; a Pub/Sub push subscription delivers it to Rails, which fans out a
    // "go sync" signal. The token never leaves the client.

    async fn create_push_subscription(&mut self, config: &PushSubConfig) -> Result<PushSubInfo> {
        let topic = config
            .gmail_topic
            .as_deref()
            .ok_or_else(|| SyncError::Other("push config missing gmail_topic".into()))?;

        let url = format!("{}/users/me/watch", self.api_base);
        let body = serde_json::json!({
            "topicName": topic,
            "labelIds": [label::INBOX],
            "labelFilterBehavior": "include",
        });
        // A mailbox may have only one active Gmail watch. If a stale watch lingers
        // (prior session / different topic), `watch` 400s with "call /stop then try
        // again"; stop it and retry once. One loop keeps a single error/body path.
        let mut stopped_stale = false;
        let data: Value = loop {
            let resp = self
                .token
                .request(reqwest::Method::POST, &url, Some(&body))
                .await?;
            let status = resp.status();
            if status.is_success() {
                break resp.json().await?;
            }
            let b = resp.text().await.unwrap_or_default();
            if status == reqwest::StatusCode::BAD_REQUEST
                && !stopped_stale
                && (b.contains("/stop") || b.contains("Only one user push notification"))
            {
                stopped_stale = true;
                self.delete_push_subscription(&PushSubInfo::default()).await?;
                continue;
            }
            return Err(http_status_error("Gmail watch", status, &b));
        };

        // `expiration` is epoch-millis (string or number); `historyId` is informational.
        let expires_at = data
            .get("expiration")
            .and_then(|v| {
                v.as_str()
                    .and_then(|s| s.parse::<i64>().ok())
                    .or_else(|| v.as_i64())
            })
            .and_then(|ms| chrono::DateTime::<chrono::Utc>::from_timestamp_millis(ms))
            .map(|dt| dt.to_rfc3339());
        let history_id = data
            .get("historyId")
            .map(|v| v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()));

        Ok(PushSubInfo {
            provider_subscription_id: history_id,
            client_state: None,
            expires_at,
        })
    }

    async fn delete_push_subscription(&mut self, _existing: &PushSubInfo) -> Result<()> {
        let url = format!("{}/users/me/stop", self.api_base);
        // Body-less POST; TokenManager sets Content-Length: 0.
        let resp = self
            .token
            .request(reqwest::Method::POST, &url, None)
            .await?;
        let status = resp.status();
        if !status.is_success() && status != reqwest::StatusCode::NOT_FOUND {
            let b = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Gmail stop", status, &b));
        }
        Ok(())
    }

    async fn incremental_sync(
        &mut self,
        folder: &UnifiedFolder,
        cursor: &SyncCursor,
    ) -> Result<FolderSyncResult> {
        // All Mail can't ride the mailbox-global history feed: its sentinel isn't
        // a real label, so the per-folder label partition below would treat every
        // changed message as "left" and delete the folder. Catch up by re-walking
        // All Mail instead.
        if folder.role == Some(WellKnownFolder::Archive) {
            return self.all_mail_incremental().await;
        }

        let start = match cursor.token.as_deref() {
            Some(t) => t.to_string(),
            None => return Err(SyncError::CursorExpired), // no cursor → force full sync
        };

        // history.list is paged, and every page reports the mailbox's *current*
        // historyId. Reading only page 1 and saving that id as the cursor
        // silently dropped every record past the first page: after an overnight
        // sleep, mail that landed in INBOX was never filed there (it only came in
        // later via the All Mail walk, so the inbox never showed it).
        let base_url = format!(
            "{}/users/me/history?startHistoryId={start}&maxResults=500\
             &historyTypes=messageAdded&historyTypes=messageDeleted\
             &historyTypes=labelAdded&historyTypes=labelRemoved",
            self.api_base
        );
        let mut records = Vec::new();
        let next_token;
        let mut page_token: Option<String> = None;
        loop {
            let url = match &page_token {
                Some(t) => format!("{base_url}&pageToken={t}"),
                None => base_url.clone(),
            };
            let data = match self.get_json(&url).await {
                Ok(d) => d,
                // Gmail returns 404 when startHistoryId is too old → full resync.
                Err(SyncError::Http(ref s)) if s.contains("404") => {
                    return Err(SyncError::CursorExpired)
                }
                Err(e) => return Err(e),
            };
            records.extend(json_array(&data, "history"));
            match data.get("nextPageToken").and_then(|v| v.as_str()) {
                Some(t) => page_token = Some(t.to_string()),
                None => {
                    next_token = data.get("historyId").and_then(parse_u64).map(|h| h.to_string());
                    break;
                }
            }
        }

        let mut deletions = Vec::new();
        let mut added_ids = HashSet::new();
        // First pass: collect the messages to (re)fetch with their desired format
        // (`true` = full body for new mail, `false` = metadata-only for flag
        // changes), deduping by message-id. The actual fetches run concurrently
        // below instead of one blocking round-trip at a time.
        let mut fetch_specs: Vec<(String, bool)> = Vec::new();

        for record in &records {
            for added in json_array(&record, "messagesAdded") {
                if let Some(id) = msg_id(&added) {
                    if added_ids.insert(id.clone()) {
                        fetch_specs.push((id, true));
                    }
                }
            }
            for deleted in json_array(&record, "messagesDeleted") {
                if let Some(id) = msg_id(&deleted) {
                    deletions.push(ProviderMessageId {
                        uid: None,
                        mod_seq: None,
                        provider_id: Some(id),
                    });
                }
            }
            // Label changes → re-fetch metadata so flags update via the store.
            for changed in json_array(&record, "labelsAdded")
                .into_iter()
                .chain(json_array(&record, "labelsRemoved"))
            {
                if let Some(id) = msg_id(&changed) {
                    if added_ids.insert(id.clone()) {
                        fetch_specs.push((id, false));
                    }
                }
            }
        }

        let mut messages = Vec::with_capacity(fetch_specs.len());
        for chunk in fetch_specs.chunks(FETCH_CONCURRENCY) {
            let started = Instant::now();
            let fetched = try_join_all(
                chunk
                    .iter()
                    .map(|(id, full)| self.fetch_message_lenient(id, *full)),
            )
            .await?;
            messages.extend(fetched.into_iter().flatten());
            pace_chunk(started).await;
        }

        // Gmail's history feed is mailbox-global, not per-folder: every message
        // added/changed anywhere in the mailbox comes back regardless of which
        // folder is being synced. Without scoping, the engine would write every
        // changed message into *this* folder's provider state (e.g. a new INBOX
        // message landing in Sent, Drafts and Trash too). Partition by the
        // folder's Gmail label: messages carrying it belong here; messages that
        // appear in the feed but lack it have left this folder (archived, moved)
        // and their stale folder row must be removed.
        let label_id = folder.flags.first().cloned().unwrap_or_default();
        let history_records = records.len();
        let fetched = messages.len();
        let (kept, left): (Vec<_>, Vec<_>) = messages
            .into_iter()
            .partition(|(msg, _)| msg.labels.contains(&label_id));
        // Visibility into the global-feed → per-folder partition: if a folder keeps
        // 0 of the fetched messages while the feed had records, that's the signature
        // of a starved folder (e.g. inbox writing nothing while the cursor advances).
        log::info!(
            "[gmail-inc] {}: label='{}' history_records={} fetched={} kept={} left={}",
            folder.provider_name,
            label_id,
            history_records,
            fetched,
            kept.len(),
            left.len()
        );
        for (_, pid) in left {
            if pid.provider_id.is_some() {
                deletions.push(pid);
            }
        }

        Ok(FolderSyncResult {
            messages: kept,
            deletions,
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
            .ok_or_else(|| SyncError::Other("Gmail action: missing message id".into()))?;
        let base = &self.api_base;

        let (url, body): (String, Option<Value>) = match &action.action_type {
            ActionType::MarkRead => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "removeLabelIds": [label::UNREAD] })),
            ),
            ActionType::MarkUnread => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "addLabelIds": [label::UNREAD] })),
            ),
            ActionType::Flag => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "addLabelIds": [label::STARRED] })),
            ),
            ActionType::Unflag => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "removeLabelIds": [label::STARRED] })),
            ),
            ActionType::Archive => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "removeLabelIds": [label::INBOX] })),
            ),
            ActionType::Unarchive => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "addLabelIds": [label::INBOX] })),
            ),
            ActionType::AddLabel { label } => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "addLabelIds": [label] })),
            ),
            ActionType::RemoveLabel { label } => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "removeLabelIds": [label] })),
            ),
            // Gmail has no folders: "move" is Gmail's own Move-to, file under
            // the label and leave the inbox.
            ActionType::Move { target_folder } => (
                format!("{base}/users/me/messages/{id}/modify"),
                Some(serde_json::json!({ "addLabelIds": [target_folder], "removeLabelIds": [label::INBOX] })),
            ),
            ActionType::Trash => (format!("{base}/users/me/messages/{id}/trash"), None),
            ActionType::Delete => {
                let url = format!("{base}/users/me/messages/{id}");
                let resp = self.token.request(reqwest::Method::DELETE, &url, None).await?;
                return check_writeback(resp).await;
            }
            // Spam/quadrant verbs are applied via the InteractiveProvider path
            // (see engine.process_writeback), never routed here.
            ActionType::Interactive { .. } => return Ok(()),
        };

        let resp = self
            .token
            .request(reqwest::Method::POST, &url, body.as_ref())
            .await?;
        check_writeback(resp).await
    }

    fn normalize_flags(&self, provider_flags: &ProviderFlags) -> UnifiedFlags {
        let has = |l: &str| provider_flags.gmail_labels.iter().any(|gl| gl == l);
        let mut f = UnifiedFlags::default();
        f.read = !has(label::UNREAD);
        f.flagged = has(label::STARRED);
        f.trashed = has(label::TRASH);
        f.spam = has(label::SPAM);
        f.draft = has(label::DRAFT);
        f.archived = !has(label::INBOX) && !f.trashed && !f.spam;
        f
    }

    fn denormalize_flags(&self, unified: &UnifiedFlags, _folder: Option<&str>) -> ProviderFlags {
        let mut labels = Vec::new();
        if !unified.read {
            labels.push(label::UNREAD.to_string());
        }
        if unified.flagged {
            labels.push(label::STARRED.to_string());
        }
        if unified.trashed {
            labels.push(label::TRASH.to_string());
        }
        if unified.spam {
            labels.push(label::SPAM.to_string());
        }
        if unified.draft {
            labels.push(label::DRAFT.to_string());
        }
        if !unified.archived && !unified.trashed && !unified.spam {
            labels.push(label::INBOX.to_string());
        }
        ProviderFlags {
            gmail_labels: labels,
            ..Default::default()
        }
    }
}

// ── Free helpers ─────────────────────────────────────────────────────────

async fn check_writeback(resp: reqwest::Response) -> Result<()> {
    let status = resp.status();
    if status.is_success() || status == reqwest::StatusCode::NOT_FOUND {
        // Success, or the message is gone on the server — treat as already applied.
        Ok(())
    } else {
        // Carry the status code so the drain can tell a dead-token 401/403 (→
        // flag NeedsReauth) and a permanent 4xx (→ give up) apart from a
        // transient 5xx/429 (→ retry), instead of burning the retry schedule on
        // an opaque error.
        let body = resp.text().await.unwrap_or_default();
        Err(http_status_error("Gmail writeback", status, &body))
    }
}

fn msg_id(record: &Value) -> Option<String> {
    record
        .get("message")
        .and_then(|m| m.get("id"))
        .and_then(|v| v.as_str())
        .map(String::from)
}

fn parse_u64(v: &Value) -> Option<u64> {
    match v {
        Value::String(s) => s.parse().ok(),
        Value::Number(n) => n.as_u64(),
        _ => None,
    }
}

/// Decode Gmail's base64url body (padding optional) to a UTF-8 string.
pub(crate) fn decode_base64url(data: &str) -> Option<String> {
    decode_base64url_charset(data, None)
}

/// Decode Gmail's base64url body honoring the part's declared charset. Gmail
/// returns the part bytes in their ORIGINAL charset — an iso-8859-1 "café"
/// would turn into replacement-char soup if force-read as UTF-8.
///
/// Valid UTF-8 always wins, regardless of the declared charset: senders
/// routinely mislabel a UTF-8 body as `iso-8859-1`, and decoding by that label
/// would turn a UTF-8 "ë" (`0xC3 0xAB`) into "Ã«" — mojibake in the list preview
/// and notification body. Only when the bytes are not valid UTF-8 do we honour
/// the declared charset (the genuine-latin1 case), falling back to lossy UTF-8.
pub(crate) fn decode_base64url_charset(data: &str, charset_label: Option<&str>) -> Option<String> {
    let cleaned: String = data.chars().filter(|c| !c.is_whitespace() && *c != '=').collect();
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(cleaned).ok()?;
    if let Ok(s) = std::str::from_utf8(&bytes) {
        return Some(s.to_string());
    }
    if let Some(label) = charset_label {
        if !label.eq_ignore_ascii_case("utf-8") && !label.eq_ignore_ascii_case("us-ascii") {
            if let Some(cs) = charset::Charset::for_label(label.as_bytes()) {
                return Some(cs.decode(&bytes).0.into_owned());
            }
        }
    }
    Some(String::from_utf8_lossy(&bytes).to_string())
}

/// Pull `charset=` out of a Gmail part's Content-Type header (the JSON
/// `headers` array on the part).
fn part_charset(payload: &Value) -> Option<String> {
    let headers = payload.get("headers").and_then(|h| h.as_array())?;
    let ctype = headers.iter().find_map(|h| {
        let name = h.get("name").and_then(|n| n.as_str())?;
        if name.eq_ignore_ascii_case("content-type") {
            h.get("value").and_then(|v| v.as_str())
        } else {
            None
        }
    })?;
    ctype.split(';').skip(1).find_map(|param| {
        let (k, v) = param.split_once('=')?;
        if k.trim().eq_ignore_ascii_case("charset") {
            Some(v.trim().trim_matches('"').to_string())
        } else {
            None
        }
    })
}

/// Recursively extract plain + html bodies from a Gmail payload.
pub(crate) fn extract_body(payload: &Value) -> (Option<String>, Option<String>) {
    let mut plain = None;
    let mut html = None;

    let mime = payload.get("mimeType").and_then(|v| v.as_str()).unwrap_or("");
    if let Some(data) = payload.get("body").and_then(|b| b.get("data")).and_then(|d| d.as_str()) {
        if let Some(decoded) = decode_base64url_charset(data, part_charset(payload).as_deref()) {
            if mime == "text/html" {
                html = Some(decoded);
            } else {
                plain = Some(decoded);
            }
        }
    }

    if let Some(parts) = payload.get("parts").and_then(|p| p.as_array()) {
        for part in parts {
            let pmime = part.get("mimeType").and_then(|v| v.as_str()).unwrap_or("");
            let pdata = part.get("body").and_then(|b| b.get("data")).and_then(|d| d.as_str());
            if pmime == "text/plain" && plain.is_none() {
                if let Some(d) = pdata {
                    plain = decode_base64url_charset(d, part_charset(part).as_deref());
                }
            }
            if pmime == "text/html" && html.is_none() {
                if let Some(d) = pdata {
                    html = decode_base64url_charset(d, part_charset(part).as_deref());
                }
            }
            if part.get("parts").is_some() {
                let (np, nh) = extract_body(part);
                if plain.is_none() {
                    plain = np;
                }
                if html.is_none() {
                    html = nh;
                }
            }
        }
    }
    (plain, html)
}

/// Whether a Gmail JSON part is shown inside the HTML body (see [`is_inline_part`]).
pub(crate) fn part_is_inline(part: &Value, html: Option<&str>) -> bool {
    let headers = part.get("headers");
    let cid = header_value(headers, "content-id").map(|v| v.trim().trim_matches(|c| c == '<' || c == '>').to_string());
    let attachment = header_value(headers, "content-disposition")
        .map(|d| d.trim_start().to_ascii_lowercase().starts_with("attachment"))
        .unwrap_or(false);
    is_inline_part(attachment, cid.as_deref().filter(|c| !c.is_empty()), html)
}

/// Every real (non-inline) attachment part in a Gmail payload: named, or carrying an
/// `attachmentId`. Checked against the payload's own HTML body.
fn real_attachments(payload: &Value) -> Vec<&Value> {
    fn walk<'a>(p: &'a Value, html: Option<&str>, out: &mut Vec<&'a Value>) {
        let named = p.get("filename").and_then(|v| v.as_str()).map(|f| !f.is_empty()).unwrap_or(false);
        let stored = p.get("body").and_then(|b| b.get("attachmentId")).is_some();
        if (named || stored) && !part_is_inline(p, html) {
            out.push(p);
        }
        for part in p.get("parts").and_then(|v| v.as_array()).into_iter().flatten() {
            walk(part, html, out);
        }
    }
    let (_, html) = extract_body(payload);
    let mut out = Vec::new();
    walk(payload, html.as_deref(), &mut out);
    out
}

fn has_attachment(payload: &Value) -> bool {
    !real_attachments(payload).is_empty()
}

/// Filenames of the real attachments, folded into the search index at sync time (Gmail is the
/// one provider that carries filenames in the list payload, so the rest backfill on open).
fn attachment_filenames(payload: &Value) -> Vec<String> {
    real_attachments(payload)
        .into_iter()
        .filter_map(|p| p.get("filename").and_then(|v| v.as_str()).filter(|f| !f.is_empty()).map(String::from))
        .collect()
}

/// Bytes of the largest named real attachment; backs the `larger:`/`smaller:` search filters.
fn attachment_max_size(payload: &Value) -> Option<i64> {
    real_attachments(payload)
        .into_iter()
        .filter(|p| p.get("filename").and_then(|v| v.as_str()).map(|f| !f.is_empty()).unwrap_or(false))
        .filter_map(|p| p.get("body").and_then(|b| b.get("size")).and_then(|s| s.as_i64()))
        .max()
}

/// Build a UnifiedMessage from a Gmail messages.get response.
fn build_message(msg: &Value, gmail_id: &str) -> UnifiedMessage {
    let payload = msg.get("payload").cloned().unwrap_or(Value::Null);

    // Header lookup (case-insensitive).
    let header = |name: &str| header_value(payload.get("headers"), name);

    let message_id = header("message-id")
        .unwrap_or_else(|| format!("<gmail-{gmail_id}@gmail.com>"));
    // Subjects and display names arrive as raw header strings from the Gmail API
    // with no MIME decoding, so RFC 2047 encoded-words must be decoded here or
    // they'd be stored as mojibake.
    let subject = header("subject").map(|s| decode_rfc2047(&s));
    let from = header("from").map(|s| decode_rfc2047(&s)).unwrap_or_default();
    let to = header("to").map(|s| decode_rfc2047(&s));
    let cc = header("cc").map(|s| decode_rfc2047(&s));
    let in_reply_to = header("in-reply-to");
    let references = header("references");
    let date = header("date").and_then(|d| {
        chrono::DateTime::parse_from_rfc2822(&d)
            .ok()
            .map(|dt| dt.with_timezone(&chrono::Utc))
    });
    // Gmail's own receipt timestamp (epoch milliseconds, as a string). Used as
    // the fallback when the RFC 2822 Date header is missing or unparseable, so
    // old mail isn't re-dated to the sync wall-clock. See upsert_synced_message.
    let internal_date = msg
        .get("internalDate")
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse::<i64>().ok())
        .and_then(chrono::DateTime::from_timestamp_millis);

    let labels: HashSet<String> = msg
        .get("labelIds")
        .and_then(|l| l.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    let flags = UnifiedFlags {
        read: !labels.contains(label::UNREAD),
        flagged: labels.contains(label::STARRED),
        trashed: labels.contains(label::TRASH),
        spam: labels.contains(label::SPAM),
        draft: labels.contains(label::DRAFT),
        archived: !labels.contains(label::INBOX)
            && !labels.contains(label::TRASH)
            && !labels.contains(label::SPAM),
    };

    let (plain, html) = if payload.is_null() {
        (None, None)
    } else {
        extract_body(&payload)
    };
    let attachment = if payload.is_null() { false } else { has_attachment(&payload) };
    let attachment_names = if payload.is_null() {
        None
    } else {
        let names = attachment_filenames(&payload);
        (!names.is_empty()).then(|| names.join(" "))
    };
    let max_size = if payload.is_null() { None } else { attachment_max_size(&payload) };

    UnifiedMessage {
        key: String::new(),
        message_id,
        subject,
        from_address: from,
        to_address: to,
        cc_address: cc,
        in_reply_to,
        references_header: references,
        body_plain: plain,
        body_html: html,
        has_attachment: attachment,
        attachment_names,
        attachment_max_size: max_size,
        is_inbound: true,
        flags,
        labels,
        folders: HashSet::new(),
        date,
        internal_date,
        provider_thread_id: msg.get("threadId").and_then(|v| v.as_str()).map(String::from),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::RwLock;
    use wiremock::matchers::{body_partial_json, method, path, query_param, query_param_is_missing};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn b64url(s: &str) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(s)
    }

    /// The `larger:`/`smaller:` filters read one number per message, so the walk
    /// has to pick the biggest REAL attachment — inline images (Content-ID) are
    /// part of the body, not files someone attached.
    #[test]
    fn attachment_max_size_takes_the_largest_non_inline_part() {
        let payload = serde_json::json!({
            "parts": [
                { "filename": "", "body": { "size": 400 } },
                { "filename": "small.pdf", "body": { "size": 1_000 } },
                { "filename": "big.zip", "body": { "size": 9_000_000 } },
                {
                    "filename": "logo.png",
                    "headers": [{ "name": "Content-ID", "value": "<logo>" }],
                    "body": { "size": 50_000_000 }
                }
            ]
        });
        assert_eq!(attachment_max_size(&payload), Some(9_000_000));
        assert_eq!(
            attachment_filenames(&payload),
            vec!["small.pdf".to_string(), "big.zip".to_string()]
        );
    }

/// Gmail sends every attachment with a Content-ID (next to X-Attachment-Id). Images attached
    /// that way, or kept by a forward whose HTML no longer shows them, are attachments.
    #[test]
    fn gmail_image_attachments_with_content_id_are_listed() {
        let png = |name: &str, disposition: Option<&str>| {
            let mut headers = vec![serde_json::json!({ "name": "Content-ID", "value": format!("<f_{name}>") })];
            if let Some(d) = disposition {
                headers.push(serde_json::json!({ "name": "Content-Disposition", "value": d }));
            }
            serde_json::json!({ "mimeType": "image/png", "filename": name, "headers": headers,
                                "body": { "attachmentId": format!("att-{name}"), "size": 10 } })
        };
        let payload = serde_json::json!({
            "mimeType": "multipart/mixed",
            "parts": [
                { "mimeType": "text/html", "body": { "data": b64url("<p>Fwd</p><img src=\"cid:f_shown.png\">") } },
                png("logo.png", Some("attachment; filename=\"logo.png\"")),
                png("kept.png", None),
                png("shown.png", Some("inline"))
            ]
        });
        assert_eq!(attachment_filenames(&payload), vec!["logo.png".to_string(), "kept.png".to_string()]);
        assert!(has_attachment(&payload));
    }

    #[test]
    fn attachment_max_size_is_none_without_attachments() {
        let payload = serde_json::json!({ "parts": [{ "filename": "", "body": { "size": 12 } }] });
        assert_eq!(attachment_max_size(&payload), None);
    }

    fn adapter_for(server: &MockServer) -> GmailAdapter {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let account_key = store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: "G".into(),
                email_address: "u@gmail.com".into(),
                provider_type: ProviderType::Gmail,
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
            username: "u@gmail.com".into(),
            access_token: "tok".into(),
            refresh_token: Some("r".into()),
        };
        let token = Arc::new(TokenManager::new(
            account_key.clone(),
            ProviderType::Gmail,
            store.clone(),
            Arc::new(RwLock::new(None)),
            &creds,
        ));
        GmailAdapter::new(token, store, account_key).with_bases(
            format!("{}/gmail/v1", server.uri()),
            format!("{}/userinfo", server.uri()),
        )
    }

    // ── Cloud push ───────────────────────────────────────────────────────

    #[tokio::test]
    async fn create_push_subscription_calls_watch_and_parses_expiry() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/gmail/v1/users/me/watch"))
            .and(body_partial_json(serde_json::json!({
                "topicName": "projects/p/topics/t",
                "labelIds": ["INBOX"],
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                // 2026-06-05T00:00:00Z in epoch millis.
                "historyId": "9876",
                "expiration": "1780617600000"
            })))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let config = PushSubConfig {
            push_enabled: true,
            gmail_topic: Some("projects/p/topics/t".into()),
            microsoft_notification_url: None,
        };
        let info = adapter.create_push_subscription(&config).await.unwrap();
        assert_eq!(info.provider_subscription_id.as_deref(), Some("9876"));
        assert!(info.client_state.is_none());
        assert!(info.expires_at.unwrap().starts_with("2026-")); // RFC3339
    }

    #[tokio::test]
    async fn create_push_subscription_stops_stale_watch_then_retries() {
        let server = MockServer::start().await;
        // First watch attempt: Gmail rejects because a watch already exists.
        Mock::given(method("POST"))
            .and(path("/gmail/v1/users/me/watch"))
            .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                "error": { "code": 400,
                    "message": "Only one user push notification client allowed per developer (call /stop then try again)" }
            })))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        // /stop succeeds, then the retried watch succeeds.
        Mock::given(method("POST"))
            .and(path("/gmail/v1/users/me/stop"))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/gmail/v1/users/me/watch"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "historyId": "9876", "expiration": "1780617600000"
            })))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let config = PushSubConfig {
            push_enabled: true,
            gmail_topic: Some("projects/p/topics/t".into()),
            microsoft_notification_url: None,
        };
        let info = adapter.create_push_subscription(&config).await.unwrap();
        assert_eq!(info.provider_subscription_id.as_deref(), Some("9876"));
    }

    #[tokio::test]
    async fn create_push_subscription_errors_without_topic() {
        let server = MockServer::start().await;
        let mut adapter = adapter_for(&server);
        let config = PushSubConfig { push_enabled: true, ..Default::default() };
        assert!(adapter.create_push_subscription(&config).await.is_err());
    }

    // ── Pure helpers ─────────────────────────────────────────────────────

    #[test]
    fn decode_base64url_handles_unpadded() {
        assert_eq!(decode_base64url("SGVsbG8").as_deref(), Some("Hello"));
        assert_eq!(decode_base64url(&b64url("hi there")).as_deref(), Some("hi there"));
    }

    #[test]
    fn decode_base64url_honors_declared_charset() {
        // "café" in iso-8859-1: é is the single byte 0xE9 (invalid as UTF-8).
        let latin1 = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b"caf\xe9");
        assert_eq!(decode_base64url_charset(&latin1, Some("ISO-8859-1")).as_deref(), Some("café"));
        // Without the charset it degrades to a replacement char, never panics.
        assert_eq!(decode_base64url_charset(&latin1, None).as_deref(), Some("caf\u{FFFD}"));
        // UTF-8 input with a UTF-8 (or absent) label passes through.
        assert_eq!(decode_base64url_charset(&b64url("café"), Some("utf-8")).as_deref(), Some("café"));
        // Sender bug: a UTF-8 body ("cliënt", ë = 0xC3 0xAB) mislabelled
        // iso-8859-1. Decoding by the label would yield "cliÃ«nt"; valid UTF-8
        // wins and recovers the original.
        assert_eq!(
            decode_base64url_charset(&b64url("Geachte cliënt"), Some("ISO-8859-1")).as_deref(),
            Some("Geachte cliënt")
        );
    }

    #[test]
    fn extract_body_decodes_part_charset() {
        let latin1 = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b"caf\xe9");
        let payload = serde_json::json!({
            "mimeType": "multipart/alternative",
            "parts": [
                {
                    "mimeType": "text/plain",
                    "headers": [
                        { "name": "Content-Type", "value": "text/plain; charset=\"ISO-8859-1\"" }
                    ],
                    "body": { "data": latin1 }
                },
            ]
        });
        let (plain, _) = extract_body(&payload);
        assert_eq!(plain.as_deref(), Some("café"));
    }

    #[test]
    fn extract_body_prefers_plain_and_html_parts() {
        let payload = serde_json::json!({
            "mimeType": "multipart/alternative",
            "parts": [
                { "mimeType": "text/plain", "body": { "data": b64url("plain body") } },
                { "mimeType": "text/html", "body": { "data": b64url("<p>html body</p>") } },
            ]
        });
        let (plain, html) = extract_body(&payload);
        assert_eq!(plain.as_deref(), Some("plain body"));
        assert_eq!(html.as_deref(), Some("<p>html body</p>"));
    }

    #[test]
    fn build_message_maps_headers_and_flags() {
        let msg = serde_json::json!({
            "id": "g1",
            "labelIds": ["INBOX", "UNREAD", "STARRED"],
            "payload": {
                "mimeType": "text/plain",
                "headers": [
                    { "name": "Message-ID", "value": "<m1@x>" },
                    { "name": "Subject", "value": "Hello" },
                    { "name": "From", "value": "a@b.com" },
                    { "name": "In-Reply-To", "value": "<m0@x>" },
                ],
                "body": { "data": b64url("the body") }
            }
        });
        let m = build_message(&msg, "g1");
        assert_eq!(m.message_id, "<m1@x>");
        assert_eq!(m.subject.as_deref(), Some("Hello"));
        assert_eq!(m.from_address, "a@b.com");
        assert_eq!(m.in_reply_to.as_deref(), Some("<m0@x>"));
        assert_eq!(m.body_plain.as_deref(), Some("the body"));
        assert!(!m.flags.read); // UNREAD present
        assert!(m.flags.flagged); // STARRED
        assert!(!m.flags.archived); // INBOX present
    }

    #[test]
    fn build_message_archived_when_no_inbox_label() {
        let msg = serde_json::json!({ "id": "g2", "labelIds": [], "payload": { "headers": [] } });
        let m = build_message(&msg, "g2");
        assert!(m.flags.archived);
        assert!(m.flags.read);
    }

    #[test]
    fn build_message_decodes_rfc2047_encoded_headers() {
        // Gmail returns raw header strings with no MIME decoding; encoded-words
        // in Subject / display names must be decoded, not stored as mojibake.
        let msg = serde_json::json!({
            "id": "g3",
            "labelIds": ["INBOX"],
            "payload": {
                "headers": [
                    { "name": "Message-ID", "value": "<m3@x>" },
                    { "name": "Subject", "value": "=?UTF-8?B?SGVsbG8gd29ybGQ=?=" },
                    { "name": "From", "value": "=?UTF-8?Q?Jos=C3=A9?= <jose@x.com>" },
                ]
            }
        });
        let m = build_message(&msg, "g3");
        assert_eq!(m.subject.as_deref(), Some("Hello world"));
        assert_eq!(m.from_address, "José <jose@x.com>");
    }

    #[tokio::test]
    async fn flag_roundtrip() {
        let server = MockServer::start().await;
        let adapter = adapter_for(&server);

        let unified = UnifiedFlags { read: false, flagged: true, ..Default::default() };
        let pf = adapter.denormalize_flags(&unified, None);
        assert!(pf.gmail_labels.contains(&"UNREAD".to_string()));
        assert!(pf.gmail_labels.contains(&"STARRED".to_string()));
        assert!(pf.gmail_labels.contains(&"INBOX".to_string()));

        let back = adapter.normalize_flags(&pf);
        assert!(!back.read);
        assert!(back.flagged);
        assert!(!back.archived);
    }

    #[test]
    fn capabilities_are_label_based_poll() {
        // Build without a server (capabilities don't touch the network).
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let acct = store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: "G".into(),
                email_address: "u@gmail.com".into(),
                provider_type: ProviderType::Gmail,
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
            username: "u@gmail.com".into(),
            access_token: "t".into(),
            refresh_token: None,
        };
        let token = Arc::new(TokenManager::new(
            acct.clone(),
            ProviderType::Gmail,
            store.clone(),
            Arc::new(RwLock::new(None)),
            &creds,
        ));
        let adapter = GmailAdapter::new(token, store, acct);
        let caps = adapter.capabilities();
        assert!(caps.labels);
        assert!(caps.incremental_sync);
        assert!(!caps.push); // push deferred — poll instead
    }

    // ── list_folders ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn list_folders_maps_roles_and_filters_flags_and_categories() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/labels"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "labels": [
                    { "id": "INBOX", "name": "INBOX", "type": "system" },
                    { "id": "SENT", "name": "SENT", "type": "system" },
                    { "id": "UNREAD", "name": "UNREAD", "type": "system" },
                    { "id": "STARRED", "name": "STARRED", "type": "system" },
                    { "id": "CATEGORY_PROMOTIONS", "name": "Promotions", "type": "system" },
                    { "id": "Label_42", "name": "Work", "type": "user" },
                ]
            })))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let folders = adapter.list_folders().await.unwrap();

        let roles: Vec<_> = folders.iter().map(|f| (f.provider_name.clone(), f.role.clone())).collect();
        // INBOX, SENT, and the user label survive; UNREAD/STARRED/CATEGORY_* filtered.
        // Plus the synthetic "All Mail" (Archive) folder appended unconditionally.
        assert_eq!(folders.len(), 4);
        assert!(roles.contains(&("INBOX".into(), Some(WellKnownFolder::Inbox))));
        assert!(roles.contains(&("SENT".into(), Some(WellKnownFolder::Sent))));
        assert!(roles.contains(&("Work".into(), None)));
        assert!(roles.contains(&("All Mail".into(), Some(WellKnownFolder::Archive))));
        // Label id stored in flags for later API calls.
        let inbox = folders.iter().find(|f| f.role == Some(WellKnownFolder::Inbox)).unwrap();
        assert_eq!(inbox.flags.first().map(String::as_str), Some("INBOX"));
    }

    // ── initial_sync ─────────────────────────────────────────────────────

    fn full_message_json(id: &str, message_id: &str, labels: &[&str]) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "historyId": "4000",
            "labelIds": labels,
            "payload": {
                "mimeType": "text/plain",
                "headers": [
                    { "name": "Message-ID", "value": message_id },
                    { "name": "Subject", "value": format!("subject {id}") },
                    { "name": "From", "value": "a@b.com" },
                ],
                "body": { "data": b64url("body") }
            }
        })
    }

    async fn mock_full_message(server: &MockServer, id: &str, message_id: &str, labels: &[&str]) {
        Mock::given(method("GET"))
            .and(path(format!("/gmail/v1/users/me/messages/{id}")))
            .and(query_param("format", "full"))
            .respond_with(ResponseTemplate::new(200).set_body_json(full_message_json(id, message_id, labels)))
            .mount(server)
            .await;
    }

    #[tokio::test]
    async fn initial_sync_paginates_and_sets_cursor_from_profile() {
        let server = MockServer::start().await;
        let inbox = UnifiedFolder {
            key: "fld_gmail_a_inbox".into(),
            account_key: "a".into(),
            provider_name: "INBOX".into(),
            role: Some(WellKnownFolder::Inbox),
            separator: None,
            flags: vec!["INBOX".into()],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        };

        // Profile (for the cursor).
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/profile"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "historyId": "9999" })))
            .mount(&server)
            .await;
        // Page 1 (no pageToken) → two ids + nextPageToken.
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/messages"))
            .and(query_param_is_missing("pageToken"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "messages": [ { "id": "g1" }, { "id": "g2" } ],
                "nextPageToken": "p2"
            })))
            .mount(&server)
            .await;
        // Page 2 (pageToken=p2) → one id, no next page.
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/messages"))
            .and(query_param("pageToken", "p2"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "messages": [ { "id": "g3" } ]
            })))
            .mount(&server)
            .await;
        mock_full_message(&server, "g1", "<m1@x>", &["INBOX", "UNREAD"]).await;
        mock_full_message(&server, "g2", "<m2@x>", &["INBOX"]).await;
        mock_full_message(&server, "g3", "<m3@x>", &["INBOX"]).await;

        let mut adapter = adapter_for(&server);

        // First batch.
        let r1 = adapter.initial_sync(&inbox, 500, None).await.unwrap();
        assert_eq!(r1.messages.len(), 2);
        assert!(r1.has_more);
        assert_eq!(r1.continuation.as_deref(), Some("p2"));
        assert!(r1.next_token.is_none()); // not yet — more pages
        assert_eq!(r1.seen_provider_ids.as_ref().unwrap().len(), 2);

        // Second (final) batch.
        let r2 = adapter.initial_sync(&inbox, 500, r1.continuation).await.unwrap();
        assert_eq!(r2.messages.len(), 1);
        assert!(!r2.has_more);
        assert_eq!(r2.next_token.as_deref(), Some("9999")); // cursor from profile
        assert!(!r2.messages[0].0.flags.read || r2.messages[0].0.flags.read); // sanity
        assert_eq!(r2.messages[0].1.provider_id.as_deref(), Some("g3"));
    }

    #[tokio::test]
    async fn initial_sync_all_mail_lists_without_labels() {
        let server = MockServer::start().await;
        let all_mail = UnifiedFolder {
            key: "fld_gmail_a_all".into(),
            account_key: "a".into(),
            provider_name: "All Mail".into(),
            role: Some(WellKnownFolder::Archive),
            separator: None,
            flags: vec![ALL_MAIL_FOLDER_ID.into()],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        };
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/profile"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "historyId": "9999" })))
            .mount(&server)
            .await;
        // All Mail lists with NO labelIds (Gmail then returns the whole mailbox
        // minus Spam/Trash); the per-label folders never match this mock.
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/messages"))
            .and(query_param_is_missing("labelIds"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "messages": [ { "id": "g1" }, { "id": "g2" } ]
            })))
            .mount(&server)
            .await;
        // g2 has no labels at all — i.e. archived (no INBOX) — which only the
        // All-Mail listing surfaces.
        mock_full_message(&server, "g1", "<a1@x>", &["SENT"]).await;
        mock_full_message(&server, "g2", "<a2@x>", &[]).await;

        let mut adapter = adapter_for(&server);
        let r = adapter.initial_sync(&all_mail, 500, None).await.unwrap();
        // Fresh store → no known ids → both fetched; cursor comes from the profile.
        assert_eq!(r.messages.len(), 2);
        assert_eq!(r.seen_provider_ids.as_ref().unwrap().len(), 2);
        assert!(!r.has_more);
        assert_eq!(r.next_token.as_deref(), Some("9999"));
    }

    #[tokio::test]
    async fn initial_sync_rerun_skips_ids_already_in_the_folder() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/profile"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "historyId": "9999" })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/messages"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "messages": [ { "id": "g1" }, { "id": "g2" } ]
            })))
            .mount(&server)
            .await;
        mock_full_message(&server, "g1", "<s1@x>", &["SENT"]).await;
        mock_full_message(&server, "g2", "<s2@x>", &["SENT"]).await;

        let mut adapter = adapter_for(&server);
        let sent = UnifiedFolder {
            key: format!("fld_gmail_{}_sent", adapter.account_key),
            account_key: adapter.account_key.clone(),
            provider_name: "SENT".into(),
            role: Some(WellKnownFolder::Sent),
            separator: None,
            flags: vec!["SENT".into()],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        };
        adapter.store.upsert_folder(&sent).unwrap();
        let r = adapter.initial_sync(&sent, 500, None).await.unwrap();
        assert_eq!(r.messages.len(), 2);
        for (m, pid) in &r.messages {
            adapter.store.upsert_synced_message(&sent.account_key, &sent.key, m, pid).unwrap();
        }
        // A re-run (the first was cut short before its cursor was saved) lists
        // the same ids but fetches no bodies; the prune still sees both.
        let r = adapter.initial_sync(&sent, 500, None).await.unwrap();
        assert_eq!(r.messages.len(), 0);
        assert_eq!(r.seen_provider_ids.as_ref().unwrap().len(), 2);
    }

    // ── incremental_sync ─────────────────────────────────────────────────

    fn folder_with_cursor(token: &str) -> (UnifiedFolder, SyncCursor) {
        let folder = UnifiedFolder {
            key: "fld_gmail_a_inbox".into(),
            account_key: "a".into(),
            provider_name: "INBOX".into(),
            role: Some(WellKnownFolder::Inbox),
            separator: None,
            flags: vec!["INBOX".into()],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: Some(token.into()),
            sync_enabled: true,
        };
        let cursor = SyncCursor { token: Some(token.into()), ..Default::default() };
        (folder, cursor)
    }

    #[tokio::test]
    async fn incremental_sync_processes_added_deleted_and_label_changes() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/history"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "history": [
                    { "messagesAdded": [ { "message": { "id": "g10" } } ] },
                    { "messagesDeleted": [ { "message": { "id": "g11" } } ] },
                    { "labelsRemoved": [ { "message": { "id": "g12" } } ] },
                ],
                "historyId": "5005"
            })))
            .mount(&server)
            .await;
        mock_full_message(&server, "g10", "<m10@x>", &["INBOX", "UNREAD"]).await;
        // label-changed message fetched as metadata (format=metadata).
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/messages/g12"))
            .and(query_param("format", "metadata"))
            .respond_with(ResponseTemplate::new(200).set_body_json(full_message_json("g12", "<m12@x>", &["INBOX"])))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let (folder, cursor) = folder_with_cursor("5000");
        let r = adapter.incremental_sync(&folder, &cursor).await.unwrap();

        // g10 (added) + g12 (label change) = 2 messages; g11 deleted.
        assert_eq!(r.messages.len(), 2);
        assert_eq!(r.deletions.len(), 1);
        assert_eq!(r.deletions[0].provider_id.as_deref(), Some("g11"));
        assert_eq!(r.next_token.as_deref(), Some("5005"));
    }

    #[tokio::test]
    async fn incremental_sync_scopes_global_history_to_folder() {
        // Gmail's history feed is mailbox-global. When syncing the Sent folder, a
        // newly-added INBOX-only message must NOT be returned as belonging to Sent
        // (otherwise it gets written into Sent's provider state); instead it is
        // routed to deletions so any stale Sent row is removed.
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/history"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "history": [
                    { "messagesAdded": [ { "message": { "id": "g20" } } ] },
                ],
                "historyId": "6006"
            })))
            .mount(&server)
            .await;
        mock_full_message(&server, "g20", "<m20@x>", &["INBOX", "UNREAD"]).await;

        let mut adapter = adapter_for(&server);
        let sent = UnifiedFolder {
            key: "fld_gmail_a_sent".into(),
            account_key: "a".into(),
            provider_name: "SENT".into(),
            role: Some(WellKnownFolder::Sent),
            separator: None,
            flags: vec!["SENT".into()],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: Some("6000".into()),
            sync_enabled: true,
        };
        let cursor = SyncCursor { token: Some("6000".into()), ..Default::default() };
        let r = adapter.incremental_sync(&sent, &cursor).await.unwrap();

        assert_eq!(r.messages.len(), 0, "INBOX-only message must not land in Sent");
        assert_eq!(r.deletions.len(), 1);
        assert_eq!(r.deletions[0].provider_id.as_deref(), Some("g20"));
    }

    #[tokio::test]
    async fn incremental_sync_404_signals_cursor_expired() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/history"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        let (folder, cursor) = folder_with_cursor("1");
        let err = adapter.incremental_sync(&folder, &cursor).await.unwrap_err();
        assert!(matches!(err, SyncError::CursorExpired));
    }

    #[tokio::test]
    async fn incremental_sync_skips_per_message_404_and_keeps_going() {
        // Gmail's history feed can reference a message that was expunged before
        // we fetch it. A per-message 404 must be skipped, not abort the whole
        // folder sync — otherwise the cursor never advances and genuinely-new
        // mail sitting after the tombstone in the delta never arrives. Covers
        // both fetch sites: messagesAdded (full) and a label change (metadata).
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/history"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "history": [
                    { "messagesAdded": [ { "message": { "id": "gone" } } ] },    // expunged → 404
                    { "labelsRemoved": [ { "message": { "id": "vanished" } } ] }, // expunged → 404
                    { "messagesAdded": [ { "message": { "id": "g30" } } ] },      // genuinely new
                ],
                "historyId": "7007"
            })))
            .mount(&server)
            .await;
        // Both expunged ids 404 on fetch (full and metadata respectively).
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/messages/gone"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/messages/vanished"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;
        mock_full_message(&server, "g30", "<m30@x>", &["INBOX"]).await;

        let mut adapter = adapter_for(&server);
        let (folder, cursor) = folder_with_cursor("7000");
        let r = adapter.incremental_sync(&folder, &cursor).await.unwrap();

        // The good message survives; both 404s are skipped; the cursor advances.
        assert_eq!(r.messages.len(), 1);
        assert_eq!(r.messages[0].1.provider_id.as_deref(), Some("g30"));
        assert_eq!(r.next_token.as_deref(), Some("7007"));
    }

    #[tokio::test]
    async fn incremental_sync_follows_history_pages() {
        // Regression: only page 1 was read and its historyId saved as the
        // cursor, so an INBOX arrival on page 2 was never filed in INBOX.
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/history"))
            .and(query_param_is_missing("pageToken"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "history": [ { "messagesDeleted": [ { "message": { "id": "g40" } } ] } ],
                "nextPageToken": "p2",
                "historyId": "8008"
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/gmail/v1/users/me/history"))
            .and(query_param("pageToken", "p2"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "history": [ { "messagesAdded": [ { "message": { "id": "g41" } } ] } ],
                "historyId": "8009"
            })))
            .mount(&server)
            .await;
        mock_full_message(&server, "g41", "<m41@x>", &["INBOX", "UNREAD"]).await;

        let mut adapter = adapter_for(&server);
        let (folder, cursor) = folder_with_cursor("8000");
        let r = adapter.incremental_sync(&folder, &cursor).await.unwrap();

        assert_eq!(r.messages.len(), 1);
        assert_eq!(r.messages[0].1.provider_id.as_deref(), Some("g41"));
        assert_eq!(r.deletions.len(), 1);
        assert_eq!(r.next_token.as_deref(), Some("8009"));
    }

    #[tokio::test]
    async fn incremental_sync_no_cursor_is_expired() {
        let server = MockServer::start().await;
        let mut adapter = adapter_for(&server);
        let folder = UnifiedFolder {
            key: "k".into(),
            account_key: "a".into(),
            provider_name: "INBOX".into(),
            role: Some(WellKnownFolder::Inbox),
            separator: None,
            flags: vec!["INBOX".into()],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        };
        let cursor = SyncCursor::default();
        assert!(matches!(
            adapter.incremental_sync(&folder, &cursor).await.unwrap_err(),
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

    #[tokio::test]
    async fn apply_action_mark_read_posts_modify() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/gmail/v1/users/me/messages/g1/modify"))
            .and(body_partial_json(serde_json::json!({ "removeLabelIds": ["UNREAD"] })))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .expect(1)
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        adapter
            .apply_action(&action(ActionType::MarkRead), &gmail_pid("g1"))
            .await
            .unwrap();
        // wiremock verifies the .expect(1) on drop.
    }

    #[tokio::test]
    async fn apply_action_trash_and_delete() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/gmail/v1/users/me/messages/g1/trash"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .and(path("/gmail/v1/users/me/messages/g2"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;

        let mut adapter = adapter_for(&server);
        adapter.apply_action(&action(ActionType::Trash), &gmail_pid("g1")).await.unwrap();
        adapter.apply_action(&action(ActionType::Delete), &gmail_pid("g2")).await.unwrap();
    }

    fn gmail_pid(id: &str) -> ProviderMessageId {
        ProviderMessageId { uid: None, mod_seq: None, provider_id: Some(id.into()) }
    }

    // The write-back error path must carry the HTTP status code so the drain can
    // classify it (auth → NeedsReauth, permanent → give up, transient → retry)
    // instead of collapsing into an opaque error and burning the retry budget.
    #[tokio::test]
    async fn check_writeback_preserves_status_for_classification() {
        use wiremock::matchers::any;

        async fn resp_for(code: u16) -> reqwest::Response {
            let server = MockServer::start().await;
            Mock::given(any())
                .respond_with(ResponseTemplate::new(code))
                .mount(&server)
                .await;
            // wiremock leaks the server for the request's lifetime via the URL.
            reqwest::Client::new().get(server.uri()).send().await.unwrap()
        }

        // 401/403 → dead credentials.
        assert!(check_writeback(resp_for(401).await).await.unwrap_err().is_auth());
        assert!(check_writeback(resp_for(403).await).await.unwrap_err().is_auth());
        // 400 → permanent (give up), not an auth prompt.
        let e = check_writeback(resp_for(400).await).await.unwrap_err();
        assert!(e.is_permanent() && !e.is_auth());
        // 5xx → transient: neither permanent nor auth, so the drain retries.
        let e = check_writeback(resp_for(503).await).await.unwrap_err();
        assert!(!e.is_permanent() && !e.is_auth());
        // 404 → the message is gone server-side; treated as already applied.
        assert!(check_writeback(resp_for(404).await).await.is_ok());
    }
}
