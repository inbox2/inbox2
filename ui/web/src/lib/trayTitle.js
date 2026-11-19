// The text beside the menu bar icon: the unread count, and — once a meeting is
// close — what's next, the way Outlook's menu bar item does it.
// e.g. "12", "Standup · in 10m", "12 · Standup · in 10m", "" (nothing to say).
// A running zone (docs/Calendar.md "Zones") counts down in its place:
// "12 · Project Atlas · 1:41 left" — a meeting about to start still wins.

const LEAD_MS = 60 * 60 * 1000;
const MAX_TITLE = 22;

import { remaining } from './zones';

export function trayTitle(unread, next, now = Date.now(), zone = null) {
  const parts = [];
  if (unread > 0) parts.push(unread > 99 ? '99+' : String(unread));
  const startsIn = next ? new Date(next.start).getTime() - now : Infinity;
  if (startsIn <= LEAD_MS && startsIn > -60 * 1000) {
    const mins = Math.max(0, Math.round(startsIn / 60000));
    const title = next.title.length > MAX_TITLE ? `${next.title.slice(0, MAX_TITLE - 1).trimEnd()}…` : next.title;
    parts.push(`${title} · ${mins < 1 ? 'now' : `in ${mins}m`}`);
  } else if (zone) {
    const name = zone.name.length > MAX_TITLE ? `${zone.name.slice(0, MAX_TITLE - 1).trimEnd()}…` : zone.name;
    parts.push(`${name} · ${remaining(zone, now)} left`);
  }
  return parts.join(' · ');
}
