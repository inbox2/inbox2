//! Tauri commands for the outbound MCP client (`inbox2_core::mcp_client`,
//! docs/MCP-Client.md). The core does the protocol, OAuth and storage; this
//! file owns the desktop-only half of sign-in: the loopback listener (shared
//! with device link) and opening the system browser.
//!
//! Nothing here calls a tool unprompted — `mcp_call_tool` runs only when the
//! person presses Create in the Send-to dialog.

use inbox2_core::mcp_client::{self as mc, AuthKind, Challenge, Connection, Credential, Probe, Status};
use serde_json::Value;
use tauri::State;

use crate::sync::commands::{open_in_browser, wait_for_callback, SyncState};

/// How long the person has to finish signing in in the browser.
const SIGN_IN_TIMEOUT_SECS: u64 = 300;

/// Bind a loopback port, run discovery/registration, open the browser, wait for
/// the code and exchange it.
async fn sign_in(
    app: &tauri::AppHandle,
    url: &str,
    challenge: &Challenge,
    client: Option<(String, Option<String>)>,
) -> Result<Credential, String> {
    let server = tiny_http::Server::http("127.0.0.1:0").map_err(|e| format!("bind loopback: {e}"))?;
    let port = server
        .server_addr()
        .to_ip()
        .map(|a| a.port())
        .ok_or("no loopback port")?;
    let redirect_uri = format!("http://127.0.0.1:{port}/cb");
    let pending = mc::oauth::begin(mc::http(), url, challenge, &redirect_uri, client).await?;
    open_in_browser(app, &pending.authorize_url).map_err(|e| e.to_string())?;
    let state = pending.state.clone();
    let code = tokio::task::spawn_blocking(move || {
        wait_for_callback(server, &state, SIGN_IN_TIMEOUT_SECS, "Connected — you can return to inbox2.")
    })
    .await
    .map_err(|e| e.to_string())??;
    mc::oauth::finish(mc::http(), pending, &code).await
}

fn client_of(client_id: Option<String>, client_secret: Option<String>) -> Option<(String, Option<String>)> {
    client_id
        .filter(|s| !s.trim().is_empty())
        .map(|id| (id.trim().to_string(), client_secret.filter(|s| !s.trim().is_empty())))
}

#[tauri::command]
pub async fn mcp_presets() -> Vec<mc::Preset> {
    mc::presets()
}

#[tauri::command]
pub async fn mcp_list_connections(state: State<'_, SyncState>) -> Result<Vec<Connection>, String> {
    mc::list_connections(state.engine.store())
}

/// Add a server. With `token`, it's a bearer connection. Without one, an open
/// server connects as-is and a 401 starts OAuth in the browser (optionally with
/// a pre-registered `client_id`/`client_secret` for servers without DCR).
#[tauri::command]
pub async fn mcp_add_connection(
    app: tauri::AppHandle,
    state: State<'_, SyncState>,
    name: String,
    url: String,
    token: Option<String>,
    client_id: Option<String>,
    client_secret: Option<String>,
) -> Result<Connection, String> {
    let url = url.trim().to_string();
    mc::validate_url(&url)?;
    let store = state.engine.store();
    let token = token.filter(|t| !t.trim().is_empty()).map(|t| t.trim().to_string());
    let name = if name.trim().is_empty() {
        url::Url::parse(&url).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_else(|| url.clone())
    } else {
        name.trim().to_string()
    };

    let (auth, cred) = match mc::probe(&url, token.as_deref()).await? {
        Probe::Ok => match token {
            Some(t) => (AuthKind::Token, Some(Credential::bearer(&t))),
            None => (AuthKind::None, None),
        },
        Probe::NeedsAuth(_) if token.is_some() => return Err("The server rejected that token.".into()),
        Probe::NeedsAuth(ch) => {
            let cred = sign_in(&app, &url, &ch, client_of(client_id, client_secret)).await?;
            (AuthKind::Oauth, Some(cred))
        }
    };
    let conn = Connection { id: mc::new_id(), name, url, auth, status: Status::Connected, error: None };
    if let Some(c) = &cred {
        mc::save_credential(store, &conn.id, c)?;
    }
    mc::upsert_connection(store, &conn)?;
    Ok(conn)
}

/// Sign in again (OAuth) or just re-check (token / open). Replaces the stored
/// credential on success.
#[tauri::command]
pub async fn mcp_reauth_connection(
    app: tauri::AppHandle,
    state: State<'_, SyncState>,
    id: String,
    token: Option<String>,
) -> Result<Connection, String> {
    let store = state.engine.store();
    let mut conn = mc::get_connection(store, &id)?;
    if let Some(t) = token.filter(|t| !t.trim().is_empty()) {
        mc::save_credential(store, &id, &Credential::bearer(t.trim()))?;
        conn.auth = AuthKind::Token;
    } else if conn.auth == AuthKind::Oauth {
        // Keep a person-supplied client (non-DCR servers); a DCR client re-registers.
        let old = mc::load_credential(store, &id).ok().flatten();
        let ch = match mc::probe(&conn.url, None).await? {
            Probe::NeedsAuth(ch) => ch,
            Probe::Ok => Challenge::default(),
        };
        let client = old
            .filter(|c| !c.registered_client)
            .and_then(|c| Some((c.client_id?, c.client_secret)));
        let cred = sign_in(&app, &conn.url, &ch, client).await?;
        mc::save_credential(store, &id, &cred)?;
    }
    mc::upsert_connection(store, &conn)?;
    mc::list_tools(store, &id).await?;
    mc::get_connection(store, &id)
}

#[tauri::command]
pub async fn mcp_remove_connection(state: State<'_, SyncState>, id: String) -> Result<(), String> {
    mc::remove_connection(state.engine.store(), &id)
}

#[tauri::command]
pub async fn mcp_list_tools(state: State<'_, SyncState>, id: String) -> Result<Vec<mc::Tool>, String> {
    mc::list_tools(state.engine.store(), &id).await
}

#[tauri::command]
pub async fn mcp_call_tool(
    state: State<'_, SyncState>,
    id: String,
    tool: String,
    arguments: Value,
) -> Result<mc::CallResult, String> {
    log::info!("[mcp_client] {id}: calling {tool} (person pressed Create)");
    mc::call_tool(state.engine.store(), &id, &tool, arguments).await
}
