//! Cloud-push orchestration for local channels (Gmail/Office365).
//!
//! The engine owns the provider-subscription *lifecycle* (create/renew/delete —
//! these need the client-side OAuth token), while the frontend owns the receive
//! websocket. After creating a provider subscription, the engine reports only the
//! mapping (provider, email, sub id, expiry) to Rails — never the token. Rails is
//! the source of truth; the local `push_subscription_state` table is just used for
//! renewal timing. Renewal is idempotent: we re-POST and Rails upserts + re-stamps
//! the lease. See docs/Cloud-Push.md.

use chrono::{DateTime, Utc};

use crate::sync::adapters;
use crate::sync::engine::SyncEngine;
use crate::sync::error::{Result, SyncError};
use crate::sync::model::{ApiContext, PushSubConfig, PushSubInfo, PushSubState};
use crate::sync::provider::ProviderAdapter;

/// Renew a subscription once it's within this window of expiring.
fn renew_threshold() -> DateTime<Utc> {
    Utc::now() + chrono::Duration::days(1)
}

impl SyncEngine {
    /// Register cloud push for an account if the backend permits it. Returns `true`
    /// if a provider subscription was created, `false` if push is disabled/unconfigured
    /// (in which case the engine's 60s polling remains the path). IMAP returns `false`
    /// (it uses IDLE, not cloud push).
    pub async fn register_push(&self, account_key: &str) -> Result<bool> {
        let config = match self.fetch_push_config().await? {
            Some(c) if c.push_enabled => c,
            _ => {
                log::info!("[push] {account_key}: disabled/unconfigured — staying on polling");
                return Ok(false);
            }
        };

        let (mut adapter, provider_str, email) = match self.push_target(account_key)? {
            Some(t) => t,
            None => return Ok(false), // IMAP / unsupported — uses IDLE, not cloud push
        };
        let info = adapter.create_push_subscription(&config).await?;
        let rails_key = self.report_subscription(provider_str, &email, &info).await?;

        self.store().upsert_push_state(&PushSubState {
            account_key: account_key.to_string(),
            rails_key,
            provider_subscription_id: info.provider_subscription_id.clone(),
            client_state: info.client_state.clone(),
            expires_at: info.expires_at.clone(),
        })?;
        log::info!(
            "[push] {account_key}: registered {provider_str} push (expires {:?})",
            info.expires_at
        );
        Ok(true)
    }

    /// Tear down cloud push for an account (toggle-off / account removal). Best-effort:
    /// failures to reach the provider or Rails don't block local cleanup.
    pub async fn deregister_push(&self, account_key: &str) -> Result<()> {
        let state = match self.store().get_push_state(account_key)? {
            Some(s) => s,
            None => return Ok(()),
        };

        if let Ok(Some((mut adapter, _, _))) = self.push_target(account_key) {
            if let Err(e) = adapter.delete_push_subscription(&state_to_info(&state)).await {
                log::warn!("[push] {account_key}: provider teardown failed: {e}");
            }
        }
        if let Some(key) = &state.rails_key {
            if let Err(e) = self.delete_subscription_on_rails(key).await {
                log::warn!("[push] {account_key}: rails teardown failed: {e}");
            }
        }
        self.store().delete_push_state(account_key)?;
        log::info!("[push] {account_key}: deregistered");
        Ok(())
    }

    /// Renew any locally-tracked subscriptions nearing expiry. Called from the poll
    /// loop. No-op when nothing is registered or push is disabled.
    pub async fn renew_push_due(&self) {
        let states = match self.store().list_push_states() {
            Ok(s) => s,
            Err(e) => {
                log::warn!("[push] renew sweep failed to list state: {e}");
                return;
            }
        };
        if states.is_empty() {
            return;
        }

        let config = match self.fetch_push_config().await {
            Ok(Some(c)) if c.push_enabled => c,
            _ => return,
        };

        let threshold = renew_threshold();
        for state in states {
            let due = match state.expires_at.as_deref().and_then(parse_iso) {
                Some(exp) => exp <= threshold,
                None => true, // unknown expiry → renew to be safe
            };
            if !due {
                continue;
            }
            if let Err(e) = self.renew_one(&state, &config).await {
                log::warn!("[push] {}: renew failed: {e}", state.account_key);
            }
        }
    }

