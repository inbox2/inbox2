//! MCP over Streamable HTTP: one JSON-RPC message per POST; the server answers
//! with `application/json` or a `text/event-stream` carrying the response. The
//! `Mcp-Session-Id` from `initialize` is echoed on every later request.
//!
//! ponytail: the 2024-11-05 HTTP+SSE transport (GET stream + `endpoint` event)
//! is not spoken — every hosted server we target serves Streamable HTTP. Add it
//! when a user brings a server that only has `/sse`.

use futures_util::StreamExt;
use reqwest::header::{ACCEPT, WWW_AUTHENTICATE};
use serde_json::{json, Value};

/// The protocol version we offer in `initialize` (the server may answer older).
pub const PROTOCOL_VERSION: &str = "2025-06-18";

#[derive(Debug)]
pub enum McpError {
    /// HTTP 401. The `WWW-Authenticate` hints drive OAuth discovery.
    Unauthorized(Challenge),
    /// A JSON-RPC error from the server (bad tool arguments etc.) — the
    /// connection itself is fine.
    Rpc(String),
    /// Transport / HTTP failure.
    Other(String),
}

impl std::fmt::Display for McpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            McpError::Unauthorized(_) => write!(f, "the server needs you to sign in"),
            McpError::Rpc(m) | McpError::Other(m) => write!(f, "{m}"),
        }
    }
}

/// What a 401 told us (RFC 9728 `resource_metadata`, and the scope to ask for).
#[derive(Debug, Clone, Default)]
pub struct Challenge {
    pub resource_metadata: Option<String>,
    pub scope: Option<String>,
}

fn header_param(header: &str, name: &str) -> Option<String> {
    let at = header.find(&format!("{name}=\""))? + name.len() + 2;
    let end = header[at..].find('"')?;
    Some(header[at..at + end].to_string())
}

fn challenge_of(resp: &reqwest::Response) -> Challenge {
    let h = resp
        .headers()
        .get(WWW_AUTHENTICATE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    Challenge {
        resource_metadata: header_param(h, "resource_metadata"),
        scope: header_param(h, "scope"),
    }
}

pub struct Session {
    http: reqwest::Client,
    url: String,
    bearer: Option<String>,
    session_id: Option<String>,
    protocol: Option<String>,
    next_id: u64,
}

impl Session {
    /// `initialize` + `notifications/initialized`.
    pub async fn connect(http: &reqwest::Client, url: &str, bearer: Option<&str>) -> Result<Self, McpError> {
        let mut s = Session {
            http: http.clone(),
            url: url.to_string(),
            bearer: bearer.map(str::to_string),
            session_id: None,
            protocol: None,
            next_id: 0,
        };
        let init = s
            .request(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": { "name": "inbox2", "version": env!("CARGO_PKG_VERSION") },
                }),
            )
            .await?;
        s.protocol = Some(
            init.get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or(PROTOCOL_VERSION)
                .to_string(),
        );
        s.post(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }), None)
            .await?;
        Ok(s)
    }

    pub async fn request(&mut self, method: &str, params: Value) -> Result<Value, McpError> {
        self.next_id += 1;
        let id = self.next_id;
        let body = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        let msg = self
            .post(&body, Some(id))
            .await?
            .ok_or_else(|| McpError::Other(format!("{method}: no response")))?;
        if let Some(err) = msg.get("error") {
            let m = err.get("message").and_then(Value::as_str).unwrap_or("error");
            return Err(McpError::Rpc(format!("{method}: {m}")));
        }
        Ok(msg.get("result").cloned().unwrap_or(Value::Null))
    }

    async fn post(&mut self, body: &Value, id: Option<u64>) -> Result<Option<Value>, McpError> {
        let mut req = self
            .http
            .post(&self.url)
            .header(ACCEPT, "application/json, text/event-stream")
            .json(body);
        if let Some(b) = &self.bearer {
            req = req.bearer_auth(b);
        }
        if let Some(s) = &self.session_id {
            req = req.header("Mcp-Session-Id", s);
        }
        if let Some(p) = &self.protocol {
            req = req.header("MCP-Protocol-Version", p);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| McpError::Other(format!("could not reach the server: {e}")))?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(McpError::Unauthorized(challenge_of(&resp)));
        }
        if let Some(sid) = resp.headers().get("mcp-session-id").and_then(|v| v.to_str().ok()) {
            self.session_id = Some(sid.to_string());
        }
        if !status.is_success() {
            let text: String = resp.text().await.unwrap_or_default().chars().take(300).collect();
            return Err(McpError::Other(format!("HTTP {status}: {text}")));
        }
        let Some(id) = id else { return Ok(None) };
        let sse = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|c| c.starts_with("text/event-stream"));
        if sse {
            return read_sse(resp, id).await.map(Some);
        }
        let v: Value = resp
            .json()
            .await
            .map_err(|e| McpError::Other(format!("invalid response: {e}")))?;
        // A server may answer with a batch array.
        Ok(match v {
            Value::Array(items) => items.into_iter().find(|m| m.get("id").and_then(Value::as_u64) == Some(id)),
            other => Some(other),
        })
    }
}

/// Read SSE events until the one answering `id` arrives (servers may send
/// notifications first). Stops there rather than waiting for the stream to close.
async fn read_sse(resp: reqwest::Response, id: u64) -> Result<Value, McpError> {
    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| McpError::Other(format!("stream: {e}")))?;
        // '\r' never occurs inside a UTF-8 multibyte sequence, so dropping it
        // normalises CRLF framing safely.
        buf.extend(chunk.iter().filter(|b| **b != b'\r'));
        while let Some(end) = buf.windows(2).position(|w| w == b"\n\n") {
            let event: Vec<u8> = buf.drain(..end + 2).collect();
            let event = String::from_utf8_lossy(&event);
            let data: Vec<&str> = event
                .lines()
                .filter_map(|l| l.strip_prefix("data:"))
                .map(str::trim_start)
                .collect();
            if data.is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<Value>(&data.join("\n")) {
                if v.get("id").and_then(Value::as_u64) == Some(id) {
                    return Ok(v);
                }
            }
        }
    }
    Err(McpError::Other("the server closed the stream without answering".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_www_authenticate() {
        let h = r#"Bearer realm="OAuth", resource_metadata="https://x/.well-known/oauth-protected-resource/mcp", scope="read write""#;
        assert_eq!(
            header_param(h, "resource_metadata").as_deref(),
            Some("https://x/.well-known/oauth-protected-resource/mcp")
        );
        assert_eq!(header_param(h, "scope").as_deref(), Some("read write"));
        assert_eq!(header_param(h, "nope"), None);
    }
}
