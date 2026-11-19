// A new event's repeat, as the editor holds it, and the RFC 5545 RRULE body it
// saves as (`FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2`, no `RRULE:` prefix). One rule
// shape for every backend: MX stores it as `recurrence_rule`, Google takes it
// verbatim, and the Rust core translates it into Graph's pattern + range.

export const REPEAT_FREQS = [
  { key: 'none', label: 'Does not repeat', unit: '' },
  { key: 'DAILY', label: 'Daily', unit: 'day' },
  { key: 'WEEKLY', label: 'Weekly', unit: 'week' },
  { key: 'MONTHLY', label: 'Monthly', unit: 'month' },
  { key: 'YEARLY', label: 'Yearly', unit: 'year' },
];

// Monday first, as the week reads in our markets. `js` is Date#getDay().
export const WEEKDAYS = [
  { code: 'MO', short: 'M', name: 'Mon', js: 1 },
  { code: 'TU', short: 'T', name: 'Tue', js: 2 },
  { code: 'WE', short: 'W', name: 'Wed', js: 3 },
  { code: 'TH', short: 'T', name: 'Thu', js: 4 },
  { code: 'FR', short: 'F', name: 'Fri', js: 5 },
  { code: 'SA', short: 'S', name: 'Sat', js: 6 },
  { code: 'SU', short: 'S', name: 'Sun', js: 0 },
];

export const NO_REPEAT = { freq: 'none', interval: 1, days: null, ends: 'never', until: '', count: 2 };

// A series' rule as editor state, for an event starting at `start` (the
// editor's local "yyyy-MM-ddTHH:mm"). A rule the editor can't show (2nd
// Tuesday, BYSETPOS, the 15th of a series starting on the 1st, …) comes back
// as `{ freq: 'custom', rule }` and is saved untouched.
export function parseRRule(rule, start) {
  const body = (rule || '').trim().replace(/^RRULE:/i, '');
  if (!body) return NO_REPEAT;
  const parts = Object.fromEntries(body.split(';').filter(Boolean).map(p => {
    const [k, ...v] = p.split('=');
    return [k.trim().toUpperCase(), v.join('=').trim()];
  }));
  const custom = { ...NO_REPEAT, freq: 'custom', rule: body };
  if (!REPEAT_FREQS.some(f => f.key === parts.FREQ && f.key !== 'none')) return custom;
  // BYMONTHDAY/BYMONTH are what Graph's absolute patterns read back as. The
  // editor repeats on the start's own day and month, so it can only show them
  // when they say exactly that; anything else would be rebuilt into a
  // different schedule.
  const known = ['FREQ', 'INTERVAL', 'BYDAY', 'COUNT', 'UNTIL', 'WKST', 'BYMONTHDAY', 'BYMONTH'];
  if (Object.keys(parts).some(k => !known.includes(k))) return custom;
  // …and only where they mean that: a month day on a monthly or yearly
  // rule, a month on a yearly one. Anywhere else they filter, and a rebuild
  // without them would change the schedule.
  if (parts.BYMONTHDAY && !['MONTHLY', 'YEARLY'].includes(parts.FREQ)) return custom;
  if (parts.BYMONTH && parts.FREQ !== 'YEARLY') return custom;
  const day = start ? new Date(`${start.slice(0, 10)}T00:00`) : null;
  if (parts.BYMONTHDAY && (!day || parts.BYMONTHDAY !== String(day.getDate()))) return custom;
  if (parts.BYMONTH && (!day || parts.BYMONTH !== String(day.getMonth() + 1))) return custom;
  const days = parts.BYDAY ? parts.BYDAY.split(',').map(d => d.trim().toUpperCase()) : null;
  if (days && (parts.FREQ !== 'WEEKLY' || days.some(d => !WEEKDAYS.some(w => w.code === d)))) return custom;
  // WKST (week start) is kept as read: it decides which weeks an every-N-weeks
  // series falls in, and the editor has no control for it.
  const repeat = { ...NO_REPEAT, freq: parts.FREQ, interval: parseInt(parts.INTERVAL, 10) || 1, days, wkst: parts.WKST || null };
  if (parts.COUNT) return { ...repeat, ends: 'after', count: parseInt(parts.COUNT, 10) || 1 };
  if (parts.UNTIL) {
    const u = parts.UNTIL;
    // A timed UNTIL is a UTC instant: its local day is the one the user picked.
    const day = u.length > 8
      ? new Date(`${u.slice(0, 4)}-${u.slice(4, 6)}-${u.slice(6, 8)}T${u.slice(9, 11)}:${u.slice(11, 13)}:${u.slice(13, 15)}Z`)
      : new Date(`${u.slice(0, 4)}-${u.slice(4, 6)}-${u.slice(6, 8)}T00:00`);
    const pad = (n) => String(n).padStart(2, '0');
    return { ...repeat, ends: 'on', until: `${day.getFullYear()}-${pad(day.getMonth() + 1)}-${pad(day.getDate())}` };
  }
  return repeat;
}

