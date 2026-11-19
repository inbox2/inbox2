use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Nonce};
use rand::RngCore;

use crate::sync::error::{Result, SyncError};

const KEY_LEN: usize = 32; // AES-256
const NONCE_LEN: usize = 12; // GCM standard nonce

/// Device-bound encryption key for OAuth tokens / IMAP passwords at rest.
///
/// With the `os-keychain` feature (desktop) the 32-byte AES-256 key lives in the
/// OS keystore (macOS Keychain / Windows credential store / Linux Secret Service)
/// — never in a plaintext file beside the ciphertext DB. Without the feature
/// (mobile, which has no keyring backend) the key is the owner-only key file.
///
/// ponytail: debug builds also take the file path. `tauri dev` produces an
/// ad-hoc (linker-signed) binary whose cdhash changes on every rebuild, so the
/// Keychain ACL "Always Allow" grant — which pins that code identity — is void
/// after the next `cargo build` and macOS re-prompts for the login password
/// every single run. Release builds are properly signed, keep a stable
/// designated requirement, and use the keystore as before.
pub struct CredentialEncryptor {
    cipher: Aes256Gcm,
}

/// Keystore identity for the credential master key. Gated on `not(test)` as well
/// as the feature: `cargo test --workspace` unifies features, so without this a
/// core unit test would compile (and run) the keystore path and pop a real
/// Keychain prompt / break headless CI. Tests always use the file backend.
// Derived from BUNDLE_ID so a side-by-side dev build (`com.inbox2.desktop.dev`)
// gets its own credential master key instead of sharing prod's.
// Not gated on `not(debug_assertions)`: the release arm READS the keystore, and the
// debug arm still has to read it once to adopt an existing key (see
// `adopt_keystore_key`). One definition, both arms.
#[cfg(all(feature = "os-keychain", not(test)))]
const KEYCHAIN_SERVICE: &str = crate::BUNDLE_ID;
#[cfg(all(feature = "os-keychain", not(test)))]
const KEYCHAIN_USER: &str = "credential-key";

impl CredentialEncryptor {
    /// Create an encryptor from the credential master key, loading it from the OS
    /// keystore (feature `os-keychain`) or the app-data key file.
    pub fn new(app_data_dir: &std::path::Path) -> Result<Self> {
        Self::for_store(app_data_dir, !app_data_dir.join("inbox2.db").exists())
    }

    /// Like `new`, told by the caller whether the store is brand new. `SyncStore::new`
    /// opens the database before it builds the encryptor, so it decides this before
    /// the open; the Linux keyring fallback (see `load_or_create_key`) relies on it.
    pub fn for_store(app_data_dir: &std::path::Path, fresh_store: bool) -> Result<Self> {
        let key_bytes = load_or_create_key(app_data_dir, fresh_store)?;
        let key = aes_gcm::Key::<Aes256Gcm>::from_slice(&key_bytes);
        let cipher = Aes256Gcm::new(key);
        Ok(Self { cipher })
    }

    /// Create an encryptor from raw key bytes (for testing).
    pub fn from_key(key_bytes: &[u8; KEY_LEN]) -> Self {
        let key = aes_gcm::Key::<Aes256Gcm>::from_slice(key_bytes);
        let cipher = Aes256Gcm::new(key);
        Self { cipher }
    }

    /// An encryptor with a fresh random key and NO persistence — for ephemeral
    /// in-memory stores (tests, the triage-eval harness). It deliberately never
    /// touches the OS keystore or the filesystem, so the desktop test build
    /// (which enables `os-keychain`) doesn't pop a Keychain prompt and CI stays
    /// headless-safe.
    pub fn ephemeral() -> Self {
        let mut key = [0u8; KEY_LEN];
        OsRng.fill_bytes(&mut key);
        Self::from_key(&key)
    }

    /// Encrypt plaintext, returning (ciphertext, nonce).
    pub fn encrypt(&self, plaintext: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
        let mut nonce_bytes = [0u8; NONCE_LEN];
        OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = self
            .cipher
            .encrypt(nonce, plaintext)
            .map_err(|e| SyncError::Encryption(format!("encrypt: {e}")))?;

        Ok((ciphertext, nonce_bytes.to_vec()))
    }

    /// Decrypt ciphertext using the provided nonce.
    pub fn decrypt(&self, ciphertext: &[u8], nonce_bytes: &[u8]) -> Result<Vec<u8>> {
        if nonce_bytes.len() != NONCE_LEN {
            return Err(SyncError::Encryption("invalid nonce length".into()));
        }
        let nonce = Nonce::from_slice(nonce_bytes);

        self.cipher
            .decrypt(nonce, ciphertext)
            .map_err(|e| SyncError::Encryption(format!("decrypt: {e}")))
    }
}

