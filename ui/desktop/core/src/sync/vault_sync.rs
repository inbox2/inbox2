//! Engine orchestration for the zero-knowledge credential vault (docs/E2EE.md).
//!
//! Ties together the local store ([`crate::sync::store::vault`]), the crypto
//! ([`crate::sync::vault`]), and the Rails blob API. The DEK lives in the engine's
//! in-memory `dek` slot once unlocked; everything persisted (locally or on the
//! server) is opaque ciphertext.
//!
//! Lifecycle: `enable_cloud_backup` (first opt-in) → `upload_account_backup` /
//! `drain_backup_dirty` (push) → on a new device `restore_from_cloud` (pull +
//! decrypt + recreate accounts). `try_device_unlock` re-opens the vault at boot via
//! the keychain copy. `rotate_vault` re-encrypts everything on a password change.
//! `clear_vault_session` tears it down on sign-out / identity switch.

use base64::Engine as _;
use serde::Serialize;

use crate::sync::engine::SyncEngine;
use crate::sync::error::{Result, SyncError};
use crate::sync::model::{AuthMethod, ExternalAccount, ProviderCredentials, ProviderType, VaultState};
use crate::sync::vault::{self, ArgonParams};

const B64: base64::engine::general_purpose::GeneralPurpose = base64::engine::general_purpose::STANDARD;

/// Metadata for one cloud-backed credential (no ciphertext) — drives the restore
/// offer and the management UI.
#[derive(Debug, Clone, Serialize)]
pub struct CloudBackupMeta {
    pub provider: String,
    pub external_email: String,
    pub blob_version: i64,
}

/// Snapshot of vault state for the UI gating + status.
#[derive(Debug, Clone, Serialize)]
pub struct VaultStatus {
    pub enabled: bool,
    pub unlocked: bool,
    pub account_count: u32,
}

/// Pack an AEAD (nonce, ciphertext) pair into one base64 string (`nonce || ct`) so
/// it fits a single server column; [`unpack`] reverses it.
fn pack(nonce: &[u8], ciphertext: &[u8]) -> String {
    let mut buf = Vec::with_capacity(nonce.len() + ciphertext.len());
    buf.extend_from_slice(nonce);
    buf.extend_from_slice(ciphertext);
    B64.encode(buf)
}

/// Split a packed `nonce || ct` blob back into (nonce, ciphertext). AES-GCM nonces
/// are 12 bytes.
fn unpack(packed: &str) -> Result<(Vec<u8>, Vec<u8>)> {
    let raw = B64
        .decode(packed.trim())
        .map_err(|e| SyncError::Encryption(format!("vault unpack: {e}")))?;
    if raw.len() <= 12 {
        return Err(SyncError::Encryption("vault blob too short".into()));
    }
    let (nonce, ct) = raw.split_at(12);
    Ok((nonce.to_vec(), ct.to_vec()))
}

impl SyncEngine {
    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// True when a non-empty Rails bearer is set — cloud backup needs an MX session
    /// or `ink_` key, exactly like push registration.
    async fn has_cloud_bearer(&self) -> bool {
        matches!(
            self.api_context().read().await.as_ref(),
            Some(c) if !c.rails_jwt.is_empty()
        )
    }

    async fn require_bearer(&self) -> Result<()> {
        if self.has_cloud_bearer().await {
            Ok(())
        } else {
            Err(SyncError::Other(
                "sign in to your inbox2 account to use cloud backup".into(),
            ))
        }
    }

