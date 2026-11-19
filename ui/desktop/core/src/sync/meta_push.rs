//! Meta webhook-relay provisioning (device-driven).
//!
//! Mirrors `push.rs` for the Meta channels. On connect the device:
//! 1. validates the System User token (`GET /me`),
//! 2. subscribes the customer's assets to *their* app's webhooks
//!    (`POST /{asset}/subscribed_apps`) — idempotent,
//! 3. reports the asset→user routing to our Rails relay
//!    (`POST /meta-channel-subscriptions`, authed with the Inbox2 `rails_jwt` —
//!    the same path the mail providers use; **no Meta secret leaves the device**),
//! 4. records the relay ids locally (`meta_subscription_state`) for the monthly
//!    lease keep-alive and teardown.
//!
//! The Meta app secret + token never reach Rails. Webhook delivery is the relay,
//! not polling — see docs/Cloud-Push.md (Meta) and `meta_normalize`.

use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;

use crate::sync::adapters::meta::MetaAdapter;
use crate::sync::engine::{event, SyncEngine, SyncPhase};
use crate::sync::error::{Result, SyncError};
use crate::sync::meta_normalize::{self, NormalizedMetaEvent};
use crate::sync::model::{ApiContext, MetaChannel, MetaCredentials, ProviderCredentials, UnifiedFolder, WellKnownFolder};

type HmacSha256 = Hmac<Sha256>;

/// Re-report (lease keep-alive) once the last report is older than this. The
/// Rails lease is 30 days; a weekly re-report keeps it comfortably alive.
const REPORT_REFRESH_DAYS: i64 = 7;

impl SyncEngine {
    /// Provision a Meta account: validate token, subscribe its app's webhooks,
    /// and register asset→user routing with the relay. Returns `true` when
    /// registered, `false` when skipped (non-Meta account, or no Rails auth yet).
    /// Best-effort: a relay/registration failure leaves the account usable for
    /// outbound; inbound just won't route until a later retry succeeds.
    pub async fn register_meta_push(&self, account_key: &str) -> Result<bool> {
        let adapter = match self.meta_adapter(account_key)? {
            Some(a) => a,
            None => return Ok(false),
        };
        if !self.has_rails_auth().await {
            log::info!("[meta] {account_key}: no Rails auth yet — deferring relay registration");
            return Ok(false);
        }

        adapter.validate_token().await?;

        // Auto-configure the customer's app webhook (callback + verify token +
        // fields) so the operator skips the App Dashboard webhook step. Callback is
        // this client's own API base + the relay path; the verify token comes from
        // the relay so the GET handshake matches. Best-effort — on failure (missing
        // permission / unreachable) fall back to manual dashboard setup.
        if let Some(ctx) = self.api_context().read().await.clone() {
            let callback = format!("{}/push/meta", ctx.api_base.trim_end_matches('/'));
            let verify_token = self.fetch_meta_verify_token().await.unwrap_or_default();
            // Meta's POST /{app_id}/subscriptions requires "all or none of
            // callback_url, verify_token" — sending a blank token is rejected with
            // error 194. Skip with a clear pointer rather than spamming failures
            // when the relay has no META_WEBHOOK_VERIFY_TOKEN set.
            if verify_token.is_empty() {
                log::warn!(
                    "[meta] {account_key}: skipping app webhook auto-config — the relay returned no verify token \
                     (set META_WEBHOOK_VERIFY_TOKEN on the deployment, or configure the webhook in the App Dashboard)"
                );
            } else if let Err(e) = adapter.subscribe_app_webhook(&callback, &verify_token).await {
                log::warn!("[meta] {account_key}: app webhook auto-config failed (set it in the App Dashboard): {e}");
            } else {
                log::info!("[meta] {account_key}: app webhook configured → {callback}");
            }
        }

        adapter.subscribe_webhooks().await?;

        let channel = adapter.channel().as_str();
        let mut rails_keys = Vec::new();
        for (asset_type, asset_id) in adapter.routing_assets() {
            match self.report_meta_asset(channel, asset_type, &asset_id).await {
                Ok(Some(key)) => rails_keys.push(key),
                Ok(None) => {}
                Err(e) => log::warn!("[meta] {account_key}: report {asset_type}={asset_id} failed: {e}"),
            }
        }
        self.store()
            .upsert_meta_subscription_state(account_key, &rails_keys)?;
        log::info!("[meta] {account_key}: registered {} asset(s) with relay", rails_keys.len());
        Ok(true)
    }

