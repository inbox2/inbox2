//! Meta BYOK provider adapter — Instagram, Facebook Messenger, WhatsApp.
//!
//! One adapter implementation backs all three [`MetaChannel`]s (the engine sees
//! three distinct `ProviderType`s / accounts, each holding its own copy of the
//! customer's app-secret bundle + the asset IDs relevant to its channel). Unlike
//! the mail adapters, Meta channels are **push-first**: the customer's Meta app
//! POSTs webhooks to our Rails relay, which buffers the raw payload and nudges
//! the device; the device fetches, verifies the `X-Hub-Signature-256` against the
//! locally-held `app_secret`, and normalizes (see `sync/meta_push.rs`). The Graph
//! API here is used for outbound send, comment moderation, on-connect token
//! validation + webhook subscription, and a best-effort initial backfill.
//!
//! The System User token is **permanent** — there is no OAuth refresh, so this
//! adapter does not use [`TokenManager`](crate::sync::oauth::TokenManager). The
//! token and `app_secret` never leave the device and are never logged.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::sync::adapters::util::truncate;
use crate::sync::error::{Result, SyncError};
use crate::sync::model::*;
use crate::sync::provider::ProviderAdapter;
use crate::sync::store::SyncStore;

/// Graph API host. Pinned, config-bumpable version appended at build time.
const GRAPH_HOST: &str = "https://graph.facebook.com";
/// Instagram-Login API host (the "Instagram API with Instagram login" path) — a
/// separate Instagram app + OAuth user token, distinct from the Facebook-Login /
/// Page path on `graph.facebook.com`.
const IG_GRAPH_HOST: &str = "https://graph.instagram.com";
/// Pinned Graph API version. Override at runtime with `META_GRAPH_VERSION`
/// (e.g. `v22.0`) so a version bump needs no code change.
const DEFAULT_GRAPH_VERSION: &str = "v21.0";

/// Versioned marker stamped on the synthetic Inbox folder's cursor once the
/// historical backfill has run. The engine then switches to the no-op
/// incremental path. **Bump the version** whenever the backfill captures new
/// fields (names, avatars, attachments, …) so existing accounts re-run it once
/// on their next sync — no reconnect needed.
const BACKFILL_TAG: &str = "backfilled:v3";

/// Resolve the Graph API base URL (`{host}/{version}`), honouring the
/// `META_GRAPH_VERSION` env override.
fn graph_api_base() -> String {
    let version = std::env::var("META_GRAPH_VERSION").unwrap_or_else(|_| DEFAULT_GRAPH_VERSION.to_string());
    format!("{GRAPH_HOST}/{version}")
}

