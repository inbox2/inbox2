//! `SyncStore` — local state for the zero-knowledge credential vault (docs/E2EE.md).
//!
//! Holds the `vault_state` single-row cache, the per-account "backed up" bookkeeping
//! (enabled flag + dirty marker + version), the bundle builder that joins an account
//! with its decrypted credentials, and the device-key wrap/unwrap (which need the
//! store's private `CredentialEncryptor`). The DEK-level and password-level crypto
//! lives in [`crate::sync::vault`]; the engine orchestration in `sync::vault_sync`.

use super::*;
use crate::sync::vault::CredentialBundle;

impl SyncStore {
    // -----------------------------------------------------------------------
    // Vault state (single row, id = 1)
    // -----------------------------------------------------------------------

    pub fn get_vault_state(&self) -> Result<Option<VaultState>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT enabled, vault_key, bound_user_id, device_wrapped_dek, device_wrapped_nonce, \
                    passphrase_wrapped_dek, passphrase_wrapped_nonce, argon_salt, argon_params \
             FROM vault_state WHERE id = 1",
            [],
            |row| {
                Ok(VaultState {
                    enabled: row.get::<_, i32>(0)? != 0,
                    vault_key: row.get(1)?,
                    bound_user_id: row.get(2)?,
                    device_wrapped_dek: row.get(3)?,
                    device_wrapped_nonce: row.get(4)?,
                    passphrase_wrapped_dek: row.get(5)?,
                    passphrase_wrapped_nonce: row.get(6)?,
                    argon_salt: row.get(7)?,
                    argon_params: row.get(8)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn save_vault_state(&self, s: &VaultState) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO vault_state
               (id, enabled, vault_key, bound_user_id, device_wrapped_dek, device_wrapped_nonce,
                passphrase_wrapped_dek, passphrase_wrapped_nonce, argon_salt, argon_params,
                created_at, updated_at)
             VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
             ON CONFLICT(id) DO UPDATE SET
               enabled = excluded.enabled,
               vault_key = excluded.vault_key,
               bound_user_id = excluded.bound_user_id,
               device_wrapped_dek = excluded.device_wrapped_dek,
               device_wrapped_nonce = excluded.device_wrapped_nonce,
               passphrase_wrapped_dek = excluded.passphrase_wrapped_dek,
               passphrase_wrapped_nonce = excluded.passphrase_wrapped_nonce,
               argon_salt = excluded.argon_salt,
               argon_params = excluded.argon_params,
               updated_at = excluded.updated_at",
            params![
                s.enabled as i32,
                s.vault_key,
                s.bound_user_id,
                s.device_wrapped_dek,
                s.device_wrapped_nonce,
                s.passphrase_wrapped_dek,
                s.passphrase_wrapped_nonce,
                s.argon_salt,
                s.argon_params,
                now,
            ],
        )?;
        Ok(())
    }

    /// Disable + forget the vault locally (the DEK is dropped from memory by the
    /// engine; this clears the on-disk wrapped copies). Also clears every account's
    /// backup flag so nothing re-uploads after the vault is gone / identity changes.
    pub fn clear_vault_state(&self) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute("DELETE FROM vault_state", [])?;
        conn.execute(
            "UPDATE external_accounts SET cloud_backup_enabled = 0",
            [],
        )?;
        conn.execute(
            "UPDATE external_account_credentials SET backup_dirty = 0",
            [],
        )?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Per-account backup bookkeeping
    // -----------------------------------------------------------------------

    pub fn set_account_backup_enabled(&self, account_key: &str, enabled: bool) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE external_accounts SET cloud_backup_enabled = ?2 WHERE key = ?1",
            params![account_key, enabled as i32],
        )?;
        Ok(())
    }

    /// Flag every existing account for cloud backup. Used on first vault-enable so
    /// channels connected *before* the inbox2 account existed are backed up too —
    /// the "I added an MX account, save my already-connected logins" upgrade case
    /// (see docs/E2EE.md). Returns the number of accounts flagged.
    pub fn enable_backup_for_all_accounts(&self) -> Result<usize> {
        let conn = self.conn.lock();
        Ok(conn.execute(
            "UPDATE external_accounts SET cloud_backup_enabled = 1 WHERE cloud_backup_enabled = 0",
            [],
        )?)
    }

    pub fn account_backup_enabled(&self, account_key: &str) -> Result<bool> {
        let conn = self.conn.lock();
        let v: Option<i32> = conn
            .query_row(
                "SELECT cloud_backup_enabled FROM external_accounts WHERE key = ?1",
                params![account_key],
                |r| r.get(0),
            )
            .optional()?;
        Ok(v.unwrap_or(0) != 0)
    }

    /// Accounts whose credentials should be mirrored to the cloud vault.
    pub fn list_backup_enabled_accounts(&self) -> Result<Vec<ExternalAccount>> {
        let keys: Vec<String> = {
            let conn = self.conn.lock();
            let mut stmt = conn.prepare(
                "SELECT key FROM external_accounts WHERE cloud_backup_enabled = 1 \
                 ORDER BY sort_order, created_at",
            )?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        let mut out = Vec::with_capacity(keys.len());
        for k in keys {
            if let Some(acct) = self.get_account(&k)? {
                out.push(acct);
            }
        }
        Ok(out)
    }

    /// Mark an account's credentials as needing (re)upload. Set on create + every
    /// token refresh; the engine's drain clears it once uploaded.
    pub fn mark_backup_dirty(&self, account_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE external_account_credentials SET backup_dirty = 1 WHERE account_key = ?1",
            params![account_key],
        )?;
        Ok(())
    }

    /// Account keys whose credentials are dirty AND whose account is backup-enabled.
    pub fn list_dirty_backup_accounts(&self) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT c.account_key FROM external_account_credentials c
             JOIN external_accounts a ON a.key = c.account_key
             WHERE c.backup_dirty = 1 AND a.cloud_backup_enabled = 1",
        )?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Clear the dirty flag and stamp the uploaded version after a successful push.
    pub fn mark_backed_up(&self, account_key: &str, version: i64) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE external_account_credentials
             SET backup_dirty = 0, backed_up_at = ?2, backup_version = ?3
             WHERE account_key = ?1",
            params![account_key, now, version],
        )?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Bundle builder + device-key wrap (needs the private encryptor)
    // -----------------------------------------------------------------------

    /// Assemble the encryptable backup payload for an account: its config + the
    /// decrypted credentials. `None` if the account or its credentials are missing.
    pub(crate) fn build_credential_bundle(
        &self,
        account_key: &str,
    ) -> Result<Option<CredentialBundle>> {
        let Some(acct) = self.get_account(account_key)? else {
            return Ok(None);
        };
        let Some(creds) = self.get_credentials(account_key)? else {
            return Ok(None);
        };
        Ok(Some(CredentialBundle {
            provider_type: acct.provider_type.as_str().to_string(),
            email_address: acct.email_address,
            display_name: acct.display_name,
            host: acct.host,
            port: acct.port,
            use_tls: acct.use_tls,
            smtp_host: acct.smtp_host,
            smtp_port: acct.smtp_port,
            smtp_use_tls: acct.smtp_use_tls,
            auth_method: acct.auth_method,
            avatar_url: acct.avatar_url,
            credentials: (&creds).into(),
        }))
    }

    /// Wrap the DEK under this device's keychain key (copy 1). Returns (ct, nonce).
    pub fn device_wrap_dek(&self, dek: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
        self.encryptor.encrypt(dek)
    }

    /// Unwrap the device-key copy of the DEK (copy 1) — transparent same-device unlock.
    pub fn device_unwrap_dek(&self, ciphertext: &[u8], nonce: &[u8]) -> Result<Vec<u8>> {
        self.encryptor.decrypt(ciphertext, nonce)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::model::{AccountStatus, AuthMethod, ProviderType};
    use crate::sync::vault;

    fn mk_account(store: &SyncStore, email: &str) -> String {
        store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: email.into(),
                email_address: email.into(),
                provider_type: ProviderType::Gmail,
                host: None,
                port: None,
                use_tls: true,
                smtp_host: None,
                smtp_port: None,
                smtp_use_tls: true,
                auth_method: AuthMethod::OAuth2.as_str().to_string(),
                status: AccountStatus::Disconnected,
                error_message: None,
                last_connected_at: None,
                sort_order: 0,
                avatar_url: None,
            })
            .unwrap()
    }

    #[test]
    fn vault_state_round_trips() {
        let store = SyncStore::new_in_memory().unwrap();
        assert!(store.get_vault_state().unwrap().is_none());

        let st = VaultState {
            enabled: true,
            vault_key: Some("vlt_abc".into()),
            bound_user_id: Some("usr_1".into()),
            device_wrapped_dek: Some(vec![1, 2, 3]),
            device_wrapped_nonce: Some(vec![4, 5]),
            passphrase_wrapped_dek: Some(vec![6, 7, 8]),
            passphrase_wrapped_nonce: Some(vec![9]),
            argon_salt: Some(vec![10, 11]),
            argon_params: Some("{\"mem_kib\":65536}".into()),
        };
        store.save_vault_state(&st).unwrap();

        let got = store.get_vault_state().unwrap().unwrap();
        assert!(got.enabled);
        assert_eq!(got.vault_key.as_deref(), Some("vlt_abc"));
        assert_eq!(got.bound_user_id.as_deref(), Some("usr_1"));
        assert_eq!(got.passphrase_wrapped_dek, Some(vec![6, 7, 8]));

        // Upsert: a second save updates the single row, not a duplicate.
        let st2 = VaultState {
            bound_user_id: Some("usr_2".into()),
            ..st
        };
        store.save_vault_state(&st2).unwrap();
        assert_eq!(
            store.get_vault_state().unwrap().unwrap().bound_user_id.as_deref(),
            Some("usr_2")
        );
    }

    #[test]
    fn backup_flags_and_dirty_drain_set() {
        let store = SyncStore::new_in_memory().unwrap();
        let a = mk_account(&store, "a@gmail.com");
        store
            .store_credentials(
                &a,
                &ProviderCredentials::OAuth2 {
                    username: "a@gmail.com".into(),
                    access_token: "tok".into(),
                    refresh_token: Some("rt".into()),
                },
            )
            .unwrap();

        // Not enabled by default.
        assert!(!store.account_backup_enabled(&a).unwrap());
        assert!(store.list_backup_enabled_accounts().unwrap().is_empty());

        store.set_account_backup_enabled(&a, true).unwrap();
        assert!(store.account_backup_enabled(&a).unwrap());
        assert_eq!(store.list_backup_enabled_accounts().unwrap().len(), 1);

        // Dirty only counts when the account is also backup-enabled.
        store.mark_backup_dirty(&a).unwrap();
        assert_eq!(store.list_dirty_backup_accounts().unwrap(), vec![a.clone()]);

        store.mark_backed_up(&a, 3).unwrap();
        assert!(store.list_dirty_backup_accounts().unwrap().is_empty());
    }

    #[test]
    fn clear_vault_state_resets_flags() {
        let store = SyncStore::new_in_memory().unwrap();
        let a = mk_account(&store, "a@gmail.com");
        store
            .store_credentials(
                &a,
                &ProviderCredentials::Password {
                    username: "a@gmail.com".into(),
                    password: "pw".into(),
                },
            )
            .unwrap();
        store.set_account_backup_enabled(&a, true).unwrap();
        store.mark_backup_dirty(&a).unwrap();
        store
            .save_vault_state(&VaultState {
                enabled: true,
                ..Default::default()
            })
            .unwrap();

        store.clear_vault_state().unwrap();

        assert!(store.get_vault_state().unwrap().is_none());
        assert!(!store.account_backup_enabled(&a).unwrap());
        assert!(store.list_dirty_backup_accounts().unwrap().is_empty());
    }

    #[test]
    fn build_bundle_round_trips_through_dek() {
        let store = SyncStore::new_in_memory().unwrap();
        let a = mk_account(&store, "a@gmail.com");
        store
            .store_credentials(
                &a,
                &ProviderCredentials::OAuth2 {
                    username: "a@gmail.com".into(),
                    access_token: "secret-tok".into(),
                    refresh_token: Some("secret-rt".into()),
                },
            )
            .unwrap();

        let bundle = store.build_credential_bundle(&a).unwrap().unwrap();
        assert_eq!(bundle.email_address, "a@gmail.com");
        assert_eq!(bundle.provider_type, "gmail");

        // End-to-end: encrypt under a DEK and decrypt back.
        let dek = vault::new_dek();
        let (ct, nonce) = vault::encrypt_bundle(&dek, &bundle).unwrap();
        let back = vault::decrypt_bundle(&dek, &ct, &nonce).unwrap();
        match back.credentials {
            CredentialPayload::OAuth2 { access_token, .. } => {
                assert_eq!(access_token, "secret-tok")
            }
            _ => panic!("expected OAuth2"),
        }
    }

    #[test]
    fn device_wrap_round_trips() {
        let store = SyncStore::new_in_memory().unwrap();
        let dek = vault::new_dek();
        let (ct, nonce) = store.device_wrap_dek(dek.as_ref()).unwrap();
        let back = store.device_unwrap_dek(&ct, &nonce).unwrap();
        assert_eq!(back, dek.as_ref());
    }
}
