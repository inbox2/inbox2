// E2EE client crypto (docs/E2EE.md Phase F) — the single module every surface
// (React web, Tauri webview) uses to handle sealed mail. libsodium throughout,
// interop-locked to the Go MX (mta/internal/seal):
//
//   • message/attachment content:  crypto_aead_xchacha20poly1305_ietf
//                                  (== Go chacha20poly1305.NewX), AAD served
//                                  verbatim by the API (`sealed.aad`)
//   • DEK / grant wrapping:        crypto_box_seal (== Go box.SealAnonymous)
//   • identity/recovery wrapping:  crypto_secretbox under an Argon2id KEK
//                                  (crypto_pwhash, alg 2 = argon2id13)
//
// Wrapped blobs are self-describing base64 JSON envelopes so the emailed
// recovery file alone (plus the passphrase) is sufficient to recover.
//
// Nothing in this module persists secrets: callers hold unwrapped keys in
// memory only (see e2eeStore).

import sodiumLib from "libsodium-wrappers-sumo";
import { EFF_WORDLIST } from "./effWordlist";

let sodium = null;

export async function ready() {
  if (!sodium) {
    await sodiumLib.ready;
    sodium = sodiumLib;
  }
  return sodium;
}

const te = new TextEncoder();
const td = new TextDecoder();

function b64(bytes) {
  return sodium.to_base64(bytes, sodium.base64_variants.ORIGINAL);
}

function unb64(str) {
  return sodium.from_base64(str, sodium.base64_variants.ORIGINAL);
}

// ── Password/passphrase wrapping (Argon2id KEK + secretbox) ─────────────────

const KDF_ALG = "argon2id13";

function kdfParams() {
  return {
    alg: KDF_ALG,
    ops: sodium.crypto_pwhash_OPSLIMIT_MODERATE,
    mem: sodium.crypto_pwhash_MEMLIMIT_MODERATE,
  };
}

function deriveKek(secret, salt, ops, mem) {
  return sodium.crypto_pwhash(
    sodium.crypto_secretbox_KEYBYTES,
    te.encode(secret),
    salt,
    ops,
    mem,
    sodium.crypto_pwhash_ALG_ARGON2ID13
  );
}

// Wraps bytes under a password/passphrase into a self-describing envelope.
export function wrapWithSecret(secret, bytes) {
  const { ops, mem } = kdfParams();
  const salt = sodium.randombytes_buf(sodium.crypto_pwhash_SALTBYTES);
  const kek = deriveKek(secret, salt, ops, mem);
  const nonce = sodium.randombytes_buf(sodium.crypto_secretbox_NONCEBYTES);
  const ct = sodium.crypto_secretbox_easy(bytes, nonce, kek);
  sodium.memzero(kek);
  const envelope = {
    v: 1,
    alg: KDF_ALG,
    ops,
    mem,
    salt: b64(salt),
    nonce: b64(nonce),
    ct: b64(ct),
  };
  return b64(te.encode(JSON.stringify(envelope)));
}

// Reverses wrapWithSecret. Throws on a wrong secret or corrupted envelope.
export function unwrapWithSecret(secret, blob) {
  const envelope = JSON.parse(td.decode(unb64(blob)));
  if (envelope.alg !== KDF_ALG) throw new Error(`unsupported kdf: ${envelope.alg}`);
  const kek = deriveKek(secret, unb64(envelope.salt), envelope.ops, envelope.mem);
  try {
    return sodium.crypto_secretbox_open_easy(unb64(envelope.ct), unb64(envelope.nonce), kek);
  } finally {
    sodium.memzero(kek);
  }
}

// ── Identity keys ────────────────────────────────────────────────────────────

// Generates the user's X25519 identity keypair, wrapped under their inbox2
// password. Returns everything the PUT /user-key endpoint wants.
export function generateIdentity(password) {
  const pair = sodium.crypto_box_keypair();
  const wrapped = wrapWithSecret(password, pair.privateKey);
  const result = {
    public_key: b64(pair.publicKey),
    encrypted_private_key: wrapped,
    kdf_params: kdfParams(),
  };
  sodium.memzero(pair.privateKey);
  return result;
}

// Unlocks the identity private key from the server-stored user_key record.
export function unlockIdentity(password, userKey) {
  return unwrapWithSecret(password, userKey.encrypted_private_key);
}

// Re-wraps an unlocked identity under a new password (password change / after
// recovery). Same public key — grants stay valid.
export function rewrapIdentity(privateKey, newPassword) {
  return {
    encrypted_private_key: wrapWithSecret(newPassword, privateKey),
    kdf_params: kdfParams(),
  };
}

// ── Recovery passphrase (Diceware) ───────────────────────────────────────────

export const RECOVERY_WORD_COUNT = 6;

// The EFF short list has exactly one hyphenated entry ("yo-yo"). Drawing it into
// a hyphen-joined phrase makes the word count ambiguous — the phrase reads as 7
// words, not RECOVERY_WORD_COUNT. Dropping it costs ~0.007 bits. (Recovery works
// either way: normalizePassphrase collapses space/hyphen runs.)
const PHRASE_WORDS = EFF_WORDLIST.filter((w) => !w.includes("-"));

