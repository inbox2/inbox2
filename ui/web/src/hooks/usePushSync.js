// usePushSync — owns the cloud-push lifecycle for local channels (Gmail/Office365).
//
// On mount (and whenever the connected accounts change) it ensures a provider
// push subscription exists for each channel and opens the PushSyncChannel
// websocket. It reacts to the user's cloud-push toggle, and reconciles missed
// pushes: while offline the per-mailbox signals are dropped, so on regaining
// connectivity it kicks a full resync to catch up. See docs/Cloud-Push.md.
import { useEffect, useRef } from 'react';
import { isTauri } from '../lib/tauri';
import pushSync from '../lib/pushSync';
import syncManager from '../lib/sync-manager';
import useCloudPushPref from '../lib/cloudPushPref';

export default function usePushSync(externalAccounts) {
  const { enabled } = useCloudPushPref();
  // Stable ref so the online/offline listener always sees the latest accounts
  // without re-binding the window listeners on every account change.
  const accountsRef = useRef(externalAccounts);
  useEffect(() => { accountsRef.current = externalAccounts; }, [externalAccounts]);

  // Register / tear down as the toggle flips or accounts change.
  useEffect(() => {
    if (!isTauri()) return;
    if (enabled) {
      pushSync.ensureForAll(externalAccounts || []);
    } else {
      pushSync.disableAll(externalAccounts || []);
    }
  }, [enabled, externalAccounts]);

  // Offline catch-up: pushes that arrived while offline were missed, so on
  // reconnect (and when the tab regains visibility) resync everything once.
  useEffect(() => {
    if (!isTauri()) return;
    const onOnline = () => {
      if (!enabled) return;
      // Re-ensure subscriptions (ActionCable auto-reconnects) and catch up.
      pushSync.ensureForAll(accountsRef.current || []);
      syncManager.resyncAll().catch(() => {});
    };
    window.addEventListener('online', onOnline);
    return () => window.removeEventListener('online', onOnline);
  }, [enabled]);
}