    /// The signed-in inbox2 user's public id (`usr_…`), used to bind the vault to
    /// one identity. Reads `GET /account`.
    async fn fetch_cloud_user_id(&self) -> Result<String> {
        let resp = self
            .rails_request(reqwest::Method::GET, "account", None, "vault account")
            .await?;
        let data: serde_json::Value = resp.json().await.unwrap_or_default();
        data.get("account")
            .and_then(|a| a.get("id"))
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| SyncError::Other("vault: no account id".into()))
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// First opt-in: generate the DEK, wrap it under the device key (local) + the
    /// password-derived KEK (server), persist vault state, cache the DEK, then back
    /// up every backup-enabled account. Returns the vault public id.
    pub async fn enable_cloud_backup(&self, password: &str) -> Result<String> {
        self.require_bearer().await?;
        let user_id = self.fetch_cloud_user_id().await?;

        let dek = vault::new_dek();
        let salt = vault::new_salt();
        let params = ArgonParams::default();
        let kek = vault::derive_kek(password, &salt, &params)?;

        let (dev_ct, dev_nonce) = self.store().device_wrap_dek(dek.as_ref())?;
        let (pw_ct, pw_nonce) = vault::wrap_key(&kek, &dek)?;
        let params_json = serde_json::to_string(&params)
            .map_err(|e| SyncError::Encryption(format!("argon params: {e}")))?;

        // Upload the vault metadata (server gets only the password-wrapped copy +
        // salt + params — all useless without the password).
        let vault_key = self
            .upsert_vault_on_rails(&pw_nonce, &pw_ct, &salt, &params_json)
            .await?;

        let state = VaultState {
            enabled: true,
            vault_key: Some(vault_key.clone()),
            bound_user_id: Some(user_id),
            device_wrapped_dek: Some(dev_ct),
            device_wrapped_nonce: Some(dev_nonce),
            passphrase_wrapped_dek: Some(pw_ct),
            passphrase_wrapped_nonce: Some(pw_nonce),
            argon_salt: Some(salt.to_vec()),
            argon_params: Some(params_json),
        };
        self.store().save_vault_state(&state)?;
        self.set_dek(Some(dek));

        // Backfill: flag EVERY existing account for backup, so channels connected
        // before this inbox2 account existed get saved too (the "add MX → save my
        // already-connected logins" upgrade case — docs/E2EE.md).
        let flagged = self.store().enable_backup_for_all_accounts()?;
        if flagged > 0 {
            log::info!("[vault] enable: backfilling {flagged} pre-existing account(s)");
        }

        // Back up every backup-enabled account.
        for acct in self.store().list_backup_enabled_accounts()? {
            if let Err(e) = self.upload_account_backup(&acct.key).await {
                log::warn!("[vault] initial backup of {} failed: {e}", acct.key);
            }
        }
        Ok(vault_key)
    }

    /// Turn off cloud backup: delete the vault + all blobs server-side, drop the DEK
    /// and clear local state.
    pub async fn disable_cloud_backup(&self) -> Result<()> {
        if self.has_cloud_bearer().await {
            let _ = self
                .rails_request(
                    reqwest::Method::DELETE,
                    "stored-credentials/vault",
                    None,
                    "vault disable",
                )
                .await;
        }
        self.set_dek(None);
        self.store().clear_vault_state()?;
        Ok(())
    }

    /// Unlock the vault with the inbox2 password (a new device, or after the device
    /// copy is unavailable). Derives the KEK, unwraps the password copy, caches the
    /// DEK, and re-wraps a fresh device copy so future boots unlock transparently.
    pub async fn unlock_vault(&self, password: &str) -> Result<()> {
        let state = self
            .store()
            .get_vault_state()?
            .ok_or_else(|| SyncError::Other("vault: not set up on this device".into()))?;
        let (salt, params) = self.salt_params(&state)?;
        let (pw_nonce, pw_ct) = self.passphrase_copy(&state)?;

        let kek = vault::derive_kek(password, &salt, &params)?;
        let dek = vault::unwrap_key(&kek, &pw_ct, &pw_nonce)
            .map_err(|_| SyncError::Other("incorrect inbox2 password".into()))?;

        // Refresh the device copy so the keychain can re-unlock without the password.
        let (dev_ct, dev_nonce) = self.store().device_wrap_dek(dek.as_ref())?;
        let mut new_state = state;
        new_state.device_wrapped_dek = Some(dev_ct);
        new_state.device_wrapped_nonce = Some(dev_nonce);
        self.store().save_vault_state(&new_state)?;

        self.set_dek(Some(dek));
        Ok(())
    }

    /// Boot-time transparent unlock via the device keychain copy. Returns whether the
    /// vault is now unlocked. Never errors hard — a locked keychain / absent vault
    /// just leaves it locked (the user can unlock with their password later).
    pub fn try_device_unlock(&self) -> bool {
        let Ok(Some(state)) = self.store().get_vault_state() else {
            return false;
        };
        if !state.enabled {
            return false;
        }
        let (Some(ct), Some(nonce)) = (&state.device_wrapped_dek, &state.device_wrapped_nonce)
        else {
            return false;
        };
        match self.store().device_unwrap_dek(ct, nonce) {
            Ok(bytes) if bytes.len() == 32 => {
                let mut dek = zeroize::Zeroizing::new([0u8; 32]);
                dek.copy_from_slice(&bytes);
                self.set_dek(Some(dek));
                true
            }
            _ => false,
        }
    }

