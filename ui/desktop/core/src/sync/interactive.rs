//! Interactive (user-initiated) provider operations: fetch full message body
//! with inline images, download attachments, view raw source, send mail, and
//! conversation-level actions / triage labels.
//!
//! Kept separate from the background-sync `ProviderAdapter` trait so the sync
//! engine stays lean. Gmail/Microsoft are ported from the JS
//! `lib/providers/{gmail,microsoft}.js`; IMAP (`ImapInteractive`) opens its own
//! short-lived IMAP connections for reads and submits sends over SMTP.

use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use unicode_normalization::UnicodeNormalization;

use crate::sync::adapters::gmail_labels as label;
use crate::sync::adapters::gmail_mail::{decode_base64url, extract_body, part_is_inline};
use crate::sync::adapters::imap_adapter::{connect_session, ImapSession};
use crate::sync::error::{Result, SyncError};
use crate::sync::mime;
use crate::sync::model::{ProviderCredentials, Quadrant, WellKnownFolder};
use crate::sync::oauth::TokenManager;
use crate::sync::store::SyncStore;
use crate::sync::util::{json_str, urlencode};

const GMAIL_API: &str = "https://gmail.googleapis.com/gmail/v1";
const GRAPH_API: &str = "https://graph.microsoft.com/v1.0";

/// Outcome of the shared head of `resolve_id` (Gmail/Microsoft): the provider id
/// is already cached, we have a Message-ID to search for, or the message has no
/// Message-ID header and so can't be resolved.
enum ResolveId {
    Found(String),
    Search(String),
    Unknown,
}

/// Shared head of Gmail/Microsoft `resolve_id`: cached provider id → `Found`,
/// else the bare (`<>`-trimmed) Message-ID to search → `Search`, else `Unknown`.
fn resolve_cached_or_mid(store: &SyncStore, account_key: &str, message_key: &str) -> Result<ResolveId> {
    if let Some(id) = store.get_provider_id_for_message(account_key, message_key)? {
        return Ok(ResolveId::Found(id));
    }
    match store.get_message_id_header(message_key)? {
        Some(m) => Ok(ResolveId::Search(m.trim_matches(|c| c == '<' || c == '>').to_string())),
        None => Ok(ResolveId::Unknown),
    }
}