    async fn renew_one(&self, state: &PushSubState, config: &PushSubConfig) -> Result<()> {
        let (mut adapter, provider_str, email) = match self.push_target(&state.account_key)? {
            Some(t) => t,
            None => return Ok(()),
        };
        let info = adapter
            .renew_push_subscription(config, &state_to_info(state))
            .await?;
        let rails_key = self
            .report_subscription(provider_str, &email, &info)
            .await?
            .or_else(|| state.rails_key.clone());

        self.store().upsert_push_state(&PushSubState {
            account_key: state.account_key.clone(),
            rails_key,
            provider_subscription_id: info.provider_subscription_id.clone(),
            client_state: info.client_state.clone(),
            expires_at: info.expires_at.clone(),
        })?;
        log::info!("[push] {}: renewed (expires {:?})", state.account_key, info.expires_at);
        Ok(())
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// Load an account and build its provider adapter for push, reading the
    /// account+credentials exactly once. Returns `None` for providers that don't
    /// do cloud push (IMAP uses IDLE), so callers can skip cleanly. The wire label
    /// is the canonical `ProviderType::as_str()`.
    fn push_target(
        &self,
        account_key: &str,
    ) -> Result<Option<(Box<dyn ProviderAdapter>, &'static str, String)>> {
        let account = self
            .store()
            .get_account(account_key)?
            .ok_or_else(|| SyncError::Other("account not found".into()))?;
        if !account.provider_type.supports_cloud_push() {
            return Ok(None);
        }
        let creds = self
            .store()
            .get_credentials(account_key)?
            .ok_or_else(|| SyncError::Other("no credentials for account".into()))?;
        let adapter = adapters::create_adapter(
            account_key,
            &account.provider_type,
            account.host.as_deref().unwrap_or(""),
            account.port.unwrap_or(0),
            account.use_tls,
            &creds,
            self.store().clone(),
            self.api_context().clone(),
        );
        Ok(Some((adapter, account.provider_type.as_str(), account.email_address)))
    }

    async fn api_ctx(&self) -> Result<ApiContext> {
        self.api_context()
            .read()
            .await
            .clone()
            .ok_or_else(|| SyncError::Other("API context not set".into()))
    }

    /// One authed request to the Rails push API: joins `path` onto `api_base`,
    /// attaches the `rails_jwt` bearer, reuses the shared client, and turns a
    /// non-2xx into an error tagged with `label`.
    pub(crate) async fn rails_request(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&serde_json::Value>,
        label: &str,
    ) -> Result<reqwest::Response> {
        let ctx = self.api_ctx().await?;
        let url = format!(
            "{}/{}",
            ctx.api_base.trim_end_matches('/'),
            path.trim_start_matches('/')
        );
        let mut rb = rails_client()
            .request(method, &url)
            .header("Authorization", format!("Bearer {}", ctx.rails_jwt));
        if let Some(b) = body {
            rb = rb.json(b);
        }
        let resp = rb.send().await?;
        if !resp.status().is_success() {
            return Err(SyncError::Other(format!("{label}: {}", resp.status())));
        }
        Ok(resp)
    }

    /// Fetch push config (topic / notificationUrl / gating) from Rails. `None` when
    /// the API context / auth token isn't set yet — without a bearer the call would
    /// just 401, and cloud push isn't available, so callers fall back to polling.
    async fn fetch_push_config(&self) -> Result<Option<PushSubConfig>> {
        let has_auth = matches!(
            self.api_context().read().await.as_ref(),
            Some(c) if !c.rails_jwt.is_empty()
        );
        if !has_auth {
            return Ok(None);
        }
        let resp = self
            .rails_request(
                reqwest::Method::GET,
                "channel-push-subscriptions/config",
                None,
                "push config",
            )
            .await?;
        Ok(Some(resp.json().await?))
    }

    /// POST the subscription mapping to Rails (idempotent upsert). Returns the
    /// `cpsub_…` public id so we can DELETE it on teardown.
    async fn report_subscription(
        &self,
        provider: &str,
        email: &str,
        info: &PushSubInfo,
    ) -> Result<Option<String>> {
        let body = serde_json::json!({
            "provider": provider,
            "external_email": email,
            "provider_subscription_id": info.provider_subscription_id,
            "client_state": info.client_state,
            "expires_at": info.expires_at,
        });
        let resp = self
            .rails_request(
                reqwest::Method::POST,
                "channel-push-subscriptions",
                Some(&body),
                "report subscription",
            )
            .await?;
        let data: serde_json::Value = resp.json().await.unwrap_or_default();
        Ok(data
            .get("subscription")
            .and_then(|s| s.get("id"))
            .and_then(|v| v.as_str())
            .map(str::to_string))
    }

    async fn delete_subscription_on_rails(&self, rails_key: &str) -> Result<()> {
        self.rails_request(
            reqwest::Method::DELETE,
            &format!("channel-push-subscriptions/{rails_key}"),
            None,
            "delete subscription",
        )
        .await?;
        Ok(())
    }
}

/// Shared HTTP client for Rails push calls — owns the connection pool / TLS config,
/// so we don't rebuild it per request.
fn rails_client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(reqwest::Client::new)
}

fn state_to_info(state: &PushSubState) -> PushSubInfo {
    PushSubInfo {
        provider_subscription_id: state.provider_subscription_id.clone(),
        client_state: state.client_state.clone(),
        expires_at: state.expires_at.clone(),
    }
}

fn parse_iso(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}