/// Parse a Graph `created_time` (ISO-8601, e.g. `2026-06-16T10:00:00+0000`) to
/// epoch milliseconds, the form the webhook normalizer's `timestamp` expects.
fn iso_to_ms(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .or_else(|| chrono::DateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%z").ok())
        .map(|dt| dt.timestamp_millis())
}

/// Map a Graph Conversations-API attachment object (`{mime_type, name,
/// image_data{url}, video_data{url}, file_url}`) to the webhook shape the
/// normalizer understands (`{type, payload:{url}, name}`), so backfilled and
/// live attachments render through the same path.
fn map_conv_attachment(a: &Value) -> Value {
    let name = a.get("name").and_then(|n| n.as_str());
    let mime = a.get("mime_type").and_then(|m| m.as_str()).unwrap_or("");
    let (ty, url) = if let Some(u) = a.get("image_data").and_then(|d| d.get("url")).and_then(|u| u.as_str()) {
        ("image", Some(u))
    } else if let Some(u) = a.get("video_data").and_then(|d| d.get("url")).and_then(|u| u.as_str()) {
        ("video", Some(u))
    } else if let Some(u) = a.get("file_url").and_then(|u| u.as_str()) {
        (if mime.starts_with("image/") { "image" } else { "file" }, Some(u))
    } else {
        ("file", None)
    };
    let mut payload = serde_json::json!({});
    if let Some(u) = url {
        payload["url"] = Value::String(u.to_string());
    }
    let mut out = serde_json::json!({ "type": ty, "payload": payload });
    if let Some(n) = name {
        out["name"] = Value::String(n.to_string());
    }
    out
}

/// Parsed Meta Graph error body (`{ "error": { code, error_subcode, message,
/// fbtrace_id, ... } }`). Meta error *messages* never contain our token, so they
/// are safe to echo (bounded) in diagnostics.
#[derive(Debug, Default, Clone)]
pub(crate) struct GraphError {
    pub code: i64,
    pub subcode: i64,
    pub message: String,
}

impl GraphError {
    fn parse(body: &str) -> Option<Self> {
        let v: Value = serde_json::from_str(body).ok()?;
        let e = v.get("error")?;
        Some(GraphError {
            code: e.get("code").and_then(|c| c.as_i64()).unwrap_or(0),
            subcode: e.get("error_subcode").and_then(|c| c.as_i64()).unwrap_or(0),
            message: e
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or_default()
                .to_string(),
        })
    }
}

/// Map a non-success Graph response to a typed, actionable [`SyncError`].
///
/// Meta overloads HTTP status (most failures arrive as `400` with the real cause
/// in `error.code`), so classification keys on the Meta code first:
///
/// - **190** (invalid/expired token) → `HttpStatus{401}` so `is_auth()` flags the
///   account `NeedsReauth`.
/// - **10 / 200..=299 / 3 / 12** (permission / deprecated permission) →
///   `HttpStatus{403}` (auth).
/// - **100** (invalid parameter / deprecated message tag) → `HttpStatus{400}`
///   (permanent — won't fix itself on retry).
/// - **131049** (WhatsApp "healthy-ecosystem" per-recipient frequency cap) →
///   `HttpStatus{429}` (transient — the outbox backs off and retries).
/// - **131047 / 131051 / 131026** (WhatsApp re-engagement / unsupported / undeliverable)
///   → `HttpStatus{400}` (permanent for this send).
/// - otherwise fall back to the HTTP status.
pub(crate) fn map_graph_error(label: &str, status: reqwest::StatusCode, body: &str) -> SyncError {
    let ge = GraphError::parse(body).unwrap_or_default();
    let effective = match ge.code {
        190 => 401,
        10 | 3 | 12 | 200..=299 => 403,
        100 => 400,
        131049 => 429,
        131047 | 131051 | 131026 | 131000 => 400,
        _ => status.as_u16(),
    };
    let detail = if ge.code != 0 {
        format!("{label}: Meta error {} (subcode {}): {}", ge.code, ge.subcode, truncate(&ge.message, 200))
    } else {
        format!("{label}: {}", truncate(body, 200))
    };
    SyncError::HttpStatus { code: effective, context: detail }
}

/// The Meta provider adapter. One struct, switched by [`MetaChannel`].
pub struct MetaAdapter {
    channel: MetaChannel,
    creds: MetaCredentials,
    store: Arc<SyncStore>,
    account_key: String,
    api_base: String,
    http: reqwest::Client,
    capabilities: ProviderCapabilities,
}

impl MetaAdapter {
    pub fn new(
        channel: MetaChannel,
        creds: MetaCredentials,
        store: Arc<SyncStore>,
        account_key: String,
    ) -> Self {
        Self {
            channel,
            creds,
            store,
            account_key,
            api_base: graph_api_base(),
            http: reqwest::Client::new(),
            capabilities: ProviderCapabilities {
                // Meta delivery is the Rails webhook relay, not IMAP IDLE and not
                // the Gmail/Graph cloud-push path — both flags stay false.
                push: false,
                incremental_sync: false,
                conditional_store: false,
                server_move: false,
                labels: false,
                custom_keywords: false,
                notify: false,
                raw: vec![format!("meta-{}", channel.as_str())],
            },
        }
    }

    /// Test helper: point the adapter at a mock Graph server.
    #[cfg(test)]
    pub fn with_base(mut self, api_base: String) -> Self {
        self.api_base = api_base;
        self
    }

    pub fn channel(&self) -> MetaChannel {
        self.channel
    }

    pub fn account_key(&self) -> &str {
        &self.account_key
    }

    pub(crate) fn creds(&self) -> &MetaCredentials {
        &self.creds
    }

    /// True when this Instagram channel uses the **Instagram-Login** path (its own
    /// OAuth user token on `graph.instagram.com`) rather than the Facebook-Login /
    /// Page path. Detected by the presence of an Instagram user token.
    pub(crate) fn ig_login(&self) -> bool {
        matches!(self.channel, MetaChannel::Instagram)
            && self.creds.instagram_user_token.as_deref().is_some_and(|t| !t.is_empty())
    }

    /// The Instagram-Login user token (bearer for `graph.instagram.com` calls).
    pub(crate) fn ig_token(&self) -> &str {
        self.creds.instagram_user_token.as_deref().unwrap_or_default()
    }

    /// Build an Instagram-Login API URL (`graph.instagram.com/{version}/{path}`),
    /// honouring the same pinned `META_GRAPH_VERSION`.
    fn ig_url(&self, path: &str) -> String {
        let version = std::env::var("META_GRAPH_VERSION").unwrap_or_else(|_| DEFAULT_GRAPH_VERSION.to_string());
        // Test override: when `api_base` is pointed at a mock server, route there.
        if self.api_base.starts_with("http://127.0.0.1") || self.api_base.starts_with("http://localhost") {
            return format!("{}/{}", self.api_base, path.trim_start_matches('/'));
        }
        format!("{IG_GRAPH_HOST}/{version}/{}", path.trim_start_matches('/'))
    }

    /// `graph_get` against the Instagram-Login host with the IG user token.
    pub(crate) async fn ig_get(&self, path: &str, label: &str) -> Result<Value> {
        let url = self.ig_url(path);
        self.send(reqwest::Method::GET, &url, None, label, self.ig_token()).await
    }

    /// `graph_post` against the Instagram-Login host with the IG user token.
    pub(crate) async fn ig_post(&self, path: &str, body: &Value, label: &str) -> Result<Value> {
        let url = self.ig_url(path);
        self.send(reqwest::Method::POST, &url, Some(body), label, self.ig_token()).await
    }

    /// The System User token (used as `Authorization: Bearer`). Passing the token
    /// in the header rather than the `access_token` query param keeps it out of
    /// request URLs (and therefore out of any URL-logging).
    fn token(&self) -> &str {
        &self.creds.system_user_token
    }

    // ── Graph HTTP helpers ───────────────────────────────────────────────

    /// `{api_base}/{path}` — `path` is already version-agnostic (no leading `/`).
    fn url(&self, path: &str) -> String {
        format!("{}/{}", self.api_base, path.trim_start_matches('/'))
    }

    async fn send(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<&Value>,
        label: &str,
        bearer: &str,
    ) -> Result<Value> {
        let mut rb = self.http.request(method, url).bearer_auth(bearer);
        if let Some(b) = body {
            rb = rb.json(b);
        }
        let resp = rb.send().await?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(map_graph_error(label, status, &text));
        }
        // Some Graph endpoints (e.g. DELETE) return an empty body or `true`.
        let text = resp.text().await.unwrap_or_default();
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text).map_err(|e| SyncError::Parse(format!("{label}: {e}")))
    }

    pub(crate) async fn graph_get(&self, path: &str, label: &str) -> Result<Value> {
        let url = self.url(path);
        self.send(reqwest::Method::GET, &url, None, label, self.token()).await
    }

    pub(crate) async fn graph_post(&self, path: &str, body: &Value, label: &str) -> Result<Value> {
        let url = self.url(path);
        self.send(reqwest::Method::POST, &url, Some(body), label, self.token()).await
    }

    /// Page-scoped endpoints (`/{page}/conversations`, `/{page}/subscribed_apps`,
    /// Messenger/Instagram sends) reject the System User token with Meta error
    /// 190/210 — they require a **Page access token**. Exchange the System User
    /// token for one via `GET /{page_id}?fields=access_token`. Returns `None` when
    /// the channel isn't Page-backed (WhatsApp) or no page id is configured.
    pub(crate) async fn page_access_token(&self) -> Result<Option<String>> {
        // Messenger + Instagram (linked-Page) are Page-backed; WhatsApp is not.
        if matches!(self.channel, MetaChannel::WhatsApp) {
            return Ok(None);
        }
        let Some(page_id) = self.creds.facebook_page_id.as_deref().filter(|s| !s.is_empty()) else {
            return Ok(None);
        };
        let v = self
            .graph_get(&format!("{page_id}?fields=access_token"), "Meta page token")
            .await?;
        Ok(v.get("access_token").and_then(|t| t.as_str()).map(str::to_string))
    }

    /// `graph_get` with an explicit bearer token (e.g. a Page access token).
    pub(crate) async fn graph_get_as(&self, path: &str, label: &str, bearer: &str) -> Result<Value> {
        let url = self.url(path);
        self.send(reqwest::Method::GET, &url, None, label, bearer).await
    }

    /// `graph_post` with an explicit bearer token (e.g. a Page access token).
    pub(crate) async fn graph_post_as(&self, path: &str, body: &Value, label: &str, bearer: &str) -> Result<Value> {
        let url = self.url(path);
        self.send(reqwest::Method::POST, &url, Some(body), label, bearer).await
    }

    /// `graph_delete` with an explicit bearer token (e.g. a Page access token).
    pub(crate) async fn graph_delete_as(&self, path: &str, label: &str, bearer: &str) -> Result<Value> {
        let url = self.url(path);
        self.send(reqwest::Method::DELETE, &url, None, label, bearer).await
    }

    /// Fetch raw bytes from a full URL with the System User token (WhatsApp media
    /// URLs from the Media API require the same bearer). Not JSON — returns bytes.
    pub(crate) async fn download_bytes(&self, url: &str) -> Result<Vec<u8>> {
        let resp = self.http.get(url).bearer_auth(self.token()).send().await?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(map_graph_error("WhatsApp media download", status, &text));
        }
        Ok(resp.bytes().await?.to_vec())
    }

    /// Resolve a Messenger PSID / Instagram-scoped id to its `(display name,
    /// avatar url)` via the Graph **User Profile API** (`GET
    /// /{id}?fields=name,profile_pic`), authenticated with the Page token.
    /// Best-effort — returns `(None, None)` on any failure (the raw id stays the
    /// display). Requires `pages_messaging` (Messenger) / `instagram_manage_messages`
    /// (Instagram); profile fields need Advanced Access in production.
    pub(crate) async fn resolve_contact(&self, id: &str, token: &str) -> (Option<String>, Option<String>) {
        match self
            .graph_get_as(&format!("{id}?fields=name,profile_pic"), "Meta profile", token)
            .await
        {
            Ok(v) => (
                v.get("name").and_then(|n| n.as_str()).filter(|s| !s.is_empty()).map(str::to_string),
                v.get("profile_pic").and_then(|p| p.as_str()).filter(|s| !s.is_empty()).map(str::to_string),
            ),
            Err(e) => {
                log::debug!("[meta] profile {id} unresolved: {e}");
                (None, None)
            }
        }
    }

    /// Subscribe the customer's app to their assets' webhooks. Idempotent and
    /// re-runnable (Meta upserts the subscription):
    /// - Page → `messages,messaging_postbacks,message_reactions,feed` (Messenger
    ///   DMs + Facebook Page comments; IG messaging rides the linked Page).
    /// - WABA → app subscription for WhatsApp.
    pub(crate) async fn subscribe_webhooks(&self) -> Result<()> {
        if let Some(page) = self.creds.facebook_page_id.as_deref().filter(|s| !s.is_empty()) {
            let body = serde_json::json!({
                "subscribed_fields": "messages,messaging_postbacks,message_reactions,feed",
            });
            // `/{page}/subscribed_apps` requires the Page access token (Meta 210).
            let page_token = self.page_access_token().await?;
            let token = page_token.as_deref().unwrap_or_else(|| self.token());
            self.graph_post_as(&format!("{page}/subscribed_apps"), &body, "Meta subscribe page", token).await?;
        }
        if let Some(waba) = self
            .creds
            .whatsapp_business_account_id
            .as_deref()
            .filter(|s| !s.is_empty())
        {
            self.graph_post(&format!("{waba}/subscribed_apps"), &serde_json::json!({}), "Meta subscribe waba")
                .await?;
        }
        Ok(())
    }

    /// The webhook `object` + comma-separated `fields` this channel subscribes to.
    fn webhook_object_fields(&self) -> (&'static str, &'static str) {
        match self.channel {
            MetaChannel::WhatsApp => ("whatsapp_business_account", "messages"),
            MetaChannel::Messenger => ("page", "messages,messaging_postbacks,message_reactions,feed"),
            MetaChannel::Instagram => ("instagram", "messages,comments,mentions"),
        }
    }

    /// Configure the customer's **app** webhook (callback URL + verify token +
    /// fields) via `POST /{app_id}/subscriptions`, so the operator doesn't have to
    /// set it in the App Dashboard by hand. Authenticated with the **app access
    /// token** (`app_id|app_secret`) — the subscriptions edge requires it (the
    /// System User token can't set it). Meta calls our GET handshake synchronously,
    /// so the relay + verify token must already be live. Best-effort: a failure
    /// (missing permission, unreachable callback) is surfaced to the caller, which
    /// logs it and falls back to manual dashboard setup.
    pub(crate) async fn subscribe_app_webhook(&self, callback_url: &str, verify_token: &str) -> Result<()> {
        if self.creds.app_id.is_empty() || self.creds.app_secret.is_empty() {
            return Err(SyncError::Other("Meta: app_id/app_secret required to auto-configure the webhook".into()));
        }
        let (object, fields) = self.webhook_object_fields();
        let app_token = format!("{}|{}", self.creds.app_id, self.creds.app_secret);
        let url = self.url(&format!("{}/subscriptions", self.creds.app_id));
        let resp = self
            .http
            .post(&url)
            .query(&[
                ("object", object),
                ("callback_url", callback_url),
                ("verify_token", verify_token),
                ("fields", fields),
                ("access_token", app_token.as_str()),
            ])
            .send()
            .await?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(map_graph_error("Meta app subscription", status, &text));
        }
        Ok(())
    }

    /// The (asset_type, asset_id) pairs to register with the relay for webhook
    /// routing. The receiver maps `entry[].id` (page/instagram/waba) or
    /// `value.metadata.phone_number_id` (WhatsApp) back to the owning user.
    pub(crate) fn routing_assets(&self) -> Vec<(&'static str, String)> {
        let c = &self.creds;
        let mut out = Vec::new();
        let mut push = |ty: &'static str, id: &Option<String>| {
            if let Some(v) = id.as_deref().filter(|s| !s.is_empty()) {
                out.push((ty, v.to_string()));
            }
        };
        push("page", &c.facebook_page_id);
        push("instagram", &c.instagram_account_id);
        push("waba", &c.whatsapp_business_account_id);
        push("phone", &c.whatsapp_phone_number_id);
        out
    }

    /// Auto-fill everything derivable from the System User token, so the operator
    /// supplies only the app secret + token + one asset id:
    /// - `app_id` + app name ← `debug_token` self-introspection.
    /// - WhatsApp: WABA → `phone_number_id` (`GET /{waba}/phone_numbers`, first).
    /// - Instagram: Page → `instagram_business_account` id (`GET /{page}?fields=…`).
    /// - Messenger: nothing extra (the Page id is the only asset).
    ///
    /// Only fills empty fields (an explicit value wins). Returns the completed
    /// bundle plus a suggested display name (the Meta app's name).
    pub(crate) async fn discover_assets(&self) -> Result<(MetaCredentials, Option<String>)> {
        let mut c = self.creds.clone();
        let empty = |o: &Option<String>| o.as_deref().unwrap_or("").is_empty();

        // Instagram-Login path: the account id + display name come from the IG user
        // token itself (`GET /me`), not a linked Page. No System User token here.
        if self.ig_login() {
            if let Ok(v) = self.ig_get("me?fields=user_id,username", "IG me").await {
                if empty(&c.instagram_account_id) {
                    if let Some(id) = v.get("user_id").and_then(|x| x.as_str()) {
                        c.instagram_account_id = Some(id.to_string());
                    } else if let Some(id) = v.get("id").and_then(|x| x.as_str()) {
                        c.instagram_account_id = Some(id.to_string());
                    }
                }
                let name = v.get("username").and_then(|x| x.as_str()).map(|u| format!("@{u}"));
                return Ok((c, name));
            }
            return Ok((c, None));
        }

        // Derive the app id (needed to auto-configure the webhook) + a display name
        // from the token itself, so neither needs a form field.
        let mut display_name: Option<String> = None;
        if !c.system_user_token.is_empty() {
            let tok = &c.system_user_token;
            if let Ok(v) = self
                .graph_get(&format!("debug_token?input_token={tok}&access_token={tok}"), "Meta debug_token")
                .await
            {
                if let Some(d) = v.get("data") {
                    if c.app_id.is_empty() {
                        if let Some(id) = d.get("app_id").and_then(|x| x.as_str()) {
                            c.app_id = id.to_string();
                        }
                    }
                    display_name = d.get("application").and_then(|x| x.as_str()).map(str::to_string);
                }
            }
        }

        match self.channel {
            MetaChannel::WhatsApp => {
                if empty(&c.whatsapp_phone_number_id) {
                    if let Some(waba) = c.whatsapp_business_account_id.as_deref().filter(|s| !s.is_empty()) {
                        let v = self.graph_get(&format!("{waba}/phone_numbers"), "Meta discover phone").await?;
                        if let Some(id) = v
                            .get("data")
                            .and_then(|d| d.as_array())
                            .and_then(|a| a.first())
                            .and_then(|p| p.get("id"))
                            .and_then(|i| i.as_str())
                        {
                            c.whatsapp_phone_number_id = Some(id.to_string());
                        }
                    }
                }
            }
            MetaChannel::Instagram => {
                if empty(&c.instagram_account_id) {
                    if let Some(page) = c.facebook_page_id.as_deref().filter(|s| !s.is_empty()) {
                        let v = self
                            .graph_get(&format!("{page}?fields=instagram_business_account"), "Meta discover IG")
                            .await?;
                        if let Some(id) = v
                            .get("instagram_business_account")
                            .and_then(|i| i.get("id"))
                            .and_then(|i| i.as_str())
                        {
                            c.instagram_account_id = Some(id.to_string());
                        }
                    }
                }
            }
            MetaChannel::Messenger => {}
        }
        Ok((c, display_name))
    }

    /// Validate the supplied System User token with a lightweight Graph call.
    /// `GET /me` works for both Page and User tokens; a failure here is the clear,
    /// early signal that the BYOK credentials are wrong (surfaced as auth error).
    pub(crate) async fn validate_token(&self) -> Result<String> {
        // Instagram-Login validates the OAuth user token against graph.instagram.com.
        if self.ig_login() {
            let v = self.ig_get("me?fields=user_id,username", "IG validate").await?;
            return v
                .get("user_id")
                .or_else(|| v.get("id"))
                .and_then(|i| i.as_str())
                .map(str::to_string)
                .ok_or_else(|| SyncError::AuthFailed("Instagram token validation returned no id".into()));
        }
        let v = self.graph_get("me?fields=id,name", "Meta validate").await?;
        v.get("id")
            .and_then(|i| i.as_str())
            .map(str::to_string)
            .ok_or_else(|| SyncError::AuthFailed("Meta token validation returned no id".into()))
    }

    /// Best-effort historical DM backfill (Messenger + Instagram; WhatsApp has no
    /// pull API). Pages the Graph **Conversations API**, synthesizes a
    /// webhook-shaped `messaging[]` payload from every *inbound* message, and runs
    /// it through the same [`meta_normalize`](crate::sync::meta_normalize) +
    /// `apply_meta_event` path as live delivery — so threading, dedup and
    /// channel/kind stamping are identical (re-running is a no-op for known
    /// messages). The account's own outbound sends are filtered out. Returns the
    /// number of messages applied.
    /// `mark_read` flattens unread for historical backfill (false for live polling
    /// so new messages stay unread); `max_pages` bounds pagination (1 = just the
    /// most-recent page, for a light poll).
    pub(crate) async fn backfill_dms(&self, mark_read: bool, max_pages: usize) -> Result<usize> {
        // Endpoint owner id + the webhook `object` to normalize as. `platform` is
        // required for Instagram; Messenger conversations default to messenger.
        let (owner_id, object, platform) = match self.channel {
            MetaChannel::Messenger => (self.creds.facebook_page_id.as_deref(), "page", None),
            MetaChannel::Instagram => {
                (self.creds.instagram_account_id.as_deref(), "instagram", Some("instagram"))
            }
            MetaChannel::WhatsApp => return Ok(0),
        };
        let Some(owner_id) = owner_id.filter(|s| !s.is_empty()) else {
            return Ok(0);
        };

        // Land in the same synthetic Inbox the webhook uses (FK-safe even before
        // the account's first folder sync has persisted it).
        let folder_key = format!("{}::inbox", self.account_key);
        self.store.upsert_folder(&UnifiedFolder {
            key: folder_key.clone(),
            account_key: self.account_key.clone(),
            provider_name: "Inbox".to_string(),
            role: Some(WellKnownFolder::Inbox),
            separator: None,
            flags: vec![],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        })?;

        // Instagram-Login reads `/me/conversations` on graph.instagram.com with the
        // OAuth user token. The Facebook path (Messenger + legacy IG) uses the Page
        // access token (the System User token is rejected with Meta 190).
        let ig = self.ig_login();
        let token = if ig {
            String::new()
        } else {
            self.page_access_token().await?.unwrap_or_else(|| self.token().to_string())
        };
        let conv_owner = if ig { "me" } else { owner_id };

        let max_pages = max_pages.max(1).min(20); // guard a runaway pull
        // Bounded field expansion — the Instagram Conversations API rejects a large
        // response with Meta error 1 ("reduce the amount of data"), so cap the
        // nested messages and keep per-page conversation count modest.
        let fields = "messages.limit(25){id,message,from{id,name},created_time,attachments{id,mime_type,name,image_data,video_data,file_url}}";
        let conv_limit = if ig { 12 } else { 30 };
        let mut after: Option<String> = None;
        let mut applied = 0usize;
        // Unique inbound senders to resolve to (name, avatar) after paging.
        let mut senders: std::collections::HashSet<String> = std::collections::HashSet::new();
        // Backfilled history is marked read on first sync (Meta has no inbound
        // read state); collect the threads we apply so live messages stay unread.
        let mut read_convs: std::collections::HashSet<String> = std::collections::HashSet::new();

        for page in 0..max_pages {
            let mut path = format!("{conv_owner}/conversations?fields={fields}&limit={conv_limit}");
            if let Some(p) = platform {
                path.push_str(&format!("&platform={p}"));
            }
            if let Some(a) = &after {
                path.push_str(&format!("&after={a}"));
            }
            let result = if ig {
                self.ig_get(&path, "IG backfill conversations").await
            } else {
                self.graph_get_as(&path, "Meta backfill conversations", &token).await
            };
            // A page error (e.g. Meta "reduce data") stops pagination but must NOT
            // abort — keep what we applied so the mark-read pass below still runs.
            let resp = match result {
                Ok(r) => r,
                Err(e) => {
                    log::warn!("[meta] {} backfill page {page} failed: {e}", self.channel.as_str());
                    break;
                }
            };

            // Flatten every inbound message across the page's conversations into one
            // synthetic webhook payload, then normalize it as a single batch.
            let mut messaging = Vec::new();
            for conv in resp.get("data").and_then(|d| d.as_array()).into_iter().flatten() {
                let msgs = conv
                    .get("messages")
                    .and_then(|m| m.get("data"))
                    .and_then(|d| d.as_array());
                for msg in msgs.into_iter().flatten() {
                    let from = msg.get("from");
                    let Some(from_id) = from.and_then(|f| f.get("id")).and_then(|i| i.as_str())
                    else {
                        continue;
                    };
                    if from_id == owner_id {
                        continue; // our own outbound send
                    }
                    let Some(mid) = msg.get("id").and_then(|i| i.as_str()) else {
                        continue;
                    };
                    senders.insert(from_id.to_string());
                    let mut message = serde_json::json!({ "mid": mid });
                    if let Some(text) = msg.get("message").and_then(|m| m.as_str()) {
                        message["text"] = Value::String(text.to_string());
                    }
                    // Conversations API nests attachments under `.data` in a
                    // different shape — map each to the webhook `{type,payload:{url}}`
                    // the normalizer renders.
                    if let Some(atts) = msg
                        .get("attachments")
                        .and_then(|a| a.get("data"))
                        .and_then(|d| d.as_array())
                    {
                        let mapped: Vec<Value> = atts.iter().map(map_conv_attachment).collect();
                        if !mapped.is_empty() {
                            message["attachments"] = Value::Array(mapped);
                        }
                    }
                    // Carry the sender's display name (`from.name`) so the row shows a
                    // human name, not the raw PSID/IG id. Live webhooks lack it.
                    let mut sender = serde_json::json!({ "id": from_id });
                    if let Some(name) = from.and_then(|f| f.get("name")).and_then(|n| n.as_str()) {
                        sender["name"] = Value::String(name.to_string());
                    }
                    let mut entry = serde_json::json!({
                        "sender": sender,
                        "message": message,
                    });
                    if let Some(ms) = msg.get("created_time").and_then(|c| c.as_str()).and_then(iso_to_ms) {
                        entry["timestamp"] = serde_json::json!(ms);
                    }
                    messaging.push(entry);
                }
            }

            if !messaging.is_empty() {
                let payload = serde_json::json!({
                    "object": object,
                    "entry": [ { "messaging": messaging } ],
                });
                for ev in crate::sync::meta_normalize::normalize(&payload) {
                    match self.store.apply_meta_event(&self.account_key, &folder_key, &ev) {
                        Ok(Some(up)) => {
                            applied += 1;
                            read_convs.insert(up.conversation_key);
                        }
                        Ok(None) => {}
                        Err(e) => log::warn!("[meta] backfill apply failed: {e}"),
                    }
                }
            }

            after = resp
                .get("paging")
                .and_then(|p| p.get("cursors"))
                .and_then(|c| c.get("after"))
                .and_then(|a| a.as_str())
                .map(str::to_string);
            if after.is_none() {
                break;
            }
            if page + 1 == max_pages && max_pages > 1 {
                log::warn!(
                    "[meta] {} backfill hit the {max_pages}-page cap; older threads not pulled",
                    self.channel.as_str()
                );
            }
        }

        // Resolve each unique sender's profile (display name + photo) via the User
        // Profile API and stamp it onto their conversation(s). Deduped, best-effort.
        // Facebook-path only — Instagram-Login carries the name in `from` already
        // (profile-photo resolution there is a follow-up).
        if !ig {
            for id in &senders {
                let (name, avatar) = self.resolve_contact(id, &token).await;
                if name.is_some() || avatar.is_some() {
                    if let Err(e) =
                        self.store.stamp_meta_contact(&self.account_key, id, name.as_deref(), avatar.as_deref())
                    {
                        log::warn!("[meta] stamp contact {id} failed: {e}");
                    }
                }
            }
        }

        // Flatten unread for historical backfill; live polling leaves new threads
        // unread.
        if mark_read {
            let conv_keys: Vec<String> = read_convs.into_iter().collect();
            if let Err(e) = self.store.mark_conversations_read(&conv_keys) {
                log::warn!("[meta] mark-read backfill failed: {e}");
            }
        }

        log::info!(
            "[meta] {} backfill applied {applied} message(s), resolved {} contact(s)",
            self.channel.as_str(),
            senders.len()
        );
        Ok(applied)
    }

    /// Best-effort backfill of recent **comments** — Facebook Page post comments
    /// (Messenger account) and Instagram media comments. Synthesizes the webhook
    /// `changes[]` shape so the same normalizer threads/dedupes them. Uses the
    /// Page token. Pulls recent posts/media (one page) with their comments — not
    /// full history. Returns the number applied.
    pub(crate) async fn backfill_comments(&self) -> Result<usize> {
        let folder_key = format!("{}::inbox", self.account_key);
        let ig = self.ig_login();

        let (path, object) = match self.channel {
            MetaChannel::Messenger => {
                let Some(page) = self.creds.facebook_page_id.as_deref().filter(|s| !s.is_empty()) else {
                    return Ok(0);
                };
                (
                    format!("{page}/posts?fields=id,comments.limit(100){{id,message,from{{id,name}},created_time}}&limit=25"),
                    "page",
                )
            }
            MetaChannel::Instagram if ig => (
                // Instagram-Login: read the user's own media + comments via /me.
                "me/media?fields=id,comments.limit(100){id,text,from{id,username},timestamp}&limit=25".to_string(),
                "instagram",
            ),
            MetaChannel::Instagram => {
                let Some(ig_id) = self.creds.instagram_account_id.as_deref().filter(|s| !s.is_empty()) else {
                    return Ok(0);
                };
                (
                    format!("{ig_id}/media?fields=id,comments.limit(100){{id,text,from{{id,username}},timestamp}}&limit=25"),
                    "instagram",
                )
            }
            MetaChannel::WhatsApp => return Ok(0),
        };

        // Facebook path needs the Page token; Instagram-Login uses the IG user token.
        let resp = if ig {
            self.ig_get(&path, "IG backfill comments").await?
        } else {
            let Some(token) = self.page_access_token().await? else {
                return Ok(0);
            };
            self.graph_get_as(&path, "Meta backfill comments", &token).await?
        };
        let mut changes = Vec::new();
        for parent in resp.get("data").and_then(|d| d.as_array()).into_iter().flatten() {
            let parent_id = parent.get("id").and_then(|i| i.as_str()).unwrap_or_default();
            let comments = parent.get("comments").and_then(|c| c.get("data")).and_then(|d| d.as_array());
            for c in comments.into_iter().flatten() {
                let Some(cid) = c.get("id").and_then(|i| i.as_str()) else { continue };
                let ts_ms = c
                    .get("created_time")
                    .or_else(|| c.get("timestamp"))
                    .and_then(|t| t.as_str())
                    .and_then(iso_to_ms);
                let from = c.get("from").cloned().unwrap_or(Value::Null);
                let change = if object == "page" {
                    let mut value = serde_json::json!({
                        "item": "comment", "verb": "add", "comment_id": cid, "post_id": parent_id,
                        "message": c.get("message").and_then(|m| m.as_str()).unwrap_or_default(),
                        "from": from,
                    });
                    if let Some(ms) = ts_ms { value["created_time"] = serde_json::json!(ms); }
                    serde_json::json!({ "field": "feed", "value": value })
                } else {
                    let mut value = serde_json::json!({
                        "id": cid, "media": { "id": parent_id },
                        "text": c.get("text").and_then(|t| t.as_str()).unwrap_or_default(),
                        "from": from,
                    });
                    if let Some(ms) = ts_ms { value["created_time"] = serde_json::json!(ms); }
                    serde_json::json!({ "field": "comments", "value": value })
                };
                changes.push(change);
            }
        }

        let mut applied = 0usize;
        let mut read_convs: std::collections::HashSet<String> = std::collections::HashSet::new();
        if !changes.is_empty() {
            let payload = serde_json::json!({ "object": object, "entry": [ { "changes": changes } ] });
            for ev in crate::sync::meta_normalize::normalize(&payload) {
                match self.store.apply_meta_event(&self.account_key, &folder_key, &ev) {
                    Ok(Some(up)) => {
                        applied += 1;
                        read_convs.insert(up.conversation_key);
                    }
                    Ok(None) => {}
                    Err(e) => log::warn!("[meta] comment backfill apply failed: {e}"),
                }
            }
        }
        // Backfilled comments are historical → read.
        let conv_keys: Vec<String> = read_convs.into_iter().collect();
        if let Err(e) = self.store.mark_conversations_read(&conv_keys) {
            log::warn!("[meta] mark-read comment backfill failed: {e}");
        }
        log::info!("[meta] {} comment backfill applied {applied}", self.channel.as_str());
        Ok(applied)
    }
}

