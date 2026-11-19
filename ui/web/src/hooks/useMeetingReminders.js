import { useEffect } from 'react';
import api from '../lib/api';
import log from '../lib/log';
import useAuth from './useAuth';
import { isTauri } from '../lib/tauri';
import { isRealOrgId } from '../lib/org';
import { fetchEventsInRange } from '../lib/localCalendar';
import { detectMeeting } from '../components/MeetingProviderIcon/meetingProvider';
import useNotificationStore, { isZoneAlert } from '../stores/notificationStore';
import { getNotificationPref, NOTIFICATION_MODES } from '../lib/notificationPref';
import { showSystemNotification } from '../lib/systemNotification';
import { showTauriNotification } from './useNewMessageNotifications';
import { playPing, playZoneChime } from '../lib/notificationSound';
import {
  DEFAULT_LEADS, START_GRACE_MS, dueAlert, ignoreMeeting, leadsFor, loadFired,
  minutesLabel, rsvpSummary, saveFired, snoozeMeeting, sweep,
} from '../lib/meetingAlerts';

/**
 * useMeetingReminders — fires an alert before a meeting starts, on the same
 * surface new mail uses (glass card window on desktop, in-app popup in the
 * browser, native OS banner under "system" mode).
 *
 * Client-side by design. The two sync modes never merge: MX events come from
 * Rails, Gmail/Office365 events live only in local SQLite and never touch the
 * API — so a server-side scheduler could only ever cover half the calendar.
 * One tick reading both sources covers all of it.
 *
 * Mount once at the app root, alongside useNewMessageNotifications.
 */

const TICK_MS = 30 * 1000;
// How far ahead we read. Comfortably past the longest lead time we honour, so a
// 60-minute reminder on a provider event still lands.
const HORIZON_MS = 2 * 60 * 60 * 1000;

// ── Reading the calendar ────────────────────────────

/** Local SQLite (Gmail / Office365 / IMAP channels) — desktop only. */
async function localUpcoming(from, to) {
  const rows = await fetchEventsInRange(from, to);
  return rows
    .filter((e) => !e.allDay && e.start >= from && e.start <= to)
    .map((e) => ({
      id: e.key,
      title: e.title,
      startAt: e.start,
      endAt: e.end,
      location: e.detail?.location || null,
      organizerName: e.detail?.organizer_name || null,
      attendeeSummary: rsvpSummary(e.detail?.attendees),
      meeting: detectMeeting(e.detail),
      leads: DEFAULT_LEADS,
    }));
}

/** MX (inbox2-hosted domains) — the Rails calendar. */
async function mxUpcoming(orgSlug, from, to) {
  const data = await api.get(
    `/orgs/${orgSlug}/events?start=${encodeURIComponent(from.toISOString())}&end=${encodeURIComponent(to.toISOString())}&per_page=200`
  );
  return (data?.events || [])
    .filter((e) => !e.all_day && e.status !== 'cancelled')
    .map((e) => ({
      id: e.id,
      title: e.title || '(No title)',
      startAt: new Date(e.start_at),
      endAt: e.end_at ? new Date(e.end_at) : new Date(e.start_at),
      location: e.location || null,
      organizerName: e.organizer_name || null,
      attendeeSummary: rsvpSummary(e.attendees),
      meeting: detectMeeting(e),
      leads: leadsFor(e.reminders),
    }))
    .filter((e) => e.startAt >= from && e.startAt <= to);
}

const clock = (d) => d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

/** The one-line "10:30 – 11:30 · Google Meet" every surface shows. */
function timeLine(evt) {
  const span = `${clock(evt.startAt)} – ${clock(evt.endAt)}`;
  return evt.meeting ? `${span} · ${evt.meeting.label}` : span;
}

