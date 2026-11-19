//! Zero-knowledge cloud credential vault — crypto core (see docs/E2EE.md).
//!
//! Channel credentials are backed up to the prod Rails DB as opaque ciphertext so
//! a new device can restore them without redoing OAuth. The server never holds a
//! usable key. The scheme is a double envelope:
//!
//!   * a random 32-byte **DEK** encrypts each account's [`CredentialBundle`]
//!     (AES-256-GCM, via the existing [`CredentialEncryptor`]);
//!   * the DEK is wrapped twice — once under the device's OS-keychain key (for
//!     transparent same-device unlock, done in `store::vault` with the store's own
//!     encryptor) and once under `KEK = Argon2id(inbox2_password, salt)` (for
//!     cross-device restore, the [`wrap_key`]/[`unwrap_key`] + [`derive_kek`] here).
//!
//! This module is pure (no I/O, no DB) so it unit-tests in isolation. All key
//! material is held in [`Zeroizing`] so it's wiped on drop and never logged.

use argon2::{Algorithm, Argon2, Params, Version};
use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::sync::crypto::CredentialEncryptor;
use crate::sync::error::{Result, SyncError};
use crate::sync::model::CredentialPayload;

/// DEK / KEK length (AES-256).
pub const KEY_LEN: usize = 32;
/// Argon2id salt length.
pub const SALT_LEN: usize = 16;

/// Argon2id parameters, persisted alongside the password-wrapped DEK so any device
/// can re-derive the KEK. Defaults are mobile-safe (64 MiB / 3 passes) and can be
/// tuned later without breaking existing blobs (each vault carries its own params).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArgonParams {
    pub mem_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}

impl Default for ArgonParams {
    fn default() -> Self {
        Self {
            mem_kib: 65536, // 64 MiB
            iterations: 3,
            parallelism: 1,
        }
    }
}

/// The per-account payload encrypted under the DEK. Carries the credentials plus
/// the account config needed to recreate the account on a new device WITHOUT
/// OAuth. Sync cursors / folder state are deliberately excluded — a restored
/// device runs a fresh initial sync. `credentials` reuses the same opt-in
/// [`CredentialPayload`] the local store serializes.
#[derive(Serialize, Deserialize)]
pub(crate) struct CredentialBundle {
    pub provider_type: String,
    pub email_address: String,
    pub display_name: String,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub use_tls: bool,
    pub smtp_host: Option<String>,
    pub smtp_port: Option<u16>,
    pub smtp_use_tls: bool,
    pub auth_method: String,
    pub avatar_url: Option<String>,
    pub credentials: CredentialPayload,
}

/// A fresh random 16-byte Argon2id salt.
pub fn new_salt() -> [u8; SALT_LEN] {
    let mut salt = [0u8; SALT_LEN];
    OsRng.fill_bytes(&mut salt);
    salt
}

/// A fresh random 32-byte DEK. Held in [`Zeroizing`] so it's wiped on drop.
pub fn new_dek() -> Zeroizing<[u8; KEY_LEN]> {
    let mut dek = Zeroizing::new([0u8; KEY_LEN]);
    OsRng.fill_bytes(dek.as_mut());
    dek
}

/// Derive the key-encryption key from the user's inbox2 password via Argon2id.
/// The password never leaves the device; only the password-wrapped DEK + this
/// salt + params reach the server (all useless without the password).
pub fn derive_kek(
    password: &str,
    salt: &[u8],
    params: &ArgonParams,
) -> Result<Zeroizing<[u8; KEY_LEN]>> {
    let cfg = Params::new(
        params.mem_kib,
        params.iterations,
        params.parallelism,
        Some(KEY_LEN),
    )
    .map_err(|e| SyncError::Encryption(format!("argon2 params: {e}")))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, cfg);

    let mut kek = Zeroizing::new([0u8; KEY_LEN]);
    argon
        .hash_password_into(password.as_bytes(), salt, kek.as_mut())
        .map_err(|e| SyncError::Encryption(format!("argon2 derive: {e}")))?;
    Ok(kek)
}

/// Wrap (encrypt) the DEK under a wrapping key (the device key or a KEK), returning
/// (ciphertext, nonce).
pub fn wrap_key(wrapping_key: &[u8; KEY_LEN], dek: &[u8; KEY_LEN]) -> Result<(Vec<u8>, Vec<u8>)> {
    CredentialEncryptor::from_key(wrapping_key).encrypt(dek)
}

/// Unwrap (decrypt) the DEK with a wrapping key. A wrong password / key fails the
/// AEAD tag check and returns an error rather than garbage.
pub fn unwrap_key(
    wrapping_key: &[u8; KEY_LEN],
    ciphertext: &[u8],
    nonce: &[u8],
) -> Result<Zeroizing<[u8; KEY_LEN]>> {
    let plain = CredentialEncryptor::from_key(wrapping_key).decrypt(ciphertext, nonce)?;
    if plain.len() != KEY_LEN {
        return Err(SyncError::Encryption("unwrapped DEK wrong length".into()));
    }
    let mut dek = Zeroizing::new([0u8; KEY_LEN]);
    dek.copy_from_slice(&plain);
    Ok(dek)
}

