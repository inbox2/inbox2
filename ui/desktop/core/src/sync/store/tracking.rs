//! `SyncStore` — open-tracking local state (docs/Open-Tracking.md).
//!
//! Per-account opt-in on `external_accounts`, the `tracked_tokens` embedded in
//! sent mail, and the `message_opens` synced back from the Rails opens poll.

use super::*;

/// Per-channel open-tracking settings.
#[derive(Debug, Clone, Default)]
pub struct OpenTrackingSettings {
    pub enabled: bool,
    pub track_domain: Option<String>,
}

/// One recorded open (who/when/where), for the reading pane's open history.
#[derive(Debug, Clone, serde::Serialize)]
pub struct OpenRecord {
    pub opened_at: String,
    pub ip: Option<String>,
    pub geo_country: Option<String>,
    pub geo_city: Option<String>,
    pub proxied: bool,
    pub proxy_kind: Option<String>,
    pub user_agent: Option<String>,
}

impl SyncStore {
    pub fn set_open_tracking(
        &self,
        account_key: &str,
        enabled: bool,
        track_domain: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE external_accounts SET open_tracking_enabled = ?2, track_domain = ?3 WHERE key = ?1",
            params![account_key, enabled as i32, track_domain],
        )?;
        Ok(())
    }

    pub fn open_tracking_settings(&self, account_key: &str) -> Result<OpenTrackingSettings> {
        let conn = self.conn.lock();
        let row: Option<(i32, Option<String>)> = conn
            .query_row(
                "SELECT open_tracking_enabled, track_domain FROM external_accounts WHERE key = ?1",
                params![account_key],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        Ok(row
            .map(|(e, d)| OpenTrackingSettings {
                enabled: e != 0,
                track_domain: d.filter(|s| !s.is_empty()),
            })
            .unwrap_or_default())
    }

    /// Distinct custom tracking hosts across tracking-enabled channels — the
    /// hosts whose CF-for-SaaS TLS the poll loop provisions.
    pub fn custom_track_domains(&self) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT DISTINCT track_domain FROM external_accounts \
             WHERE open_tracking_enabled = 1 AND track_domain IS NOT NULL AND track_domain != ''",
        )?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn record_tracked_token(&self, token: &str, account_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT OR IGNORE INTO tracked_tokens (token, account_key, created_at) \
             VALUES (?1, ?2, ?3)",
            params![token, account_key, Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    /// Keep the read secret behind a new pixel token, on this device only.
    pub fn record_tracked_secret(&self, token: &str, secret: &str) -> Result<()> {
        self.conn.lock().execute(
            "INSERT OR IGNORE INTO tracked_token_secrets (token, secret) VALUES (?1, ?2)",
            params![token, secret],
        )?;
        Ok(())
    }

    /// What to poll with, newest sends first: (tokens from before read secrets, secrets).
    pub fn tracked_polls(&self, limit: usize) -> Result<(Vec<String>, Vec<String>)> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT t.token, s.secret FROM tracked_tokens t
             LEFT JOIN tracked_token_secrets s ON s.token = t.token
             ORDER BY t.created_at DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit as i64], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)))?;
        let (mut legacy, mut secrets) = (Vec::new(), Vec::new());
        for (token, secret) in rows.flatten() {
            match secret {
                Some(s) => secrets.push(s),
                None => legacy.push(token),
            }
        }
        Ok((legacy, secrets))
    }

    /// Tokens to poll opens for. Bounded so the poll body stays small; newest
    /// first (recent sends are the ones a user is watching).
    pub fn tracked_tokens(&self, limit: usize) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT token FROM tracked_tokens ORDER BY created_at DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit as i64], |r| r.get::<_, String>(0))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Upsert opens for one token (idempotent on the token+opened_at+ip PK).
    pub fn replace_opens_for_token(&self, token: &str, opens: &[OpenRecord]) -> Result<()> {
        let conn = self.conn.lock();
        for o in opens {
            conn.execute(
                "INSERT OR IGNORE INTO message_opens \
                 (token, opened_at, ip, geo_country, geo_city, proxied, proxy_kind, user_agent) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    token,
                    o.opened_at,
                    o.ip,
                    o.geo_country,
                    o.geo_city,
                    o.proxied as i32,
                    o.proxy_kind,
                    o.user_agent,
                ],
            )?;
        }
        Ok(())
    }

    /// A message's HTML body by key — used to recover its embedded tracking token.
    pub fn message_body_html(&self, message_key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        let v: Option<Option<String>> = conn
            .query_row(
                "SELECT body_html FROM messages WHERE key = ?1",
                params![message_key],
                |r| r.get(0),
            )
            .optional()?;
        Ok(v.flatten())
    }

    pub fn opens_for_token(&self, token: &str) -> Result<Vec<OpenRecord>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT opened_at, ip, geo_country, geo_city, proxied, proxy_kind, user_agent \
             FROM message_opens WHERE token = ?1 ORDER BY opened_at ASC",
        )?;
        let rows = stmt.query_map(params![token], |r| {
            Ok(OpenRecord {
                opened_at: r.get(0)?,
                ip: r.get(1)?,
                geo_country: r.get(2)?,
                geo_city: r.get(3)?,
                proxied: r.get::<_, i32>(4)? != 0,
                proxy_kind: r.get(5)?,
                user_agent: r.get(6)?,
            })
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }
}
