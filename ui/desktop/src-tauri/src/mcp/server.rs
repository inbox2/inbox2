use parking_lot::Mutex;
use rusqlite::Connection;
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

/// Upper bound on live MCP sessions kept in memory. Each `initialize` opens a
/// session; without a cap a long-running server would accumulate one entry per
/// reconnect forever. Oldest sessions are evicted FIFO past this.
const MAX_SESSIONS: usize = 4096;

/// The stateless protocol revision (version, client identity and capabilities
/// ride in every request's `_meta`; no `initialize`, no sessions).
pub const MODERN_VERSION: &str = "2026-07-28";
/// Handshake-era revisions still served through `initialize` + `Mcp-Session-Id`,
/// newest first. The server is dual-era: which path a client gets is decided by
/// whether its request carries [`META_VERSION`].
const LEGACY_VERSIONS: &[&str] = &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
pub const META_VERSION: &str = "io.modelcontextprotocol/protocolVersion";
pub const META_CLIENT_INFO: &str = "io.modelcontextprotocol/clientInfo";

pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const HEADER_MISMATCH: i32 = -32020;
pub const UNSUPPORTED_PROTOCOL_VERSION: i32 = -32022;

/// Tool and resource lists only change with a new build.
const LIST_TTL_MS: u64 = 60 * 60 * 1000;

const INSTRUCTIONS: &str = "inbox2 mail: every connected mailbox (Gmail, Microsoft, IMAP) plus \
inbox2-hosted mail mirrored on this device. Find mail with search_messages, then \
read_conversation / read_message. Attachments: list_attachments gives ids, \
get_attachment returns the file. End-to-end sealed mail is never exposed.";

/// The protocol revision a request declares in `_meta`, if it's a modern request.
pub fn modern_version(request: &JsonRpcRequest) -> Option<&str> {
    request.params["_meta"][META_VERSION].as_str()
}

use crate::local_agents::store::AuditStatus;
use crate::mcp::permissions::{PermissionLevel, PermissionManager};
use crate::mcp::protocol::*;
use crate::mcp::resources;
use crate::mcp::tools;
use crate::sync::actions::WritebackQueue;
use crate::sync::engine::SyncEngine;
use crate::vector::store::VectorStore;

/// MCP server core: transport-agnostic JSON-RPC dispatch.
///
/// Hosted in-process by the Rust core (the sync-engine process) and exposed
/// over loopback HTTP (see [`crate::mcp::http`]) so that any MCP client drives
/// the *same* live sync engine the Tauri UI uses. Writes are deferred to the
/// engine's write-back queue, so the interface is fully UI-agnostic.
///
/// Shared across concurrent HTTP clients, so every method takes `&self`:
/// per-client identity is tracked via sessions, not a mutable field.
pub struct McpServer {
    conn: Arc<Mutex<Connection>>,
    vector_store: Arc<VectorStore>,
    permissions: PermissionManager,
    writeback: Arc<WritebackQueue>,
    /// The live sync engine. Tools use it for reads/queue writes via its store
    /// and write-back queue, and for the interactive provider path (e.g.
    /// `set_priority`, which propagates as triage labels rather than a
    /// write-back ActionType).
    engine: Arc<SyncEngine>,
    /// Maps an MCP session id (handed out on `initialize`) to the resolved
    /// agent key, so later tool calls permission-check and audit against the
    /// right agent. Bounded FIFO (see [`MAX_SESSIONS`]).
    sessions: Mutex<Sessions>,
}

/// Bounded session map: a `HashMap` for lookup plus an insertion-order queue so
/// the oldest entry can be evicted once the map is full.
#[derive(Default)]
struct Sessions {
    map: HashMap<String, String>,
    order: VecDeque<String>,
}

