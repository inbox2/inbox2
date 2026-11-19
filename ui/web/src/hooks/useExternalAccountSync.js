import { useState, useEffect, useRef, useCallback } from 'react';
import { isTauri } from '../lib/tauri';
import { isRealOrgId } from '../lib/org';
import log from '../lib/log';
import { scrubIfDemo } from '../lib/demoData';
import syncManager from '../lib/sync-manager';
import pushSync from '../lib/pushSync';
import usePushSync from './usePushSync';
import useSyncRefresh from './useSyncRefresh';
import { isSyncStart, isSyncEnd, formatSyncLogLine, SYNC_PHASE } from '../lib/syncEvents';
import useNavigationStore from '../stores/navigationStore';
import useAccountStore from '../stores/accountStore';
import { SYNC_FOLDERS } from '../lib/storageKeys';

// How often to reconcile the syncing indicator against the engine's
// (authoritative) set, and how long after a `started` to shield an account from
// a get_syncing_accounts snapshot race. Grace must exceed the IPC round-trip.
const RECONCILE_INTERVAL_MS = 30_000;
const RECONCILE_GRACE_MS = 12_000;

export default function useExternalAccountSync({ orgId }) {
  const externalAccounts = useAccountStore(s => s.externalAccounts);
  const setExternalAccounts = useAccountStore(s => s.setExternalAccounts);

  // Cloud push (Gmail/Office365): keep provider subscriptions + the receive
  // websocket in sync with the connected accounts and the user's toggle.
  usePushSync(externalAccounts);

  const activeAccountKey = useNavigationStore(s => s.accountKey);
  const setActiveAccountKey = useCallback((key) => {
    useNavigationStore.getState().navigateTo({ accountKey: key });
  }, []);

  const [addAccountOpen, setAddAccountOpen] = useState(false);
  const [consoleOpen, setConsoleOpen] = useState(false);
  const [syncStatus, setSyncStatus] = useState('disconnected');
  const [syncFolders, _setSyncFolders] = useState(() => {
    try { return JSON.parse(localStorage.getItem(SYNC_FOLDERS) || '[]'); } catch { return []; }
  });
  const setSyncFolders = (folders) => {
    _setSyncFolders(folders);
    try { localStorage.setItem(SYNC_FOLDERS, JSON.stringify(folders)); } catch { /* ignore */ }
  };
  const [syncLogs, setSyncLogs] = useState([]);
  // Deterministic per-account progress, keyed by accountKey, derived from the
  // sync-lifecycle events. Each entry:
  //   { folderName, folderIndex, totalFolders, synced, folderTotal }
  const [syncProgressByAccount, setSyncProgressByAccount] = useState(() => ({}));
  // Ref so lifetime-stable subscriptions/callbacks resolve the current account
  // list for log tags without re-subscribing.
  const externalAccountsRef = useRef(externalAccounts);
  // Seqs of sync events already shown, so the live stream and the on-mount
  // backfill (get_sync_log) don't double-log the same event.
  const seenSeqRef = useRef(new Set());
  const formatLogTime = (ms) =>
    new Date(ms).toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const addSyncLog = (level, message) => {
    const t = Date.now();
    setSyncLogs(prev => [...prev.slice(-300), { t, time: formatLogTime(t), level, message }]);
    const l = level.toLowerCase();
    if (l === 'error') log.error('Sync', message);
    else if (l === 'warn') log.warn('Sync', message);
    else log.info('Sync', message);
  };
  // Render one sync-lifecycle event as a console line (deduped by seq), tagged
  // with the short account name. Shared by the live stream and the backfill.
  const appendSyncEvent = useCallback((p) => {
    if (p?.seq != null) {
      if (seenSeqRef.current.has(p.seq)) return;
      seenSeqRef.current.add(p.seq);
    }
    // Per-account progress for the deterministic bar. Driven from the same
    // events (and the on-mount backfill), so a sync that started before the UI
    // mounted still shows a correct bar — the replayed events settle to the
    // current folder/position.
    const acct = p?.accountKey;
    if (acct) {
      setSyncProgressByAccount((prev) => {
        const next = { ...prev };
        const cur = next[acct] || {};
        switch (p.phase) {
          case SYNC_PHASE.STARTED:
            next[acct] = { folderName: null, folderIndex: 0, totalFolders: 0, synced: 0, folderTotal: null };
            break;
          case SYNC_PHASE.FOLDER_STARTED:
            // New folder → reset the per-folder counters.
            next[acct] = {
              folderName: p.folderName ?? null,
              folderIndex: p.folderIndex ?? 1,
              totalFolders: p.totalFolders ?? cur.totalFolders ?? 1,
              synced: 0,
              folderTotal: null,
            };
            break;
          case SYNC_PHASE.FOLDER_PROGRESS:
          case SYNC_PHASE.FOLDER_COMPLETE: {
            // Background polls emit folder events with no account-level
            // started/completed bracket, so the last folder-complete is their
            // only terminal signal — without this the entry lingers forever
            // and resurfaces as a stale "Syncing <folder>" bar. A bracketed
            // run (startedAtRef holds the account) keeps its entry; `completed`
            // clears it after the trailing calendar phase.
            const folderIndex = p.folderIndex ?? cur.folderIndex ?? 1;
            const totalFolders = p.totalFolders ?? cur.totalFolders ?? 1;
            if (
              p.phase === SYNC_PHASE.FOLDER_COMPLETE &&
              folderIndex >= totalFolders &&
              !startedAtRef.current.has(acct)
            ) {
              delete next[acct];
              break;
            }
            next[acct] = {
              folderName: p.folderName ?? cur.folderName ?? null,
              folderIndex,
              totalFolders,
              synced: p.synced ?? cur.synced ?? 0,
              folderTotal: p.folderTotal ?? cur.folderTotal ?? null,
            };
            break;
          }
          case SYNC_PHASE.COMPLETED:
          case SYNC_PHASE.FAILED:
            delete next[acct];
            break;
          default:
            break;
        }
        return next;
      });
    }
    const line = formatSyncLogLine(p);
    if (!line) return;
    const tag = externalAccountsRef.current.find(a => a.key === p.accountKey)?.email_address?.split('@')[0];
    const t = p.at || Date.now();
    const message = tag ? `[${tag}] ${line.message}` : line.message;
    setSyncLogs(prev => [...prev.slice(-300), { t, time: formatLogTime(t), level: line.level, message }]);
  }, []);

  // Accounts the engine reports as actively syncing (started → completed/failed
  // from the sync-lifecycle event). Status bar shows "Syncing…" while non-empty.
  const [syncingAccounts, setSyncingAccounts] = useState(() => new Set());
  const isSyncing = syncingAccounts.size > 0;
  const [syncDiagnostics, setSyncDiagnostics] = useState(null);
  // Wall-clock of the last `started` per account, so periodic reconciliation can
  // protect a just-started account from a get_syncing_accounts snapshot race.
  const startedAtRef = useRef(new Map());

  useEffect(() => { externalAccountsRef.current = externalAccounts; }, [externalAccounts]);

  // Single sync-lifecycle subscription: drives the syncing indicator AND the
  // Sync Console log from the one `sync` event (no separate sync-state/sync-log).
  useEffect(() => {
    return syncManager.on('sync', (p) => {
      if (isSyncStart(p)) {
        if (p.accountKey) startedAtRef.current.set(p.accountKey, Date.now());
        setSyncingAccounts(prev => new Set(prev).add(p.accountKey));
      } else if (isSyncEnd(p)) {
        if (p.accountKey) startedAtRef.current.delete(p.accountKey);
        setSyncingAccounts((prev) => {
          const next = new Set(prev);
          next.delete(p.accountKey);
          return next;
        });
      }
      appendSyncEvent(p);
    });
  }, [appendSyncEvent]);

  // Self-heal the syncing indicator. The engine's `syncing` set is authoritative
  // (maintained by a cancellation-safe guard); the UI's set is event-derived and
  // can drift if a terminal event is ever missed — e.g. a `completed` fired in a
  // brief no-listener window on reload (the SyncBus "no listeners" warnings).
  // Periodic reconciliation against the engine means the indicator can never
  // latch the way it did when a leaked account was seeded but never cleared.
  useEffect(() => {
    if (!isTauri()) return;
    let cancelled = false;
    const reconcile = async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        const syncing = await invoke('get_syncing_accounts');
        if (cancelled) return;
        const engineSet = new Set(syncing || []);
        setSyncingAccounts((prev) => {
          const now = Date.now();
          const next = new Set(engineSet);
          // Shield a just-started account: a `started` that landed after the
          // engine snapshotted its set isn't in engineSet yet, but it really is
          // syncing — keep it until the grace window passes.
          prev.forEach((k) => {
            const at = startedAtRef.current.get(k);
            if (at && now - at < RECONCILE_GRACE_MS) next.add(k);
          });
          if (prev.size === next.size && [...prev].every((k) => next.has(k))) return prev;
          log.info('SyncIndicator', `reconciled syncing set -> ${JSON.stringify([...next])}`);
          return next;
        });
      } catch (e) {
        if (!cancelled) log.warn('SyncIndicator', `reconcile failed: ${e?.message || e}`);
      }
    };
    const id = setInterval(reconcile, RECONCILE_INTERVAL_MS);
    return () => { cancelled = true; clearInterval(id); };
  }, []);

  // Boot sync on mount. Sync runs in the Rust engine (which auto-starts stored
  // accounts on launch); here we just bridge events and ensure a sync kick.
  useEffect(() => {
    if (!isTauri()) return;
    let cancelled = false;
    (async () => {
      // Hand Rust the API context + start bridging engine events to the UI bus.
      await syncManager.init();
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        const accounts = scrubIfDemo(await invoke('list_external_accounts'));
        log.info('Boot', `External accounts: ${accounts.length} [${accounts.map(a => a.provider_type).join(', ')}]`);
        if (cancelled) return;
        setExternalAccounts(accounts);

        // Seed the syncing indicator from any sync already in flight — e.g. the
        // initial import kicked off during setup, still running as we mount here.
        // Without this the "syncing started" event fired before we subscribed.
        try {
          const syncing = await invoke('get_syncing_accounts');
          log.info('SyncIndicator', `boot: ${syncing?.length || 0} account(s) already syncing ${JSON.stringify(syncing || [])}`);
          if (!cancelled && syncing?.length) setSyncingAccounts(new Set(syncing));
        } catch (e) {
          log.warn('SyncIndicator', `get_syncing_accounts failed: ${e?.message || e}`);
        }

        // Backfill the Sync Console from the engine's retained event buffer, so
        // it shows the whole run (started → folders → completed) even when this
        // mounted mid-sync (e.g. right after setup) and missed the early events.
        // Deduped by seq against the live stream in appendSyncEvent.
        try {
          const events = await invoke('get_sync_log');
          if (!cancelled && events?.length) events.forEach(appendSyncEvent);
        } catch (e) {
          log.warn('SyncLog', `get_sync_log backfill failed: ${e?.message || e}`);
        }

        // Default to the first account only when nothing is targeted yet. Guard on
        // the URL too: this boot effect can run before the navigation store has
        // synced from an account URL (child effects fire before NavigationSync),
        // and without this check a click on an account tab would be overridden by
        // accounts[0] on the org-less /mail/account/:key route.
        const onAccountRoute = window.location.pathname.includes('/mail/account/');
        if (accounts.length > 0 && !activeAccountKey && !isRealOrgId(orgId) && !onAccountRoute) {
          log.info('Boot', `Auto-selected account: ${accounts[0].key}`);
          setActiveAccountKey(accounts[0].key);
        }

        // The Rust engine boots stored accounts itself; just track them and
        // kick an immediate sync (mail + calendar both run server-side). The
        // sync emits the lifecycle events (started/…/completed) that drive the
        // indicator, console log, and refresh.
        const newAccounts = accounts.filter(a => !syncManager.has(a.key));
        newAccounts.forEach(a => {
          syncManager.register(a.key);
          addSyncLog('INFO', `Sync started for ${a.email_address}`);
        });
        if (newAccounts.length) syncManager.resyncAll().catch(() => {});
      } catch (err) {
        log.warn('Boot', `Failed to list accounts: ${err?.message || err}`);
      }
    })();
    return () => { cancelled = true; };
  // eslint-disable-next-line react-hooks/exhaustive-deps -- boot once; activeAccountKey/orgId are read but must not re-trigger
  }, [setExternalAccounts, setActiveAccountKey]);

  // Handle account removal events
  const onAccountRemovedRef = useRef(null);
  useEffect(() => {
    const handler = (e) => {
      const { key } = e.detail || {};
      if (!key) return;
      syncManager.unregister(key);
      setExternalAccounts(prev => prev.filter(a => a.key !== key));
      if (activeAccountKey === key) {
        setActiveAccountKey(null);
        onAccountRemovedRef.current?.();
      }
    };
    window.addEventListener('external-account-removed', handler);
    return () => window.removeEventListener('external-account-removed', handler);
  }, [activeAccountKey, setActiveAccountKey, setExternalAccounts]);

  // Poll sync status (+ folders/diagnostics, but only while the Sync Console is
  // open — those feed nothing else, so fetching them when it's closed is waste).
  const pollSyncStatus = useCallback(async () => {
    if (!isTauri() || !activeAccountKey) return;
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      const accounts = scrubIfDemo(await invoke('list_external_accounts'));
      if (accounts.length > 0) {
        setExternalAccounts(accounts);
        const entry = accounts.find(a => a.key === activeAccountKey);
        setSyncStatus(entry?.status || 'disconnected');
      }
      // Folders drive the sidebar folder views (and the default activeView), so
      // they're always needed — not just for the console.
      const folders = await invoke('list_external_folders', { accountKey: activeAccountKey });
      setSyncFolders(folders);
      // Diagnostics only feed the Sync Console — skip the extra queries when closed.
      if (consoleOpen) {
        try {
          const diag = await invoke('get_account_diagnostics', { accountKey: activeAccountKey });
          setSyncDiagnostics(diag);
        } catch { /* diagnostics are best-effort */ }
      }
    } catch { /* silently retry */ }
  // setSyncFolders is recreated each render; the others are stable. Re-bind only
  // when the account or console-open state changes.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeAccountKey, consoleOpen]);

  // Initial load on mount / account / console-open change. pollSyncStatus is
  // async (state set after awaiting IPC), so set-state-in-effect is a false
  // positive here.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    pollSyncStatus();
  }, [pollSyncStatus]);

  // Then refresh on sync activity (and the built-in slow failsafe), so status +
  // console track the import without a dedicated poll loop.
  useSyncRefresh(pollSyncStatus);

  const handleAddAccount = async (params) => {
    if (!isTauri()) throw new Error('Connect this account from the desktop app');
    const { invoke } = await import('@tauri-apps/api/core');
    const result = await invoke('add_external_account', { request: params });
    setExternalAccounts(prev => [...prev, result]);
    setActiveAccountKey(result.key);
    try {
      await invoke('start_sync', { accountKey: result.key });
      addSyncLog('INFO', `Connected to ${params.host}:${params.port}`);
    } catch (e) {
      addSyncLog('ERROR', `Sync failed: ${e}`);
    }
  };

  // Meta BYOK channels (Instagram/Messenger/WhatsApp). Creates the account with
  // its encrypted credential bundle, then starts a sync (which validates the
  // token, subscribes the app webhooks, and registers the relay).
  const handleAddMetaAccount = async (request) => {
    if (!isTauri()) throw new Error('Connect WhatsApp, Messenger and Instagram from the desktop app');
    const { invoke } = await import('@tauri-apps/api/core');
    const result = await invoke('add_meta_account', { request });
    setExternalAccounts(prev => [...prev, result]);
    setActiveAccountKey(result.key);
    await syncManager.init();
    syncManager.register(result.key);
    try {
      await invoke('start_sync', { accountKey: result.key });
      addSyncLog('INFO', `${request.channel} account connected`);
      pushSync.ensureForAccount(result).catch(() => {});
    } catch (e) {
      addSyncLog('ERROR', `${request.channel} sync failed: ${e?.message || e}`);
    }
  };

  // Gmail/Microsoft sync (mail + calendar) now runs in the Rust engine; the
  // account row already holds the encrypted tokens, so we just kick off a sync.
  const startProviderSync = async (accountResult, provider, email) => {
    setExternalAccounts(prev => [...prev, accountResult]);
    setActiveAccountKey(accountResult.key);
    addSyncLog('INFO', `${provider} account connected: ${email}`);
    await syncManager.init();
    syncManager.register(accountResult.key);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('start_sync', { accountKey: accountResult.key });
      addSyncLog('INFO', `${provider} sync started for ${email}`);
      // Register cloud push for the new channel: check the backend, else register.
      pushSync.ensureForAccount(accountResult).catch(() => {});
    } catch (e) {
      addSyncLog('ERROR', `${provider} sync failed: ${e?.message || e}`);
    }
  };

  const handleGmailConnected = (accountResult, _accessToken, _refreshToken, email) =>
    startProviderSync(accountResult, 'Gmail', email);

  const handleMicrosoftConnected = (accountResult, _accessToken, _refreshToken, email) =>
    startProviderSync(accountResult, 'Microsoft', email);

  const handleRefresh = useCallback(() => {
    addSyncLog('INFO', 'Manual resync triggered');
    syncManager.resyncAll().catch(e => {
      addSyncLog('ERROR', `Resync failed: ${e.message || e}`);
    });
  }, []);

  const handleRefreshChannel = useCallback((accountKey) => {
    addSyncLog('INFO', `Manual resync for ${accountKey}`);
    syncManager.resyncChannel(accountKey).catch(e => {
      addSyncLog('ERROR', `Channel resync failed: ${e.message || e}`);
    });
  }, []);

  // Progress for the bar above the inbox — strictly the active account's, so we
  // never show one account's progress on another. In the unified view (no
  // active account) fall back to whichever account is currently syncing.
  const syncProgress = activeAccountKey
    ? (syncProgressByAccount[activeAccountKey] || null)
    : (syncProgressByAccount[Object.keys(syncProgressByAccount)[0]] || null);

  // The bar should only appear when the account the user is looking at is
  // syncing — not whenever *any* account is (the global `isSyncing`).
  const isActiveSyncing = activeAccountKey
    ? syncingAccounts.has(activeAccountKey)
    : isSyncing;

  return {
    externalAccounts,
    setExternalAccounts,
    activeAccountKey,
    setActiveAccountKey,
    syncStatus,
    syncFolders,
    syncProgress,
    syncLogs,
    syncDiagnostics,
    addSyncLog,
    addAccountOpen, setAddAccountOpen,
    consoleOpen, setConsoleOpen,
    syncManager,
    isSyncing,
    isActiveSyncing,
    handleRefresh,
    handleRefreshChannel,
    handleAddAccount,
    handleAddMetaAccount,
    handleGmailConnected,
    handleMicrosoftConnected,
    onAccountRemovedRef,
  };
}
