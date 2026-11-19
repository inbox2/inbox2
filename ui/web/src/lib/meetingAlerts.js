// When a meeting alert fires, and when it fires again.
//
// Pure bookkeeping, deliberately free of React and of the app's import graph:
// this is the part with the actual rules in it, so it's the part that gets a
// test. useMeetingReminders is the wiring around it.

// No reminders on the event (every local-channel event — the providers don't
// sync their reminder rows) falls back to these, in minutes before the start.
export const DEFAULT_LEADS = [10, 0];
// Past this much after the start we stop alerting entirely, so launching the app
// at lunchtime doesn't replay the morning. Exported because the calendar reads
// have to reach back this far too — a tick at 10:30:30 must still see the
// meeting that started at 10:30:15.
export const START_GRACE_MS = 5 * 60 * 1000;
const SNOOZE_MS = 5 * 60 * 1000;
// Keys for meetings older than this are swept on each tick.
const KEEP_MS = 6 * 60 * 60 * 1000;

const FIRED_KEY = 'inbox2_meeting_alerts_fired';

// `fired` is { "<eventId>:<lead>": <event start ms> }, persisted so relaunching
// the app at 10:29 doesn't replay the 10:20 alert. The start time is kept purely
// so old keys can be swept.

export function loadFired() {
  try {
    return JSON.parse(localStorage.getItem(FIRED_KEY)) || {};
  } catch {
    return {};
  }
}

export function saveFired(map) {
  try {
    localStorage.setItem(FIRED_KEY, JSON.stringify(map));
  } catch { /* quota / private mode / no DOM — worst case an alert repeats */ }
}

/** Drop keys for meetings that are well over. Returns whether anything changed. */
export function sweep(fired, now) {
  let changed = false;
  for (const [key, startMs] of Object.entries(fired)) {
    if (now - startMs > KEEP_MS) { delete fired[key]; changed = true; }
  }
  return changed;
}

const snoozedUntil = new Map();

/**
 * "Remind me again in 5 minutes." Un-fires the event's alerts and holds them
 * back until the snooze expires — the next tick then re-fires naturally, so
 * there is still exactly one place that decides when an alert appears.
 */
export function snoozeMeeting(eventId) {
  if (!eventId) return;
  snoozedUntil.set(eventId, Date.now() + SNOOZE_MS);
  const fired = loadFired();
  for (const key of Object.keys(fired)) {
    if (key.startsWith(`${eventId}:`)) delete fired[key];
  }
  saveFired(fired);
}

// The tick only reads two hours ahead, so a longer lead than this can't be
// honoured at its real moment — firing it late, mislabelled, is worse than
// falling back to the usual nudge.
export const MAX_LEAD_MIN = 120;

/**
 * Who's actually coming — "5 accepted · 1 tentative". At T-10 that's what decides
 * whether the meeting is happening, so it beats a raw head count. Counted over
 * the whole list; the alert carries this string rather than the attendees.
 */
export function rsvpSummary(attendees) {
  if (!attendees?.length) return null;
  const counts = { accepted: 0, tentative: 0, declined: 0 };
  for (const a of attendees) {
    // The API serializes snake_case, the offline sync keeps the provider's camelCase.
    const status = (a.response_status || a.responseStatus || '').replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase();
    if (status in counts) counts[status] += 1;
  }
  const parts = Object.entries(counts).filter(([, n]) => n > 0).map(([k, n]) => `${n} ${k}`);
  return parts.length ? parts.join(' · ') : `${attendees.length} attendee${attendees.length === 1 ? '' : 's'}`;
}

/** Lead times in minutes, from the event's own reminders when it has any. */
export function leadsFor(reminders) {
  const mins = (reminders || [])
    .filter((r) => (r.method || 'popup') === 'popup')
    .map((r) => Number(r.minutes_before))
    .filter((m) => Number.isFinite(m) && m >= 0 && m <= MAX_LEAD_MIN);
  return mins.length ? [...new Set(mins)] : DEFAULT_LEADS;
}

/**
 * "Stop reminding me about this meeting." Marks the occurrence itself as spent —
 * the at-start nudge included — so no further card fires for it, relaunches
 * included. Same persisted map as fired leads, so the sweep cleans it up too.
 */
export function ignoreMeeting(eventId, startMs) {
  if (!eventId) return;
  const fired = loadFired();
  fired[`${eventId}:ignored`] = startMs || Date.now();
  saveFired(fired);
}

/**
 * Which lead time is due for this event, if any. Every lead whose moment has
 * passed counts as spent — the smallest one is the honest thing to show (it's
 * closest to the real start), and the longer ones are marked fired rather than
 * replayed behind it.
 */
export function dueAlert(evt, now, fired) {
  const start = evt.startAt.getTime();
  if (now >= start + START_GRACE_MS) return null;
  if (fired[`${evt.id}:ignored`]) return null;
  const until = snoozedUntil.get(evt.id);
  if (until && now < until) return null;

  const passed = evt.leads.filter((L) => now >= start - L * 60000 && !fired[`${evt.id}:${L}`]);
  if (!passed.length) return null;
  return { lead: Math.min(...passed), keys: passed.map((L) => `${evt.id}:${L}`) };
}

export function minutesLabel(startAt, now) {
  const mins = Math.round((startAt.getTime() - now) / 60000);
  if (mins <= 0) return 'Starting now';
  if (mins === 1) return 'Meeting in 1 minute';
  if (mins < 60) return `Meeting in ${mins} minutes`;
  const hours = Math.round(mins / 60);
  return `Meeting in ${hours} hour${hours === 1 ? '' : 's'}`;
}