/// Resolve the credential master key from the OS keystore (desktop release build).
///
/// Linux: the Secret Service needs a running keyring daemon with an unlocked default
/// collection (gnome-keyring, KWallet). Without one every call errors and the app
/// could not open its database at all (seen 2026-11-07 on a fresh KDE session:
/// "No default store has been set"). So on Linux a keyring failure on a FRESH store
/// falls back to the owner-only key file, and once that file exists it stays the key.
/// A store whose key came from the keyring (marked by `.credential_keyring`) never
/// switches: a passing keyring outage must not mint a new key and leave every stored
/// credential undecryptable, so there the failure propagates and the caller retries.
#[cfg(all(feature = "os-keychain", not(test), not(debug_assertions)))]
fn load_or_create_key(app_data_dir: &std::path::Path, fresh_store: bool) -> Result<Vec<u8>> {
    #[cfg(target_os = "linux")]
    {
        if app_data_dir.join(".credential_key").exists() {
            return load_or_create_file_key(app_data_dir);
        }
        let keyring_marker = app_data_dir.join(".credential_keyring");
        // Fresh store = no marker AND no database yet (the caller checked that before
        // opening it). An install from before the marker existed has a database whose
        // credentials were encrypted with the keyring key; a fallback there would mint
        // a second key and strand them.
        let fresh_store = fresh_store && !keyring_marker.exists();
        match keystore_key() {
            Ok(key) => {
                let _ = std::fs::create_dir_all(app_data_dir);
                if let Err(e) = std::fs::write(&keyring_marker, b"") {
                    log::warn!("[crypto] could not write {}: {e}", keyring_marker.display());
                }
                Ok(key)
            }
            Err(SyncError::Encryption(msg)) if fresh_store => {
                log::warn!("[crypto] OS keyring unavailable ({msg}); using the owner-only key file");
                load_or_create_file_key(app_data_dir)
            }
            Err(SyncError::Encryption(msg)) => Err(SyncError::KeychainLocked(format!(
                "keyring unavailable, and this store's key lives there: {msg}"
            ))),
            other => other,
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (app_data_dir, fresh_store);
        keystore_key()
    }
}

/// The keystore read/create itself. `KeychainLocked` is transient (callers retry);
/// `Encryption` is a real failure.
#[cfg(all(feature = "os-keychain", not(test), not(debug_assertions)))]
fn keystore_key() -> Result<Vec<u8>> {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD;

    let entry = keyring::Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_USER)
        .map_err(|e| SyncError::Encryption(format!("keychain entry: {e}")))?;

    match entry.get_password() {
        Ok(stored) => {
            let bytes = b64
                .decode(stored.trim())
                .map_err(|e| SyncError::Encryption(format!("keychain decode: {e}")))?;
            if bytes.len() != KEY_LEN {
                return Err(SyncError::Encryption("keychain key wrong length".into()));
            }
            Ok(bytes)
        }
        // First run: generate a fresh key and store it.
        Err(keyring::Error::NoEntry) => {
            let mut key = vec![0u8; KEY_LEN];
            OsRng.fill_bytes(&mut key);
            entry
                .set_password(&b64.encode(&key))
                .map_err(|e| SyncError::Encryption(format!("keychain set: {e}")))?;
            Ok(key)
        }
        Err(e) => {
            let msg = e.to_string();
            // macOS dark wake (Power Nap / maintenance wake with the display
            // asleep) refuses keychain access with `errSecInteractionNotAllowed`,
            // which keyring surfaces as "Platform secure storage failure: In dark
            // wake, no UI possible". A locked login keychain looks the same. This
            // is transient — the key reads fine once the machine is fully awake —
            // so classify it distinctly and let callers retry instead of treating
            // the (perfectly intact) DB as corrupt.
            if is_keychain_locked(&msg) {
                Err(SyncError::KeychainLocked(format!("keychain get: {msg}")))
            } else {
                Err(SyncError::Encryption(format!("keychain get: {msg}")))
            }
        }
    }
}

/// Whether a keystore read error is the transient "can't reach the keychain right
/// now" condition (macOS dark wake / no-UI context / locked keychain) rather than
/// a genuine failure. Matched on the platform error text because keyring collapses
/// these into an opaque `PlatformFailure`.
#[cfg(all(feature = "os-keychain", not(test), not(debug_assertions)))]
fn is_keychain_locked(msg: &str) -> bool {
    let m = msg.to_ascii_lowercase();
    m.contains("dark wake")
        || m.contains("no ui possible")
        || m.contains("interactionnotallowed")
        || m.contains("interaction not allowed")
        || m.contains("user interaction is not allowed")
        || m.contains("-25308") // errSecInteractionNotAllowed
        || (m.contains("keychain") && m.contains("locked"))
}