impl McpServer {
    /// Build the server from the live sync engine, sharing its DB connection
    /// and write-back queue so agent writes defer to the same engine the UI uses.
    pub fn new(engine: Arc<SyncEngine>) -> Self {
        let conn = engine.store().connection();
        let writeback = engine.writeback().clone();
        let vector_store = Arc::new(VectorStore::new(conn.clone()));
        let permissions = PermissionManager::new(conn.clone());
        Self {
            conn,
            vector_store,
            permissions,
            writeback,
            engine,
            sessions: Mutex::new(Sessions::default()),
        }
    }

    /// Register (or touch) the connecting agent and open a session for it.
    /// Returns the session id; the transport echoes it in the `Mcp-Session-Id`
    /// response header and clients send it back on subsequent requests.
    pub fn open_session(&self, client_name: &str) -> Result<String, String> {
        let agent = self.permissions.register_or_touch(client_name, None)?;
        let session_id = format!("ses_{}", nanoid::nanoid!(24));
        let mut sessions = self.sessions.lock();
        if sessions.order.len() >= MAX_SESSIONS {
            if let Some(oldest) = sessions.order.pop_front() {
                sessions.map.remove(&oldest);
            }
        }
        sessions.map.insert(session_id.clone(), agent.key);
        sessions.order.push_back(session_id.clone());
        Ok(session_id)
    }

    /// Resolve the agent key for a session id. Unknown/missing → `"unknown"`,
    /// which fails permission checks for anything above the lowest tier.
    pub fn agent_for_session(&self, session_id: Option<&str>) -> String {
        session_id
            .and_then(|s| self.sessions.lock().map.get(s).cloned())
            .unwrap_or_else(|| "unknown".to_string())
    }

    /// Dispatch a single JSON-RPC request. `agent_key` identifies the caller
    /// (resolved by the transport from its session). Returns `None` for
    /// notifications (no `id`), which get no response.
    pub fn handle_request(
        &self,
        request: &JsonRpcRequest,
        agent_key: &str,
    ) -> Option<JsonRpcResponse> {
        if request.id.is_none() {
            return None;
        }
        let id = request.id.clone().unwrap_or(Value::Null);

        if let Some(version) = modern_version(request) {
            if version != MODERN_VERSION {
                return Some(JsonRpcResponse::error_with_data(
                    id,
                    UNSUPPORTED_PROTOCOL_VERSION,
                    "Unsupported protocol version",
                    Some(json!({ "supported": [MODERN_VERSION], "requested": version })),
                ));
            }
        }

        let result = match request.method.as_str() {
            "initialize" => self.handle_initialize(&request.params),
            "server/discover" => Ok(self.handle_discover()),
            "tools/list" => Ok(cacheable(json!({ "tools": tools::tool_definitions().into_iter().map(|t| {
                let mut v = json!(t);
                v["annotations"] = tools::tool_annotations(&t.name);
                v
            }).collect::<Vec<_>>() }))),
            "tools/call" => self.handle_tools_call(&request.params, agent_key),
            "resources/list" => Ok(cacheable(json!({ "resources": resources::resource_definitions() }))),
            "resources/read" => self.handle_resources_read(&request.params),
            "ping" => Ok(json!({})),
            other => {
                return Some(JsonRpcResponse::error(id, METHOD_NOT_FOUND, &format!("Method not found: {other}")))
            }
        };

        Some(match result {
            Ok(value) => JsonRpcResponse::success(id, complete(value)),
            Err(msg) => JsonRpcResponse::error(id, INVALID_PARAMS, &msg),
        })
    }

    /// Agent key for a stateless (modern) request: the self-reported client name
    /// in `_meta`, the same identity legacy clients give in `initialize`.
    pub fn agent_for_request(&self, request: &JsonRpcRequest) -> Result<String, String> {
        let name = request.params["_meta"][META_CLIENT_INFO]["name"]
            .as_str()
            .unwrap_or("unknown-agent");
        Ok(self.permissions.register_or_touch(name, None)?.key)
    }

