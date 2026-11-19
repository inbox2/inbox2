//! OAuth token management for Gmail / Microsoft adapters.
//!
//! Token refresh prefers going **directly** to the provider's token endpoint
//! (Google / Microsoft) when the host has supplied OAuth client credentials
//! (see [`SyncEngine::set_oauth_client`]) — the Rails proxy is only required
//! for the *first* auth (building the consent URL + exchanging the code).
//! When no client credentials are configured, refresh falls back to the Rails
//! proxy (`/api/v1/auth/{google,microsoft}/refresh`), which holds the client
//! secret server-side. `TokenManager` keeps the current access token in
//! memory, refreshes it on `401`, and persists the refreshed token back to the
//! encrypted credential store.

use std::sync::Arc;
use std::time::Duration;

use serde::Deserialize;
use tokio::sync::RwLock;

use crate::sync::error::{Result, SyncError};
use crate::sync::model::{ApiContext, ProviderCredentials, ProviderType};
use crate::sync::store::SyncStore;

#[derive(Default, Clone)]
struct CachedToken {
    username: String,
    access_token: String,
    refresh_token: Option<String>,
}

/// Encrypted-store key holding the Google OAuth client credentials (JSON
/// [`OAuthClientConfig`]) for direct token refresh.
pub const SECRET_OAUTH_CLIENT_GOOGLE: &str = "oauth_client_google";
/// Encrypted-store key holding the Microsoft OAuth client credentials.
pub const SECRET_OAUTH_CLIENT_MICROSOFT: &str = "oauth_client_microsoft";

/// The store key for a provider's OAuth client credentials, when the provider
/// has any (IMAP doesn't).
pub fn oauth_client_secret_key(provider: &ProviderType) -> Option<&'static str> {
    match provider {
        ProviderType::Gmail => Some(SECRET_OAUTH_CLIENT_GOOGLE),
        ProviderType::Microsoft => Some(SECRET_OAUTH_CLIENT_MICROSOFT),
        // IMAP uses a stored password; Meta uses a permanent System User token —
        // neither has refreshable OAuth client credentials.
        ProviderType::Imap | ProviderType::Instagram | ProviderType::Messenger
        | ProviderType::WhatsApp => None,
    }
}

/// Google's token endpoint (desktop-app client: the secret is distributable —
/// Google's docs explicitly do not treat installed-app secrets as confidential).
const GOOGLE_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
/// Microsoft identity platform token endpoint (multi-tenant + personal).
const MICROSOFT_TOKEN_URL: &str = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
/// Scopes echoed in Microsoft refresh requests (matches the Rails proxy's
/// `MicrosoftOauthProxyController#scopes`, which issued the original grant).
const MICROSOFT_SCOPES: &str =
    "Mail.ReadWrite Mail.Send Calendars.ReadWrite Contacts.Read User.Read offline_access openid";

/// OAuth client credentials for refreshing tokens directly against the
/// provider, bypassing the Rails proxy. Persisted as JSON in the encrypted
/// app-secret store under [`SECRET_OAUTH_CLIENT_GOOGLE`] /
/// [`SECRET_OAUTH_CLIENT_MICROSOFT`].
#[derive(Clone, serde::Serialize, Deserialize)]
pub struct OAuthClientConfig {
    pub client_id: String,
    /// Required by Google (installed-app secrets are non-confidential by
    /// design); required for confidential Microsoft app registrations.
    #[serde(default)]
    pub client_secret: Option<String>,
    /// Override of the provider token endpoint (tests only).
    #[serde(default)]
    pub token_url: Option<String>,
}

/// Holds and refreshes the OAuth access token for one account.
pub struct TokenManager {
    account_key: String,
    provider: ProviderType,
    store: Arc<SyncStore>,
    api_context: Arc<RwLock<Option<ApiContext>>>,
    client: reqwest::Client,
    cached: RwLock<CachedToken>,
}