/// Encrypt a credential bundle under the DEK, returning (ciphertext, nonce).
pub(crate) fn encrypt_bundle(
    dek: &[u8; KEY_LEN],
    bundle: &CredentialBundle,
) -> Result<(Vec<u8>, Vec<u8>)> {
    let plaintext = serde_json::to_vec(bundle)
        .map_err(|e| SyncError::Encryption(format!("serialize bundle: {e}")))?;
    CredentialEncryptor::from_key(dek).encrypt(&plaintext)
}

/// Decrypt a credential bundle with the DEK.
pub(crate) fn decrypt_bundle(
    dek: &[u8; KEY_LEN],
    ciphertext: &[u8],
    nonce: &[u8],
) -> Result<CredentialBundle> {
    let plaintext = CredentialEncryptor::from_key(dek).decrypt(ciphertext, nonce)?;
    serde_json::from_slice(&plaintext)
        .map_err(|e| SyncError::Encryption(format!("deserialize bundle: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::model::CredentialPayload;

    fn sample_bundle() -> CredentialBundle {
        CredentialBundle {
            provider_type: "gmail".into(),
            email_address: "me@gmail.com".into(),
            display_name: "Me".into(),
            host: None,
            port: None,
            use_tls: true,
            smtp_host: None,
            smtp_port: None,
            smtp_use_tls: true,
            auth_method: "xoauth2".into(),
            avatar_url: None,
            credentials: CredentialPayload::OAuth2 {
                username: "me@gmail.com".into(),
                access_token: "ya29.secret-access".into(),
                refresh_token: Some("1//refresh-secret".into()),
            },
        }
    }

    #[test]
    fn dek_round_trips_through_password_wrap() {
        let dek = new_dek();
        let salt = new_salt();
        let params = ArgonParams::default();
        let kek = derive_kek("hunter2-correct-horse", &salt, &params).unwrap();

        let (ct, nonce) = wrap_key(&kek, &dek).unwrap();
        let unwrapped = unwrap_key(&kek, &ct, &nonce).unwrap();
        assert_eq!(unwrapped.as_ref(), dek.as_ref());
    }

    #[test]
    fn wrong_password_fails_to_unwrap() {
        let dek = new_dek();
        let salt = new_salt();
        let params = ArgonParams::default();
        let kek = derive_kek("right-password", &salt, &params).unwrap();
        let (ct, nonce) = wrap_key(&kek, &dek).unwrap();

        let wrong = derive_kek("wrong-password", &salt, &params).unwrap();
        assert!(unwrap_key(&wrong, &ct, &nonce).is_err());
    }

    #[test]
    fn kek_derivation_is_deterministic_for_fixed_salt() {
        let salt = [7u8; SALT_LEN];
        let params = ArgonParams::default();
        let a = derive_kek("pw", &salt, &params).unwrap();
        let b = derive_kek("pw", &salt, &params).unwrap();
        assert_eq!(a.as_ref(), b.as_ref());
        // A different salt yields a different KEK.
        let c = derive_kek("pw", &[9u8; SALT_LEN], &params).unwrap();
        assert_ne!(a.as_ref(), c.as_ref());
    }

    #[test]
    fn bundle_round_trips_under_dek() {
        let dek = new_dek();
        let bundle = sample_bundle();
        let (ct, nonce) = encrypt_bundle(&dek, &bundle).unwrap();

        // The ciphertext must not leak the secret token.
        assert!(!String::from_utf8_lossy(&ct).contains("ya29.secret-access"));

        let back = decrypt_bundle(&dek, &ct, &nonce).unwrap();
        assert_eq!(back.email_address, "me@gmail.com");
        assert_eq!(back.provider_type, "gmail");
        match back.credentials {
            CredentialPayload::OAuth2 {
                access_token,
                refresh_token,
                ..
            } => {
                assert_eq!(access_token, "ya29.secret-access");
                assert_eq!(refresh_token.as_deref(), Some("1//refresh-secret"));
            }
            _ => panic!("expected OAuth2 payload"),
        }
    }

    #[test]
    fn meta_and_password_bundles_round_trip() {
        let dek = new_dek();

        let pw = CredentialBundle {
            provider_type: "imap".into(),
            email_address: "u@imap.test".into(),
            display_name: "IMAP".into(),
            host: Some("imap.test".into()),
            port: Some(993),
            use_tls: true,
            smtp_host: Some("smtp.test".into()),
            smtp_port: Some(465),
            smtp_use_tls: true,
            auth_method: "plain".into(),
            avatar_url: None,
            credentials: CredentialPayload::Password {
                username: "u@imap.test".into(),
                password: "imap-secret".into(),
            },
        };
        let (ct, n) = encrypt_bundle(&dek, &pw).unwrap();
        let back = decrypt_bundle(&dek, &ct, &n).unwrap();
        assert_eq!(back.host.as_deref(), Some("imap.test"));
        assert!(matches!(back.credentials, CredentialPayload::Password { .. }));
    }

    #[test]
    fn wrong_dek_cannot_decrypt_bundle() {
        let dek = new_dek();
        let other = new_dek();
        let (ct, nonce) = encrypt_bundle(&dek, &sample_bundle()).unwrap();
        assert!(decrypt_bundle(&other, &ct, &nonce).is_err());
    }
}
