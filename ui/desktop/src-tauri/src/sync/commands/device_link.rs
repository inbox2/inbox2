//! Desktop side of the "link this device to your inbox2 account" flow — the
//! OAuth-style loopback + PKCE dance the webview kicks off via
//! `startDesktopDeviceLink()` (see `ui/web/src/lib/deviceLink.js`).
//!
//! The whole loopback exchange happens in Rust so the system browser (not the
//! in-app webview, whose origin is a custom protocol a raw HTTP client can't
//! reach) approves the request and 302s back to a `127.0.0.1` listener we own:
//!
//!   1. Generate PKCE (`code_verifier`/`code_challenge`) + a CSRF `state`.
//!   2. Bind an ephemeral loopback HTTP listener; `redirect_uri` points at it.
//!   3. Open the browser to the web `/link` approval page with those params.
//!   4. Catch the `/cb?code=…&state=…` redirect, verify `state`, ack the tab.
//!   5. POST the code (+ verifier) to the Rails token endpoint → `ink_…` key.
//!   6. Adopt the minted bearer into the engine so cloud push arms immediately.
//!
//! A `~180s` deadline bounds the whole flow; on timeout the listener is dropped
//! (freeing the port) and an error is returned.

use serde::Serialize;
use tauri::State;

use super::SyncState;
use crate::sync::error::SyncError;

/// Platform tag sent to the approval page (mirrors `PLATFORM_DESKTOP` in
/// `deviceLink.js`).
const PLATFORM_DESKTOP: &str = "desktop";
/// PKCE challenge method — we always use SHA-256.
const PKCE_METHOD_S256: &str = "S256";
/// Loopback callback path the browser is redirected back to.
const CALLBACK_PATH: &str = "/cb";
/// Rails endpoint (relative to `api_base`) that exchanges the code for a token.
const TOKEN_ENDPOINT: &str = "/auth/device-link/token";
/// HTTP status the token endpoint returns on a successful mint.
const HTTP_CREATED: u16 = 201;
/// Overall deadline for the user to approve + the code to come back.
const LINK_FLOW_TIMEOUT_SECS: u64 = 180;
/// Fallback device label when none is supplied and the hostname is unavailable.
const DEFAULT_DEVICE_NAME: &str = "Desktop";

#[derive(Debug, Serialize)]
pub struct DeviceLinkResult {
    /// The minted `ink_…` bearer the webview persists + uses for API calls.
    pub token: String,
}

/// Run the full device-link flow: bind the loopback, open the browser, exchange
/// the approved code for an `ink_…` key, and adopt it into the engine.
///
/// Tauri maps the JS `{ linkUrl, apiBase, deviceName }` to these snake_case
/// params. `device_name` defaults to the machine hostname when empty.
#[tauri::command]
pub async fn start_device_link(
    app: tauri::AppHandle,
    state: State<'_, SyncState>,
    link_url: String,
    api_base: String,
    device_name: String,
) -> Result<DeviceLinkResult, SyncError> {
    let device_name = if device_name.trim().is_empty() {
        machine_hostname()
    } else {
        device_name
    };

    // 1. PKCE + CSRF state.
    let code_verifier = generate_code_verifier();
    let code_challenge = pkce_challenge(&code_verifier);
    let csrf_state = nanoid::nanoid!(32);

    // 2. Bind an ephemeral loopback listener for the approval redirect.
    let server = tiny_http::Server::http("127.0.0.1:0")
        .map_err(|e| SyncError::Other(format!("device link: bind loopback: {e}")))?;
    let port = server
        .server_addr()
        .to_ip()
        .map(|a| a.port())
        .ok_or_else(|| SyncError::Other("device link: no loopback port".into()))?;
    let redirect_uri = format!("http://127.0.0.1:{port}{CALLBACK_PATH}");

    // 3. Open the system browser to the web approval page.
    let approval_url = build_approval_url(
        &link_url,
        &device_name,
        &redirect_uri,
        &csrf_state,
        &code_challenge,
    );
    open_in_browser(&app, &approval_url)?;

    // 4 + 5. Wait for the callback, verify state, ack the tab, exchange the code.
    // The listener loop blocks, so run it (and the exchange) off the async pool.
    // `api_base` is still needed afterwards (as the adopt fallback), so clone it;
    // the rest move into the closure.
    let exchange_base = api_base.clone();
    let token: String = tokio::task::spawn_blocking(move || {
        let code = wait_for_callback(
            server,
            &csrf_state,
            LINK_FLOW_TIMEOUT_SECS,
            "Device linked — you can return to the app.",
        )?;
        exchange_code(&exchange_base, &code, &code_verifier, &redirect_uri)
    })
    .await
    .map_err(|e| SyncError::Other(format!("device link: task join: {e}")))?
    .map_err(SyncError::Other)?;

    // 6. Adopt the bearer so cloud push arms immediately. Reuse the engine's
    // CURRENT api_base (the app/proxy origin sync-manager uses) if one is set;
    // only fall back to the public exchange base when none exists. Idempotent —
    // the webview also calls `set_api_context` as a backstop.
    let adopt_base = state
        .engine
        .api_context()
        .read()
        .await
        .as_ref()
        .map(|c| c.api_base.clone())
        .filter(|b| !b.is_empty())
        .unwrap_or(api_base);
    state
        .engine
        .set_api_context(adopt_base.clone(), token.clone())
        .await;
    // Client mode: forward to the host engine that runs the sync loop + cloud
    // push (mirrors `secrets::set_api_context`). Best-effort.
    if let Some(bus) = &state.bus {
        let _ = bus.call(
            "set_api_context",
            serde_json::json!({ "api_base": adopt_base, "rails_jwt": token }),
        );
    }

    Ok(DeviceLinkResult { token })
}

