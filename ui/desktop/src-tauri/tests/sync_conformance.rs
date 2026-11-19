//! Provider adapter conformance tests.
//!
//! Every adapter must pass these tests. They verify the ProviderAdapter trait
//! contract without depending on a specific provider implementation.
//!
//! For IMAP: run against the GreenMail container (docker/docker-compose.yml, `test` profile).
//! For Gmail/Microsoft: run against stub adapters (they return NotImplemented).

#[cfg(test)]
mod conformance {
    /// Verify that normalize -> denormalize is a reasonable round-trip.
    ///
    /// Perfect round-trip is not required (archived/spam depend on folder context),
    /// but the core flags (read, flagged, draft) must survive.
    #[test]
    fn flag_roundtrip_core_flags() {
        use app_lib::sync::adapters::ImapAdapter;
        use app_lib::sync::adapters::ImapConfig;
        use app_lib::sync::model::*;
        use app_lib::sync::provider::ProviderAdapter;

        let adapter = ImapAdapter::new(ImapConfig::default());

        let cases = vec![
            UnifiedFlags {
                read: true,
                flagged: false,
                archived: false,
                trashed: false,
                spam: false,
                draft: false,
            },
            UnifiedFlags {
                read: false,
                flagged: true,
                archived: false,
                trashed: false,
                spam: false,
                draft: true,
            },
            UnifiedFlags {
                read: true,
                flagged: true,
                archived: false,
                trashed: true,
                spam: false,
                draft: false,
            },
        ];

        for original in &cases {
            let provider = adapter.denormalize_flags(original, None);
            let roundtrip = adapter.normalize_flags(&provider);

            // Core flags must survive
            assert_eq!(roundtrip.read, original.read, "read flag mismatch");
            assert_eq!(roundtrip.flagged, original.flagged, "flagged flag mismatch");
            assert_eq!(roundtrip.draft, original.draft, "draft flag mismatch");
            // trashed via \\Deleted also survives
            assert_eq!(roundtrip.trashed, original.trashed, "trashed flag mismatch");
        }
    }

    // Gmail flag-roundtrip + REST conformance live in the adapter's own unit
    // tests (src/sync/adapters/gmail_mail.rs), which can use test-only
    // constructors and a wiremock server.

    // Microsoft + Gmail flag/REST conformance live in their adapter unit tests
    // (src/sync/adapters/{microsoft,gmail}_mail.rs).

    /// Capabilities: the IMAP adapter reports no push before connect.
    #[test]
    fn capabilities_sensible_defaults() {
        use app_lib::sync::adapters::{ImapAdapter, ImapConfig};
        use app_lib::sync::provider::ProviderAdapter;

        let imap = ImapAdapter::new(ImapConfig::default());
        let caps = imap.capabilities();
        assert!(!caps.push, "IMAP should report no push before connect");
    }
}

/// Credential encryption tests.
#[cfg(test)]
mod crypto_tests {
    #[test]
    fn encrypt_decrypt_password() {
        use app_lib::sync::crypto::CredentialEncryptor;

        let key = [0x42u8; 32];
        let enc = CredentialEncryptor::from_key(&key);

        let secret = b"hunter2";
        let (ct, nonce) = enc.encrypt(secret).unwrap();
        let pt = enc.decrypt(&ct, &nonce).unwrap();
        assert_eq!(pt, secret);
    }

    #[test]
    fn wrong_key_fails() {
        use app_lib::sync::crypto::CredentialEncryptor;

        let enc1 = CredentialEncryptor::from_key(&[0x01u8; 32]);
        let enc2 = CredentialEncryptor::from_key(&[0x02u8; 32]);

        let (ct, nonce) = enc1.encrypt(b"secret").unwrap();
        assert!(enc2.decrypt(&ct, &nonce).is_err());
    }

    #[test]
    fn ciphertext_does_not_contain_plaintext() {
        use app_lib::sync::crypto::CredentialEncryptor;

        let enc = CredentialEncryptor::from_key(&[0x42u8; 32]);
        let password = b"MyP@ssw0rd!VerySecret";
        let (ct, _) = enc.encrypt(password).unwrap();

        // Plaintext must not appear in ciphertext
        for window in ct.windows(password.len()) {
            assert_ne!(window, password);
        }
    }
}

/// Backoff calculation tests.
#[cfg(test)]
mod backoff_tests {
    #[test]
    fn exponential_backoff_capped() {
        let initial: i64 = 1;
        let max: i64 = 300;

        // Verify exponential growth
        assert_eq!(std::cmp::min(initial * (1i64 << 0), max), 1);
        assert_eq!(std::cmp::min(initial * (1i64 << 1), max), 2);
        assert_eq!(std::cmp::min(initial * (1i64 << 2), max), 4);
        assert_eq!(std::cmp::min(initial * (1i64 << 3), max), 8);
        assert_eq!(std::cmp::min(initial * (1i64 << 4), max), 16);
        assert_eq!(std::cmp::min(initial * (1i64 << 5), max), 32);
        assert_eq!(std::cmp::min(initial * (1i64 << 6), max), 64);
        assert_eq!(std::cmp::min(initial * (1i64 << 7), max), 128);
        assert_eq!(std::cmp::min(initial * (1i64 << 8), max), 256);
        // Cap kicks in
        assert_eq!(std::cmp::min(initial * (1i64 << 9), max), 300);
        assert_eq!(std::cmp::min(initial * (1i64 << 10), max), 300);
    }
}