    /// Auto-fill everything derivable from the token (app_id + a display name +
    /// the secondary asset id) so the add-account form needs only the app secret +
    /// token + one asset id. Best-effort: on any Graph failure the input bundle is
    /// returned unchanged (the caller then errors if a required id is still
    /// missing). Returns `(completed creds, suggested display name)`.
    pub async fn discover_meta_assets(
        &self,
        channel: crate::sync::model::MetaChannel,
        creds: MetaCredentials,
    ) -> (MetaCredentials, Option<String>) {
        let adapter = MetaAdapter::new(channel, creds.clone(), self.store().clone(), "meta-discovery".to_string());
        match adapter.discover_assets().await {
            Ok(result) => result,
            Err(e) => {
                log::warn!("[meta] asset discovery failed: {e}");
                (creds, None)
            }
        }
    }

    /// Exchange an Instagram-Login OAuth `code` for a long-lived (≈60-day) user
    /// token. Two hops: code → short-lived (`api.instagram.com/oauth/access_token`)
    /// → long-lived (`graph.instagram.com/access_token?grant_type=ig_exchange_token`).
    /// Returns `(long_lived_token, expires_at_rfc3339)`.
    pub async fn instagram_exchange_code(
        &self,
        app_id: &str,
        app_secret: &str,
        code: &str,
        redirect_uri: &str,
    ) -> Result<(String, Option<String>)> {
        let http = reqwest::Client::new();
        // Instagram strips a trailing `#_` it sometimes appends to the code.
        let code = code.trim_end_matches("#_");

        // 1) code → short-lived token.
        let resp = http
            .post("https://api.instagram.com/oauth/access_token")
            .form(&[
                ("client_id", app_id),
                ("client_secret", app_secret),
                ("grant_type", "authorization_code"),
                ("redirect_uri", redirect_uri),
                ("code", code),
            ])
            .send()
            .await?;
        if !resp.status().is_success() {
            let t = resp.text().await.unwrap_or_default();
            return Err(SyncError::AuthFailed(format!("Instagram code exchange failed: {t}")));
        }
        let v: serde_json::Value = resp.json().await.map_err(|e| SyncError::Parse(e.to_string()))?;
        // Newer responses nest under data[0]; older return it at the top level.
        let short = v
            .get("access_token")
            .and_then(|t| t.as_str())
            .or_else(|| v.get("data").and_then(|d| d.get(0)).and_then(|d| d.get("access_token")).and_then(|t| t.as_str()))
            .ok_or_else(|| SyncError::AuthFailed("Instagram code exchange returned no token".into()))?
            .to_string();

        // 2) short-lived → long-lived (≈60 days).
        let long = http
            .get(format!(
                "https://graph.instagram.com/access_token?grant_type=ig_exchange_token&client_secret={app_secret}&access_token={short}"
            ))
            .send()
            .await?;
        if !long.status().is_success() {
            // The short-lived token still works (1h) — fall back so connect succeeds.
            log::warn!("[meta] IG long-lived exchange failed; using short-lived token");
            return Ok((short, None));
        }
        let lv: serde_json::Value = long.json().await.map_err(|e| SyncError::Parse(e.to_string()))?;
        let token = lv.get("access_token").and_then(|t| t.as_str()).unwrap_or(&short).to_string();
        let expires_at = lv
            .get("expires_in")
            .and_then(|s| s.as_i64())
            .map(|secs| (Utc::now() + chrono::Duration::seconds(secs)).to_rfc3339());
        Ok((token, expires_at))
    }

