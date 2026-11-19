import { useEffect, useMemo, useRef, useState } from 'react';
import {
  addDays, addMonths, addWeeks, eachDayOfInterval, endOfMonth, endOfWeek, format,
  isSameDay, isSameMonth, isToday, startOfDay, startOfMonth, startOfWeek,
} from 'date-fns';
import { useNavigate, useParams } from 'react-router';
import useAuth from '../hooks/useAuth';
import useCalendarEvents from '../hooks/useCalendarEvents';
import useCalendarStore from '../stores/calendarStore';
import useAccountStore from '../stores/accountStore';
import EventEditor from '../components/Calendar/EventEditor';
import ConfirmDialog from '../components/ConfirmDialog/ConfirmDialog';
import Icon from '../components/Icon';
import Linkify from '../components/Linkify';
import MeetingProviderIcon from '../components/MeetingProviderIcon/MeetingProviderIcon';
import { detectMeeting } from '../components/MeetingProviderIcon/meetingProvider';
import { openLink } from '../lib/openLink';
import { getPastel } from '../lib/calendarColors';
import { getLastCalendar, setLastCalendar } from '../lib/lastUsedPref';
import { PROVIDER } from '../lib/providerTypes';
import { isRealOrgId } from '../lib/org';
import api from '../lib/localFirstApi';
import log from '../lib/log';
import MobileShell, { MobileIconButton, MobileTopBar } from './MobileShell';
import { MOBILE_TAB, useMobileOrg, useOpenNotifications } from './mobileContext';
import styles from './MobileCalendar.module.css';

/* The phone calendar, after the iOS CalendarView: Upcoming / Day / Month over
 * the same useCalendarEvents data the desktop grid reads. Tapping an event
 * opens a full-screen detail; create/edit reuse the desktop EventEditor, which
 * goes full-screen below 760px. Zones and blocked time are not shown here. */

const SEG = { UPCOMING: 'upcoming', DAY: 'day', MONTH: 'month' };
const SEGMENTS = [[SEG.UPCOMING, 'Upcoming'], [SEG.DAY, 'Day'], [SEG.MONTH, 'Month']];
const UPCOMING_DAYS = 30;
const WEEK = { weekStartsOn: 1 }; // matches the desktop grid's firstDay={1}

const NO_ACCOUNTS = [];

// Wall clock, ticking each minute (the now-line, what still counts as upcoming).
function useNow() {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 60000);
    return () => clearInterval(t);
  }, []);
  return now;
}

const dayKey = (d) => format(d, 'yyyy-MM-dd');
const timeFmt = (d) => d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

// Sets CSS custom properties from a ref — the no-inline-styles way to position.
const cssVars = (vars) => (el) => {
  if (el) for (const [k, v] of Object.entries(vars)) el.style.setProperty(k, String(v));
};

// Does the event touch this local day? All-day events are calendar dates (end
// exclusive), never instants — read them as written, like EventEditor does.
function onDay(evt, day) {
  if (evt.all_day) {
    const key = dayKey(day);
    const s = String(evt.start_at).slice(0, 10);
    const e = String(evt.end_at || evt.start_at).slice(0, 10);
    return key === s || (key > s && key < e);
  }
  const s = new Date(evt.start_at);
  const e = new Date(evt.end_at || evt.start_at);
  const d0 = startOfDay(day);
  const d1 = addDays(d0, 1);
  return s < d1 && (e > d0 || s >= d0);
}

const byStart = (a, b) => (b.all_day ? 1 : 0) - (a.all_day ? 1 : 0)
  || new Date(a.start_at) - new Date(b.start_at);

function timeRange(evt) {
  if (evt.all_day) return 'All day';
  const s = new Date(evt.start_at);
  const e = new Date(evt.end_at || evt.start_at);
  return `${timeFmt(s)} – ${timeFmt(e)}`;
}

