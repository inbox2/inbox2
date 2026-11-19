// MxMirror — drives the engine's local mirror of MX mail (docs/MX-Sync.md).
//
// The Rust engine does the syncing and keeps every mirrored org fresh on its own
// 60s beat; this singleton tells it WHICH orgs to mirror (on sign-in), nudges it
// the moment the server says something changed (cable hints, via orgLiveMail),
// and clears the mirror on sign-out — mail must not outlive the session on disk.
// Reads go straight to SQLite (lib/localData.js). Desktop only; a no-op in the
// browser, which has no local store and stays on the API.
import { isTauri } from './tauri.js';
import log from './log.js';

const MAX_PASSES_PER_KICK = 25;

class MxMirror {
  constructor() {
    this._orgs = new Set();
    this._userKey = null;
    this._listeners = new Set();
    this._listening = false;
    // watch / reset / forget run one at a time: a forget still in flight must not
    // land after the same org was re-watched and delete the new mirror.
    this._queue = Promise.resolve();
  }

  // Whose mirror this is. localData only serves rows mirrored for this user.
  get userKey() { return this._userKey; }

  _serial(fn) {
    this._queue = this._queue.then(fn, fn);
    return this._queue;
  }

  // Fired after a pass or a local action changed the mirror. Returns unsubscribe.
  onChange(cb) {
    this._listeners.add(cb);
    return () => this._listeners.delete(cb);
  }

  // Mirror exactly these orgs as this user. Idempotent — called on every
  // auth/org change. Orgs that dropped out of the list are forgotten.
  watch(orgKeys, userKey) {
    if (!isTauri() || !userKey) return Promise.resolve();
    return this._serial(async () => {
      await this._listen();
      const want = new Set((orgKeys || []).filter(Boolean));
      for (const org of [...this._orgs]) if (!want.has(org)) await this._forget(org);
      // Another user signed in without a sign-out in between: every org starts
      // over (the engine wipes a mirror built for someone else on its first pass).
      const switched = this._userKey !== userKey;
      this._userKey = userKey;
      for (const org of want) {
        const fresh = switched || !this._orgs.has(org);
        this._orgs.add(org);
        if (fresh) this.kick(org);
      }
    });
  }

  // Run a pass now. `directory` for a hint about members/tags/domains/…, which
  // may also have moved this user's own access — hence the reconcile.
  async kick(org, { directory = false } = {}) {
    if (!isTauri() || !this._userKey || !this._orgs.has(org)) return;
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      // A first pass leaves history to read; keep going until it's in — but bounded:
      // the engine's own tick carries on, and a server that always says "more"
      // must not pin this loop.
      for (let pass = 0; pass < MAX_PASSES_PER_KICK && this._orgs.has(org); pass++) {
        const report = await invoke('mx_sync', { org, userKey: this._userKey, directory, reconcile: directory });
        directory = false;
        if (!report?.more) break;
      }
    } catch (e) {
      log.warn('MxMirror', `sync ${org} failed: ${e?.message || e}`);
    }
  }

  // archive / trash / spam / open / mark_read / mark_unread. Shows locally before
  // it resolves, is queued durably, and is sent as soon as the network allows —
  // so it never fails for being offline.
  async action(org, threads, action) {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('mx_action', { org, threads, action });
  }

  // E2EE: the member unlocked (or locked) their identity. The engine gets the
  // domain keypairs — memory only, never persisted — so it can open mirrored
  // sealed mail for local search / MCP / Bridge; `[]` takes them back. The webview
  // keeps decrypting what it renders itself; this is only for the engine's readers.
  async setDomainKeys(orgKeyOrSlug, entries) {
    if (!isTauri()) return;
    try {
      // Callers name the org by key or by slug; the mirror is keyed by key.
      const { mirroredOrg } = await import('./localData.js');
      const org = this._orgs.has(orgKeyOrSlug) ? orgKeyOrSlug : await mirroredOrg(orgKeyOrSlug);
      if (!org) return;
      const { invoke } = await import('@tauri-apps/api/core');
      const keys = entries.map(e => ({
        version: e.version,
        public_key: e.publicKey,
        secret_key: btoa(String.fromCharCode(...e.secretKey)),
      }));
      await invoke('mx_set_domain_keys', { org, keys });
    } catch (e) {
      log.warn('MxMirror', `domain keys for ${orgKeyOrSlug} not delivered: ${e?.message || e}`);
    }
  }

  // Lock: every org's keys leave the engine's memory.
  async clearDomainKeys() {
    for (const org of this._orgs) await this.setDomainKeys(org, []);
  }

  // Sign-out: every mirrored org leaves the device.
  reset() {
    return this._serial(async () => {
      for (const org of [...this._orgs]) await this._forget(org);
      this._userKey = null;
    });
  }

  async _forget(org) {
    this._orgs.delete(org);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('mx_forget', { org });
    } catch (e) {
      log.warn('MxMirror', `forget ${org} failed: ${e?.message || e}`);
    }
  }

  async _listen() {
    if (this._listening) return;
    this._listening = true;
    const { listen } = await import('@tauri-apps/api/event');
    await listen('mx-sync', () => {
      for (const cb of this._listeners) {
        try { cb(); } catch (e) { log.warn('MxMirror', `listener failed: ${e?.message || e}`); }
      }
    });
  }
}

export default new MxMirror();
