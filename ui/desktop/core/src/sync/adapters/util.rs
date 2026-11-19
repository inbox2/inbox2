//! Small helpers shared across the mail provider adapters.

use serde_json::Value;

use crate::sync::error::{Result, SyncError};

/// Turn an HTTP response into parsed JSON, with shared status/error handling.
///
/// The Gmail and Microsoft `get_json` helpers had byte-identical bodies apart
/// from a provider-specific way to map certain statuses/bodies to a typed
/// `SyncError` (Gmail: 404 → `Http("404")`; Graph: 410/`syncStateNotFound` →
/// `CursorExpired`). `classify` expresses just that difference:
///
/// - called once with `body = None` *before* the body is consumed, so a
///   status-only mapping (e.g. `GONE`) can short-circuit; then
/// - called again with `Some(body)` on any non-success status, so a
///   body-content mapping can apply before the generic error is built.
///
/// Returning `None` from both passes falls through to a bounded
/// `http_status_error`. Exercised end-to-end by the adapters' wiremock tests.
pub(crate) async fn parse_json_response(
    provider: &str,
    resp: reqwest::Response,
    classify: impl Fn(reqwest::StatusCode, Option<&str>) -> Option<SyncError>,
) -> Result<Value> {
    let status = resp.status();
    if let Some(err) = classify(status, None) {
        return Err(err);
    }
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        if let Some(err) = classify(status, Some(&body)) {
            return Err(err);
        }
        return Err(http_status_error(provider, status, &body));
    }
    resp.json::<Value>().await.map_err(Into::into)
}

/// Format a non-success HTTP response into a `SyncError::HttpStatus`, bounding
/// the echoed body so a huge error page can't bloat the log/error. Used by the
/// Gmail and Microsoft `get_json` helpers for the generic (non-special-cased)
/// failure arm.
///
/// Carrying the numeric status code (rather than a bare `Http(String)`) is what
/// lets callers distinguish a dead-credentials `401/403` (→ `NeedsReauth`) from
/// a transient `5xx`/`429` (→ retry). Collapsing every status into an opaque
/// string would force the connect path to guess, which is how transient blips
/// used to masquerade as expired sign-ins.
pub(crate) fn http_status_error(provider: &str, status: reqwest::StatusCode, body: &str) -> SyncError {
    SyncError::HttpStatus {
        code: status.as_u16(),
        context: format!("{provider}: {}", truncate(body, 200)),
    }
}

/// Decode an RFC 2047 encoded-word header value (e.g. `=?UTF-8?B?...?=`) to
/// plain text. Gmail/Microsoft return raw header strings from their JSON APIs
/// with no decoding, so encoded subjects/display-names would otherwise be stored
/// as mojibake. Reuses `mailparse`'s decoder (the same one the IMAP path uses
/// via `MailHeader::get_value`). Falls back to the input on any parse error.
pub(crate) fn decode_rfc2047(value: &str) -> String {
    // Fast path: no encoded-word marker → nothing to decode.
    if !value.contains("=?") {
        return value.to_string();
    }
    // Wrap the bare value in a synthetic header line so we can reuse mailparse's
    // encoded-word decoding. Strip CR/LF first so the value can't terminate the
    // synthetic header early.
    let line = format!("Subject: {}", value.replace(['\r', '\n'], " "));
    mailparse::parse_header(line.as_bytes())
        .map(|(h, _)| h.get_value())
        .unwrap_or_else(|_| value.to_string())
}

/// Lowercase a string and replace every non-alphanumeric ASCII character with
/// `_`, yielding a stable identifier-safe token. Used to derive local label/tag
/// keys from provider-side label/category names.
pub(crate) fn sanitize(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

/// Truncate to at most `n` characters (not bytes), preserving UTF-8 boundaries.
/// Used to bound error-body text included in `SyncError` messages.
pub(crate) fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_lowercases_and_replaces_non_alnum() {
        assert_eq!(sanitize("INBOX/Work-2024"), "inbox_work_2024");
        assert_eq!(sanitize("a.b c"), "a_b_c");
        assert_eq!(sanitize(""), "");
    }

    #[test]
    fn truncate_counts_chars_not_bytes() {
        assert_eq!(truncate("hello", 3), "hel");
        assert_eq!(truncate("hi", 10), "hi");
        // Multi-byte chars must not be split mid-codepoint.
        assert_eq!(truncate("héllo", 2), "hé");
    }

    #[test]
    fn http_status_error_preserves_code_for_auth_classification() {
        use reqwest::StatusCode;
        // A 401/403 must carry its code so the engine flags the account
        // NeedsReauth — the whole point of the bug fix.
        let unauth = http_status_error("Gmail", StatusCode::UNAUTHORIZED, "bad token");
        assert!(matches!(unauth, SyncError::HttpStatus { code: 401, .. }));
        assert!(unauth.is_auth());
        assert!(http_status_error("Graph", StatusCode::FORBIDDEN, "").is_auth());
        // A transient 5xx/429 must NOT look like an expired sign-in.
        assert!(!http_status_error("Gmail", StatusCode::INTERNAL_SERVER_ERROR, "").is_auth());
        assert!(!http_status_error("Graph", StatusCode::TOO_MANY_REQUESTS, "").is_auth());
        // Body is still echoed (bounded) in the context for diagnostics.
        if let SyncError::HttpStatus { context, .. } = http_status_error("Gmail", StatusCode::UNAUTHORIZED, "bad token") {
            assert!(context.contains("Gmail"));
            assert!(context.contains("bad token"));
        } else {
            panic!("expected HttpStatus");
        }
    }

    #[test]
    fn decode_rfc2047_handles_encoded_words_and_plain() {
        // Plain ASCII passes through untouched (fast path).
        assert_eq!(decode_rfc2047("Hello world"), "Hello world");
        // Base64 UTF-8 encoded-word.
        assert_eq!(decode_rfc2047("=?UTF-8?B?SGVsbG8gd29ybGQ=?="), "Hello world");
        // Quoted-printable encoded-word with a non-ASCII char.
        assert_eq!(decode_rfc2047("=?UTF-8?Q?caf=C3=A9?="), "café");
        // Malformed encoded-word falls back to the raw input rather than erroring.
        let malformed = "=?bogus";
        assert_eq!(decode_rfc2047(malformed), malformed);
    }
}
