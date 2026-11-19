// PushSync — receives cloud-push "go sync" signals over ActionCable and drives a
// channel resync, plus orchestrates provider-subscription registration via the
// Rust engine. The token never leaves the client: the engine creates the provider
// subscription (Gmail watch / Graph subscription) pointing at our Rails backend,
// Rails fans out a content-free signal here, and we trigger a normal sync.
//
// Singleton (like syncManager) so it survives React strict-mode remounts and HMR.
// See docs/Cloud-Push.md.
import { getConsumer } from './cable';
import api from './api';
import syncManager from './sync-manager';
import useAccountStore from '../stores/accountStore';
import { getCloudPushPref } from './cloudPushPref';
import { isTauri } from './tauri';
import { PROVIDER } from './providerTypes';
import { scrubIfDemo } from './demoData';
import log from './log';

// Map a connected-account row to its cloud-push provider, or null (IMAP/unknown).
function providerOf(account) {
  const t = (account?.provider_type || '').toLowerCase();
  if (t === PROVIDER.GMAIL) return PROVIDER.GMAIL;
  if (t === PROVIDER.MICROSOFT) return PROVIDER.MICROSOFT;
  return null;
}

// Meta channels deliver over the same PushSyncChannel (as `meta_event` nudges),
// but registration is engine-driven on connect — the frontend only needs the
// websocket open to receive them.
const META_PROVIDERS = ['instagram', 'messenger', 'whatsapp'];
function isMetaAccount(account) {
  return META_PROVIDERS.includes((account?.provider_type || '').toLowerCase());
}

// Rails' cable alert → the engine's NewMessageNotification shape. `key` is the
// conversation; orgId/orgSlug stand in for the local account key
// (lib/notificationActions.js routes on providerType).
function mxAlert(d) {
  return {
    key: d.conversation_id,
    messageKey: d.message_id,
    subject: d.subject,
    from_address: d.from_address,
    snippet: d.snippet,
    updated_at: d.updated_at,
    providerType: PROVIDER.INBOX2,
    orgId: d.organization_id,
    orgSlug: d.workspace_slug,
    accountKey: null,
    hasAttachment: false,
    invite: d.invite || null,
    // A sign-in code or link Rails found (OtpDetector) — docs/Notifications.md.
    otp: d.otp || null,
  };
}

class PushSync {
  constructor() {
    this._subscription = null;
    // accountKeys already checked/registered this session — avoids re-firing the
    // GET on every externalAccounts store churn (sync-progress updates, etc.).
    this._ensured = new Set();
    // Mailboxes signalled before the account store hydrated — flushed by
    // ensureForAll once the engine's accounts land. See _onSignal.
    this._pending = new Set();
    // Callback fired when the server revokes this user (admin disabled/deleted
    // them). Registered by AuthProvider; clears the session in real time.
    this._onForceLogout = null;
  }

  // Register the real-time revocation handler (AuthProvider wires this to a
  // session teardown). The PushSyncChannel must be open for it to fire — see
  // ensureSessionListener.
  onForceLogout(cb) { this._onForceLogout = cb; }

  // Open the per-user channel for *any* authenticated client (web included),
  // independent of cloud-push/Tauri gating, so a force_logout kick always lands.
  ensureSessionListener() { this._ensureChannel(); }

