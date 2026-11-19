//! Localhost OAuth callback listeners. A shared listener structure backs the
//! per-provider start commands (Gmail / Microsoft); the providers' registered
//! redirect URIs all point at `http://localhost:<ephemeral>/oauth-callback`.

use serde::Serialize;
use tauri::State;

use super::SyncState;
use crate::sync::error::SyncError;

#[derive(Debug, Serialize)]
pub struct OAuthStartResponse {
    pub state: String,
    pub redirect_uri: String,
}

// Keep the old type alias so existing code that references GmailOAuthStartResponse compiles.
pub type GmailOAuthStartResponse = OAuthStartResponse;

/// Shared helper: spin up one-shot localhost HTTP listeners for OAuth callbacks.
/// Returns (state, redirect_uri). Emits `event_name` with a {code, state}
/// payload on success.
///
/// We bind BOTH `127.0.0.1` and `[::1]` on the same port. The redirect_uri uses
/// the host name `localhost`, which on macOS commonly resolves to the IPv6
/// loopback `::1` first — an IPv4-only listener would then never receive the
/// callback and the flow would silently stall after the user clicks "Allow".
/// Keeping the `localhost` host name (rather than a literal IP) also means the
/// providers' registered redirect URIs don't have to change.
fn start_oauth_listener(
    app: tauri::AppHandle,
    csrf_state: String,
    event_name: &'static str,
    provider_label: &'static str,
) -> Result<OAuthStartResponse, SyncError> {
    use std::net::TcpListener;

    // Bind IPv4 loopback first to obtain an ephemeral port.
    let v4 = TcpListener::bind("127.0.0.1:0")
        .map_err(|e| SyncError::Other(format!("bind listener: {e}")))?;
    let port = v4
        .local_addr()
        .map_err(|e| SyncError::Other(format!("get port: {e}")))?
        .port();

    // Best-effort: also claim the same port on IPv6 loopback. If it's already
    // taken or v6 is unavailable we proceed with v4 only.
    let v6 = TcpListener::bind(("::1", port)).ok();

    let redirect_uri = format!("http://localhost:{port}/oauth-callback");

    // Shared flag so that once any listener captures the code, the other stops.
    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for listener in std::iter::once(v4).chain(v6) {
        let app_handle = app.clone();
        let done = done.clone();
        std::thread::spawn(move || {
            handle_oauth_connections(listener, app_handle, event_name, provider_label, done);
        });
    }

    Ok(OAuthStartResponse {
        state: csrf_state,
        redirect_uri,
    })
}

/// Accept loop for a single OAuth callback listener. Polls non-blocking so it
/// can honour the shared `done` flag (set once any listener captures the code)
/// and an overall 5-minute deadline, instead of blocking forever on `accept`.
fn handle_oauth_connections(
    listener: std::net::TcpListener,
    app: tauri::AppHandle,
    event_name: &'static str,
    provider_label: &'static str,
    done: std::sync::Arc<std::sync::atomic::AtomicBool>,
) {
    use base64::Engine as _;
    use std::io::{Read as _, Write as _};
    use std::sync::atomic::Ordering;

    let _ = listener.set_nonblocking(true);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);

    while !done.load(Ordering::Relaxed) && std::time::Instant::now() < deadline {
        let mut stream = match listener.accept() {
            Ok((s, _)) => s,
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(std::time::Duration::from_millis(100));
                continue;
            }
            Err(_) => break,
        };

        // Handle this connection in blocking mode.
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(30)));

        // Read until we have the full request line (first CRLF). A single
        // fixed read can truncate a long callback URL (code+state) that
        // spans more than one TCP segment, so accumulate, bounded to 64 KB.
        let mut buf = Vec::new();
        let mut chunk = [0u8; 2048];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    if buf.windows(2).any(|w| w == b"\r\n") || buf.len() >= 64 * 1024 {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        if buf.is_empty() {
            continue;
        }
        let request = String::from_utf8_lossy(&buf);
        let first_line = match request.lines().next() {
            Some(l) => l.to_string(),
            None => continue,
        };
        let path = match first_line.split_whitespace().nth(1) {
            Some(p) => p.to_string(),
            None => continue,
        };

        if !path.contains("oauth-callback") {
            let response = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n";
            let _ = stream.write_all(response.as_bytes());
            continue;
        }

        let parsed = match url::Url::parse(&format!("http://localhost{path}")) {
            Ok(u) => u,
            Err(_) => continue,
        };

        let code = parsed.query_pairs().find(|(k, _)| k == "code").map(|(_, v)| v.to_string());
        let state_param = parsed.query_pairs().find(|(k, _)| k == "state").map(|(_, v)| v.to_string());

        // Inline the inbox2 logo as a base64 data URI — no external request, so
        // the page renders in a production build (the previous
        // `http://localhost:4173/logo.png` only resolved against the dev server
        // and was broken when packaged; the envelope SVG that replaced it was
        // generic). The PNG is bundled at compile time via include_bytes!.
        let logo_b64 = base64::engine::general_purpose::STANDARD
            .encode(include_bytes!("../../../assets/logo.png"));
        let logo = format!(
            r##"<img src="data:image/png;base64,{logo_b64}" width="64" height="65" alt="inbox2" style="margin-bottom:8px"/>"##
        );
        let body = if code.is_some() {
            format!("<html><body style='font-family:system-ui;text-align:center;padding:80px;background:#0a0b0f;color:#e0e0e8;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:80vh'>{logo}<h2 style='margin-top:16px'>Connected!</h2><p style='color:#a0a0b0'>You can close this tab and return to inbox2.</p></body></html>")
        } else {
            format!("<html><body style='font-family:system-ui;text-align:center;padding:80px;background:#0a0b0f;color:#e0e0e8;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:80vh'>{logo}<h2 style='margin-top:16px'>Error</h2><p style='color:#a0a0b0'>No authorization code received.</p></body></html>")
        };
        // Include Content-Length so the browser renders immediately instead of
        // waiting on connection close, and drain any unread request bytes before
        // shutting down — closing a socket with data still in the receive buffer
        // makes the OS send an RST rather than a clean FIN, which can leave the
        // tab spinning forever (very visible with Microsoft's ~2.7 KB callback
        // URL, whose request far exceeds what we read to find the code).
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes());
        let _ = stream.flush();
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(200)));
        let mut drain = [0u8; 1024];
        while let Ok(n) = stream.read(&mut drain) {
            if n == 0 {
                break;
            }
        }
        let _ = stream.shutdown(std::net::Shutdown::Both);

        if let Some(code) = code {
            use tauri::Emitter;
            log::info!("[{provider_label}OAuth] Received code, emitting event");
            let payload = serde_json::json!({
                "code": code,
                "state": state_param.unwrap_or_default(),
            });
            let _ = app.emit(event_name, payload);
            done.store(true, Ordering::Relaxed);
            break;
        }
    }
}

