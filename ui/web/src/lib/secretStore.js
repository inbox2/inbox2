// Cross-target secret store for third-party API keys (Apollo, …).
//
// On the desktop it persists to the engine's encrypted, device-bound SQLite store
// (shared across the desktop webview, CLI, and daemon); on the plain web build —
// which has no engine — it falls back to localStorage. The localStorage fallback
// key is `inbox2_<name>`, matching the legacy keys, so existing values keep working
// and are lazily migrated into the encrypted store on first desktop read.
// See docs/Cloud-Push.md.
import { isTauri } from './tauri';
import log from './log';

const lsKey = (name) => `inbox2_${name}`;

// localStorage is absent in non-browser targets (SSR; some unit tests run in a
// node env). Resolve it lazily per call — never captured at module load — so a
// polyfill installed after import is still seen, and a missing global degrades
// to a no-op instead of throwing a ReferenceError.
const ls = () => (typeof localStorage !== 'undefined' ? localStorage : null);

async function invoke(cmd, args) {
  const { invoke: tauriInvoke } = await import('@tauri-apps/api/core');
  return tauriInvoke(cmd, args);
}

export async function getSecret(name) {
  if (!isTauri()) return ls()?.getItem(lsKey(name)) ?? null;
  try {
    const v = await invoke('get_secret', { name });
    if (v) return v;
    // Lazy-migrate a pre-existing plaintext localStorage value into the store.
    const legacy = ls()?.getItem(lsKey(name));
    if (legacy) {
      await invoke('set_secret', { name, value: legacy });
      ls()?.removeItem(lsKey(name));
      return legacy;
    }
    return null;
  } catch (e) {
    log.warn('secretStore', `getSecret(${name}) failed: ${e?.message || e}`);
    return ls()?.getItem(lsKey(name)) ?? null;
  }
}

export async function setSecret(name, value) {
  if (!isTauri()) {
    ls()?.setItem(lsKey(name), value);
    return;
  }
  try {
    await invoke('set_secret', { name, value });
    ls()?.removeItem(lsKey(name)); // no plaintext copy on desktop
  } catch (e) {
    log.warn('secretStore', `setSecret(${name}) failed: ${e?.message || e}`);
    ls()?.setItem(lsKey(name), value);
  }
}

export async function clearSecret(name) {
  ls()?.removeItem(lsKey(name));
  if (!isTauri()) return;
  try {
    await invoke('clear_secret', { name });
  } catch (e) {
    log.warn('secretStore', `clearSecret(${name}) failed: ${e?.message || e}`);
  }
}