    /// Password change: rotate to a FRESH DEK and re-encrypt every backed-up account
    /// under it, so an exposed old password can't derive the new key. Requires the
    /// vault to be unlocked (the device holds the plaintext creds locally).
    pub async fn rotate_vault(&self, new_password: &str) -> Result<()> {
        self.require_bearer().await?;
        let state = self
            .store()
            .get_vault_state()?
            .ok_or_else(|| SyncError::Other("vault: not set up".into()))?;
        // Must be unlocked so we can re-wrap with the new password.
        if self.dek_snapshot().is_none() && !self.try_device_unlock() {
            return Err(SyncError::Other(
                "unlock the vault before changing the password".into(),
            ));
        }

        let new_dek = vault::new_dek();
        let salt = vault::new_salt();
        let params = ArgonParams::default();
        let kek = vault::derive_kek(new_password, &salt, &params)?;
        let (dev_ct, dev_nonce) = self.store().device_wrap_dek(new_dek.as_ref())?;
        let (pw_ct, pw_nonce) = vault::wrap_key(&kek, &new_dek)?;
        let params_json = serde_json::to_string(&params)
            .map_err(|e| SyncError::Encryption(format!("argon params: {e}")))?;

        // Re-key server-side: new wrapped DEK, then re-encrypt + re-upload every blob.
        self.upsert_vault_on_rails(&pw_nonce, &pw_ct, &salt, &params_json)
            .await?;

        let new_state = VaultState {
            enabled: true,
            vault_key: state.vault_key,
            bound_user_id: state.bound_user_id,
            device_wrapped_dek: Some(dev_ct),
            device_wrapped_nonce: Some(dev_nonce),
            passphrase_wrapped_dek: Some(pw_ct),
            passphrase_wrapped_nonce: Some(pw_nonce),
            argon_salt: Some(salt.to_vec()),
            argon_params: Some(params_json),
        };
        self.store().save_vault_state(&new_state)?;
        self.set_dek(Some(new_dek));

        // Re-encrypt all backed-up accounts under the new DEK.
        for acct in self.store().list_backup_enabled_accounts()? {
            if let Err(e) = self.upload_account_backup(&acct.key).await {
                log::warn!("[vault] rotate re-upload of {} failed: {e}", acct.key);
            }
        }
        Ok(())
    }

    /// Drop the DEK + clear local vault state. Called on sign-out and when a token is
    /// adopted for a different inbox2 user, so identity A's tokens never upload into
    /// identity B's vault.
    pub fn clear_vault_session(&self) {
        self.set_dek(None);
        if let Err(e) = self.store().clear_vault_state() {
            log::warn!("[vault] clear session failed: {e}");
        }
    }

    pub fn vault_status(&self) -> Result<VaultStatus> {
        let state = self.store().get_vault_state()?;
        Ok(VaultStatus {
            enabled: state.as_ref().map(|s| s.enabled).unwrap_or(false),
            unlocked: self.dek_snapshot().is_some(),
            account_count: self.store().list_backup_enabled_accounts()?.len() as u32,
        })
    }

    // -----------------------------------------------------------------------
    // Push
    // -----------------------------------------------------------------------

    /// Encrypt one account's credential bundle under the DEK and upsert it to Rails.
    pub async fn upload_account_backup(&self, account_key: &str) -> Result<()> {
        self.require_bearer().await?;
        let dek = self
            .dek_snapshot()
            .ok_or_else(|| SyncError::Other("vault locked".into()))?;
        let Some(bundle) = self.store().build_credential_bundle(account_key)? else {
            return Ok(());
        };
        let (ct, nonce) = vault::encrypt_bundle(&dek, &bundle)?;
        let version = (chrono::Utc::now().timestamp_millis()).max(1);
        let body = serde_json::json!({
            "provider": bundle.provider_type,
            "external_email": bundle.email_address,
            "blob": B64.encode(&ct),
            "blob_nonce": B64.encode(&nonce),
            "blob_version": version,
        });
        self.rails_request(
            reqwest::Method::PUT,
            "stored-credentials",
            Some(&body),
            "vault upload",
        )
        .await?;
        self.store().mark_backed_up(account_key, version)?;
        Ok(())
    }