/// Start a one-shot localhost HTTP server to catch the Google OAuth callback.
#[tauri::command]
pub async fn start_gmail_oauth(
    app: tauri::AppHandle,
    _state: State<'_, SyncState>,
) -> Result<OAuthStartResponse, SyncError> {
    // CSRF `state` is generated here, threaded to the listener, emitted to the
    // frontend, and compared there on callback (useOAuthFlow.js) — the
    // authoritative check. (No server-side copy is kept; see SyncState.)
    let csrf_state = nanoid::nanoid!(32);
    start_oauth_listener(app, csrf_state, "gmail-oauth-callback", "Gmail")
}

/// Start a one-shot localhost HTTP server to catch the Microsoft OAuth callback.
#[tauri::command]
pub async fn start_microsoft_oauth(
    app: tauri::AppHandle,
    _state: State<'_, SyncState>,
) -> Result<OAuthStartResponse, SyncError> {
    let csrf_state = nanoid::nanoid!(32);
    start_oauth_listener(app, csrf_state, "microsoft-oauth-callback", "Microsoft")
}

/// Candidate fixed ports for Instagram OAuth. Instagram requires an exactly
/// pre-registered redirect URI (no random-port loopback like Google/Microsoft),
/// so the user registers these in their Instagram app's Valid OAuth Redirect URIs
/// and we bind the first free one.
const INSTAGRAM_OAUTH_PORTS: &[u16] = &[8723, 8724, 8725];

/// Like `start_oauth_listener` but binds the first free port from a fixed list
/// (Instagram's redirect URI must match a registered one exactly).
fn start_oauth_listener_fixed(
    app: tauri::AppHandle,
    csrf_state: String,
    event_name: &'static str,
    provider_label: &'static str,
    ports: &[u16],
) -> Result<OAuthStartResponse, SyncError> {
    use std::net::TcpListener;
    let (v4, port) = ports
        .iter()
        .find_map(|&p| TcpListener::bind(("127.0.0.1", p)).ok().map(|l| (l, p)))
        .ok_or_else(|| {
            SyncError::Other(format!(
                "Instagram OAuth: none of the registered ports {ports:?} are free — close whatever is using them and retry"
            ))
        })?;
    let v6 = TcpListener::bind(("::1", port)).ok();
    let redirect_uri = format!("http://localhost:{port}/oauth-callback");

    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for listener in std::iter::once(v4).chain(v6) {
        let app_handle = app.clone();
        let done = done.clone();
        std::thread::spawn(move || {
            handle_oauth_connections(listener, app_handle, event_name, provider_label, done);
        });
    }
    Ok(OAuthStartResponse { state: csrf_state, redirect_uri })
}

/// Instagram-Login OAuth scopes inbox2 requests.
const INSTAGRAM_OAUTH_SCOPE: &str =
    "instagram_business_basic,instagram_business_manage_messages,instagram_business_manage_comments";