#[derive(Deserialize)]
struct RefreshResponse {
    access_token: String,
    /// Providers may rotate the refresh token (Microsoft always does, Google
    /// occasionally). When present it replaces the stored one — keeping the old
    /// token would eventually refresh with a revoked grant.
    #[serde(default)]
    refresh_token: Option<String>,
}

impl TokenManager {
    pub fn new(
        account_key: String,
        provider: ProviderType,
        store: Arc<SyncStore>,
        api_context: Arc<RwLock<Option<ApiContext>>>,
        initial: &ProviderCredentials,
    ) -> Self {
        let cached = match initial {
            ProviderCredentials::OAuth2 {
                username,
                access_token,
                refresh_token,
            } => CachedToken {
                username: username.clone(),
                access_token: access_token.clone(),
                refresh_token: refresh_token.clone(),
            },
            ProviderCredentials::Password { username, .. } => CachedToken {
                username: username.clone(),
                ..Default::default()
            },
            // Meta channels never build a TokenManager (the System User token is
            // permanent and used directly by MetaAdapter); arm present only for
            // exhaustiveness.
            ProviderCredentials::Meta(m) => CachedToken {
                access_token: m.system_user_token.clone(),
                ..Default::default()
            },
        };
        Self {
            account_key,
            provider,
            store,
            api_context,
            // Every provider call (mail + calendar) goes through this client, and
            // the engine's poll loop awaits them with no timeout of its own — so a
            // request that never returns wedges the whole run loop: no polling, no
            // push handling, no write-back drain, until the app restarts.
            // ponytail: one flat per-request cap; per-endpoint budgets only if a
            // legitimately slow call (large attachment fetch) starts tripping it.
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .build()
                .unwrap_or_default(),
            cached: RwLock::new(cached),
        }
    }

    /// For tests: construct against an explicit reqwest client.
    #[cfg(test)]
    pub fn new_with_client(
        account_key: String,
        provider: ProviderType,
        store: Arc<SyncStore>,
        api_context: Arc<RwLock<Option<ApiContext>>>,
        initial: &ProviderCredentials,
        client: reqwest::Client,
    ) -> Self {
        let mut tm = Self::new(account_key, provider, store, api_context, initial);
        tm.client = client;
        tm
    }

    /// The current cached access token.
    pub async fn access_token(&self) -> String {
        self.cached.read().await.access_token.clone()
    }

    pub fn client(&self) -> &reqwest::Client {
        &self.client
    }

    pub fn account_key(&self) -> &str {
        &self.account_key
    }

    /// The provider's OAuth client credentials from the encrypted store, if the
    /// host has supplied them (see `SyncEngine::set_oauth_client`). Present →
    /// refresh goes directly to the provider; absent → Rails proxy fallback.
    fn oauth_client_config(&self) -> Option<OAuthClientConfig> {
        let key = oauth_client_secret_key(&self.provider)?;
        let raw = self.store.get_app_secret(key).ok().flatten()?;
        match serde_json::from_str(&raw) {
            Ok(config) => Some(config),
            Err(e) => {
                log::error!(
                    "[oauth] {} ({}): stored OAuth client config is unreadable ({e}); falling back to proxy refresh",
                    self.account_key,
                    self.provider.as_str()
                );
                None
            }
        }
    }

    /// Update the in-memory cache and persist the (possibly rotated) tokens back
    /// to the encrypted credential store.
    async fn persist_refreshed(
        &self,
        username: String,
        access_token: String,
        refresh_token: String,
    ) -> Result<()> {
        {
            let mut c = self.cached.write().await;
            c.access_token = access_token.clone();
            c.refresh_token = Some(refresh_token.clone());
        }
        self.store.store_credentials(
            &self.account_key,
            &ProviderCredentials::OAuth2 {
                username,
                access_token,
                refresh_token: Some(refresh_token),
            },
        )?;
        // Mark the credential dirty so the engine's backup drain re-uploads the
        // rotated token to the cloud vault (no-op if backup is off / vault locked).
        let _ = self.store.mark_backup_dirty(&self.account_key);
        Ok(())
    }