/// Resolve the credential master key from the owner-only key file (mobile — no
/// keyring backend — every test build, and every debug build, see the keystore
/// consts above).
#[cfg(any(not(feature = "os-keychain"), test, debug_assertions))]
fn load_or_create_key(app_data_dir: &std::path::Path, _fresh_store: bool) -> Result<Vec<u8>> {
    load_or_create_file_key(app_data_dir)
}

/// The owner-only key file: the key on mobile, debug and test builds, and the
/// fallback on a Linux release build without a usable keyring.
#[cfg(any(not(feature = "os-keychain"), test, debug_assertions, target_os = "linux"))]
fn load_or_create_file_key(app_data_dir: &std::path::Path) -> Result<Vec<u8>> {
    let key_path = app_data_dir.join(".credential_key");
    if key_path.exists() {
        let data =
            std::fs::read(&key_path).map_err(|e| SyncError::Encryption(format!("read key: {e}")))?;
        if data.len() != KEY_LEN {
            return Err(SyncError::Encryption("corrupt key file".into()));
        }
        return Ok(data);
    }
    // No file yet. On a desktop debug build that may mean this install predates the
    // move to the file backend and its real key is still in the OS keystore — mint a
    // fresh one there and every stored credential silently becomes undecryptable
    // (accounts drop out, the cloud session is lost, sync stops with no error). Adopt
    // the keystore key when there is one; only generate when there genuinely isn't.
    let key = match adopt_keystore_key() {
        Some(existing) => existing,
        None => {
            let mut fresh = vec![0u8; KEY_LEN];
            OsRng.fill_bytes(&mut fresh);
            fresh
        }
    };
    if let Some(parent) = key_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| SyncError::Encryption(format!("create dir: {e}")))?;
    }
    // Owner-only from the first byte: the file is created with mode 0600, never
    // written world-readable and chmod'ed afterwards.
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut file = opts
        .open(&key_path)
        .map_err(|e| SyncError::Encryption(format!("create key: {e}")))?;
    std::io::Write::write_all(&mut file, &key)
        .map_err(|e| SyncError::Encryption(format!("write key: {e}")))?;
    #[cfg(unix)]
    {
        // An existing file keeps its old mode on open; pin it too.
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|e| SyncError::Encryption(format!("chmod key: {e}")))?;
    }
    Ok(key)
}

/// One-time adoption of a pre-existing keystore key by a desktop DEBUG build (the
/// only configuration that reads the keystore but writes the file). Any failure —
/// no entry, locked keychain, garbage value — returns `None` so the caller falls
/// back to generating, which is the correct behaviour for a genuinely fresh install.
#[cfg(all(feature = "os-keychain", not(test), debug_assertions))]
fn adopt_keystore_key() -> Option<Vec<u8>> {
    use base64::Engine;
    let stored = keyring::Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_USER)
        .ok()?
        .get_password()
        .ok()?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(stored.trim())
        .ok()?;
    (bytes.len() == KEY_LEN).then(|| {
        log::info!("[crypto] adopted the existing keystore credential key into the key file");
        bytes
    })
}

