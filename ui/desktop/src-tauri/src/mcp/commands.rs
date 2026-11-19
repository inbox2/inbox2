//! Settings › On-device AI › "Connect an AI agent": turn the MCP server on or
//! off, show how to connect, and set each connected agent's access.

use serde::Serialize;
use tauri::{AppHandle, Manager, State};

use crate::mcp::permissions::{Agent, PermissionLevel, PermissionManager};
use crate::sync::commands::SyncState;
use crate::vector::store::VectorStore;

const ENABLED_KEY: &str = "mcp_server_enabled";

#[derive(Serialize)]
pub struct McpInfo {
    enabled: bool,
    /// Present while the server is on.
    url: Option<String>,
    token: Option<String>,
    agents: Vec<Agent>,
}

fn info(app: &AppHandle, state: &SyncState) -> Result<McpInfo, String> {
    let conn = state.engine.store().connection();
    let enabled = VectorStore::new(conn.clone()).get_setting(ENABLED_KEY).ok().flatten().as_deref() == Some("true");
    let (url, token) = if enabled {
        let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
        let (port, token) = crate::setup::ensure_mcp_started(&dir, &state.engine);
        (Some(format!("http://127.0.0.1:{port}/mcp")), Some(token))
    } else {
        (None, None)
    };
    let agents = PermissionManager::new(conn).list_agents()?;
    Ok(McpInfo { enabled, url, token, agents })
}

#[tauri::command]
pub async fn mcp_info(app: AppHandle, state: State<'_, SyncState>) -> Result<McpInfo, String> {
    info(&app, &state)
}

/// Takes effect at once: on starts the server if needed, off makes it refuse
/// every request.
#[tauri::command]
pub async fn mcp_set_enabled(app: AppHandle, state: State<'_, SyncState>, enabled: bool) -> Result<McpInfo, String> {
    VectorStore::new(state.engine.store().connection())
        .set_setting(ENABLED_KEY, if enabled { "true" } else { "false" })
        .map_err(|e| e.to_string())?;
    crate::mcp::http::set_enabled(enabled);
    info(&app, &state)
}

/// `read`, `read_write` or `full` (full includes acting without approval).
#[tauri::command]
pub async fn mcp_set_agent_access(state: State<'_, SyncState>, agent_key: String, level: String) -> Result<(), String> {
    let level = match level.as_str() {
        "read" | "read_write" | "full" => PermissionLevel::from_str(&level),
        other => return Err(format!("unknown access level '{other}'")),
    };
    PermissionManager::new(state.engine.store().connection()).set_access(&agent_key, &level)
}
