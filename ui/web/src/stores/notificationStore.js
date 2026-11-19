import { create } from 'zustand';
import { START_GRACE_MS } from '../lib/meetingAlerts';
import { markDismissed } from '../lib/zones';

/**
 * NotificationStore — workflow event notification manager.
 *
 * Behavior:
 *   - Vertical queue: max 3 visible, newest on top, no overlap
 *   - Merging: same-thread notifications collapse into a single card
 *   - Priority lifetime: low=auto-dismiss, assigned=longer, urgent=persist until action
 *   - History: all events persist for the notification center feed
 */

const MAX_VISIBLE = 3;
const MAX_HISTORY = 100;

/** Auto-dismiss durations by priority. 0 = persist until manual dismiss. */
const DISMISS_BY_PRIORITY = {
  low:      6000,
  normal:   8000,
  high:     14000,
  urgent:   0,
};

let idCounter = 0;
const dismissTimers = new Map();

/** Derive a workflow event type from message metadata. */
function deriveEventType(notification) {
  if (notification.eventType) return notification.eventType;
  return 'new_message';
}

/** Alert kind for a calendar reminder — the one event type that isn't mail. */
export const MEETING_EVENT = 'meeting_reminder';
export const isMeetingAlert = (notif) => notif?.eventType === MEETING_EVENT;

/** A calendar zone starting (docs/Calendar.md "Zones") — stays until clicked away. */
export const ZONE_EVENT = 'zone_start';
export const isZoneAlert = (notif) => notif?.eventType === ZONE_EVENT;
/** Either calendar alert — both open the calendar rather than a thread. */
export const isCalendarAlert = (notif) => isMeetingAlert(notif) || isZoneAlert(notif);

/** Human-readable label + semantic color key for each event type. */
const EVENT_META = {
  new_message:  { label: 'New message',      color: 'primary',   priority: 'normal', icon: 'envelope.badge' },
  assigned:     { label: 'Assigned to you',   color: 'assigned',  priority: 'high',   icon: 'person' },
  reply:        { label: 'Customer replied',  color: 'waiting',   priority: 'normal', icon: 'arrowshape.turn.up.left' },
  mention:      { label: 'Mentioned',         color: 'mention',   priority: 'normal', icon: 'at' },
  approval:     { label: 'Approval required', color: 'urgent',    priority: 'urgent', icon: 'checkmark.circle' },
  delegated:    { label: 'Delegated',         color: 'assigned',  priority: 'normal', icon: 'person.2' },
  completed:    { label: 'Completed',         color: 'completed', priority: 'low',    icon: 'checkmark.circle.fill' },
  sla_breach:   { label: 'SLA breached',      color: 'urgent',    priority: 'urgent', icon: 'exclamationmark.triangle' },
  // Calendar. The label is written per-alert by useMeetingReminders ("Meeting in
  // 10 minutes" / "Starting now"), so the one here is only the fallback. Urgent:
  // the card stays until clicked away; expiresAt ends it 5 minutes in.
  [MEETING_EVENT]: { label: 'Upcoming meeting', color: 'meeting', priority: 'urgent', icon: 'calendar.badge.clock' },
  // Urgent = no auto-dismiss: the card is the reminder, so it waits for you.
  [ZONE_EVENT]: { label: "You're in the zone", color: 'zone_blue', priority: 'urgent', icon: 'scope' },
};

function getEventMeta(type) {
  return EVENT_META[type] || EVENT_META.new_message;
}

/**
 * Rail gradient colors per event-type color key — drives the animated bottom
 * time-bar on notification cards. Shared by the in-app toast (NewMessagePopup)
 * and the standalone Tauri window (NotificationPage). primary/assigned follow
 * the theme via --accent-warning (defaults to #1B69D4 under :root); the rest are
 * bespoke saturated rails, deliberately theme-independent.
 */
