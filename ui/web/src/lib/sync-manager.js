// SyncManager — thin bridge between the Rust sync engine and the React UI.
//
// Sync itself now runs entirely in the Rust/Tauri backend (background polling,
// write-back, OAuth refresh). This module:
//   1. Hands the engine the API context (Rails proxy base + JWT) on init.
//   2. Re-broadcasts the engine's Tauri events onto a local event bus so the
//      existing UI subscribers (on('new-message'), on('sync-complete'), …) keep
//      working unchanged.
//   3. Exposes resync/register helpers that call Tauri commands.
//
// The public API (on/emit/subscribe/register/unregister/resyncAll/resyncChannel)
// is unchanged so callers don't need to know sync moved to Rust.

import log from './log';
import { scrubIfDemo } from './demoData';
import api from './api';
import { apiBaseUrl } from './apiOrigin';

const STATUS_IDLE = 'idle';
const STATUS_SYNCING = 'syncing';
const STATUS_ERROR = 'error';

// Pull the user's cloud-synced per-channel open-tracking config and write it into
// the local engine (matched to connected accounts by email), so pixel injection
// honors settings saved on their other devices (docs/Open-Tracking.md).
async function syncChannelTrackingToLocal(invoke) {
  const { channels } = await api.getChannelTracking();
  if (!channels?.length) return;
  const accounts = await invoke('list_external_accounts');
  const byEmail = new Map(accounts.map((a) => [String(a.email_address || '').toLowerCase(), a.key]));
  for (const ch of channels) {
    const key = byEmail.get(String(ch.email_address || '').toLowerCase());
    if (!key) continue;
    await invoke('set_open_tracking', {
      accountKey: key,
      enabled: !!ch.open_tracking_enabled,
      trackDomain: ch.track_domain || null,
    }).catch(() => {});
  }
}

class SyncManager {
  constructor() {
    /** @type {Set<string>} known account keys */
    this.accounts = new Set();
    this.status = STATUS_IDLE;
    /** @type {Map<string, Array<function>>} event name → listeners */
    this._listeners = new Map();
    this._initialized = false;
  }

  /**
   * Initialize the bridge: push the API context to Rust and start forwarding
   * engine events onto the local bus. Idempotent.
   */
  async init() {
    if (this._initialized) return;
    this._initialized = true;
    if (!window.__TAURI_INTERNALS__ && !window.__TAURI__) {
      // Not running under Tauri (e.g. plain web preview) — nothing to bridge.
      return;
    }
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      const apiBase = apiBaseUrl();
      const railsJwt = (await api.getToken()) || '';
      // Only push a token DOWN to the engine — never an empty one, which would
      // delete the engine's persisted CLOUD_AUTH_TOKEN. With no token here the
      // engine keeps whatever it loaded from its encrypted store on boot (the
      // store is the shared source of truth; api.getToken reads the same secret).
      if (railsJwt) {
        await invoke('set_api_context', { apiBase, railsJwt });
        // Mirror cloud-synced per-channel open-tracking config into the local
        // engine (docs/Open-Tracking.md) so the pixel injection uses the settings
        // saved on the user's other devices.
        await syncChannelTrackingToLocal(invoke).catch((e) =>
          log.warn('SyncManager', `channel tracking sync failed: ${e?.message || e}`));
      }
    } catch (e) {
      log.warn('SyncManager', `set_api_context failed: ${e?.message || e}`);
    }

    // Push the user's generation-lane choice (Settings → On-device AI) to the
    // background triage worker and warm the matching on-device backend. The
    // default ('auto') keeps the old behavior: OpenAI when a key is configured,
    // else on-device.
    try {
      const { applyNluLane } = await import('./ai/lanePrefs');
      // Fire-and-forget: applying the lane can spawn/warm an on-device model
      // (llama-server health-poll up to 30s, Apple FM sidecar). Awaiting it here
      // held up list_external_accounts — i.e. every account tab — behind a
      // model load on each boot.
      applyNluLane().catch((e) =>
        log.warn('SyncManager', `set_ai_config failed: ${e?.message || e}`));
    } catch (e) {
      log.warn('SyncManager', `set_ai_config failed: ${e?.message || e}`);
    }