    /// Refresh the access token and persist it, returning the new access token.
    /// Prefers the direct provider token endpoint (no proxy) when client
    /// credentials are configured; otherwise refreshes via the Rails proxy.
    pub async fn refresh(&self) -> Result<String> {
        let (refresh_token, username) = {
            let c = self.cached.read().await;
            (c.refresh_token.clone(), c.username.clone())
        };
        let provider = self.provider.as_str();
        let account_key = &self.account_key;
        let refresh_token = match refresh_token {
            Some(t) => t,
            None => {
                log::error!(
                    "[oauth] {account_key} ({provider}): token refresh impossible — no refresh token on file; account must be re-authenticated"
                );
                return Err(SyncError::TokenRefresh("no refresh token on file".into()));
            }
        };

        if let Some(config) = self.oauth_client_config() {
            return self.refresh_direct(&config, refresh_token, username).await;
        }

        let ctx = match self.api_context.read().await.clone() {
            Some(ctx) => ctx,
            None => {
                log::error!(
                    "[oauth] {account_key} ({provider}): token refresh impossible — API base not set (call override_api_base/set_api_context)"
                );
                return Err(SyncError::TokenRefresh(
                    "API base not set (call override_api_base/set_api_context)".into(),
                ));
            }
        };

        let path = match self.provider {
            ProviderType::Gmail => "auth/google/refresh",
            ProviderType::Microsoft => "auth/microsoft/refresh",
            ProviderType::Imap => {
                return Err(SyncError::TokenRefresh("IMAP has no OAuth refresh".into()))
            }
            ProviderType::Instagram | ProviderType::Messenger | ProviderType::WhatsApp => {
                return Err(SyncError::TokenRefresh(
                    "Meta System User token is permanent — no refresh".into(),
                ))
            }
        };
        let url = format!("{}/{}", ctx.api_base.trim_end_matches('/'), path);
        log::info!("[oauth] {account_key} ({provider}): refreshing access token via proxy at {url}");

        // The proxy's refresh endpoint is public — it holds the OAuth client secret
        // and performs the exchange with Google/Microsoft itself, so no Rails auth is
        // required (mirroring the public authorize/token endpoints). Attach the bearer
        // only when we actually have one (e.g. desktop); iOS never signs into Rails.
        let mut rb = self
            .client
            .post(&url)
            .json(&serde_json::json!({ "refresh_token": refresh_token }));
        if !ctx.rails_jwt.is_empty() {
            rb = rb.header("Authorization", format!("Bearer {}", ctx.rails_jwt));
        }
        let resp = match rb.send().await {
            Ok(resp) => resp,
            Err(e) => {
                // Network-level failure reaching the proxy — transient, but log it
                // so an offline/blocked device is distinguishable from a rejected
                // token in the logs.
                log::warn!(
                    "[oauth] {account_key} ({provider}): token refresh request failed to reach proxy: {e}"
                );
                return Err(e.into());
            }
        };

        if !resp.status().is_success() {
            let status = resp.status();
            // Capture the proxy's body — it usually carries the provider's reason
            // (e.g. `invalid_grant` when the refresh token has been revoked).
            let body = resp.text().await.unwrap_or_default();
            let detail = body.trim();
            // Only a client-side rejection (4xx, e.g. `invalid_grant`) means the
            // stored refresh token is actually dead and the user must re-auth. A
            // 5xx/429 from the proxy or its upstream is a transient outage — the
            // next sync will retry — so it must NOT flag the account NeedsReauth.
            // Returning `TokenRefresh` for every non-success is what made a brief
            // proxy hiccup look like an expired sign-in.
            let transient = status.is_server_error()
                || status == reqwest::StatusCode::TOO_MANY_REQUESTS;
            let context = format!(
                "proxy returned {status}{}{}",
                if detail.is_empty() { "" } else { ": " },
                detail
            );
            if transient {
                log::warn!(
                    "[oauth] {account_key} ({provider}): token refresh transiently failed — HTTP {status}; will retry on next sync"
                );
                return Err(SyncError::Http(context));
            }
            log::error!(
                "[oauth] {account_key} ({provider}): token refresh REJECTED by proxy — HTTP {status}{}{}; the stored refresh token is likely revoked/expired — account must be re-authenticated",
                if detail.is_empty() { "" } else { ": " },
                detail
            );
            return Err(SyncError::TokenRefresh(context));
        }

        let body: RefreshResponse = resp.json().await?;

        let next_refresh = body.refresh_token.clone().unwrap_or(refresh_token);
        self.persist_refreshed(username, body.access_token.clone(), next_refresh)
            .await?;
        log::info!("[oauth] {account_key} ({provider}): access token refreshed (via proxy)");

        Ok(body.access_token)
    }

