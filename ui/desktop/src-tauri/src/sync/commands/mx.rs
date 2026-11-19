//! The MX mirror (docs/MX-Sync.md): inbox2-hosted mail kept in local SQLite by
//! the engine. The webview reads the `mx_*` tables directly; these commands are
//! the verbs. In engine-client mode they route to the host, like every other sync
//! command — only one engine ever syncs.

use serde_json::{json, Value};
use tauri::State;

use super::SyncState;
use crate::sync::error::SyncError;
use crate::sync::mx_sync::MxSyncOptions;

/// Mirror `org` as `user_key` and run a pass now. Called on sign-in, when an org
/// opens, and on a cable `sync` hint (`directory`/`reconcile` for a directory-
/// scoped one). The engine's run loop keeps it fresh in between.
#[tauri::command]
pub async fn mx_sync(
    state: State<'_, SyncState>,
    org: String,
    user_key: String,
    directory: Option<bool>,
    reconcile: Option<bool>,
) -> Result<Value, SyncError> {
    let (directory, reconcile) = (directory.unwrap_or(false), reconcile.unwrap_or(false));
    if let Some(bus) = &state.bus {
        return bus
            .call("mx_sync", json!({ "org": org, "user_key": user_key, "directory": directory, "reconcile": reconcile }))
            .map_err(SyncError::Other);
    }
    let report = state.engine.mx_sync(&org, &user_key, MxSyncOptions { directory, reconcile }).await?;
    Ok(serde_json::to_value(report).unwrap_or(Value::Null))
}

/// archive / trash / spam / open / mark_read / mark_unread on MX threads:
/// applied locally before this returns, queued, sent as soon as possible.
#[tauri::command]
pub async fn mx_action(
    state: State<'_, SyncState>,
    org: String,
    threads: Vec<String>,
    action: String,
) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("mx_action", json!({ "org": org, "threads": threads, "action": action }))
            .map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.mx_action(&org, &threads, &action).await
}

/// One E2EE domain keypair, base64 (libsodium ORIGINAL variant), as the webview
/// holds it after the member unlocks their identity.
#[derive(serde::Deserialize)]
pub struct DomainKeyArg {
    pub version: i64,
    pub public_key: String,
    pub secret_key: String,
}

/// Hand the engine the domain keys the member just unlocked so it can open
/// mirrored sealed mail for local search / MCP / Bridge (docs/MX-Sync.md "Sealed
/// mail"). Memory only on the engine side; an empty list (lock, sign-out) drops
/// them. Returns how many messages were opened.
#[tauri::command]
pub async fn mx_set_domain_keys(
    state: State<'_, SyncState>,
    org: String,
    keys: Vec<DomainKeyArg>,
) -> Result<usize, SyncError> {
    // Engine-client mode (a second instance, the CLI): the syncing engine lives in
    // another process, and domain secret keys do not travel over the shared bus —
    // unlike the tokens it carries, they decrypt mail. The host's own webview feeds
    // its engine directly; this instance just doesn't.
    if state.bus.is_some() {
        return Ok(0);
    }
    let keys = keys
        .iter()
        .map(|k| crate::sync::seal::DomainKey::from_b64(k.version, &k.public_key, &k.secret_key))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(state.engine.mx_set_domain_keys(&org, keys))
}

/// Sign-out / org removed: the org's mail and queued actions leave the device.
#[tauri::command]
pub async fn mx_forget(state: State<'_, SyncState>, org: String) -> Result<(), SyncError> {
    if let Some(bus) = &state.bus {
        bus.call("mx_forget", json!({ "org": org })).map_err(SyncError::Other)?;
        return Ok(());
    }
    state.engine.mx_forget(&org).await
}
