// One colour per calendar, shared by every surface that draws an event: the
// full calendar grid, the sidebar / rail day preview, and the menu bar popover.
// They used to disagree — the grid drew these pastels while the day preview
// tinted the provider's own calendar colour — so the same meeting was blue in
// one place and grey in the other.

import { CALENDAR_PASTELS } from './storageKeys';

export const PASTELS = [
  '#7EB0F7', // cornflower blue
  '#F0A8C5', // rose pink
  '#C5A8F0', // lavender
  '#A8F0C5', // mint
  '#F0D8A8', // peach
  '#A8E0F0', // sky blue
  '#E8A8F0', // orchid
  '#F0C5A8', // salmon
  '#A8F0E0', // aqua
  '#D8F0A8', // lime
];

// Ink that reads on every pastel above, in every theme.
export const EVENT_TEXT = '#1a1a1a';

// Color per calendar: its position in the calendar list sorted by id, so the
// same calendars keep the same colors across restarts. (Handing them out in
// first-rendered order reshuffled them whenever the API's and the local events
// arrived in a different order.)
export function getPastel(calId, sortedCalendarIds) {
  const i = sortedCalendarIds.indexOf(calId);
  return PASTELS[Math.max(i, 0) % PASTELS.length];
}

// The full calendar is the only place that knows the whole list (API + local),
// so it records the assignment; everything else looks it up. localStorage is
// shared with the menu bar popover's webview, which is how it gets there.
export function rememberPastels(calendarIds) {
  const sorted = [...calendarIds].sort();
  const map = Object.fromEntries(sorted.map((id) => [id, getPastel(id, sorted)]));
  try { localStorage.setItem(CALENDAR_PASTELS, JSON.stringify(map)); } catch { /* private mode */ }
}

// ponytail: a calendar the full calendar hasn't recorded yet (added since it was
// last opened) gets a stable hash pick, which can differ from the grid until the
// calendar page is opened once. Load the calendar list here if that ever matters.
export function pastelFor(calId) {
  let map = {};
  try { map = JSON.parse(localStorage.getItem(CALENDAR_PASTELS)) || {}; } catch { /* malformed */ }
  if (map[calId]) return map[calId];
  let h = 0;
  for (const ch of String(calId || '')) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return PASTELS[h % PASTELS.length];
}