    /// Refresh directly against the provider's token endpoint — no Rails proxy.
    /// This is the preferred path: the proxy is only needed for first auth.
    async fn refresh_direct(
        &self,
        config: &OAuthClientConfig,
        refresh_token: String,
        username: String,
    ) -> Result<String> {
        let provider = self.provider.as_str();
        let account_key = &self.account_key;
        let default_url = match self.provider {
            ProviderType::Gmail => GOOGLE_TOKEN_URL,
            ProviderType::Microsoft => MICROSOFT_TOKEN_URL,
            ProviderType::Imap => {
                return Err(SyncError::TokenRefresh("IMAP has no OAuth refresh".into()))
            }
            ProviderType::Instagram | ProviderType::Messenger | ProviderType::WhatsApp => {
                return Err(SyncError::TokenRefresh(
                    "Meta System User token is permanent — no refresh".into(),
                ))
            }
        };
        let url = config.token_url.as_deref().unwrap_or(default_url);
        log::info!(
            "[oauth] {account_key} ({provider}): refreshing access token directly at {url}"
        );

        let mut form = vec![
            ("grant_type", "refresh_token".to_string()),
            ("refresh_token", refresh_token.clone()),
            ("client_id", config.client_id.clone()),
        ];
        if let Some(secret) = &config.client_secret {
            form.push(("client_secret", secret.clone()));
        }
        if self.provider == ProviderType::Microsoft {
            form.push(("scope", MICROSOFT_SCOPES.to_string()));
        }

        let resp = match self.client.post(url).form(&form).send().await {
            Ok(resp) => resp,
            Err(e) => {
                // Network-level failure reaching the provider — transient.
                log::warn!(
                    "[oauth] {account_key} ({provider}): direct token refresh failed to reach {url}: {e}"
                );
                return Err(e.into());
            }
        };

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            let detail = body.trim();
            // Same classification as the proxy path: a 4xx (`invalid_grant`)
            // means the refresh token is dead → re-auth; a 5xx/429 is a provider
            // hiccup the next sync retries.
            let transient = status.is_server_error()
                || status == reqwest::StatusCode::TOO_MANY_REQUESTS;
            let context = format!(
                "{provider} token endpoint returned {status}{}{}",
                if detail.is_empty() { "" } else { ": " },
                detail
            );
            if transient {
                log::warn!(
                    "[oauth] {account_key} ({provider}): direct token refresh transiently failed — HTTP {status}; will retry on next sync"
                );
                return Err(SyncError::Http(context));
            }
            log::error!(
                "[oauth] {account_key} ({provider}): token refresh REJECTED by provider — HTTP {status}{}{}; the stored refresh token is likely revoked/expired — account must be re-authenticated",
                if detail.is_empty() { "" } else { ": " },
                detail
            );
            return Err(SyncError::TokenRefresh(context));
        }