    fn handle_discover(&self) -> Value {
        cacheable(json!({
            "supportedVersions": [MODERN_VERSION],
            "capabilities": { "tools": {}, "resources": {} },
            "instructions": INSTRUCTIONS,
        }))
    }

    fn handle_initialize(&self, params: &Value) -> Result<Value, String> {
        // Legacy handshake: echo the client's version when we speak it, else offer
        // our newest handshake-era one (modern clients never send `initialize`).
        let protocol = params["protocolVersion"]
            .as_str()
            .filter(|v| LEGACY_VERSIONS.contains(v))
            .unwrap_or(LEGACY_VERSIONS[0]);
        Ok(json!({
            "protocolVersion": protocol,
            "capabilities": {
                "tools": { "listChanged": false },
                "resources": { "listChanged": false, "subscribe": false }
            },
            "serverInfo": server_info(),
            "instructions": INSTRUCTIONS
        }))
    }

    fn handle_tools_call(&self, params: &Value, agent_key: &str) -> Result<Value, String> {
        let tool_name = params["name"].as_str().ok_or("Missing tool name")?;
        let tool_params = &params["arguments"];

        // Check permissions
        let required = tools::tool_permission(tool_name);
        if !self.permissions.check_permission(agent_key, &required)? {
            let result = ToolResult::error(format!(
                "Permission denied: '{tool_name}' requires {:?} permission",
                required
            ));
            self.permissions.log_action(
                agent_key,
                tool_name,
                Some(&tool_params.to_string()),
                None,
                "denied",
                Some("Insufficient permission"),
                None,
            )?;
            return Ok(serde_json::to_value(result).unwrap());
        }

        // Privileged (Full-tier) tools additionally require human approval unless
        // auto-approve is enabled globally or per-agent. Without an interactive
        // approval channel here, "needs approval" means "reject" — the agent must
        // be granted auto-approve to perform privileged actions. This enforces the
        // documented privileged-action gate (previously `needs_approval` was never
        // invoked, so privileged tools ran unchecked).
        if required == PermissionLevel::Full && self.permissions.needs_approval(agent_key)? {
            let result = ToolResult::error(format!(
                "Approval required: '{tool_name}' is a privileged action and this agent is not auto-approved"
            ));
            self.permissions.log_action(
                agent_key,
                tool_name,
                Some(&tool_params.to_string()),
                None,
                "denied",
                Some("Approval required (auto-approve disabled)"),
                None,
            )?;
            return Ok(serde_json::to_value(result).unwrap());
        }

        // Execute the tool
        let start = std::time::Instant::now();
        let result = tools::execute_tool(
            &self.conn,
            &self.vector_store,
            &self.writeback,
            &self.engine,
            tool_name,
            tool_params,
        );
        let duration = start.elapsed().as_millis() as i64;

        // Audit log
        let is_error = result.is_error.unwrap_or(false);
        let status = if is_error { AuditStatus::Error } else { AuditStatus::Success };
        let summary = Some(result.first_text().chars().take(500).collect::<String>());
        // On error the tool's message lives in `content`; record it as the audit
        // `error_message` rather than dropping it (the result_summary is left
        // empty for failures so the two columns don't duplicate the same text).
        let (result_summary, error_message) = if is_error {
            (None, summary.as_deref())
        } else {
            (summary.as_deref(), None)
        };

        self.permissions.log_action(
            agent_key,
            tool_name,
            Some(&tool_params.to_string()),
            result_summary,
            status.as_str(),
            error_message,
            Some(duration),
        )?;

        Ok(serde_json::to_value(result).unwrap())
    }

    fn handle_resources_read(&self, params: &Value) -> Result<Value, String> {
        let uri = params["uri"].as_str().ok_or("Missing resource URI")?;
        let content = resources::read_resource(&self.conn, uri)?;
        Ok(json!({
            "contents": [{
                "uri": uri,
                "mimeType": "application/json",
                "text": serde_json::to_string_pretty(&content).unwrap_or_default()
            }]
        }))
    }
}

