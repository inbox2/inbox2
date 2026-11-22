// OrgLiveMail — realtime "new MX mail arrived" nudges over ActionCable, so the web
// unified/domain inbox refreshes the instant mail lands instead of waiting on the
// 30s polling failsafe (which browsers suspend on a backgrounded tab — the reason
// new mail only appeared after a tab switch).
//
// Rails' InboundMailProcessor broadcasts { type: 'new_message', … } to
// "organization_<key>" for every inbound message; OrganizationChannel serves that
// stream to active org members. We open one subscription per accessible org and,
// on a signal, fire the registered refresh callbacks (throttled + coalesced so a
// burst of arriving mail triggers a single reload).
//
// Singleton (like syncManager / pushSync) so it survives React strict-mode
// remounts and HMR. The token never appears in the URL on web — the socket
// authenticates via the same-site HttpOnly session cookie (see lib/cable.js).
import { getConsumer } from './cable';
import mxMirror from './mxMirror';
import { isTauri } from './tauri.js';
import log from './log';

const THROTTLE_MS = 1200;

class OrgLiveMail {
  constructor() {
    /** @type {Map<string, object>} orgKey → ActionCable subscription */
    this._subs = new Map();
    /** @type {Set<function>} refresh callbacks (inbox hooks) */
    this._listeners = new Set();
    /** @type {Set<function>} domain-list-changed callbacks (AuthProvider.refreshAccount) */
    this._domainListeners = new Set();
    this._throttle = null;
    this._lastFire = 0;
    mxMirror.onChange(() => this._fireThrottled());
    // Desktop: back in the foreground → pull now rather than on the mirror's 60s
    // beat. The browser's lists refetch on focus themselves (useRefetchOnFocus).
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible' && isTauri()) for (const key of this._subs.keys()) mxMirror.kick(key);
      });
    }
  }

  // Register a refresh callback; returns an unsubscribe fn. Called (throttled)
  // whenever new mail lands in ANY subscribed org — the callback decides what to
  // reload (the unified fetch, or the active domain list).
  onNewMail(cb) {
    this._listeners.add(cb);
    return () => this._listeners.delete(cb);
  }

  // Open/close OrganizationChannel subscriptions so they match exactly the given
  // set of org keys (the user's accessible orgs). Idempotent — safe to call on
  // every auth/org change.
  syncOrgs(orgKeys) {
    const want = new Set((orgKeys || []).filter(Boolean));
    // Drop subscriptions for orgs no longer present.
    for (const [key, sub] of this._subs) {
      if (!want.has(key)) {
        try { sub.unsubscribe(); } catch { /* ignore */ }
        this._subs.delete(key);
      }
    }
    // Open subscriptions for newly-present orgs.
    let consumer;
    for (const key of want) {
      if (this._subs.has(key)) continue;
      try {
        consumer ||= getConsumer();
        let reconnect = false;
        const sub = consumer.subscriptions.create(
          { channel: 'OrganizationChannel', key },
          {
            // The ingress drops sockets on config changes / pod swaps; anything
            // broadcast meanwhile is gone, so a reconnect fetches what it missed.
            connected: () => {
              log.info('OrgLiveMail', `● org ${key} connected`);
              if (reconnect) this._catchUp(key);
              reconnect = true;
            },
            disconnected: () => log.warn('OrgLiveMail', `○ org ${key} disconnected`),
            rejected: () => log.warn('OrgLiveMail', `⊘ org ${key} rejected (membership?)`),
            received: (data) => this._onSignal(key, data),
          },
        );
        this._subs.set(key, sub);
      } catch (e) {
        log.warn('OrgLiveMail', `subscribe failed for ${key}: ${e?.message || e}`);
      }
    }
  }

  // Register a callback fired when the org's domain list changes (added/removed/
  // status). Returns an unsubscribe fn. Not throttled — these are rare.
  onDomainChanged(cb) {
    this._domainListeners.add(cb);
    return () => this._domainListeners.delete(cb);
  }

  // Reconnected: act as if every kind of signal had arrived while we were away.
  _catchUp(orgKey) {
    this._onSignal(orgKey, { type: 'domain_changed' });
    this._onSignal(orgKey, isTauri() ? { type: 'sync', scope: 'directory' } : { type: 'new_message' });
  }

  _onSignal(orgKey, data) {
    // Disk writes: the desktop app's Rust side pulls for Finder (docs/Disk-Sync.md). Not mail.
    if (data?.scope === 'disk') return;
    if (data?.type === 'domain_changed') {
      log.info('OrgLiveMail', `◀ domain_changed org=${orgKey}`);
      for (const cb of this._domainListeners) {
        try { cb(); } catch (e) { log.warn('OrgLiveMail', `domain listener failed: ${e?.message || e}`); }
      }
      return;
    }
    // Desktop reads MX mail from the engine's local mirror (docs/MX-Sync.md), so a
    // signal means "pull now"; the lists refresh when the mirror reports a change
    // (see the constructor), not before — a reload ahead of the pull would just
    // re-read the old rows. `sync` is the server's any-write hint: a teammate
    // archived, read, assigned, retagged. The browser has no mirror and keeps
    // reloading on new mail only, as before.
    if (isTauri()) {
      if (data?.type === 'new_message' || data?.type === 'sync') {
        mxMirror.kick(orgKey, { directory: data.scope === 'directory' });
      }
      return;
    }
    if (data?.type !== 'new_message') return;
    log.info('OrgLiveMail', `◀ new_message org=${orgKey} conv=${data.conversation_id || '?'}`);
    this._fireThrottled();
  }

  _fireThrottled() {
    const since = Date.now() - this._lastFire;
    if (since >= THROTTLE_MS) this._fire();
    else if (!this._throttle) this._throttle = setTimeout(() => this._fire(), THROTTLE_MS - since);
  }

  _fire() {
    this._throttle = null;
    this._lastFire = Date.now();
    for (const cb of this._listeners) {
      try { cb(); } catch (e) { log.warn('OrgLiveMail', `listener failed: ${e?.message || e}`); }
    }
  }

  // Tear down every org subscription (called on sign-out).
  reset() {
    for (const [, sub] of this._subs) {
      try { sub.unsubscribe(); } catch { /* ignore */ }
    }
    this._subs.clear();
    clearTimeout(this._throttle);
    this._throttle = null;
  }
}

export default new OrgLiveMail();
