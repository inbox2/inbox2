//! Outbound MCP client — inbox2 as a *client* of remote MCP servers (Linear,
//! GitHub, Jira, Notion, …), for the Lore handoff (docs/plans/lore.md §5,
//! docs/MCP-Client.md). Draft-only: nothing here calls a tool on its own; the
//! host calls [`call_tool`] only when the person presses Create.
//!
//! Storage (no new table): the connection list is JSON in `engine_settings`
//! under [`CONNECTIONS_KEY`]; each connection's token/OAuth state is an
//! encrypted `app_secrets` row (`mcp_client:<id>`), the same device-key AES-GCM
//! store the Rails token and third-party API keys use.

pub mod draft;
pub mod oauth;
pub mod rpc;

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::sync::store::SyncStore;
pub use oauth::{Credential, PendingAuth};
pub use rpc::{Challenge, McpError, Session};

pub const CONNECTIONS_KEY: &str = "mcp_client_connections";
const SECRET_PREFIX: &str = "mcp_client:";
/// The error string a host can match to offer "Sign in again".
pub const NEEDS_AUTH: &str = "needs_auth";

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthKind {
    Oauth,
    Token,
    None,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Connected,
    NeedsAuth,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Connection {
    pub id: String,
    pub name: String,
    pub url: String,
    pub auth: AuthKind,
    pub status: Status,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Tool {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct CallResult {
    /// The MCP content blocks as the server sent them. Untrusted.
    pub content: Value,
    pub is_error: bool,
}

/// A hosted remote MCP server worth one click. `auth`: "oauth" = sign in with
/// dynamic registration; "token" = paste a token (no DCR); "client_id" = OAuth
/// with an app you register there yourself (no DCR).
#[derive(Debug, Clone, Serialize)]
pub struct Preset {
    pub name: &'static str,
    pub url: &'static str,
    pub auth: &'static str,
    /// Probed 2026-10-20: the URL answers MCP `initialize` with a 401 + OAuth metadata.
    pub verified: bool,
    pub note: &'static str,
}

pub fn presets() -> Vec<Preset> {
    vec![
        Preset { name: "Linear", url: "https://mcp.linear.app/mcp", auth: "oauth", verified: true, note: "" },
        Preset { name: "GitHub", url: "https://api.githubcopilot.com/mcp/", auth: "token", verified: true,
            note: "GitHub has no app self-registration: paste a personal access token (repo scope)." },
        Preset { name: "Atlassian (Jira, Confluence)", url: "https://mcp.atlassian.com/v1/mcp", auth: "oauth", verified: true, note: "" },
        Preset { name: "Notion", url: "https://mcp.notion.com/mcp", auth: "oauth", verified: true, note: "" },
        Preset { name: "Sentry", url: "https://mcp.sentry.dev/mcp", auth: "oauth", verified: true, note: "" },
        Preset { name: "HubSpot", url: "https://mcp.hubspot.com/", auth: "client_id", verified: true,
            note: "Create an MCP auth app in HubSpot and paste its client ID and secret." },
        Preset { name: "Asana", url: "https://mcp.asana.com/v2/mcp", auth: "client_id", verified: true,
            note: "Asana's V2 server needs an OAuth app you register in the Asana developer console." },
        Preset { name: "Salesforce", url: "https://api.salesforce.com/platform/mcp/v1/platform/sobject-all", auth: "client_id", verified: false,
            note: "Path depends on the server you activate in Setup › MCP Servers; needs an External Client App." },
    ]
}

/// Tokens only travel over TLS; plain http is allowed for loopback (local servers, tests).
pub fn validate_url(url: &str) -> Result<(), String> {
    let u = url::Url::parse(url.trim()).map_err(|_| "That is not a valid URL.".to_string())?;
    let loopback = matches!(u.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    match u.scheme() {
        "https" => Ok(()),
        "http" if loopback => Ok(()),
        _ => Err("Use an https:// URL.".into()),
    }
}

pub fn http() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .expect("reqwest client")
    })
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

pub fn list_connections(store: &SyncStore) -> Result<Vec<Connection>, String> {
    let raw = store.get_engine_setting(CONNECTIONS_KEY).map_err(|e| e.to_string())?;
    Ok(raw.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default())
}

fn save_connections(store: &SyncStore, all: &[Connection]) -> Result<(), String> {
    let s = serde_json::to_string(all).map_err(|e| e.to_string())?;
    store.set_engine_setting(CONNECTIONS_KEY, &s).map_err(|e| e.to_string())
}

pub fn get_connection(store: &SyncStore, id: &str) -> Result<Connection, String> {
    list_connections(store)?
        .into_iter()
        .find(|c| c.id == id)
        .ok_or_else(|| "No such connection.".into())
}

pub fn upsert_connection(store: &SyncStore, conn: &Connection) -> Result<(), String> {
    let mut all = list_connections(store)?;
    match all.iter_mut().find(|c| c.id == conn.id) {
        Some(c) => *c = conn.clone(),
        None => all.push(conn.clone()),
    }
    save_connections(store, &all)
}

pub fn remove_connection(store: &SyncStore, id: &str) -> Result<(), String> {
    let mut all = list_connections(store)?;
    all.retain(|c| c.id != id);
    save_connections(store, &all)?;
    store.delete_app_secret(&format!("{SECRET_PREFIX}{id}")).map_err(|e| e.to_string())
}

pub fn save_credential(store: &SyncStore, id: &str, c: &Credential) -> Result<(), String> {
    let s = serde_json::to_string(c).map_err(|e| e.to_string())?;
    store.store_app_secret(&format!("{SECRET_PREFIX}{id}"), &s).map_err(|e| e.to_string())
}

pub fn load_credential(store: &SyncStore, id: &str) -> Result<Option<Credential>, String> {
    let raw = store.get_app_secret(&format!("{SECRET_PREFIX}{id}")).map_err(|e| e.to_string())?;
    Ok(raw.and_then(|s| serde_json::from_str(&s).ok()))
}

fn set_status(store: &SyncStore, id: &str, status: Status, error: Option<String>) {
    if let Ok(mut c) = get_connection(store, id) {
        if c.status != status || c.error != error {
            c.status = status;
            c.error = error;
            let _ = upsert_connection(store, &c);
        }
    }
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

pub fn parse_tools(result: &Value) -> Vec<Tool> {
    result
        .get("tools")
        .and_then(Value::as_array)
        .map(|ts| {
            ts.iter()
                .filter_map(|t| {
                    Some(Tool {
                        name: t.get("name")?.as_str()?.to_string(),
                        description: t.get("description").and_then(Value::as_str).unwrap_or("").to_string(),
                        input_schema: t.get("inputSchema").cloned().unwrap_or_else(|| json!({ "type": "object" })),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// One request on a fresh session. ponytail: a new `initialize` per operation
/// (3 round-trips) — operations are person-initiated and rare, and it sidesteps
/// expired sessions. Cache the session per connection if it ever feels slow.
async fn exchange(url: &str, bearer: Option<&str>, method: &str, params: Value) -> Result<Value, McpError> {
    let mut s = Session::connect(http(), url, bearer).await?;
    s.request(method, params).await
}

/// What adding a connection found: tools straight away, or a sign-in to do.
pub enum Probe {
    Ok,
    NeedsAuth(Challenge),
}

pub async fn probe(url: &str, bearer: Option<&str>) -> Result<Probe, String> {
    match exchange(url, bearer, "tools/list", json!({})).await {
        Ok(_) => Ok(Probe::Ok),
        Err(McpError::Unauthorized(ch)) => Ok(Probe::NeedsAuth(ch)),
        Err(e) => Err(e.to_string()),
    }
}

/// Run one MCP request against a stored connection: refreshes an expiring
/// OAuth token, retries once after a 401 if it can refresh, and records the
/// connection's status.
async fn run(store: &SyncStore, id: &str, method: &str, params: Value) -> Result<Value, String> {
    let conn = get_connection(store, id)?;
    let mut cred = match conn.auth {
        AuthKind::None => None,
        _ => load_credential(store, id)?,
    };
    if conn.auth != AuthKind::None && cred.is_none() {
        set_status(store, id, Status::NeedsAuth, None);
        return Err(NEEDS_AUTH.into());
    }
    let mut refreshed = false;
    loop {
        if let Some(c) = cred.as_ref().filter(|c| !refreshed && c.expired() && c.can_refresh()) {
            refreshed = true;
            match oauth::refresh(http(), c).await {
                Ok(n) => {
                    save_credential(store, id, &n)?;
                    cred = Some(n);
                }
                Err(e) => log::warn!("[mcp_client] {id}: refresh failed: {e}"),
            }
        }
        let bearer = cred.as_ref().map(|c| c.access_token.as_str());
        match exchange(&conn.url, bearer, method, params.clone()).await {
            Ok(v) => {
                set_status(store, id, Status::Connected, None);
                return Ok(v);
            }
            Err(McpError::Unauthorized(_)) => {
                if let Some(c) = cred.as_mut().filter(|c| !refreshed && c.can_refresh()) {
                    c.expires_at = Some(0); // force the refresh on the next pass
                    continue;
                }
                set_status(store, id, Status::NeedsAuth, None);
                return Err(NEEDS_AUTH.into());
            }
            Err(McpError::Rpc(e)) => return Err(e),
            Err(McpError::Other(e)) => {
                set_status(store, id, Status::Error, Some(e.clone()));
                return Err(e);
            }
        }
    }
}

pub async fn list_tools(store: &SyncStore, id: &str) -> Result<Vec<Tool>, String> {
    Ok(parse_tools(&run(store, id, "tools/list", json!({})).await?))
}

pub async fn call_tool(store: &SyncStore, id: &str, tool: &str, arguments: Value) -> Result<CallResult, String> {
    let r = run(store, id, "tools/call", json!({ "name": tool, "arguments": arguments })).await?;
    Ok(CallResult {
        content: r.get("content").cloned().unwrap_or_else(|| json!([])),
        is_error: r.get("isError").and_then(Value::as_bool).unwrap_or(false),
    })
}

// ─── Sign-in for hosts that own the browser and the loopback (the phones) ──────────

/// A sign-in started, waiting for the browser to come back.
struct Pending {
    auth: PendingAuth,
    name: String,
    url: String,
    /// `Some`: signing in again on an existing connection.
    connection_id: Option<String>,
}

static PENDING: LazyLock<Mutex<HashMap<String, Pending>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// `{ connected: Connection }` or `{ state, authorize_url }` (open the browser, then `finish_connect`).
fn hold(p: Pending) -> Value {
    let (state, url) = (p.auth.state.clone(), p.auth.authorize_url.clone());
    PENDING.lock().unwrap_or_else(|e| e.into_inner()).insert(state.clone(), p);
    json!({ "state": state, "authorize_url": url })
}

pub async fn begin_connect(
    store: &SyncStore,
    name: &str,
    url: &str,
    token: Option<&str>,
    client: Option<(String, Option<String>)>,
    redirect_uri: &str,
) -> Result<Value, String> {
    let url = url.trim().to_string();
    validate_url(&url)?;
    let token = token.map(str::trim).filter(|t| !t.is_empty());
    let name = if name.trim().is_empty() { url.clone() } else { name.trim().to_string() };
    match probe(&url, token).await? {
        Probe::Ok => {
            let conn = Connection { id: new_id(), name, url, auth: if token.is_some() { AuthKind::Token } else { AuthKind::None }, status: Status::Connected, error: None };
            if let Some(t) = token {
                save_credential(store, &conn.id, &Credential::bearer(t))?;
            }
            upsert_connection(store, &conn)?;
            Ok(json!({ "connected": conn }))
        }
        Probe::NeedsAuth(_) if token.is_some() => Err("The server rejected that token.".into()),
        Probe::NeedsAuth(ch) => {
            let auth = oauth::begin(http(), &url, &ch, redirect_uri, client).await?;
            Ok(hold(Pending { auth, name, url, connection_id: None }))
        }
    }
}

/// Sign in again on an existing connection (OAuth), or store a new token.
pub async fn begin_reauth(store: &SyncStore, id: &str, token: Option<&str>, redirect_uri: &str) -> Result<Value, String> {
    let mut conn = get_connection(store, id)?;
    if let Some(t) = token.map(str::trim).filter(|t| !t.is_empty()) {
        save_credential(store, id, &Credential::bearer(t))?;
        conn.auth = AuthKind::Token;
        upsert_connection(store, &conn)?;
        list_tools(store, id).await?;
        return Ok(json!({ "connected": get_connection(store, id)? }));
    }
    let ch = match probe(&conn.url, None).await? {
        Probe::NeedsAuth(ch) => ch,
        Probe::Ok => Challenge::default(),
    };
    let old = load_credential(store, id).ok().flatten();
    let client = old.filter(|c| !c.registered_client).and_then(|c| Some((c.client_id?, c.client_secret)));
    let auth = oauth::begin(http(), &conn.url, &ch, redirect_uri, client).await?;
    Ok(hold(Pending { auth, name: conn.name, url: conn.url, connection_id: Some(id.to_string()) }))
}

/// The browser came back with `code`: exchange it and store the connection.
pub async fn finish_connect(store: &SyncStore, state: &str, code: &str) -> Result<Connection, String> {
    let p = PENDING.lock().unwrap_or_else(|e| e.into_inner()).remove(state).ok_or("Start the sign-in again.")?;
    let cred = oauth::finish(http(), p.auth, code).await?;
    let conn = match p.connection_id {
        Some(id) => {
            save_credential(store, &id, &cred)?;
            let mut conn = get_connection(store, &id)?;
            conn.status = Status::Connected;
            conn.error = None;
            conn
        }
        None => {
            let conn = Connection { id: new_id(), name: p.name, url: p.url, auth: AuthKind::Oauth, status: Status::Connected, error: None };
            save_credential(store, &conn.id, &cred)?;
            conn
        }
    };
    upsert_connection(store, &conn)?;
    Ok(conn)
}

pub fn new_id() -> String {
    format!("mcpc_{}", nanoid::nanoid!(12))
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{body_partial_json, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    const SID: &str = "ses_test";

    /// A Streamable-HTTP MCP server: initialize (JSON + session id),
    /// initialized (202), tools/list (SSE, needs the session), tools/call (JSON).
    async fn mock_server(require_bearer: Option<&str>) -> MockServer {
        let server = MockServer::start().await;
        if require_bearer.is_some() {
            // Anything without the right bearer is a 401 (lower priority than the
            // authorised mocks below, which match first).
            Mock::given(method("POST"))
                .respond_with(ResponseTemplate::new(401).insert_header(
                    "WWW-Authenticate",
                    format!(r#"Bearer resource_metadata="{}/.well-known/oauth-protected-resource/mcp""#, server.uri()).as_str(),
                ))
                .with_priority(10)
                .mount(&server)
                .await;
        }
        let auth = |m: wiremock::MockBuilder| match require_bearer {
            Some(t) => m.and(header("Authorization", format!("Bearer {t}").as_str())),
            None => m,
        };
        auth(Mock::given(method("POST")).and(body_partial_json(json!({ "method": "initialize" }))))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("Mcp-Session-Id", SID)
                    .set_body_json(json!({ "jsonrpc": "2.0", "id": 1, "result": { "protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": { "name": "mock" } } })),
            )
            .with_priority(1)
            .mount(&server)
            .await;
        auth(Mock::given(method("POST")).and(body_partial_json(json!({ "method": "notifications/initialized" }))))
            .respond_with(ResponseTemplate::new(202))
            .with_priority(1)
            .mount(&server)
            .await;
        let sse = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\r\n\r\n\
                   event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"create_issue\",\"description\":\"Create an issue\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"}},\"required\":[\"title\"]}}]}}\r\n\r\n";
        auth(
            Mock::given(method("POST"))
                .and(body_partial_json(json!({ "method": "tools/list" })))
                .and(header("Mcp-Session-Id", SID))
                .and(header("MCP-Protocol-Version", "2025-06-18")),
        )
        .respond_with(ResponseTemplate::new(200).set_body_raw(sse, "text/event-stream"))
        .with_priority(1)
        .mount(&server)
        .await;
        auth(
            Mock::given(method("POST"))
                .and(body_partial_json(json!({ "method": "tools/call", "params": { "name": "create_issue", "arguments": { "title": "Hi" } } })))
                .and(header("Mcp-Session-Id", SID)),
        )
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "jsonrpc": "2.0", "id": 2,
            "result": { "content": [{ "type": "text", "text": "Created TUL-412" }], "isError": false }
        })))
        .with_priority(1)
        .mount(&server)
        .await;
        server
    }

    fn conn(url: String, auth: AuthKind) -> Connection {
        Connection { id: new_id(), name: "Mock".into(), url, auth, status: Status::Connected, error: None }
    }

    #[tokio::test]
    async fn lists_and_calls_tools_over_streamable_http() {
        let server = mock_server(None).await;
        let url = format!("{}/mcp", server.uri());
        let mut s = Session::connect(http(), &url, None).await.unwrap();
        let tools = parse_tools(&s.request("tools/list", json!({})).await.unwrap());
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0].name, "create_issue");
        assert_eq!(tools[0].input_schema["required"][0], "title");

        let store = SyncStore::new_in_memory().unwrap();
        let c = conn(url, AuthKind::None);
        upsert_connection(&store, &c).unwrap();
        let r = call_tool(&store, &c.id, "create_issue", json!({ "title": "Hi" })).await.unwrap();
        assert!(!r.is_error);
        assert_eq!(r.content[0]["text"], "Created TUL-412");
    }

    #[tokio::test]
    async fn bearer_token_connection_and_401_marks_needs_auth() {
        let server = mock_server(Some("good")).await;
        let url = format!("{}/mcp", server.uri());

        // No token → 401 with the resource-metadata pointer.
        match probe(&url, None).await.unwrap() {
            Probe::NeedsAuth(ch) => assert!(ch.resource_metadata.unwrap().ends_with("/.well-known/oauth-protected-resource/mcp")),
            Probe::Ok => panic!("expected a 401"),
        }
        assert!(matches!(probe(&url, Some("good")).await.unwrap(), Probe::Ok));

        let store = SyncStore::new_in_memory().unwrap();
        let c = conn(url, AuthKind::Token);
        upsert_connection(&store, &c).unwrap();
        save_credential(&store, &c.id, &Credential::bearer("good")).unwrap();
        assert_eq!(list_tools(&store, &c.id).await.unwrap().len(), 1);

        // A revoked token (no refresh possible) → needs_auth, recorded.
        save_credential(&store, &c.id, &Credential::bearer("revoked")).unwrap();
        assert_eq!(list_tools(&store, &c.id).await.unwrap_err(), NEEDS_AUTH);
        assert_eq!(get_connection(&store, &c.id).unwrap().status, Status::NeedsAuth);

        // Stored encrypted, never in the settings JSON; removal drops both.
        let raw = store.get_engine_setting(CONNECTIONS_KEY).unwrap().unwrap();
        assert!(!raw.contains("revoked"));
        remove_connection(&store, &c.id).unwrap();
        assert!(load_credential(&store, &c.id).unwrap().is_none());
        assert!(list_connections(&store).unwrap().is_empty());
    }

    #[tokio::test]
    async fn oauth_discovery_registration_exchange_and_refresh() {
        let server = MockServer::start().await;
        let base = server.uri();
        Mock::given(method("GET"))
            .and(path("/.well-known/oauth-protected-resource/mcp"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "resource": format!("{base}/mcp"), "authorization_servers": [format!("{base}/auth")], "scopes_supported": ["read", "write"]
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/.well-known/oauth-authorization-server/auth"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "authorization_endpoint": format!("{base}/auth/authorize"),
                "token_endpoint": format!("{base}/auth/token"),
                "registration_endpoint": format!("{base}/auth/register"),
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/auth/register"))
            .and(body_partial_json(json!({ "redirect_uris": ["http://127.0.0.1:5555/cb"], "token_endpoint_auth_method": "none" })))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "client_id": "cid_1" })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/auth/token"))
            .and(wiremock::matchers::body_string_contains("grant_type=authorization_code"))
            .and(wiremock::matchers::body_string_contains("code=the_code"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "access_token": "at_1", "refresh_token": "rt_1", "expires_in": 3600
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/auth/token"))
            .and(wiremock::matchers::body_string_contains("grant_type=refresh_token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "access_token": "at_2", "expires_in": 3600 })))
            .mount(&server)
            .await;

        let ch = Challenge { resource_metadata: None, scope: None }; // exercise the well-known fallback
        let p = oauth::begin(http(), &format!("{base}/mcp"), &ch, "http://127.0.0.1:5555/cb", None).await.unwrap();
        let u = url::Url::parse(&p.authorize_url).unwrap();
        assert!(u.path().ends_with("/auth/authorize"));
        let q: std::collections::HashMap<_, _> = u.query_pairs().into_owned().collect();
        assert_eq!(q["client_id"], "cid_1");
        assert_eq!(q["code_challenge_method"], "S256");
        assert_eq!(q["resource"], format!("{base}/mcp"));
        assert_eq!(q["scope"], "read write");
        assert_eq!(q["state"], p.state);

        let cred = oauth::finish(http(), p, "the_code").await.unwrap();
        assert_eq!(cred.access_token, "at_1");
        assert!(cred.can_refresh() && !cred.expired());
        assert!(cred.registered_client);

        let r = oauth::refresh(http(), &cred).await.unwrap();
        assert_eq!(r.access_token, "at_2");
        assert_eq!(r.refresh_token.as_deref(), Some("rt_1")); // kept when not rotated
    }

    #[test]
    fn urls_must_be_https_except_loopback() {
        assert!(validate_url("https://mcp.linear.app/mcp").is_ok());
        assert!(validate_url("http://127.0.0.1:8080/mcp").is_ok());
        assert!(validate_url("http://example.com/mcp").is_err());
        assert!(validate_url("not a url").is_err());
    }
}