    /// Refresh a long-lived Instagram-Login token (valid 60 days, refreshable
    /// once >24h old) via `ig_refresh_token`. Returns the new `(token, expires_at)`.
    pub async fn instagram_refresh_token(&self, token: &str) -> Result<(String, Option<String>)> {
        let http = reqwest::Client::new();
        let resp = http
            .get(format!(
                "https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token={token}"
            ))
            .send()
            .await?;
        if !resp.status().is_success() {
            let t = resp.text().await.unwrap_or_default();
            return Err(SyncError::AuthFailed(format!("Instagram token refresh failed: {t}")));
        }
        let v: serde_json::Value = resp.json().await.map_err(|e| SyncError::Parse(e.to_string()))?;
        let new_token = v.get("access_token").and_then(|t| t.as_str()).unwrap_or(token).to_string();
        let expires_at = v
            .get("expires_in")
            .and_then(|s| s.as_i64())
            .map(|secs| (Utc::now() + chrono::Duration::seconds(secs)).to_rfc3339());
        Ok((new_token, expires_at))
    }

    /// Re-report Meta registrations whose lease is aging, across all Meta
    /// accounts. Called from the poll loop alongside `renew_push_due`.
    pub async fn renew_meta_push_due(&self) {
        let accounts = match self.store().list_accounts() {
            Ok(a) => a,
            Err(e) => {
                log::warn!("[meta] renew sweep: list accounts failed: {e}");
                return;
            }
        };
        let cutoff = Utc::now() - chrono::Duration::days(REPORT_REFRESH_DAYS);
        for account in accounts.into_iter().filter(|a| a.provider_type.is_meta()) {
            let due = match self.store().get_meta_subscription_state(&account.key) {
                Ok(Some((_, reported))) => parse_iso(&reported).map(|t| t <= cutoff).unwrap_or(true),
                Ok(None) => true, // never registered → try now
                Err(_) => continue,
            };
            if !due {
                continue;
            }
            if let Err(e) = self.register_meta_push(&account.key).await {
                log::warn!("[meta] {}: lease renew failed: {e}", account.key);
            }
        }
    }

