// Calendar reads straight off the local SQLite store (desktop / local channels
// only — MX calendars don't live here). Feeds the NextMeeting sidebar footer and
// the unified inbox's calendar rail.

import { getDb } from './db.js';
import { detectMeeting } from '../components/MeetingProviderIcon/meetingProvider';
import { pastelFor } from './calendarColors.js';
import log from './log.js';

const DAY_MS = 24 * 60 * 60 * 1000;
const SOON_MS = 30 * 60 * 1000;

// Earliest event starting after `now`. start_at is stored in mixed RFC3339 forms
// (`+02:00` and `Z`), so SQL can only bound it coarsely by date prefix — the
// ordering and the future test happen here with Date, which reads both.
export function pickNext(rows, now) {
  return (rows || [])
    .map((r) => ({
      title: r.title || 'Busy',
      start: r.start_at,
      // Which calendar this is on: the channel it belongs to, plus the calendar
      // name when it says something beyond the address itself.
      email: r.email_address,
      providerType: r.provider_type,
      avatarUrl: r.avatar_url,
      calendarName: r.calendar_name !== r.email_address ? r.calendar_name : null,
      meeting: detectMeeting({ ...r, conference: parseMetadata(r.metadata).conference }),
      soon: new Date(r.start_at).getTime() - now <= SOON_MS,
    }))
    .filter((e) => new Date(e.start).getTime() > now)
    .sort((a, b) => new Date(a.start) - new Date(b.start))[0] || null;
}

export async function fetchNextMeeting() {
  try {
    const db = await getDb();
    if (!db) return null;
    const from = new Date(Date.now() - DAY_MS).toISOString().slice(0, 10);
    const rows = await db.select(
      `SELECT e.title, e.start_at, e.location, e.description, e.metadata, c.name AS calendar_name,
              a.email_address, a.provider_type, a.avatar_url
       FROM calendar_events e
       JOIN calendars c ON c.key = e.calendar_key
       LEFT JOIN external_accounts a ON a.key = e.account_key
       WHERE e.all_day = 0 AND e.status != 'cancelled' AND c.is_visible = 1
         AND substr(e.start_at, 1, 10) >= ?1
       ORDER BY e.start_at ASC LIMIT 60`,
      [from]
    );
    return pickNext(rows, Date.now());
  } catch (e) {
    log.warn('[NextMeeting] fetch failed', e);
    return null;
  }
}

// Side-by-side columns for overlapping events, the way every calendar does it:
// walk the spans in start order, put each in the first column that's free by the
// time it starts, and once nothing is still open, close the cluster and stamp
// everyone in it with the column count. Mutates + returns `spans`.
function assignColumns(spans) {
  spans.sort((a, b) => a.from - b.from || a.to - b.to);
  let cluster = [];
  let colEnds = []; // end minute of the last event in each column of this cluster

  const close = () => {
    for (const s of cluster) s.cols = colEnds.length;
    cluster = [];
    colEnds = [];
  };

  for (const s of spans) {
    if (colEnds.length && s.from >= Math.max(...colEnds)) close();
    let col = colEnds.findIndex((end) => end <= s.from);
    if (col === -1) {
      col = colEnds.length;
      colEnds.push(s.to);
    } else {
      colEnds[col] = s.to;
    }
    s.col = col;
    cluster.push(s);
  }
  close();
  return spans;
}

// Lay one day out the way FullCalendar's timeGrid does: minutes-from-midnight
// spans clamped into the day (so a multi-day event still draws), the hour
// window they need — at least MIN_HOUR..MAX_HOUR, widened to fit outliers — and
// a {col, cols} pair per span so concurrent events sit side by side.
export function layoutDay(events, day, { minHour = 7, maxHour = 20 } = {}) {
  const sameDay = (a, b) => a.toDateString() === b.toDateString();
  const clamp = (when, fallback) =>
    (sameDay(when, day) ? when.getHours() * 60 + when.getMinutes() : fallback);

  const spans = assignColumns(events
    .filter((e) => !e.allDay)
    .map((e) => {
      const from = clamp(e.start, 0);
      return { ...e, from, to: Math.max(from + 15, clamp(e.end, 24 * 60)) };
    }));

  const firstHour = Math.min(minHour, ...spans.map((s) => Math.floor(s.from / 60)));
  const lastHour = Math.max(maxHour, ...spans.map((s) => Math.ceil(s.to / 60)));
  return {
    spans,
    originMin: firstHour * 60,
    hours: Array.from({ length: lastHour - firstHour + 1 }, (_, i) => firstHour + i),
  };
}

function parseMetadata(metadata) {
  try {
    return JSON.parse(metadata || '{}');
  } catch {
    return {};
  }
}

// Every visible event overlapping [from, to] — the calendar rail's one read
// (mini-calendar dots, the day hover peek and "Coming up" all come off it).
// Same mixed-RFC3339 caveat: bound coarsely in SQL, compare precisely in JS.
export async function fetchEventsInRange(from, to) {
  try {
    const db = await getDb();
    if (!db) return [];
    const lo = new Date(from.getTime() - DAY_MS).toISOString().slice(0, 10);
    const hi = new Date(to.getTime() + DAY_MS).toISOString().slice(0, 10);
    const rows = await db.select(
      `SELECT e.key, e.title, e.start_at, e.end_at, e.all_day, e.location, e.description,
              e.organizer_email, e.organizer_name, e.metadata, e.calendar_key,
              a.email_address, a.provider_type, a.avatar_url
       FROM calendar_events e
       JOIN calendars c ON c.key = e.calendar_key
       LEFT JOIN external_accounts a ON a.key = e.account_key
       WHERE e.status != 'cancelled' AND c.is_visible = 1
         AND substr(e.start_at, 1, 10) BETWEEN ?1 AND ?2
       ORDER BY e.start_at ASC LIMIT 500`,
      [lo, hi]
    );
    return (rows || []).map((r) => {
      // The synced metadata blob holds the attendees AND the provider's own join
      // link (Google conferenceData / Microsoft onlineMeeting) — one parse feeds
      // the rail's brand glyph and the detail popup's Join button alike.
      const meta = parseMetadata(r.metadata);
      const detail = {
        id: r.key,
        title: r.title || 'Busy',
        start_at: r.start_at,
        end_at: r.end_at || r.start_at,
        all_day: !!r.all_day,
        location: r.location,
        description: r.description,
        organizer_email: r.organizer_email,
        organizer_name: r.organizer_name,
        attendees: meta.attendees || [],
        conference: meta.conference || null,
      };
      const meeting = detectMeeting(detail);
      return {
        key: r.key,
        title: detail.title,
        start: new Date(r.start_at),
        end: new Date(r.end_at || r.start_at),
        allDay: detail.all_day,
        // The full calendar's pastel for this calendar, not the provider's colour.
        color: pastelFor(r.calendar_key),
        provider: meeting?.provider || null,
        // { url, provider, label } when the event has a join link — the menu bar
        // popover's Join button.
        meeting,
        // Which channel the event lives on — the rail rows show its icon.
        account: r.provider_type
          ? { providerType: r.provider_type, avatarUrl: r.avatar_url, email: r.email_address }
          : null,
        // The raw row in EventDetailPopup's shape.
        detail,
      };
    }).filter((e) => e.start <= to && e.end >= from);
  } catch (e) {
    log.warn('[localCalendar] range fetch failed', e);
    return [];
  }
}
