//! `SyncStore` — accounts, diagnostics, and the per-account attachment cache.

use super::*;

/// Minimum gap between two reconnect prompts for the same account.
const REAUTH_PROMPT_COOLDOWN_SECS: i64 = 300;

impl SyncStore {

    /// Rate-limits the "sign-in expired — reconnect" prompt: returns true at most
    /// once every 5 minutes per account, and stamps the claim. Persisted (the
    /// clients' in-memory "already alerted" sets reset on every relaunch, which is
    /// why an expired token re-prompted on every app start and every foreground).
    /// The passive indicators (red dot, Settings banner) are unaffected — this only
    /// gates the interrupting prompt.
    pub fn claim_reauth_prompt(&self, account_key: &str) -> bool {
        let key = format!("reauth_prompted_at:{account_key}");
        let last = self
            .get_engine_setting(&key)
            .ok()
            .flatten()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(&s).ok())
            .map(|t| t.with_timezone(&Utc));
        let now = Utc::now();
        if last.is_some_and(|t| now.signed_duration_since(t).num_seconds() < REAUTH_PROMPT_COOLDOWN_SECS) {
            return false;
        }
        let _ = self.set_engine_setting(&key, &now.to_rfc3339());
        true
    }

    /// Per-account local-DB counts + the inbox sync cursor (Gmail historyId /
    /// Microsoft deltaLink), for the Sync Console. Returns
    /// (conversations, messages, provider_states, folders, inbox_cursor).
    pub fn account_diagnostics(
        &self,
        account_key: &str,
    ) -> Result<(i64, i64, i64, i64, Option<String>)> {
        let conn = self.conn.lock();
        let (messages, conversations): (i64, i64) = conn.query_row(
            "SELECT COUNT(*), COUNT(DISTINCT conversation_key) FROM messages WHERE account_key = ?1",
            params![account_key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let provider_states: i64 = conn.query_row(
            "SELECT COUNT(*) FROM message_provider_state WHERE account_key = ?1",
            params![account_key],
            |r| r.get(0),
        )?;
        let folders: i64 = conn.query_row(
            "SELECT COUNT(*) FROM external_folders WHERE account_key = ?1",
            params![account_key],
            |r| r.get(0),
        )?;
        let inbox_cursor: Option<String> = conn
            .query_row(
                "SELECT sync_cursor FROM external_folders \
                 WHERE account_key = ?1 AND well_known_role = 'inbox' LIMIT 1",
                params![account_key],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        Ok((conversations, messages, provider_states, folders, inbox_cursor))
    }

    /// Message count per folder (keyed by external_folders.key) for an account.
    pub fn folder_message_counts(
        &self,
        account_key: &str,
    ) -> Result<std::collections::HashMap<String, i64>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT folder_key, COUNT(*) FROM message_provider_state \
             WHERE account_key = ?1 GROUP BY folder_key",
        )?;
        let rows = stmt.query_map(params![account_key], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
        })?;
        let mut counts = std::collections::HashMap::new();
        for row in rows {
            let (key, count) = row?;
            counts.insert(key, count);
        }
        Ok(counts)
    }

    // -----------------------------------------------------------------------
    // Accounts
    // -----------------------------------------------------------------------

    pub fn create_account(&self, account: &ExternalAccount) -> Result<String> {
        let conn = self.conn.lock();

        // Check for existing account with same email + provider
        let existing: Option<String> = conn.query_row(
            "SELECT key FROM external_accounts WHERE email_address = ?1 AND provider_type = ?2 LIMIT 1",
            params![account.email_address, account.provider_type.as_str()],
            |row| row.get(0),
        ).optional()?;

        if let Some(key) = existing {
            // Update existing account
            let now = Utc::now().to_rfc3339();
            conn.execute(
                "UPDATE external_accounts SET display_name = ?1, host = ?2, port = ?3,
                 use_tls = ?4, smtp_host = ?5, smtp_port = ?6, smtp_use_tls = ?7,
                 auth_method = ?8, updated_at = ?9 WHERE key = ?10",
                params![
                    account.display_name,
                    account.host,
                    account.port.map(|p| p as i64),
                    account.use_tls as i32,
                    account.smtp_host,
                    account.smtp_port.map(|p| p as i64),
                    account.smtp_use_tls as i32,
                    account.auth_method,
                    now,
                    key,
                ],
            )?;
            return Ok(key);
        }

        let key = Self::generate_key("acc");
        let now = Utc::now().to_rfc3339();
        // Assign sort_order = max + 1
        let max_order: i32 = conn
            .query_row(
                "SELECT COALESCE(MAX(sort_order), -1) FROM external_accounts",
                [],
                |row| row.get(0),
            )
            .unwrap_or(-1);
        conn.execute(
            "INSERT INTO external_accounts
             (key, display_name, email_address, provider_type, host, port, use_tls,
              smtp_host, smtp_port, smtp_use_tls, auth_method, status, sort_order,
              created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            params![
                key,
                account.display_name,
                account.email_address,
                account.provider_type.as_str(),
                account.host,
                account.port.map(|p| p as i64),
                account.use_tls as i32,
                account.smtp_host,
                account.smtp_port.map(|p| p as i64),
                account.smtp_use_tls as i32,
                account.auth_method,
                AccountStatus::Disconnected.as_str(),
                max_order + 1,
                now,
                now,
            ],
        )?;
        Ok(key)
    }

    /// Column list shared by [`get_account`] and [`list_accounts`]; the order
    /// must match the indices read in [`row_to_external_account`].
    const ACCOUNT_COLUMNS: &'static str =
        "key, display_name, email_address, provider_type, host, port, use_tls, \
         smtp_host, smtp_port, smtp_use_tls, \
         auth_method, status, error_message, last_connected_at, sort_order, avatar_url";

    pub fn get_account(&self, key: &str) -> Result<Option<ExternalAccount>> {
        let conn = self.conn.lock();
        conn.query_row(
            &format!("SELECT {} FROM external_accounts WHERE key = ?1", Self::ACCOUNT_COLUMNS),
            params![key],
            row_to_external_account,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn list_accounts(&self) -> Result<Vec<ExternalAccount>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM external_accounts ORDER BY sort_order, created_at",
            Self::ACCOUNT_COLUMNS,
        ))?;
        let rows = stmt.query_map([], row_to_external_account)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn reorder_accounts(&self, keys: &[String]) -> Result<()> {
        let conn = self.conn.lock();
        for (i, key) in keys.iter().enumerate() {
            conn.execute(
                "UPDATE external_accounts SET sort_order = ?1 WHERE key = ?2",
                params![i as i32, key],
            )?;
        }
        Ok(())
    }

    pub fn update_account_status(
        &self,
        key: &str,
        status: &AccountStatus,
        error: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        let last_connected = if *status == AccountStatus::Connected {
            Some(now.clone())
        } else {
            None
        };
        conn.execute(
            "UPDATE external_accounts
             SET status = ?1, error_message = ?2, last_connected_at = COALESCE(?3, last_connected_at), updated_at = ?4
             WHERE key = ?5",
            params![status.as_str(), error, last_connected, now, key],
        )?;
        Ok(())
    }

    pub fn set_account_avatar(&self, key: &str, avatar_url: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE external_accounts SET avatar_url = ?1, updated_at = ?2 WHERE key = ?3",
            params![avatar_url, Utc::now().to_rfc3339(), key],
        )?;
        Ok(())
    }

    pub fn delete_account(&self, key: &str) -> Result<()> {
        let mut conn = self.conn.lock();

        // All deletes run in a single transaction: a failure (or crash) partway
        // through must not leave the DB FK-inconsistent (e.g. messages gone but
        // conversations orphaned). The transaction rolls back on any `?` and on
        // drop without commit.
        let tx = conn.transaction()?;

        // Order matters: delete referencing rows before referenced rows.
        // message_provider_state FK on messages(key) has no CASCADE,
        // so we must delete it before messages.
        tx.execute(
            "DELETE FROM message_provider_state WHERE account_key = ?1",
            params![key],
        )?;
        tx.execute(
            "DELETE FROM writeback_actions WHERE account_key = ?1",
            params![key],
        )?;

        // Delete orphan-prone join tables scoped to this account's conversations
        tx.execute(
            "DELETE FROM conversation_tags WHERE conversation_key IN \
             (SELECT key FROM conversations WHERE organization_id = ?1)",
            params![key],
        )?;
        tx.execute(
            "DELETE FROM notes WHERE organization_id = ?1",
            params![key],
        )?;
        tx.execute(
            "DELETE FROM tags WHERE organization_id = ?1",
            params![key],
        )?;

        // Now safe to delete messages and conversations
        tx.execute(
            "DELETE FROM messages WHERE account_key = ?1",
            params![key],
        )?;
        tx.execute(
            "DELETE FROM conversations WHERE organization_id = ?1",
            params![key],
        )?;

        // Calendar tables carry account_key but have no ON DELETE CASCADE FK, so
        // delete them explicitly (attendees first — they hang off events) to
        // avoid orphaning a removed account's calendars/events.
        tx.execute(
            "DELETE FROM calendar_attendees WHERE event_key IN \
             (SELECT key FROM calendar_events WHERE account_key = ?1)",
            params![key],
        )?;
        tx.execute(
            "DELETE FROM calendar_events WHERE account_key = ?1",
            params![key],
        )?;
        tx.execute(
            "DELETE FROM calendars WHERE account_key = ?1",
            params![key],
        )?;

        // CASCADE handles: credentials, folders, message_provider_state,
        // writeback_actions, outbox_messages, push_subscription_state.
        tx.execute("DELETE FROM external_accounts WHERE key = ?1", params![key])?;

        tx.commit()?;
        drop(conn);

        // Clean up cached attachment files for this account *after* the DB delete
        // commits — the filesystem isn't part of the transaction, and a failed
        // cache cleanup must not roll back a successful account deletion.
        if let Ok(cache_dir) = self.resolve_attachment_cache_dir(key) {
            let _ = std::fs::remove_dir_all(&cache_dir);
        }

        Ok(())
    }

    pub(crate) fn resolve_attachment_cache_dir(&self, account_key: &str) -> std::result::Result<std::path::PathBuf, String> {
        Ok(self.app_data_dir.join("attachment-cache").join(account_key))
    }

    /// Path an attachment occupies in the shared attachment cache, namespaced by
    /// message so same-named attachments on different messages (e.g. every invoice
    /// arriving as `invoice.pdf`) don't collide. Shares the `attachment-cache` root
    /// used by the open-attachment feature, so account deletion still wipes it.
    pub fn message_attachment_path(
        &self,
        account_key: &str,
        message_key: &str,
        filename: &str,
    ) -> std::path::PathBuf {
        let safe_name = std::path::Path::new(filename)
            .file_name()
            .and_then(|s| s.to_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("attachment");
        let safe_msg = message_key.replace(['/', '\\', '\0'], "_");
        self.app_data_dir
            .join("attachment-cache")
            .join(account_key)
            .join(safe_msg)
            .join(safe_name)
    }

    /// Write bytes to the per-message attachment cache (idempotent), returning the
    /// absolute path. Used by the agent runner so a downloaded attachment is reused
    /// on retries and never re-fetched.
    pub fn cache_message_attachment(
        &self,
        account_key: &str,
        message_key: &str,
        filename: &str,
        bytes: &[u8],
    ) -> Result<std::path::PathBuf> {
        let path = self.message_attachment_path(account_key, message_key, filename);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| SyncError::Other(format!("create attachment dir: {e}")))?;
        }
        std::fs::write(&path, bytes)
            .map_err(|e| SyncError::Other(format!("write attachment: {e}")))?;
        Ok(path)
    }
}
