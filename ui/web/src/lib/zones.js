// Calendar zones (docs/Calendar.md "Zones"): soft focus blocks that never count
// as busy. Pure helpers shared by the calendar, the sidebar, the start alert and
// the menu bar title.
import { ZONE_DISMISSED } from './storageKeys';
import api from './api';
import log from './log';

/** Palette keys the API stores — mirrors ZoneCategory::COLORS. */
export const ZONE_COLORS = ['blue', 'amber', 'violet', 'green', 'rose', 'teal'];

/** Lead times offered for a meeting's prep zone, in minutes. */
export const PREP_LEADS = [30, 60, 120];

/** Repeat rules — mirrors Zone::REPEATS. */
export const ZONE_REPEATS = [
  { key: 'none', label: 'Doesn’t repeat' },
  { key: 'daily', label: 'Every day' },
  { key: 'weekdays', label: 'Every weekday' },
  { key: 'weekly', label: 'Every week' },
];

/** Whether a zone is one of a series (anything but the 'none' rule). */
export const isRepeating = (zone) => !!zone?.repeat && zone.repeat !== ZONE_REPEATS[0].key;

/** Longest zone the API accepts (Zone::MAX_LENGTH). */
export const MAX_ZONE_MS = 24 * 3600 * 1000;

/** The theme token for a palette key (tokens.css defines one per theme). */
export function zoneColorVar(color) {
  return `var(--zone-${ZONE_COLORS.includes(color) ? color : 'blue'})`;
}

export function categoryFor(zone, categories) {
  return (categories || []).find(c => c.id === zone?.category_id) || null;
}

export function isActive(zone, now = Date.now()) {
  return Date.parse(zone.start_at) <= now && now < Date.parse(zone.end_at);
}

/** Share of the zone already behind you, 0–1. */
export function progress(zone, now = Date.now()) {
  const start = Date.parse(zone.start_at);
  const span = Date.parse(zone.end_at) - start;
  return span > 0 ? Math.min(1, Math.max(0, (now - start) / span)) : 1;
}

/** Time left as "1:41:52" (withSeconds) or "1:41" / "41m". */
export function remaining(zone, now = Date.now(), { withSeconds = false } = {}) {
  const left = Math.max(0, Math.floor((Date.parse(zone.end_at) - now) / 1000));
  const h = Math.floor(left / 3600);
  const m = Math.floor((left % 3600) / 60);
  const s = left % 60;
  const pad = (n) => String(n).padStart(2, '0');
  if (withSeconds) return `${h}:${pad(m)}:${pad(s)}`;
  return h > 0 ? `${h}:${pad(m)}` : `${m}m`;
}

/**
 * A prep zone for a meeting: `minutes` long, ending when the meeting starts,
 * filed under the category called "Prep" when the user still has one. The
 * anchor lets `anchorFix` pull it along when the meeting moves.
 */
export function prepZoneParams(event, minutes, categories) {
  const start = Date.parse(event.start_at);
  const prep = (categories || []).find(c => c.name.toLowerCase() === 'prep');
  return {
    name: `Prep: ${event.title || 'meeting'}`,
    category_id: prep?.id ?? null,
    start_at: new Date(start - minutes * 60000).toISOString(),
    end_at: new Date(start).toISOString(),
    notify: true,
    anchor_event_id: event.id ?? null,
    anchor_minutes: minutes,
    time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  };
}

/**
 * The retime an anchored prep zone needs, or null. Only when its meeting is in
 * view, still on, and has moved away from the zone's end.
 */
export function anchorFix(zone, events) {
  if (!zone.anchor_event_id || !zone.anchor_minutes) return null;
  const evt = (events || []).find(e => e.id === zone.anchor_event_id);
  if (!evt?.start_at || evt.status === 'cancelled') return null;
  const start = Date.parse(evt.start_at);
  if (!Number.isFinite(start) || start === Date.parse(zone.end_at)) return null;
  return {
    start_at: new Date(start - zone.anchor_minutes * 60000).toISOString(),
    end_at: new Date(start).toISOString(),
  };
}

// ── Dismissed start cards ───────────────────────────
// A zone's card stays until it's clicked away; that choice outlives a reload
// (and the app), so it's persisted. Entries drop out once the zone has ended.

export function loadDismissed() {
  try { return JSON.parse(localStorage.getItem(ZONE_DISMISSED) || '{}') || {}; }
  catch { return {}; }
}

/**
 * Forget a series' dismissals — it was edited, so it should alert again (the
 * server drops its rows on the same edit).
 */
export function clearDismissed(seriesId) {
  const map = loadDismissed();
  let changed = false;
  for (const id of Object.keys(map)) {
    if (id === seriesId || id.startsWith(`${seriesId}@`)) { delete map[id]; changed = true; }
  }
  if (changed) {
    try { localStorage.setItem(ZONE_DISMISSED, JSON.stringify(map)); } catch { /* private mode */ }
  }
}

/**
 * Record a card clicked away. Also tells the server (so the user's other
 * devices drop their card) unless `remote` — the dismissal came from there.
 */
export function markDismissed(zone, { remote = false } = {}) {
  if (!zone?.id) return;
  if (!remote) {
    api.dismissZone(zone.id, zone.end_at)
      .catch((e) => log.warn('Zones', `dismissal sync failed: ${e?.message || e}`));
  }
  const map = loadDismissed();
  map[zone.id] = Date.parse(zone.end_at) || Date.now();
  const now = Date.now();
  for (const [id, end] of Object.entries(map)) if (end < now) delete map[id];
  try { localStorage.setItem(ZONE_DISMISSED, JSON.stringify(map)); } catch { /* private mode */ }
}