function dayHeading(day) {
  if (isToday(day)) return 'Today';
  if (isSameDay(day, addDays(new Date(), 1))) return 'Tomorrow';
  return format(day, 'EEEE, MMM d');
}

// The month whose fetch window (month ± a week, see useCalendarEvents) best
// covers the next 30 days.
function upcomingAnchor(now) {
  const left = endOfMonth(now).getDate() - now.getDate();
  return left < 7 ? addMonths(startOfMonth(now), 1) : now;
}
// The last day that window actually loads — the agenda stops there rather than
// showing empty days it never fetched. ponytail: mid-month that is ~2 weeks
// ahead, not 30 days; a second range fetch in useCalendarEvents would close it.
const fetchedThrough = (anchor) => endOfWeek(addWeeks(endOfMonth(anchor), 1));

// Timed events of one day laid out in side-by-side columns where they overlap.
function layoutDay(events, day) {
  const d0 = startOfDay(day).getTime();
  const d1 = addDays(d0, 1).getTime();
  const items = events.map((evt) => {
    const s = Math.max(new Date(evt.start_at).getTime(), d0);
    const e = Math.min(new Date(evt.end_at || evt.start_at).getTime(), d1);
    return { evt, s, e: Math.max(e, s + 20 * 60000) };
  }).sort((a, b) => a.s - b.s || b.e - a.e);
  let cluster = [];
  let cols = [];
  let clusterEnd = 0;
  const flush = () => { cluster.forEach((it) => { it.cols = cols.length; }); cluster = []; cols = []; };
  for (const it of items) {
    if (it.s >= clusterEnd) { flush(); clusterEnd = 0; }
    let c = cols.findIndex((end) => end <= it.s);
    if (c === -1) { c = cols.length; cols.push(it.e); } else cols[c] = it.e;
    it.col = c;
    cluster.push(it);
    clusterEnd = Math.max(clusterEnd, it.e);
  }
  flush();
  return items.map((it) => ({ ...it, start: (it.s - d0) / 60000, dur: (it.e - it.s) / 60000 }));
}

// Who may do what — the same rules as CalendarPage (docs/Calendar.md).
const isOwnApiEvent = (evt, cals) => evt?._source === 'api' && cals.some((c) => c._source === 'api' && c.id === evt.calendar_id);
const isEditable = (evt, cals) => isOwnApiEvent(evt, cals) && evt.organized_by_me !== false;
function isDeletable(evt, cals) {
  if (evt?._source === 'local') return cals.find((c) => c.id === evt.calendar_id)?.is_writable !== false;
  return isOwnApiEvent(evt, cals);
}
function myEmail(evt, userEmail, accounts) {
  if (evt?._source === 'local') return accounts.find((a) => a.key === evt._accountKey)?.email_address || userEmail;
  return userEmail;
}
function isInvite(evt, userEmail, accounts) {
  if (evt?._source === 'api') return evt.organized_by_me === false;
  const organizer = (evt?.organizer_email || '').toLowerCase();
  return !!organizer && organizer !== (myEmail(evt, userEmail, accounts) || '').toLowerCase();
}
function rsvpOf(att) {
  const raw = att?.response_status || att?.responseStatus || '';
  const s = raw.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase();
  return s === 'needs_action' ? '' : s;
}
function myRsvp(evt, userEmail, accounts) {
  if (evt?._myRsvp) return evt._myRsvp;
  const me = (myEmail(evt, userEmail, accounts) || '').toLowerCase();
  return rsvpOf((evt?.attendees || []).find((a) => (a.email || '').toLowerCase() === me)) || null;
}

