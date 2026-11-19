import { useEffect } from 'react';
import log from '../lib/log';
import useAuth from './useAuth';
import { isTauri } from '../lib/tauri';
import { getConsumer } from '../lib/cable';
import useZoneStore from '../stores/zoneStore';
import useNotificationStore, { ZONE_EVENT, isZoneAlert } from '../stores/notificationStore';
import { deliverMeetingAlert } from './useMeetingReminders';
import { categoryFor, isActive, loadDismissed, markDismissed } from '../lib/zones';
import { ZONE_DISMISSED } from '../lib/storageKeys';

/**
 * useZoneAlerts — raises "You're in the zone" when a zone starts
 * (docs/Calendar.md "Zones"), on the surface the notification mode picks:
 * the always-on-top card window on desktop, the in-app popup in the browser.
 * The card never times out; it waits until it's clicked away, and that choice
 * is remembered (lib/zones markDismissed) so a reload doesn't raise it again.
 *
 * Also keeps the zone store fed around "now" for the menu bar countdown and
 * the sidebar, whatever page is open. Mount once, next to useMeetingReminders.
 */

const TICK_MS = 30 * 1000;
const REFETCH_MS = 5 * 60 * 1000;
const WINDOW_BACK_MS = 12 * 60 * 60 * 1000;
const WINDOW_AHEAD_MS = 36 * 60 * 60 * 1000;

const clock = (iso) => new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

export function buildZoneAlert(zone, category) {
  const color = category?.color || 'blue';
  return {
    eventType: ZONE_EVENT,
    eventLabel: "You're in the zone",
    priority: 'urgent',
    eventColor: `zone_${color}`,
    key: `zone:${zone.id}`,
    zoneId: zone.id,
    subject: zone.name,
    title: zone.name,
    note: zone.note || null,
    timeLine: `${category?.name || 'Zone'} · until ${clock(zone.end_at)}`,
    startAt: zone.start_at,
    endAt: zone.end_at,
    updated_at: zone.start_at,
  };
}

// Shown this session — the dismissed record covers the rest. A card still up
// in the desktop window when the app restarts comes back until it's clicked.
// id → end_at, so a card whose zone was deleted can be taken down (sweepDeleted).
const shown = new Map();

/**
 * A card clicked away on another device: record it locally (no echo to the
 * server) and take down this device's card, wherever it is showing.
 */
function applyRemoteDismissal(zoneId, endAt) {
  if (!zoneId) return;
  const store = useNotificationStore.getState();
  const card = store.notifications.find(n => isZoneAlert(n) && n.zoneId === zoneId);
  if (card) store.dismiss(card._alertId, { remote: true });
  else markDismissed({ id: zoneId, end_at: endAt || new Date().toISOString() }, { remote: true });
  if (isTauri()) {
    import('@tauri-apps/api/event')
      .then(({ emitTo }) => emitTo('notification', 'zone-card-remove', { zoneId }))
      .catch(() => { /* window not open */ });
  }
}

/**
 * A raised card whose zone is gone from a fresh fetch was deleted (here or on
 * another device): take the card down. Zones that simply aged out of the fetch
 * window are left alone — their card waits for its click like any other.
 */
function sweepDeleted(zones, now) {
  const ids = new Set(zones.map(z => z.id));
  for (const [id, endAt] of shown) {
    if (ids.has(id) || Date.parse(endAt) < now - WINDOW_BACK_MS) continue;
    shown.delete(id);
    applyRemoteDismissal(id, endAt);
  }
}