const RAIL_COLORS = {
  primary:   { base: 'var(--accent-warning)', highlight: '#7EB0F7' },
  assigned:  { base: 'var(--accent-warning)', highlight: '#7EB0F7' },
  waiting:   { base: '#C8A040', highlight: '#E0C878' },
  completed: { base: '#5A9A6C', highlight: '#8ABFA0' },
  urgent:    { base: '#C45858', highlight: '#E08888' },
  mention:   { base: '#8868B0', highlight: '#B8A0D0' },
  // Amber, so a meeting reads apart from mail at a glance in a mixed stack.
  meeting:   { base: '#C8A040', highlight: '#E0C878' },
  // Zones carry their category's colour. The cards are a fixed light-glass
  // surface, so these are the light-theme zone shades (tokens.css --zone-*).
  zone_blue:   { base: '#2f64d0', highlight: '#7EB0F7' },
  zone_amber:  { base: '#a8701a', highlight: '#E0C878' },
  zone_violet: { base: '#6d5aa8', highlight: '#B8A0D0' },
  zone_green:  { base: '#3d8a5f', highlight: '#8ABFA0' },
  zone_rose:   { base: '#b8506a', highlight: '#E4A0B0' },
  zone_teal:   { base: '#2a8585', highlight: '#88C8C8' },
};

/** Set the per-card rail/color custom properties on a card element. */
function applyRailColors(el, colorKey, dismissMs) {
  if (!el) return;
  const colors = RAIL_COLORS[colorKey] || RAIL_COLORS.primary;
  el.style.setProperty('--event-color', colors.base);
  el.style.setProperty('--rail-base', colors.base);
  el.style.setProperty('--rail-highlight', colors.highlight);
  if (dismissMs > 0) el.style.setProperty('--dismiss-ms', `${dismissMs}ms`);
}

function enrichEntry(notification) {
  const id = ++idCounter;
  const eventType = deriveEventType(notification);
  const meta = getEventMeta(eventType);
  return {
    ...notification,
    _alertId: id,
    eventType,
    eventLabel: notification.eventLabel || meta.label,
    eventColor: notification.eventColor || meta.color,
    priority: notification.priority || meta.priority,
    arrivedAt: Date.now(),
  };
}

/**
 * When a card should disappear, as a wall-clock timestamp — null = persist until
 * it's touched. A meeting card also expires shortly after the meeting starts —
 * the same grace the reminder tick stops firing after — so one that fired at
 * 10:30 while the lid was shut is gone by the time the machine wakes at 14:00
 * instead of still sitting there saying "Starting now".
 */
export function expiresAt(notif, now = Date.now()) {
  const ms = DISMISS_BY_PRIORITY[notif?.priority] ?? DISMISS_BY_PRIORITY.normal;
  const dwell = ms > 0 ? now + ms : null;
  if (!isMeetingAlert(notif)) return dwell;
  const over = Date.parse(notif.startAt) + START_GRACE_MS;
  if (!Number.isFinite(over)) return dwell;
  return dwell ? Math.min(dwell, over) : over;
}

function scheduleDismiss(entry, set) {
  const until = expiresAt(entry);
  if (!until) return; // urgent — persist until manual dismiss
  // Ticks against the wall clock rather than sleeping on one long delay: JS
  // timers stall while the machine is asleep, so an expiry that passed with the
  // lid shut is only caught by re-comparing clocks after the wake.
  const timer = setInterval(() => {
    if (Date.now() < until) return;
    cancelDismiss(entry._alertId);
    set((s) => ({
      notifications: s.notifications.filter(n => n._alertId !== entry._alertId),
    }));
  }, 1000);
  dismissTimers.set(entry._alertId, timer);
}

function cancelDismiss(alertId) {
  const timer = dismissTimers.get(alertId);
  if (timer) {
    clearInterval(timer);
    dismissTimers.delete(alertId);
  }
}

/**
 * Trim a newest-first card list to MAX_VISIBLE without ever dropping a zone or
 * meeting card — both wait to be clicked away. Shared with the desktop
 * notification window.
 */
export function keepVisible(list, max = MAX_VISIBLE) {
  const pinned = list.filter(isCalendarAlert);
  const room = Math.max(0, max - pinned.length);
  const others = list.filter(n => !isCalendarAlert(n)).slice(0, room);
  return list.filter(n => isCalendarAlert(n) || others.includes(n));
}

