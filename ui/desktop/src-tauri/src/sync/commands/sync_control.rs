//! Sync lifecycle: start/stop/resync, cloud-push registration, status +
//! diagnostics, write-back enqueue, and folder listing. In engine-client mode
//! these route to the host over the bus so only one engine ever syncs.

use serde::{Deserialize, Serialize};
use tauri::State;

use super::SyncState;
use crate::sync::error::SyncError;
use crate::sync::model::*;

#[derive(Debug, Serialize)]
pub struct SyncStatusResponse {
    pub accounts: Vec<AccountStatusEntry>,
}

#[derive(Debug, Serialize)]
pub struct AccountStatusEntry {
    pub key: String,
    pub status: String,
}

#[derive(Debug, Deserialize)]
pub struct WritebackRequest {
    pub account_key: String,
    pub action_type: String,
    pub message_key: String,
    pub folder_key: Option<String>,
    pub target_folder: Option<String>,
    pub label: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct FolderResponse {
    pub key: String,
    pub provider_name: String,
    pub well_known_role: Option<String>,
    pub sync_enabled: bool,
    pub last_synced_uid: u32,
    pub provider_label_id: Option<String>,
}

#[tauri::command]
pub async fn start_sync(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<(), SyncError> {
    // Client mode: let the host engine do the syncing.
    if let Some(bus) = &state.bus {
        bus.call("start_sync", serde_json::json!({ "account_key": account_key }))
            .map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.connect_and_sync(&account_key).await
}

#[tauri::command]
pub async fn stop_sync(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("stop_sync", serde_json::json!({ "account_key": account_key }))
            .map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.remove_account(&account_key).await
}

/// Force a full re-sync of an account: clear every folder's sync cursor so the
/// next sync runs as an initial sync and re-fetches all messages. Used to
/// backfill fields added after a thread was first synced (e.g. has_attachment).
/// Messages dedupe by Message-ID per account, so this never creates duplicates.
/// Exposed in the UI behind dev mode, but the command itself is safe to call.
#[tauri::command]
pub async fn resync_account(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("resync_account", serde_json::json!({ "account_key": account_key }))
            .map_err(SyncError::Other)?;
        return Ok(());
    }
    let folders = state.engine.store().get_folders_for_account(&account_key)?;
    for folder in &folders {
        state
            .engine
            .store()
            .invalidate_folder_uids(&account_key, &folder.key)?;
    }
    state.engine.connect_and_sync(&account_key).await
}

/// Register cloud push for a local channel (Gmail/Office365). Returns whether a
/// provider subscription was created — `false` means push is disabled/unconfigured
/// and the channel stays on polling. See docs/Cloud-Push.md.
#[tauri::command]
pub async fn register_push(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<bool, SyncError> {
    if let Some(bus) = &state.bus {
        let resp = bus
            .call("register_push", serde_json::json!({ "account_key": account_key }))
            .map_err(SyncError::Other)?;
        return Ok(resp.get("registered").and_then(|v| v.as_bool()).unwrap_or(false));
    }
    state.engine.register_push(&account_key).await
}

/// Tear down cloud push for a local channel (toggle-off).
#[tauri::command]
pub async fn deregister_push(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("deregister_push", serde_json::json!({ "account_key": account_key }))
            .map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.deregister_push(&account_key).await
}

/// Ingest a buffered Meta webhook event by its relay buffer key (driven by the
/// frontend on a `meta_event` ActionCable nudge). Fetches, verifies the HMAC
/// against the local app_secret, normalizes, and applies. Returns `true` if
/// applied. See docs/Cloud-Push.md (Meta).
#[tauri::command]
pub async fn ingest_meta_event(
    state: State<'_, SyncState>,
    event_key: String,
) -> Result<bool, SyncError> {
    if let Some(bus) = &state.bus {
        let resp = bus
            .call("ingest_meta_event", serde_json::json!({ "event_key": event_key }))
            .map_err(SyncError::Other)?;
        return Ok(resp.get("applied").and_then(|v| v.as_bool()).unwrap_or(false));
    }
    state.engine.ingest_meta_event(&event_key).await
}

#[tauri::command]
pub async fn get_sync_status(
    state: State<'_, SyncState>,
) -> Result<SyncStatusResponse, SyncError> {
    // Client mode: the host knows the true per-account status.
    if let Some(bus) = &state.bus {
        let value = bus
            .call("get_sync_status", serde_json::Value::Null)
            .map_err(SyncError::Other)?;
        let accounts = value
            .as_array()
            .map(|arr| {
                arr.iter()
                    .map(|e| AccountStatusEntry {
                        key: e.get("key").and_then(|k| k.as_str()).unwrap_or("").to_string(),
                        status: e.get("status").and_then(|s| s.as_str()).unwrap_or("").to_string(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        return Ok(SyncStatusResponse { accounts });
    }

    let statuses = state.engine.account_statuses().await;
    Ok(SyncStatusResponse {
        accounts: statuses
            .into_iter()
            .map(|(key, status)| AccountStatusEntry {
                key,
                status: status.as_str().to_string(),
            })
            .collect(),
    })
}

/// Keys of accounts currently syncing. The UI seeds its "Syncing…" indicator
/// from this on mount, so a sync already in flight (e.g. right after setup) is
/// reflected even though the transient sync-state event was missed.
#[tauri::command]
pub async fn get_syncing_accounts(
    state: State<'_, SyncState>,
) -> Result<Vec<String>, SyncError> {
    if let Some(bus) = &state.bus {
        let value = bus
            .call("get_syncing_accounts", serde_json::Value::Null)
            .map_err(SyncError::Other)?;
        let keys: Vec<String> =
            serde_json::from_value(value).map_err(|e| SyncError::Other(e.to_string()))?;
        log::info!("[sync-indicator] get_syncing_accounts (via bus) -> {keys:?}");
        return Ok(keys);
    }
    let keys = state.engine.syncing_accounts();
    log::info!("[sync-indicator] get_syncing_accounts -> {keys:?}");
    Ok(keys)
}

/// Recent sync-lifecycle events (oldest→newest) the engine retains for the
/// Sync Console. The Console backfills from this on mount so it shows the whole
/// run — `started`, per-folder progress, `completed` — even when it opened
/// mid-sync and missed the early events live.
#[tauri::command]
pub async fn get_sync_log(
    state: State<'_, SyncState>,
) -> Result<Vec<serde_json::Value>, SyncError> {
    if let Some(bus) = &state.bus {
        let value = bus
            .call("get_sync_log", serde_json::Value::Null)
            .map_err(SyncError::Other)?;
        return serde_json::from_value(value).map_err(|e| SyncError::Other(e.to_string()));
    }
    Ok(state.engine.recent_sync_events())
}

/// Live diagnostics for the Sync Console (adapter/polling state, inbox cursor,
/// local-DB counts). Replaces the dead JS-adapter diagnostics from before sync
/// moved to Rust.
#[tauri::command]
pub async fn get_account_diagnostics(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<serde_json::Value, SyncError> {
    if let Some(bus) = &state.bus {
        return bus
            .call(
                "get_account_diagnostics",
                serde_json::json!({ "account_key": account_key }),
            )
            .map_err(SyncError::Other);
    }
    state.engine.account_diagnostics(&account_key).await
}

#[tauri::command]
pub async fn queue_writeback_action(
    state: State<'_, SyncState>,
    request: WritebackRequest,
) -> Result<String, SyncError> {
    let action_type = ActionType::from_request(
        &request.action_type,
        request.target_folder,
        request.label,
    )
    .map_err(SyncError::Other)?;

    let engine = &state.engine;
    engine.writeback().enqueue(
        &request.account_key,
        action_type,
        &request.message_key,
        request.folder_key.as_deref(),
        None,
    )
}

#[tauri::command]
pub async fn list_external_folders(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<Vec<FolderResponse>, SyncError> {
    let engine = &state.engine;
    let folders = engine.store().get_folders_for_account(&account_key)?;

    Ok(folders
        .into_iter()
        .map(|f| FolderResponse {
            key: f.key,
            provider_name: f.provider_name,
            well_known_role: f.role.as_ref().map(|r| r.as_str().to_string()),
            sync_enabled: f.sync_enabled,
            last_synced_uid: f.last_synced_uid,
            provider_label_id: f.flags.first().cloned(),
        })
        .collect())
}