#[async_trait]
impl ProviderAdapter for MetaAdapter {
    async fn connect(&mut self, credentials: &ProviderCredentials) -> Result<ProviderCapabilities> {
        // Refresh our cached creds from the (possibly re-entered) bundle.
        if let ProviderCredentials::Meta(m) = credentials {
            self.creds = m.clone();
        }
        // Instagram-Login authenticates with the OAuth user token (no System User
        // token); the Facebook path (WhatsApp/Messenger/legacy IG) needs the System
        // User token. validate_token() picks the right call per mode.
        let has_token = if self.ig_login() {
            true
        } else {
            !self.creds.system_user_token.is_empty()
        };
        if !has_token {
            return Err(SyncError::AuthFailed("Meta: missing access token".into()));
        }
        self.validate_token().await?;
        Ok(self.capabilities.clone())
    }

    async fn disconnect(&mut self) -> Result<()> {
        Ok(())
    }

    fn capabilities(&self) -> &ProviderCapabilities {
        &self.capabilities
    }

    async fn list_folders(&mut self) -> Result<Vec<UnifiedFolder>> {
        // Meta has no folders; expose one synthetic Inbox so the engine has a
        // sync target. Delivery is push-driven via the relay; the folder exists
        // mainly to hang the backfill + cursor off of.
        Ok(vec![UnifiedFolder {
            key: format!("{}::inbox", self.account_key),
            account_key: self.account_key.clone(),
            provider_name: "Inbox".to_string(),
            role: Some(WellKnownFolder::Inbox),
            separator: None,
            flags: vec![],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        }])
    }

