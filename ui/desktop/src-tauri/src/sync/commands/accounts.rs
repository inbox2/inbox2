//! External-account CRUD, account creation on the engine, and credential
//! retrieval for the JS sync engines to boot on launch.

use serde::{Deserialize, Serialize};
use tauri::State;

use super::SyncState;
use crate::sync::engine::SyncEngine;
use crate::sync::error::SyncError;
use crate::sync::model::*;

#[derive(Debug, Serialize, Deserialize)]
pub struct AddAccountRequest {
    pub display_name: String,
    pub email_address: String,
    pub provider_type: String,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub use_tls: Option<bool>,
    pub smtp_host: Option<String>,
    pub smtp_port: Option<u16>,
    pub smtp_use_tls: Option<bool>,
    pub auth_method: Option<String>,
    pub username: String,
    pub password: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    /// Mirror this account's credentials to the zero-knowledge cloud vault
    /// (docs/E2EE.md). On by default in the UI; gated on a signed-in inbox2 account.
    #[serde(default)]
    pub cloud_backup: Option<bool>,
}

/// BYOK Meta connection. The customer's app secret + System User token stay
/// on-device; only asset-id routing is later reported to the relay. See
/// docs/Cloud-Push.md (Meta).
#[derive(Debug, Serialize, Deserialize)]
pub struct AddMetaAccountRequest {
    pub channel: String, // instagram | messenger | whatsapp
    pub display_name: Option<String>,
    pub app_id: String,
    pub app_secret: String,
    pub system_user_token: String,
    pub facebook_page_id: Option<String>,
    pub instagram_account_id: Option<String>,
    pub whatsapp_phone_number_id: Option<String>,
    pub whatsapp_business_account_id: Option<String>,
    /// Reuse another Meta account's app credentials (app id + app secret +
    /// System User token) instead of re-entering them. When set, the operator
    /// only supplies the new channel's asset id. The secrets are copied from the
    /// source account's on-device encrypted bundle and never leave the device.
    pub reuse_credentials_from: Option<String>,
    /// Mirror this account's credentials to the cloud vault (docs/E2EE.md).
    #[serde(default)]
    pub cloud_backup: Option<bool>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AccountResponse {
    pub key: String,
    pub display_name: String,
    pub email_address: String,
    pub provider_type: String,
    pub status: String,
    pub error_message: Option<String>,
    pub avatar_url: Option<String>,
    /// The Meta app id (non-secret) for Meta accounts, so the UI can group
    /// channels that share one app and offer credential reuse. `None` for
    /// non-Meta accounts (and Meta accounts created without an app id).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meta_app_id: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CredentialsResponse {
    pub auth_method: String,
    pub username: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
}

#[tauri::command]
pub async fn add_external_account(
    state: State<'_, SyncState>,
    request: AddAccountRequest,
) -> Result<AccountResponse, SyncError> {
    // Client mode: the host owns the engine that performs sync, so create +
    // register the account there. It writes to the shared DB (which we read
    // back for the UI) and registers in the host's in-memory map so the
    // subsequent start_sync actually syncs. Doing it locally would register
    // the account only in this client engine, which never syncs.
    if let Some(bus) = &state.bus {
        let params = serde_json::to_value(&request).map_err(|e| SyncError::Other(e.to_string()))?;
        let resp = bus.call("add_external_account", params).map_err(SyncError::Other)?;
        return serde_json::from_value(resp).map_err(|e| SyncError::Other(e.to_string()));
    }
    create_account_on_engine(&state.engine, request).await
}

/// Derive a likely SMTP submission host from an IMAP host: `imap.example.com`
/// → `smtp.example.com`, otherwise prefix the bare domain with `smtp.`. Returns
/// `None` for an empty host so the caller can leave SMTP unconfigured.
fn derive_smtp_host(imap_host: &str) -> Option<String> {
    let h = imap_host.trim();
    if h.is_empty() {
        return None;
    }
    let lower = h.to_lowercase();
    if let Some(rest) = lower.strip_prefix("imap.") {
        Some(format!("smtp.{rest}"))
    } else if lower.starts_with("smtp.") {
        Some(lower)
    } else {
        Some(format!("smtp.{lower}"))
    }
}

/// Create an account in the store, persist its credentials, and register it
/// with the engine. State-free so both the Tauri command and the bus RPC
/// (host side) share one implementation.
pub async fn create_account_on_engine(
    engine: &SyncEngine,
    request: AddAccountRequest,
) -> Result<AccountResponse, SyncError> {
    let provider_type = ProviderType::from_str(&request.provider_type)
        .ok_or_else(|| SyncError::Other(format!("unknown provider: {}", request.provider_type)))?;

    let host = request.host.unwrap_or_default();
    let port = request.port.unwrap_or(993);
    let use_tls = request.use_tls.unwrap_or(true);
    let auth_method = request.auth_method.as_deref().unwrap_or("plain");

    // SMTP submission config (IMAP send). When the UI leaves it blank, derive a
    // sensible default from the IMAP host (e.g. imap.example.com → smtp.example.com)
    // and default to implicit TLS on 465.
    let (smtp_host, smtp_port, smtp_use_tls) = if provider_type == ProviderType::Imap {
        let derived_host = request
            .smtp_host
            .clone()
            .filter(|h| !h.is_empty())
            .or_else(|| derive_smtp_host(&host));
        let smtp_use_tls = request.smtp_use_tls.unwrap_or(true);
        let smtp_port = request
            .smtp_port
            .unwrap_or(if smtp_use_tls { 465 } else { 587 });
        (derived_host, Some(smtp_port), smtp_use_tls)
    } else {
        (None, None, true)
    };

    // `auth_method` is persisted verbatim; only the credential shape is derived
    // here (xoauth2 is an OAuth2 synonym — see AuthMethod).
    let credentials = if AuthMethod::from_str(auth_method).is_oauth() {
        ProviderCredentials::OAuth2 {
            username: request.username.clone(),
            access_token: request.access_token.unwrap_or_default(),
            refresh_token: request.refresh_token,
        }
    } else {
        ProviderCredentials::Password {
            username: request.username.clone(),
            password: request.password.unwrap_or_default(),
        }
    };

    // Create account in store
    let account = ExternalAccount {
        key: String::new(), // Generated by store
        display_name: request.display_name.clone(),
        email_address: request.email_address.clone(),
        provider_type: provider_type.clone(),
        host: Some(host.clone()),
        port: Some(port),
        use_tls,
        smtp_host: smtp_host.clone(),
        smtp_port,
        smtp_use_tls,
        auth_method: auth_method.to_string(),
        status: AccountStatus::Disconnected,
        error_message: None,
        last_connected_at: None,
        sort_order: 0,
        avatar_url: None,
    };

    let account_key = engine.store().create_account(&account)?;

    // Store encrypted credentials
    engine.store().store_credentials(&account_key, &credentials)?;

    // Cloud credential backup (docs/E2EE.md): flag + mark dirty so the engine's
    // backup drain uploads it once the vault is unlocked. No-op if not opted in.
    if request.cloud_backup.unwrap_or(false) {
        let _ = engine.store().set_account_backup_enabled(&account_key, true);
        let _ = engine.store().mark_backup_dirty(&account_key);
    }

    // Register with engine
    engine
        .add_account(&account_key, &provider_type, &host, port, use_tls, credentials)
        .await?;

    Ok(AccountResponse {
        key: account_key,
        display_name: request.display_name,
        email_address: request.email_address,
        provider_type: provider_type.as_str().to_string(),
        status: "disconnected".to_string(),
        error_message: None,
        avatar_url: None,
        meta_app_id: None,
    })
}

#[tauri::command]
pub async fn add_meta_account(
    state: State<'_, SyncState>,
    request: AddMetaAccountRequest,
) -> Result<AccountResponse, SyncError> {
    // Client mode: route to the host engine (same rationale as add_external_account).
    if let Some(bus) = &state.bus {
        let params = serde_json::to_value(&request).map_err(|e| SyncError::Other(e.to_string()))?;
        let resp = bus.call("add_meta_account", params).map_err(SyncError::Other)?;
        return serde_json::from_value(resp).map_err(|e| SyncError::Other(e.to_string()));
    }
    create_meta_account_on_engine(&state.engine, request).await
}

/// Create a Meta BYOK account in the store, persist its encrypted credential
/// bundle, and register it with the engine. Shared by the Tauri command and the
/// host-side bus RPC.
/// The required primary asset id per channel, validated after asset discovery:
/// WhatsApp → phone_number_id (send target), Messenger → Page id, Instagram → IG
/// account id. Errors with a manual-entry hint when discovery couldn't resolve it.
fn meta_primary_asset(provider: &ProviderType, c: &MetaCredentials) -> Result<String, SyncError> {
    let (id, missing) = match provider {
        ProviderType::WhatsApp => (&c.whatsapp_phone_number_id, "WhatsApp phone number"),
        ProviderType::Instagram => (&c.instagram_account_id, "Instagram account"),
        ProviderType::Messenger => (&c.facebook_page_id, "Facebook Page"),
        _ => (&None, "asset"),
    };
    id.clone()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| SyncError::Other(format!(
            "Meta: couldn't auto-detect the {missing} — check the System User token's permissions and that the asset is assigned to it"
        )))
}