fn server_info() -> Value {
    json!({ "name": "inbox2-mcp", "version": env!("CARGO_PKG_VERSION") })
}

/// Every result is `complete` (this server never asks for more input) and names
/// the server in `_meta`. Harmless extra fields for handshake-era clients.
fn complete(mut value: Value) -> Value {
    if let Some(obj) = value.as_object_mut() {
        obj.insert("resultType".into(), json!("complete"));
        obj.entry("_meta")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .map(|m| m.insert("io.modelcontextprotocol/serverInfo".into(), server_info()));
    }
    value
}

/// List results carry a cache hint. Not user data, so shareable.
fn cacheable(mut value: Value) -> Value {
    value["ttlMs"] = json!(LIST_TTL_MS);
    value["cacheScope"] = json!("public");
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::events::NullSink;
    use crate::sync::store::SyncStore;
    use rusqlite::params;

    fn server() -> McpServer {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let engine = Arc::new(SyncEngine::new(store, Arc::new(NullSink)));
        McpServer::new(engine)
    }

    fn call_trash(srv: &McpServer, agent_key: &str) -> Value {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(json!(1)),
            method: "tools/call".into(),
            params: json!({ "name": "trash", "arguments": {} }),
        };
        srv.handle_request(&req, agent_key)
            .expect("request with id yields a response")
            .result
            .expect("tools/call returns a result envelope")
    }

    fn audit_status(srv: &McpServer, agent_key: &str) -> (String, Option<String>) {
        srv.conn
            .lock()
            .query_row(
                "SELECT status, error_message FROM agent_audit_log
                 WHERE agent_key = ?1 ORDER BY id DESC LIMIT 1",
                params![agent_key],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap()
    }

    #[test]
    fn read_agent_is_denied_privileged_tool() {
        let srv = server();
        let agent = srv.permissions.register_or_touch("reader", None).unwrap();
        let result = call_trash(&srv, &agent.key);
        assert_eq!(result["isError"], json!(true));
        assert!(result["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Permission denied"));
        assert_eq!(audit_status(&srv, &agent.key).0, "denied");
    }

    #[test]
    fn full_agent_without_auto_approve_requires_approval() {
        let srv = server();
        // Default permission for new agents → "full".
        srv.conn
            .lock()
            .execute(
                "UPDATE vector_settings SET value = 'full' WHERE key = 'mcp_permission_default'",
                [],
            )
            .unwrap();
        let agent = srv.permissions.register_or_touch("privileged", None).unwrap();
        let result = call_trash(&srv, &agent.key);
        assert_eq!(result["isError"], json!(true));
        assert!(result["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Approval required"));
        assert_eq!(audit_status(&srv, &agent.key).0, "denied");
    }

    #[test]
    fn full_agent_with_auto_approve_passes_the_gate() {
        let srv = server();
        srv.conn
            .lock()
            .execute(
                "UPDATE vector_settings SET value = 'full' WHERE key = 'mcp_permission_default'",
                [],
            )
            .unwrap();
        let agent = srv.permissions.register_or_touch("trusted", None).unwrap();
        srv.conn
            .lock()
            .execute(
                "UPDATE agents SET auto_approve = 1 WHERE key = ?1",
                params![agent.key],
            )
            .unwrap();
        let result = call_trash(&srv, &agent.key);
        // It clears the permission + approval gates and reaches the handler,
        // which then rejects the empty arguments — *not* an approval error.
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(!text.contains("Approval required"), "should pass approval gate: {text}");
        assert!(text.contains("account_key is required"));
    }

    #[test]
    fn tool_error_is_recorded_in_audit_error_message() {
        let srv = server();
        let agent = srv.permissions.register_or_touch("reader", None).unwrap();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(json!(1)),
            method: "tools/call".into(),
            // read_message is Read-tier (passes the gate) but errors on empty args.
            params: json!({ "name": "read_message", "arguments": {} }),
        };
        srv.handle_request(&req, &agent.key).unwrap();
        let (status, err) = audit_status(&srv, &agent.key);
        assert_eq!(status, "error");
        assert!(err.unwrap().contains("message_key is required"));
    }

    #[test]
    fn unknown_method_yields_jsonrpc_error() {
        let srv = server();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(json!(7)),
            method: "no_such_method".into(),
            params: Value::Null,
        };
        let resp = srv.handle_request(&req, "unknown").unwrap();
        assert!(resp.result.is_none());
        assert!(resp.error.is_some());
    }

    fn modern(srv: &McpServer, method: &str, version: &str) -> JsonRpcResponse {
        let req: JsonRpcRequest = serde_json::from_value(json!({
            "jsonrpc": "2.0", "id": 1, "method": method,
            "params": { "_meta": {
                META_VERSION: version,
                META_CLIENT_INFO: { "name": "modern-client", "version": "1" },
                "io.modelcontextprotocol/clientCapabilities": {}
            }}
        }))
        .unwrap();
        let agent = srv.agent_for_request(&req).unwrap();
        srv.handle_request(&req, &agent).unwrap()
    }

    #[test]
    fn modern_discover_lists_the_version_and_cache_hints() {
        let srv = server();
        let r = modern(&srv, "server/discover", MODERN_VERSION).result.unwrap();
        assert_eq!(r["supportedVersions"], json!([MODERN_VERSION]));
        assert_eq!(r["resultType"], "complete");
        assert_eq!(r["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], "inbox2-mcp");
        assert!(r["ttlMs"].as_u64().is_some());
        let tools = modern(&srv, "tools/list", MODERN_VERSION).result.unwrap();
        assert_eq!(tools["cacheScope"], "public");
        let names: Vec<&str> = tools["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        for want in ["search_messages", "read_message", "list_attachments", "get_attachment"] {
            assert!(names.contains(&want), "{want} missing");
        }
        // every tool says whether it only reads, so clients need not guess from its name
        let hint = |n: &str| tools["tools"].as_array().unwrap().iter().find(|t| t["name"] == n).unwrap()["annotations"].clone();
        for t in tools["tools"].as_array().unwrap() {
            assert!(t["annotations"]["readOnlyHint"].is_boolean(), "{} has no readOnlyHint", t["name"]);
        }
        assert_eq!(hint("list_conversations")["readOnlyHint"], true);
        assert_eq!(hint("get_attachment")["readOnlyHint"], true);
        assert_eq!((hint("delete")["readOnlyHint"].clone(), hint("delete")["destructiveHint"].clone()), (json!(false), json!(true)));
        assert_eq!(hint("add_tag")["destructiveHint"], false);
    }

    #[test]
    fn modern_rejects_unknown_versions_with_the_supported_list() {
        let srv = server();
        let err = modern(&srv, "tools/list", "2099-01-01").error.unwrap();
        assert_eq!(err.code, UNSUPPORTED_PROTOCOL_VERSION);
        assert_eq!(err.data.unwrap()["supported"], json!([MODERN_VERSION]));
        assert_eq!(modern(&srv, "nope", MODERN_VERSION).error.unwrap().code, METHOD_NOT_FOUND);
    }

    #[test]
    fn legacy_initialize_still_negotiates_a_handshake_version() {
        let srv = server();
        let init = |v: &str| {
            let req: JsonRpcRequest = serde_json::from_value(json!({
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": { "protocolVersion": v, "clientInfo": { "name": "old", "version": "1" } }
            }))
            .unwrap();
            srv.handle_request(&req, "unknown").unwrap().result.unwrap()["protocolVersion"].clone()
        };
        assert_eq!(init("2025-06-18"), "2025-06-18");
        assert_eq!(init("1999-01-01"), LEGACY_VERSIONS[0]);
    }
}