/** Thread key for merging: use conversationId or key as grouping identity. */
function threadKey(notification) {
  return notification.conversationId || notification.key || null;
}

const useNotificationStore = create((set) => ({
  notifications: [],
  history: [],

  show(notification) {
    const entry = enrichEntry(notification);

    // Add to history (dedup)
    set((state) => {
      const dk = entry.key || entry.id;
      if (dk && state.history.some(h => (h.key || h.id) === dk)) return state;
      return { history: [entry, ...state.history].slice(0, MAX_HISTORY) };
    });

    set((state) => {
      const tKey = threadKey(entry);
      let list = [...state.notifications];

      // Dedup by key — must check before merge
      const dedupKey = entry.key || entry.id;
      if (dedupKey && list.some(n => {
        if (n._isMerged) return n.items.some(i => (i.key || i.id) === dedupKey);
        return (n.key || n.id) === dedupKey;
      })) {
        return state;
      }

      // Merge: if same thread already visible, collapse into it
      if (tKey) {
        const existingIdx = list.findIndex(n => {
          if (n._isMerged) return n.items.some(i => threadKey(i) === tKey);
          return threadKey(n) === tKey;
        });
        if (existingIdx !== -1) {
          const existing = list[existingIdx];
          cancelDismiss(existing._alertId);

          const mergedId = ++idCounter;
          const items = existing._isMerged
            ? [...existing.items, entry]
            : [existing, entry];
          const merged = {
            _alertId: mergedId,
            _isMerged: true,
            items,
            count: items.length,
            eventType: entry.eventType,
            eventLabel: `${items.length} new replies`,
            eventColor: entry.eventColor,
            priority: entry.priority,
            subject: existing.subject,
            from_address: entry.from_address,
            arrivedAt: Date.now(),
          };
          list[existingIdx] = merged;
          scheduleDismiss(merged, set);
          return { notifications: list };
        }
      }

      // Add to front (newest on top) — enforce max visible
      list = [entry, ...list];
      if (list.length > MAX_VISIBLE) {
        // A zone or meeting card only leaves when it's clicked away (or the
        // meeting is 5 minutes in), so the overflow comes out of the other cards.
        const keep = keepVisible(list);
        list.filter(n => !keep.includes(n)).forEach(n => cancelDismiss(n._alertId));
        list = keep;
      }

      scheduleDismiss(entry, set);
      return { notifications: list };
    });

    return entry._alertId;
  },

  /** Add to history only — no in-app popup. Used by Tauri path where the external window handles display. */
  record(notification) {
    const entry = enrichEntry(notification);
    set((state) => {
      const dk = entry.key || entry.id;
      if (dk && state.history.some(h => (h.key || h.id) === dk)) return state;
      return { history: [entry, ...state.history].slice(0, MAX_HISTORY) };
    });
  },

  dismiss(id, { remote = false } = {}) {
    cancelDismiss(id);
    // Clicking a zone card away is the answer it was waiting for — remember it,
    // or the next tick would raise the card again. `remote`: it was clicked
    // away on another device, so there's nothing to tell the server.
    const gone = useNotificationStore.getState().notifications.find(n => n._alertId === id);
    if (isZoneAlert(gone)) markDismissed({ id: gone.zoneId, end_at: gone.endAt }, { remote });
    set((state) => ({
      notifications: state.notifications.filter(n => n._alertId !== id),
    }));
  },

  dismissAll() {
    for (const n of useNotificationStore.getState().notifications) {
      if (isZoneAlert(n)) markDismissed({ id: n.zoneId, end_at: n.endAt });
    }
    for (const timer of dismissTimers.values()) clearInterval(timer);
    dismissTimers.clear();
    set({ notifications: [] });
  },

  clearHistory() {
    set({ history: [] });
  },

  /** How many notifications exist beyond MAX_VISIBLE. */
  get overflowCount() {
    // Zustand doesn't support getters on the store object, use a selector instead
    return 0;
  },
}));

export { DISMISS_BY_PRIORITY, MAX_VISIBLE, EVENT_META, getEventMeta, RAIL_COLORS, applyRailColors };
export default useNotificationStore;