/// Resolve the app-level Meta credentials (app id + app secret + System User
/// token) for a new channel: either reused from an existing Meta account's
/// on-device bundle (`reuse_credentials_from`) or taken from the request.
fn resolve_meta_app_credentials(
    engine: &SyncEngine,
    request: &AddMetaAccountRequest,
) -> Result<(String, String, String), SyncError> {
    if let Some(source_key) = request.reuse_credentials_from.as_deref().filter(|s| !s.is_empty()) {
        match engine.store().get_credentials(source_key)? {
            Some(ProviderCredentials::Meta(c)) => {
                Ok((c.app_id, c.app_secret, c.system_user_token))
            }
            Some(_) => Err(SyncError::Other(
                "Meta: the selected account to reuse credentials from is not a Meta account".into(),
            )),
            None => Err(SyncError::Other(
                "Meta: couldn't find the account to reuse credentials from".into(),
            )),
        }
    } else if request.app_secret.is_empty() || request.system_user_token.is_empty() {
        Err(SyncError::Other(
            "Meta: app_secret and System User token are required".into(),
        ))
    } else {
        Ok((
            request.app_id.clone(),
            request.app_secret.clone(),
            request.system_user_token.clone(),
        ))
    }
}

pub async fn create_meta_account_on_engine(
    engine: &SyncEngine,
    request: AddMetaAccountRequest,
) -> Result<AccountResponse, SyncError> {
    let provider_type = ProviderType::from_str(&request.channel)
        .filter(ProviderType::is_meta)
        .ok_or_else(|| SyncError::Other(format!("unknown Meta channel: {}", request.channel)))?;

    let (app_id, app_secret, system_user_token) = resolve_meta_app_credentials(engine, &request)?;
    let channel = provider_type
        .meta_channel()
        .ok_or_else(|| SyncError::Other("not a Meta channel".into()))?;

    // Build the BYOK bundle, then auto-derive the secondary asset id (WABA→phone,
    // Page→Instagram account) so the operator only supplies one id per channel.
    let partial = MetaCredentials {
        app_id,
        app_secret,
        system_user_token,
        facebook_page_id: request.facebook_page_id.filter(|s| !s.is_empty()),
        instagram_account_id: request.instagram_account_id.filter(|s| !s.is_empty()),
        whatsapp_phone_number_id: request.whatsapp_phone_number_id.filter(|s| !s.is_empty()),
        whatsapp_business_account_id: request.whatsapp_business_account_id.filter(|s| !s.is_empty()),
        ..Default::default()
    };
    let (meta_creds, suggested_name) = engine.discover_meta_assets(channel, partial).await;

    // The primary asset (dedup/display key) must resolve after discovery; a clear
    // error tells the operator to supply the id manually if it couldn't.
    let primary_asset = meta_primary_asset(&provider_type, &meta_creds)?;
    let email_address = format!("{}:{}", provider_type.as_str(), primary_asset);
    // Display name: explicit > the Meta app's name (from the token) > the key.
    let display_name = request
        .display_name
        .clone()
        .filter(|s| !s.is_empty())
        .or(suggested_name)
        .unwrap_or_else(|| email_address.clone());

    let meta_app_id = Some(meta_creds.app_id.clone()).filter(|s| !s.is_empty());
    let credentials = ProviderCredentials::Meta(meta_creds);

    let account = ExternalAccount {
        key: String::new(),
        display_name: display_name.clone(),
        email_address: email_address.clone(),
        provider_type: provider_type.clone(),
        host: None,
        port: None,
        use_tls: false,
        smtp_host: None,
        smtp_port: None,
        smtp_use_tls: false,
        auth_method: "meta".to_string(),
        status: AccountStatus::Disconnected,
        error_message: None,
        last_connected_at: None,
        sort_order: 0,
        avatar_url: None,
    };

    let account_key = engine.store().create_account(&account)?;
    engine.store().store_credentials(&account_key, &credentials)?;
    if request.cloud_backup.unwrap_or(false) {
        let _ = engine.store().set_account_backup_enabled(&account_key, true);
        let _ = engine.store().mark_backup_dirty(&account_key);
    }
    engine
        .add_account(&account_key, &provider_type, "", 0, false, credentials)
        .await?;

    Ok(AccountResponse {
        key: account_key,
        display_name,
        email_address,
        provider_type: provider_type.as_str().to_string(),
        status: "disconnected".to_string(),
        error_message: None,
        avatar_url: None,
        meta_app_id,
    })
}

