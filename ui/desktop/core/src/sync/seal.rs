//! Opening sealed (E2EE) mail — docs/E2EE.md, docs/MX-Sync.md "Sealed mail".
//!
//! Decrypt only; the core never seals. Interop-locked to the two producers:
//!
//!   * the per-message DEK is a libsodium **sealed box** to the domain public key
//!     (`crypto_box_seal` in `ui/web/src/lib/e2ee.js`, `box.SealAnonymous` in
//!     `mta/internal/seal`);
//!   * header and body are **XChaCha20-Poly1305-IETF** under that DEK, with the
//!     API-served `aad` string bound in verbatim. `sealed_box_v2` bundles (`scheme`
//!     in the bundle) append the part's role: `<aad>|header`, `<aad>|body`.
//!
//! `testdata/sealed_by_go.json` and `sealed_by_js.json` were produced by those two
//! code paths, not by this one: the tests below prove the port against the real
//! senders. Key material lives in [`Zeroizing`] and is never logged.

use base64::Engine as _;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use serde_json::Value;
use zeroize::Zeroizing;

use crate::sync::error::{Result, SyncError};

const B64: base64::engine::general_purpose::GeneralPurpose = base64::engine::general_purpose::STANDARD;

/// A domain keypair the signed-in member holds a grant for. Deliberately neither
/// `Clone` nor `Debug`: one copy, in the engine's key map, wiped on drop.
pub struct DomainKey {
    pub version: i64,
    pub public: [u8; 32],
    pub secret: Zeroizing<[u8; 32]>,
}

impl DomainKey {
    pub fn from_b64(version: i64, public_b64: &str, secret_b64: &str) -> Result<Self> {
        Ok(Self { version, public: key32(public_b64)?, secret: Zeroizing::new(key32(secret_b64)?) })
    }

    pub fn from_grant(version: i64, public_b64: &str, secret: Zeroizing<[u8; 32]>) -> Result<Self> {
        Ok(Self { version, public: key32(public_b64)?, secret })
    }
}

/// A sealed message, opened: the header (`subject`, `from`, `snippet`, …) and the
/// body (`plain`, `html`) exactly as the sender's MX wrote them.
pub struct Opened {
    pub header: Value,
    pub body: Value,
}

fn bad(what: &str) -> SyncError {
    SyncError::Other(format!("sealed mail: {what}"))
}

fn unb64(v: &Value, field: &str) -> Result<Vec<u8>> {
    let s = v.get(field).and_then(Value::as_str).ok_or_else(|| bad(&format!("missing {field}")))?;
    B64.decode(s).map_err(|_| bad(&format!("{field} is not base64")))
}

fn key32(b64: &str) -> Result<[u8; 32]> {
    B64.decode(b64).ok().and_then(|b| b.try_into().ok()).ok_or_else(|| bad("key is not 32 bytes of base64"))
}

/// Largest Argon2 cost we run from an envelope. The server stores the envelope,
/// and a phone must not be made to allocate whatever it says. Web writes 256 MiB.
const MAX_KDF_OPS: u64 = 10;
const MAX_KDF_BYTES: u64 = 1 << 30;

/// Open the identity private key from its password envelope (`wrapWithSecret` in
/// `e2ee.js`: Argon2id KEK + libsodium secretbox). `Ok(None)` is a wrong password.
pub fn unwrap_identity(password: &str, envelope_b64: &str) -> Result<Option<Zeroizing<[u8; 32]>>> {
    let raw = B64.decode(envelope_b64).map_err(|_| bad("identity envelope is not base64"))?;
    let env: Value = serde_json::from_slice(&raw).map_err(|_| bad("identity envelope is not JSON"))?;
    if env.get("alg").and_then(Value::as_str) != Some("argon2id13") {
        return Err(bad("identity envelope uses an unknown KDF"));
    }
    let cost = |f: &str| env.get(f).and_then(Value::as_u64).ok_or_else(|| bad(&format!("missing {f}")));
    let (ops, mem) = (cost("ops")?, cost("mem")?);
    if ops == 0 || ops > MAX_KDF_OPS || mem > MAX_KDF_BYTES {
        return Err(bad("identity envelope asks for an unreasonable KDF cost"));
    }
    let params = argon2::Params::new((mem / 1024) as u32, ops as u32, 1, Some(32))
        .map_err(|_| bad("identity envelope has bad KDF parameters"))?;
    let mut kek = Zeroizing::new([0u8; 32]);
    argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params)
        .hash_password_into(password.as_bytes(), &unb64(&env, "salt")?, kek.as_mut())
        .map_err(|_| bad("identity envelope has a bad salt"))?;

    let nonce = unb64(&env, "nonce")?;
    if nonce.len() != 24 {
        return Err(bad("nonce is not 24 bytes"));
    }
    let cipher = crypto_secretbox::XSalsa20Poly1305::new_from_slice(kek.as_ref()).map_err(|_| bad("KEK is not 32 bytes"))?;
    let Ok(plain) = cipher.decrypt(crypto_secretbox::Nonce::from_slice(&nonce), unb64(&env, "ct")?.as_slice()) else {
        return Ok(None);
    };
    let plain = Zeroizing::new(plain);
    let key: [u8; 32] = plain.as_slice().try_into().map_err(|_| bad("identity key is not 32 bytes"))?;
    Ok(Some(Zeroizing::new(key)))
}

