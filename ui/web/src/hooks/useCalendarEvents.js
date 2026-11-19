import { getDb } from '../lib/db.js';
import { useState, useEffect, useCallback, useRef } from 'react';
import { isTauri } from '../lib/tauri';
import api from '../lib/api';
import { isRealOrgId } from '../lib/org';
import log from '../lib/log';
import syncManager from '../lib/sync-manager';
import useCalendarStore from '../stores/calendarStore';
import { startOfMonth, endOfMonth, startOfWeek, endOfWeek, subWeeks, addWeeks, format } from 'date-fns';

// RFC3339 in the device's own offset ("2026-10-26T14:00:00+01:00").
const localIso = (at) => format(new Date(at), "yyyy-MM-dd'T'HH:mm:ssxxx");

/**
 * Fetches calendar events from both sources:
 *   - MX mode (web): Rails API
 *   - Offline channels (desktop): local SQLite (populated by GoogleCalendarSync / MicrosoftCalendarSync)
 *
 * Merges both into the calendarStore.
 *
 * Fetch triggers:
 *   1. Mount (initial load)
 *   2. orgSlug or date-range change (navigation)
 *   3. syncManager 'calendar-changed' event (debounced 500ms)
 *   4. Tab regains visibility (visibilitychange)
 */
// The provider id of the series a synced instance belongs to, or null. Rows
// synced before `seriesId` was recorded fall back to Google's instance-id form,
// `<series id>_<start>` (20261020T090000Z, or 20261020 all-day).
function localSeriesId(row, metadata) {
  if (metadata.seriesId) return metadata.seriesId;
  if (row.cal_source !== 'google') return null;
  return /^(.+)_\d{8}(T\d{6}Z)?$/.exec(row.provider_id || '')?.[1] || null;
}

