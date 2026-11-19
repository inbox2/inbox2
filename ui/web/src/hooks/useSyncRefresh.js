import { useEffect, useRef } from 'react';
import syncManager from '../lib/sync-manager';
import { isDataChange } from '../lib/syncEvents';

/**
 * Push-based refresh: the sync engine alerts subscribers when data changes, and
 * each subscriber decides whether the alert is relevant to what it's showing.
 *
 * `onRefresh(alert)` is called (throttled) on sync activity. `alert` is the
 * union of the engine events coalesced during the throttle window:
 *   { accountKeys: Set, folderKeys: Set, conversationKeys: Set }
 * or `null` for the periodic failsafe tick (treat null as "refresh anyway").
 *
 * Subscribers scope themselves, e.g.:
 *   useSyncRefresh(a => { if (!a || a.accountKeys.has(key)) reloadList() })
 *   useSyncRefresh(a => { if (!a || a.conversationKeys.has(id)) reloadThread() })
 *
 * The callback is held in a ref so the subscription stays mounted for the
 * component's lifetime (no re-bind churn when the callback identity changes).
 *
 * @param {(alert: {accountKeys:Set,folderKeys:Set,conversationKeys:Set}|null) => void} onRefresh
 * @param {{ throttleMs?: number, failsafeMs?: number }} [opts]
 */
export default function useSyncRefresh(
  onRefresh,
  { throttleMs = 1500, failsafeMs = 30000 } = {},
) {
  const onRefreshRef = useRef(onRefresh);
  useEffect(() => { onRefreshRef.current = onRefresh; }, [onRefresh]);

  useEffect(() => {
    let timer = null;
    let last = 0;
    let pending = null;
    const acc = () => (pending ||= {
      accountKeys: new Set(), folderKeys: new Set(), conversationKeys: new Set(),
    });
    const fire = () => {
      timer = null;
      last = Date.now();
      const alert = pending;
      pending = null;
      onRefreshRef.current?.(alert);
    };
    // Only data-change phases (folder-progress / folder-complete-with-changes)
    // trigger a refresh; started/completed/failed are lifecycle, not data.
    const onSync = (payload) => {
      if (!isDataChange(payload)) return;
      const a = acc();
      if (payload.accountKey) a.accountKeys.add(payload.accountKey);
      if (payload.folderKey) a.folderKeys.add(payload.folderKey);
      for (const k of payload.conversationKeys || []) a.conversationKeys.add(k);
      const since = Date.now() - last;
      if (since >= throttleMs) fire();
      else if (!timer) timer = setTimeout(fire, throttleMs - since);
    };
    const unsub = syncManager.on('sync', onSync);
    // Slow failsafe: forces a refresh (null alert) in case an event was missed.
    const failsafe = setInterval(() => onRefreshRef.current?.(null), failsafeMs);
    return () => {
      unsub();
      clearTimeout(timer);
      clearInterval(failsafe);
    };
  }, [throttleMs, failsafeMs]);
}