        let body: RefreshResponse = resp.json().await?;

        let next_refresh = body.refresh_token.clone().unwrap_or(refresh_token);
        self.persist_refreshed(username, body.access_token.clone(), next_refresh)
            .await?;
        log::info!("[oauth] {account_key} ({provider}): access token refreshed (direct)");

        Ok(body.access_token)
    }

    /// Send an authenticated JSON request, retrying once with a refreshed token
    /// on `401` and up to [`MAX_RATE_RETRIES`] times on `429 Too Many Requests`
    /// (honoring `Retry-After`). `body` is sent as JSON when present. Returns the
    /// final response. Retrying is safe for mutating requests because a rate-
    /// limited request never applied.
    pub async fn request(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<&serde_json::Value>,
    ) -> Result<reqwest::Response> {
        let send = |token: &str| {
            let mut rb = self
                .client
                .request(method.clone(), url)
                .header("Authorization", format!("Bearer {token}"));
            if let Some(b) = body {
                rb = rb.json(b);
            } else if matches!(
                method,
                reqwest::Method::POST
                    | reqwest::Method::PUT
                    | reqwest::Method::PATCH
                    | reqwest::Method::DELETE
            ) {
                // Body-less mutating requests (e.g. Gmail's `/trash`, `/untrash`)
                // must send `Content-Length: 0` or Google rejects them with
                // `411 Length Required`. reqwest omits the header otherwise.
                rb = rb.header(reqwest::header::CONTENT_LENGTH, 0);
            }
            rb.send()
        };
        self.run_with_retries(url, send).await
    }

    /// An authenticated GET with a `Prefer` header — Graph's
    /// `outlook.timezone="…"`, which returns event times in that zone rather
    /// than UTC.
    pub async fn get_with_prefer(&self, url: &str, prefer: &str) -> Result<reqwest::Response> {
        let send = |token: &str| {
            self.client
                .get(url)
                .header("Authorization", format!("Bearer {token}"))
                .header("Prefer", prefer)
                .send()
        };
        self.run_with_retries(url, send).await
    }

    /// Like [`request`](Self::request) but with a raw text body and explicit
    /// content type — Graph's raw-MIME `sendMail` wants a base64 RFC 822
    /// message as `text/plain`, which the JSON variant can't express.
    pub async fn request_text(
        &self,
        method: reqwest::Method,
        url: &str,
        content_type: &str,
        body: String,
    ) -> Result<reqwest::Response> {
        let send = |token: &str| {
            self.client
                .request(method.clone(), url)
                .header("Authorization", format!("Bearer {token}"))
                .header(reqwest::header::CONTENT_TYPE, content_type)
                .body(body.clone())
                .send()
        };
        self.run_with_retries(url, send).await
    }

    /// The shared retry loop: one token refresh on `401`, capped backoff on
    /// `429` (honoring `Retry-After`). Retrying is safe for mutating requests
    /// because a rate-limited request never applied.
    async fn run_with_retries<F, Fut>(&self, url: &str, send: F) -> Result<reqwest::Response>
    where
        F: Fn(&str) -> Fut,
        Fut: std::future::Future<Output = reqwest::Result<reqwest::Response>>,
    {
        let mut token = self.access_token().await;
        let mut refreshed = false;
        let mut rate_retries = 0u32;
        loop {
            let resp = send(&token).await?;
            let status = resp.status();

            if status == reqwest::StatusCode::UNAUTHORIZED && !refreshed {
                token = self.refresh().await?;
                refreshed = true;
                continue;
            }

            if status == reqwest::StatusCode::TOO_MANY_REQUESTS
                && rate_retries < MAX_RATE_RETRIES
            {
                let delay = retry_after(&resp)
                    .unwrap_or_else(|| Duration::from_secs(2u64.pow(rate_retries + 1)));
                rate_retries += 1;
                log::warn!(
                    "{} rate-limited (429); retry {}/{} after {:?}",
                    url,
                    rate_retries,
                    MAX_RATE_RETRIES,
                    delay
                );
                tokio::time::sleep(delay).await;
                continue;
            }

            return Ok(resp);
        }
    }
}