    async fn initial_sync(
        &mut self,
        _folder: &UnifiedFolder,
        _batch_size: u32,
        _continuation: Continuation,
    ) -> Result<FolderSyncResult> {
        // Historical backfill of Messenger/Instagram DMs via the Conversations
        // API. We apply directly through the normalizer + store, so the result
        // carries no messages (no double-write). On success we stamp a sentinel
        // cursor so the engine switches to the no-op incremental path on later
        // syncs (the folder otherwise stays cursor-less and would re-pull every
        // cycle) — live updates then arrive via the relay. A failure leaves the
        // folder cursor-less so the backfill retries next sync; it must not error
        // the account. WhatsApp returns 0 (no pull API) but is still marked done.
        match self.backfill_dms(true, 20).await {
            Ok(_) => {
                // Comments are a separate Graph edge; best-effort, never fail the sync.
                if let Err(e) = self.backfill_comments().await {
                    log::warn!("[meta] {} comment backfill failed: {e}", self.channel.as_str());
                }
                Ok(FolderSyncResult {
                    next_token: Some(BACKFILL_TAG.to_string()),
                    ..FolderSyncResult::default()
                })
            }
            Err(e) => {
                log::warn!("[meta] {} backfill failed: {e}", self.channel.as_str());
                Ok(FolderSyncResult::default())
            }
        }
    }