export default function useZoneAlerts() {
  const { user } = useAuth();

  useEffect(() => {
    // Signed out: nothing of the last account's zones may leak into the next one.
    if (!user) {
      shown.clear();
      useZoneStore.getState().reset();
      return undefined;
    }
    let alive = true;
    let fetchedAt = 0;

    const tick = async () => {
      const now = Date.now();
      if (now - fetchedAt > REFETCH_MS) {
        fetchedAt = now;
        const store = useZoneStore.getState();
        if (!store.categories.length) await store.loadCategories();
        await store.loadRange(new Date(now - WINDOW_BACK_MS), new Date(now + WINDOW_AHEAD_MS));
      }
      if (!alive) return;

      const { zones, categories } = useZoneStore.getState();
      sweepDeleted(zones, now);
      const dismissed = loadDismissed();
      for (const zone of zones) {
        // Dismissed on another device (the server's flag): take our card down too.
        if (zone.dismissed && !dismissed[zone.id]) { applyRemoteDismissal(zone.id, zone.end_at); continue; }
        if (!zone.notify || !isActive(zone, now) || dismissed[zone.id] || zone.dismissed || shown.has(zone.id)) continue;
        shown.set(zone.id, zone.end_at);
        const mode = deliverMeetingAlert(buildZoneAlert(zone, categoryFor(zone, categories)));
        log.info('ZoneAlerts', `fire mode=${mode} "${zone.name}"`);
      }
    };

    tick();
    const timer = setInterval(tick, TICK_MS);
    // A zone deleted here (editor, right-click) takes its card down at once. Only
    // a delete: an edit drops the series' occurrences before refetching them, and
    // sweeping then would dismiss the card the edit means to raise again.
    const unsubZones = useZoneStore.subscribe((st, prev) => {
      if (st.deletions !== prev.deletions) sweepDeleted(st.zones, Date.now());
    });
    // Back from sleep or another app: refetch now rather than on the next slot.
    const onFocus = () => { if (document.visibilityState !== 'hidden') { fetchedAt = 0; tick(); } };
    window.addEventListener('focus', onFocus);
    document.addEventListener('visibilitychange', onFocus);

    // Another device wrote a zone, category or dismissal (ZoneChannel): apply a
    // dismissal at once, then refetch — both the alert window and whatever the
    // calendar has on screen.
    let sub = null;
    let reconnect = false;
    const refetchAll = () => {
      fetchedAt = 0;
      tick();
      const store = useZoneStore.getState();
      store.refresh();
      store.loadCategories();
    };
    try {
      sub = getConsumer().subscriptions.create({ channel: 'ZoneChannel' }, {
        // Changes broadcast while the socket was down are lost: refetch on reconnect.
        connected: () => { if (reconnect) refetchAll(); reconnect = true; },
        received: (data) => {
          if (data?.type !== 'zones_changed') return;
          if (data.dismissed) applyRemoteDismissal(data.dismissed);
          refetchAll();
        },
      });
    } catch (e) {
      log.warn('ZoneAlerts', `subscribe failed: ${e?.message || e}`);
    }

    return () => {
      alive = false;
      clearInterval(timer);
      unsubZones();
      window.removeEventListener('focus', onFocus);
      document.removeEventListener('visibilitychange', onFocus);
      try { sub?.unsubscribe(); } catch { /* socket already gone */ }
    };
  }, [user]);

  // Done/✕ on a card in the standalone notification window.
  useEffect(() => {
    if (!isTauri()) return undefined;
    let unlisten;
    let disposed = false;
    import('@tauri-apps/api/event')
      .then(({ listen }) => listen('zone-dismiss', (e) => markDismissed({ id: e.payload?.zoneId, end_at: e.payload?.endAt })))
      .then((fn) => { if (disposed) fn(); else unlisten = fn; })
      .catch((e) => log.warn('ZoneAlerts', `listen failed: ${e?.message || e}`));
    return () => { disposed = true; if (unlisten) unlisten(); };
  }, []);

  // Browser: a card clicked away in another tab goes away here too.
  useEffect(() => {
    const onStorage = (e) => {
      if (e.key !== ZONE_DISMISSED) return;
      const dismissed = loadDismissed();
      const store = useNotificationStore.getState();
      for (const n of store.notifications) {
        if (isZoneAlert(n) && dismissed[n.zoneId]) store.dismiss(n._alertId, { remote: true });
      }
    };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);
}