/// 64 random bytes, base64url-encoded without padding (RFC 7636 verifier).
fn generate_code_verifier() -> String {
    use base64::Engine as _;
    use rand::RngCore as _;
    let mut bytes = [0u8; 64];
    rand::thread_rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// `base64url(SHA256(verifier))` without padding (PKCE S256 challenge).
fn pkce_challenge(verifier: &str) -> String {
    use base64::Engine as _;
    use sha2::{Digest as _, Sha256};
    let digest = Sha256::digest(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

/// Best-effort machine hostname for the default device label.
fn machine_hostname() -> String {
    hostname::get()
        .ok()
        .and_then(|h| h.into_string().ok())
        .filter(|h| !h.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_DEVICE_NAME.to_string())
}

/// Assemble the browser approval URL with all link params url-encoded.
fn build_approval_url(
    link_url: &str,
    device_name: &str,
    redirect_uri: &str,
    csrf_state: &str,
    code_challenge: &str,
) -> String {
    let enc = |s: &str| -> String { url::form_urlencoded::byte_serialize(s.as_bytes()).collect() };
    format!(
        "{link_url}?device_name={dn}&platform={PLATFORM_DESKTOP}&redirect_uri={ru}&state={st}&code_challenge={cc}&code_challenge_method={PKCE_METHOD_S256}",
        dn = enc(device_name),
        ru = enc(redirect_uri),
        st = enc(csrf_state),
        // base64url is already URL-safe, so the challenge needs no encoding.
        cc = code_challenge,
    )
}

/// Open `url` in the OS default browser via the opener plugin (cross-platform).
pub(crate) fn open_in_browser(app: &tauri::AppHandle, url: &str) -> Result<(), SyncError> {
    use tauri_plugin_opener::OpenerExt;
    app.opener()
        .open_url(url.to_string(), None::<&str>)
        .map_err(|e| SyncError::Other(format!("open browser: {e}")))
}

/// Block on the loopback listener until the `/cb` redirect arrives (or the
/// deadline lapses), verify the echoed `state`, ack the browser tab, and return
/// the one-time code. The `server` is dropped on return, freeing the port.
/// Shared with the MCP client's OAuth sign-in (`crate::mcp_client`).
pub(crate) fn wait_for_callback(
    server: tiny_http::Server,
    expected_state: &str,
    timeout_secs: u64,
    ok_message: &str,
) -> Result<String, String> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);

    loop {
        let now = std::time::Instant::now();
        if now >= deadline {
            return Err("timed out waiting for approval in the browser".into());
        }
        let request = match server.recv_timeout(deadline - now) {
            Ok(Some(req)) => req,
            Ok(None) => return Err("timed out waiting for approval in the browser".into()),
            Err(e) => return Err(format!("loopback listener error: {e}")),
        };

        // tiny_http gives us "/cb?code=…&state=…"; parse against a dummy base.
        let parsed = match url::Url::parse(&format!("http://127.0.0.1{}", request.url())) {
            Ok(u) => u,
            Err(_) => {
                let _ = request.respond(html_response(404, "Bad request."));
                continue;
            }
        };
        if parsed.path() != CALLBACK_PATH {
            let _ = request.respond(html_response(404, "Not found."));
            continue;
        }

        let code = parsed
            .query_pairs()
            .find(|(k, _)| k == "code")
            .map(|(_, v)| v.into_owned());
        let state = parsed
            .query_pairs()
            .find(|(k, _)| k == "state")
            .map(|(_, v)| v.into_owned())
            .unwrap_or_default();

        // CSRF: the echoed state must match the one we sent.
        if state != expected_state {
            let _ = request.respond(html_response(400, "State mismatch — please retry."));
            return Err("sign-in state mismatch".into());
        }
        let code = match code {
            Some(c) if !c.is_empty() => c,
            _ => {
                let _ = request.respond(html_response(400, "No authorization code received."));
                return Err("no authorization code in the callback".into());
            }
        };

        let _ = request.respond(html_response(200, ok_message));
        return Ok(code);
    }
}

/// A tiny styled HTML acknowledgement page for the browser tab.
fn html_response(status: u16, message: &str) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    let body = format!(
        "<html><body style='font-family:system-ui;text-align:center;padding:80px;background:#0a0b0f;color:#e0e0e8'>\
         <h2>inbox2</h2><p style='color:#a0a0b0'>{message}</p></body></html>"
    );
    let header = tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"text/html; charset=utf-8"[..])
        .expect("static header");
    tiny_http::Response::from_string(body)
        .with_status_code(status)
        .with_header(header)
}

/// POST the approved code to the Rails token endpoint and parse the minted key.
/// The exchange hits the PUBLIC api base (no auth header) per the protocol.
fn exchange_code(
    api_base: &str,
    code: &str,
    code_verifier: &str,
    redirect_uri: &str,
) -> Result<String, String> {
    let token_url = format!("{}{TOKEN_ENDPOINT}", api_base.trim_end_matches('/'));
    let resp = reqwest::blocking::Client::new()
        .post(&token_url)
        .json(&serde_json::json!({
            "code": code,
            "code_verifier": code_verifier,
            "redirect_uri": redirect_uri,
        }))
        .send()
        .map_err(|e| format!("device link: token request failed: {e}"))?;

    let status = resp.status();
    let body: serde_json::Value = resp
        .json()
        .map_err(|e| format!("device link: invalid token response: {e}"))?;

    if status.as_u16() != HTTP_CREATED {
        let detail = body
            .get("error")
            .and_then(|v| v.as_str())
            .or_else(|| body.get("message").and_then(|v| v.as_str()))
            .unwrap_or("token exchange rejected");
        return Err(format!("device link failed ({status}): {detail}"));
    }

    body.get("token")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| "device link: token missing in response".to_string())
}
