// E2EE session state (docs/E2EE.md Phase F): the unlocked identity key and
// per-domain sealing secrets, IN MEMORY ONLY — nothing here ever touches
// localStorage/IndexedDB. Locking is a page reload away by design; per-session
// unlock is the documented friction of sealed mail.
//
// Components subscribe via useE2ee() (useSyncExternalStore) and call the
// orchestration functions below, which wrap lib/e2ee.js crypto + lib/api.js.

import { useSyncExternalStore } from 'react';
import api from './api';
import log from './log';
import mxMirror from './mxMirror';
import {
  ready,
  generateIdentity,
  unlockIdentity,
  rewrapIdentity,
  recoverIdentity,
  generateRecoveryPassphrase,
  wrapRecovery,
  openGrant,
  decryptMessage,
  decryptAttachment,
  decryptFilename,
} from './e2ee';

const state = {
  // 'unknown' | 'none' (no identity uploaded) | 'locked' | 'unlocked'
  identityStatus: 'unknown',
  identityPublicKey: null,
  userKey: null, // the server record (wrapped blobs)
  // domain record key -> { version, publicKey, secretKey } (current version)
  domainSecrets: new Map(),
  epoch: 0, // bump to re-render subscribers
};

let identityPrivateKey = null; // deliberately outside the snapshot object

const listeners = new Set();
function emit() {
  state.epoch++;
  snapshotCache = null;
  listeners.forEach((fn) => fn());
}

let snapshotCache = null;
function getSnapshot() {
  if (!snapshotCache) {
    snapshotCache = {
      identityStatus: state.identityStatus,
      identityPublicKey: state.identityPublicKey,
      unlockedDomains: [...state.domainSecrets.keys()],
      epoch: state.epoch,
    };
  }
  return snapshotCache;
}

export function useE2ee() {
  return useSyncExternalStore(
    (fn) => { listeners.add(fn); return () => listeners.delete(fn); },
    getSnapshot
  );
}

// ── Identity ────────────────────────────────────────────────────────────────

// Loads (and caches) the server-side user_key record; resolves identityStatus.
export async function refreshIdentity() {
  try {
    const res = await api.getUserKey();
    state.userKey = res.user_key;
    state.identityPublicKey = res.user_key.public_key;
    if (state.identityStatus !== 'unlocked') state.identityStatus = 'locked';
  } catch (e) {
    if (e?.status === 404) {
      state.userKey = null;
      state.identityStatus = 'none';
    } else {
      log.warn('E2EE', `user-key load failed: ${e?.message || e}`);
    }
  }
  emit();
  return state.identityStatus;
}

// First-time setup: generate the identity + recovery material, upload both,
// email the recovery file. Returns { passphrase } for the save-gate — the ONLY
// time it is ever available.
export async function setupIdentity(password) {
  await ready();
  const identity = generateIdentity(password);
  const priv = unlockIdentity(password, identity);
  const passphrase = generateRecoveryPassphrase();
  const recoveryBlob = wrapRecovery(passphrase, priv);

  // current_password: the server refuses a key wrapped under anything but the
  // account password (a typo here used to make a key no password could open).
  let res;
  try {
    res = await api.putUserKey({ ...identity, recovery_encrypted_private_key: recoveryBlob, current_password: password });
  } catch (e) {
    throw e?.status === 422 ? new Error('That is not your inbox2 password.') : e;
  }
  state.userKey = res.user_key;
  state.identityPublicKey = res.user_key.public_key;
  identityPrivateKey = priv;
  state.identityStatus = 'unlocked';
  emit();

  // Offsite backup via email (fire-and-forget; the save-gate is the primary).
  api.sendRecoveryEmail(recoveryBlob).catch((e) =>
    log.warn('E2EE', `recovery email failed: ${e?.message || e}`));

  return { passphrase };
}

// Per-session unlock with the account password. Throws on a wrong password.
export async function unlock(password) {
  await ready();
  if (!state.userKey) await refreshIdentity();
  if (!state.userKey) throw new Error('No identity key on this account');
  try {
    identityPrivateKey = unlockIdentity(password, state.userKey);
  } catch (e) {
    // Only libsodium's own "wrong secret key" means a wrong password; anything
    // else (the 256 MB key derivation failing in this browser, a damaged key)
    // must not be reported as one.
    if (!/wrong secret key/.test(e?.message || '')) {
      log.warn('E2EE', `unlock failed: ${e?.message || e}`);
      throw new Error(`Your key could not be opened in this browser: ${e?.message || e}`, { cause: e });
    }
    // The key is wrapped under the password it was set up (or last re-wrapped)
    // with; a password reset cannot re-wrap it, so the two can differ.
    throw new Error('That password did not unlock your key. If you changed your password after setting up encryption, enter the one you had then.', { cause: e });
  }
  state.identityStatus = 'unlocked';
  emit();
}

// Password change: re-wraps the identity under the new password so the account
// password keeps unlocking it. Call unwrapForRewrap BEFORE the change (it needs
// the old password) and the returned function after it succeeds. Resolves to
// null when there is no identity, or the old password does not open it.
/** Whether this account has an identity key (so a password change must re-wrap it). */
export async function hasIdentityKey() {
  await ready();
  if (!state.userKey) await refreshIdentity();
  return !!state.userKey;
}

export async function unwrapForRewrap(currentPassword) {
  await ready();
  if (!state.userKey) await refreshIdentity();
  if (!state.userKey) return null;
  let priv;
  try { priv = unlockIdentity(currentPassword, state.userKey); } catch { return null; }
  return async (newPassword) => {
    const { public_key, recovery_encrypted_private_key } = state.userKey;
    const res = await api.putUserKey({ public_key, recovery_encrypted_private_key, ...rewrapIdentity(priv, newPassword) });
    state.userKey = res.user_key;
  };
}

