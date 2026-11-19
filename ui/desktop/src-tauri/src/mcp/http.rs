//! HTTP transport for the in-core MCP server.
//!
//! The Rust core hosts a single MCP endpoint over loopback HTTP so that any
//! MCP client (Claude Desktop / Cursor / an agent runtime) can drive the same
//! live sync engine the Tauri UI uses — writes are deferred to the engine's
//! write-back queue, so the interface is fully UI-agnostic.
//!
//! Transport: MCP Streamable HTTP, JSON-only. This server pushes no
//! server-initiated messages, so there is no SSE stream — `POST /mcp` carries
//! a JSON-RPC request and returns a JSON-RPC response.
//!
//! Dual-era (spec 2026-07-28 "Backward Compatibility"): a request whose `_meta`
//! declares a protocol version is served statelessly — its `MCP-Protocol-Version`
//! / `Mcp-Method` / `Mcp-Name` headers must match the body, and the agent is the
//! `_meta` clientInfo. Anything else is the handshake era: `initialize` hands
//! back an `Mcp-Session-Id` header that later requests echo.
//!
//! Security: bound to 127.0.0.1 and gated by a bearer token. Not intended to
//! be exposed off-host.

use std::io::Cursor;
use std::sync::Arc;

use serde_json::Value;
use tiny_http::{Header, Method, Request, Response, Server};

use crate::mcp::protocol::{JsonRpcRequest, JsonRpcResponse};
use crate::mcp::server::{self, McpServer};

/// Whether requests are served. Settings can switch the server off without a
/// restart: the listener stays bound and answers 503 until switched back on.
static ENABLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn set_enabled(on: bool) {
    ENABLED.store(on, std::sync::atomic::Ordering::Relaxed);
}

/// Spawn the MCP HTTP server on a dedicated thread. Returns immediately; the
/// accept loop runs until the process exits.
pub fn spawn(server: Arc<McpServer>, token: String, port: u16) {
    std::thread::Builder::new()
        .name("mcp-http".into())
        .spawn(move || {
            let addr = format!("127.0.0.1:{port}");
            let http = match Server::http(&addr) {
                Ok(s) => s,
                Err(e) => {
                    log::error!("MCP HTTP server failed to bind {addr}: {e}");
                    return;
                }
            };
            log::info!("MCP HTTP server listening on http://{addr}/mcp");
            for request in http.incoming_requests() {
                handle(&server, &token, request);
            }
        })
        .expect("failed to spawn mcp-http thread");
}

/// Case-insensitive header lookup.
fn header_value<'a>(req: &'a Request, name: &str) -> Option<&'a str> {
    req.headers()
        .iter()
        .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

fn json_response(
    status: u16,
    body: String,
    session_id: Option<&str>,
) -> Response<Cursor<Vec<u8>>> {
    let mut resp = Response::from_string(body).with_status_code(status);
    resp.add_header(
        Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap(),
    );
    if let Some(sid) = session_id {
        if let Ok(h) = Header::from_bytes(&b"Mcp-Session-Id"[..], sid.as_bytes()) {
            resp.add_header(h);
        }
    }
    resp
}