export default function MobileCalendar() {
  const { org, orgSlug } = useMobileOrg();
  const { user } = useAuth();
  const openNotifications = useOpenNotifications();
  const externalAccounts = useAccountStore((s) => s.externalAccounts) || NO_ACCOUNTS;
  const { events, createEvent, updateEvent, deleteEvent, rsvp } = useCalendarEvents(org?.id || orgSlug);
  const calendars = useCalendarStore((s) => s.calendars);
  const visibleCalendarIds = useCalendarStore((s) => s.visibleCalendarIds);
  const currentDate = useCalendarStore((s) => s.currentDate);
  const setCurrentDate = useCalendarStore((s) => s.setCurrentDate);

  const [segment, setSegment] = useState(SEG.UPCOMING);
  const [selected, setSelected] = useState(() => startOfDay(new Date()));
  const [month, setMonth] = useState(() => startOfMonth(new Date()));
  const [detailId, setDetailId] = useState(null);
  // /:slug/calendar/:eventId opens that event (an emailed or shared link).
  const { eventId } = useParams();
  const [seenEventId, setSeenEventId] = useState(null);
  if (eventId && eventId !== seenEventId) { setSeenEventId(eventId); setDetailId(eventId); }
  // The store only holds the visible month(s): look the linked event up and move
  // the fetch window to its date, so the detail resolves wherever it falls.
  // The fetched event is kept as the detail's fallback until the store has it;
  // a link that doesn't resolve (deleted, no access) just shows the calendar.
  const [linkedEvent, setLinkedEvent] = useState(null);
  const navigate = useNavigate();
  // Closing the detail also leaves an /…/calendar/:eventId URL, so Back and a
  // refresh don't land on an event that's no longer showing.
  const closeDetail = () => {
    setDetailId(null);
    if (eventId) navigate(`/${orgSlug}/calendar`, { replace: true });
  };
  useEffect(() => {
    if (!eventId || !isRealOrgId(org?.id)) return undefined;
    let alive = true;
    api.get(`/orgs/${org.id}/events/${encodeURIComponent(eventId)}`)
      .then((res) => {
        if (!alive || !res?.event) return;
        setLinkedEvent(res.event);
        if (res.event.start_at) setCurrentDate(new Date(res.event.start_at));
      })
      .catch((e) => {
        log.warn('MobileCalendar', `event link ${eventId} not found: ${e?.message || e}`);
        if (alive) setDetailId((id) => (id === eventId ? null : id));
      });
    return () => { alive = false; };
  }, [eventId, org?.id, setCurrentDate]);
  const [editor, setEditor] = useState(null); // { event } | { defaults }

  // Point the hook's fetch window at whatever this view shows. Only a month
  // change refetches, so same-month moves are free.
  const follow = (date) => { if (!isSameMonth(date, currentDate)) setCurrentDate(date); };
  useEffect(() => {
    setCurrentDate(upcomingAnchor(new Date()));
  }, [setCurrentDate]);

  const go = (seg, sel = selected, mon = month) => {
    setSegment(seg); setSelected(sel); setMonth(mon);
    follow(seg === SEG.UPCOMING ? upcomingAnchor(new Date()) : seg === SEG.DAY ? sel : mon);
  };
  const goToday = () => {
    const today = startOfDay(new Date());
    go(segment, today, startOfMonth(today));
  };

  const sortedCalIds = useMemo(() => calendars.map((c) => c.id).sort(), [calendars]);
  const colorOf = (evt) => getPastel(evt.calendar_id || '', sortedCalIds);
  const shown = useMemo(() => events.filter((e) => !calendars.length || visibleCalendarIds.has(e.calendar_id)), [events, calendars, visibleCalendarIds]);

  // Video-call options for MX calendars in the editor (as CalendarPage).
  const [conferencing, setConferencing] = useState([]);
  useEffect(() => {
    if (!isRealOrgId(org?.id)) return undefined;
    let alive = true;
    api.listConferencing(org.id)
      .then((res) => { if (alive) setConferencing((res?.connections || []).map((c) => c.provider)); })
      .catch((e) => log.warn('MobileCalendar', `conferencing fetch failed: ${e?.message || e}`));
    return () => { alive = false; };
  }, [org?.id]);

  const editorCalendars = useMemo(() => {
    const accts = new Map(externalAccounts.map((a) => [a.key, a]));
    const last = getLastCalendar();
    return calendars
      .filter((c) => c.is_writable !== false && c.is_owned !== false)
      .map((c) => {
        const acct = c._accountKey ? accts.get(c._accountKey) : null;
        const owner = acct ? (acct.email_address || acct.display_name) : (user?.email || org?.domain || org?.name);
        const line = !owner || c.name === owner ? c.name : `${c.name} · ${owner}`;
        const conferenceOptions = c._source === 'local'
          ? (c._conferenceProviders ?? (c.source === 'google' ? ['meet'] : c.source === 'microsoft' ? ['teams'] : []))
          : conferencing.map((p) => (p === 'google' ? 'meet' : p === 'microsoft' ? 'teams' : null)).filter(Boolean);
        return {
          ...c, label: line, email: line,
          providerType: acct ? acct.provider_type : PROVIDER.INBOX2,
          iconUrl: acct?.icon_url || org?.icon_url || null,
          avatarUrl: acct?.avatar_url || null,
          conferenceOptions,
        };
      })
      // Last-used calendar first, then inbox2's own, primaries ahead.
      .sort((a, b) => {
        const rank = (c) => (c.id === last ? 0 : c._source === 'api' ? 1 : 2) * 2 + (c.is_primary ? 0 : 1);
        return rank(a) - rank(b);
      });
  }, [calendars, externalAccounts, user, org, conferencing]);

  const newEvent = () => {
    // The next whole hour today, else 9:00 on the day being looked at.
    const onToday = segment === SEG.UPCOMING || isToday(selected);
    const base = onToday ? new Date() : new Date(selected);
    base.setHours(onToday ? base.getHours() + 1 : 9, 0, 0, 0);
    setEditor({ defaults: { start_at: base.toISOString(), end_at: new Date(base.getTime() + 3600000).toISOString() } });
  };

  const saveEvent = async (data) => {
    if (editor?.event) await updateEvent(editor.event.id, data);
    else { await createEvent(data); setLastCalendar(data.calendar_id); }
    setEditor(null);
  };

  const detail = detailId
    ? (events.find((e) => e.id === detailId) || (linkedEvent?.id === detailId ? linkedEvent : null))
    : null;
  const title = segment === SEG.DAY ? format(selected, 'EEE, MMM d')
    : segment === SEG.MONTH ? format(month, 'MMMM yyyy')
      : 'Upcoming';

  return (
    <MobileShell tab={MOBILE_TAB.CALENDAR} hideNav={!!detail || !!editor}>
      {detail ? (
        <EventDetail
          event={detail}
          color={colorOf(detail)}
          calendar={calendars.find((c) => c.id === detail.calendar_id)}
          canEdit={isEditable(detail, calendars)}
          canDelete={isDeletable(detail, calendars)}
          invite={isInvite(detail, user?.email, externalAccounts)}
          rsvpStatus={myRsvp(detail, user?.email, externalAccounts)}
          onBack={closeDetail}
          onEdit={() => setEditor({ event: detail })}
          onRsvp={(status) => rsvp(detail, status)}
          onDelete={async ({ decline }) => {
            if (decline) await rsvp(detail, 'declined');
            await deleteEvent(detail);
            closeDetail();
          }}
        />
      ) : (
        <div className={styles.screen}>
          <MobileTopBar title={title} subtitle={segment === SEG.UPCOMING ? format(new Date(), 'MMMM yyyy') : undefined}>
            <button type="button" className={styles.todayBtn} onClick={goToday}>Today</button>
            <MobileIconButton icon="plus" label="New event" onClick={newEvent} />
            <MobileIconButton icon="bell" label="Notifications" onClick={openNotifications} />
          </MobileTopBar>

          <div className={styles.segments} role="radiogroup" aria-label="Calendar view">
            {SEGMENTS.map(([key, label], i) => (
              <button
                key={key}
                type="button"
                role="radio"
                aria-checked={segment === key}
                tabIndex={segment === key ? 0 : -1}
                className={[styles.segment, segment === key ? styles.segmentOn : ''].join(' ')}
                onClick={() => go(key)}
                onKeyDown={(e) => {
                  // Standard radio-group keys: arrows step (wrapping), Home/End jump.
                  const n = SEGMENTS.length;
                  const to = { ArrowRight: i + 1, ArrowDown: i + 1, ArrowLeft: i - 1, ArrowUp: i - 1, Home: 0, End: n - 1 }[e.key];
                  if (to === undefined) return;
                  e.preventDefault();
                  const next = SEGMENTS[(to + n) % n][0];
                  go(next);
                  e.currentTarget.parentElement.querySelector(`[data-seg="${next}"]`)?.focus();
                }}
                data-seg={key}
              >
                {label}
              </button>
            ))}
          </div>

          {segment === SEG.UPCOMING && <Upcoming events={shown} colorOf={colorOf} onOpen={setDetailId} />}
          {segment === SEG.DAY && (
            <DayView
              day={selected}
              events={shown.filter((e) => onDay(e, selected))}
              colorOf={colorOf}
              onOpen={setDetailId}
              onStep={(n) => go(SEG.DAY, addDays(selected, n))}
            />
          )}
          {segment === SEG.MONTH && (
            <MonthView
              month={month}
              selected={selected}
              events={shown}
              colorOf={colorOf}
              onOpen={setDetailId}
              // A greyed day from the next/previous month moves there (and its fetch).
              onSelect={(d) => (isSameMonth(d, month) ? setSelected(d) : go(SEG.MONTH, d, startOfMonth(d)))}
              // The day list follows the month: today if it's in it, else the 1st.
              onStep={(n) => {
                const next = addMonths(month, n);
                go(SEG.MONTH, isSameMonth(new Date(), next) ? startOfDay(new Date()) : next, next);
              }}
            />
          )}
        </div>
      )}

      {editor && (
        <EventEditor
          event={editor.event || null}
          defaults={editor.defaults || null}
          orgSlug={orgSlug}
          calendars={editorCalendars}
          onSave={saveEvent}
          onClose={() => setEditor(null)}
          onDelete={editor.event && isDeletable(editor.event, calendars)
            ? async () => { await deleteEvent(editor.event); setEditor(null); closeDetail(); }
            : undefined}
        />
      )}
    </MobileShell>
  );
}

