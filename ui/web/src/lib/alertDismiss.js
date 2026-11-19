// Close a new-mail alert as soon as its thread leaves the inbox from anywhere
// else (deleted, archived or marked spam in the conversation view, search, Lore…).
// A card still offering "Delete" for mail you just deleted is stale, so it goes
// at once instead of waiting out its timer.
//
// Called from the two action primitives every dispatcher funnels through —
// providers/index.js `performAction` (local channels) and api.js
// `bulkConversations` (MX) — after the action landed.
import { isTauri } from './tauri';

/** Tauri event the notification window (pages/notification) listens for. */
export const ALERT_REMOVE_EVENT = 'notification-card-remove';
const NOTIFICATION_WINDOW = 'notification';

/** The thread a card is about (the in-app store and the panel use both spellings). */
export function alertThreadKeys(notif) {
  const items = notif?._isMerged ? notif.items || [] : [notif];
  return items.flatMap((n) => [n?.conversationId, n?.key, n?.id]).filter(Boolean).map(String);
}

/** Whether a card is about any of `keys`. */
export function alertMatches(notif, keys) {
  const set = keys instanceof Set ? keys : new Set(keys);
  return alertThreadKeys(notif).some((k) => set.has(k));
}

export async function closeAlertsFor(conversationKeys, action) {
  const keys = (conversationKeys || []).filter(Boolean).map(String);
  if (!keys.length) return;
  // Lazy: api.js imports this module, and conversationActions' own imports
  // (shortcuts → tauri) must not join api.js's graph.
  const { REMOVAL_ACTIONS } = await import('./conversationActions');
  if (!REMOVAL_ACTIONS.includes(action)) return;
  // In-app popup (browser, and the desktop's in-window mode): same window.
  import('../stores/notificationStore')
    .then(({ default: store }) => {
      const { notifications, dismiss } = store.getState();
      for (const n of notifications) if (alertMatches(n, keys)) dismiss(n._alertId);
    })
    .catch(() => {});
  // The desktop's separate notification panel.
  if (isTauri()) {
    import('@tauri-apps/api/event')
      .then(({ emitTo }) => emitTo(NOTIFICATION_WINDOW, ALERT_REMOVE_EVENT, { keys }))
      .catch(() => {});
  }
}