export function buildAlert(evt, now) {
  const starting = evt.startAt.getTime() - now <= 0;
  return {
    eventType: 'meeting_reminder',
    eventLabel: minutesLabel(evt.startAt, now),
    // Persists until clicked away, counting down to the start, like a zone card;
    // expiresAt still takes it down 5 minutes into the meeting. The at-start
    // nudge is red, an earlier one amber.
    priority: 'urgent',
    eventColor: starting ? 'urgent' : 'meeting',
    // One identity per meeting: the 10-minute card and the at-start card are the
    // same alert, so the second never stacks a duplicate on top of the first.
    key: `mtg:${evt.id}`,
    eventId: evt.id,
    // The history feed and the OS banner both read `subject`.
    subject: evt.title,
    title: evt.title,
    timeLine: timeLine(evt),
    startAt: evt.startAt.toISOString(),
    endAt: evt.endAt.toISOString(),
    location: evt.location,
    organizerName: evt.organizerName,
    attendeeSummary: evt.attendeeSummary,
    meeting: evt.meeting,
    updated_at: evt.startAt.toISOString(),
  };
}

/**
 * Put an alert on whichever surface the user's notification mode selects. Same
 * routing new mail uses; the dev harness calls it directly to preview the card.
 */
export function deliverMeetingAlert(alert) {
  const { mode } = getNotificationPref();
  // Always recorded to the activity feed, whatever the alert mode is.
  useNotificationStore.getState().record(alert);
  if (mode === NOTIFICATION_MODES.NONE) return mode;

  if (isZoneAlert(alert)) playZoneChime(); else playPing();
  if (mode === NOTIFICATION_MODES.SYSTEM) showSystemNotification(alert);
  else if (isTauri()) showTauriNotification(alert);
  else useNotificationStore.getState().show(alert);
  return mode;
}

// ── The hook ────────────────────────────────────────

export default function useMeetingReminders() {
  const { currentOrgSlug } = useAuth();

  useEffect(() => {
    let alive = true;

    const tick = async () => {
      const now = Date.now();
      const from = new Date(now - START_GRACE_MS);
      const to = new Date(now + HORIZON_MS);

      const events = [];
      if (isTauri()) {
        try { events.push(...await localUpcoming(from, to)); }
        catch (e) { log.warn('MeetingReminders', `local read failed: ${e?.message || e}`); }
      }
      if (isRealOrgId(currentOrgSlug)) {
        try { events.push(...await mxUpcoming(currentOrgSlug, from, to)); }
        catch { /* API may be unavailable — local half still alerts */ }
      }
      if (!alive) return;

      const fired = loadFired();
      let changed = sweep(fired, now);

      for (const evt of events) {
        const due = dueAlert(evt, now, fired);
        if (!due) continue;
        for (const key of due.keys) fired[key] = evt.startAt.getTime();
        changed = true;

        const alert = buildAlert(evt, now);
        const mode = deliverMeetingAlert(alert);
        log.info('MeetingReminders', `fire lead=${due.lead}m mode=${mode} "${evt.title}" join=${alert.meeting?.url || 'none'}`);
      }

      if (changed) saveFired(fired);
    };

    tick();
    const timer = setInterval(tick, TICK_MS);
    return () => { alive = false; clearInterval(timer); };
  }, [currentOrgSlug]);

  // Snooze pressed on a card in the standalone notification window — that webview
  // has its own module instances, so it hands the decision back to this one.
  useEffect(() => {
    if (!isTauri()) return undefined;
    let unlisten;
    import('@tauri-apps/api/event')
      .then(({ listen }) => Promise.all([
        listen('meeting-snooze', (e) => snoozeMeeting(e.payload?.eventId)),
        listen('meeting-ignore', (e) => ignoreMeeting(e.payload?.eventId, e.payload?.startMs)),
      ]))
      .then((fns) => { unlisten = () => fns.forEach((fn) => fn()); })
      .catch((e) => log.warn('MeetingReminders', `listen failed: ${e?.message || e}`));
    return () => { if (unlisten) unlisten(); };
  }, []);
}