/* ── One event row (Upcoming + the month's day list) ───────── */
function EventRow({ evt, color, onOpen }) {
  const meeting = detectMeeting(evt);
  return (
    <li>
      <button type="button" className={styles.row} onClick={() => onOpen(evt.id)}>
        <span className={styles.stripe} ref={cssVars({ '--cal': color })} />
        {/* Start over end, each kept whole — a single "2:00 PM – 3:00 PM"
            wrapped mid-range in this column. */}
        <span className={styles.rowTime}>
          {evt.all_day ? 'All day' : (
            <>
              <span className={styles.rowStart}>{timeFmt(new Date(evt.start_at))}</span>
              <span className={styles.rowEnd}>{timeFmt(new Date(evt.end_at || evt.start_at))}</span>
            </>
          )}
        </span>
        <span className={styles.rowMain}>
          <span className={styles.rowTitle} dir="auto">{evt.title || '(No title)'}</span>
          {meeting ? (
            <span className={styles.rowHint}>
              {meeting.provider ? <MeetingProviderIcon provider={meeting.provider} size={12} /> : <Icon name="video" size={12} />}
              {meeting.label}
            </span>
          ) : evt.location ? (
            <span className={styles.rowHint}><Icon name="location" size={12} />{evt.location}</span>
          ) : null}
        </span>
      </button>
    </li>
  );
}