export default function useCalendarEvents(orgSlug) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  const currentDate = useCalendarStore(s => s.currentDate);
  const events = useCalendarStore(s => s.events);
  const setEvents = useCalendarStore(s => s.setEvents);
  const setCalendars = useCalendarStore(s => s.setCalendars);
  const addEvent = useCalendarStore(s => s.addEvent);
  const updateEventInStore = useCalendarStore(s => s.updateEvent);
  const removeEvent = useCalendarStore(s => s.removeEvent);

  // Compute visible date range with buffer — stable strings for the same month,
  // so intra-month date changes (e.g. FullCalendar datesSet on mount) won't
  // trigger a redundant refetch.
  const rangeStart = startOfWeek(subWeeks(startOfMonth(currentDate), 1)).toISOString();
  const rangeEnd = endOfWeek(addWeeks(endOfMonth(currentDate), 1)).toISOString();

  // ── Fetch calendars (MX API + local SQLite) ───────

  useEffect(() => {
    let cancelled = false;

    async function loadCalendars() {
      const allCalendars = [];

      if (isRealOrgId(orgSlug)) {
        try {
          const data = await api.get(`/orgs/${orgSlug}/calendars`);
          if (data?.calendars) {
            for (const c of data.calendars) {
              allCalendars.push({ ...c, _source: 'api' });
            }
          }
        } catch { /* API may be unavailable */ }
      }

      if (isTauri()) {
        try {
          const db = await getDb();
          const rows = await db.select('SELECT * FROM calendars WHERE status = ?', ['active']);
          for (const row of rows) {
            allCalendars.push({
              id: row.key, name: row.name, color: row.color, source: row.source,
              is_primary: !!row.is_primary, is_visible: row.is_visible !== 0,
              // is_writable is null on rows written before the column existed;
              // treat unknown as writable and let the provider 403 decide.
              is_writable: row.is_writable !== 0,
              // Owned by this account, rather than someone else's calendar we
              // were given write access to (null on pre-column rows → owned).
              is_owned: row.is_owned !== 0,
              // What the provider says this calendar can mint ('meet'/'teams').
              // null = not synced yet (a row from before the column existed);
              // an empty list is a real "nothing", not a missing answer.
              _conferenceProviders: row.conference_providers == null
                ? null
                : row.conference_providers.split(',').filter(Boolean),
              _source: 'local', _accountKey: row.account_key,
              _providerId: row.provider_id,
            });
          }
        } catch (e) {
          log.debug('CalendarEvents', `No local calendars: ${e?.message}`);
        }
      }

      if (!cancelled) {
        setCalendars(allCalendars);
        log.info('CalendarEvents', `Loaded ${allCalendars.length} calendar(s)`);
      }
    }

    loadCalendars();
    return () => { cancelled = true; };
  }, [orgSlug, setCalendars]);

  // ── Core fetch — kept in a ref so sync/visibility handlers always ─────
  // call the latest version without causing effect re-runs.
  const fetchRef = useRef(null);

  const fetchAllEvents = useCallback(async () => {
    const start = rangeStart;
    const end = rangeEnd;
    const allEvents = [];

    if (isRealOrgId(orgSlug)) {
      try {
        const data = await api.get(`/orgs/${orgSlug}/events?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}&per_page=500`);
        if (data?.events) {
          const calMap = new Map();
          useCalendarStore.getState().calendars.forEach(c => calMap.set(c.id, c));
          for (const evt of data.events) {
            allEvents.push({
              ...evt,
              _calendarColor: calMap.get(evt.calendar_id)?.color || '#3B82F6',
              _source: 'api',
            });
          }
        }
      } catch { /* API may be unavailable */ }
    }

    if (isTauri()) {
      try {
        const db = await getDb();
        const rows = await db.select(
          `SELECT ce.*, c.color as cal_color, c.name as cal_name, c.source as cal_source
           FROM calendar_events ce
           JOIN calendars c ON c.key = ce.calendar_key
           WHERE ce.start_at < ? AND ce.end_at > ?
           AND ce.status != 'cancelled'
           ORDER BY ce.start_at`,
          [end, start]
        );
        for (const row of rows) {
          let metadata = {};
          try { metadata = row.metadata ? JSON.parse(row.metadata) : {}; } catch { /* */ }

          allEvents.push({
            id: row.key, title: row.title, description: row.description,
            location: row.location, start_at: row.start_at, end_at: row.end_at,
            all_day: !!row.all_day, timezone: row.timezone, status: row.status,
            calendar_id: row.calendar_key, organizer_email: row.organizer_email,
            organizer_name: row.organizer_name, ical_uid: row.ical_uid,
            attendees: metadata.attendees || [],
            conference: metadata.conference || null,
            _seriesId: localSeriesId(row, metadata),
            _calendarColor: row.cal_color || '#3B82F6',
            _calendarName: row.cal_name, _calendarSource: row.cal_source,
            _source: 'local', _accountKey: row.account_key,
          });
        }
      } catch (e) {
        log.debug('CalendarEvents', `No local events: ${e?.message}`);
      }
    }

    return allEvents;
  }, [orgSlug, rangeStart, rangeEnd]);

  useEffect(() => { fetchRef.current = fetchAllEvents; });

  // ── Load events when range or org changes ──────────

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      try {
        const allEvents = await fetchRef.current();
        if (!cancelled) { setEvents(allEvents); setError(null); }
      } catch (e) {
        if (!cancelled) setError(e.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, [orgSlug, rangeStart, rangeEnd, setEvents]);

  // ── Sync subscription + visibility (runs once, uses ref) ──────────

  useEffect(() => {
    let cancelled = false;
    let debounceTimer = null;

    const refresh = () => {
      fetchRef.current().then(allEvents => {
        if (!cancelled) { setEvents(allEvents); setError(null); }
      }).catch(e => {
        if (!cancelled) setError(e.message);
      });
    };

    const unsub = syncManager.on('calendar-changed', () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        if (!cancelled && !document.hidden) {
          log.info('CalendarEvents', 'Calendar sync changed, refreshing...');
          refresh();
        }
      }, 500);
    });

    const handleVisibility = () => {
      if (!document.hidden && !cancelled) refresh();
    };
    document.addEventListener('visibilitychange', handleVisibility);

    return () => {
      cancelled = true;
      clearTimeout(debounceTimer);
      unsub?.();
      document.removeEventListener('visibilitychange', handleVisibility);
    };
  }, [setEvents]);

  // ── CRUD helpers (MX API, plus the engine for local-channel creates) ──

  // Create an event on the calendar the editor picked. A local (Google/
  // Microsoft) calendar writes through the Rust engine — the API knows nothing
  // about those events; everything else is an MX event on the Rails API.
  const createEvent = useCallback(async (eventData) => {
    let calendars = useCalendarStore.getState().calendars;
    const picked = eventData.calendar_id && calendars.find(c => c.id === eventData.calendar_id);

    if (picked?._source === 'local') {
      const { createCalendarEvent } = await import('../lib/providers/index.js');
      await createCalendarEvent(picked._accountKey, picked._providerId, {
        title: eventData.title,
        description: eventData.description || null,
        location: eventData.location || null,
        // EventDraft wants a bare date for all-day, RFC3339 otherwise — with
        // the local offset, not Z: Graph reads the wall clock in `timezone`,
        // and a repeat's days are local days.
        start_at: eventData.all_day ? eventData.start_at.slice(0, 10) : localIso(eventData.start_at),
        end_at: eventData.all_day ? eventData.end_at.slice(0, 10) : localIso(eventData.end_at),
        all_day: !!eventData.all_day,
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        attendees: (eventData.attendees || []).map(a => a.email).filter(Boolean),
        conference: !!eventData.conference,
        recurrence: eventData.recurrence_rule || null,
      });
      // The engine resyncs and emits 'calendar-changed'; that refetch is what
      // puts the event (with its generated Meet/Teams link) on screen.
      return undefined;
    }

    // MX only past this point, so the fallbacks stay on API calendars — falling
    // back to `calendars[0]` could hand a local (Google/Microsoft) calendar's id
    // to Rails, which knows nothing about it.
    let cal = picked || calendars.find(c => c._source === 'api' && c.is_primary)
      || calendars.find(c => c._source === 'api');

    if (!cal) {
      if (!orgSlug) throw new Error('No calendar yet');
      const res = await api.post(`/orgs/${orgSlug}/calendars`, { name: 'My Calendar', is_primary: true });
      if (res?.calendar) {
        cal = res.calendar;
        calendars = [...calendars, cal];
        setCalendars(calendars);
      } else {
        throw new Error("Couldn't create your calendar");
      }
    }

    eventData.calendar_id = cal.id;
    const data = await api.post(`/orgs/${orgSlug}/events`, eventData);
    if (data?.event) {
      addEvent({ ...data.event, _calendarColor: cal.color || '#3B82F6' });
    }
    return data;
  }, [orgSlug, addEvent, setCalendars]);

  // `changes.scope` (this | following | all) and `notify` ride along for a
  // repeating event; a series-wide edit can add, move or drop many instances
  // (and split one off under a new id), so the window is re-read after it.
  const updateEvent = useCallback(async (eventId, changes) => {
    const { scope } = changes;
    const fields = { ...changes };
    delete fields.scope;
    delete fields.notify;
    const seriesWide = (scope && scope !== 'this') || 'recurrence_rule' in fields;
    if (!seriesWide) updateEventInStore(eventId, fields);
    try {
      const data = await api.patch(`/orgs/${orgSlug}/events/${eventId}`, changes);
      if (seriesWide) setEvents(await fetchRef.current());
      else if (data?.event) updateEventInStore(eventId, data.event);
      return data;
    } catch (e) {
      const allEvents = await fetchRef.current();
      setEvents(allEvents);
      throw e;
    }
  }, [orgSlug, updateEventInStore, setEvents]);

  // Drag/resize. `move`: {start_at, end_at, all_day, shift_seconds, scope:
  // 'this'|'all', notify}. Synced events go through the engine; MX events PATCH
  // with scope/notify. Shown at the new time right away, re-read on failure.
  const rescheduleEvent = useCallback(async (event, move) => {
    const { scope, notify, shift_seconds: shiftSeconds, ...times } = move;
    updateEventInStore(event.id, { start_at: times.start_at, end_at: times.end_at });
    try {
      if (event._source === 'local') {
        const { rescheduleCalendarEvent } = await import('../lib/providers/index.js');
        await rescheduleCalendarEvent(event._accountKey, event.id, {
          ...times,
          timezone: event.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone,
          series_id: scope === 'all' ? event._seriesId : null,
          shift_seconds: shiftSeconds,
          notify,
        });
        return;
      }
      await api.patch(`/orgs/${orgSlug}/events/${event.id}`, { ...times, scope, notify });
      // Every instance may have moved, and a split instance gets a new id.
      setEvents(await fetchRef.current());
    } catch (e) {
      setEvents(await fetchRef.current());
      throw e;
    }
  }, [orgSlug, updateEventInStore, setEvents]);

  // Delete an event. Offline-synced events (Google/Microsoft) delete through the
  // Rust engine and never touch the Rails API; org/MX events use the API. Removed
  // optimistically in both cases — the engine emits 'calendar-changed' so the
  // list reconciles (and restores it if the provider delete fails).
  const deleteEvent = useCallback(async (event, scope = 'this') => {
    removeEvent(event.id);
    try {
      if (event?._source === 'local') {
        if (!isTauri()) return;
        const { deleteCalendarEvent } = await import('../lib/providers/index.js');
        await deleteCalendarEvent(event._accountKey, event.id);
        return;
      }
      await api.request('DELETE', `/orgs/${orgSlug}/events/${event.id}?scope=${scope}`);
    } catch (e) {
      // Put it back: the optimistic removal would otherwise leave a refused
      // delete looking like it worked.
      setEvents(await fetchRef.current());
      throw e;
    }
  }, [orgSlug, removeEvent, setEvents]);

  // RSVP to an event. `status` is 'accepted' | 'declined' | 'tentative'.
  // Offline-synced events (Google/Microsoft) write back through the Rust engine
  // and never touch the Rails API; org/MX events use the API. `_myRsvp` is set
  // optimistically so the UI reflects the choice before the resync lands.
  const rsvp = useCallback(async (event, status, comment) => {
    if (event?._source === 'local') {
      if (!isTauri()) return;
      const { respondToEvent } = await import('../lib/providers/index.js');
      updateEventInStore(event.id, { _myRsvp: status });
      await respondToEvent(event._accountKey, event.id, status);
      return;
    }
    const data = await api.post(`/orgs/${orgSlug}/events/${event.id}/rsvp`, { status, comment });
    if (data?.event) {
      updateEventInStore(event.id, data.event);
    }
    return data;
  }, [orgSlug, updateEventInStore]);

  // Organizer answering a counter-proposal (docs/Calendar.md). Accepting moves
  // the event onto the proposed time and re-invites everyone; declining leaves
  // it where it is. MX-only — offline channels have no proposal concept.
  const respondToProposal = useCallback(async (event, attendee, action) => {
    if (event?._source === 'local') return undefined;
    const path = action === 'accept' ? 'accept-proposal' : 'decline-proposal';
    const data = await api.post(`/orgs/${orgSlug}/events/${event.id}/${path}`, {
      attendee_email: attendee.email,
    });
    if (data?.event) updateEventInStore(event.id, data.event);
    // Accepting moves the event, so the visible range must be re-read rather
    // than patched in place — it may have moved out of the current window.
    if (action === 'accept') setEvents(await fetchRef.current());
    return data;
  }, [orgSlug, updateEventInStore, setEvents]);

  return {
    events,
    loading,
    error,
    createEvent,
    updateEvent,
    rescheduleEvent,
    deleteEvent,
    rsvp,
    respondToProposal,
  };
}