// Generated, never user-chosen: ~62 bits from the 1296-word EFF list, behind
// Argon2id-MODERATE (docs/E2EE.md — a chosen "easy" phrase would be offline-
// brute-forceable against the emailed file).
export function generateRecoveryPassphrase() {
  const words = [];
  for (let i = 0; i < RECOVERY_WORD_COUNT; i++) {
    words.push(PHRASE_WORDS[sodium.randombytes_uniform(PHRASE_WORDS.length)]);
  }
  return words.join("-");
}

// Wraps the identity key under the recovery passphrase → the blob stored as
// recovery_encrypted_private_key AND emailed as the recovery file.
export function wrapRecovery(passphrase, identityPrivateKey) {
  return wrapWithSecret(normalizePassphrase(passphrase), identityPrivateKey);
}

// Opens a recovery blob (server-stored or pasted from the welcome email).
export function recoverIdentity(passphrase, recoveryBlob) {
  return unwrapWithSecret(normalizePassphrase(passphrase), recoveryBlob);
}

// Tolerate the ways humans re-type a passphrase: case, surrounding space, and
// space-vs-hyphen separators.
export function normalizePassphrase(passphrase) {
  return passphrase.trim().toLowerCase().split(/[\s-]+/).join("-");
}

// ── Domain keys & grants ─────────────────────────────────────────────────────

// Generates a domain sealing keypair. The public key goes to the server; the
// secret exists only inside per-member sealed grants.
export function generateDomainKey() {
  const pair = sodium.crypto_box_keypair();
  return { publicKey: b64(pair.publicKey), secretKey: pair.privateKey };
}

// Seals the domain secret to one member's identity public key → their grant.
export function sealGrant(domainSecretKey, memberIdentityPublicKeyB64) {
  return b64(sodium.crypto_box_seal(domainSecretKey, unb64(memberIdentityPublicKeyB64)));
}

// Opens the caller's own grant with their unlocked identity keypair.
export function openGrant(sealedGrantB64, identityPublicKeyB64, identityPrivateKey) {
  return sodium.crypto_box_seal_open(
    unb64(sealedGrantB64),
    unb64(identityPublicKeyB64),
    identityPrivateKey
  );
}

// ── Sealed message / attachment decryption ───────────────────────────────────

// Unseals the per-message DEK with the domain keypair (secret from the grant).
export function unsealDek(sealed, domainPublicKeyB64, domainSecretKey) {
  return sodium.crypto_box_seal_open(
    unb64(sealed.sealed_dek),
    unb64(domainPublicKeyB64),
    domainSecretKey
  );
}

// v2 binds the part's role into the AAD; v1 bundles carry no `scheme`.
function partAad(sealed, role) {
  return sealed.scheme === 'sealed_box_v2' ? `${sealed.aad}|${role}` : sealed.aad;
}

function aeadOpen(dek, nonceB64, ciphertextB64, aadString) {
  return sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
    null,
    unb64(ciphertextB64),
    te.encode(aadString),
    unb64(nonceB64),
    dek
  );
}

// Decrypts one sealed message (the `sealed` bundle from MessageSerializer).
// Returns { header: {subject, from, to, cc, snippet, message_id, ...},
//           body: {plain, html} }. Throws if the AAD/blob was tampered with.
export function decryptMessage(sealed, domainPublicKeyB64, domainSecretKey) {
  const dek = unsealDek(sealed, domainPublicKeyB64, domainSecretKey);
  try {
    const header = JSON.parse(
      td.decode(aeadOpen(dek, sealed.header_nonce, sealed.header_ciphertext, partAad(sealed, 'header')))
    );
    const body = JSON.parse(
      td.decode(aeadOpen(dek, sealed.body_nonce, sealed.body_ciphertext, partAad(sealed, 'body')))
    );
    // On v1 the cipher can't tell the two parts apart (docs/E2EE.md).
    if ('plain' in header || 'html' in header || 'subject' in body || 'from' in body || 'snippet' in body) {
      throw new Error('sealed mail: header and body were swapped');
    }
    return { header, body };
  } finally {
    sodium.memzero(dek);
  }
}

// Decrypts a sealed attachment's content bytes. `index` is the attachment's
// position in the message (AAD suffix "|att:<i>", matching the MX).
export function decryptAttachment(sealed, attachment, index, ciphertextBytes, domainPublicKeyB64, domainSecretKey) {
  const dek = unsealDek(sealed, domainPublicKeyB64, domainSecretKey);
  try {
    const aad = `${sealed.aad}|att:${index}`;
    return sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
      null,
      ciphertextBytes,
      te.encode(aad),
      unb64(attachment.content_nonce),
      dek
    );
  } finally {
    sodium.memzero(dek);
  }
}

// Decrypts a sealed attachment's filename (AAD suffix "|att:<i>|name").
export function decryptFilename(sealed, attachment, index, domainPublicKeyB64, domainSecretKey) {
  const dek = unsealDek(sealed, domainPublicKeyB64, domainSecretKey);
  try {
    const aad = `${sealed.aad}|att:${index}|name`;
    const name = sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
      null,
      unb64(attachment.sealed_filename),
      te.encode(aad),
      unb64(attachment.filename_nonce),
      dek
    );
    return td.decode(name);
  } finally {
    sodium.memzero(dek);
  }
}