function Upcoming({ events, colorOf, onOpen }) {
  const now = useNow();
  const until = fetchedThrough(upcomingAnchor(new Date(now)));
  const days = [];
  for (let i = 0; i < UPCOMING_DAYS; i += 1) {
    const day = addDays(startOfDay(now), i);
    if (day > until) break;
    const list = events
      .filter((e) => onDay(e, day) && (i > 0 || e.all_day || new Date(e.end_at || e.start_at).getTime() > now))
      .sort(byStart);
    if (list.length) days.push({ day, list });
  }
  return (
    <div className={styles.scroll}>
      {days.length === 0 && <p className={styles.empty}>Nothing coming up through {format(until, 'MMM d')}</p>}
      {days.map(({ day, list }) => (
        <section key={dayKey(day)} className={styles.daySection}>
          <h2 className={styles.dayHeading}>{dayHeading(day)}</h2>
          <ul className={styles.list}>
            {list.map((e) => <EventRow key={e.id} evt={e} color={colorOf(e)} onOpen={onOpen} />)}
          </ul>
        </section>
      ))}
    </div>
  );
}

function StepBar({ label, onStep, unit }) {
  return (
    <div className={styles.stepBar}>
      <button type="button" className={styles.stepBtn} onClick={() => onStep(-1)} aria-label={`Previous ${unit}`}>
        <Icon name="chevron.left" size={16} />
      </button>
      <span className={styles.stepLabel}>{label}</span>
      <button type="button" className={styles.stepBtn} onClick={() => onStep(1)} aria-label={`Next ${unit}`}>
        <Icon name="chevron.right" size={16} />
      </button>
    </div>
  );
}