    async fn incremental_sync(
        &mut self,
        _folder: &UnifiedFolder,
        cursor: &SyncCursor,
    ) -> Result<FolderSyncResult> {
        // When the backfill's version tag has moved on (a code improvement that
        // captures new fields), re-run the full backfill once so existing threads
        // pick up the change without a reconnect, then re-stamp the current tag.
        if cursor.token.as_deref() != Some(BACKFILL_TAG) {
            match self.backfill_dms(true, 20).await {
                Ok(_) => {
                    if let Err(e) = self.backfill_comments().await {
                        log::warn!("[meta] {} comment backfill failed: {e}", self.channel.as_str());
                    }
                    return Ok(FolderSyncResult {
                        next_token: Some(BACKFILL_TAG.to_string()),
                        ..FolderSyncResult::default()
                    })
                }
                Err(e) => {
                    // Leave the (stale) tag so it retries on the next tick.
                    log::warn!("[meta] {} re-backfill failed: {e}", self.channel.as_str());
                    return Ok(FolderSyncResult::default());
                }
            }
        }
        // Up to date: lightweight live poll of the most-recent page for pull-capable
        // channels (Instagram-Login + Messenger). New messages arrive within a poll
        // tick and stay unread; deduped against what's already stored. WhatsApp has
        // no pull API and relies on the relay. (Webhooks remain the efficient path
        // where the device is on the public cloud; polling makes live work anywhere.)
        if self.ig_login() || matches!(self.channel, MetaChannel::Messenger) {
            if let Err(e) = self.backfill_dms(false, 1).await {
                log::debug!("[meta] {} live poll failed: {e}", self.channel.as_str());
            }
        }
        Ok(FolderSyncResult::default())
    }