/// The HTTPS redirect URI inbox2 registers with Instagram (and reuses on token
/// exchange). Instagram rejects `http://localhost`, so in dev (app base is the
/// local origin) we fall back to the public cloud base (`INBOX2_CLOUD_API_BASE`,
/// default prod api); a real HTTPS app base is used as-is.
async fn instagram_redirect_uri(engine: &crate::sync::engine::SyncEngine) -> String {
    const DEFAULT_CLOUD_API_BASE: &str = "https://api.inbox2.com/api/v1";
    let app_base = engine
        .api_context()
        .read()
        .await
        .as_ref()
        .map(|c| c.api_base.clone())
        .unwrap_or_default();
    let base = if app_base.starts_with("https://") {
        app_base
    } else {
        std::env::var("INBOX2_CLOUD_API_BASE").unwrap_or_else(|_| DEFAULT_CLOUD_API_BASE.to_string())
    };
    format!("{}/oauth/instagram/callback", base.trim_end_matches('/'))
}

#[derive(Debug, Serialize)]
pub struct InstagramOAuthStart {
    pub state: String,
    pub redirect_uri: String,
    pub authorize_url: String,
}

#[derive(Debug, Serialize)]
pub struct InstagramOAuthPreview {
    pub redirect_uri: String,
    pub authorize_url: String,
}

/// Preview the Instagram authorize URL + redirect URI **without** binding a
/// listener or opening a browser — for the dev-mode label so you can see exactly
/// what inbox2 will call and what to register. The real `state`/port are filled
/// in at `start_instagram_oauth`; here they're placeholders.
#[tauri::command]
pub async fn instagram_oauth_preview(
    state: State<'_, SyncState>,
    app_id: String,
) -> Result<InstagramOAuthPreview, SyncError> {
    let redirect_uri = instagram_redirect_uri(&state.engine).await;
    let enc: String = url::form_urlencoded::byte_serialize(redirect_uri.as_bytes()).collect();
    let authorize_url = format!(
        "https://www.instagram.com/oauth/authorize?client_id={app_id}&redirect_uri={enc}&response_type=code&scope={INSTAGRAM_OAUTH_SCOPE}&state=<state>.8723"
    );
    Ok(InstagramOAuthPreview { redirect_uri, authorize_url })
}

/// Begin Instagram-Login OAuth. Instagram requires an exact, pre-registered HTTPS
/// redirect URI, so we register one stable cloud URL (`{api_base}/oauth/instagram/
/// callback`) that 302s the code back to a local loopback port. We bind that port
/// here and carry it in `state` (`<csrf>.<port>`) so the relay knows where to
/// bounce. Emits `instagram-oauth-callback` {code, state:<csrf>} once it lands.
#[tauri::command]
pub async fn start_instagram_oauth(
    app: tauri::AppHandle,
    state: State<'_, SyncState>,
    app_id: String,
) -> Result<InstagramOAuthStart, SyncError> {
    let csrf_state = nanoid::nanoid!(32);
    // Bind the local loopback port that the cloud redirect will bounce back to.
    let resp = start_oauth_listener_fixed(
        app,
        csrf_state.clone(),
        "instagram-oauth-callback",
        "Instagram",
        INSTAGRAM_OAUTH_PORTS,
    )?;
    let port = url::Url::parse(&resp.redirect_uri)
        .ok()
        .and_then(|u| u.port())
        .ok_or_else(|| SyncError::Other("Instagram OAuth: could not determine loopback port".into()))?;

    // The redirect Instagram sees (and the one to register) is the HTTPS cloud URL;
    // the code exchange must reuse this exact value.
    let redirect_uri = instagram_redirect_uri(&state.engine).await;
    let state_param = format!("{csrf_state}.{port}");
    let enc_redirect: String = url::form_urlencoded::byte_serialize(redirect_uri.as_bytes()).collect();
    let authorize_url = format!(
        "https://www.instagram.com/oauth/authorize?client_id={app_id}&redirect_uri={enc_redirect}&response_type=code&scope={INSTAGRAM_OAUTH_SCOPE}&state={state_param}"
    );
    // Log the exact redirect URI to register in the Instagram app (must match
    // character-for-character) + the app id used, to diagnose "Invalid redirect_uri".
    log::info!(
        "[instagram-oauth] register this exact redirect URI: {redirect_uri}  (client_id={app_id}, loopback port {port})"
    );
    Ok(InstagramOAuthStart { state: csrf_state, redirect_uri, authorize_url })
}

/// Finish Instagram-Login OAuth: exchange the code for a long-lived token and
/// create the Instagram account on the Instagram-Login path. Returns the account.
#[tauri::command]
pub async fn complete_instagram_oauth(
    state: State<'_, SyncState>,
    app_id: String,
    app_secret: String,
    code: String,
    redirect_uri: String,
    display_name: Option<String>,
) -> Result<super::accounts::AccountResponse, SyncError> {
    let engine = &state.engine;
    let (token, expires_at) = engine
        .instagram_exchange_code(&app_id, &app_secret, &code, &redirect_uri)
        .await?;
    super::accounts::create_instagram_login_account_on_engine(
        engine, app_id, app_secret, token, expires_at, display_name,
    )
    .await
}