function DayView({ day, events, colorOf, onOpen, onStep }) {
  const allDay = events.filter((e) => e.all_day);
  const timed = layoutDay(events.filter((e) => !e.all_day), day);
  const scrollRef = useRef(null);
  const now = new Date(useNow());
  const nowMin = now.getHours() * 60 + now.getMinutes();
  // Open on the working day (or just before now), not midnight.
  const dayStr = dayKey(day);
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const hour = dayStr === dayKey(new Date()) ? Math.max(new Date().getHours() - 1, 0) : 8;
    const px = parseFloat(getComputedStyle(el).getPropertyValue('--hour-px')) || 56;
    el.scrollTop = hour * px;
  }, [dayStr]);

  return (
    <>
      <StepBar label={dayHeading(day)} unit="day" onStep={onStep} />
      {allDay.length > 0 && (
        <ul className={`${styles.list} ${styles.allDayList}`}>
          {allDay.map((e) => <EventRow key={e.id} evt={e} color={colorOf(e)} onOpen={onOpen} />)}
        </ul>
      )}
      <div className={`${styles.scroll} ${styles.timelineScroll}`} ref={scrollRef}>
        <div className={styles.timeline}>
          {Array.from({ length: 24 }, (_, h) => (
            <div key={h} className={styles.hour}>
              <span className={styles.hourLabel}>{h === 0 ? '' : new Date(2000, 0, 1, h).toLocaleTimeString([], { hour: 'numeric' })}</span>
            </div>
          ))}
          <div className={styles.lane}>
            {timed.map(({ evt, start, dur, col, cols }) => (
              <button
                key={evt.id}
                type="button"
                // Under ~45 min there's one line of room: title and time side by side.
                className={[styles.block, dur < 45 ? styles.blockShort : ''].join(' ')}
                ref={cssVars({ '--start': start, '--dur': dur, '--col': col, '--cols': cols, '--cal': colorOf(evt) })}
                onClick={() => onOpen(evt.id)}
              >
                <span className={styles.blockTitle} dir="auto">{evt.title || '(No title)'}</span>
                <span className={styles.blockTime}>{dur < 45 ? timeFmt(new Date(evt.start_at)) : timeRange(evt)}</span>
              </button>
            ))}
            {isToday(day) && <div className={styles.nowLine} ref={cssVars({ '--start': nowMin })} aria-hidden="true" />}
          </div>
        </div>
      </div>
    </>
  );
}

