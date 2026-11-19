//! OAuth 2.1 for remote MCP servers (MCP authorization spec): protected-resource
//! metadata (RFC 9728) → authorization-server metadata (RFC 8414 / OIDC) →
//! dynamic client registration (RFC 7591) → authorization code + PKCE (S256)
//! with the `resource` indicator (RFC 8707) → refresh.
//!
//! The host owns the loopback listener and the browser: it binds a port, calls
//! [`begin`] with that redirect URI, opens `authorize_url`, waits for the code
//! (checking `state`), and hands it to [`finish`].

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::rpc::Challenge;

/// What is stored (encrypted, in `app_secrets`) per connection.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Credential {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    /// Unix seconds.
    #[serde(default)]
    pub expires_at: Option<i64>,
    #[serde(default)]
    pub token_endpoint: Option<String>,
    #[serde(default)]
    pub client_id: Option<String>,
    #[serde(default)]
    pub client_secret: Option<String>,
    #[serde(default)]
    pub resource: Option<String>,
    /// True when `client_id` came from dynamic registration (re-register on
    /// the next sign-in, since the loopback port changes); false when the person
    /// supplied it (reuse it).
    #[serde(default)]
    pub registered_client: bool,
}

impl Credential {
    pub fn bearer(token: &str) -> Self {
        Credential { access_token: token.to_string(), ..Default::default() }
    }

    /// Expired or within a minute of it.
    pub fn expired(&self) -> bool {
        self.expires_at.is_some_and(|t| t <= chrono::Utc::now().timestamp() + 60)
    }

    pub fn can_refresh(&self) -> bool {
        self.refresh_token.is_some() && self.token_endpoint.is_some() && self.client_id.is_some()
    }
}

/// An authorization in flight, between [`begin`] and [`finish`].
#[derive(Debug, Clone)]
pub struct PendingAuth {
    pub authorize_url: String,
    pub state: String,
    verifier: String,
    redirect_uri: String,
    token_endpoint: String,
    client_id: String,
    client_secret: Option<String>,
    resource: String,
    registered: bool,
}

