use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// JSON-RPC 2.0 request (MCP uses this as transport).
#[derive(Debug, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: Option<Value>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

/// JSON-RPC 2.0 response.
#[derive(Debug, Serialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: Value,
    // JSON-RPC allows exactly one of the two; a `"error": null` next to a result
    // trips strict clients.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

#[derive(Debug, Serialize)]
pub struct JsonRpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// JSON-RPC 2.0 notification (no id, no response expected).
#[derive(Debug, Serialize)]
pub struct JsonRpcNotification {
    pub jsonrpc: String,
    pub method: String,
    pub params: Value,
}

impl JsonRpcResponse {
    pub fn success(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: Value, code: i32, message: &str) -> Self {
        Self::error_with_data(id, code, message, None)
    }

    pub fn error_with_data(id: Value, code: i32, message: &str, data: Option<Value>) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(JsonRpcError { code, message: message.to_string(), data }),
        }
    }
}

impl JsonRpcNotification {
    pub fn new(method: &str, params: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            method: method.to_string(),
            params,
        }
    }
}

// MCP-specific types

/// MCP server capabilities declared during initialize.
#[derive(Debug, Serialize)]
pub struct ServerCapabilities {
    pub tools: ToolsCapability,
    pub resources: ResourcesCapability,
}

#[derive(Debug, Serialize)]
pub struct ToolsCapability {
    #[serde(rename = "listChanged")]
    pub list_changed: bool,
}

#[derive(Debug, Serialize)]
pub struct ResourcesCapability {
    #[serde(rename = "listChanged")]
    pub list_changed: bool,
    pub subscribe: bool,
}

/// MCP tool definition.
#[derive(Debug, Clone, Serialize)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema")]
    pub input_schema: Value,
}

/// MCP resource definition.
#[derive(Debug, Clone, Serialize)]
pub struct ResourceDefinition {
    pub uri: String,
    pub name: String,
    pub description: String,
    #[serde(rename = "mimeType")]
    pub mime_type: String,
}

/// MCP tool call result. `content` holds MCP content blocks (`text`, `image`,
/// `resource`) as raw JSON; the first block is what the audit log summarises.
#[derive(Debug, Serialize)]
pub struct ToolResult {
    pub content: Vec<Value>,
    #[serde(rename = "isError", skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
}

impl ToolResult {
    pub fn text(text: String) -> Self {
        Self { content: vec![json!({ "type": "text", "text": text })], is_error: None }
    }

    /// Build a success result whose text is the compact JSON of `value`. Not
    /// pretty-printed: the reader is a model, and indentation was ~25% of every
    /// list result's tokens.
    pub fn json<T: Serialize>(value: &T) -> Self {
        Self::text(serde_json::to_string(value).unwrap_or_default())
    }

    pub fn error(message: String) -> Self {
        Self { content: vec![json!({ "type": "text", "text": message })], is_error: Some(true) }
    }

    /// Text of the first block, or its type (`image`, `resource`) for binary ones.
    pub fn first_text(&self) -> &str {
        self.content
            .first()
            .and_then(|c| c["text"].as_str().or_else(|| c["type"].as_str()))
            .unwrap_or_default()
    }
}