  // Open the per-user PushSyncChannel (idempotent). ActionCable handles
  // reconnect/backoff; we just route received signals to a channel resync.
  _ensureChannel() {
    if (this._subscription) return;
    try {
      const consumer = getConsumer();
      let reconnect = false;
      this._subscription = consumer.subscriptions.create(
        { channel: 'PushSyncChannel' },
        {
          // A channel_sync nudge sent while the socket was down is lost: on a
          // reconnect, resync the push-driven mailboxes so the mail still lands.
          // (MX alerts aren't replayed; the lists catch up via OrgLiveMail.)
          connected: () => {
            log.info('PushSync', '● PushSyncChannel connected');
            if (reconnect && isTauri() && this._ensured.size) syncManager.resyncAll().catch(() => {});
            reconnect = true;
          },
          disconnected: () => log.warn('PushSync', '○ PushSyncChannel disconnected'),
          // TERMINAL, not a blip: Rails answers reject_unauthorized_connection
          // with `reconnect: false`, and @rails/actioncable calls monitor.stop()
          // on that — no retry for the life of the webview. Say so, because the
          // socket looks merely "not connected" from here on.
          rejected: () => log.warn('PushSync', '⊘ PushSyncChannel REJECTED (bad/absent bearer) — will not retry until reload'),
          received: (data) => this._onSignal(data),
        },
      );
      log.info('PushSync', 'subscribing to PushSyncChannel…');
    } catch (e) {
      log.warn('PushSync', `subscribe failed: ${e?.message || e}`);
    }
  }

  _dropChannel() {
    if (!this._subscription) return;
    try { this._subscription.unsubscribe(); } catch { /* ignore */ }
    this._subscription = null;
    log.info('PushSync', 'unsubscribed from PushSyncChannel');
  }

  _onSignal(data) {
    // MX mail: Rails sends the finished alert to exactly the users it alerts on
    // mobile (MobilePushSender.new_message). Hand it to the same 'new-message'
    // bus the engine feeds for local channels, so it gets the same cards, system
    // notification, sound and activity feed — desktop and browser alike. Logged
    // by id only: the payload is mail content, and demo mode scrubs only the emit.
    if (data && data.type === 'new_message') {
      log.info('PushSync', `◀ new_message conv=${data.conversation_id} org=${data.organization_id}`);
      syncManager.emit('new-message', scrubIfDemo(mxAlert(data)));
      return;
    }
    // Verbose on purpose — this is the live-test trace of the cloud-push round-trip.
    log.info('PushSync', `◀ signal received ${JSON.stringify(data)}`);
    // Real-time access revocation: an admin disabled or deleted this user. Tear
    // down the session immediately rather than waiting for the next API 401.
    if (data && data.type === 'force_logout') {
      log.warn('PushSync', `force logout (${data.reason || 'access_revoked'})`);
      try { this._onForceLogout?.(data); } catch (e) { log.warn('PushSync', `force logout handler failed: ${e?.message || e}`); }
      return;
    }
    // Meta channels (Instagram/Messenger/WhatsApp): the nudge carries the relay
    // buffer key; the engine fetches the raw payload, verifies the HMAC against
    // the local app_secret, and normalizes. See docs/Cloud-Push.md (Meta).
    if (data && data.type === 'meta_event') {
      this._onMetaEvent(data);
      return;
    }
    if (!data || data.type !== 'channel_sync') {
      log.warn('PushSync', `ignored signal (unexpected type=${data?.type})`);
      return;
    }
    // Engine-only: local channels live in Rust, so a browser tab has no
    // externalAccounts and nothing to resync. It still holds the channel open for
    // force_logout, so it sees the desktop's signals — drop them quietly.
    if (!isTauri()) return;
    const email = (data.email || '').toLowerCase();
    const account = useAccountStore.getState().externalAccounts
      .find((a) => (a.email_address || '').toLowerCase() === email);
    if (!account) {
      // The channel opens the moment the user is authenticated (for force_logout),
      // which is well before the engine has listed the local accounts — a signal
      // landing in that window used to be dropped, and the mail only appeared on
      // the next manual resync. Hold it; ensureForAll flushes when accounts land.
      this._pending.add(email);
      const known = useAccountStore.getState().externalAccounts
        .map((a) => a.email_address).join(', ');
      log.warn('PushSync', `signal for unknown mailbox ${email} (connected: ${known || 'none'}) — deferred`);
      return;
    }
    this._resync(account, email, data);
  }

  _resync(account, email, data = {}) {
    log.info('PushSync', `push → resync ${email} (${account.key}, provider=${data.provider}, historyId=${data.history_id ?? '–'})`);
    const t0 = Date.now();
    syncManager.resyncChannel(account.key)
      .then(() => log.info('PushSync', `✔ resync done ${email} in ${Date.now() - t0}ms`))
      .catch((e) => log.warn('PushSync', `✗ resync failed ${email}: ${e?.message || e}`));
  }

