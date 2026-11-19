//! Open-tracking helpers for local channels (docs/Open-Tracking.md).
//!
//! Pure string/URL helpers shared by the engine's inject/poll paths and the FFI
//! read path. The token lives inside the sent message's `body_html` (it IS the
//! pixel URL), so a message row is correlated to its opens by extracting the
//! token back out of its body — no separate id mapping needed.

use crate::sync::store::tracking::OpenRecord;

/// The pixel token for a read secret: the first 24 characters of the secret's
/// SHA-256 in unpadded URL-safe base64. Rails derives the same (Tracking.token_for).
pub fn token_for_secret(secret: &str) -> String {
    use base64::Engine;
    use sha2::{Digest, Sha256};
    let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(secret.as_bytes()));
    encoded[..24].to_string()
}

/// A fresh read secret and the token that goes in the mail. The mail carries only the
/// token, so a recipient can't read the other recipients' opens; the secret stays here.
pub fn gen_secret_token() -> (String, String) {
    let secret = nanoid::nanoid!(32);
    let token = token_for_secret(&secret);
    (secret, token)
}

/// The base URL the pixel is served from, derived from the API base by dropping
/// the `/api/v1` suffix — the pixel route lives at the Rails app root
/// (`/o/:token.gif`) on the same host the client polls, so opens land where we
/// read them.
pub fn pixel_base_from_api(api_base: &str) -> String {
    let trimmed = api_base.trim_end_matches('/');
    trimmed
        .strip_suffix("/api/v1")
        .unwrap_or(trimmed)
        .to_string()
}

/// Append the tracking pixel to an HTML body once (idempotent for this URL).
pub fn inject(html: &str, pixel_url: &str) -> String {
    if html.contains(pixel_url) {
        return html.to_string();
    }
    let tag = format!(
        r#"<img src="{pixel_url}" width="1" height="1" alt="" style="display:none;width:1px;height:1px;border:0" />"#
    );
    match html.to_lowercase().rfind("</body>") {
        Some(idx) => format!("{}{}{}", &html[..idx], tag, &html[idx..]),
        None => format!("{html}{tag}"),
    }
}

/// Extract the tracking token from a sent message's body_html (the `/o/<token>.gif`
/// pixel URL), so the reading pane can look up its opens. None when untracked.
pub fn extract_token(html: &str) -> Option<String> {
    let start = html.find("/o/")? + 3;
    let rest = &html[start..];
    let end = rest.find(".gif")?;
    let token = &rest[..end];
    // Token is a URL-safe nanoid: bail if the slice looks like it captured markup.
    if token.is_empty() || token.contains(['"', '/', '<', '>', ' ']) {
        return None;
    }
    Some(token.to_string())
}

/// Parse the Rails opens payload array for one token into OpenRecords.
pub fn parse_opens(arr: &serde_json::Value) -> Vec<OpenRecord> {
    arr.as_array()
        .map(|items| {
            items
                .iter()
                .map(|o| OpenRecord {
                    opened_at: o.get("opened_at").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    ip: str_field(o, "ip"),
                    geo_country: str_field(o, "geo_country"),
                    geo_city: str_field(o, "geo_city"),
                    proxied: o.get("proxied").and_then(|v| v.as_bool()).unwrap_or(false),
                    proxy_kind: str_field(o, "proxy_kind"),
                    user_agent: str_field(o, "user_agent"),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn str_field(o: &serde_json::Value, key: &str) -> Option<String> {
    o.get(key).and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn injects_before_body_and_is_idempotent() {
        let url = "https://o.inbox2.com/o/abc123.gif";
        let html = "<html><body><p>hi</p></body></html>";
        let out = inject(html, url);
        assert!(out.contains(url));
        assert!(out.contains(r#"<img src="https://o.inbox2.com/o/abc123.gif""#));
        assert!(out.ends_with("</body></html>"));
        assert_eq!(inject(&out, url), out); // idempotent
    }

    #[test]
    fn appends_when_no_body() {
        let out = inject("<p>hi</p>", "https://h/o/t.gif");
        assert!(out.starts_with("<p>hi</p><img"));
    }

    #[test]
    fn roundtrips_the_token() {
        let url = "https://o.inbox2.com/o/Xy_9-Zt.gif";
        let out = inject("<body></body>", url);
        assert_eq!(extract_token(&out).as_deref(), Some("Xy_9-Zt"));
        assert_eq!(extract_token("<p>no pixel</p>"), None);
    }

    #[test]
    fn strips_api_suffix() {
        assert_eq!(pixel_base_from_api("https://api.inbox2.com/api/v1"), "https://api.inbox2.com");
        assert_eq!(pixel_base_from_api("http://localhost:4000/api/v1/"), "http://localhost:4000");
    }
}

#[cfg(test)]
mod secret_token_tests {
    use super::*;

    #[test]
    fn matches_the_rails_derivation() {
        // Same vector as api/spec/requests/api/v1/tracking_opens_spec.rb.
        assert_eq!(token_for_secret("abc-secret-for-the-vector"), "RxoDeNON5B-uEL6OqeMInQdE");
    }

    #[test]
    fn a_new_token_is_the_hash_of_its_secret_and_longer_than_a_legacy_one() {
        let (secret, token) = gen_secret_token();
        assert_eq!(token, token_for_secret(&secret));
        assert_eq!(token.len(), 24);
    }
}