/// Shared tail of `resolve_id`: best-effort backfill of the discovered provider
/// id into provider_state so the next lookup hits the cache. A backfill failure
/// is logged, never fatal.
fn backfill_provider_id(store: &SyncStore, account_key: &str, message_key: &str, gid: &str) -> Result<()> {
    if let Some(folder) = store.first_folder_key(account_key)? {
        if let Err(e) = store.backfill_provider_state(message_key, account_key, &folder, gid) {
            log::warn!("provider-state backfill failed for {message_key}: {e}");
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachmentRef {
    pub attachment_id: String,
    pub filename: String,
    pub mime_type: String,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct FetchedMessage {
    pub body_html: Option<String>,
    pub body_plain: Option<String>,
    pub attachments: Vec<AttachmentRef>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutgoingAttachment {
    pub filename: String,
    pub mime_type: Option<String>,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OutgoingMessage {
    pub from_address: String,
    pub to_address: String,
    pub cc_address: Option<String>,
    #[serde(default)]
    pub bcc_address: Option<String>,
    pub subject: Option<String>,
    pub body_html: Option<String>,
    pub body_plain: Option<String>,
    #[serde(default)]
    pub attachments: Vec<OutgoingAttachment>,
    /// RFC 5322 `Message-ID` for this send, generated at enqueue time (see
    /// `SyncEngine::enqueue_send`) and written into the MIME headers. It ties the
    /// local sent copy to the provider's copy when the Sent folder syncs back —
    /// Gmail/Graph may rewrite it, which is why the provider's returned id is
    /// the primary match (see `SyncStore::upsert_synced_message`).
    #[serde(default)]
    pub message_id: Option<String>,
    /// Local `messages.key` of the message this send replies to. Set by the
    /// compose UI; the engine hydrates the three threading fields below from
    /// the store at enqueue time (so the outbox payload is self-contained and
    /// retries don't depend on the parent row still existing).
    #[serde(default)]
    pub reply_to_message_key: Option<String>,
    /// RFC 5322 `In-Reply-To`: the parent's Message-ID. Hydrated from
    /// `reply_to_message_key` when unset.
    #[serde(default)]
    pub in_reply_to: Option<String>,
    /// RFC 5322 `References`: the parent's References chain plus the parent's
    /// Message-ID. Hydrated from `reply_to_message_key` when unset.
    #[serde(default)]
    pub references: Option<String>,
    /// Provider-native thread id of the parent's conversation (Gmail
    /// `threadId`). Lets Gmail thread the sent copy server-side; ignored by
    /// providers without a send-time thread handle.
    #[serde(default)]
    pub provider_thread_id: Option<String>,
    /// Meta WhatsApp template message name. When set, the send is a **template**
    /// (used to reach a customer *outside* the 24h CS window); when unset, the
    /// send is an in-window session message built from `body_plain`. Ignored by
    /// mail providers and by Messenger/Instagram.
    #[serde(default)]
    pub meta_template_name: Option<String>,
    /// BCP-47 language code for the WhatsApp template (e.g. `en_US`).
    #[serde(default)]
    pub meta_template_language: Option<String>,
    /// WhatsApp template `components` array (header/body/button params), passed
    /// through verbatim to the Graph API.
    #[serde(default)]
    pub meta_template_components: Option<Value>,
    /// Messenger/Instagram message tag (e.g. `HUMAN_AGENT`) for an out-of-window
    /// send. When set, the send uses `messaging_type: MESSAGE_TAG` instead of
    /// `RESPONSE`. Ignored by WhatsApp (which uses templates) and mail.
    #[serde(default)]
    pub meta_message_tag: Option<String>,
}

#[async_trait]
pub trait InteractiveProvider: Send + Sync {
    async fn fetch_message(&self, message_key: &str) -> Result<FetchedMessage>;
    async fn download_attachment(&self, message_key: &str, attachment_id: &str) -> Result<Vec<u8>>;
    async fn get_message_source(&self, message_key: &str) -> Result<String>;
    async fn send_message(&self, msg: &OutgoingMessage) -> Result<String>;
    /// Save `msg` as a draft in the account's Drafts, unsent, replacing the
    /// draft `existing` (the id an earlier save returned) when given. Returns the
    /// provider's id for the saved draft (empty where it hands none back).
    async fn save_draft(&self, _msg: &OutgoingMessage, _existing: Option<&str>) -> Result<String> {
        Err(SyncError::Other("drafts are not supported for this account".into()))
    }
    /// Apply an action to provider message ids. `action` follows the JS verbs:
    /// archive/trash/spam/mark_read/mark_unread, set_quadrant:KEY, clear_quadrant.
    async fn perform_action(&self, provider_ids: &[String], action: &str) -> Result<()>;
    /// Run `query` through the provider's own search index, which reads inside
    /// attachments (the local FTS only sees filenames), and return the local
    /// conversations it hit. One request; nothing is downloaded. Empty where the
    /// provider has no usable search (IMAP rarely indexes attachments, Meta none).
    async fn search_conversations(&self, _query: &str) -> Result<Vec<String>> {
        Ok(Vec::new())
    }
}

/// Provider search hits per request. Matches the local search's 50-row page.
const PROVIDER_SEARCH_LIMIT: usize = 50;

// ── Shared helpers ─────────────────────────────────────────────────────────

/// Inline images at or below this size pass through byte-for-byte (small logos
/// keep their exact pixels + any transparency). Above it we re-encode — a single
/// screenshot otherwise bloats the stored body to many MB and makes the reader
/// crawl (one thread arrived with two ~10MB inline screenshots).
const INLINE_IMG_MAX_BYTES: usize = 512 * 1024;
/// Longest edge an oversized inline image is scaled down to before re-encoding.
const INLINE_IMG_MAX_DIM: u32 = 1600;

/// Standard-base64 a byte slice for a `data:` URI.
fn b64_std(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Raster types we're willing to flatten to JPEG. Excludes SVG (vector) and GIF
/// (animation would collapse to a single frame).
fn is_downscalable_image(mime: &str) -> bool {
    matches!(
        mime.trim().to_ascii_lowercase().as_str(),
        "image/png" | "image/jpeg" | "image/jpg" | "image/webp" | "image/bmp"
    )
}

/// Build a `data:` URI for an inline image, downscaling oversized rasters so a
/// single screenshot can't bloat the stored body. Small images, vector/animated
/// types, and anything we can't decode pass through untouched — correctness over
/// savings, and we never grow the payload.
fn inline_image_data_uri(mime: &str, bytes: &[u8]) -> String {
    if bytes.len() > INLINE_IMG_MAX_BYTES && is_downscalable_image(mime) {
        if let Some(jpeg) = downscale_to_jpeg(bytes) {
            if jpeg.len() < bytes.len() {
                return format!("data:image/jpeg;base64,{}", b64_std(&jpeg));
            }
        }
    }
    format!("data:{mime};base64,{}", b64_std(bytes))
}

/// Decode, scale the longest edge down to `INLINE_IMG_MAX_DIM` (only if larger),
/// and re-encode as JPEG q82. Returns None for anything undecodable.
fn downscale_to_jpeg(bytes: &[u8]) -> Option<Vec<u8>> {
    let img = image::load_from_memory(bytes).ok()?;
    let scaled = if img.width().max(img.height()) > INLINE_IMG_MAX_DIM {
        img.resize(INLINE_IMG_MAX_DIM, INLINE_IMG_MAX_DIM, image::imageops::FilterType::Triangle)
    } else {
        img
    };
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 82)
        .encode_image(&image::DynamicImage::from(scaled.to_rgb8()))
        .ok()?;
    Some(out)
}

/// Case-insensitively replace `cid:<content_id>` occurrences with `replacement`.
fn replace_cid(html: &str, content_id: &str, replacement: &str) -> String {
    let needle = format!("cid:{content_id}");
    let lower_html = html.to_lowercase();
    let lower_needle = needle.to_lowercase();
    let mut out = String::with_capacity(html.len());
    let mut idx = 0;
    while let Some(pos) = lower_html[idx..].find(&lower_needle) {
        let abs = idx + pos;
        out.push_str(&html[idx..abs]);
        out.push_str(replacement);
        idx = abs + needle.len();
    }
    out.push_str(&html[idx..]);
    out
}

// ===========================================================================
// Gmail
// ===========================================================================

pub struct GmailInteractive {
    token: Arc<TokenManager>,
    store: Arc<SyncStore>,
    account_key: String,
    api_base: String,
    /// Memoized triage-label name→id map. `ensure_triage_labels` otherwise does
    /// a full `labels.list` GET (and may create labels) on *every* quadrant
    /// action; caching it means one list per provider instance (the engine
    /// reuses one instance across a write-back batch).
    triage_labels: tokio::sync::Mutex<Option<std::collections::HashMap<String, String>>>,
}

impl GmailInteractive {
    pub fn new(token: Arc<TokenManager>, store: Arc<SyncStore>, account_key: String) -> Self {
        Self {
            token,
            store,
            account_key,
            api_base: GMAIL_API.to_string(),
            triage_labels: tokio::sync::Mutex::new(None),
        }
    }

    #[cfg(test)]
    pub fn with_base(mut self, base: String) -> Self {
        self.api_base = base;
        self
    }

    async fn get_json(&self, url: &str) -> Result<Value> {
        let resp = self.token.request(reqwest::Method::GET, url, None).await?;
        // Route through the shared classifier so the status code survives (an
        // expired-token 401/403 → is_auth, a transient 5xx → retry) instead of
        // collapsing into an opaque Http(String).
        crate::sync::adapters::util::parse_json_response("Gmail", resp, |_, _| None).await
    }

    /// Resolve the Gmail message id for a local message key (provider state, then
    /// a `rfc822msgid:` search with backfill).
    async fn resolve_id(&self, message_key: &str) -> Result<Option<String>> {
        let mid = match resolve_cached_or_mid(&self.store, &self.account_key, message_key)? {
            ResolveId::Found(id) => return Ok(Some(id)),
            ResolveId::Unknown => return Ok(None),
            ResolveId::Search(mid) => mid,
        };
        let url = format!(
            "{}/users/me/messages?q=rfc822msgid:{}&maxResults=1",
            self.api_base,
            urlencode(&mid)
        );
        let id = self
            .get_json(&url)
            .await?
            .get("messages")
            .and_then(|m| m.as_array())
            .and_then(|a| a.first())
            .and_then(|m| json_str(m, "id"));
        if let Some(ref gid) = id {
            backfill_provider_id(&self.store, &self.account_key, message_key, gid)?;
        }
        Ok(id)
    }

    async fn ensure_triage_labels(&self) -> Result<std::collections::HashMap<String, String>> {
        // Serve from the per-instance cache when already resolved.
        if let Some(cached) = self.triage_labels.lock().await.as_ref() {
            return Ok(cached.clone());
        }
        let resolved = self.resolve_triage_labels().await?;
        *self.triage_labels.lock().await = Some(resolved.clone());
        Ok(resolved)
    }

    async fn resolve_triage_labels(&self) -> Result<std::collections::HashMap<String, String>> {
        let url = format!("{}/users/me/labels", self.api_base);
        let data = self.get_json(&url).await?;
        let existing = data.get("labels").and_then(|l| l.as_array()).cloned().unwrap_or_default();
        let wanted = Quadrant::ALL.map(|q| (q.as_str(), q.folder_name()));
        let mut cache = std::collections::HashMap::new();
        for (key, name) in wanted {
            if let Some(found) = existing.iter().find(|l| json_str(l, "name").as_deref() == Some(name)) {
                if let Some(id) = json_str(found, "id") {
                    cache.insert(key.to_string(), id);
                }
            } else {
                let body = serde_json::json!({
                    "name": name,
                    "labelListVisibility": "labelShow",
                    "messageListVisibility": "show"
                });
                let resp = self
                    .token
                    .request(reqwest::Method::POST, &url, Some(&body))
                    .await?;
                if resp.status().is_success() {
                    if let Ok(v) = resp.json::<Value>().await {
                        if let Some(id) = json_str(&v, "id") {
                            cache.insert(key.to_string(), id);
                        }
                    }
                }
            }
        }
        Ok(cache)
    }
}

#[async_trait]
impl InteractiveProvider for GmailInteractive {
    async fn fetch_message(&self, message_key: &str) -> Result<FetchedMessage> {
        let id = self
            .resolve_id(message_key)
            .await?
            .ok_or_else(|| SyncError::Other("Gmail message id not found".into()))?;
        let url = format!("{}/users/me/messages/{id}?format=full", self.api_base);
        let msg = self.get_json(&url).await?;
        let payload = msg.get("payload").cloned().unwrap_or(Value::Null);

        let (plain, mut html) = extract_body(&payload);
        // Before the cid: links below become data URIs, while the HTML still says which parts it shows.
        let mut attachments = Vec::new();
        collect_attachments(&payload, html.as_deref(), &mut attachments);

        // Resolve inline cid: images.
        let mut inline = Vec::new();
        collect_inline_images(&payload, &mut inline);
        if html.is_some() && !inline.is_empty() {
            let mut h = html.take().unwrap();
            for img in &inline {
                let aurl = format!(
                    "{}/users/me/messages/{id}/attachments/{}",
                    self.api_base, img.attachment_id
                );
                if let Ok(att) = self.get_json(&aurl).await {
                    if let Some(d) = json_str(&att, "data") {
                        // Gmail attachment data is unpadded base64url.
                        let cleaned: String = d.chars().filter(|c| !c.is_whitespace()).collect();
                        if let Ok(raw) = base64::engine::general_purpose::URL_SAFE_NO_PAD
                            .decode(cleaned.trim_end_matches('='))
                        {
                            let data_uri = inline_image_data_uri(&img.mime_type, &raw);
                            h = replace_cid(&h, &img.content_id, &data_uri);
                        }
                    }
                }
            }
            html = Some(h);
        }

        self.store
            .update_message_body(message_key, html.as_deref(), plain.as_deref())?;

        Ok(FetchedMessage { body_html: html, body_plain: plain, attachments })
    }

    async fn download_attachment(&self, message_key: &str, attachment_id: &str) -> Result<Vec<u8>> {
        let id = self
            .resolve_id(message_key)
            .await?
            .ok_or_else(|| SyncError::Other("Gmail message id not found".into()))?;
        let url = format!(
            "{}/users/me/messages/{id}/attachments/{attachment_id}",
            self.api_base
        );
        let data = self.get_json(&url).await?;
        let b64 = data
            .get("data")
            .and_then(|d| d.as_str())
            .ok_or_else(|| SyncError::Other("attachment has no data".into()))?;
        let cleaned: String = b64.chars().filter(|c| !c.is_whitespace() && *c != '=').collect();
        base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(cleaned)
            .map_err(|e| SyncError::Other(format!("attachment decode: {e}")))
    }

    async fn get_message_source(&self, message_key: &str) -> Result<String> {
        let id = match self.resolve_id(message_key).await? {
            Some(id) => id,
            None => {
                return self
                    .store
                    .local_message_source(message_key)?
                    .ok_or_else(|| SyncError::Other("message not found".into()))
            }
        };
        let url = format!("{}/users/me/messages/{id}?format=raw", self.api_base);
        match self.get_json(&url).await {
            Ok(data) => match data.get("raw").and_then(|r| r.as_str()).and_then(decode_base64url) {
                Some(raw) => Ok(raw),
                None => self.store.local_message_source(message_key)?.ok_or_else(|| {
                    SyncError::Other("Gmail returned no raw body and no local copy is cached".into())
                }),
            },
            // A real API failure (auth, rate limit, network) must not be masked
            // as an empty body — fall back to the local copy only when one
            // actually exists, otherwise surface the error.
            Err(e) => {
                log::warn!("Gmail message source fetch failed ({e}); trying the local cache");
                self.store.local_message_source(message_key)?.ok_or(e)
            }
        }
    }

    async fn send_message(&self, msg: &OutgoingMessage) -> Result<String> {
        let mime = build_mime_message(msg);
        let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(mime.as_bytes());
        let url = format!("{}/users/me/messages/send", self.api_base);
        // threadId makes Gmail thread the sent copy server-side (it honors it
        // when the References/Subject also match, which build_mime_message set).
        let body = match &msg.provider_thread_id {
            Some(tid) if !tid.is_empty() => serde_json::json!({ "raw": raw, "threadId": tid }),
            _ => serde_json::json!({ "raw": raw }),
        };
        let resp = self
            .token
            .request(reqwest::Method::POST, &url, Some(&body))
            .await?;
        if !resp.status().is_success() {
            return Err(SyncError::HttpStatus {
                code: resp.status().as_u16(),
                context: format!("Gmail send {}", resp.status()),
            });
        }
        let v: Value = resp.json().await?;
        Ok(json_str(&v, "id").unwrap_or_default())
    }

    /// Every version of a draft carries one Message-ID, and the draft already
    /// holding it is found by that (`rfc822msgid:` search) as well as by the id
    /// an earlier save returned. So a create whose response was lost is found
    /// and updated on retry instead of becoming a second draft; any duplicates
    /// from before are deleted.
    async fn save_draft(&self, msg: &OutgoingMessage, existing: Option<&str>) -> Result<String> {
        let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(build_mime_message(msg).as_bytes());
        let mut message = serde_json::json!({ "raw": raw });
        if let Some(tid) = msg.provider_thread_id.as_deref().filter(|t| !t.is_empty()) {
            message["threadId"] = serde_json::json!(tid);
        }
        let body = serde_json::json!({ "message": message });

        let mut candidates: Vec<String> = existing.filter(|id| !id.is_empty()).map(String::from).into_iter().collect();
        if let Some(mid) = msg.message_id.as_deref().filter(|m| !m.is_empty()) {
            let url = format!("{}/users/me/drafts?q={}", self.api_base, urlencode(&format!("rfc822msgid:{mid}")));
            if let Some(found) = self.get_json(&url).await?.get("drafts").and_then(|d| d.as_array()) {
                for id in found.iter().filter_map(|d| json_str(d, "id")) {
                    if !candidates.contains(&id) {
                        candidates.push(id);
                    }
                }
            }
        }

        // drafts.update replaces a draft in place; a 404 means it was deleted or
        // sent meanwhile, so try the next one.
        let mut kept: Option<String> = None;
        for id in &candidates {
            if kept.is_some() {
                let url = format!("{}/users/me/drafts/{id}", self.api_base);
                let _ = self.token.request(reqwest::Method::DELETE, &url, None).await;
                continue;
            }
            let url = format!("{}/users/me/drafts/{id}", self.api_base);
            let resp = self.token.request(reqwest::Method::PUT, &url, Some(&body)).await?;
            if resp.status().is_success() {
                let v: Value = resp.json().await?;
                kept = Some(json_str(&v, "id").unwrap_or_else(|| id.clone()));
            } else if resp.status() != reqwest::StatusCode::NOT_FOUND {
                return Err(SyncError::HttpStatus {
                    code: resp.status().as_u16(),
                    context: format!("Gmail draft update {}", resp.status()),
                });
            }
        }
        if let Some(id) = kept {
            return Ok(id);
        }

        let url = format!("{}/users/me/drafts", self.api_base);
        let resp = self.token.request(reqwest::Method::POST, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            return Err(SyncError::HttpStatus {
                code: resp.status().as_u16(),
                context: format!("Gmail draft {}", resp.status()),
            });
        }
        let v: Value = resp.json().await?;
        Ok(json_str(&v, "id").unwrap_or_default())
    }

    async fn search_conversations(&self, query: &str) -> Result<Vec<String>> {
        // Gmail's own `q` syntax, exactly what gmail.com runs (spam/trash excluded
        // by default, like the local search).
        let url = format!(
            "{}/users/me/messages?q={}&maxResults={PROVIDER_SEARCH_LIMIT}",
            self.api_base,
            urlencode(query)
        );
        let v = self.get_json(&url).await?;
        let ids: Vec<String> = v
            .get("messages")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|m| json_str(m, "id")).collect())
            .unwrap_or_default();
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        self.store.conversation_keys_for_hits(&self.account_key, &ids, &[])
    }

    async fn perform_action(&self, provider_ids: &[String], action: &str) -> Result<()> {
        if provider_ids.is_empty() {
            return Ok(());
        }
        let modification: Value = if action == "clear_quadrant" {
            let triage = self.ensure_triage_labels().await?;
            let ids: Vec<String> = triage.values().cloned().collect();
            serde_json::json!({ "removeLabelIds": ids })
        } else if let Some(key) = action.strip_prefix("set_quadrant:") {
            let triage = self.ensure_triage_labels().await?;
            let target = match triage.get(key) {
                Some(t) => t.clone(),
                None => return Ok(()),
            };
            let remove: Vec<String> = triage.values().filter(|v| **v != target).cloned().collect();
            serde_json::json!({ "addLabelIds": [target], "removeLabelIds": remove })
        } else {
            match action {
                "archive" => serde_json::json!({ "removeLabelIds": [label::INBOX] }),
                "trash" => serde_json::json!({ "addLabelIds": [label::TRASH], "removeLabelIds": [label::INBOX] }),
                "spam" => serde_json::json!({ "addLabelIds": [label::SPAM], "removeLabelIds": [label::INBOX] }),
                "mark_read" => serde_json::json!({ "removeLabelIds": [label::UNREAD] }),
                "mark_unread" => serde_json::json!({ "addLabelIds": [label::UNREAD] }),
                "untrash" => serde_json::json!({ "removeLabelIds": [label::TRASH], "addLabelIds": [label::INBOX] }),
                "unspam" => serde_json::json!({ "removeLabelIds": [label::SPAM], "addLabelIds": [label::INBOX] }),
                "unarchive" => serde_json::json!({ "addLabelIds": [label::INBOX] }),
                _ => return Ok(()),
            }
        };

        let mut body = serde_json::Map::new();
        body.insert("ids".into(), serde_json::json!(provider_ids));
        if let Value::Object(m) = modification {
            for (k, v) in m {
                body.insert(k, v);
            }
        }
        let url = format!("{}/users/me/messages/batchModify", self.api_base);
        let resp = self
            .token
            .request(reqwest::Method::POST, &url, Some(&Value::Object(body)))
            .await?;
        if !resp.status().is_success() {
            return Err(SyncError::Http(format!("Gmail batchModify {}", resp.status())));
        }
        Ok(())
    }
}

struct InlineImage {
    content_id: String,
    attachment_id: String,
    mime_type: String,
}

fn collect_inline_images(payload: &Value, out: &mut Vec<InlineImage>) {
    let cid = payload
        .get("headers")
        .and_then(|h| h.as_array())
        .and_then(|hs| {
            hs.iter().find_map(|h| {
                if json_str(h, "name").as_deref().map(|n| n.eq_ignore_ascii_case("content-id")) == Some(true) {
                    json_str(h, "value")
                } else {
                    None
                }
            })
        });
    let mime = json_str(payload, "mimeType").unwrap_or_default();
    let att_id = payload.get("body").and_then(|b| json_str(b, "attachmentId"));
    if let (Some(cid), Some(att_id)) = (cid, att_id) {
        if mime.starts_with("image/") {
            out.push(InlineImage {
                content_id: cid.trim_matches(|c| c == '<' || c == '>').to_string(),
                attachment_id: att_id,
                mime_type: mime,
            });
        }
    }
    if let Some(parts) = payload.get("parts").and_then(|p| p.as_array()) {
        for p in parts {
            collect_inline_images(p, out);
        }
    }
}

fn collect_attachments(payload: &Value, html: Option<&str>, out: &mut Vec<AttachmentRef>) {
    let filename = json_str(payload, "filename").unwrap_or_default();
    let mime = json_str(payload, "mimeType").unwrap_or_default();
    if !filename.is_empty() && !part_is_inline(payload, html) {
        if let Some(att_id) = payload.get("body").and_then(|b| json_str(b, "attachmentId")) {
            out.push(AttachmentRef {
                attachment_id: att_id,
                filename,
                mime_type: if mime.is_empty() { "application/octet-stream".into() } else { mime },
                size: payload
                    .get("body")
                    .and_then(|b| b.get("size"))
                    .and_then(|s| s.as_u64())
                    .unwrap_or(0),
            });
        }
    }
    if let Some(parts) = payload.get("parts").and_then(|p| p.as_array()) {
        for p in parts {
            collect_attachments(p, html, out);
        }
    }
}

/// Raw bytes per encoded-word. RFC 2047 §2 caps an encoded-word at 75 chars:
/// base64(45 bytes) = 60 chars, + `=?UTF-8?B?` (10) + `?=` (2) = 72.
const MAX_ENCODED_WORD_BYTES: usize = 45;

/// RFC 2047 B-encode header text when it contains non-ASCII. RFC 5322 headers
/// are ASCII-only: raw UTF-8 bytes get re-interpreted (often twice) down the
/// line — "Ömer" arrived in recipients' inboxes as "ÃƒÂ–mer".
///
/// Long text folds into several encoded-words: a 100-character Chinese or
/// Arabic subject B-encodes to ~400 characters, past both the 75-char
/// encoded-word cap and the RFC 5322 998-octet line limit, and strict receivers
/// then refuse to decode it. Text is NFC-normalized first so a decomposed "أ"
/// goes out as the precomposed codepoint every other client sends.
fn encode_header_text(s: &str) -> String {
    let s = s.nfc().collect::<String>();
    if s.is_ascii() {
        return s;
    }
    chunk_utf8(&s, MAX_ENCODED_WORD_BYTES)
        .into_iter()
        .map(|c| format!("=?UTF-8?B?{}?=", base64::engine::general_purpose::STANDARD.encode(c.as_bytes())))
        .collect::<Vec<_>>()
        .join("\r\n ") // RFC 2047 §5: adjacent encoded-words fold on CRLF + WSP
}

/// Split into pieces of at most `max` UTF-8 bytes without cutting a character —
/// each encoded-word has to decode standalone, so a multi-byte character may
/// never straddle two of them.
fn chunk_utf8(s: &str, max: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    for ch in s.chars() {
        if cur.len() + ch.len_utf8() > max && !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
        cur.push(ch);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Encode a MIME parameter value (`filename`, `name`). RFC 2047 encoded-words
/// are NOT valid syntax inside a parameter value — the mechanism is RFC 2231's
/// extended syntax — so an Arabic or Chinese filename sent as
/// `filename="=?UTF-8?B?...?="` shows up literally in strict clients.
/// ponytail: no RFC 2231 continuations (`filename*0*=`), so a very long
/// non-ASCII filename yields one long parameter line. Add them if a receiver
/// complains.
fn encode_mime_param(name: &str, value: &str) -> String {
    let value = value.nfc().collect::<String>();
    if value.is_ascii() {
        return format!("{name}=\"{}\"", value.replace('"', ""));
    }
    // RFC 2231 percent-encoding over the UTF-8 bytes; over-encoding everything
    // outside the unreserved set is always safe to decode.
    let encoded: String = value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect();
    format!("{name}*=UTF-8''{encoded}")
}

/// Split an address-list header on top-level commas (quoted display names may
/// contain commas: `"Eryigit, Ömer" <o@x>, b@y`).
fn split_address_list(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    for c in s.chars() {
        match c {
            '"' => {
                in_quotes = !in_quotes;
                cur.push(c);
            }
            ',' if !in_quotes => {
                out.push(cur.clone());
                cur.clear();
            }
            _ => cur.push(c),
        }
    }
    out.push(cur);
    out.into_iter().map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect()
}

/// Encode the display-name part of each mailbox in an address-list header
/// (`Name <a@b>` / `"Name" <a@b>` / bare `a@b`) per RFC 2047.
fn encode_address_header(list: &str) -> String {
    split_address_list(list)
        .into_iter()
        .map(|mb| {
            if mb.is_ascii() {
                return mb;
            }
            match mb.rfind('<') {
                Some(lt) => {
                    let name = mb[..lt].trim().trim_matches('"').trim();
                    format!("{} {}", encode_header_text(name), mb[lt..].trim())
                }
                None => mb,
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// Quoted-printable encode a text body: 7-bit clean, lines ≤76 chars. Raw
/// UTF-8 bodies with kilobyte-long HTML lines (or bare LFs) violate the SMTP
/// 998-char line limit and 7-bit assumptions once the message leaves Gmail.
fn qp_body(text: &str) -> String {
    quoted_printable::encode_to_str(text)
}

/// Graph's JSON message shape for an [`OutgoingMessage`]: shared by sendMail
/// and draft creation.
fn graph_message(m: &OutgoingMessage) -> Value {
    // Graph wants the bare SMTP address in `address` (a `Name <a@b>` string
    // 400s), with the display name in `name`. Split quote-aware so a
    // `"Eryigit, Ömer" <o@x>` mailbox isn't broken at its comma.
    let recipients = |s: &str| -> Vec<Value> {
        split_address_list(s)
            .into_iter()
            .map(|mb| match mb.rfind('<') {
                Some(lt) => {
                    let name = mb[..lt].trim().trim_matches('"').trim().to_string();
                    let addr = mb[lt..].trim().trim_matches(['<', '>']).to_string();
                    if name.is_empty() {
                        serde_json::json!({ "emailAddress": { "address": addr } })
                    } else {
                        serde_json::json!({ "emailAddress": { "address": addr, "name": name } })
                    }
                }
                None => serde_json::json!({ "emailAddress": { "address": mb } }),
            })
            .collect()
    };
    let mut message = serde_json::json!({
        "subject": m.subject.as_deref().unwrap_or("(no subject)"),
        "body": {
            "contentType": if m.body_html.is_some() { "HTML" } else { "Text" },
            "content": m.body_html.clone().or_else(|| m.body_plain.clone()).unwrap_or_default(),
        },
        "from": { "emailAddress": { "address": m.from_address } },
        "toRecipients": recipients(&m.to_address),
    });
    if let Some(cc) = &m.cc_address {
        let cc_list = recipients(cc);
        if !cc_list.is_empty() {
            message["ccRecipients"] = serde_json::json!(cc_list);
        }
    }
    if let Some(bcc) = &m.bcc_address {
        let bcc_list = recipients(bcc);
        if !bcc_list.is_empty() {
            message["bccRecipients"] = serde_json::json!(bcc_list);
        }
    }
    if !m.attachments.is_empty() {
        let atts: Vec<Value> = m
            .attachments
            .iter()
            .map(|a| {
                serde_json::json!({
                    "@odata.type": "#microsoft.graph.fileAttachment",
                    "name": a.filename,
                    "contentType": a.mime_type.as_deref().unwrap_or("application/octet-stream"),
                    "contentBytes": base64::engine::general_purpose::STANDARD.encode(&a.data),
                })
            })
            .collect();
        message["attachments"] = serde_json::json!(atts);
    }
    message
}

/// Chunk base64 attachment data into 76-char lines (RFC 2045 §6.8).
fn b64_wrapped(data: &[u8]) -> String {
    let b64 = base64::engine::general_purpose::STANDARD.encode(data);
    b64.as_bytes()
        .chunks(76)
        .map(|c| std::str::from_utf8(c).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\r\n")
}

/// Build an RFC 2822 MIME message (ported from the JS `buildMimeMessage`).
fn build_mime_message(m: &OutgoingMessage) -> String {
    // Random boundary: deriving it from the from-address made it predictable
    // (collision-prone with quoted content) and non-ASCII if the address had a
    // display name.
    let boundary = format!("inbox2-{}", nanoid::nanoid!(16));
    let mut lines: Vec<String> = Vec::new();
    lines.push(format!("From: {}", encode_address_header(&m.from_address)));
    lines.push(format!("To: {}", encode_address_header(&m.to_address)));
    if let Some(cc) = &m.cc_address {
        if !cc.is_empty() {
            lines.push(format!("Cc: {}", encode_address_header(cc)));
        }
    }
    // Gmail's messages.send honors a Bcc header in the raw MIME and strips it
    // from the delivered/stored copy, so recipients never see it.
    if let Some(bcc) = &m.bcc_address {
        if !bcc.is_empty() {
            lines.push(format!("Bcc: {}", encode_address_header(bcc)));
        }
    }
    lines.push(format!(
        "Subject: {}",
        encode_header_text(m.subject.as_deref().unwrap_or("(no subject)"))
    ));
    if let Some(mid) = m.message_id.as_deref().filter(|s| !s.is_empty()) {
        lines.push(format!("Message-ID: {mid}"));
    }
    // RFC 5322 threading headers (replies). References chains grow one
    // Message-ID per hop — fold at the IDs so no line nears the 998-char limit.
    if let Some(irt) = m.in_reply_to.as_deref().filter(|s| !s.is_empty()) {
        lines.push(format!("In-Reply-To: {irt}"));
    }
    if let Some(refs) = m.references.as_deref().filter(|s| !s.is_empty()) {
        lines.push(format!(
            "References: {}",
            refs.split_whitespace().collect::<Vec<_>>().join("\r\n ")
        ));
    }
    lines.push("MIME-Version: 1.0".into());

    let has_att = !m.attachments.is_empty();
    let plain = m.body_plain.clone().unwrap_or_default();

    let push_text_part = |lines: &mut Vec<String>, ctype: &str, body: &str| {
        lines.push(format!("Content-Type: {ctype}; charset=\"UTF-8\""));
        lines.push("Content-Transfer-Encoding: quoted-printable".into());
        lines.push(String::new());
        lines.push(qp_body(body));
    };

    if has_att {
        let mixed = format!("mixed-{boundary}");
        let alt = format!("alt-{boundary}");
        lines.push(format!("Content-Type: multipart/mixed; boundary=\"{mixed}\""));
        lines.push(String::new());
        lines.push(format!("--{mixed}"));
        if let Some(html) = &m.body_html {
            lines.push(format!("Content-Type: multipart/alternative; boundary=\"{alt}\""));
            lines.push(String::new());
            lines.push(format!("--{alt}"));
            push_text_part(&mut lines, "text/plain", &plain);
            lines.push(format!("--{alt}"));
            push_text_part(&mut lines, "text/html", html);
            lines.push(format!("--{alt}--"));
        } else {
            push_text_part(&mut lines, "text/plain", &plain);
        }
        for att in &m.attachments {
            lines.push(format!("--{mixed}"));
            lines.push(format!(
                "Content-Type: {}; {}",
                att.mime_type.as_deref().unwrap_or("application/octet-stream"),
                encode_mime_param("name", &att.filename),
            ));
            lines.push(format!(
                "Content-Disposition: attachment; {}",
                encode_mime_param("filename", &att.filename)
            ));
            lines.push("Content-Transfer-Encoding: base64".into());
            lines.push(String::new());
            lines.push(b64_wrapped(&att.data));
        }
        lines.push(format!("--{mixed}--"));
    } else if let Some(html) = &m.body_html {
        let alt = format!("alt-{boundary}");
        lines.push(format!("Content-Type: multipart/alternative; boundary=\"{alt}\""));
        lines.push(String::new());
        lines.push(format!("--{alt}"));
        push_text_part(&mut lines, "text/plain", &plain);
        lines.push(format!("--{alt}"));
        push_text_part(&mut lines, "text/html", html);
        lines.push(format!("--{alt}--"));
    } else {
        push_text_part(&mut lines, "text/plain", &plain);
    }
    lines.join("\r\n")
}

// ===========================================================================
// Microsoft
// ===========================================================================

pub struct MicrosoftInteractive {
    token: Arc<TokenManager>,
    store: Arc<SyncStore>,
    account_key: String,
    api_base: String,
}

impl MicrosoftInteractive {
    pub fn new(token: Arc<TokenManager>, store: Arc<SyncStore>, account_key: String) -> Self {
        Self { token, store, account_key, api_base: GRAPH_API.to_string() }
    }

    #[cfg(test)]
    pub fn with_base(mut self, base: String) -> Self {
        self.api_base = base;
        self
    }

    async fn get_json(&self, url: &str) -> Result<Value> {
        let resp = self.token.request(reqwest::Method::GET, url, None).await?;
        // Shared classifier so the status code survives (see GmailInteractive).
        crate::sync::adapters::util::parse_json_response("Graph", resp, |_, _| None).await
    }

    async fn resolve_id(&self, message_key: &str) -> Result<Option<String>> {
        let mid = match resolve_cached_or_mid(&self.store, &self.account_key, message_key)? {
            ResolveId::Found(id) => return Ok(Some(id)),
            ResolveId::Unknown => return Ok(None),
            ResolveId::Search(mid) => mid,
        };
        let url = format!(
            "{}/me/messages?$filter=internetMessageId eq '{}'&$select=id&$top=1",
            self.api_base,
            urlencode(&format!("<{mid}>"))
        );
        let id = self
            .get_json(&url)
            .await?
            .get("value")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .and_then(|m| json_str(m, "id"));
        if let Some(ref gid) = id {
            backfill_provider_id(&self.store, &self.account_key, message_key, gid)?;
        }
        Ok(id)
    }
}

#[async_trait]
impl InteractiveProvider for MicrosoftInteractive {
    async fn fetch_message(&self, message_key: &str) -> Result<FetchedMessage> {
        let id = self
            .resolve_id(message_key)
            .await?
            .ok_or_else(|| SyncError::Other("Graph message id not found".into()))?;

        // The body and the attachment list are independent reads — fetch them
        // concurrently rather than back-to-back. (This used to be the start of a
        // long serial chain that made first-open of image-heavy mail take ~30s.)
        let body_url = format!("{}/me/messages/{id}", self.api_base);
        let att_url = format!("{}/me/messages/{id}/attachments", self.api_base);
        let (msg, att_list) =
            tokio::join!(self.get_json(&body_url), self.get_json(&att_url));
        let msg = msg?;
        let att_list = att_list.ok();

        let ctype = msg.get("body").and_then(|b| json_str(b, "contentType"));
        let content = msg.get("body").and_then(|b| json_str(b, "content"));
        let (mut html, mut plain) = match ctype.as_deref() {
            Some("html") => (content.clone(), None),
            Some("text") => (None, content.clone()),
            _ => (None, content.clone()),
        };

        let mut attachments = Vec::new();
        // Inline images we still need to pull (cid, content-type, fetch url); these
        // are fetched in parallel below instead of one-at-a-time in this loop.
        let mut inline_jobs: Vec<(String, String, String)> = Vec::new();
        if let Some(list) = att_list {
            for att in list.get("value").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
                let is_inline = att.get("isInline").and_then(|v| v.as_bool()).unwrap_or(false);
                let content_id = json_str(&att, "contentId");
                if is_inline {
                    // Only worth fetching inline content when we have an HTML body
                    // with a cid reference to splice it into.
                    if let (Some(cid), true) = (content_id, html.is_some()) {
                        let att_id = json_str(&att, "id").unwrap_or_default();
                        let ct = json_str(&att, "contentType").unwrap_or_else(|| "image/png".into());
                        let url = format!("{}/me/messages/{id}/attachments/{att_id}", self.api_base);
                        inline_jobs.push((cid, ct, url));
                    }
                } else {
                    attachments.push(AttachmentRef {
                        attachment_id: json_str(&att, "id").unwrap_or_default(),
                        filename: json_str(&att, "name").unwrap_or_else(|| "attachment".into()),
                        mime_type: json_str(&att, "contentType")
                            .unwrap_or_else(|| "application/octet-stream".into()),
                        size: att.get("size").and_then(|s| s.as_u64()).unwrap_or(0),
                    });
                }
            }
        }

        // Fetch every inline image concurrently, then splice them into the body.
        // A single failed fetch just drops that one image rather than the body.
        if let Some(cur_html) = html.clone() {
            if !inline_jobs.is_empty() {
                let fetched = futures_util::future::join_all(inline_jobs.iter().map(
                    |(cid, ct, url)| async move {
                        let full = self.get_json(url).await.ok()?;
                        let b64 = json_str(&full, "contentBytes")?;
                        let raw = base64::engine::general_purpose::STANDARD
                            .decode(b64.trim())
                            .ok()?;
                        Some((cid.as_str(), inline_image_data_uri(ct, &raw)))
                    },
                ))
                .await;
                let mut new_html = cur_html;
                for (cid, data_uri) in fetched.into_iter().flatten() {
                    new_html = replace_cid(&new_html, cid, &data_uri);
                }
                html = Some(new_html);
            }
        }

        if html.is_none() && plain.is_none() {
            plain = content;
        }

        self.store
            .update_message_body(message_key, html.as_deref(), plain.as_deref())?;
        Ok(FetchedMessage { body_html: html, body_plain: plain, attachments })
    }

    async fn download_attachment(&self, message_key: &str, attachment_id: &str) -> Result<Vec<u8>> {
        let id = self
            .resolve_id(message_key)
            .await?
            .ok_or_else(|| SyncError::Other("Graph message id not found".into()))?;
        // Try the raw $value endpoint first.
        let value_url = format!(
            "{}/me/messages/{id}/attachments/{attachment_id}/$value",
            self.api_base
        );
        let resp = self.token.request(reqwest::Method::GET, &value_url, None).await?;
        if resp.status().is_success() {
            return Ok(resp.bytes().await?.to_vec());
        }
        // Fallback: contentBytes (base64) on the attachment object.
        let obj = self
            .get_json(&format!("{}/me/messages/{id}/attachments/{attachment_id}", self.api_base))
            .await?;
        let b64 = obj
            .get("contentBytes")
            .and_then(|c| c.as_str())
            .ok_or_else(|| SyncError::Other("attachment has no contentBytes".into()))?;
        base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| SyncError::Other(format!("attachment decode: {e}")))
    }

    async fn get_message_source(&self, message_key: &str) -> Result<String> {
        let id = match self.resolve_id(message_key).await? {
            Some(id) => id,
            None => {
                return self
                    .store
                    .local_message_source(message_key)?
                    .ok_or_else(|| SyncError::Other("message not found".into()))
            }
        };
        let url = format!("{}/me/messages/{id}/$value", self.api_base);
        let resp = self.token.request(reqwest::Method::GET, &url, None).await?;
        let status = resp.status();
        if status.is_success() {
            Ok(resp.text().await?)
        } else {
            // A real API failure (auth, throttling) must not be masked as an
            // empty body — fall back to the local copy only when one exists.
            log::warn!("Graph message source fetch failed (HTTP {status}); trying the local cache");
            self.store.local_message_source(message_key)?.ok_or_else(|| {
                SyncError::Http(format!("message source fetch failed (HTTP {status})"))
            })
        }
    }

    async fn send_message(&self, m: &OutgoingMessage) -> Result<String> {
        // Replies: Graph's JSON sendMail cannot carry the RFC threading headers
        // (internetMessageHeaders rejects non-custom names), which breaks
        // threading for every recipient. Send replies as raw MIME instead —
        // Graph accepts a base64 RFC 822 message with Content-Type: text/plain
        // and preserves In-Reply-To/References. New mail keeps the JSON path.
        if m.in_reply_to.as_deref().is_some_and(|s| !s.is_empty()) {
            let mime = build_mime_message(m);
            let b64 = base64::engine::general_purpose::STANDARD.encode(mime.as_bytes());
            let url = format!("{}/me/sendMail", self.api_base);
            let resp = self.token.request_text(reqwest::Method::POST, &url, "text/plain", b64).await?;
            if !resp.status().is_success() {
                return Err(SyncError::HttpStatus {
                    code: resp.status().as_u16(),
                    context: format!("Graph sendMail (MIME) {}", resp.status()),
                });
            }
            return Ok(String::new()); // Graph sendMail returns 202 with no id
        }

        let message = graph_message(m);
        let url = format!("{}/me/sendMail", self.api_base);
        let body = serde_json::json!({ "message": message, "saveToSentItems": true });
        let resp = self
            .token
            .request(reqwest::Method::POST, &url, Some(&body))
            .await?;
        if !resp.status().is_success() {
            return Err(SyncError::HttpStatus {
                code: resp.status().as_u16(),
                context: format!("Graph sendMail {}", resp.status()),
            });
        }
        Ok(String::new()) // Graph sendMail returns 202 with no id
    }

    /// Graph can't update a draft from MIME, so a new version replaces the old:
    /// delete every draft holding this draft's Message-ID (found by
    /// `internetMessageId`, plus the id an earlier save returned), then create it
    /// from MIME, which keeps that Message-ID. A create whose response was lost
    /// is therefore deleted and redone on retry, never left as a second draft.
    async fn save_draft(&self, m: &OutgoingMessage, existing: Option<&str>) -> Result<String> {
        let mut stale: Vec<String> = existing.filter(|id| !id.is_empty()).map(String::from).into_iter().collect();
        if let Some(mid) = m.message_id.as_deref().filter(|s| !s.is_empty()) {
            let url = format!(
                "{}/me/mailFolders/drafts/messages?$filter=internetMessageId eq '{}'&$select=id",
                self.api_base,
                urlencode(mid)
            );
            if let Some(found) = self.get_json(&url).await?.get("value").and_then(|v| v.as_array()) {
                for id in found.iter().filter_map(|d| json_str(d, "id")) {
                    if !stale.contains(&id) {
                        stale.push(id);
                    }
                }
            }
        }
        for id in &stale {
            let resp = self
                .token
                .request(reqwest::Method::DELETE, &format!("{}/me/messages/{id}", self.api_base), None)
                .await?;
            if !resp.status().is_success() && resp.status() != reqwest::StatusCode::NOT_FOUND {
                return Err(SyncError::HttpStatus {
                    code: resp.status().as_u16(),
                    context: format!("Graph draft replace {}", resp.status()),
                });
            }
        }
        let url = format!("{}/me/messages", self.api_base);
        let b64 = base64::engine::general_purpose::STANDARD.encode(build_mime_message(m).as_bytes());
        let resp = self.token.request_text(reqwest::Method::POST, &url, "text/plain", b64).await?;
        if !resp.status().is_success() {
            return Err(SyncError::HttpStatus {
                code: resp.status().as_u16(),
                context: format!("Graph draft {}", resp.status()),
            });
        }
        let v: Value = resp.json().await?;
        Ok(json_str(&v, "id").unwrap_or_default())
    }

    async fn search_conversations(&self, query: &str) -> Result<Vec<String>> {
        // KQL over subject/body/attachments. The phrase is one quoted string, so
        // inner quotes/backslashes are escaped. Graph ids change on a folder move,
        // so the Message-ID is matched too.
        // A `-word` exclusion has no place in one quoted phrase (Graph would search
        // for the word itself): drop those terms; nothing left means no search.
        let kept: Vec<&str> = query.split_whitespace().filter(|t| !t.starts_with('-')).collect();
        if kept.is_empty() {
            return Ok(Vec::new());
        }
        let kql = kept.join(" ").replace('\\', "\\\\").replace('"', "\\\"");
        let url = format!(
            "{}/me/messages?$search={}&$top={PROVIDER_SEARCH_LIMIT}&$select=id,internetMessageId",
            self.api_base,
            urlencode(&format!("\"{kql}\""))
        );
        let v = self.get_json(&url).await?;
        let hits = v.get("value").and_then(Value::as_array).cloned().unwrap_or_default();
        if hits.is_empty() {
            return Ok(Vec::new());
        }
        let ids: Vec<String> = hits.iter().filter_map(|m| json_str(m, "id")).collect();
        let mids: Vec<String> = hits
            .iter()
            .filter_map(|m| json_str(m, "internetMessageId"))
            .map(|m| m.trim_matches(|c| c == '<' || c == '>' || c == ' ').to_string())
            .collect();
        self.store.conversation_keys_for_hits(&self.account_key, &ids, &mids)
    }

    async fn perform_action(&self, provider_ids: &[String], action: &str) -> Result<()> {
        let all_names = Quadrant::ALL.map(|q| q.folder_name());

        for id in provider_ids {
            let base = &self.api_base;
            match action {
                "mark_read" => {
                    self.patch(id, serde_json::json!({ "isRead": true })).await?;
                }
                "mark_unread" => {
                    self.patch(id, serde_json::json!({ "isRead": false })).await?;
                }
                "archive" => self.move_to(id, "archive").await?,
                "trash" => self.move_to(id, "deleteditems").await?,
                "spam" => self.move_to(id, "junkemail").await?,
                "untrash" | "unspam" | "unarchive" => self.move_to(id, "inbox").await?,
                a if a == "clear_quadrant" || a.starts_with("set_quadrant:") => {
                    let url = format!("{base}/me/messages/{id}?$select=categories");
                    let data = self.get_json(&url).await?;
                    let mut categories: Vec<String> = data
                        .get("categories")
                        .and_then(|c| c.as_array())
                        .map(|arr| {
                            arr.iter()
                                .filter_map(|v| v.as_str().map(String::from))
                                .filter(|c| !all_names.contains(&c.as_str()))
                                .collect()
                        })
                        .unwrap_or_default();
                    if let Some(key) = a.strip_prefix("set_quadrant:") {
                        if let Some(q) = Quadrant::from_str(key) {
                            categories.push(q.folder_name().to_string());
                        }
                    }
                    self.patch(id, serde_json::json!({ "categories": categories })).await?;
                }
                _ => {}
            }
        }
        Ok(())
    }
}

impl MicrosoftInteractive {
    async fn patch(&self, id: &str, body: Value) -> Result<()> {
        let url = format!("{}/me/messages/{id}", self.api_base);
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(&body)).await?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(SyncError::Http(format!("Graph PATCH {}", resp.status())))
        }
    }

    async fn move_to(&self, id: &str, destination: &str) -> Result<()> {
        let url = format!("{}/me/messages/{id}/move", self.api_base);
        let body = serde_json::json!({ "destinationId": destination });
        let resp = self.token.request(reqwest::Method::POST, &url, Some(&body)).await?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(SyncError::Http(format!("Graph move {}", resp.status())))
        }
    }
}

// ===========================================================================
// IMAP
// ===========================================================================

/// Connection parameters for an IMAP account's interactive operations. Built by
/// the engine from the stored account row + credentials.
pub struct ImapConnectionInfo {
    pub host: String,
    pub port: u16,
    pub use_tls: bool,
    pub credentials: ProviderCredentials,
    /// SMTP submission host (for send). `None` ⇒ this account can't send.
    pub smtp_host: Option<String>,
    pub smtp_port: u16,
    /// true ⇒ implicit TLS (465); false ⇒ STARTTLS (587).
    pub smtp_use_tls: bool,
}

pub struct ImapInteractive {
    store: Arc<SyncStore>,
    account_key: String,
    conn: ImapConnectionInfo,
}

impl ImapInteractive {
    pub fn new(store: Arc<SyncStore>, account_key: String, conn: ImapConnectionInfo) -> Self {
        Self { store, account_key, conn }
    }

    /// Resolve a local message key to the IMAP `(folder mailbox name, UID)` it
    /// lives under — the coordinates every interactive IMAP op needs.
    fn locate(&self, message_key: &str) -> Result<(String, u32)> {
        let (folder_key, pid) = self
            .store
            .get_provider_state_by_message(message_key, &self.account_key)?
            .ok_or_else(|| SyncError::Other("message not synced for this account".into()))?;
        let uid = pid
            .uid
            .ok_or_else(|| SyncError::Other("message has no IMAP UID".into()))?;
        let mailbox = self.folder_name(&folder_key)?;
        Ok((mailbox, uid))
    }

    /// Map a local folder key to its provider mailbox name.
    fn folder_name(&self, folder_key: &str) -> Result<String> {
        self.store
            .get_folders_for_account(&self.account_key)?
            .into_iter()
            .find(|f| f.key == folder_key)
            .map(|f| f.provider_name)
            .ok_or_else(|| SyncError::Other("folder not found".into()))
    }

    /// Fetch one message's full raw RFC822 bytes (`UID FETCH … BODY.PEEK[]`).
    /// Runs the blocking IMAP I/O on a blocking thread.
    async fn fetch_raw(&self, mailbox: &str, uid: u32) -> Result<Vec<u8>> {
        let host = self.conn.host.clone();
        let port = self.conn.port;
        let use_tls = self.conn.use_tls;
        let creds = self.conn.credentials.clone();
        let mailbox = mailbox.to_string();

        tokio::task::spawn_blocking(move || -> Result<Vec<u8>> {
            let mut session = connect_session(&host, port, use_tls, &creds)?;
            session.select(&mailbox)?;
            let fetches = session.uid_fetch(&uid.to_string(), "BODY.PEEK[]")?;
            let raw = fetches
                .iter()
                .find_map(|f| f.body().map(|b| b.to_vec()))
                .ok_or_else(|| SyncError::Other(format!("UID {uid} not found in {mailbox}")))?;
            let _ = session.logout();
            Ok(raw)
        })
        .await
        .map_err(|e| SyncError::Other(format!("join error: {e}")))?
    }

    /// Run a closure with a freshly-connected session (no mailbox selected).
    /// Used by `perform_action` for folder moves/copies.
    async fn with_session<F>(&self, f: F) -> Result<()>
    where
        F: FnOnce(&mut ImapSession) -> Result<()> + Send + 'static,
    {
        let host = self.conn.host.clone();
        let port = self.conn.port;
        let use_tls = self.conn.use_tls;
        let creds = self.conn.credentials.clone();
        tokio::task::spawn_blocking(move || -> Result<()> {
            let mut session = connect_session(&host, port, use_tls, &creds)?;
            let res = f(&mut session);
            let _ = session.logout();
            res
        })
        .await
        .map_err(|e| SyncError::Other(format!("join error: {e}")))?
    }
}

#[async_trait]
impl InteractiveProvider for ImapInteractive {
    async fn fetch_message(&self, message_key: &str) -> Result<FetchedMessage> {
        let (mailbox, uid) = self.locate(message_key)?;
        let raw = self.fetch_raw(&mailbox, uid).await?;
        let parsed = mime::parse_message(&raw);

        let plain = parsed.body_plain.clone();
        let mut html = parsed.body_html.clone();

        // Inline `cid:` images → data URIs embedded directly in the HTML.
        if let Some(mut h) = html.take() {
            for att in parsed.attachments.iter().filter(|a| a.is_inline) {
                if let Some(cid) = &att.content_id {
                    let data_uri = inline_image_data_uri(&att.mime_type, &att.data);
                    h = replace_cid(&h, cid, &data_uri);
                }
            }
            html = Some(h);
        }

        let attachments = parsed
            .attachments
            .iter()
            .filter(|a| !a.is_inline)
            .map(|a| AttachmentRef {
                attachment_id: a.part_id.clone(),
                filename: a.filename.clone(),
                mime_type: a.mime_type.clone(),
                size: a.size,
            })
            .collect();

        self.store
            .update_message_body(message_key, html.as_deref(), plain.as_deref())?;
        Ok(FetchedMessage { body_html: html, body_plain: plain, attachments })
    }

    async fn download_attachment(&self, message_key: &str, attachment_id: &str) -> Result<Vec<u8>> {
        let (mailbox, uid) = self.locate(message_key)?;
        let raw = self.fetch_raw(&mailbox, uid).await?;
        let parsed = mime::parse_message(&raw);
        parsed
            .attachments
            .into_iter()
            .find(|a| a.part_id == attachment_id)
            .map(|a| a.data)
            .ok_or_else(|| SyncError::Other(format!("attachment part {attachment_id} not found")))
    }

    async fn get_message_source(&self, message_key: &str) -> Result<String> {
        match self.locate(message_key) {
            Ok((mailbox, uid)) => match self.fetch_raw(&mailbox, uid).await {
                Ok(raw) => Ok(String::from_utf8_lossy(&raw).to_string()),
                // A real fetch failure must not be masked as an empty body —
                // fall back to the local copy only when one exists.
                Err(e) => {
                    log::warn!("IMAP message source fetch failed ({e}); trying the local cache");
                    self.store.local_message_source(message_key)?.ok_or(e)
                }
            },
            Err(_) => self
                .store
                .local_message_source(message_key)?
                .ok_or_else(|| SyncError::Other("message not found".into())),
        }
    }

    async fn send_message(&self, msg: &OutgoingMessage) -> Result<String> {
        let smtp_host = self
            .conn
            .smtp_host
            .clone()
            .ok_or_else(|| SyncError::Other("SMTP not configured for this account".into()))?;
        // Reuse the id minted at enqueue time so the local sent copy and the
        // APPENDed/synced Sent copy carry the same Message-ID.
        let message_id = msg
            .message_id
            .clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| format!("<{}@inbox2.local>", nanoid::nanoid!(24)));
        let email = build_smtp_message(msg, &message_id)?;

        let port = self.conn.smtp_port;
        let use_tls = self.conn.smtp_use_tls;
        let creds = self.conn.credentials.clone();
        let mid = message_id.clone();

        tokio::task::spawn_blocking(move || -> Result<String> {
            use lettre::transport::smtp::authentication::{Credentials, Mechanism};
            use lettre::{SmtpTransport, Transport};

            let mut builder = if use_tls {
                SmtpTransport::relay(&smtp_host)
                    .map_err(|e| SyncError::Other(format!("SMTP relay: {e}")))?
            } else {
                SmtpTransport::starttls_relay(&smtp_host)
                    .map_err(|e| SyncError::Other(format!("SMTP starttls: {e}")))?
            }
            .port(port);

            builder = match &creds {
                ProviderCredentials::Password { username, password } => {
                    builder.credentials(Credentials::new(username.clone(), password.clone()))
                }
                ProviderCredentials::OAuth2 { username, access_token, .. } => builder
                    .credentials(Credentials::new(username.clone(), access_token.clone()))
                    .authentication(vec![Mechanism::Xoauth2]),
                ProviderCredentials::Meta(_) => {
                    return Err(SyncError::Other("SMTP send not applicable to Meta channels".into()))
                }
            };

            let mailer = builder.build();
            match mailer.send(&email) {
                Ok(_) => Ok(mid),
                Err(e) => {
                    // SMTP 5xx = permanent (bad recipient, relay denied); map it
                    // onto the outbox's HTTP-style permanence check so it isn't
                    // retried 3× pointlessly. Transient (4xx / connection) stays
                    // retryable.
                    if e.is_permanent() {
                        Err(SyncError::HttpStatus { code: 400, context: format!("SMTP send: {e}") })
                    } else {
                        Err(SyncError::Other(format!("SMTP send: {e}")))
                    }
                }
            }
        })
        .await
        .map_err(|e| SyncError::Other(format!("join error: {e}")))?
    }

    /// APPEND to the Drafts folder flagged `\Draft \Seen`. IMAP returns no id:
    /// every version of a draft carries the same Message-ID, so the previous
    /// version is found by it and expunged first. A retry after a lost APPEND
    /// just appends again.
    async fn save_draft(&self, msg: &OutgoingMessage, _existing: Option<&str>) -> Result<String> {
        let drafts = self
            .store
            .get_folders_for_account(&self.account_key)?
            .into_iter()
            .find(|f| f.role == Some(WellKnownFolder::Drafts))
            .map(|f| f.provider_name)
            .unwrap_or_else(|| "Drafts".to_string());
        let mime = build_mime_message(msg);
        let message_id = msg.message_id.clone().filter(|m| !m.is_empty());
        self.with_session(move |session| {
            if let Some(mid) = message_id {
                session.select(&drafts)?;
                let old = session.uid_search(format!("HEADER Message-ID \"{}\"", mid.replace('"', "")))?;
                if !old.is_empty() {
                    let set = old.iter().map(|u| u.to_string()).collect::<Vec<_>>().join(",");
                    session.uid_store(&set, "+FLAGS (\\Deleted)")?;
                    // UID EXPUNGE removes just the old version; a plain EXPUNGE
                    // would also purge anything else flagged \Deleted in Drafts.
                    // Without UIDPLUS the old version stays flagged, hidden by clients.
                    let uidplus = session.capabilities().is_ok_and(|c| c.has_str("UIDPLUS"));
                    if uidplus {
                        session.uid_expunge(&set)?;
                    }
                }
            }
            session.append_with_flags(&drafts, mime.as_bytes(), &[imap::types::Flag::Draft, imap::types::Flag::Seen])?;
            Ok(())
        })
        .await?;
        Ok(String::new())
    }

    async fn perform_action(&self, provider_ids: &[String], action: &str) -> Result<()> {
        if provider_ids.is_empty() {
            return Ok(());
        }
        let folders = self.store.get_folders_for_account(&self.account_key)?;
        let role_folder = |role: WellKnownFolder, fallback: &str| -> String {
            folders
                .iter()
                .find(|f| f.role.as_ref() == Some(&role))
                .map(|f| f.provider_name.clone())
                .unwrap_or_else(|| fallback.to_string())
        };

        // The destination mailbox for the verb (None = a label/quadrant op).
        let target: Option<String> = match action {
            "spam" => Some(role_folder(WellKnownFolder::Spam, "Junk")),
            "untrash" | "unspam" | "unarchive" => Some(role_folder(WellKnownFolder::Inbox, "INBOX")),
            // Quadrant/triage maps onto label folders (the user's "labels →
            // folders" choice); applied per-message below.
            a if a == "clear_quadrant" || a.starts_with("set_quadrant:") => None,
            other => {
                log::warn!("IMAP perform_action: unsupported verb {other:?}; ignoring");
                return Ok(());
            }
        };

        // Resolve each provider id (Message-ID) to its current (mailbox, UID).
        let mut located = Vec::new();
        for pid in provider_ids {
            match self.store.provider_state_by_provider_id(&self.account_key, pid)? {
                Some((folder_key, uid)) => {
                    let mailbox = self.folder_name(&folder_key)?;
                    located.push((mailbox, uid, pid.clone()));
                }
                None => log::warn!("IMAP perform_action: no UID for {pid}; skipping"),
            }
        }
        if located.is_empty() {
            return Ok(());
        }

        let quadrant_folders = Quadrant::ALL.map(|q| q.folder_name().to_string());
        let action = action.to_string();
        self.with_session(move |session| {
            for (mailbox, uid, _pid) in &located {
                let uid_str = uid.to_string();
                session.select(mailbox)?;
                match &target {
                    Some(dest) => {
                        // Move: ensure dest, MOVE (or COPY+\Deleted+EXPUNGE).
                        if !dest.eq_ignore_ascii_case("INBOX") {
                            let _ = session.create(dest);
                        }
                        if session.uid_mv(&uid_str, dest).is_err() {
                            session.uid_copy(&uid_str, dest)?;
                            session.uid_store(&uid_str, "+FLAGS (\\Deleted)")?;
                            let _ = session.expunge();
                        }
                    }
                    None => {
                        // Quadrant as label-folders: clear membership of all four
                        // quadrant folders, then (for set) COPY into the target.
                        for qf in &quadrant_folders {
                            let _ = session.create(qf);
                        }
                        if let Some(key) = action.strip_prefix("set_quadrant:") {
                            if let Some(name) = Quadrant::from_str(key).map(Quadrant::folder_name) {
                                let _ = session.create(name);
                                session.uid_copy(&uid_str, name)?;
                            }
                        }
                        // clear_quadrant removes the copies in the *other* folders;
                        // handled by the next sync reconciling membership.
                    }
                }
            }
            Ok(())
        })
        .await
    }
}

/// Build a `lettre` SMTP message from an outgoing payload: a `text/plain` part,
/// a `multipart/alternative` when HTML is present, wrapped in `multipart/mixed`
/// when there are attachments.
fn build_smtp_message(m: &OutgoingMessage, message_id: &str) -> Result<lettre::Message> {
    use lettre::message::{header::ContentType, Attachment, Mailbox, MultiPart, SinglePart};

    let parse_one = |s: &str| -> Result<Mailbox> {
        s.trim()
            .parse::<Mailbox>()
            .map_err(|e| SyncError::HttpStatus { code: 400, context: format!("bad address {s:?}: {e}") })
    };
    // Quote-aware split: a `"Eryigit, Ömer" <o@x>` display name must not be
    // broken at its comma. lettre RFC 2047-encodes non-ASCII names itself.
    let parse_many = |s: &str| -> Result<Vec<Mailbox>> {
        split_address_list(s).iter().map(|p| parse_one(p)).collect()
    };

    let mut builder = lettre::Message::builder()
        .from(parse_one(&m.from_address)?)
        .message_id(Some(message_id.to_string()))
        .subject(m.subject.clone().unwrap_or_else(|| "(no subject)".into()));
    // RFC 5322 threading headers (replies) — lettre folds them itself.
    if let Some(irt) = m.in_reply_to.as_deref().filter(|s| !s.is_empty()) {
        builder = builder.in_reply_to(irt.to_string());
    }
    if let Some(refs) = m.references.as_deref().filter(|s| !s.is_empty()) {
        builder = builder.references(refs.to_string());
    }
    for to in parse_many(&m.to_address)? {
        builder = builder.to(to);
    }
    if let Some(cc) = &m.cc_address {
        for cc in parse_many(cc)? {
            builder = builder.cc(cc);
        }
    }
    // lettre adds Bcc recipients to the SMTP envelope (RCPT TO) without emitting
    // a Bcc header in the transmitted message, so they stay hidden.
    if let Some(bcc) = &m.bcc_address {
        for bcc in parse_many(bcc)? {
            builder = builder.bcc(bcc);
        }
    }

    let plain = m.body_plain.clone().unwrap_or_default();

    // The body: HTML present → alternative(plain, html); else a plain singlepart.
    let body: MultiPartOrSingle = match &m.body_html {
        Some(html) => MultiPartOrSingle::Multi(MultiPart::alternative_plain_html(plain, html.clone())),
        None => MultiPartOrSingle::Single(SinglePart::plain(plain)),
    };

    let email = if m.attachments.is_empty() {
        match body {
            MultiPartOrSingle::Multi(mp) => builder.multipart(mp),
            MultiPartOrSingle::Single(sp) => builder.singlepart(sp),
        }
    } else {
        let mut mixed = match body {
            MultiPartOrSingle::Multi(mp) => MultiPart::mixed().multipart(mp),
            MultiPartOrSingle::Single(sp) => MultiPart::mixed().singlepart(sp),
        };
        for att in &m.attachments {
            let ct = att
                .mime_type
                .as_deref()
                .and_then(|t| ContentType::parse(t).ok())
                .unwrap_or(ContentType::parse("application/octet-stream").unwrap());
            mixed = mixed
                .singlepart(Attachment::new(att.filename.clone()).body(att.data.clone(), ct));
        }
        builder.multipart(mixed)
    };

    email.map_err(|e| SyncError::HttpStatus { code: 400, context: format!("build message: {e}") })
}

enum MultiPartOrSingle {
    Multi(lettre::message::MultiPart),
    Single(lettre::message::SinglePart),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoded_words_stay_within_the_rfc_2047_length_cap() {
        // 60 Han characters = 180 UTF-8 bytes; as one encoded-word that is a
        // 252-char header token, four times the RFC 2047 §2 limit.
        let subject = "订".repeat(60);
        let encoded = encode_header_text(&subject);
        for word in encoded.split("\r\n ") {
            assert!(word.len() <= 75, "encoded-word over 75 chars: {} chars", word.len());
            assert!(word.starts_with("=?UTF-8?B?") && word.ends_with("?="));
            // Every word must decode standalone — no character split across two.
            let b64 = &word["=?UTF-8?B?".len()..word.len() - 2];
            let bytes = base64::engine::general_purpose::STANDARD.decode(b64).expect("valid base64");
            assert!(std::str::from_utf8(&bytes).is_ok(), "encoded-word cut a character in half");
        }
        // Round-trips to the original text.
        let rejoined: String = encoded
            .split("\r\n ")
            .map(|w| {
                let b64 = &w["=?UTF-8?B?".len()..w.len() - 2];
                String::from_utf8(base64::engine::general_purpose::STANDARD.decode(b64).unwrap()).unwrap()
            })
            .collect();
        assert_eq!(rejoined, subject);
    }

    #[test]
    fn ascii_headers_are_left_alone() {
        assert_eq!(encode_header_text("Re: invoice"), "Re: invoice");
    }

    #[test]
    fn mime_params_use_rfc_2231_for_non_ascii() {
        assert_eq!(encode_mime_param("filename", "report.pdf"), "filename=\"report.pdf\"");
        // Arabic "ملف.pdf" — extended syntax, never an RFC 2047 encoded-word.
        let p = encode_mime_param("filename", "ملف.pdf");
        assert!(p.starts_with("filename*=UTF-8''"), "got {p}");
        assert!(!p.contains("=?UTF-8?B?"));
        assert!(p.ends_with(".pdf"), "unreserved chars stay literal: {p}");
    }

    fn outgoing(html: Option<&str>, attachments: Vec<OutgoingAttachment>) -> OutgoingMessage {
        OutgoingMessage {
            from_address: "Me <me@x.com>".into(),
            to_address: "you@x.com, them@y.com".into(),
            cc_address: Some("cc@x.com".into()),
            bcc_address: None,
            subject: Some("Hi".into()),
            body_html: html.map(String::from),
            body_plain: Some("plain text".into()),
            attachments,
            ..Default::default()
        }
    }

    #[test]
    fn build_smtp_plain_only_sets_headers() {
        let m = outgoing(None, vec![]);
        let email = build_smtp_message(&m, "<id@inbox2.local>").unwrap();
        let raw = String::from_utf8(email.formatted()).unwrap();
        assert!(raw.contains("From: Me <me@x.com>"));
        assert!(raw.contains("you@x.com"));
        assert!(raw.contains("them@y.com"));
        assert!(raw.contains("Cc: cc@x.com"));
        assert!(raw.contains("Subject: Hi"));
        assert!(raw.contains("Message-ID: <id@inbox2.local>"));
        assert!(raw.contains("plain text"));
    }

    // Reply threading: both builders must emit the RFC 5322 headers, or every
    // reply starts a new thread for us AND every recipient (the Furlan/tcrmbo
    // regression). The MIME builder folds References at the Message-IDs so a
    // long chain can't near the 998-char line limit.
    #[test]
    fn build_smtp_sets_threading_headers() {
        let mut m = outgoing(None, vec![]);
        m.in_reply_to = Some("<p2@x>".into());
        m.references = Some("<p1@x> <p2@x>".into());
        let raw = String::from_utf8(build_smtp_message(&m, "<id@x>").unwrap().formatted()).unwrap();
        assert!(raw.contains("In-Reply-To: <p2@x>"));
        assert!(raw.contains("References: <p1@x> <p2@x>"));
    }

    #[test]
    fn build_mime_sets_threading_headers_folded() {
        let mut m = outgoing(None, vec![]);
        m.in_reply_to = Some("<p2@x>".into());
        m.references = Some("<p1@x> <p2@x>".into());
        let mime = build_mime_message(&m);
        assert!(mime.contains("In-Reply-To: <p2@x>"));
        assert!(mime.contains("References: <p1@x>\r\n <p2@x>"));
    }

    #[test]
    fn build_mime_omits_threading_headers_for_new_mail() {
        let mime = build_mime_message(&outgoing(None, vec![]));
        assert!(!mime.contains("In-Reply-To:"));
        assert!(!mime.contains("References:"));
    }

    #[test]
    fn build_smtp_html_is_multipart_alternative() {
        let m = outgoing(Some("<p>hi</p>"), vec![]);
        let raw = String::from_utf8(build_smtp_message(&m, "<id@x>").unwrap().formatted()).unwrap();
        assert!(raw.contains("multipart/alternative"));
        assert!(raw.contains("text/html"));
    }

    #[test]
    fn build_smtp_with_attachment_is_multipart_mixed() {
        let m = outgoing(
            Some("<p>hi</p>"),
            vec![OutgoingAttachment {
                filename: "doc.pdf".into(),
                mime_type: Some("application/pdf".into()),
                data: b"PDFDATA".to_vec(),
            }],
        );
        let raw = String::from_utf8(build_smtp_message(&m, "<id@x>").unwrap().formatted()).unwrap();
        assert!(raw.contains("multipart/mixed"));
        assert!(raw.contains("doc.pdf"));
        assert!(raw.contains("application/pdf"));
    }

    #[test]
    fn build_smtp_rejects_bad_recipient_as_permanent() {
        let mut m = outgoing(None, vec![]);
        m.to_address = "not-an-email".into();
        let err = build_smtp_message(&m, "<id@x>").unwrap_err();
        assert!(err.is_permanent(), "bad address should be a permanent failure");
    }

    #[test]
    fn replace_cid_is_case_insensitive_and_global() {
        let html = r#"<img src="cid:ABC"><img src="CID:ABC">"#;
        let out = replace_cid(html, "ABC", "data:x");
        assert_eq!(out, r#"<img src="data:x"><img src="data:x">"#);
    }

    #[test]
    fn small_inline_image_passes_through_unchanged() {
        // Below the threshold: exact bytes preserved (logos keep transparency).
        let bytes = vec![0u8; 1024];
        let uri = inline_image_data_uri("image/png", &bytes);
        assert_eq!(uri, format!("data:image/png;base64,{}", b64_std(&bytes)));
    }

    #[test]
    fn oversized_inline_image_is_downscaled_to_jpeg() {
        // A noisy 2000×2000 PNG that won't compress small — must exceed the cap.
        let mut img = image::RgbImage::new(2000, 2000);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = image::Rgb([(x ^ y) as u8, x.wrapping_mul(3) as u8, y.wrapping_mul(7) as u8]);
        }
        let mut png = Vec::new();
        image::DynamicImage::ImageRgb8(img)
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        assert!(png.len() > INLINE_IMG_MAX_BYTES, "fixture {} must exceed cap", png.len());

        let uri = inline_image_data_uri("image/png", &png);
        assert!(uri.starts_with("data:image/jpeg;base64,"), "oversized png → jpeg");
        let encoded = uri.len() - "data:image/jpeg;base64,".len();
        assert!(encoded * 3 / 4 < png.len(), "re-encoded payload must be smaller");
    }

    #[test]
    fn undecodable_oversized_passes_through() {
        // Over the cap but not a real image (or a type we won't touch): unchanged.
        let junk = vec![7u8; INLINE_IMG_MAX_BYTES + 10];
        let uri = inline_image_data_uri("image/png", &junk);
        assert_eq!(uri, format!("data:image/png;base64,{}", b64_std(&junk)));
        let svg = vec![1u8; INLINE_IMG_MAX_BYTES + 10];
        let uri = inline_image_data_uri("image/svg+xml", &svg);
        assert_eq!(uri, format!("data:image/svg+xml;base64,{}", b64_std(&svg)));
    }

    #[test]
    fn build_mime_plain_only() {
        let m = OutgoingMessage {
            from_address: "me@x.com".into(),
            to_address: "you@x.com".into(),
            cc_address: None,
            bcc_address: None,
            subject: Some("Hi".into()),
            body_html: None,
            body_plain: Some("hello".into()),
            attachments: vec![],
            ..Default::default()
        };
        let mime = build_mime_message(&m);
        assert!(mime.contains("From: me@x.com"));
        assert!(mime.contains("To: you@x.com"));
        assert!(mime.contains("Subject: Hi"));
        assert!(mime.contains("text/plain"));
        assert!(mime.contains("hello"));
    }

    #[test]
    fn build_mime_with_attachment_is_multipart_mixed() {
        let m = OutgoingMessage {
            from_address: "me@x.com".into(),
            to_address: "you@x.com".into(),
            cc_address: Some("cc@x.com".into()),
            bcc_address: None,
            subject: Some("Hi".into()),
            body_html: Some("<p>hi</p>".into()),
            body_plain: Some("hi".into()),
            attachments: vec![OutgoingAttachment {
                filename: "a.txt".into(),
                mime_type: Some("text/plain".into()),
                data: b"DATA".to_vec(),
            }],
            ..Default::default()
        };
        let mime = build_mime_message(&m);
        assert!(mime.contains("multipart/mixed"));
        assert!(mime.contains("Cc: cc@x.com"));
        assert!(mime.contains("Content-Disposition: attachment; filename=\"a.txt\""));
        assert!(mime.contains(&base64::engine::general_purpose::STANDARD.encode(b"DATA")));
    }

    #[test]
    fn build_mime_encodes_non_ascii_headers() {
        let m = OutgoingMessage {
            from_address: "me@x.com".into(),
            to_address: "Ahmet Akca <a@x.nl>, \"Ömer Eryigit\" <o@x.nl>".into(),
            cc_address: None,
            bcc_address: None,
            subject: Some("Rendez-vous café".into()),
            body_html: None,
            body_plain: Some("hello".into()),
            attachments: vec![],
            ..Default::default()
        };
        let mime = build_mime_message(&m);
        // ASCII mailbox passes through untouched; non-ASCII display name is
        // RFC 2047 B-encoded with the bare address kept outside the word.
        assert!(mime.contains("To: Ahmet Akca <a@x.nl>, =?UTF-8?B?w5ZtZXIgRXJ5aWdpdA==?= <o@x.nl>"));
        assert!(mime.contains("Subject: =?UTF-8?B?UmVuZGV6LXZvdXMgY2Fmw6k=?="));
        // No raw non-ASCII bytes may remain in the header block.
        let headers = mime.split("\r\n\r\n").next().unwrap();
        assert!(headers.is_ascii(), "headers must be ASCII: {headers}");
    }

    #[test]
    fn build_mime_bodies_are_wire_safe() {
        // A kilometre-long single HTML line with non-ASCII — exactly what the
        // compose editor produces. The wire form must be 7-bit clean with
        // every line within the SMTP 998-char limit.
        let long_html = format!("<p>{}</p>", "café et thé ".repeat(300));
        let m = OutgoingMessage {
            from_address: "me@x.com".into(),
            to_address: "you@x.com".into(),
            cc_address: None,
            bcc_address: None,
            subject: Some("Hi".into()),
            body_html: Some(long_html),
            body_plain: Some("café\net thé".into()),
            attachments: vec![OutgoingAttachment {
                filename: "a.bin".into(),
                mime_type: None,
                data: vec![0u8; 600], // base64 > 76 chars, must be wrapped
            }],
            ..Default::default()
        };
        let mime = build_mime_message(&m);
        assert!(mime.is_ascii(), "message must be 7-bit clean");
        assert!(mime.contains("Content-Transfer-Encoding: quoted-printable"));
        for line in mime.split("\r\n") {
            assert!(line.len() <= 998, "line exceeds SMTP limit ({}): {line}", line.len());
        }
        // Round-trip: mailparse must recover the original body text.
        let parsed = mailparse::parse_mail(mime.as_bytes()).unwrap();
        let alt = &parsed.subparts[0];
        let plain = alt.subparts[0].get_body().unwrap();
        assert_eq!(plain.trim_end_matches("\r\n"), "café\net thé");
        let html = alt.subparts[1].get_body().unwrap();
        assert!(html.contains("café et thé"));
    }

    #[test]
    fn build_mime_encodes_non_ascii_attachment_filename() {
        let m = OutgoingMessage {
            from_address: "me@x.com".into(),
            to_address: "you@x.com".into(),
            cc_address: None,
            bcc_address: None,
            subject: Some("Hi".into()),
            body_html: None,
            body_plain: Some("see attached".into()),
            attachments: vec![OutgoingAttachment {
                filename: "Verslag café.pdf".into(),
                mime_type: Some("application/pdf".into()),
                data: b"PDF".to_vec(),
            }],
            ..Default::default()
        };
        let mime = build_mime_message(&m);
        // RFC 2231 extended parameter, not an RFC 2047 encoded-word: encoded-words
        // are not valid syntax inside a parameter value, and strict clients
        // display `filename="=?UTF-8?B?...?="` literally.
        assert!(
            mime.contains("filename*=UTF-8''Verslag%20caf%C3%A9.pdf"),
            "expected RFC 2231 filename, got:\n{mime}"
        );
        assert!(mime.contains("name*=UTF-8''Verslag%20caf%C3%A9.pdf"));
        assert!(!mime.contains("=?UTF-8?B?VmVyc2xhZyBjYWbDqS5wZGY=?="), "encoded-word in a parameter value");
        assert!(!mime.contains("café"), "raw non-ASCII filename leaked into part headers");
    }

    #[test]
    fn build_smtp_handles_quoted_comma_display_name() {
        let m = OutgoingMessage {
            from_address: "me@x.com".into(),
            to_address: "\"Eryigit, Ömer\" <o@x.nl>, b@y.com".into(),
            cc_address: None,
            bcc_address: None,
            subject: Some("Hi".into()),
            body_html: None,
            body_plain: Some("hello".into()),
            attachments: vec![],
            ..Default::default()
        };
        let email = build_smtp_message(&m, "<id@inbox2.local>").unwrap();
        let rendered = String::from_utf8(email.formatted()).unwrap();
        // Both mailboxes survive the split; the name is not broken at its comma.
        assert!(rendered.contains("o@x.nl"));
        assert!(rendered.contains("b@y.com"));
    }

    #[test]
    fn split_address_list_respects_quoted_commas() {
        assert_eq!(
            split_address_list(r#""Eryigit, Ömer" <o@x.nl>, b@y.com"#),
            vec![r#""Eryigit, Ömer" <o@x.nl>"#.to_string(), "b@y.com".to_string()]
        );
    }

    #[test]
    fn collect_attachments_skips_inline_images() {
        let payload = serde_json::json!({
            "mimeType": "multipart/mixed",
            "parts": [
                {
                    "mimeType": "image/png",
                    "filename": "inline.png",
                    "headers": [{ "name": "Content-ID", "value": "<img1>" }],
                    "body": { "attachmentId": "att-inline", "size": 10 }
                },
                {
                    "mimeType": "application/pdf",
                    "filename": "doc.pdf",
                    "body": { "attachmentId": "att-pdf", "size": 100 }
                }
            ]
        });
        let mut atts = Vec::new();
        collect_attachments(&payload, None, &mut atts);
        assert_eq!(atts.len(), 1);
        assert_eq!(atts[0].filename, "doc.pdf");
    }

    #[test]
    fn collect_inline_images_finds_cid_parts() {
        let payload = serde_json::json!({
            "parts": [{
                "mimeType": "image/jpeg",
                "headers": [{ "name": "Content-ID", "value": "<logo>" }],
                "body": { "attachmentId": "att-logo" }
            }]
        });
        let mut imgs = Vec::new();
        collect_inline_images(&payload, &mut imgs);
        assert_eq!(imgs.len(), 1);
        assert_eq!(imgs[0].content_id, "logo");
        assert_eq!(imgs[0].attachment_id, "att-logo");
    }
}

// ===========================================================================
// Meta (Instagram / Messenger / WhatsApp)
// ===========================================================================

use crate::sync::adapters::meta::MetaAdapter;
use crate::sync::meta_normalize::{self, NormalizedMessage};
use crate::sync::model::{MetaChannel, MetaCredentials, UnifiedMessage};

/// Interactive (send + comment moderation) surface for the Meta channels.
///
/// Wraps a [`MetaAdapter`] for its Graph client (token injection, pinned version,
/// typed error mapping). Send dispatches per channel; `perform_action` carries
/// the Meta verbs `hide_comment`/`unhide_comment`/`delete_comment`,
/// `react:<emoji>` (WhatsApp), and `mark_read` (WhatsApp). Reads (`fetch_message`)
/// return the already-stored body — Meta bodies are persisted at normalize time,
/// so there is no lazy-body round-trip.
pub struct MetaInteractive {
    adapter: MetaAdapter,
    store: Arc<SyncStore>,
    account_key: String,
}

impl MetaInteractive {
    pub fn new(channel: MetaChannel, creds: MetaCredentials, store: Arc<SyncStore>, account_key: String) -> Self {
        Self {
            adapter: MetaAdapter::new(channel, creds, store.clone(), account_key.clone()),
            store,
            account_key,
        }
    }

    /// Test helper: point the wrapped Graph client at a mock server.
    #[cfg(test)]
    pub fn with_base(mut self, api_base: String) -> Self {
        self.adapter = self.adapter.with_base(api_base);
        self
    }

    fn creds(&self) -> &MetaCredentials {
        self.adapter.creds()
    }

    /// The Graph node that sends/receives for this channel: WhatsApp phone-number
    /// id, Facebook Page id (Messenger), or Instagram account id.
    fn send_node(&self) -> Result<String> {
        let c = self.creds();
        let id = match self.adapter.channel() {
            MetaChannel::WhatsApp => c.whatsapp_phone_number_id.as_deref(),
            MetaChannel::Messenger => c.facebook_page_id.as_deref(),
            MetaChannel::Instagram => c.instagram_account_id.as_deref(),
        };
        id.filter(|s| !s.is_empty())
            .map(str::to_string)
            .ok_or_else(|| SyncError::Other("Meta: missing asset id for channel".into()))
    }

    /// The local Message-ID (== Meta id) of the parent a reply targets, resolved
    /// from `reply_to_message_key`, falling back to an explicit `in_reply_to`.
    fn reply_target(&self, msg: &OutgoingMessage) -> Option<String> {
        if let Some(key) = &msg.reply_to_message_key {
            let conn = self.store.connection();
            let conn = conn.lock();
            if let Ok(mid) = conn.query_row(
                "SELECT message_id_header FROM messages WHERE key = ?1",
                rusqlite::params![key],
                |r| r.get::<_, Option<String>>(0),
            ) {
                if let Some(mid) = mid {
                    return Some(mid);
                }
            }
        }
        msg.in_reply_to.clone()
    }

    /// The conversation reply-target (cs_recipient_id, e.g. a WhatsApp wa_id) for
    /// the message whose provider id is `provider_message_id`. Used by WhatsApp
    /// reactions, which must address the customer, not the message.
    fn recipient_for_provider_message(&self, provider_message_id: &str) -> Option<String> {
        let conn = self.store.connection();
        let conn = conn.lock();
        conn.query_row(
            "SELECT c.cs_recipient_id
             FROM message_provider_state ps
             JOIN messages m ON m.key = ps.message_key
             JOIN conversations c ON c.key = m.conversation_key
             WHERE ps.provider_message_id = ?1 AND ps.account_key = ?2
             LIMIT 1",
            rusqlite::params![provider_message_id, self.account_key],
            |r| r.get::<_, Option<String>>(0),
        )
        .ok()
        .flatten()
    }

    async fn send_whatsapp(&self, node: &str, msg: &OutgoingMessage) -> Result<String> {
        let mut body = serde_json::json!({
            "messaging_product": "whatsapp",
            "recipient_type": "individual",
            "to": msg.to_address,
        });
        if let Some(name) = &msg.meta_template_name {
            // Out-of-window template message.
            let mut template = serde_json::json!({
                "name": name,
                "language": { "code": msg.meta_template_language.as_deref().unwrap_or("en_US") },
            });
            if let Some(components) = &msg.meta_template_components {
                template["components"] = components.clone();
            }
            body["type"] = serde_json::json!("template");
            body["template"] = template;
        } else {
            // In-window session text.
            body["type"] = serde_json::json!("text");
            body["text"] = serde_json::json!({ "body": msg.body_plain.clone().unwrap_or_default() });
            if let Some(ctx) = self.reply_target(msg) {
                body["context"] = serde_json::json!({ "message_id": ctx });
            }
        }
        let resp = self.adapter.graph_post(&format!("{node}/messages"), &body, "WhatsApp send").await?;
        Ok(resp
            .get("messages")
            .and_then(|m| m.as_array())
            .and_then(|a| a.first())
            .and_then(|m| m.get("id"))
            .and_then(|i| i.as_str())
            .unwrap_or_default()
            .to_string())
    }

    async fn send_chat(&self, node: &str, msg: &OutgoingMessage, token: &str) -> Result<String> {
        // Messenger + Instagram DMs share the Send API shape. `messaging_type` is
        // RESPONSE within the 24h window; an out-of-window send carries a message
        // tag (e.g. HUMAN_AGENT) when the caller supplies one.
        let mut body = serde_json::json!({
            "recipient": { "id": msg.to_address },
            "message": { "text": msg.body_plain.clone().unwrap_or_default() },
        });
        if let Some(tag) = msg.meta_message_tag.as_deref().filter(|t| !t.is_empty()) {
            body["messaging_type"] = serde_json::json!("MESSAGE_TAG");
            body["tag"] = serde_json::json!(tag);
        } else {
            body["messaging_type"] = serde_json::json!("RESPONSE");
        }
        let resp = self.adapter.graph_post_as(&format!("{node}/messages"), &body, "Meta send", token).await?;
        Ok(resp
            .get("message_id")
            .and_then(|i| i.as_str())
            .unwrap_or_default()
            .to_string())
    }

    /// Instagram-Login DM send: `POST /me/messages` on graph.instagram.com with the
    /// OAuth user token (vs the Page-token Facebook path).
    async fn send_ig_login(&self, msg: &OutgoingMessage) -> Result<String> {
        let body = serde_json::json!({
            "recipient": { "id": msg.to_address },
            "message": { "text": msg.body_plain.clone().unwrap_or_default() },
        });
        let resp = self.adapter.ig_post("me/messages", &body, "IG send").await?;
        Ok(resp
            .get("message_id")
            .and_then(|i| i.as_str())
            .unwrap_or_default()
            .to_string())
    }

    /// The Page access token for Page-scoped calls (Messenger/IG send + comment
    /// moderation), falling back to the System User token if none is returned.
    async fn page_bearer(&self) -> Result<String> {
        Ok(self
            .adapter
            .page_access_token()
            .await?
            .unwrap_or_else(|| self.creds().system_user_token.clone()))
    }

    /// Persist a just-sent outbound message into its conversation so the reply
    /// shows in the thread (Meta has no Sent-folder sync). Threads on the same key
    /// as inbound messages from this recipient. Best-effort.
    fn record_outbound(&self, msg: &OutgoingMessage, provider_message_id: &str) {
        use meta_normalize::{channel, kind};
        let (chan, prefix) = match self.adapter.channel() {
            MetaChannel::WhatsApp => (channel::WHATSAPP, "wa"),
            MetaChannel::Messenger => (channel::MESSENGER, "messenger"),
            MetaChannel::Instagram => (channel::INSTAGRAM, "ig"),
        };
        // Thread on the same key inbound uses for this recipient, mark outbound.
        let mut unified: UnifiedMessage = meta_normalize::build_msg(
            provider_message_id,
            format!("{prefix}:{}", msg.to_address),
            "me".to_string(),
            msg.body_plain.clone().unwrap_or_default(),
            None,
            false,
        );
        unified.to_address = Some(msg.to_address.clone());
        unified.in_reply_to = msg.in_reply_to.clone();
        let nm = NormalizedMessage {
            msg: unified,
            provider_id: meta_normalize::pid(provider_message_id),
            channel: chan,
            kind: kind::DM,
            recipient_id: None,
            window_inbound_at: None,
            media: None,
        };
        let folder_key = format!("{}::inbox", self.account_key);
        if let Err(e) = self.store.apply_meta_message(&self.account_key, &folder_key, &nm) {
            log::warn!("[meta] record outbound failed: {e}");
        }
    }
}

#[async_trait]
impl InteractiveProvider for MetaInteractive {
    async fn fetch_message(&self, message_key: &str) -> Result<FetchedMessage> {
        // Meta bodies are persisted at normalize time — return the stored body.
        // WhatsApp media (delivered by id) is exposed as downloadable attachments
        // (the id is the attachment_id); Messenger/IG media is already inline HTML.
        let (plain, html, media): (Option<String>, Option<String>, Option<String>) = {
            let conn = self.store.connection();
            let conn = conn.lock();
            conn.query_row(
                "SELECT body_plain, body_html, meta_media FROM messages WHERE key = ?1",
                rusqlite::params![message_key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .map_err(|_| SyncError::Other("message not found".into()))?
        };
        let attachments = media
            .as_deref()
            .and_then(|j| serde_json::from_str::<Vec<Value>>(j).ok())
            .map(|items| {
                items
                    .iter()
                    .filter_map(|a| {
                        let id = a.get("id").and_then(|x| x.as_str())?;
                        Some(AttachmentRef {
                            attachment_id: id.to_string(),
                            filename: a.get("name").and_then(|x| x.as_str()).unwrap_or(id).to_string(),
                            mime_type: a.get("mime").and_then(|x| x.as_str()).unwrap_or_default().to_string(),
                            size: 0,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(FetchedMessage { body_html: html, body_plain: plain, attachments })
    }

    async fn download_attachment(&self, _message_key: &str, attachment_id: &str) -> Result<Vec<u8>> {
        // WhatsApp Media API is a two-step fetch: GET /{media_id} returns a
        // short-lived, token-authed URL; then GET that URL (same bearer) for the
        // bytes. Messenger/IG media is plain URLs rendered inline, not via here.
        if !matches!(self.adapter.channel(), MetaChannel::WhatsApp) {
            return Err(SyncError::NotImplemented("Meta attachment download (non-WhatsApp)".into()));
        }
        let meta = self.adapter.graph_get(attachment_id, "WhatsApp media url").await?;
        let url = meta
            .get("url")
            .and_then(|u| u.as_str())
            .ok_or_else(|| SyncError::Other("WhatsApp media: no url".into()))?;
        self.adapter.download_bytes(url).await
    }

    async fn get_message_source(&self, message_key: &str) -> Result<String> {
        // No RFC822 source for Meta — surface the stored plain body.
        Ok(self.fetch_message(message_key).await?.body_plain.unwrap_or_default())
    }

    async fn send_message(&self, msg: &OutgoingMessage) -> Result<String> {
        let node = self.send_node()?;
        let id = match self.adapter.channel() {
            MetaChannel::WhatsApp => self.send_whatsapp(&node, msg).await?,
            // Instagram-Login posts to /me/messages on graph.instagram.com with the
            // OAuth user token. The Facebook path (Messenger + legacy IG) posts to
            // /{node}/messages with the Page token.
            MetaChannel::Instagram if self.adapter.ig_login() => self.send_ig_login(msg).await?,
            MetaChannel::Messenger | MetaChannel::Instagram => {
                let token = self.page_bearer().await?;
                self.send_chat(&node, msg, &token).await?
            }
        };
        // Meta has no Sent-folder sync and we drop inbound echoes, so record the
        // sent reply locally — otherwise it vanishes from the thread after sending.
        if !id.is_empty() {
            self.record_outbound(msg, &id);
        }
        Ok(id)
    }

    async fn perform_action(&self, provider_ids: &[String], action: &str) -> Result<()> {
        // Comment moderation hits Page/IG-owned nodes, which require the Page
        // access token (Meta 190/210 with the System User token). Resolve once.
        let page_token = if matches!(action, "hide_comment" | "unhide_comment" | "delete_comment") {
            Some(self.page_bearer().await?)
        } else {
            None
        };
        for id in provider_ids {
            match action {
                "hide_comment" | "unhide_comment" => {
                    let hidden = action == "hide_comment";
                    self.adapter
                        .graph_post_as(
                            id,
                            &serde_json::json!({ "is_hidden": hidden }),
                            "Meta hide comment",
                            page_token.as_deref().unwrap_or_else(|| self.creds().system_user_token.as_str()),
                        )
                        .await?;
                }
                "delete_comment" => {
                    self.adapter
                        .graph_delete_as(id, "Meta delete comment", page_token.as_deref().unwrap_or_else(|| self.creds().system_user_token.as_str()))
                        .await?;
                }
                "mark_read" => {
                    // WhatsApp read receipt.
                    let node = self.send_node()?;
                    let body = serde_json::json!({
                        "messaging_product": "whatsapp",
                        "status": "read",
                        "message_id": id,
                    });
                    self.adapter.graph_post(&format!("{node}/messages"), &body, "WhatsApp mark read").await?;
                }
                other if other.starts_with("react:") => {
                    // WhatsApp reaction: react:<emoji> ("" clears the reaction).
                    // The reaction is addressed to the *customer* (wa_id), with
                    // the target message in `reaction.message_id`.
                    let emoji = other.strip_prefix("react:").unwrap_or("");
                    let to = self
                        .recipient_for_provider_message(id)
                        .ok_or_else(|| SyncError::Other("Meta react: unknown recipient for message".into()))?;
                    let node = self.send_node()?;
                    let body = serde_json::json!({
                        "messaging_product": "whatsapp",
                        "recipient_type": "individual",
                        "to": to,
                        "type": "reaction",
                        "reaction": { "message_id": id, "emoji": emoji },
                    });
                    self.adapter.graph_post(&format!("{node}/messages"), &body, "WhatsApp react").await?;
                }
                _ => {
                    log::warn!("[meta] unsupported perform_action verb: {action}");
                    return Err(SyncError::NotImplemented(format!("Meta action: {action}")));
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod meta_interactive_tests {
    use super::*;
    use crate::sync::model::MetaCredentials;
    use crate::sync::store::SyncStore;
    use wiremock::matchers::{body_partial_json, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn creds() -> MetaCredentials {
        MetaCredentials {
            app_id: "app".into(),
            app_secret: "secret".into(),
            system_user_token: "tok".into(),
            facebook_page_id: Some("PAGE".into()),
            instagram_account_id: Some("IG".into()),
            whatsapp_phone_number_id: Some("PNID".into()),
            whatsapp_business_account_id: Some("WABA".into()),
            ..Default::default()
        }
    }

    fn interactive(server: &MockServer, channel: MetaChannel) -> MetaInteractive {
        let store = std::sync::Arc::new(SyncStore::new_in_memory().unwrap());
        MetaInteractive::new(channel, creds(), store, "acc_test".into()).with_base(server.uri())
    }

    #[tokio::test]
    async fn whatsapp_session_text_send() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/PNID/messages"))
            .and(body_partial_json(serde_json::json!({"type":"text","to":"15551234567","text":{"body":"hi"}})))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "messages": [{ "id": "wamid.sent1" }]
            })))
            .mount(&server)
            .await;

        let wa = interactive(&server, MetaChannel::WhatsApp);
        let msg = OutgoingMessage {
            to_address: "15551234567".into(),
            body_plain: Some("hi".into()),
            ..Default::default()
        };
        assert_eq!(wa.send_message(&msg).await.unwrap(), "wamid.sent1");
    }

    #[tokio::test]
    async fn whatsapp_template_send_when_out_of_window() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/PNID/messages"))
            .and(body_partial_json(serde_json::json!({"type":"template","template":{"name":"hello"}})))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "messages": [{ "id": "wamid.tmpl" }]
            })))
            .mount(&server)
            .await;

        let wa = interactive(&server, MetaChannel::WhatsApp);
        let msg = OutgoingMessage {
            to_address: "15551234567".into(),
            meta_template_name: Some("hello".into()),
            meta_template_language: Some("en_US".into()),
            ..Default::default()
        };
        assert_eq!(wa.send_message(&msg).await.unwrap(), "wamid.tmpl");
    }

    #[tokio::test]
    async fn messenger_send_uses_page_node_and_recipient() {
        let server = MockServer::start().await;
        // Messenger sends authenticate with the Page access token.
        Mock::given(method("GET"))
            .and(path("/PAGE"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"access_token": "PAGE_TOKEN"})))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/PAGE/messages"))
            .and(body_partial_json(serde_json::json!({"recipient":{"id":"PSID"},"message":{"text":"yo"}})))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "message_id": "mid.sent"
            })))
            .mount(&server)
            .await;

        let m = interactive(&server, MetaChannel::Messenger);
        let msg = OutgoingMessage { to_address: "PSID".into(), body_plain: Some("yo".into()), ..Default::default() };
        assert_eq!(m.send_message(&msg).await.unwrap(), "mid.sent");
    }

    #[tokio::test]
    async fn hide_and_delete_comment() {
        let server = MockServer::start().await;
        // Comment moderation authenticates with the Page access token.
        Mock::given(method("GET"))
            .and(path("/PAGE"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"access_token": "PAGE_TOKEN"})))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/comment_123"))
            .and(body_partial_json(serde_json::json!({"is_hidden": true})))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"success": true})))
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .and(path("/comment_456"))
            .respond_with(ResponseTemplate::new(200).set_body_string("true"))
            .mount(&server)
            .await;

        let fb = interactive(&server, MetaChannel::Messenger);
        fb.perform_action(&["comment_123".into()], "hide_comment").await.unwrap();
        fb.perform_action(&["comment_456".into()], "delete_comment").await.unwrap();
    }

    #[tokio::test]
    async fn whatsapp_mark_read() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/PNID/messages"))
            .and(body_partial_json(serde_json::json!({"status":"read","message_id":"wamid.in"})))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"success": true})))
            .mount(&server)
            .await;

        let wa = interactive(&server, MetaChannel::WhatsApp);
        wa.perform_action(&["wamid.in".into()], "mark_read").await.unwrap();
    }

    #[tokio::test]
    async fn graph_error_surfaces_as_auth() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/PNID/messages"))
            .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                "error": { "code": 190, "message": "Invalid OAuth access token" }
            })))
            .mount(&server)
            .await;

        let wa = interactive(&server, MetaChannel::WhatsApp);
        let msg = OutgoingMessage { to_address: "1".into(), body_plain: Some("x".into()), ..Default::default() };
        let err = wa.send_message(&msg).await.unwrap_err();
        assert!(err.is_auth(), "Meta token error must flag re-auth, got {err:?}");
    }
}