/// Open a member's grant (a sealed box of the domain's secret key to their identity).
pub fn open_grant(sealed_secret_key_b64: &str, identity_private_b64: &str) -> Result<Zeroizing<[u8; 32]>> {
    let identity = crypto_box::SecretKey::from(*Zeroizing::new(key32(identity_private_b64)?));
    let grant = B64.decode(sealed_secret_key_b64).map_err(|_| bad("grant is not base64"))?;
    let plain = Zeroizing::new(identity.unseal(&grant).map_err(|_| bad("this identity does not open the grant"))?);
    let key: [u8; 32] = plain.as_slice().try_into().map_err(|_| bad("domain key is not 32 bytes"))?;
    Ok(Zeroizing::new(key))
}

/// Open `sealed` (the `sealed` bundle of a message payload) with one key. Fails
/// cleanly — wrong key, tampered blob or AAD — without partial output.
pub fn open(sealed: &Value, key: &DomainKey) -> Result<Opened> {
    let secret = crypto_box::SecretKey::from(*key.secret);
    let dek = Zeroizing::new(
        secret.unseal(&unb64(sealed, "sealed_dek")?).map_err(|_| bad("this key does not open it"))?,
    );
    let cipher = XChaCha20Poly1305::new_from_slice(&dek).map_err(|_| bad("DEK is not 32 bytes"))?;
    let aad = sealed.get("aad").and_then(Value::as_str).ok_or_else(|| bad("missing aad"))?;

    let v2 = sealed.get("scheme").and_then(Value::as_str) == Some("sealed_box_v2");

    let part = |role: &str, nonce_field: &str, text_field: &str| -> Result<Value> {
        let aad = if v2 { format!("{aad}|{role}") } else { aad.to_string() };
        let nonce = unb64(sealed, nonce_field)?;
        if nonce.len() != 24 {
            return Err(bad("nonce is not 24 bytes"));
        }
        let text = unb64(sealed, text_field)?;
        let plain = Zeroizing::new(
            cipher
                .decrypt(XNonce::from_slice(&nonce), Payload { msg: &text, aad: aad.as_bytes() })
                .map_err(|_| bad("ciphertext or AAD was tampered with"))?,
        );
        serde_json::from_slice(&plain).map_err(|_| bad("opened, but it is not JSON"))
    };
    let (header, body) = (part("header", "header_nonce", "header_ciphertext")?, part("body", "body_nonce", "body_ciphertext")?);
    // On v1 header and body share one DEK and one AAD, so the cipher itself can't
    // tell them apart: whoever serves the bundle could swap the two pairs and both
    // would still authenticate. Refuse a part that is wearing the other's fields.
    let has = |v: &Value, fields: &[&str]| fields.iter().any(|f| v.get(*f).is_some());
    if has(&header, &["plain", "html"]) || has(&body, &["subject", "from", "snippet"]) {
        return Err(bad("header and body were swapped"));
    }
    Ok(Opened { header, body })
}