    /// Drain accounts whose credentials are dirty (created / refreshed) — called from
    /// the run loop. No-op when the vault is locked or no bearer is set.
    pub async fn drain_backup_dirty(&self) {
        if self.dek_snapshot().is_none() || !self.has_cloud_bearer().await {
            return;
        }
        let dirty = match self.store().list_dirty_backup_accounts() {
            Ok(d) => d,
            Err(e) => {
                log::warn!("[vault] dirty list failed: {e}");
                return;
            }
        };
        for key in dirty {
            if let Err(e) = self.upload_account_backup(&key).await {
                log::warn!("[vault] backup drain of {key} failed: {e}");
            }
        }
    }

    /// Delete an account's cloud blob (on local removal) so it isn't restored on a
    /// new device. Best-effort: looks the blob up by (provider, email) and DELETEs it.
    pub async fn delete_account_backup(&self, provider: &str, email: &str) -> Result<()> {
        if !self.has_cloud_bearer().await {
            return Ok(());
        }
        for meta_with_key in self.list_cloud_backups_with_keys().await? {
            if meta_with_key.1.provider == provider && meta_with_key.1.external_email == email {
                let _ = self
                    .rails_request(
                        reqwest::Method::DELETE,
                        &format!("stored-credentials/{}", meta_with_key.0),
                        None,
                        "vault delete",
                    )
                    .await;
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Pull / restore
    // -----------------------------------------------------------------------

    /// Metadata of every cloud-backed credential for the signed-in user.
    pub async fn list_cloud_backups(&self) -> Result<Vec<CloudBackupMeta>> {
        Ok(self
            .list_cloud_backups_with_keys()
            .await?
            .into_iter()
            .map(|(_, m)| m)
            .collect())
    }

    async fn list_cloud_backups_with_keys(&self) -> Result<Vec<(String, CloudBackupMeta)>> {
        self.require_bearer().await?;
        let resp = self
            .rails_request(reqwest::Method::GET, "stored-credentials", None, "vault list")
            .await?;
        let data: serde_json::Value = resp.json().await.unwrap_or_default();
        let rows = data
            .get("stored_credentials")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(rows
            .into_iter()
            .filter_map(|r| {
                Some((
                    r.get("id")?.as_str()?.to_string(),
                    CloudBackupMeta {
                        provider: r.get("provider")?.as_str()?.to_string(),
                        external_email: r.get("external_email")?.as_str()?.to_string(),
                        blob_version: r.get("blob_version").and_then(|v| v.as_i64()).unwrap_or(0),
                    },
                ))
            })
            .collect())
    }

    /// Restore all cloud-backed credentials on a new device: unlock with the password,
    /// decrypt each blob, recreate the account + credentials locally, and connect
    /// (a fresh initial sync — no OAuth). Returns how many accounts were restored.
    pub async fn restore_from_cloud(&self, password: &str) -> Result<u32> {
        self.require_bearer().await?;
        let user_id = self.fetch_cloud_user_id().await?;

        // Fetch the vault, derive the KEK, unwrap the DEK.
        let resp = self
            .rails_request(
                reqwest::Method::GET,
                "stored-credentials/vault",
                None,
                "vault fetch",
            )
            .await?;
        let v: serde_json::Value = resp.json().await.unwrap_or_default();
        let v = v
            .get("vault")
            .ok_or_else(|| SyncError::Other("no vault to restore".into()))?;
        let salt = B64
            .decode(v.get("argon_salt").and_then(|x| x.as_str()).unwrap_or("").trim())
            .map_err(|e| SyncError::Encryption(format!("salt decode: {e}")))?;
        let params: ArgonParams = serde_json::from_value(
            v.get("argon_params").cloned().unwrap_or_default(),
        )
        .unwrap_or_default();
        let packed = v
            .get("passphrase_wrapped_dek")
            .and_then(|x| x.as_str())
            .ok_or_else(|| SyncError::Other("vault missing password copy".into()))?;
        let (pw_nonce, pw_ct) = unpack(packed)?;

        let kek = vault::derive_kek(password, &salt, &params)?;
        let dek = vault::unwrap_key(&kek, &pw_ct, &pw_nonce)
            .map_err(|_| SyncError::Other("incorrect inbox2 password".into()))?;

        // Persist local vault state (re-wrap a device copy for this device) + cache DEK.
        let (dev_ct, dev_nonce) = self.store().device_wrap_dek(dek.as_ref())?;
        let params_json = serde_json::to_string(&params).unwrap_or_default();
        self.store().save_vault_state(&VaultState {
            enabled: true,
            vault_key: v.get("id").and_then(|x| x.as_str()).map(str::to_string),
            bound_user_id: Some(user_id),
            device_wrapped_dek: Some(dev_ct),
            device_wrapped_nonce: Some(dev_nonce),
            passphrase_wrapped_dek: Some(pw_ct),
            passphrase_wrapped_nonce: Some(pw_nonce),
            argon_salt: Some(salt),
            argon_params: Some(params_json),
        })?;
        self.set_dek(Some(dek.clone()));

        // Pull every blob, decrypt, recreate the account + creds, connect.
        let metas = self.list_cloud_backups_with_keys().await?;
        let mut restored = 0u32;
        for (key, _meta) in metas {
            match self.restore_one(&key, &dek).await {
                Ok(true) => restored += 1,
                Ok(false) => {}
                Err(e) => log::warn!("[vault] restore of {key} failed: {e}"),
            }
        }
        Ok(restored)
    }

    /// Fetch + decrypt one blob and recreate the account locally. Returns whether an
    /// account was created/updated.
    async fn restore_one(&self, scr_key: &str, dek: &zeroize::Zeroizing<[u8; 32]>) -> Result<bool> {
        let resp = self
            .rails_request(
                reqwest::Method::GET,
                &format!("stored-credentials/{scr_key}"),
                None,
                "vault blob",
            )
            .await?;
        let data: serde_json::Value = resp.json().await.unwrap_or_default();
        let row = data
            .get("stored_credential")
            .ok_or_else(|| SyncError::Other("blob missing".into()))?;
        let ct = B64
            .decode(row.get("blob").and_then(|x| x.as_str()).unwrap_or("").trim())
            .map_err(|e| SyncError::Encryption(format!("blob decode: {e}")))?;
        let nonce = B64
            .decode(row.get("blob_nonce").and_then(|x| x.as_str()).unwrap_or("").trim())
            .map_err(|e| SyncError::Encryption(format!("nonce decode: {e}")))?;
        let bundle = vault::decrypt_bundle(dek, &ct, &nonce)?;

        let provider = ProviderType::from_str(&bundle.provider_type)
            .ok_or_else(|| SyncError::Other(format!("unknown provider {}", bundle.provider_type)))?;
        let creds: ProviderCredentials = bundle.credentials.into();

        // Recreate the account row (idempotent upsert by email+provider).
        let account = ExternalAccount {
            key: String::new(),
            display_name: bundle.display_name,
            email_address: bundle.email_address,
            provider_type: provider.clone(),
            host: bundle.host.clone(),
            port: bundle.port,
            use_tls: bundle.use_tls,
            smtp_host: bundle.smtp_host,
            smtp_port: bundle.smtp_port,
            smtp_use_tls: bundle.smtp_use_tls,
            auth_method: bundle.auth_method.clone(),
            status: crate::sync::model::AccountStatus::Disconnected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: bundle.avatar_url,
        };
        let key = self.store().create_account(&account)?;
        self.store().store_credentials(&key, &creds)?;
        // Restored accounts stay cloud-backed (don't re-upload — clean, just mark enabled).
        self.store().set_account_backup_enabled(&key, true)?;

        // Register + connect so it starts a fresh initial sync (no OAuth).
        let host = account.host.unwrap_or_default();
        let port = account.port.unwrap_or(0);
        let _ = AuthMethod::from_str(&bundle.auth_method); // validated above; kept for clarity
        self.add_account(&key, &provider, &host, port, account.use_tls, creds)
            .await?;
        if let Err(e) = self.connect_and_sync(&key).await {
            log::warn!("[vault] connect after restore of {key} failed: {e}");
        }
        Ok(true)
    }

    // -----------------------------------------------------------------------
    // Rails vault metadata upsert
    // -----------------------------------------------------------------------

    async fn upsert_vault_on_rails(
        &self,
        pw_nonce: &[u8],
        pw_ct: &[u8],
        salt: &[u8],
        params_json: &str,
    ) -> Result<String> {
        let params: serde_json::Value =
            serde_json::from_str(params_json).unwrap_or(serde_json::Value::Null);
        let body = serde_json::json!({
            "passphrase_wrapped_dek": pack(pw_nonce, pw_ct),
            "argon_salt": B64.encode(salt),
            "argon_params": params,
        });
        let resp = self
            .rails_request(
                reqwest::Method::PUT,
                "stored-credentials/vault",
                Some(&body),
                "vault upsert",
            )
            .await?;
        let data: serde_json::Value = resp.json().await.unwrap_or_default();
        Ok(data
            .get("vault")
            .and_then(|v| v.get("id"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string())
    }

    fn salt_params(&self, state: &VaultState) -> Result<(Vec<u8>, ArgonParams)> {
        let salt = state
            .argon_salt
            .clone()
            .ok_or_else(|| SyncError::Other("vault missing salt".into()))?;
        let params: ArgonParams = state
            .argon_params
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default();
        Ok((salt, params))
    }

    fn passphrase_copy(&self, state: &VaultState) -> Result<(Vec<u8>, Vec<u8>)> {
        let nonce = state
            .passphrase_wrapped_nonce
            .clone()
            .ok_or_else(|| SyncError::Other("vault missing password nonce".into()))?;
        let ct = state
            .passphrase_wrapped_dek
            .clone()
            .ok_or_else(|| SyncError::Other("vault missing password copy".into()))?;
        Ok((nonce, ct))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::engine::SyncEngine;
    use crate::sync::events::NullSink;
    use crate::sync::model::{AccountStatus, AuthMethod};
    use crate::sync::store::SyncStore;
    use std::sync::Arc;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    async fn engine_with_store(store: Arc<SyncStore>, base: &str) -> SyncEngine {
        let engine = SyncEngine::new(store, Arc::new(NullSink));
        // Non-empty bearer so has_cloud_bearer() passes.
        engine
            .set_api_context(base.to_string(), "ink_test".to_string())
            .await;
        engine
    }

    fn seed_gmail_account(store: &SyncStore, token: &str) -> String {
        let key = store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: "Me".into(),
                email_address: "me@gmail.com".into(),
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
            .unwrap();
        store
            .store_credentials(
                &key,
                &ProviderCredentials::OAuth2 {
                    username: "me@gmail.com".into(),
                    access_token: token.into(),
                    refresh_token: Some("refresh-xyz".into()),
                },
            )
            .unwrap();
        store.set_account_backup_enabled(&key, true).unwrap();
        key
    }

    async fn mount_vault_endpoints(server: &MockServer) {
        Mock::given(method("GET"))
            .and(path("/account"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "account": { "id": "usr_test" }
                })),
            )
            .mount(server)
            .await;
        Mock::given(method("PUT"))
            .and(path("/stored-credentials/vault"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(serde_json::json!({ "vault": { "id": "vlt_x" } })),
            )
            .mount(server)
            .await;
        Mock::given(method("PUT"))
            .and(path("/stored-credentials"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "stored_credential": { "provider": "gmail", "external_email": "me@gmail.com" }
            })))
            .mount(server)
            .await;
    }

    #[tokio::test]
    async fn enable_uploads_vault_and_ciphertext_blob() {
        let server = MockServer::start().await;
        mount_vault_endpoints(&server).await;

        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let key = seed_gmail_account(&store, "secret-token-xyz");
        let engine = engine_with_store(store.clone(), &server.uri()).await;

        let vault_key = engine.enable_cloud_backup("hunter2-correct").await.unwrap();
        assert_eq!(vault_key, "vlt_x");

        // Vault is enabled + unlocked locally; the account's dirty flag was cleared.
        let status = engine.vault_status().unwrap();
        assert!(status.enabled && status.unlocked);
        assert_eq!(status.account_count, 1);
        assert!(store.list_dirty_backup_accounts().unwrap().is_empty());
        assert_eq!(store.get_vault_state().unwrap().unwrap().bound_user_id.as_deref(), Some("usr_test"));
        let _ = key;

        // Zero-knowledge: NO request body may carry the plaintext token.
        let reqs = server.received_requests().await.unwrap();
        for r in &reqs {
            assert!(
                !String::from_utf8_lossy(&r.body).contains("secret-token-xyz"),
                "plaintext token leaked in a request body"
            );
        }
        // The credential blob upload happened, carrying ciphertext metadata.
        let blob_put = reqs
            .iter()
            .find(|r| {
                serde_json::from_slice::<serde_json::Value>(&r.body)
                    .ok()
                    .and_then(|b| b.get("blob").and_then(|v| v.as_str().map(str::to_string)))
                    .is_some()
            })
            .expect("a credential blob was uploaded");
        let body: serde_json::Value = serde_json::from_slice(&blob_put.body).unwrap();
        assert_eq!(body["provider"], "gmail");
        assert_eq!(body["external_email"], "me@gmail.com");
        assert!(!body["blob"].as_str().unwrap().is_empty());
    }

    #[tokio::test]
    async fn enable_backfills_preexisting_unflagged_accounts() {
        // The upgrade case: a channel was connected BEFORE any inbox2 account, so
        // its cloud_backup flag is off. Turning on the vault must back it up anyway.
        let server = MockServer::start().await;
        mount_vault_endpoints(&server).await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());

        // Seed WITHOUT flagging it for backup.
        let key = store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: "Pre".into(),
                email_address: "pre@gmail.com".into(),
                provider_type: ProviderType::Gmail,
                host: None, port: None, use_tls: true,
                smtp_host: None, smtp_port: None, smtp_use_tls: true,
                auth_method: AuthMethod::OAuth2.as_str().to_string(),
                status: AccountStatus::Disconnected,
                error_message: None, last_connected_at: None, sort_order: 0, avatar_url: None,
            })
            .unwrap();
        store
            .store_credentials(&key, &ProviderCredentials::OAuth2 {
                username: "pre@gmail.com".into(), access_token: "pre-token".into(),
                refresh_token: Some("pre-rt".into()),
            })
            .unwrap();
        assert!(!store.account_backup_enabled(&key).unwrap());

        let engine = engine_with_store(store.clone(), &server.uri()).await;
        engine.enable_cloud_backup("pw").await.unwrap();

        // The pre-existing account is now flagged + backed up (dirty cleared).
        assert!(store.account_backup_enabled(&key).unwrap());
        assert_eq!(engine.vault_status().unwrap().account_count, 1);
        assert!(store.list_dirty_backup_accounts().unwrap().is_empty());
    }