// The Gmail/Microsoft interactive `get_json` helpers route through the shared
// `parse_json_response`, so a non-2xx response now carries its HTTP status code
// (→ is_auth/is_permanent) instead of collapsing into an opaque error. Use 403
// and 500: unlike 401 they don't trigger a token-refresh retry, so the test is
// hermetic against the wiremock server.
#[cfg(test)]
mod interactive_http_tests {
    use super::*;
    use crate::sync::model::{AccountStatus, AuthMethod, ExternalAccount, ProviderType};
    use crate::sync::store::SyncStore;
    use tokio::sync::RwLock;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn account(store: &Arc<SyncStore>, pt: ProviderType) -> String {
        store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: "T".into(),
                email_address: "u@x.com".into(),
                provider_type: pt,
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
            .unwrap()
    }

    fn token_for(store: &Arc<SyncStore>, account_key: &str, pt: ProviderType) -> Arc<TokenManager> {
        let creds = ProviderCredentials::OAuth2 {
            username: "u@x.com".into(),
            access_token: "tok".into(),
            refresh_token: Some("r".into()),
        };
        Arc::new(TokenManager::new(
            account_key.to_string(),
            pt,
            store.clone(),
            Arc::new(RwLock::new(None)),
            &creds,
        ))
    }

    #[tokio::test]
    async fn gmail_get_json_preserves_status_code() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/x"))
            .respond_with(ResponseTemplate::new(403))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/y"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let acct = account(&store, ProviderType::Gmail);
        let token = token_for(&store, &acct, ProviderType::Gmail);
        let gi = GmailInteractive::new(token, store, acct).with_base(server.uri());