/// Maximum retries on `429 Too Many Requests` before giving up and surfacing the
/// rate-limit error to the caller (which aborts that folder's sync cleanly).
const MAX_RATE_RETRIES: u32 = 3;

/// Cap on how long we'll honor a server's `Retry-After`, so a hostile or buggy
/// value can't stall a sync indefinitely.
const MAX_RETRY_AFTER: Duration = Duration::from_secs(30);

/// Parse a `Retry-After` header (delta-seconds form) into a capped `Duration`.
fn retry_after(resp: &reqwest::Response) -> Option<Duration> {
    let secs: u64 = resp
        .headers()
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse()
        .ok()?;
    Some(Duration::from_secs(secs).min(MAX_RETRY_AFTER))
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn oauth_creds() -> ProviderCredentials {
        ProviderCredentials::OAuth2 {
            username: "user@gmail.com".to_string(),
            access_token: "old-token".to_string(),
            refresh_token: Some("refresh-abc".to_string()),
        }
    }

    async fn token_manager_for(server: &MockServer) -> TokenManager {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        // The account must exist so store_credentials' row has somewhere to live.
        let account_key = store
            .create_account(&crate::sync::model::ExternalAccount {
                key: String::new(),
                display_name: "G".into(),
                email_address: "user@gmail.com".into(),
                provider_type: ProviderType::Gmail,
                host: None,
                port: None,
                use_tls: true,
                smtp_host: None,
                smtp_port: None,
                smtp_use_tls: true,
                auth_method: crate::sync::model::AuthMethod::OAuth2.as_str().into(),
                status: crate::sync::model::AccountStatus::Disconnected,
                error_message: None,
                last_connected_at: None,
                sort_order: 0,
                avatar_url: None,
            })
            .unwrap();
        let ctx = Arc::new(RwLock::new(Some(ApiContext {
            api_base: format!("{}/api/v1", server.uri()),
            rails_jwt: "jwt-123".into(),
        })));
        TokenManager::new(account_key, ProviderType::Gmail, store, ctx, &oauth_creds())
    }

    #[tokio::test]
    async fn refresh_posts_to_proxy_and_updates_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v1/auth/google/refresh"))
            .and(header("authorization", "Bearer jwt-123"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "access_token": "fresh-token",
                    "expires_in": 3600
                })),
            )
            .mount(&server)
            .await;

        let tm = token_manager_for(&server).await;
        assert_eq!(tm.access_token().await, "old-token");

        let new = tm.refresh().await.unwrap();
        assert_eq!(new, "fresh-token");
        assert_eq!(tm.access_token().await, "fresh-token");

        // Persisted back to the store.
        let stored = tm.store.get_credentials(&tm.account_key).unwrap().unwrap();
        match stored {
            ProviderCredentials::OAuth2 {
                access_token,
                refresh_token,
                ..
            } => {
                assert_eq!(access_token, "fresh-token");
                assert_eq!(refresh_token.as_deref(), Some("refresh-abc"));
            }
            _ => panic!("expected oauth2 creds"),
        }
    }

    #[tokio::test]
    async fn refresh_without_jwt_omits_bearer_and_succeeds() {
        // iOS path: an API base but no Rails JWT. The proxy's refresh endpoint is
        // public, so the request must go out with NO Authorization header and still
        // succeed. The mock only matches when the header is absent.
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v1/auth/google/refresh"))
            .and(|req: &wiremock::Request| req.headers.get("authorization").is_none())
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(serde_json::json!({ "access_token": "fresh-token" })),
            )
            .mount(&server)
            .await;

        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let account_key = store
            .create_account(&crate::sync::model::ExternalAccount {
                key: String::new(),
                display_name: "G".into(),
                email_address: "user@gmail.com".into(),
                provider_type: ProviderType::Gmail,
                host: None,
                port: None,
                use_tls: true,
                smtp_host: None,
                smtp_port: None,
                smtp_use_tls: true,
                auth_method: crate::sync::model::AuthMethod::OAuth2.as_str().into(),
                status: crate::sync::model::AccountStatus::Disconnected,
                error_message: None,
                last_connected_at: None,
                sort_order: 0,
                avatar_url: None,
            })
            .unwrap();
        let ctx = Arc::new(RwLock::new(Some(ApiContext {
            api_base: format!("{}/api/v1", server.uri()),
            rails_jwt: String::new(), // no Rails sign-in (iOS)
        })));
        let tm =
            TokenManager::new(account_key, ProviderType::Gmail, store, ctx, &oauth_creds());

        let new = tm.refresh().await.unwrap();
        assert_eq!(new, "fresh-token");
        assert_eq!(tm.access_token().await, "fresh-token");
    }

    /// Store OAuth client credentials (with the token endpoint pointed at the
    /// mock server) so refresh takes the direct path.
    fn configure_direct_client(tm: &TokenManager, server: &MockServer) {
        let config = OAuthClientConfig {
            client_id: "client-123".into(),
            client_secret: Some("secret-456".into()),
            token_url: Some(format!("{}/provider/token", server.uri())),
        };
        tm.store
            .store_app_secret(
                SECRET_OAUTH_CLIENT_GOOGLE,
                &serde_json::to_string(&config).unwrap(),
            )
            .unwrap();
    }

    #[tokio::test]
    async fn refresh_goes_direct_when_client_credentials_configured() {
        let server = MockServer::start().await;
        // The provider endpoint answers (and rotates the refresh token); the
        // proxy must NOT be hit at all.
        Mock::given(method("POST"))
            .and(path("/provider/token"))
            .and(wiremock::matchers::body_string_contains("grant_type=refresh_token"))
            .and(wiremock::matchers::body_string_contains("client_id=client-123"))
            .and(wiremock::matchers::body_string_contains("client_secret=secret-456"))
            .and(wiremock::matchers::body_string_contains("refresh_token=refresh-abc"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "fresh-token",
                "refresh_token": "rotated-refresh",
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/v1/auth/google/refresh"))
            .respond_with(ResponseTemplate::new(500))
            .expect(0)
            .mount(&server)
            .await;

        let tm = token_manager_for(&server).await;
        configure_direct_client(&tm, &server);

        let new = tm.refresh().await.unwrap();
        assert_eq!(new, "fresh-token");

        // The rotated refresh token is persisted (Microsoft rotates on every
        // refresh; keeping the old one would eventually hit invalid_grant).
        let stored = tm.store.get_credentials(&tm.account_key).unwrap().unwrap();
        match stored {
            ProviderCredentials::OAuth2 { access_token, refresh_token, .. } => {
                assert_eq!(access_token, "fresh-token");
                assert_eq!(refresh_token.as_deref(), Some("rotated-refresh"));
            }
            _ => panic!("expected oauth2 creds"),
        }
    }

    #[tokio::test]
    async fn direct_refresh_invalid_grant_is_auth_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/provider/token"))
            .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                "error": "invalid_grant",
                "error_description": "Token has been expired or revoked.",
            })))
            .mount(&server)
            .await;

        let tm = token_manager_for(&server).await;
        configure_direct_client(&tm, &server);

        let err = tm.refresh().await.unwrap_err();
        assert!(
            matches!(err, SyncError::TokenRefresh(_)),
            "a provider 4xx (invalid_grant) must flag re-auth, got: {err}"
        );
        assert!(err.is_auth());
    }

    #[tokio::test]
    async fn direct_refresh_5xx_is_transient_not_auth() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/provider/token"))
            .respond_with(ResponseTemplate::new(503))
            .mount(&server)
            .await;

        let tm = token_manager_for(&server).await;
        configure_direct_client(&tm, &server);

        let err = tm.refresh().await.unwrap_err();
        assert!(
            !err.is_auth(),
            "a provider 5xx must NOT look like an expired sign-in, got: {err}"
        );
    }

    #[tokio::test]
    async fn proxy_refresh_persists_rotated_refresh_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v1/auth/google/refresh"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "fresh-token",
                "refresh_token": "rotated-refresh",
            })))
            .mount(&server)
            .await;

        let tm = token_manager_for(&server).await;
        tm.refresh().await.unwrap();

        let stored = tm.store.get_credentials(&tm.account_key).unwrap().unwrap();
        match stored {
            ProviderCredentials::OAuth2 { refresh_token, .. } => {
                assert_eq!(refresh_token.as_deref(), Some("rotated-refresh"));
            }
            _ => panic!("expected oauth2 creds"),
        }
    }

    #[tokio::test]
    async fn request_retries_once_on_401_then_succeeds() {
        let server = MockServer::start().await;

        // Refresh endpoint.
        Mock::given(method("POST"))
            .and(path("/api/v1/auth/google/refresh"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(serde_json::json!({ "access_token": "fresh-token" })),
            )
            .mount(&server)
            .await;

        // Resource: rejects the stale token, accepts the fresh one.
        Mock::given(method("GET"))
            .and(path("/resource"))
            .and(header("authorization", "Bearer old-token"))
            .respond_with(ResponseTemplate::new(401))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/resource"))
            .and(header("authorization", "Bearer fresh-token"))
            .respond_with(ResponseTemplate::new(200).set_body_string("ok"))
            .mount(&server)
            .await;

        let tm = token_manager_for(&server).await;
        let url = format!("{}/resource", server.uri());
        let resp = tm.request(reqwest::Method::GET, &url, None).await.unwrap();
        assert!(resp.status().is_success());
        assert_eq!(resp.text().await.unwrap(), "ok");
        assert_eq!(tm.access_token().await, "fresh-token");
    }

    #[tokio::test]
    async fn request_retries_on_429_then_succeeds() {
        let server = MockServer::start().await;
        // First call is rate-limited (Retry-After: 0 keeps the test instant),
        // then the retry succeeds.
        Mock::given(method("GET"))
            .and(path("/rl"))
            .respond_with(ResponseTemplate::new(429).insert_header("retry-after", "0"))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/rl"))
            .respond_with(ResponseTemplate::new(200).set_body_string("ok"))
            .mount(&server)
            .await;

        let tm = token_manager_for(&server).await;
        let url = format!("{}/rl", server.uri());
        let resp = tm.request(reqwest::Method::GET, &url, None).await.unwrap();
        assert!(resp.status().is_success(), "429 should be retried to success");
        assert_eq!(resp.text().await.unwrap(), "ok");
    }

    #[tokio::test]
    async fn body_less_mutating_request_sets_content_length_zero() {
        // Regression: Gmail's `/trash` (and `DELETE`) are body-less mutating
        // requests. reqwest omits `Content-Length` for them, so Google replied
        // `411 Length Required`. The mock only matches when the header is "0";
        // without the fix the request 404s (no match) and the assert fails.
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/trash"))
            .and(header("content-length", "0"))
            .respond_with(ResponseTemplate::new(200).set_body_string("ok"))
            .mount(&server)
            .await;

        let tm = token_manager_for(&server).await;
        let url = format!("{}/trash", server.uri());
        let resp = tm
            .request(reqwest::Method::POST, &url, None)
            .await
            .unwrap();
        assert!(
            resp.status().is_success(),
            "body-less POST should send Content-Length: 0; got {}",
            resp.status()
        );
    }
}