    #[tokio::test]
    async fn unlock_and_device_unlock_round_trip() {
        let server = MockServer::start().await;
        mount_vault_endpoints(&server).await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        seed_gmail_account(&store, "secret-token-xyz");
        let engine = engine_with_store(store.clone(), &server.uri()).await;
        engine.enable_cloud_backup("right-pass").await.unwrap();

        // Simulate a fresh process: drop the in-memory DEK, then re-unlock.
        engine.set_dek(None);
        assert!(!engine.vault_status().unwrap().unlocked);

        // Device-key copy unlocks transparently (same device).
        assert!(engine.try_device_unlock());
        assert!(engine.vault_status().unwrap().unlocked);

        // Password unlock also works; the wrong password fails.
        engine.set_dek(None);
        assert!(engine.unlock_vault("wrong-pass").await.is_err());
        assert!(engine.unlock_vault("right-pass").await.is_ok());
        assert!(engine.vault_status().unwrap().unlocked);
    }

    #[tokio::test]
    async fn clear_vault_session_locks_and_disables() {
        let server = MockServer::start().await;
        mount_vault_endpoints(&server).await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let key = seed_gmail_account(&store, "tok");
        let engine = engine_with_store(store.clone(), &server.uri()).await;
        engine.enable_cloud_backup("pw").await.unwrap();

        engine.clear_vault_session();

        assert!(!engine.vault_status().unwrap().unlocked);
        assert!(store.get_vault_state().unwrap().is_none());
        // Account backup flag is reset so nothing uploads to a different identity.
        assert!(!store.account_backup_enabled(&key).unwrap());
    }
}