        // 403 → dead credentials: a coded HttpStatus that classifies as auth.
        let auth = gi.get_json(&format!("{}/x", gi.api_base)).await.unwrap_err();
        assert!(matches!(auth, SyncError::HttpStatus { code: 403, .. }), "got {auth:?}");
        assert!(auth.is_auth());

        // 5xx → transient: neither auth nor permanent, so callers still retry.
        let transient = gi.get_json(&format!("{}/y", gi.api_base)).await.unwrap_err();
        assert!(matches!(transient, SyncError::HttpStatus { code: 500, .. }), "got {transient:?}");
        assert!(!transient.is_auth() && !transient.is_permanent());
    }

    #[tokio::test]
    async fn microsoft_get_json_preserves_status_code() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/z"))
            .respond_with(ResponseTemplate::new(403))
            .mount(&server)
            .await;

        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let acct = account(&store, ProviderType::Microsoft);
        let token = token_for(&store, &acct, ProviderType::Microsoft);
        let mi = MicrosoftInteractive::new(token, store, acct).with_base(server.uri());

        let err = mi.get_json(&format!("{}/z", mi.api_base)).await.unwrap_err();
        assert!(matches!(err, SyncError::HttpStatus { code: 403, .. }), "got {err:?}");
        assert!(err.is_auth());
    }

    fn draft(reply: bool) -> OutgoingMessage {
        OutgoingMessage {
            from_address: "u@x.com".into(),
            to_address: "a@b.com".into(),
            subject: Some("Hi".into()),
            body_plain: Some("hello".into()),
            in_reply_to: reply.then(|| "<parent@x>".to_string()),
            provider_thread_id: reply.then(|| "thr_1".to_string()),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn gmail_draft_posts_raw_mime_with_the_thread() {
        use wiremock::matchers::body_partial_json;
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/users/me/drafts"))
            .and(body_partial_json(serde_json::json!({ "message": { "threadId": "thr_1" } })))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "id": "r-1" })))
            .expect(1)
            .mount(&server)
            .await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let acct = account(&store, ProviderType::Gmail);
        let gi = GmailInteractive::new(token_for(&store, &acct, ProviderType::Gmail), store, acct).with_base(server.uri());
        assert_eq!(gi.save_draft(&draft(true), None).await.unwrap(), "r-1");
        let req = &server.received_requests().await.unwrap()[0];
        let body: Value = serde_json::from_slice(&req.body).unwrap();
        let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(body["message"]["raw"].as_str().unwrap()).unwrap();
        assert!(String::from_utf8(raw).unwrap().contains("In-Reply-To: <parent@x>"));
    }

    // A create whose response was lost left a draft Graph knows by its
    // Message-ID: the retry deletes it and creates once, from MIME.
    #[tokio::test]
    async fn graph_draft_retry_replaces_the_orphan_found_by_message_id() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/me/mailFolders/drafts/messages"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "value": [{ "id": "orphan" }] })))
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .and(path("/me/messages/orphan"))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/me/messages"))
            .respond_with(ResponseTemplate::new(201).set_body_json(serde_json::json!({ "id": "AAMk" })))
            .expect(1)
            .mount(&server)
            .await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let acct = account(&store, ProviderType::Microsoft);
        let mi = MicrosoftInteractive::new(token_for(&store, &acct, ProviderType::Microsoft), store, acct).with_base(server.uri());
        let mut d = draft(false);
        d.message_id = Some("<drf_1@x.com>".into());
        assert_eq!(mi.save_draft(&d, None).await.unwrap(), "AAMk");
        let post = server.received_requests().await.unwrap().into_iter().find(|r| r.method.as_str() == "POST").unwrap();
        assert_eq!(post.headers.get("content-type").unwrap(), "text/plain");
    }

    // Same for Gmail: the draft holding the Message-ID is updated, not duplicated,
    // and an extra copy from an earlier lost response is deleted.
    #[tokio::test]
    async fn gmail_draft_retry_updates_the_draft_found_by_message_id() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/users/me/drafts"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "drafts": [{ "id": "r-1" }, { "id": "r-2" }] })))
            .mount(&server)
            .await;
        Mock::given(method("PUT"))
            .and(path("/users/me/drafts/r-1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "id": "r-1" })))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .and(path("/users/me/drafts/r-2"))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST")).respond_with(ResponseTemplate::new(500)).expect(0).mount(&server).await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let acct = account(&store, ProviderType::Gmail);
        let gi = GmailInteractive::new(token_for(&store, &acct, ProviderType::Gmail), store, acct).with_base(server.uri());
        let mut d = draft(false);
        d.message_id = Some("<drf_1@x.com>".into());
        assert_eq!(gi.save_draft(&d, None).await.unwrap(), "r-1");
    }
}
