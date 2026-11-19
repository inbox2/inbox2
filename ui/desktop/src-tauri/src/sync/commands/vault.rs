//! Tauri commands for the zero-knowledge credential vault (docs/E2EE.md).
//!
//! Each command routes to the host engine over the IPC bus when running as a
//! client (CLI / secondary window), or calls the local engine directly when this
//! process owns it — mirroring `add_external_account`.

use serde_json::{json, Value};
use tauri::State;

use super::SyncState;
use crate::sync::error::SyncError;

fn parse<T: serde::de::DeserializeOwned>(v: Value) -> Result<T, SyncError> {
    serde_json::from_value(v).map_err(|e| SyncError::Other(e.to_string()))
}

/// `{ enabled, unlocked, account_count }` for UI gating.
#[tauri::command]
pub async fn vault_status(state: State<'_, SyncState>) -> Result<Value, SyncError> {
    if let Some(bus) = &state.bus {
        return bus.call("vault_status", Value::Null).map_err(SyncError::Other);
    }
    serde_json::to_value(state.engine.vault_status()?).map_err(|e| SyncError::Other(e.to_string()))
}

/// Enable cloud backup with the inbox2 account password. Returns the vault id.
#[tauri::command]
pub async fn enable_cloud_backup(
    state: State<'_, SyncState>,
    password: String,
) -> Result<String, SyncError> {
    if let Some(bus) = &state.bus {
        let v = bus
            .call("enable_cloud_backup", json!({ "password": password }))
            .map_err(SyncError::Other)?;
        return parse(v);
    }
    state.engine.enable_cloud_backup(&password).await
}

/// Turn off cloud backup (delete the vault + all blobs server-side).
#[tauri::command]
pub async fn disable_cloud_backup(state: State<'_, SyncState>) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("disable_cloud_backup", Value::Null).map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.disable_cloud_backup().await
}

/// Unlock the vault on this device with the inbox2 password.
#[tauri::command]
pub async fn unlock_vault(state: State<'_, SyncState>, password: String) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("unlock_vault", json!({ "password": password })).map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.unlock_vault(&password).await
}

/// Re-encrypt all backed-up credentials under a new password (after a password change).
#[tauri::command]
pub async fn rotate_vault(
    state: State<'_, SyncState>,
    new_password: String,
) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("rotate_vault", json!({ "new_password": new_password }))
            .map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.rotate_vault(&new_password).await
}

/// Drop the vault session (DEK + local state). Call on sign-out / account switch.
#[tauri::command]
pub async fn clear_vault_session(state: State<'_, SyncState>) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("clear_vault_session", Value::Null).map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.clear_vault_session();
    Ok(())
}

/// Metadata of every cloud-backed credential (drives the management card + restore).
#[tauri::command]
pub async fn list_cloud_backed_credentials(state: State<'_, SyncState>) -> Result<Value, SyncError> {
    if let Some(bus) = &state.bus {
        return bus.call("list_cloud_backed_credentials", Value::Null).map_err(SyncError::Other);
    }
    let metas = state.engine.list_cloud_backups().await?;
    serde_json::to_value(metas).map_err(|e| SyncError::Other(e.to_string()))
}

/// Restore all cloud-backed credentials with the inbox2 password (a new device).
/// Returns how many accounts were restored.
#[tauri::command]
pub async fn restore_from_cloud(
    state: State<'_, SyncState>,
    password: String,
) -> Result<u32, SyncError> {
    if let Some(bus) = &state.bus {
        let v = bus
            .call("restore_from_cloud", json!({ "password": password }))
            .map_err(SyncError::Other)?;
        return parse(v);
    }
    state.engine.restore_from_cloud(&password).await
}

/// Toggle cloud backup for one already-connected account.
#[tauri::command]
pub async fn set_account_cloud_backup(
    state: State<'_, SyncState>,
    account_key: String,
    enabled: bool,
) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call(
            "set_account_cloud_backup",
            json!({ "account_key": account_key, "enabled": enabled }),
        )
        .map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.store().set_account_backup_enabled(&account_key, enabled)?;
    if enabled {
        state.engine.store().mark_backup_dirty(&account_key)?;
    }
    Ok(())
}