// Recovery: opens the identity with the recovery phrase (the password it was
// wrapped under is lost or out of date), then re-wraps it under the account
// password, which the server checks. Leaves the key unlocked.
export async function recover(passphrase, password) {
  await ready();
  if (!state.userKey) await refreshIdentity();
  if (!state.userKey) throw new Error('No identity key on this account');
  const { public_key, recovery_encrypted_private_key } = state.userKey;
  if (!recovery_encrypted_private_key) throw new Error('This key has no recovery copy.');
  let priv;
  try {
    priv = recoverIdentity(passphrase, recovery_encrypted_private_key);
  } catch {
    throw new Error('That recovery phrase did not open your key. Check the six words.');
  }
  try {
    const res = await api.putUserKey({
      public_key, recovery_encrypted_private_key, ...rewrapIdentity(priv, password), current_password: password,
    });
    state.userKey = res.user_key;
  } catch (e) {
    throw new Error(e?.status === 422 ? 'That is not your inbox2 password.' : `The key was not saved: ${e?.message || e}`, { cause: e });
  }
  identityPrivateKey = priv;
  state.identityStatus = 'unlocked';
  emit();
}

export function lock() {
  identityPrivateKey = null;
  state.identityStatus = state.userKey ? 'locked' : 'none';
  state.domainSecrets.clear();
  mxMirror.clearDomainKeys(); // desktop: the engine forgets them too
  emit();
}

// The unlocked identity as bytes, for opening Disk key grants (lib/disk/sealed.js),
// or null while locked. Never stored; the private key stays in this module's memory.
export function identityKeys() {
  if (!isUnlocked() || !state.identityPublicKey) return null;
  return { publicKey: sodiumFromB64(state.identityPublicKey), privateKey: identityPrivateKey };
}
const sodiumFromB64 = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

export function isUnlocked() {
  return state.identityStatus === 'unlocked' && !!identityPrivateKey;
}

// ── Domain secrets ──────────────────────────────────────────────────────────

// Opens the caller's grant for one domain and caches the sealing secret.
export async function loadDomainSecret(orgKey, domainRecordKey) {
  if (!isUnlocked()) throw new Error('locked');
  if (state.domainSecrets.has(domainRecordKey)) return state.domainSecrets.get(domainRecordKey);

  const res = await api.getDomainE2ee(orgKey, domainRecordKey);
  const { current_key: currentKey, my_grant: myGrant } = res.e2ee || {};
  if (!currentKey || !myGrant) return null;

  await ready();
  const secretKey = openGrant(myGrant.sealed_secret_key, state.identityPublicKey, identityPrivateKey);
  const entry = { version: currentKey.version, publicKey: currentKey.public_key, secretKey };
  state.domainSecrets.set(domainRecordKey, entry);
  emit();
  return entry;
}

// Loads every e2ee-enabled domain's secret for an org (best effort).
export async function loadOrgDomainSecrets(orgKey) {
  if (!isUnlocked()) return;
  try {
    const res = await api.listDomains(orgKey);
    const enabled = (res.domains || []).filter((d) => d.e2ee_enabled);
    const entries = [];
    for (const d of enabled) {
      try {
        const entry = await loadDomainSecret(orgKey, d.id);
        if (entry) entries.push(entry);
      } catch (e) {
        log.warn('E2EE', `domain secret load failed for ${d.name}: ${e?.message || e}`);
      }
    }
    // Desktop: let the engine open this org's mirrored sealed mail (docs/MX-Sync.md).
    // Always the full current set — an empty one takes back keys for grants that
    // are gone.
    mxMirror.setDomainKeys(orgKey, entries);
  } catch (e) {
    log.warn('E2EE', `domain list failed: ${e?.message || e}`);
  }
}

// ── Message decryption ──────────────────────────────────────────────────────

// Decrypts a sealed API message using any cached domain secret that opens it
// (an org can own several domains; trial decryption fails cleanly on a
// mismatch). Returns { header, body } or throws when locked / no key fits.
export async function decryptSealedMessage(message) {
  return withDomainSecret(message, (pub, sec) => decryptMessage(message.sealed, pub, sec));
}

// A sealed attachment's filename and its bytes are encrypted under the same
// message DEK, with the attachment's position in the AAD ("|att:<i>", and
// "|att:<i>|name" for the filename) — so both need the same domain secret the
// body was opened with, and the same index the server serialized them in.
export async function decryptSealedFilename(message, attachment, index) {
  return withDomainSecret(message, (pub, sec) =>
    decryptFilename(message.sealed, attachment, index, pub, sec));
}

export async function decryptSealedAttachment(message, attachment, index, ciphertext) {
  return withDomainSecret(message, (pub, sec) =>
    decryptAttachment(message.sealed, attachment, index, ciphertext, pub, sec));
}

// Runs `fn(domainPublicKey, domainSecretKey)` against whichever cached domain
// secret opens this message. An org can own several domains, and trial
// decryption fails cleanly on a mismatch — so prefer the version the message
// declares, then fall back to trying them all (the key-rotation edge).
async function withDomainSecret(message, fn) {
  if (!message?.sealed) throw new Error('not sealed');
  if (!isUnlocked()) throw new Error('locked');
  await ready();

  let lastError = new Error('no domain key available');
  for (const entry of state.domainSecrets.values()) {
    if (entry.version !== message.sealed.domain_key_version) continue;
    try {
      return fn(entry.publicKey, entry.secretKey);
    } catch (e) {
      lastError = e;
    }
  }
  for (const entry of state.domainSecrets.values()) {
    try {
      return fn(entry.publicKey, entry.secretKey);
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError;
}