function MonthView({ month, selected, events, colorOf, onOpen, onSelect, onStep }) {
  const days = eachDayOfInterval({ start: startOfWeek(month, WEEK), end: endOfWeek(endOfMonth(month), WEEK) });
  const weekdays = days.slice(0, 7).map((d) => format(d, 'EEEEE'));
  const byDay = new Map(days.map((d) => [dayKey(d), events.filter((e) => onDay(e, d)).sort(byStart)]));
  const selectedList = byDay.get(dayKey(selected)) || [];

  return (
    <div className={styles.scroll}>
      <StepBar label={format(month, 'MMMM yyyy')} unit="month" onStep={onStep} />
      <div className={styles.monthGrid} role="group" aria-label={format(month, 'MMMM yyyy')}>
        {weekdays.map((w, i) => <span key={i} className={styles.weekday} aria-hidden="true">{w}</span>)}
        {days.map((d) => {
          const list = byDay.get(dayKey(d));
          const cls = [
            styles.dayCell,
            isSameMonth(d, month) ? '' : styles.dayOut,
            isToday(d) ? styles.dayToday : '',
            isSameDay(d, selected) ? styles.daySelected : '',
          ].join(' ');
          return (
            <button
              key={dayKey(d)}
              type="button"
              className={cls}
              onClick={() => onSelect(d)}
              aria-pressed={isSameDay(d, selected)}
              aria-label={`${format(d, 'EEEE, MMMM d')}${list.length ? `, ${list.length} event${list.length > 1 ? 's' : ''}` : ''}`}
            >
              <span className={styles.dayNum}>{d.getDate()}</span>
              <span className={styles.dots}>
                {list.slice(0, 3).map((e) => <span key={e.id} className={styles.dot} ref={cssVars({ '--cal': colorOf(e) })} />)}
              </span>
            </button>
          );
        })}
      </div>
      <section className={styles.daySection}>
        <h2 className={styles.dayHeading}>{dayHeading(selected)}</h2>
        {selectedList.length === 0
          ? <p className={styles.empty}>No events</p>
          : (
            <ul className={styles.list}>
              {selectedList.map((e) => <EventRow key={e.id} evt={e} color={colorOf(e)} onOpen={onOpen} />)}
            </ul>
          )}
      </section>
    </div>
  );
}

/* ── Full-screen event detail ──────────────────────────────── */
const RSVP = [['accepted', 'Accept'], ['tentative', 'Maybe'], ['declined', 'Decline']];

