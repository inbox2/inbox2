//! Rails API context (base URL + JWT) for Rust-side OAuth token refresh, and
//! the engine's encrypted app-secret KV store for webview-managed third-party
//! API keys.

use tauri::State;

use super::SyncState;
use crate::sync::error::SyncError;

/// Push the Rails API base URL + JWT to the engine so the Rust OAuth adapters
/// can refresh tokens via the proxy. Called by the frontend on boot.
#[tauri::command]
pub async fn set_api_context(
    state: State<'_, SyncState>,
    api_base: String,
    rails_jwt: String,
) -> Result<(), SyncError> {
    // Always set locally — the MCP server, vector subsystem, and interactive
    // providers use this process's engine.
    state
        .engine
        .set_api_context(api_base.clone(), rails_jwt.clone())
        .await;
    // Client mode: also forward to the host, which runs the sync loop + OAuth
    // token refresh. Without this the host syncs with no API context and token
    // refresh fails with "API context not set".
    if let Some(bus) = &state.bus {
        bus.call(
            "set_api_context",
            serde_json::json!({ "api_base": api_base, "rails_jwt": rails_jwt }),
        )
        .map_err(SyncError::Other)?;
    }
    Ok(())
}

/// The Rails token persisted in the engine's encrypted store, if any. Lets the
/// webview rehydrate its localStorage on boot when it's been cleared, so the
/// durable token is the source of truth. See docs/Cloud-Push.md.
#[tauri::command]
pub async fn get_rails_token(state: State<'_, SyncState>) -> Result<Option<String>, SyncError> {
    if let Some(bus) = &state.bus {
        let resp = bus
            .call("get_rails_token", serde_json::Value::Null)
            .map_err(SyncError::Other)?;
        return Ok(resp.as_str().map(str::to_string));
    }
    Ok(state.engine.persisted_rails_token())
}

/// Namespace for webview-managed secrets (third-party API keys) in `app_secrets`,
/// keeping them disjoint from engine-managed entries like `rails_token`.
pub const SECRET_KV_PREFIX: &str = "kv:";

/// Store a named third-party secret (e.g. an Apollo API key) in the engine's
/// encrypted store — durable, encrypted at rest, shared across engine clients.
#[tauri::command]
pub async fn set_secret(
    state: State<'_, SyncState>,
    name: String,
    value: String,
) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("set_secret", serde_json::json!({ "name": name, "value": value }))
            .map_err(SyncError::Other)?;
        return Ok(());
    }
    state
        .engine
        .store()
        .store_app_secret(&format!("{SECRET_KV_PREFIX}{name}"), &value)
}

#[tauri::command]
pub async fn get_secret(
    state: State<'_, SyncState>,
    name: String,
) -> Result<Option<String>, SyncError> {
    if let Some(bus) = &state.bus {
        let resp = bus
            .call("get_secret", serde_json::json!({ "name": name }))
            .map_err(SyncError::Other)?;
        return Ok(resp.as_str().map(str::to_string));
    }
    state
        .engine
        .store()
        .get_app_secret(&format!("{SECRET_KV_PREFIX}{name}"))
}

#[tauri::command]
pub async fn clear_secret(state: State<'_, SyncState>, name: String) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("clear_secret", serde_json::json!({ "name": name }))
            .map_err(SyncError::Other)?;
        return Ok(());
    }
    state
        .engine
        .store()
        .delete_app_secret(&format!("{SECRET_KV_PREFIX}{name}"))
}