// `start` is the editor's local "yyyy-MM-ddTHH:mm". A weekly repeat with no
// days picked repeats on the start's own weekday.
export function weekdayOf(start) {
  const js = new Date(`${start.slice(0, 10)}T00:00`).getDay();
  return WEEKDAYS.find(d => d.js === js).code;
}

export function repeatDays(repeat, start) {
  return repeat.days?.length ? repeat.days : [weekdayOf(start)];
}

// The RRULE body, or null for no repeat. `until` is a local date and means
// "through that day": a DATE for an all-day series, the day's last second in
// UTC for a timed one (RFC 5545 wants UNTIL in UTC when DTSTART has a zone).
export function buildRRule(repeat, start, allDay) {
  if (!repeat || repeat.freq === 'none') return null;
  if (repeat.freq === 'custom') return repeat.rule;
  const parts = [`FREQ=${repeat.freq}`];
  const interval = Math.max(1, parseInt(repeat.interval, 10) || 1);
  if (interval > 1) parts.push(`INTERVAL=${interval}`);
  if (repeat.freq === 'WEEKLY') {
    const picked = repeatDays(repeat, start);
    // Calendar order, whatever order they were ticked in.
    parts.push(`BYDAY=${WEEKDAYS.filter(d => picked.includes(d.code)).map(d => d.code).join(',')}`);
    if (repeat.wkst) parts.push(`WKST=${repeat.wkst}`);
  }
  if (repeat.ends === 'after') {
    parts.push(`COUNT=${Math.max(1, parseInt(repeat.count, 10) || 1)}`);
  } else if (repeat.ends === 'on') {
    // No date yet, or one before the start, would mean "forever" or "never":
    // it ends on the start's own day at the earliest.
    const first = start.slice(0, 10);
    const until = repeat.until && repeat.until >= first ? repeat.until : first;
    parts.push(`UNTIL=${allDay
      ? until.replaceAll('-', '')
      : new Date(`${until}T23:59:59`).toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '')}`);
  }
  return parts.join(';');
}

// "Weekly on Mon, Wed · 2 times", for the invite preview.
export function describeRepeat(repeat, start) {
  if (!repeat || repeat.freq === 'none') return '';
  if (repeat.freq === 'custom') return 'Custom repeat';
  const f = REPEAT_FREQS.find(r => r.key === repeat.freq);
  const n = Math.max(1, parseInt(repeat.interval, 10) || 1);
  let text = n > 1 ? `Every ${n} ${f.unit}s` : f.label;
  if (repeat.freq === 'WEEKLY') {
    const picked = repeatDays(repeat, start);
    text += ` on ${WEEKDAYS.filter(d => picked.includes(d.code)).map(d => d.name).join(', ')}`;
  }
  if (repeat.ends === 'after') {
    const c = Math.max(1, parseInt(repeat.count, 10) || 1);
    text += ` · ${c} ${c === 1 ? 'time' : 'times'}`;
  } else if (repeat.ends === 'on' && repeat.until) {
    text += ` · until ${new Date(`${repeat.until}T00:00`).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })}`;
  }
  return text;
}
