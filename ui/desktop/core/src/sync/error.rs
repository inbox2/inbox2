use thiserror::Error;

#[derive(Error, Debug)]
pub enum SyncError {
    #[error("IMAP error: {0}")]
    Imap(String),

    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("TLS error: {0}")]
    Tls(#[from] native_tls::Error),

    #[error("Authentication failed: {0}")]
    AuthFailed(String),

    #[error("Provider not connected")]
    NotConnected,

    #[error("Folder not found: {0}")]
    FolderNotFound(String),

    #[error("UIDVALIDITY changed for folder {folder}: expected {expected}, got {actual}")]
    UidValidityChanged {
        folder: String,
        expected: u32,
        actual: u32,
    },

    #[error("Encryption error: {0}")]
    Encryption(String),

    /// Stored credentials exist but will not decrypt with the current master key —
    /// the key file or keystore entry was regenerated or replaced, so the ciphertext
    /// is unrecoverable. Distinct from `Encryption` (a serialize/format fault) and
    /// from `KeychainLocked` (transient, the key is fine): this one can only be
    /// resolved by re-authenticating, so `is_auth` reports it and the account lands
    /// on `NeedsReauth` with a reconnect prompt instead of the channel silently
    /// sitting `Connected` while every sync and write-back fails.
    #[error("Stored credentials could not be decrypted (the credential key changed): {0}")]
    CredentialUnreadable(String),

    /// The OS keystore is temporarily inaccessible — macOS *dark wake* ("In dark
    /// wake, no UI possible" / `errSecInteractionNotAllowed`) during Power Nap or
    /// a maintenance wake, or a locked login keychain. The master key is fine and
    /// the DB is NOT corrupt: the key becomes readable again once the machine is
    /// fully awake / unlocked, so callers must back off and retry rather than
    /// treat this as a fatal open failure.
    #[error("Keychain locked: {0}")]
    KeychainLocked(String),

    #[error("Write conflict: server state changed during write-back")]
    WriteConflict,

    #[error("Capability not supported: {0}")]
    UnsupportedCapability(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Parse error: {0}")]
    Parse(String),

    #[error("Channel closed")]
    ChannelClosed,

    #[error("Provider not implemented: {0}")]
    NotImplemented(String),

    #[error("HTTP error: {0}")]
    Http(String),

    /// HTTP failure carrying the status code, so callers (e.g. the outbox) can
    /// tell a permanent client error (4xx) from a retryable one (5xx/429).
    #[error("HTTP {code}: {context}")]
    HttpStatus { code: u16, context: String },

    #[error("Token refresh failed: {0}")]
    TokenRefresh(String),

    #[error("Provider sync cursor expired; full resync required")]
    CursorExpired,

    #[error("{0}")]
    Other(String),
}

impl SyncError {
    /// Whether retrying is futile. A 4xx client error (bad request, forbidden,
    /// unauthorized) won't fix itself — except 408 Request Timeout and 429 Too
    /// Many Requests, which are inherently retryable. Everything else
    /// (5xx, network, timeouts) is treated as transient.
    ///
    /// Gmail is the exception that proves the rule: it signals per-user
    /// rate limiting with **403** (`rateLimitExceeded` / `userRateLimitExceeded`
    /// / "Quota exceeded"), not 429. A 403 whose body is a quota/rate-limit is
    /// therefore transient, not permanent.
    pub fn is_permanent(&self) -> bool {
        match self {
            SyncError::HttpStatus { code, context } => {
                if *code == 403 && Self::is_rate_limit_body(context) {
                    return false;
                }
                (400..500).contains(code) && *code != 408 && *code != 429
            }
            _ => false,
        }
    }

    /// A Gmail 403 carrying a quota/rate-limit body is throttling, not a dead
    /// credential. Google phrases this several ways across the JSON `reason`
    /// and the human `message`; match any of them, case-insensitively.
    fn is_rate_limit_body(context: &str) -> bool {
        let ctx = context.to_ascii_lowercase();
        ctx.contains("ratelimitexceeded")
            || ctx.contains("userratelimitexceeded")
            || ctx.contains("quotaexceeded")
            || ctx.contains("quota exceeded")
            || ctx.contains("rate limit")
            || ctx.contains("user rate limit")
    }

    /// Whether this failure means the account's credentials are no longer valid
    /// and the user must re-authenticate (vs. a transient network/server blip
    /// that the next sync will recover from). A failed OAuth token refresh, an
    /// outright auth rejection, or a `401/403` from the provider all mean the
    /// stored tokens are dead. Callers use this to flag the account
    /// `NeedsReauth` so the UI can prompt for re-auth.
    pub fn is_auth(&self) -> bool {
        match self {
            // Unreadable ciphertext is as dead as a revoked token — the only way
            // back is to reconnect, so it must reach the UI as NeedsReauth.
            SyncError::TokenRefresh(_)
            | SyncError::AuthFailed(_)
            | SyncError::CredentialUnreadable(_) => true,
            // A 403 is normally a dead/insufficient credential — EXCEPT Gmail's
            // per-user rate limit, which it (mis)reports as 403 with a quota
            // body. That's throttling, not an expired sign-in: the next sync
            // recovers, so it must stay `Error`, never `NeedsReauth`.
            SyncError::HttpStatus { code, context } => {
                *code == 401 || (*code == 403 && !Self::is_rate_limit_body(context))
            }
            _ => false,
        }
    }
}

impl From<imap::Error> for SyncError {
    fn from(e: imap::Error) -> Self {
        SyncError::Imap(e.to_string())
    }
}

impl From<reqwest::Error> for SyncError {
    fn from(e: reqwest::Error) -> Self {
        SyncError::Http(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, SyncError>;

/// The "Retry after 2026-10-13T13:51:39.056Z" deadline Gmail puts in a 429
/// body. It is a lockout: every request before it pushes it further out, so a
/// once-a-minute retry kept tuli.com locked out for five hours (2026-10-13).
/// Read from the persisted `error_message`, so the errored-account poll can
/// sit the window out.
pub fn retry_after_deadline(message: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    let rest = &message[message.find("Retry after ")? + "Retry after ".len()..];
    let end = rest
        .find(|c: char| c.is_whitespace() || c == '"' || c == ',')
        .unwrap_or(rest.len());
    chrono::DateTime::parse_from_rfc3339(&rest[..end])
        .ok()
        .map(|t| t.with_timezone(&chrono::Utc))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_after_deadline_reads_gmail_429_body() {
        let body = "HTTP 429: Gmail: {\n  \"error\": {\n    \"code\": 429,\n    \
                    \"message\": \"User-rate limit exceeded.  Retry after 2026-10-13T13:51:39.056Z\",";
        assert_eq!(
            retry_after_deadline(body).unwrap().to_rfc3339(),
            "2026-10-13T13:51:39.056+00:00"
        );
        assert!(retry_after_deadline("HTTP 403: Quota exceeded per minute").is_none());
        assert!(retry_after_deadline("Retry after soon").is_none());
    }

    #[test]
    fn http_4xx_is_permanent_except_408_and_429() {
        let perm = |c| SyncError::HttpStatus { code: c, context: String::new() }.is_permanent();
        assert!(perm(400)); // bad request (e.g. no recipient)
        assert!(perm(401));
        assert!(perm(403));
        assert!(perm(404));
        assert!(!perm(408)); // request timeout — retryable
        assert!(!perm(429)); // rate limited — retryable
        assert!(!perm(500)); // server error — retryable
        assert!(!perm(503));
    }

    #[test]
    fn gmail_403_quota_is_transient_not_permanent() {
        // Gmail reports per-user rate limiting as 403 with a quota body.
        let quota = SyncError::HttpStatus {
            code: 403,
            context: "Gmail: { \"message\": \"Quota exceeded for quota metric \
                'Queries' and limit 'Queries per minute per user'\" }"
                .into(),
        };
        assert!(!quota.is_permanent(), "a 403 quota body must be retryable");
        assert!(!quota.is_auth(), "a 403 quota body must NOT flag re-auth");

        // A genuine 403 (e.g. insufficient scope) is still permanent + auth.
        let forbidden = SyncError::HttpStatus {
            code: 403,
            context: "insufficientPermissions".into(),
        };
        assert!(forbidden.is_permanent());
        assert!(forbidden.is_auth());
    }

    #[test]
    fn non_http_errors_are_not_permanent() {
        assert!(!SyncError::NotConnected.is_permanent());
        assert!(!SyncError::Http("opaque".into()).is_permanent());
    }

    #[test]
    fn auth_errors_are_detected() {
        assert!(SyncError::TokenRefresh("no refresh token".into()).is_auth());
        assert!(SyncError::AuthFailed("bad password".into()).is_auth());
        // Ciphertext the current master key can't open needs a reconnect, same as a
        // revoked token — but a locked keychain is transient and must NOT prompt.
        assert!(SyncError::CredentialUnreadable("account acc_x".into()).is_auth());
        assert!(!SyncError::KeychainLocked("dark wake".into()).is_auth());
        assert!(SyncError::HttpStatus { code: 401, context: String::new() }.is_auth());
        assert!(SyncError::HttpStatus { code: 403, context: String::new() }.is_auth());
        // Transient/other failures must NOT trip the re-auth prompt.
        assert!(!SyncError::HttpStatus { code: 500, context: String::new() }.is_auth());
        assert!(!SyncError::HttpStatus { code: 429, context: String::new() }.is_auth());
        // Gmail's 403-with-quota-body is throttling, not dead credentials.
        assert!(!SyncError::HttpStatus {
            code: 403,
            context: "Quota exceeded ... Queries per minute per user".into(),
        }
        .is_auth());
        assert!(!SyncError::Http("network down".into()).is_auth());
        assert!(!SyncError::NotConnected.is_auth());
    }
}

impl serde::Serialize for SyncError {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}
