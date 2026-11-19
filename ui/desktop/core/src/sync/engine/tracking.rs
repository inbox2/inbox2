//! Open tracking for local channels (docs/Open-Tracking.md): inject the pixel at
//! send, poll Rails for opens, and read them back.
//!
//! The injection hangs off the single `enqueue_send` funnel, so Gmail/Office365/
//! IMAP all get it without touching their three MIME builders. Opens are
//! collected server-side (the recipient hits our pixel endpoint, not the device)
//! and polled back read-only — the one server touch open tracking fundamentally
//! needs for otherwise-serverless local channels.

use super::*;
use crate::sync::tracking;
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};

// Custom hosts already registered for CF-for-SaaS TLS this process — so the poll
// loop provisions each once, not every tick.
fn registered_hosts() -> &'static Mutex<HashSet<String>> {
    static R: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashSet::new()))
}

impl SyncEngine {
    /// Inject the tracking pixel into `message.body_html` when the account has
    /// open tracking on, and record the token for the opens poll. No-op otherwise.
    pub(crate) async fn maybe_inject_tracking_pixel(
        &self,
        account_key: &str,
        message: &mut OutgoingMessage,
    ) {
        let settings = match self.store.open_tracking_settings(account_key) {
            Ok(s) if s.enabled => s,
            _ => return,
        };
        let Some(html) = message.body_html.clone().filter(|h| !h.is_empty()) else {
            return;
        };
        let Some(base) = self.tracking_pixel_base(settings.track_domain.as_deref()).await else {
            // No API base configured → opens couldn't be collected/polled; skip
            // rather than embed a dead pixel.
            log::debug!("[tracking] no API base — skipping pixel injection");
            return;
        };

        let (secret, token) = tracking::gen_secret_token();
        // The secret first: a token on record without one would be polled as a legacy token.
        if let Err(e) = self.store.record_tracked_secret(&token, &secret) {
            log::warn!("[tracking] failed to record secret, skipping pixel: {e}");
            return;
        }
        let url = format!("{base}/o/{token}.gif");
        message.body_html = Some(tracking::inject(&html, &url));
        if let Err(e) = self.store.record_tracked_token(&token, account_key) {
            log::warn!("[tracking] failed to record token: {e}");
        }
    }

    /// Base URL the pixel is served from: a custom `track_domain` (https) or the
    /// API host (so the pixel lands on the same Rails app the client polls opens
    /// from). None when no API context is set.
    async fn tracking_pixel_base(&self, track_domain: Option<&str>) -> Option<String> {
        if let Some(d) = track_domain.filter(|s| !s.is_empty()) {
            return Some(format!("https://{}", d.trim_end_matches('/')));
        }
        let ctx = self.api_context.read().await;
        let api_base = ctx.as_ref().map(|c| c.api_base.clone())?;
        Some(tracking::pixel_base_from_api(&api_base))
    }

    /// Poll Rails for opens on our tracked tokens and cache them locally. No-op
    /// when nothing is tracked or no API context is set. The endpoint is
    /// unauthenticated (the read secret is the capability), so this works even
    /// when `rails_jwt` is empty (iOS). Secrets live on the device that sent the
    /// mail, so opens read back there only (decided 2026-11-09).
    pub(crate) async fn poll_tracking_opens(&self) {
        let (tokens, secrets) = match self.store.tracked_polls(500) {
            Ok((t, s)) if !(t.is_empty() && s.is_empty()) => (t, s),
            _ => return,
        };

        let body = serde_json::json!({ "tokens": tokens, "secrets": secrets });
        let resp = match self
            .rails_request(reqwest::Method::POST, "tracking/opens", Some(&body), "tracking opens")
            .await
        {
            Ok(r) => r,
            Err(e) => {
                log::debug!("[tracking] opens poll skipped: {e}");
                return;
            }
        };

        let parsed: serde_json::Value = match resp.json().await {
            Ok(v) => v,
            Err(e) => {
                log::warn!("[tracking] opens poll bad body: {e}");
                return;
            }
        };
        let Some(map) = parsed.get("opens").and_then(|o| o.as_object()) else {
            return;
        };
        for (token, arr) in map {
            let opens = tracking::parse_opens(arr);
            if let Err(e) = self.store.replace_opens_for_token(token, &opens) {
                log::warn!("[tracking] failed to store opens for {token}: {e}");
            }
        }
    }

    /// Provision CF-for-SaaS TLS for each channel's custom tracking host (so a
    /// same-domain host like track.tuli.com actually serves the pixel over https).
    /// Idempotent + deduped per process. Needs a linked account (a device without one,
    /// iOS included until it links, skips this and the pixel uses the host as set).
    pub(crate) async fn ensure_custom_hosts_registered(&self) {
        // Registering needs a linked account; without one every poll would just get a 401.
        if self.api_context.read().await.as_ref().is_none_or(|c| c.rails_jwt.is_empty()) {
            return;
        }
        let hosts = match self.store.custom_track_domains() {
            Ok(h) if !h.is_empty() => h,
            _ => return,
        };
        for host in hosts {
            {
                let mut set = registered_hosts().lock().unwrap();
                if set.contains(&host) {
                    continue;
                }
                set.insert(host.clone());
            }
            let body = serde_json::json!({ "host": host });
            if let Err(e) = self
                .rails_request(reqwest::Method::POST, "tracking/register", Some(&body), "tracking register")
                .await
            {
                log::debug!("[tracking] register {host} skipped: {e}");
                registered_hosts().lock().unwrap().remove(&host); // retry next poll
            }
        }
    }

    /// Opens (who/when/where) for a sent message, resolved via the token embedded
    /// in its body_html. Empty when the message wasn't tracked or has no opens yet.
    pub fn message_opens(&self, message_body_html: &str) -> Vec<crate::sync::store::tracking::OpenRecord> {
        match tracking::extract_token(message_body_html) {
            Some(token) => self.store.opens_for_token(&token).unwrap_or_default(),
            None => Vec::new(),
        }
    }
}