/// Create an Instagram account on the **Instagram-Login** path from a completed
/// OAuth exchange (long-lived user token). Mirrors `create_meta_account_on_engine`
/// but builds Instagram-Login credentials (no System User token / Page) and
/// resolves the account id + @username via `GET /me` (in `discover_assets`).
pub async fn create_instagram_login_account_on_engine(
    engine: &SyncEngine,
    app_id: String,
    app_secret: String,
    user_token: String,
    token_expires_at: Option<String>,
    display_name: Option<String>,
) -> Result<AccountResponse, SyncError> {
    let provider_type = ProviderType::Instagram;
    let channel = provider_type
        .meta_channel()
        .ok_or_else(|| SyncError::Other("not a Meta channel".into()))?;

    let partial = MetaCredentials {
        instagram_app_id: Some(app_id),
        instagram_app_secret: Some(app_secret),
        instagram_user_token: Some(user_token),
        instagram_token_expires_at: token_expires_at,
        ..Default::default()
    };
    let (meta_creds, suggested_name) = engine.discover_meta_assets(channel, partial).await;

    let ig_id = meta_creds
        .instagram_account_id
        .clone()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| SyncError::Other("Instagram: couldn't resolve the account id from the token".into()))?;
    let email_address = format!("{}:{}", provider_type.as_str(), ig_id);
    let display_name = display_name
        .filter(|s| !s.is_empty())
        .or(suggested_name)
        .unwrap_or_else(|| email_address.clone());

    let credentials = ProviderCredentials::Meta(meta_creds);
    let account = ExternalAccount {
        key: String::new(),
        display_name: display_name.clone(),
        email_address: email_address.clone(),
        provider_type: provider_type.clone(),
        host: None,
        port: None,
        use_tls: false,
        smtp_host: None,
        smtp_port: None,
        smtp_use_tls: false,
        auth_method: "instagram_login".to_string(),
        status: AccountStatus::Disconnected,
        error_message: None,
        last_connected_at: None,
        sort_order: 0,
        avatar_url: None,
    };
    let account_key = engine.store().create_account(&account)?;
    engine.store().store_credentials(&account_key, &credentials)?;
    engine
        .add_account(&account_key, &provider_type, "", 0, false, credentials)
        .await?;

    Ok(AccountResponse {
        key: account_key,
        display_name,
        email_address,
        provider_type: provider_type.as_str().to_string(),
        status: "disconnected".to_string(),
        error_message: None,
        avatar_url: None,
        meta_app_id: None,
    })
}