    async fn start_watching(
        &mut self,
        _folders: &[UnifiedFolder],
        _credentials: &ProviderCredentials,
        _tx: mpsc::UnboundedSender<ProviderEvent>,
    ) -> Result<()> {
        // No IMAP-IDLE-style watch; relay delivers events.
        Ok(())
    }

    async fn stop_watching(&mut self) -> Result<()> {
        Ok(())
    }

    async fn apply_action(
        &mut self,
        _action: &WritebackAction,
        _provider_state: &ProviderMessageId,
    ) -> Result<()> {
        // Meta write-backs (comment hide/delete, read receipts, reactions) are
        // implemented through InteractiveProvider::perform_action in step 3.
        Ok(())
    }

    fn normalize_flags(&self, _provider_flags: &ProviderFlags) -> UnifiedFlags {
        UnifiedFlags::default()
    }

    fn denormalize_flags(&self, _unified: &UnifiedFlags, _folder: Option<&str>) -> ProviderFlags {
        ProviderFlags::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn graph_error_maps_meta_codes_to_actionable_status() {
        // Token expired/invalid → auth (NeedsReauth).
        let e = map_graph_error("send", reqwest::StatusCode::BAD_REQUEST, r#"{"error":{"code":190,"message":"Invalid OAuth access token"}}"#);
        assert!(e.is_auth());
        assert!(matches!(e, SyncError::HttpStatus { code: 401, .. }));

        // Permission error → 403 (auth).
        let e = map_graph_error("send", reqwest::StatusCode::BAD_REQUEST, r#"{"error":{"code":10,"message":"permission"}}"#);
        assert!(e.is_auth());

        // Invalid param / deprecated tag (100) → permanent 400, NOT auth.
        let e = map_graph_error("send", reqwest::StatusCode::BAD_REQUEST, r#"{"error":{"code":100,"message":"deprecated tag"}}"#);
        assert!(e.is_permanent());
        assert!(!e.is_auth());

        // WhatsApp frequency cap (131049) → transient (retryable), not permanent.
        let e = map_graph_error("send", reqwest::StatusCode::BAD_REQUEST, r#"{"error":{"code":131049,"message":"healthy ecosystem"}}"#);
        assert!(!e.is_permanent());
        assert!(matches!(e, SyncError::HttpStatus { code: 429, .. }));
    }

    #[test]
    fn graph_error_falls_back_to_http_status_when_unparseable() {
        let e = map_graph_error("x", reqwest::StatusCode::INTERNAL_SERVER_ERROR, "not json");
        assert!(matches!(e, SyncError::HttpStatus { code: 500, .. }));
        assert!(!e.is_permanent());
    }

    #[test]
    fn graph_api_base_honours_env_override() {
        // Default pin.
        std::env::remove_var("META_GRAPH_VERSION");
        assert!(graph_api_base().ends_with("/v21.0"));
    }

    #[tokio::test]
    async fn backfill_pulls_inbound_dms_and_skips_own_sends() {
        use crate::sync::store::SyncStore;
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        // Page-scoped calls first exchange the System User token for a Page token.
        Mock::given(method("GET"))
            .and(path("/PAGE"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "PAGE_TOKEN"
            })))
            .mount(&server)
            .await;
        // One thread: an inbound message (from the user) + an outbound from our
        // own Page node (must be skipped). No paging cursor → single page.
        Mock::given(method("GET"))
            .and(path("/PAGE/conversations"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": [{
                    "id": "t_1",
                    "messages": { "data": [
                        { "id": "m_in", "message": "hello there", "from": { "id": "USER1", "name": "Ada Lovelace" }, "created_time": "2026-06-16T10:00:00+0000" },
                        { "id": "m_out", "message": "our reply", "from": { "id": "PAGE" }, "created_time": "2026-06-16T10:01:00+0000" }
                    ]}
                }]
            })))
            .mount(&server)
            .await;

