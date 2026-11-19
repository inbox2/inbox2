//! `SyncStore` — encrypted credentials, app secrets, and push-subscription state.

use super::*;

impl SyncStore {

    // -----------------------------------------------------------------------
    // Credentials
    // -----------------------------------------------------------------------

    pub fn store_credentials(&self, account_key: &str, creds: &ProviderCredentials) -> Result<()> {
        let plaintext = serde_json::to_vec(&CredentialPayload::from(creds))
            .map_err(|e| SyncError::Encryption(format!("serialize: {e}")))?;

        let (encrypted, nonce) = self.encryptor.encrypt(&plaintext)?;
        let now = Utc::now().to_rfc3339();

        let conn = self.conn.lock();
        conn.execute(
            "INSERT OR REPLACE INTO external_account_credentials
             (account_key, encrypted_data, nonce, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![account_key, encrypted, nonce, now, now],
        )?;
        Ok(())
    }

    pub fn get_credentials(&self, account_key: &str) -> Result<Option<ProviderCredentials>> {
        let conn = self.conn.lock();
        let row: Option<(Vec<u8>, Vec<u8>)> = conn
            .query_row(
                "SELECT encrypted_data, nonce FROM external_account_credentials WHERE account_key = ?1",
                params![account_key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;

        match row {
            None => Ok(None),
            Some((encrypted, nonce)) => {
                // A decrypt failure here means the row is intact but the master key
                // no longer matches it. Reported distinctly so it reaches the UI as
                // "reconnect this account" — otherwise the channel stays `Connected`
                // while every sync and write-back fails with an opaque error.
                let plaintext = self.encryptor.decrypt(&encrypted, &nonce).map_err(|e| {
                    log::error!(
                        "[crypto] credentials for {account_key} will not decrypt ({e}) — the \
                         credential master key no longer matches the stored ciphertext; \
                         this account must be reconnected"
                    );
                    SyncError::CredentialUnreadable(format!("account {account_key}: {e}"))
                })?;
                let payload: CredentialPayload = serde_json::from_slice(&plaintext)
                    .map_err(|e| SyncError::Encryption(format!("deserialize: {e}")))?;
                Ok(Some(payload.into()))
            }
        }
    }

    // -----------------------------------------------------------------------
    // App-level encrypted secrets (Rails token, third-party API keys)
    // -----------------------------------------------------------------------

    /// Store an app-level secret by name, encrypted with the device-bound key.
    pub fn store_app_secret(&self, name: &str, value: &str) -> Result<()> {
        let (encrypted, nonce) = self.encryptor.encrypt(value.as_bytes())?;
        let now = Utc::now().to_rfc3339();
        let conn = self.conn.lock();
        conn.execute(
            "INSERT OR REPLACE INTO app_secrets (name, encrypted_data, nonce, updated_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![name, encrypted, nonce, now],
        )?;
        Ok(())
    }

    pub fn get_app_secret(&self, name: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        let row: Option<(Vec<u8>, Vec<u8>)> = conn
            .query_row(
                "SELECT encrypted_data, nonce FROM app_secrets WHERE name = ?1",
                params![name],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        match row {
            None => Ok(None),
            Some((encrypted, nonce)) => {
                let plaintext = self.encryptor.decrypt(&encrypted, &nonce)?;
                Ok(Some(String::from_utf8_lossy(&plaintext).into_owned()))
            }
        }
    }

    pub fn delete_app_secret(&self, name: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute("DELETE FROM app_secrets WHERE name = ?1", params![name])?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Cloud-push subscription state (Gmail/Office365) — see docs/Cloud-Push.md
    // -----------------------------------------------------------------------

    /// Upsert the local copy of a provider-side push subscription (metadata only;
    /// never tokens). Used for renewal timing — Rails is the source of truth.
    pub fn upsert_push_state(&self, state: &PushSubState) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO push_subscription_state
             (account_key, rails_key, provider_subscription_id, client_state, expires_at, registered_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
             ON CONFLICT(account_key) DO UPDATE SET
               rails_key = excluded.rails_key,
               provider_subscription_id = excluded.provider_subscription_id,
               client_state = excluded.client_state,
               expires_at = excluded.expires_at,
               updated_at = excluded.updated_at",
            params![
                state.account_key,
                state.rails_key,
                state.provider_subscription_id,
                state.client_state,
                state.expires_at,
                now,
            ],
        )?;
        Ok(())
    }

    pub fn get_push_state(&self, account_key: &str) -> Result<Option<PushSubState>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT account_key, rails_key, provider_subscription_id, client_state, expires_at
             FROM push_subscription_state WHERE account_key = ?1",
            params![account_key],
            Self::map_push_state,
        )
        .optional()
        .map_err(Into::into)
    }

    /// All locally-tracked push subscriptions (for the renewal sweep).
    pub fn list_push_states(&self) -> Result<Vec<PushSubState>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT account_key, rails_key, provider_subscription_id, client_state, expires_at
             FROM push_subscription_state",
        )?;
        let rows = stmt
            .query_map([], Self::map_push_state)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn map_push_state(row: &rusqlite::Row) -> rusqlite::Result<PushSubState> {
        Ok(PushSubState {
            account_key: row.get(0)?,
            rails_key: row.get(1)?,
            provider_subscription_id: row.get(2)?,
            client_state: row.get(3)?,
            expires_at: row.get(4)?,
        })
    }

    pub fn delete_push_state(&self, account_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM push_subscription_state WHERE account_key = ?1",
            params![account_key],
        )?;
        Ok(())
    }
}