#[tauri::command]
pub async fn remove_external_account(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<(), SyncError> {
    let engine = &state.engine;
    engine.remove_account(&account_key).await
}

// ── Open tracking (docs/Open-Tracking.md) — per-channel opt-in + open history ──

#[tauri::command]
pub async fn set_open_tracking(
    state: State<'_, SyncState>,
    account_key: String,
    enabled: bool,
    track_domain: Option<String>,
) -> Result<(), SyncError> {
    let td = track_domain.map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty());
    state.engine.store().set_open_tracking(&account_key, enabled, td.as_deref())
}

#[tauri::command]
pub async fn get_open_tracking(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<serde_json::Value, SyncError> {
    let s = state.engine.store().open_tracking_settings(&account_key)?;
    Ok(serde_json::json!({ "enabled": s.enabled, "track_domain": s.track_domain }))
}

#[tauri::command]
pub async fn get_message_opens(
    state: State<'_, SyncState>,
    message_key: String,
) -> Result<serde_json::Value, SyncError> {
    let body = state.engine.store().message_body_html(&message_key)?.unwrap_or_default();
    let opens = state.engine.message_opens(&body);
    serde_json::to_value(opens).map_err(|e| SyncError::Other(e.to_string()))
}

/// Gate for the interrupting "sign-in expired" prompt: true at most once every
/// 5 minutes per account, persisted in the engine DB. Without it the prompt
/// reappeared on every sync tick and every app start for a dead token.
#[tauri::command]
pub async fn claim_reauth_prompt(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<bool, SyncError> {
    Ok(state.engine.store().claim_reauth_prompt(&account_key))
}

#[tauri::command]
pub async fn list_external_accounts(
    state: State<'_, SyncState>,
) -> Result<Vec<AccountResponse>, SyncError> {
    let engine = &state.engine;
    let accounts = engine.store().list_accounts()?;

    Ok(accounts
        .into_iter()
        .map(|a| {
            // Surface the (non-secret) app id for Meta accounts so the UI can
            // group channels by app and offer credential reuse. The app secret +
            // token stay encrypted and are never included.
            let meta_app_id = a
                .provider_type
                .is_meta()
                .then(|| match engine.store().get_credentials(&a.key) {
                    Ok(Some(ProviderCredentials::Meta(c))) if !c.app_id.is_empty() => Some(c.app_id),
                    _ => None,
                })
                .flatten();
            AccountResponse {
                key: a.key,
                display_name: a.display_name,
                email_address: a.email_address,
                provider_type: a.provider_type.as_str().to_string(),
                status: a.status.as_str().to_string(),
                error_message: a.error_message,
                avatar_url: a.avatar_url,
                meta_app_id,
            }
        })
        .collect())
}

#[tauri::command]
pub async fn reorder_external_accounts(
    state: State<'_, SyncState>,
    account_keys: Vec<String>,
) -> Result<(), SyncError> {
    let engine = &state.engine;
    engine.store().reorder_accounts(&account_keys)
}

#[tauri::command]
pub async fn update_external_account_status(
    state: State<'_, SyncState>,
    account_key: String,
    status: String,
    error_message: Option<String>,
) -> Result<(), SyncError> {
    let engine = &state.engine;
    let account_status = AccountStatus::from_str(&status);
    engine
        .store()
        .update_account_status(&account_key, &account_status, error_message.as_deref())
}

#[tauri::command]
pub async fn get_account_credentials(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<Option<CredentialsResponse>, SyncError> {
    let engine = &state.engine;
    let creds = engine.store().get_credentials(&account_key)?;
    Ok(creds.map(|c| match c {
        ProviderCredentials::OAuth2 { username, access_token, refresh_token } => {
            CredentialsResponse {
                auth_method: AuthMethod::OAuth2.as_str().to_string(),
                username: Some(username),
                access_token: Some(access_token),
                refresh_token,
            }
        }
        ProviderCredentials::Password { username, .. } => {
            CredentialsResponse {
                auth_method: "plain".to_string(),
                username: Some(username),
                access_token: None,
                refresh_token: None,
            }
        }
        // Meta BYOK credentials are never surfaced back to the UI (app secret +
        // System User token must stay on-device).
        ProviderCredentials::Meta(_) => CredentialsResponse {
            auth_method: "meta".to_string(),
            username: None,
            access_token: None,
            refresh_token: None,
        },
    }))
}