fn handle(server: &Arc<McpServer>, token: &str, mut request: Request) {
    let path = request.url().split('?').next().unwrap_or("");

    // Lightweight liveness probe.
    if request.method() == &Method::Get && path == "/health" {
        let _ = request.respond(Response::from_string("ok"));
        return;
    }

    if !ENABLED.load(std::sync::atomic::Ordering::Relaxed) {
        let _ = request.respond(json_response(503, r#"{"error":"agent access is off in inbox2 settings"}"#.into(), None));
        return;
    }

    // No standalone SSE stream and no sessions to DELETE.
    if path == "/mcp" && request.method() != &Method::Post {
        let _ = request.respond(Response::from_string("").with_status_code(405));
        return;
    }
    if path != "/mcp" {
        let _ = request.respond(Response::from_string("Not found").with_status_code(404));
        return;
    }

    // Defence against DNS-rebinding: a web page the user visits could rebind a
    // hostname to this loopback port and POST `/mcp` from the browser. Reject any
    // request whose Origin is a real web origin, and require a loopback Host. The
    // bearer token is still the primary gate; this closes the rebinding class so
    // the token is not the *only* defence.
    if !origin_allowed(&request) || !host_is_loopback(&request) {
        let _ = request.respond(json_response(403, r#"{"error":"forbidden origin"}"#.into(), None));
        return;
    }

    // Bearer-token auth. Compare in constant time so a network attacker can't
    // recover the token byte-by-byte via response timing.
    let authorized = header_value(&request, "Authorization")
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| ct_eq(t, token))
        .unwrap_or(false);
    if !authorized {
        let _ = request.respond(json_response(401, r#"{"error":"unauthorized"}"#.into(), None));
        return;
    }

    // Read the headers we need before consuming the body reader.
    let session_id = header_value(&request, "Mcp-Session-Id").map(String::from);
    let headers = RoutingHeaders {
        version: header_value(&request, "MCP-Protocol-Version").map(String::from),
        method: header_value(&request, "Mcp-Method").map(String::from),
        name: header_value(&request, "Mcp-Name").map(String::from),
    };

    let mut body = String::new();
    if request.as_reader().read_to_string(&mut body).is_err() {
        let _ = request.respond(json_response(400, r#"{"error":"unreadable body"}"#.into(), None));
        return;
    }

    let rpc: JsonRpcRequest = match serde_json::from_str(&body) {
        Ok(r) => r,
        Err(e) => {
            let err = JsonRpcResponse::error(Value::Null, -32700, &format!("Parse error: {e}"));
            let _ = request.respond(json_response(200, to_json(&err), None));
            return;
        }
    };

    if let Some(version) = server::modern_version(&rpc) {
        let id = rpc.id.clone().unwrap_or(Value::Null);
        if let Err(msg) = headers.check(&rpc, version) {
            let err = JsonRpcResponse::error(id, server::HEADER_MISMATCH, &msg);
            let _ = request.respond(json_response(400, to_json(&err), None));
            return;
        }
        let agent_key = match server.agent_for_request(&rpc) {
            Ok(key) => key,
            Err(e) => {
                let err = JsonRpcResponse::error(id, -32603, &e);
                let _ = request.respond(json_response(500, to_json(&err), None));
                return;
            }
        };
        let _ = match server.handle_request(&rpc, &agent_key) {
            Some(resp) => {
                let status = match resp.error.as_ref().map(|e| e.code) {
                    Some(server::UNSUPPORTED_PROTOCOL_VERSION) => 400,
                    Some(server::METHOD_NOT_FOUND) => 404,
                    _ => 200,
                };
                request.respond(json_response(status, to_json(&resp), None))
            }
            None => request.respond(Response::from_string("").with_status_code(202)),
        };
        return;
    }

    // Handshake era. On `initialize`, open a session for the agent; other
    // methods reuse the session id the client sent back.
    let mut new_session: Option<String> = None;
    let agent_key = if rpc.method == "initialize" {
        let client_name = rpc.params["clientInfo"]["name"]
            .as_str()
            .unwrap_or("unknown-agent");
        match server.open_session(client_name) {
            Ok(sid) => {
                let key = server.agent_for_session(Some(&sid));
                new_session = Some(sid);
                key
            }
            Err(e) => {
                let id = rpc.id.clone().unwrap_or(Value::Null);
                let err = JsonRpcResponse::error(id, -32603, &e);
                let _ = request.respond(json_response(200, to_json(&err), None));
                return;
            }
        }
    } else {
        server.agent_for_session(session_id.as_deref())
    };

    match server.handle_request(&rpc, &agent_key) {
        Some(resp) => {
            let _ = request.respond(json_response(200, to_json(&resp), new_session.as_deref()));
        }
        // Notification (no id): acknowledge with 202 and no body.
        None => {
            let _ = request.respond(Response::from_string("").with_status_code(202));
        }
    }
}

/// The routing headers a modern request mirrors from its body.
struct RoutingHeaders {
    version: Option<String>,
    method: Option<String>,
    name: Option<String>,
}

impl RoutingHeaders {
    /// Spec 2026-07-28 "Server Validation": each header must be present and equal
    /// the body value it mirrors, so nothing routing on headers can be told one
    /// thing while the server executes another.
    fn check(&self, rpc: &JsonRpcRequest, version: &str) -> Result<(), String> {
        match self.version.as_deref() {
            None => return Err("Header mismatch: MCP-Protocol-Version header is missing".into()),
            Some(v) if v != version => {
                return Err(format!("Header mismatch: MCP-Protocol-Version '{v}' does not match body '{version}'"))
            }
            _ => {}
        }
        match self.method.as_deref() {
            None => return Err("Header mismatch: Mcp-Method header is missing".into()),
            Some(m) if m != rpc.method => {
                return Err(format!("Header mismatch: Mcp-Method '{m}' does not match body '{}'", rpc.method))
            }
            _ => {}
        }
        let body_name = match rpc.method.as_str() {
            "tools/call" | "prompts/get" => rpc.params["name"].as_str(),
            "resources/read" => rpc.params["uri"].as_str(),
            _ => return Ok(()),
        };
        let Some(raw) = self.name.as_deref() else {
            return Err("Header mismatch: Mcp-Name header is missing".into());
        };
        let name = decode_header_value(raw).ok_or("Header mismatch: Mcp-Name is not valid base64")?;
        if Some(name.as_str()) != body_name {
            return Err(format!("Header mismatch: Mcp-Name '{name}' does not match body value"));
        }
        Ok(())
    }
}

/// Undo the `=?base64?…?=` sentinel clients use for values that aren't plain
/// header-safe ASCII. A plain value passes through.
fn decode_header_value(raw: &str) -> Option<String> {
    use base64::Engine;
    match raw.strip_prefix("=?base64?").and_then(|r| r.strip_suffix("?=")) {
        Some(b64) => base64::engine::general_purpose::STANDARD
            .decode(b64)
            .ok()
            .and_then(|b| String::from_utf8(b).ok()),
        None => Some(raw.to_string()),
    }
}

fn to_json(resp: &JsonRpcResponse) -> String {
    serde_json::to_string(resp).unwrap_or_default()
}

/// Reject browser DNS-rebinding: a present `Origin` must be a loopback web origin
/// (or the literal `null`). Non-browser MCP clients (Claude Desktop, curl) send no
/// Origin and pass through to the bearer-token check.
fn origin_allowed(req: &Request) -> bool {
    origin_value_allowed(header_value(req, "Origin"))
}

/// `Origin`-header policy, split out so it's unit-testable without a `Request`.
fn origin_value_allowed(origin: Option<&str>) -> bool {
    match origin {
        None => true,
        Some(o) => {
            o == "null"
                || host_part_is_loopback(
                    o.strip_prefix("http://")
                        .or_else(|| o.strip_prefix("https://"))
                        .unwrap_or(o),
                )
        }
    }
}

/// A present `Host` header must name loopback, so a public hostname rebound to
/// this port is rejected. Absent Host (rare, non-browser) is allowed — the bearer
/// token and Origin check still apply, and browsers always send Host.
fn host_is_loopback(req: &Request) -> bool {
    host_value_loopback(header_value(req, "Host"))
}

/// `Host`-header policy, split out so it's unit-testable without a `Request`.
fn host_value_loopback(host: Option<&str>) -> bool {
    match host {
        None => true,
        Some(h) => host_part_is_loopback(h),
    }
}

/// True if `hostport` (e.g. `127.0.0.1:8765`, `localhost`, `[::1]:8765`) names a
/// loopback host.
fn host_part_is_loopback(hostport: &str) -> bool {
    let host = if let Some(rest) = hostport.strip_prefix('[') {
        rest.split(']').next().unwrap_or("") // IPv6 literal: [::1]:port
    } else {
        hostport.split(':').next().unwrap_or("")
    };
    host == "127.0.0.1" || host == "localhost" || host == "::1"
}

/// Constant-time byte comparison. The length check leaks only the token length
/// (fixed and not secret); the byte comparison itself runs in time independent
/// of how many leading bytes match.
fn ct_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::ct_eq;

    fn rpc(method: &str, params: serde_json::Value) -> super::JsonRpcRequest {
        serde_json::from_value(serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }))
            .unwrap()
    }

    fn headers(version: Option<&str>, method: Option<&str>, name: Option<&str>) -> super::RoutingHeaders {
        super::RoutingHeaders {
            version: version.map(String::from),
            method: method.map(String::from),
            name: name.map(String::from),
        }
    }

    #[test]
    fn modern_headers_must_mirror_the_body() {
        let call = rpc("tools/call", serde_json::json!({ "name": "read_message" }));
        let v = "2026-07-28";
        assert!(headers(Some(v), Some("tools/call"), Some("read_message")).check(&call, v).is_ok());
        // Base64 sentinel decodes before comparing.
        assert!(headers(Some(v), Some("tools/call"), Some("=?base64?cmVhZF9tZXNzYWdl?=")).check(&call, v).is_ok());
        assert!(headers(None, Some("tools/call"), Some("read_message")).check(&call, v).is_err());
        assert!(headers(Some("2025-11-25"), Some("tools/call"), Some("read_message")).check(&call, v).is_err());
        assert!(headers(Some(v), Some("tools/list"), Some("read_message")).check(&call, v).is_err());
        assert!(headers(Some(v), Some("tools/call"), None).check(&call, v).is_err());
        assert!(headers(Some(v), Some("tools/call"), Some("trash")).check(&call, v).is_err());
        // Mcp-Name is only required where the body has a name/uri.
        let list = rpc("tools/list", serde_json::json!({}));
        assert!(headers(Some(v), Some("tools/list"), None).check(&list, v).is_ok());
    }

    #[test]
    fn ct_eq_matches_only_identical_tokens() {
        assert!(ct_eq("secret-token", "secret-token"));
        assert!(!ct_eq("secret-token", "secret-tokeN"));
        assert!(!ct_eq("secret", "secret-token"));
        assert!(!ct_eq("", "x"));
        assert!(ct_eq("", ""));
    }

    #[test]
    fn loopback_host_check() {
        use super::host_part_is_loopback;
        assert!(host_part_is_loopback("127.0.0.1:8765"));
        assert!(host_part_is_loopback("127.0.0.1"));
        assert!(host_part_is_loopback("localhost:8765"));
        assert!(host_part_is_loopback("[::1]:8765"));
        // A rebound public hostname must be rejected.
        assert!(!host_part_is_loopback("evil.example.com:8765"));
        assert!(!host_part_is_loopback("attacker.test"));
        assert!(!host_part_is_loopback("10.0.0.5:8765"));
    }

    #[test]
    fn origin_policy_blocks_remote_web_origins() {
        use super::origin_value_allowed;
        // Non-browser clients (no Origin header) pass; the bearer token gates them.
        assert!(origin_value_allowed(None));
        // Loopback web origins (and the literal `null`) are allowed.
        assert!(origin_value_allowed(Some("http://127.0.0.1:8765")));
        assert!(origin_value_allowed(Some("http://localhost")));
        assert!(origin_value_allowed(Some("https://[::1]:8765")));
        assert!(origin_value_allowed(Some("null")));
        // A real remote web origin (the DNS-rebinding case) is rejected.
        assert!(!origin_value_allowed(Some("https://evil.example.com")));
        assert!(!origin_value_allowed(Some("http://attacker.test:8765")));
    }

    #[test]
    fn host_policy_requires_loopback_when_present() {
        use super::host_value_loopback;
        assert!(host_value_loopback(None)); // absent → allowed (token + Origin still apply)
        assert!(host_value_loopback(Some("127.0.0.1:8765")));
        assert!(host_value_loopback(Some("localhost")));
        // A public hostname rebound to the loopback port is rejected.
        assert!(!host_value_loopback(Some("evil.example.com:8765")));
        assert!(!host_value_loopback(Some("10.0.0.5")));
    }
}