/// Mobile (no keyring), test and release desktop builds: nothing to adopt. The
/// release build reaches the file arm only on Linux, after the keystore itself
/// failed, so there is no key to read there either.
#[cfg(any(not(feature = "os-keychain"), test, all(not(debug_assertions), target_os = "linux")))]
fn adopt_keystore_key() -> Option<Vec<u8>> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_round_trip() {
        let key = [0x42u8; KEY_LEN];
        let enc = CredentialEncryptor::from_key(&key);

        let plaintext = b"s3cret_p@ssword!";
        let (ciphertext, nonce) = enc.encrypt(plaintext).unwrap();

        assert_ne!(ciphertext, plaintext);
        assert_eq!(nonce.len(), NONCE_LEN);

        let decrypted = enc.decrypt(&ciphertext, &nonce).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn decrypt_wrong_nonce_fails() {
        let key = [0x42u8; KEY_LEN];
        let enc = CredentialEncryptor::from_key(&key);

        let plaintext = b"s3cret_p@ssword!";
        let (ciphertext, _nonce) = enc.encrypt(plaintext).unwrap();

        let wrong_nonce = [0xFFu8; NONCE_LEN];
        assert!(enc.decrypt(&ciphertext, &wrong_nonce).is_err());
    }

    #[test]
    fn decrypt_wrong_key_fails() {
        let key1 = [0x42u8; KEY_LEN];
        let key2 = [0x99u8; KEY_LEN];
        let enc1 = CredentialEncryptor::from_key(&key1);
        let enc2 = CredentialEncryptor::from_key(&key2);

        let plaintext = b"s3cret_p@ssword!";
        let (ciphertext, nonce) = enc1.encrypt(plaintext).unwrap();

        assert!(enc2.decrypt(&ciphertext, &nonce).is_err());
    }

    #[test]
    fn credential_never_in_ciphertext() {
        let key = [0x42u8; KEY_LEN];
        let enc = CredentialEncryptor::from_key(&key);

        let password = b"MySecretPassword123";
        let (ciphertext, _) = enc.encrypt(password).unwrap();

        // The password must not appear in the ciphertext
        let ct_str = String::from_utf8_lossy(&ciphertext);
        assert!(!ct_str.contains("MySecretPassword123"));
    }

    // `new()` must load a STABLE key across instances: ciphertext from the first
    // encryptor decrypts in a second one built afterwards (a regression that
    // re-keys each launch fails here). Test builds always use the file backend
    // (the keystore path is `not(test)`), so this never prompts / is CI-safe.
    #[test]
    fn key_persists_across_instances() {
        let dir = std::env::temp_dir().join(format!("inbox2_crypto_{}", nanoid::nanoid!(12)));
        std::fs::create_dir_all(&dir).unwrap();

        let enc1 = CredentialEncryptor::new(&dir).unwrap();
        let (ciphertext, nonce) = enc1.encrypt(b"s3cret-token").unwrap();

        let enc2 = CredentialEncryptor::new(&dir).unwrap();
        assert_eq!(enc2.decrypt(&ciphertext, &nonce).unwrap(), b"s3cret-token");

        // The non-keystore arm keeps the key in an owner-only file beside the DB.
        let key_file = dir.join(".credential_key");
        assert!(key_file.exists(), "file backend must persist .credential_key");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&key_file).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "key file must stay owner-only");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    // The adoption path only compiles in a desktop debug build, so no test build can
    // execute it either — assert the source instead. Dropping this call is silent and
    // destructive: a dev build on an install that predates the file backend would mint
    // a fresh key, and every stored credential (accounts + cloud session) becomes
    // undecryptable with no error, which is exactly what happened on 2026-08-03.
    #[test]
    fn file_arm_adopts_existing_keystore_key() {
        let src = include_str!("crypto.rs");
        let arm = src
            .split("fn load_or_create_file_key(app_data_dir:")
            .nth(1)
            .expect("load_or_create_file_key not found");
        let body = &arm[..arm.find("\n}\n").expect("unterminated file arm")];
        let adopt = body.find("adopt_keystore_key()").expect("file arm must try the keystore first");
        let generate = body.find("fill_bytes").expect("file arm must be able to generate");
        assert!(adopt < generate, "keystore adoption must precede generating a fresh key");
    }

    // The keystore arm is `not(test)`, so no test build can ever execute it —
    // the only way to stop a future edit from silently downgrading RELEASE
    // builds to the plaintext key file is to assert the gates themselves.
    // Fails if the keychain arm loses the feature/release condition, or if the
    // file arm stops covering test + debug (which would put the Keychain back
    // in `tauri dev` and re-prompt for the login password on every rebuild —
    // ad-hoc dev binaries get a new cdhash each build, voiding "Always Allow").
    #[test]
    fn key_backend_gates_intact() {
        let src = include_str!("crypto.rs");
        let gates: Vec<&str> = src
            .lines()
            .zip(src.lines().skip(1))
            .filter(|(_, def)| def.starts_with("fn load_or_create_key"))
            .map(|(gate, _)| gate.trim())
            .collect();
        assert_eq!(gates.len(), 2, "expected two load_or_create_key arms: {gates:?}");

        // Matched verbatim, not by substring: `not(test)` contains `test`, so a
        // loose check would still pass on an inverted gate. Reordering the
        // predicates trips this too — deliberate, so the change gets re-read.
        let keystore = gates
            .iter()
            .find(|g| g.starts_with("#[cfg(all("))
            .expect("keystore arm gate missing");
        assert_eq!(
            *keystore,
            "#[cfg(all(feature = \"os-keychain\", not(test), not(debug_assertions)))]",
            "release builds must still take the OS keystore"
        );

        let file = gates
            .iter()
            .find(|g| g.starts_with("#[cfg(any("))
            .expect("file arm gate missing");
        assert_eq!(
            *file,
            "#[cfg(any(not(feature = \"os-keychain\"), test, debug_assertions))]",
            "mobile/test/debug builds must still take the key file"
        );
    }
}