/// Open with whichever held key fits: the version the message declares first,
/// then the rest (the key-rotation edge) — the same order `e2eeStore.js` tries.
pub fn open_with_any(sealed: &Value, keys: &[DomainKey]) -> Result<Opened> {
    let declared = sealed.get("domain_key_version").and_then(Value::as_i64);
    let mut last = bad("no domain key held");
    for pass in [true, false] {
        for key in keys.iter().filter(|k| (Some(k.version) == declared) == pass) {
            match open(sealed, key) {
                Ok(opened) => return Ok(opened),
                Err(e) => last = e,
            }
        }
    }
    Err(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> (Value, DomainKey, Value) {
        let raw = std::fs::read_to_string(format!("{}/testdata/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap();
        let f: Value = serde_json::from_str(&raw).unwrap();
        let sealed = f["sealed"].clone();
        let key = DomainKey::from_b64(
            sealed["domain_key_version"].as_i64().unwrap(),
            f["domain_public_key"].as_str().unwrap(),
            f["domain_secret_key"].as_str().unwrap(),
        )
        .unwrap();
        (sealed, key, f["expect"].clone())
    }

    #[test]
    fn opens_mail_sealed_by_the_go_mx_and_by_libsodium_js() {
        for name in ["sealed_by_go.json", "sealed_by_js.json"] {
            let (sealed, key, expect) = fixture(name);
            let opened = open(&sealed, &key).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(opened.header["subject"], expect["subject"], "{name}");
            assert_eq!(opened.body["plain"], expect["plain"], "{name}");
        }
    }

    #[test]
    fn a_wrong_key_a_tampered_blob_or_a_changed_aad_all_fail_cleanly() {
        let (sealed, key, _) = fixture("sealed_by_go.json");
        let (_, other, _) = fixture("sealed_by_js.json");
        assert!(open(&sealed, &other).is_err());

        let mut aad = sealed.clone();
        aad["aad"] = Value::String("42|3|<someone-else@go.test>".into());
        assert!(open(&aad, &key).is_err(), "AAD is bound into the ciphertext");

        let mut flipped = sealed.clone();
        let mut bytes = B64.decode(flipped["body_ciphertext"].as_str().unwrap()).unwrap();
        bytes[0] ^= 1;
        flipped["body_ciphertext"] = Value::String(B64.encode(bytes));
        assert!(open(&flipped, &key).is_err());

        assert!(open(&serde_json::json!({}), &key).is_err());

        // Same DEK, same AAD: a swapped pair authenticates — and must still be refused.
        let mut swapped = sealed.clone();
        for (a, b) in [("header_nonce", "body_nonce"), ("header_ciphertext", "body_ciphertext")] {
            swapped[a] = sealed[b].clone();
            swapped[b] = sealed[a].clone();
        }
        assert!(open(&swapped, &key).err().unwrap().to_string().contains("swapped")); // (Opened has no Debug: it is plaintext)
    }

    #[test]
    fn opens_v2_and_a_swap_or_a_scheme_change_fails_in_the_cipher() {
        let (sealed, key, expect) = fixture("sealed_v2_by_go.json");
        let opened = open(&sealed, &key).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(opened.header["subject"], expect["subject"]);
        assert_eq!(opened.body["plain"], expect["plain"]);

        let mut swapped = sealed.clone();
        for (a, b) in [("header_nonce", "body_nonce"), ("header_ciphertext", "body_ciphertext")] {
            swapped[a] = sealed[b].clone();
            swapped[b] = sealed[a].clone();
        }
        assert!(open(&swapped, &key).err().unwrap().to_string().contains("tampered"));

        let mut downgraded = sealed.clone();
        downgraded.as_object_mut().unwrap().remove("scheme");
        assert!(open(&downgraded, &key).is_err());
    }

    #[test]
    fn opens_an_identity_and_grant_made_by_e2ee_js() {
        let raw = std::fs::read_to_string(format!("{}/testdata/identity_by_js.json", env!("CARGO_MANIFEST_DIR"))).unwrap();
        let f: Value = serde_json::from_str(&raw).unwrap();
        let envelope = f["encrypted_private_key"].as_str().unwrap();
        assert!(unwrap_identity("wrong", envelope).unwrap().is_none(), "a wrong password is None, not an error");

        let identity = unwrap_identity(f["password"].as_str().unwrap(), envelope).unwrap().unwrap();
        let derived = crypto_box::SecretKey::from(*identity).public_key();
        assert_eq!(B64.encode(derived.as_bytes()), f["public_key"].as_str().unwrap());

        let secret = open_grant(f["sealed_secret_key"].as_str().unwrap(), &B64.encode(*identity)).unwrap();
        let key = DomainKey { version: 3, public: key32(f["domain_public_key"].as_str().unwrap()).unwrap(), secret };
        assert_eq!(open(&f["sealed"], &key).unwrap().header["subject"], f["expect"]["subject"]);

        assert!(open_grant(f["sealed_secret_key"].as_str().unwrap(), &B64.encode([7u8; 32])).is_err());
    }

    #[test]
    fn refuses_an_envelope_that_asks_for_too_much_memory() {
        let env = B64.encode(serde_json::json!({"alg":"argon2id13","ops":3,"mem":(1u64<<40),"salt":"AA==","nonce":"AA==","ct":"AA=="}).to_string());
        assert!(unwrap_identity("x", &env).is_err());
    }

    #[test]
    fn finds_the_right_key_among_several_even_when_the_version_lies() {
        let (sealed, key, expect) = fixture("sealed_by_js.json");
        let other = || fixture("sealed_by_go.json").1;
        let mislabeled = DomainKey { version: 99, ..key };
        let opened = open_with_any(&sealed, &[other(), mislabeled]).unwrap();
        assert_eq!(opened.header["subject"], expect["subject"]);
        assert!(open_with_any(&sealed, &[other()]).is_err());
        assert!(open_with_any(&sealed, &[]).is_err());
    }
}