function EventDetail({ event, color, calendar, canEdit, canDelete, invite, rsvpStatus, onBack, onEdit, onRsvp, onDelete }) {
  const meeting = detectMeeting(event);
  const [pending, setPending] = useState(null);
  const [error, setError] = useState(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const start = new Date(event.start_at);
  const end = new Date(event.end_at || event.start_at);
  const multiDay = event.all_day
    ? String(event.end_at || '').slice(0, 10) > dayKey(addDays(new Date(String(event.start_at).slice(0, 10) + 'T00:00'), 1))
    : !isSameDay(start, end);
  // All-day end_at is exclusive (the day after the last one), so show end − 1.
  const allDayStart = new Date(String(event.start_at).slice(0, 10) + 'T00:00');
  const allDayLast = event.end_at ? addDays(new Date(String(event.end_at).slice(0, 10) + 'T00:00'), -1) : allDayStart;
  const when = event.all_day
    ? (multiDay
      ? `${format(allDayStart, 'EEE, MMM d')} – ${format(allDayLast, 'EEE, MMM d')}`
      : format(allDayStart, 'EEEE, MMMM d'))
    : multiDay
      ? `${format(start, 'EEE, MMM d')} ${timeFmt(start)} – ${format(end, 'EEE, MMM d')} ${timeFmt(end)}`
      : format(start, 'EEEE, MMMM d');

  const run = async (fn, label) => {
    setError(null);
    setPending(label);
    try { await fn(); } catch (e) {
      setError((typeof e === 'string' ? e : e?.message) || 'Something went wrong.');
    } finally { setPending(null); }
  };

  return (
    <div className={styles.screen}>
      <MobileTopBar
        title="Event"
        leading={<MobileIconButton icon="chevron.left" label="Back" onClick={onBack} />}
      >
        {canEdit && <MobileIconButton icon="pencil" label="Edit event" onClick={onEdit} />}
        {canDelete && <MobileIconButton icon="trash" label="Delete event" onClick={() => setConfirmDelete(true)} />}
      </MobileTopBar>
      <div className={`${styles.scroll} ${styles.detail}`}>
        <div className={styles.detailHead}>
          <span className={styles.detailStripe} ref={cssVars({ '--cal': color })} />
          <div>
            <h2 className={styles.detailTitle} dir="auto">{event.title || '(No title)'}</h2>
            <p className={styles.detailWhen}>{when}</p>
            {!multiDay && <p className={styles.detailWhen}>{timeRange(event)}</p>}
            {(calendar?.name || event._calendarName) && (
              <p className={styles.detailCal}>{calendar?.name || event._calendarName}</p>
            )}
          </div>
        </div>

        {meeting && (
          <button type="button" className={styles.join} onClick={() => openLink(meeting.url)}>
            {meeting.provider ? <MeetingProviderIcon provider={meeting.provider} size={18} /> : <Icon name="video" size={16} />}
            Join {meeting.label}
          </button>
        )}

        {invite && (
          <div className={styles.rsvp} role="group" aria-label="Your response">
            {RSVP.map(([status, label]) => (
              <button
                key={status}
                type="button"
                className={[styles.rsvpBtn, rsvpStatus === status ? styles.rsvpOn : ''].join(' ')}
                aria-pressed={rsvpStatus === status}
                disabled={!!pending}
                onClick={() => run(() => onRsvp(status), status)}
              >
                {pending === status ? '…' : label}
              </button>
            ))}
          </div>
        )}
        {error && <p className={styles.error} role="alert">{error}</p>}

        {event.location && (
          <div className={styles.detailRow}>
            <Icon name="location" size={15} />
            <span><Linkify text={event.location} className={styles.link} /></span>
          </div>
        )}
        {(event.organizer_name || event.organizer_email) && (
          <div className={styles.detailRow}>
            <Icon name="person" size={15} />
            <span>{event.organizer_name || event.organizer_email}{event.organizer_name && event.organizer_email ? ` (${event.organizer_email})` : ''}</span>
          </div>
        )}
        {event.description && (
          <div className={`${styles.detailRow} ${styles.detailDesc}`}>
            <Icon name="text.alignleft" size={15} />
            <span><Linkify text={event.description} className={styles.link} /></span>
          </div>
        )}

        {event.attendees?.length > 0 && (
          <section className={styles.attendees}>
            <h3 className={styles.attendeesLabel}>{event.attendees.length} attendee{event.attendees.length > 1 ? 's' : ''}</h3>
            <ul className={styles.list}>
              {event.attendees.map((a, i) => {
                const status = rsvpOf(a);
                return (
                  <li key={a.id || a.email || i} className={styles.attendee}>
                    <span className={styles.attendeeName} dir="auto">{a.name || a.email}</span>
                    {status && <span className={`${styles.badge} ${styles[`badge_${status}`] || ''}`}>{status}</span>}
                  </li>
                );
              })}
            </ul>
          </section>
        )}
      </div>
      <ConfirmDialog
        open={confirmDelete}
        title={invite ? 'Decline and delete?' : 'Delete this event?'}
        message={invite
          ? `${event.organizer_name || event.organizer_email || 'The organizer'} will be told you won't attend.`
          : `"${event.title || '(No title)'}" will be removed from your calendar.`}
        confirmLabel={invite ? 'Decline & delete' : 'Delete'}
        onCancel={() => setConfirmDelete(false)}
        onConfirm={() => { setConfirmDelete(false); run(() => onDelete({ decline: invite }), 'delete'); }}
      />
    </div>
  );
}
