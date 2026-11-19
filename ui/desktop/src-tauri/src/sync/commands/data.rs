//! The "Clear data & log out" danger action.

use super::SyncState;
use crate::sync::error::SyncError;

/// Wipe all local data: cleanly stop every sync, delete the SQLite database and
/// its caches from disk, then restart the app so all in-memory state (engine,
/// MCP server, vector store) is rebuilt against an empty database.
///
/// This is the "Clear data & log out" danger action. It does NOT remove the
/// device encryption key or downloaded AI models — those aren't user data, and
/// re-downloading models on a data wipe would be hostile.
#[tauri::command]
pub async fn clear_local_data(app: tauri::AppHandle) -> Result<(), SyncError> {
    use tauri::Manager;

    // 1. Clean shutdown: signal the sync loop to stop and disconnect every
    //    adapter so nothing writes to the DB while we delete it.
    {
        let state = app.state::<SyncState>();
        state.engine.shutdown().await;
    }

    // 2. Resolve the app data dir and remove all on-disk state.
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| SyncError::Other(format!("resolve app data dir: {e}")))?;

    // SQLite database + its WAL/SHM sidecars.
    for name in ["inbox2.db", "inbox2.db-wal", "inbox2.db-shm"] {
        let path = app_data_dir.join(name);
        if path.exists() {
            std::fs::remove_file(&path)
                .map_err(|e| SyncError::Other(format!("remove {name}: {e}")))?;
        }
    }

    // Cached attachments + MCP bearer token (best-effort).
    let cache_dir = app_data_dir.join("attachment-cache");
    if cache_dir.exists() {
        let _ = std::fs::remove_dir_all(&cache_dir);
    }
    let token_path = app_data_dir.join("mcp-token");
    if token_path.exists() {
        let _ = std::fs::remove_file(&token_path);
    }

    // 3. Restart against the now-empty database. Never returns.
    log::warn!("clear_local_data: wiped local DB + caches, restarting app");
    app.restart();
}