  // Replay signals that arrived before their account was known. Emails that never
  // match (mailbox removed on this device, subscription still live) just sit in
  // the set — bounded by the user's subscription count.
  _flushPending(accounts) {
    if (this._pending.size === 0) return;
    for (const email of [...this._pending]) {
      const account = (accounts || [])
        .find((a) => (a.email_address || '').toLowerCase() === email);
      if (!account) continue;
      this._pending.delete(email);
      log.info('PushSync', `flushing deferred signal for ${email}`);
      this._resync(account, email);
    }
  }

  // Drive ingestion of a buffered Meta webhook event through the engine.
  _onMetaEvent(data) {
    const eventKey = data.event_key;
    if (!eventKey) {
      log.warn('PushSync', 'meta_event missing event_key');
      return;
    }
    if (!isTauri()) return; // engine-only path
    const t0 = Date.now();
    import('@tauri-apps/api/core')
      .then(({ invoke }) => invoke('ingest_meta_event', { eventKey }))
      .then((applied) => log.info('PushSync', `✔ meta ingest ${eventKey} applied=${applied} in ${Date.now() - t0}ms`))
      .catch((e) => log.warn('PushSync', `✗ meta ingest ${eventKey} failed: ${e?.message || e}`));
  }

  // Check Rails for an existing subscription; register via the engine if absent
  // and push is enabled (both the client toggle and the backend gate). This is
  // the "after a channel is added, check the backend, else register" flow.
  async ensureForAccount(account) {
    if (!isTauri()) return;
    if (!getCloudPushPref().enabled) return;
    // Meta accounts: just open the websocket (the engine registers the relay on
    // connect); no provider subscription to create from the frontend.
    if (isMetaAccount(account)) {
      if (!(await api.getToken())) return;
      if (this._ensured.has(account.key)) return;
      this._ensureChannel();
      this._ensured.add(account.key);
      return;
    }
    if (!providerOf(account)) return;
    // No Rails auth token (no web session / no ink_ API key) → cloud push isn't
    // available for this client; stay on polling instead of firing unauthenticated
    // 401s at the API. Read from the secret store (the portable source of truth).
    if (!(await api.getToken())) return;
    if (this._ensured.has(account.key)) return; // already handled this session

    const email = account.email_address;
    try {
      const res = await api.get(`/channel-push-subscriptions?email=${encodeURIComponent(email)}`);
      if (!res.push_enabled) return; // backend gate off → stay on polling
      this._ensureChannel();
      this._ensured.add(account.key);
      if ((res.subscriptions || []).length > 0) return; // already registered (this/another device)

      const { invoke } = await import('@tauri-apps/api/core');
      const registered = await invoke('register_push', { accountKey: account.key });
      log.info('PushSync', `register_push(${email}) → ${registered}`);
    } catch (e) {
      log.warn('PushSync', `ensureForAccount(${email}) failed: ${e?.message || e}`);
    }
  }

  // Independent per account — run them concurrently. ensureForAccount carries the
  // enabled/provider/dedup guards, so callers don't need to pre-filter.
  async ensureForAll(accounts) {
    this._flushPending(accounts);
    await Promise.all((accounts || []).map((a) => this.ensureForAccount(a)));
  }

  // Toggle-off / sign-out: drop the websocket and tear down provider subs.
  async disableAll(accounts) {
    this._dropChannel();
    this._ensured.clear();
    this._pending.clear();
    if (!isTauri()) return;
    const { invoke } = await import('@tauri-apps/api/core');
    await Promise.all((accounts || [])
      .filter((a) => providerOf(a))
      .map((a) => invoke('deregister_push', { accountKey: a.key })
        .catch((e) => log.warn('PushSync', `deregister(${a.email_address}) failed: ${e?.message || e}`))));
  }
}

const pushSync = new PushSync();
export default pushSync;