    /// Tear down a Meta account's relay registration (account removal). Best-effort.
    pub async fn deregister_meta_push(&self, account_key: &str) -> Result<()> {
        let state = self.store().get_meta_subscription_state(account_key)?;
        if let Some((rails_keys, _)) = state {
            for key in rails_keys {
                if let Err(e) = self
                    .rails_request(
                        reqwest::Method::DELETE,
                        &format!("meta-channel-subscriptions/{key}"),
                        None,
                        "delete meta subscription",
                    )
                    .await
                {
                    log::warn!("[meta] {account_key}: relay teardown {key} failed: {e}");
                }
            }
        }
        self.store().delete_meta_subscription_state(account_key)?;
        log::info!("[meta] {account_key}: deregistered");
        Ok(())
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// Build a [`MetaAdapter`] for a Meta account (reading account + creds once),
    /// or `None` for non-Meta accounts.
    fn meta_adapter(&self, account_key: &str) -> Result<Option<MetaAdapter>> {
        let account = self
            .store()
            .get_account(account_key)?
            .ok_or_else(|| SyncError::Other("account not found".into()))?;
        let Some(channel) = account.provider_type.meta_channel() else {
            return Ok(None);
        };
        let creds = self
            .store()
            .get_credentials(account_key)?
            .ok_or_else(|| SyncError::Other("no credentials for account".into()))?;
        let ProviderCredentials::Meta(meta_creds) = creds else {
            return Err(SyncError::Other("Meta account has non-Meta credentials".into()));
        };
        Ok(Some(MetaAdapter::new(
            channel,
            meta_creds,
            self.store().clone(),
            account_key.to_string(),
        )))
    }

    /// The relay's webhook verify token (the value the GET handshake checks), so
    /// the device can set it when auto-configuring the app webhook. `None`/empty
    /// when unset on the deployment (the relay then accepts any token).
    async fn fetch_meta_verify_token(&self) -> Option<String> {
        let resp = self
            .rails_request(
                reqwest::Method::GET,
                "meta-channel-subscriptions/config",
                None,
                "meta config",
            )
            .await
            .ok()?;
        let data: serde_json::Value = resp.json().await.ok()?;
        data.get("verify_token")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    }

    async fn has_rails_auth(&self) -> bool {
        matches!(
            self.api_context().read().await.as_ref(),
            Some(ApiContext { rails_jwt, .. }) if !rails_jwt.is_empty()
        )
    }

    /// Report one asset→user routing row to the relay (idempotent upsert). Returns
    /// the relay's public id (`mcs_…`) for teardown.
    async fn report_meta_asset(
        &self,
        channel: &str,
        asset_type: &str,
        asset_id: &str,
    ) -> Result<Option<String>> {
        let body = serde_json::json!({
            "channel": channel,
            "asset_type": asset_type,
            "asset_id": asset_id,
        });
        let resp = self
            .rails_request(
                reqwest::Method::POST,
                "meta-channel-subscriptions",
                Some(&body),
                "report meta subscription",
            )
            .await?;
        let data: serde_json::Value = resp.json().await.unwrap_or_default();
        Ok(data
            .get("subscription")
            .and_then(|s| s.get("id"))
            .and_then(|v| v.as_str())
            .map(str::to_string))
    }

    // ── inbound: fetch + verify + normalize + apply ──────────────────────────

    /// Ingest one buffered Meta webhook event (driven by an ActionCable
    /// `meta_event` nudge or a silent mobile push). Fetches the byte-exact raw
    /// payload + signature from the relay, **verifies `X-Hub-Signature-256`
    /// against the matching local account's `app_secret`**, normalizes, upserts
    /// (deduped), then acks. Returns `true` when applied. A signature mismatch,
    /// an unknown asset, or a parse failure is logged, acked (so the buffered
    /// row doesn't linger), and returns `false` — a forged/unroutable event must
    /// not reach the store.
    pub async fn ingest_meta_event(&self, event_key: &str) -> Result<bool> {
        let resp = self
            .rails_request(
                reqwest::Method::GET,
                &format!("meta-webhook-events/{event_key}"),
                None,
                "fetch meta event",
            )
            .await?;
        let data: Value = resp.json().await?;
        let event = data
            .get("event")
            .ok_or_else(|| SyncError::Other("meta event: missing body".into()))?;
        let raw = event
            .get("raw_payload")
            .and_then(|v| v.as_str())
            .ok_or_else(|| SyncError::Other("meta event: missing raw_payload".into()))?;
        let signature = event.get("signature_header").and_then(|v| v.as_str()).unwrap_or("");

        let payload: Value = serde_json::from_str(raw)
            .map_err(|e| SyncError::Parse(format!("meta event payload: {e}")))?;

        // Which local account owns this payload's assets?
        let asset_ids = candidate_asset_ids(&payload);
        let Some((account_key, creds)) = self.match_meta_account(&asset_ids)? else {
            log::warn!("[meta] ingest {event_key}: no local account for assets — acking + dropping");
            self.ack_meta_event(event_key).await;
            return Ok(false);
        };

        // Verify the HMAC over the byte-exact body with that account's secret.
        if !verify_signature(&creds.app_secret, raw.as_bytes(), signature) {
            log::warn!("[meta] ingest {event_key}: X-Hub-Signature-256 mismatch — rejecting");
            self.ack_meta_event(event_key).await;
            return Ok(false);
        }

        let folder_key = format!("{account_key}::inbox");
        self.ensure_meta_inbox(&account_key, &folder_key)?;

        let normalized = meta_normalize::normalize(&payload);
        let mut new_pids: Vec<String> = Vec::new();
        for ev in &normalized {
            match self.store().apply_meta_event(&account_key, &folder_key, ev) {
                Ok(Some(up)) if up.was_new => {
                    if let NormalizedMetaEvent::Message(m) = ev {
                        // Inbound + unread only — an already-read message is
                        // never a notification (mirrors the IMAP/Graph path).
                        if m.msg.is_inbound && !m.msg.flags.read {
                            if let Some(pid) = &m.provider_id.provider_id {
                                new_pids.push(pid.clone());
                            }
                        }
                    }
                }
                Ok(_) => {}
                Err(e) => log::warn!("[meta] ingest {event_key}: apply failed: {e}"),
            }
        }

        // Resolve sender profiles (display name + photo) for newly-arrived
        // Messenger/Instagram DMs — live webhooks carry only the sender id, not a
        // name/avatar. Best-effort; WhatsApp gets its name from the payload's
        // contacts[] and has no profile-photo API, so it's skipped.
        let new_senders: std::collections::HashSet<String> = normalized
            .iter()
            .filter_map(|ev| match ev {
                NormalizedMetaEvent::Message(m) if m.msg.is_inbound => m.recipient_id.clone(),
                _ => None,
            })
            .collect();
        if !new_senders.is_empty() {
            if let Ok(Some(account)) = self.store().get_account(&account_key) {
                match account.provider_type.meta_channel() {
                    Some(channel) if !matches!(channel, MetaChannel::WhatsApp) => {
                        let adapter = MetaAdapter::new(channel, creds.clone(), self.store().clone(), account_key.clone());
                        if let Ok(Some(token)) = adapter.page_access_token().await {
                            for id in &new_senders {
                                let (name, avatar) = adapter.resolve_contact(id, &token).await;
                                if name.is_some() || avatar.is_some() {
                                    let _ = self.store().stamp_meta_contact(
                                        &account_key,
                                        id,
                                        name.as_deref(),
                                        avatar.as_deref(),
                                    );
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
        }

        if !new_pids.is_empty() {
            let email = self
                .store()
                .get_account(&account_key)
                .ok()
                .flatten()
                .map(|a| a.email_address)
                .unwrap_or_default();
            for pid in &new_pids {
                if let Ok(Some(mut notif)) = self.store().message_notification(&account_key, pid) {
                    notif.email = email.clone();
                    self.emit(event::NEW_MESSAGE, notif);
                }
            }
            // Drive the UI's push-based refresh via the sync backbone.
            self.sync_event(
                &account_key,
                SyncPhase::FolderComplete,
                serde_json::json!({
                    "folderKey": folder_key,
                    "folderName": "Inbox",
                    "added": new_pids.len(),
                    "synced": new_pids.len(),
                }),
            );
            // Wake the local-rules + triage workers now (the mail path does this in
            // sync_flow) so a just-arrived Meta message is rule-evaluated and
            // triaged immediately rather than on the worker's next poll tick.
            self.rules_scan_notify().notify_one();
            self.ai_scan_notify().notify_one();
        }

        self.ack_meta_event(event_key).await;
        log::info!("[meta] ingest {event_key}: applied {} new message(s)", new_pids.len());
        Ok(true)
    }

    /// Find the local Meta account (and its creds) owning any of `asset_ids`.
    fn match_meta_account(&self, asset_ids: &[String]) -> Result<Option<(String, MetaCredentials)>> {
        if asset_ids.is_empty() {
            return Ok(None);
        }
        for account in self.store().list_accounts()?.into_iter().filter(|a| a.provider_type.is_meta()) {
            let Ok(Some(ProviderCredentials::Meta(creds))) = self.store().get_credentials(&account.key) else {
                continue;
            };
            let owned = [
                &creds.facebook_page_id,
                &creds.instagram_account_id,
                &creds.whatsapp_business_account_id,
                &creds.whatsapp_phone_number_id,
            ];
            let matches = owned
                .iter()
                .filter_map(|o| o.as_deref())
                .any(|id| asset_ids.iter().any(|a| a == id));
            if matches {
                return Ok(Some((account.key, creds)));
            }
        }
        Ok(None)
    }

    /// Ensure the synthetic Inbox folder exists so the provider-state FK holds
    /// even when a webhook arrives before the account's first folder sync.
    fn ensure_meta_inbox(&self, account_key: &str, folder_key: &str) -> Result<()> {
        self.store().upsert_folder(&UnifiedFolder {
            key: folder_key.to_string(),
            account_key: account_key.to_string(),
            provider_name: "Inbox".to_string(),
            role: Some(WellKnownFolder::Inbox),
            separator: None,
            flags: vec![],
            uid_validity: None,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            sync_cursor: None,
            sync_enabled: true,
        })
    }

    /// Ack (delete) a buffered event. Best-effort — the relay GCs by TTL anyway.
    async fn ack_meta_event(&self, event_key: &str) {
        if let Err(e) = self
            .rails_request(
                reqwest::Method::DELETE,
                &format!("meta-webhook-events/{event_key}"),
                None,
                "ack meta event",
            )
            .await
        {
            log::warn!("[meta] ack {event_key} failed: {e}");
        }
    }
}

/// Verify a Meta `X-Hub-Signature-256` header (`sha256=<hex>`) — HMAC-SHA256 over
/// the raw request body, keyed by the app secret. Constant-time hex compare.
pub(crate) fn verify_signature(app_secret: &str, body: &[u8], header: &str) -> bool {
    let Some(hex_sig) = header.strip_prefix("sha256=") else {
        return false;
    };
    let Ok(mut mac) = HmacSha256::new_from_slice(app_secret.as_bytes()) else {
        return false;
    };
    mac.update(body);
    let computed = to_hex(&mac.finalize().into_bytes());
    constant_time_eq(computed.as_bytes(), hex_sig.as_bytes())
}

fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Length-independent, value constant-time byte comparison.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// All asset ids referenced by a webhook payload (page/IG entry ids, WABA entry
/// id, WhatsApp phone-number id), for matching against a local account's creds.
fn candidate_asset_ids(payload: &Value) -> Vec<String> {
    let mut out = Vec::new();
    let object = payload.get("object").and_then(|o| o.as_str()).unwrap_or("");
    if let Some(entries) = payload.get("entry").and_then(|e| e.as_array()) {
        for entry in entries {
            if let Some(id) = entry.get("id").and_then(|i| i.as_str()) {
                out.push(id.to_string());
            }
            if object == "whatsapp_business_account" {
                if let Some(changes) = entry.get("changes").and_then(|c| c.as_array()) {
                    for change in changes {
                        if let Some(phone) = change
                            .get("value")
                            .and_then(|v| v.get("metadata"))
                            .and_then(|m| m.get("phone_number_id"))
                            .and_then(|p| p.as_str())
                        {
                            out.push(phone.to_string());
                        }
                    }
                }
            }
        }
    }
    out
}

fn parse_iso(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::{candidate_asset_ids, verify_signature};
    use hmac::{Hmac, Mac};
    use serde_json::json;
    use sha2::Sha256;

    fn sign(secret: &str, body: &[u8]) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(body);
        let hex: String = mac.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect();
        format!("sha256={hex}")
    }

    #[test]
    fn valid_signature_passes() {
        let body = br#"{"object":"whatsapp_business_account"}"#;
        let header = sign("app_secret", body);
        assert!(verify_signature("app_secret", body, &header));
    }

    #[test]
    fn wrong_secret_fails() {
        let body = br#"{"x":1}"#;
        let header = sign("real_secret", body);
        assert!(!verify_signature("attacker_secret", body, &header));
    }

    #[test]
    fn tampered_body_fails() {
        let header = sign("s", b"original");
        assert!(!verify_signature("s", b"tampered", &header));
    }

    #[test]
    fn malformed_header_fails() {
        let body = b"x";
        assert!(!verify_signature("s", body, "deadbeef"));
        assert!(!verify_signature("s", body, ""));
        assert!(!verify_signature("s", body, "sha256=00"));
    }

    #[test]
    fn candidate_assets_extracts_ids_per_object() {
        let page = json!({"object":"page","entry":[{"id":"PAGE1"},{"id":"PAGE2"}]});
        assert_eq!(candidate_asset_ids(&page), vec!["PAGE1", "PAGE2"]);

        let ig = json!({"object":"instagram","entry":[{"id":"IG1"}]});
        assert_eq!(candidate_asset_ids(&ig), vec!["IG1"]);

        let wa = json!({
            "object":"whatsapp_business_account",
            "entry":[{"id":"WABA1","changes":[{"value":{"metadata":{"phone_number_id":"PNID1"}}}]}]
        });
        let ids = candidate_asset_ids(&wa);
        assert!(ids.contains(&"WABA1".to_string()));
        assert!(ids.contains(&"PNID1".to_string()));
    }
}