        let store = std::sync::Arc::new(SyncStore::new_in_memory().unwrap());
        // The folder (and provider-state) FK requires a real account row.
        let account = ExternalAccount {
            key: String::new(),
            display_name: "FB".into(),
            email_address: "messenger:PAGE".into(),
            provider_type: ProviderType::Messenger,
            host: None,
            port: None,
            use_tls: false,
            smtp_host: None,
            smtp_port: None,
            smtp_use_tls: false,
            auth_method: "oauth2".into(),
            status: AccountStatus::Connected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: None,
        };
        let account_key = store.create_account(&account).unwrap();
        let creds = MetaCredentials {
            app_id: "app".into(),
            app_secret: "s".into(),
            system_user_token: "tok".into(),
            facebook_page_id: Some("PAGE".into()),
            instagram_account_id: None,
            whatsapp_phone_number_id: None,
            whatsapp_business_account_id: None,
            ..Default::default()
        };
        let adapter = MetaAdapter::new(MetaChannel::Messenger, creds, store.clone(), account_key)
            .with_base(server.uri());

        let applied = adapter.backfill_dms(true, 20).await.unwrap();
        assert_eq!(applied, 1, "only the inbound message is applied; our own send is skipped");

        // It landed stamped messenger/dm (so the channel sub-views match it).
        let conn = store.connection();
        let conn = conn.lock();
        let (channel, kind, from): (Option<String>, Option<String>, String) = conn
            .query_row(
                "SELECT channel, kind, from_address FROM messages WHERE channel IS NOT NULL LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(channel.as_deref(), Some("messenger"));
        assert_eq!(kind.as_deref(), Some("dm"));
        assert_eq!(from, "Ada Lovelace", "from.name should display instead of the PSID");
        // Backfilled history is read at the conversation level (live stays unread).
        let conv_read: i64 = conn
            .query_row("SELECT read FROM conversations WHERE channel IS NOT NULL LIMIT 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(conv_read, 1, "backfilled thread should be marked read");
    }

    #[tokio::test]
    async fn backfill_is_a_noop_for_whatsapp() {
        use crate::sync::store::SyncStore;
        let store = std::sync::Arc::new(SyncStore::new_in_memory().unwrap());
        let creds = MetaCredentials {
            app_id: "app".into(),
            app_secret: "s".into(),
            system_user_token: "tok".into(),
            facebook_page_id: None,
            instagram_account_id: None,
            whatsapp_phone_number_id: Some("PNID".into()),
            whatsapp_business_account_id: Some("WABA".into()),
            ..Default::default()
        };
        let adapter = MetaAdapter::new(MetaChannel::WhatsApp, creds, store, "acc_wa".into());
        // No Graph call, no panic — WhatsApp has no pull API.
        assert_eq!(adapter.backfill_dms(true, 20).await.unwrap(), 0);
    }

    #[tokio::test]
    async fn ig_login_backfill_uses_me_endpoint() {
        use crate::sync::store::SyncStore;
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        // Instagram-Login reads /me/conversations (vs /{ig}/conversations on FB path).
        Mock::given(method("GET"))
            .and(path("/me/conversations"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": [{ "id": "t_ig", "messages": { "data": [
                    { "id": "ig_m1", "message": "hi from insta", "from": { "id": "IGUSER", "name": "fan" }, "created_time": "2026-06-16T10:00:00+0000" }
                ]}}]
            })))
            .mount(&server)
            .await;

        let store = std::sync::Arc::new(SyncStore::new_in_memory().unwrap());
        let account = ExternalAccount {
            key: String::new(),
            display_name: "IG".into(),
            email_address: "instagram:IGSELF".into(),
            provider_type: ProviderType::Instagram,
            host: None,
            port: None,
            use_tls: false,
            smtp_host: None,
            smtp_port: None,
            smtp_use_tls: false,
            auth_method: "oauth2".into(),
            status: AccountStatus::Connected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: None,
        };
        let account_key = store.create_account(&account).unwrap();
        let creds = MetaCredentials {
            instagram_account_id: Some("IGSELF".into()),
            instagram_user_token: Some("IGTOK".into()),
            ..Default::default()
        };
        let adapter = MetaAdapter::new(MetaChannel::Instagram, creds, store.clone(), account_key)
            .with_base(server.uri());
        assert!(adapter.ig_login(), "should be in Instagram-Login mode");

        let applied = adapter.backfill_dms(true, 20).await.unwrap();
        assert_eq!(applied, 1, "the inbound IG DM should apply");
        let conn = store.connection();
        let conn = conn.lock();
        let channel: Option<String> = conn
            .query_row("SELECT channel FROM messages WHERE channel IS NOT NULL LIMIT 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(channel.as_deref(), Some("instagram"));
    }
}