pub fn code_verifier() -> String {
    use base64::Engine as _;
    use rand::RngCore as _;
    let mut bytes = [0u8; 48];
    rand::thread_rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub fn pkce_challenge(verifier: &str) -> String {
    use base64::Engine as _;
    use sha2::{Digest as _, Sha256};
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

async fn get_json(http: &reqwest::Client, url: &str) -> Option<Value> {
    let resp = http.get(url).header("Accept", "application/json").send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.json().await.ok()
}

/// `https://host/a/b` → (`https://host`, `/a/b`), path without a trailing slash.
fn split(url: &str) -> Result<(String, String), String> {
    let u = url::Url::parse(url).map_err(|e| format!("bad URL {url}: {e}"))?;
    Ok((u.origin().ascii_serialization(), u.path().trim_end_matches('/').to_string()))
}

struct AsMeta {
    authorize: String,
    token: String,
    register: Option<String>,
}

async fn discover(http: &reqwest::Client, server_url: &str, ch: &Challenge) -> Result<(AsMeta, String, Option<String>), String> {
    let (origin, path) = split(server_url)?;

    // 1. Protected-resource metadata: the 401's pointer, else the well-known
    //    location with the path inserted, else at the root.
    let mut candidates = Vec::new();
    if let Some(u) = &ch.resource_metadata {
        candidates.push(u.clone());
    }
    if !path.is_empty() {
        candidates.push(format!("{origin}/.well-known/oauth-protected-resource{path}"));
    }
    candidates.push(format!("{origin}/.well-known/oauth-protected-resource"));
    let mut prm = None;
    for c in candidates {
        if let Some(v) = get_json(http, &c).await {
            prm = Some(v);
            break;
        }
    }

    let issuer = prm
        .as_ref()
        .and_then(|v| v.get("authorization_servers")?.get(0)?.as_str().map(str::to_string))
        .unwrap_or_else(|| origin.clone());
    let resource = prm
        .as_ref()
        .and_then(|v| v.get("resource")?.as_str().map(str::to_string))
        .unwrap_or_else(|| server_url.to_string());
    let scope = ch.scope.clone().or_else(|| {
        let scopes: Vec<&str> = prm
            .as_ref()?
            .get("scopes_supported")?
            .as_array()?
            .iter()
            .filter_map(Value::as_str)
            .collect();
        (!scopes.is_empty()).then(|| scopes.join(" "))
    });

    // 2. Authorization-server metadata (RFC 8414, then OIDC, path-aware).
    let (as_origin, as_path) = split(&issuer)?;
    let mut urls = vec![
        format!("{as_origin}/.well-known/oauth-authorization-server{as_path}"),
        format!("{as_origin}/.well-known/openid-configuration{as_path}"),
    ];
    if !as_path.is_empty() {
        urls.push(format!("{as_origin}{as_path}/.well-known/openid-configuration"));
    }
    let mut meta = None;
    for u in urls {
        if let Some(v) = get_json(http, &u).await {
            meta = Some(v);
            break;
        }
    }
    let field = |k: &str| meta.as_ref().and_then(|m| m.get(k)?.as_str().map(str::to_string));
    // 2025-03-26 servers without metadata: default endpoints at the origin.
    let am = AsMeta {
        authorize: field("authorization_endpoint").unwrap_or_else(|| format!("{as_origin}/authorize")),
        token: field("token_endpoint").unwrap_or_else(|| format!("{as_origin}/token")),
        register: field("registration_endpoint")
            .or_else(|| meta.is_none().then(|| format!("{as_origin}/register"))),
    };
    Ok((am, resource, scope))
}

/// Discover, register (unless `client` is given), and build the authorize URL.
pub async fn begin(
    http: &reqwest::Client,
    server_url: &str,
    challenge: &Challenge,
    redirect_uri: &str,
    client: Option<(String, Option<String>)>,
) -> Result<PendingAuth, String> {
    let (am, resource, scope) = discover(http, server_url, challenge).await?;

    let registered = client.is_none();
    let (client_id, client_secret) = match client {
        Some(c) => c,
        None => {
            let reg = am.register.as_deref().ok_or(
                "This server does not let apps register themselves. Paste an access token, \
                 or the client ID of an OAuth app you created there.",
            )?;
            let resp = http
                .post(reg)
                .json(&serde_json::json!({
                    "client_name": "inbox2",
                    "redirect_uris": [redirect_uri],
                    "grant_types": ["authorization_code", "refresh_token"],
                    "response_types": ["code"],
                    "token_endpoint_auth_method": "none",
                }))
                .send()
                .await
                .map_err(|e| format!("client registration failed: {e}"))?;
            let status = resp.status();
            let v: Value = resp.json().await.unwrap_or(Value::Null);
            let id = v
                .get("client_id")
                .and_then(Value::as_str)
                .ok_or_else(|| format!("client registration failed ({status})"))?;
            (id.to_string(), v.get("client_secret").and_then(Value::as_str).map(str::to_string))
        }
    };

    let verifier = code_verifier();
    let state = nanoid::nanoid!(32);
    let mut url = url::Url::parse(&am.authorize).map_err(|e| format!("bad authorize URL: {e}"))?;
    {
        let mut q = url.query_pairs_mut();
        q.append_pair("response_type", "code")
            .append_pair("client_id", &client_id)
            .append_pair("redirect_uri", redirect_uri)
            .append_pair("code_challenge", &pkce_challenge(&verifier))
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", &state)
            .append_pair("resource", &resource);
        if let Some(s) = &scope {
            q.append_pair("scope", s);
        }
    }
    Ok(PendingAuth {
        authorize_url: url.to_string(),
        state,
        verifier,
        redirect_uri: redirect_uri.to_string(),
        token_endpoint: am.token,
        client_id,
        client_secret,
        resource,
        registered,
    })
}

async fn token_request(http: &reqwest::Client, endpoint: &str, form: &[(&str, &str)]) -> Result<Value, String> {
    let resp = http
        .post(endpoint)
        .header("Accept", "application/json")
        .form(form)
        .send()
        .await
        .map_err(|e| format!("token request failed: {e}"))?;
    let status = resp.status();
    let v: Value = resp.json().await.unwrap_or(Value::Null);
    if !status.is_success() || v.get("access_token").is_none() {
        let why = v
            .get("error_description")
            .or_else(|| v.get("error"))
            .and_then(Value::as_str)
            .unwrap_or("rejected");
        return Err(format!("token request failed ({status}): {why}"));
    }
    Ok(v)
}

fn apply(mut c: Credential, v: &Value) -> Credential {
    c.access_token = v["access_token"].as_str().unwrap_or_default().to_string();
    // Providers that rotate refresh tokens send a new one; others omit it.
    if let Some(r) = v.get("refresh_token").and_then(Value::as_str) {
        c.refresh_token = Some(r.to_string());
    }
    c.expires_at = v
        .get("expires_in")
        .and_then(Value::as_i64)
        .map(|s| chrono::Utc::now().timestamp() + s);
    c
}

pub async fn finish(http: &reqwest::Client, p: PendingAuth, code: &str) -> Result<Credential, String> {
    let mut form = vec![
        ("grant_type", "authorization_code"),
        ("code", code),
        ("redirect_uri", p.redirect_uri.as_str()),
        ("client_id", p.client_id.as_str()),
        ("code_verifier", p.verifier.as_str()),
        ("resource", p.resource.as_str()),
    ];
    if let Some(s) = &p.client_secret {
        form.push(("client_secret", s));
    }
    let v = token_request(http, &p.token_endpoint, &form).await?;
    Ok(apply(
        Credential {
            token_endpoint: Some(p.token_endpoint.clone()),
            client_id: Some(p.client_id.clone()),
            client_secret: p.client_secret.clone(),
            resource: Some(p.resource.clone()),
            registered_client: p.registered,
            ..Default::default()
        },
        &v,
    ))
}

pub async fn refresh(http: &reqwest::Client, c: &Credential) -> Result<Credential, String> {
    let (Some(rt), Some(te), Some(cid)) = (&c.refresh_token, &c.token_endpoint, &c.client_id) else {
        return Err("no refresh token".into());
    };
    let mut form = vec![("grant_type", "refresh_token"), ("refresh_token", rt.as_str()), ("client_id", cid.as_str())];
    if let Some(r) = &c.resource {
        form.push(("resource", r));
    }
    if let Some(s) = &c.client_secret {
        form.push(("client_secret", s));
    }
    let v = token_request(http, te, &form).await?;
    Ok(apply(c.clone(), &v))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_matches_rfc7636_vector() {
        assert_eq!(
            pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }
}