    try {
      const { listen } = await import('@tauri-apps/api/event');
      // Engine event → local bus event. `sync` is the structured sync-lifecycle
      // backbone (phases: started/folder-started/folder-progress/
      // folder-complete/completed/failed); new-message + calendar-changed are
      // distinct triggers (notifications / calendar refresh).
      const events = ['sync', 'new-message', 'calendar-changed', 'outbox-changed', 'triage-progress', 'triage-updated', 'space-updated'];
      for (const event of events) {
        await listen(event, (e) => {
          if (event === 'sync') {
            const p = e.payload || {};
            log.info('SyncBus', `sync ${p.phase}${p.folderName ? ` ${p.folderName}` : ''}${p.synced != null ? ` (${p.synced})` : ''} account=${p.accountKey}`);
          }
          // Demo mode: engine events don't pass any of the read chokepoints, so
          // a real mail arriving mid-demo would otherwise pop a notification with
          // the real sender and subject on it. (Payloads the demo harness emits
          // are already fake, and scrub() leaves its own cast alone.)
          this.emit(event, scrubIfDemo(e.payload));
        });
      }
      // The engine's `status` event (an account's connection status changed:
      // connected/error/needs_reauth/…) is re-broadcast as 'account-status' —
      // the bus's own 'status' event is the manager's syncing/idle state and
      // predates it. Payload: { accountKey, status, error }.
      await listen('status', (e) => {
        const p = e.payload || {};
        log.info('SyncBus', `account-status ${p.status} account=${p.accountKey}${p.error ? ` (${p.error})` : ''}`);
        this.emit('account-status', p);
      });
      log.info('SyncBus', 'event bridge ready');
    } catch (e) {
      log.warn('SyncManager', `event bridge failed: ${e?.message || e}`);
    }
  }

  // ── Channel registry (just account keys now) ──────

  register(accountKey) {
    this.accounts.add(accountKey);
  }

  async unregister(accountKey) {
    this.accounts.delete(accountKey);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('stop_sync', { accountKey });
    } catch { /* best effort */ }
  }

  get(accountKey) {
    // Adapters live in Rust now; diagnostics come from Tauri commands instead.
    return this.accounts.has(accountKey) ? { accountKey } : null;
  }

  has(accountKey) {
    return this.accounts.has(accountKey);
  }

  clear() {
    this.accounts.clear();
    this._setStatus(STATUS_IDLE);
  }

  // ── Resync (trigger an immediate sync via Rust) ───

  async resyncAll() {
    if (this.accounts.size === 0) return;
    this._setStatus(STATUS_SYNCING);
    const { invoke } = await import('@tauri-apps/api/core');
    const results = await Promise.allSettled(
      [...this.accounts].map((key) => invoke('start_sync', { accountKey: key }))
    );
    this._setStatus(results.some((r) => r.status === 'rejected') ? STATUS_ERROR : STATUS_IDLE);
  }

  async resyncChannel(accountKey) {
    this._setStatus(STATUS_SYNCING);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('start_sync', { accountKey });
      this._setStatus(STATUS_IDLE);
    } catch (e) {
      this.emit('sync-log', { email: accountKey, level: 'ERROR', message: `Sync failed: ${e?.message || e}` });
      this._setStatus(STATUS_ERROR);
    }
  }

  get isSyncing() {
    return this.status === STATUS_SYNCING;
  }

  // ── Event bus (unchanged) ─────────────────────────

  on(event, listener) {
    if (!this._listeners.has(event)) this._listeners.set(event, []);
    this._listeners.get(event).push(listener);
    return () => {
      const arr = this._listeners.get(event);
      if (arr) this._listeners.set(event, arr.filter((l) => l !== listener));
    };
  }

  emit(event, data) {
    const listeners = this._listeners.get(event);
    if (!listeners || listeners.length === 0) {
      // An event with no listeners is a useful diagnostic for "synced but the UI
      // didn't update" — it means a subscription gap (e.g. a hook unmounted).
      if (event === 'sync' || event === 'new-message') {
        log.warn('SyncBus', `'${event}' emitted with no listeners — UI may not refresh`);
      }
      return;
    }
    for (const listener of listeners) {
      try { listener(data); } catch (e) {
        log.warn('SyncBus', `listener for '${event}' threw: ${e?.message || e}`);
      }
    }
  }

  subscribe(listener) {
    return this.on('status', listener);
  }

  _setStatus(status) {
    if (this.status === status) return;
    this.status = status;
    this.emit('status', status);
  }
}

// Singleton — survives React strict-mode remounts and HMR.
const syncManager = new SyncManager();
export default syncManager;
