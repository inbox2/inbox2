import { useState, useCallback, useEffect, useMemo, useRef } from 'react';
import { useLocation, useParams, useSearchParams } from 'react-router';
import FullCalendar from '@fullcalendar/react';
import dayGridPlugin from '@fullcalendar/daygrid';
import timeGridPlugin from '@fullcalendar/timegrid';
import interactionPlugin from '@fullcalendar/interaction';
import listPlugin from '@fullcalendar/list';
import intlTimeZonePlugin from './intlTimeZonePlugin';
import useAuth from '../../hooks/useAuth';
import useAccounts from '../../hooks/useAccounts';
import useExternalAccountSync from '../../hooks/useExternalAccountSync';
import useCalendarEvents from '../../hooks/useCalendarEvents';
import useCalendarStore from '../../stores/calendarStore';
import useNavigationStore from '../../stores/navigationStore';
import { getLastCalendar, setLastCalendar } from '../../lib/lastUsedPref';
import usePanelResize from '../../hooks/usePanelResize';
import CalendarSidebar from '../../components/Calendar/CalendarSidebar';
import TimeZonePicker from '../../components/Calendar/TimeZonePicker';
import EventDetailPopup from '../../components/Calendar/EventDetailPopup';
import { detectMeetingProvider, meetingProviderSvg } from '../../components/MeetingProviderIcon/meetingProvider';
import EventEditor from '../../components/Calendar/EventEditor';
import MoveEventDialog from '../../components/Calendar/MoveEventDialog';
import Icon from '../../components/Icon';
import ConfirmDialog from '../../components/ConfirmDialog/ConfirmDialog';
import ContextMenu from '../../components/DropdownMenu/ContextMenu';
import ZoneEditor from '../../components/Calendar/ZoneEditor';
import useZoneStore from '../../stores/zoneStore';
import { anchorFix, categoryFor, isActive, isRepeating, prepZoneParams, remaining, zoneColorVar } from '../../lib/zones';
import api from '../../lib/localFirstApi';
import { isRealOrgId } from '../../lib/org';
import { PROVIDER } from '../../lib/providerTypes';
import log from '../../lib/log';
import { getPastel, rememberPastels, EVENT_TEXT } from '../../lib/calendarColors';
import styles from './CalendarPage.module.css';

const VIEW_MAP = {
  month: 'dayGridMonth',
  week: 'timeGridWeek',
  workweek: 'timeGridWorkWeek',
  day: 'timeGridDay',
  agenda: 'listWeek',
};

// An MX/API event is the user's to change when it sits on one of their own
// calendars — the API's own write scope (`editable_by`). An event visible only
// because they're invited to it isn't, and neither is an invite they accepted
// onto their calendar: that opens read-only, with the RSVP. (Comparing the
// organizer to `user.email` hid Edit on everything — the user payload has no
// `email`, and the organizer is the member's mailbox address anyway.)
function isOwnApiEvent(evt, calendars) {
  return evt?._source === 'api' && calendars.some(c => c._source === 'api' && c.id === evt.calendar_id);
}

function isEventEditable(evt, calendars) {
  return isOwnApiEvent(evt, calendars) && evt.organized_by_me !== false;
}

// Deleting works on any event on the user's own calendars, invites included.
// Google/Microsoft events can't be edited here (updates go to the Rails API), but
// they delete through the engine — on any calendar the account can write to.
function isEventDeletable(evt, calendars) {
  if (evt?._source === 'local') return calendars.find(c => c.id === evt.calendar_id)?.is_writable !== false;
  return isOwnApiEvent(evt, calendars);
}

// Drag/resize: an MX event the user can edit, or a synced one on a writable
// calendar that isn't someone else's meeting (the provider would refuse it).
function isEventMovable(evt, calendars, userEmail, externalAccounts) {
  if (evt?._source === 'local') {
    return calendars.find(c => c.id === evt.calendar_id)?.is_writable !== false
      && !isInvite(evt, userEmail, externalAccounts);
  }
  return isEventEditable(evt, calendars);
}

// Guests besides the organizer and me — the people a move would be mailed to.
function hasGuests(evt, userEmail, externalAccounts) {
  const me = (myEmailForEvent(evt, userEmail, externalAccounts) || '').toLowerCase();
  return (evt?.attendees || []).some(a => !(a.is_organizer || a.organizer) && (a.email || '').toLowerCase() !== me);
}

// A dragged FullCalendar event's new times, in the shape the APIs take: an
// absolute instant for timed events, bare dates for all-day ones (FullCalendar
// drops `end` when it equals the default length, so a one-day event gets one back).
function movedTimes(ev) {
  if (!ev.allDay) return { start_at: ev.start.toISOString(), end_at: (ev.end || ev.start).toISOString() };
  const start = ev.startStr.slice(0, 10);
  const nextDay = new Date(Date.parse(`${start}T00:00:00Z`) + 86400000).toISOString().slice(0, 10);
  return { start_at: start, end_at: ev.endStr ? ev.endStr.slice(0, 10) : nextDay };
}

// Someone else's meeting — deleting it offers to decline to the organizer.
function isInvite(evt, userEmail, externalAccounts) {
  if (evt?._source === 'api') return evt.organized_by_me === false;
  const organizer = (evt?.organizer_email || '').toLowerCase();
  return !!organizer && organizer !== (myEmailForEvent(evt, userEmail, externalAccounts) || '').toLowerCase();
}

// The address that represents "me" for this event: the owning external account's
// address for offline events, otherwise the signed-in user's. Used to find my
// own attendee row and highlight my current RSVP.
function myEmailForEvent(evt, userEmail, externalAccounts) {
  if (evt?._source === 'local') {
    return externalAccounts.find(a => a.key === evt._accountKey)?.email_address || userEmail;
  }
  return userEmail;
}

// My current RSVP on an event (null if I'm not an attendee / haven't responded).
function myRsvpForEvent(evt, userEmail, externalAccounts) {
  const me = (myEmailForEvent(evt, userEmail, externalAccounts) || '').toLowerCase();
  if (!me || !evt?.attendees?.length) return null;
  const mine = evt.attendees.find(a => (a.email || '').toLowerCase() === me);
  return mine?.response_status || mine?.responseStatus || null;
}

// Pick order for the editor's calendar list: the account in focus (the calendar
// sidebar's, else the inbox's filter) — or, with none, the calendar last created
// on — then inbox2's own (MX) calendars, then everything else; a primary calendar
// ahead of the secondary ones inside each group.
function rank(cal, focusAccountKey, lastCalendarId) {
  const focused = focusAccountKey ? cal._accountKey === focusAccountKey : cal.id === lastCalendarId;
  const group = focused ? 0 : cal._source === 'api' ? 1 : 2;
  return group * 2 + (cal.is_primary ? 0 : 1);
}

export default function CalendarPage() {
  const { orgSlug, eventId } = useParams();
  const { key: locationKey } = useLocation();
  const [searchParams, setSearchParams] = useSearchParams();
  const { organizations, user } = useAuth();
  const currentOrg = organizations?.find(o => o.slug === orgSlug || o.id === orgSlug);
  const orgId = currentOrg?.id || orgSlug;
  const { externalAccounts } = useExternalAccountSync({ orgId });
  const { allAccounts } = useAccounts(organizations, { externalAccounts });
  const calendarRef = useRef(null);
  const calendarMainRef = useRef(null);
  const tzAnchorRef = useRef(null);
  // Temporary "view in another timezone" override (session-only — resets on reload).
  const [displayTz, setDisplayTz] = useState(() => Intl.DateTimeFormat().resolvedOptions().timeZone);
  // On a Saturday or Sunday the week view starts on Saturday: the weekend, then
  // the work week ahead, instead of five days that are already over. Read in
  // the calendar's own zone. ponytail: evaluated per render, so it flips at
  // the next render after midnight rather than on a timer.
  // Every weekend check reads days in the calendar's own zone, not the
  // browser's: the two can be on different dates.
  const ymdIn = useCallback(
    (d) => new Intl.DateTimeFormat('en-CA', { timeZone: displayTz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d),
    [displayTz],
  );
  const dowIn = useCallback((d) => new Date(`${ymdIn(d)}T00:00:00Z`).getUTCDay(), [ymdIn]);
  const weekendNow = [0, 6].includes(dowIn(new Date()));
  // The Mon–Fri columns of a Saturday-start week belong to the next week.
  // (`dow` is FullCalendar's own weekday for the cell, in the calendar's zone.)
  const nextWeekClass = useCallback(
    (arg) => (arg.view.type === 'timeGridWeek' && dowIn(arg.view.currentStart) === 6 && arg.dow >= 1 && arg.dow <= 5
      ? [styles.nextWeek] : []),
    [dowIn],
  );
  const { width: sidebarWidth, startResize: startSidebarResize } = usePanelResize(
    'inbox2_cal_sidebar_width', 260, { min: 200, max: 400 }
  );

  const view = useCalendarStore(s => s.view);
  const currentDate = useCalendarStore(s => s.currentDate);
  const setCurrentDate = useCalendarStore(s => s.setCurrentDate);
  const activeAccountKey = useCalendarStore(s => s.activeAccountKey);
  const visibleCalendarIds = useCalendarStore(s => s.visibleCalendarIds);

  const { events, createEvent, updateEvent, rescheduleEvent, deleteEvent, rsvp, respondToProposal } = useCalendarEvents(orgSlug);

  // Blocked time (docs/Calendar.md): "not available" windows that read as busy
  // to meet-link visitors and colleagues, but are not calendar events. MX-only;
  // fetched over a generous window around the visible month.
  const [blockedTimes, setBlockedTimes] = useState([]);
  const [blockedReload, setBlockedReload] = useState(0);
  const [confirmUnblock, setConfirmUnblock] = useState(null);
  const [zoneMenu, setZoneMenu] = useState(null); // { zone, x, y } — right-click on a zone band
  const [confirmZoneDelete, setConfirmZoneDelete] = useState(null);
  useEffect(() => {
    if (!isRealOrgId(orgId) || activeAccountKey) return undefined;
    let alive = true;
    const from = new Date(currentDate); from.setDate(from.getDate() - 45);
    const to = new Date(currentDate); to.setDate(to.getDate() + 45);
    api.listBlockedTimes(orgId, from.toISOString(), to.toISOString())
      .then((res) => { if (alive) setBlockedTimes(res?.blocked_times || []); })
      .catch((e) => log.warn('Calendar', `blocked-times fetch failed: ${e?.message || e}`));
    return () => { alive = false; };
  }, [orgId, activeAccountKey, currentDate, blockedReload]);

  // Zones (docs/Calendar.md "Zones"): the user's soft focus blocks. User-scoped,
  // so they show on every calendar and account view; fetched like blocked time,
  // over a generous window around the visible month.
  const zones = useZoneStore(s => s.zones);
  const zoneCategories = useZoneStore(s => s.categories);
  const hiddenZoneCategories = useZoneStore(s => s.hiddenCategoryIds);
  const [zoneEditor, setZoneEditor] = useState(null); // { zone } | { defaults }
  // Minute tick so the running zone's highlight and "time left" stay current.
  const [zoneNow, setZoneNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setZoneNow(Date.now()), 60000);
    return () => clearInterval(t);
  }, []);
  useEffect(() => {
    if (!user) return;
    const store = useZoneStore.getState();
    if (!store.categories.length) store.loadCategories();
    const from = new Date(currentDate); from.setDate(from.getDate() - 45);
    const to = new Date(currentDate); to.setDate(to.getDate() + 45);
    store.loadRange(from, to);
  }, [user, currentDate]);

  // A prep zone rides along with its meeting: when the meeting has moved, the
  // zone is retimed to end at the new start. Each fix is tried once per target
  // time, so a failing PATCH can't loop.
  const anchorTried = useRef(new Set());
  useEffect(() => {
    for (const z of zones) {
      const fix = anchorFix(z, events);
      if (!fix) continue;
      const attempt = `${z.series_id}:${fix.end_at}`;
      if (anchorTried.current.has(attempt)) continue;
      anchorTried.current.add(attempt);
      useZoneStore.getState().updateZone(z.series_id, fix)
        .catch((e) => log.warn('Calendar', `prep zone follow failed: ${e?.message || e}`));
    }
  }, [zones, events]);

  // Conferencing grants the signed-in member has (docs/Calendar.md) — what MX
  // events can have a Meet/Teams link minted for them. Local channels don't
  // need this: their own provider owns the calendar.
  const [conferencingProviders, setConferencingProviders] = useState([]);
  useEffect(() => {
    if (!isRealOrgId(orgId)) return undefined;
    let alive = true;
    api.listConferencing(orgId)
      .then((res) => { if (alive) setConferencingProviders((res?.connections || []).map(c => c.provider)); })
      .catch((e) => log.warn('Calendar', `conferencing fetch failed: ${e?.message || e}`));
    return () => { alive = false; };
  }, [orgId]);

  // The calendars a new event can be created on, labelled with the account that
  // owns them, plus the video-meeting each one can mint.
  const storeCalendars = useCalendarStore(s => s.calendars);
  const inboxAccountKey = useNavigationStore(s => s.accountKey);
  const editorCalendars = useMemo(() => {
    const acctByKey = new Map((allAccounts || []).map(a => [a.key, a]));
    return storeCalendars
      // Writable AND ours: a calendar someone transferred or shared with write
      // access still shows its events, but it is not somewhere to put your own
      // meetings, so it stays out of this picker.
      .filter(c => c.is_writable !== false && c.is_owned !== false)
      .map((c) => {
        const acct = c._accountKey ? acctByKey.get(c._accountKey) : null;
        // An MX calendar has no account row of its own — say which domain it
        // belongs to, or the picker just reads "Calendar".
        const owner = acct
          ? (acct.email_address || acct.display_name)
          : (user?.email || currentOrg?.domain || currentOrg?.name);
        let conferenceOptions;
        if (c._source === 'local') {
          // The provider's own answer (calendars.conference_providers), so a
          // mailbox without Teams doesn't get offered one and 400 the create.
          // Only when the column predates this account's last calendar sync do
          // we fall back to assuming the obvious one for the provider.
          conferenceOptions = c._conferenceProviders
            ?? (c.source === 'google' ? ['meet'] : c.source === 'microsoft' ? ['teams'] : []);
        } else {
          conferenceOptions = conferencingProviders
            .map(p => (p === 'google' ? 'meet' : p === 'microsoft' ? 'teams' : null))
            .filter(Boolean);
        }
        // Shaped for FromSelect (the compose From picker): one line of text
        // plus the account's own channel icon. A primary calendar is named
        // after its account, so don't print the address twice.
        const line = !owner || c.name === owner ? c.name : `${c.name} · ${owner}`;
        return {
          ...c,
          label: line,
          email: line,
          providerType: acct ? acct.provider_type : PROVIDER.INBOX2,
          iconUrl: acct?.icon_url || currentOrg?.icon_url || null,
          avatarUrl: acct?.avatar_url || null,
          conferenceOptions,
        };
      })
      // The account in focus first, then inbox2's own calendars.
      .sort((a, b) => {
        const focus = activeAccountKey || inboxAccountKey;
        const last = getLastCalendar();
        return rank(a, focus, last) - rank(b, focus, last);
      });
  }, [storeCalendars, allAccounts, user, currentOrg, conferencingProviders, activeAccountKey, inboxAccountKey]);

  const [selectedEvent, setSelectedEvent] = useState(null);
  const [popupPosition, setPopupPosition] = useState(null);
  const [editorEvent, setEditorEvent] = useState(null);
  const [editorDefaults, setEditorDefaults] = useState(null);
  const [editorReadOnly, setEditorReadOnly] = useState(false);

  const userEmail = user?.email;
  const selectedEditable = isEventEditable(selectedEvent, storeCalendars);

  // ?new=<ISO> — the timezone planner's "Schedule meeting" handing over the
  // slot under its ruler. Read straight off the URL rather than copied into
  // state; closing the editor drops the param.
  const plannerDefaults = useMemo(() => {
    const start = new Date(searchParams.get('new') || '');
    if (Number.isNaN(start.getTime())) return null;
    return {
      start_at: start.toISOString(),
      end_at: new Date(start.getTime() + 3600000).toISOString(),
    };
  }, [searchParams]);

  // Sync FullCalendar view when store changes
  useEffect(() => {
    const api = calendarRef.current?.getApi();
    if (!api) return;
    const fcView = VIEW_MAP[view] || 'timeGridWeek';
    if (api.view.type !== fcView) {
      api.changeView(fcView);
    }
  }, [view]);

  useEffect(() => {
    const api = calendarRef.current?.getApi();
    if (!api) return;
    const current = api.getDate();
    if (current.toDateString() !== currentDate.toDateString()) {
      api.gotoDate(currentDate);
    }
  }, [currentDate]);

  // Park the timezone chip in FullCalendar's top-left corner cell (the empty
  // axis header above the hour gutter). Measured off the real cell so it tracks
  // theme/width; hidden in month/list views where there's no hour axis.
  useEffect(() => {
    const place = () => {
      const anchor = tzAnchorRef.current;
      const main = calendarMainRef.current;
      if (!anchor || !main) return;
      const axis = main.querySelector('.fc-timegrid-axis');
      if (!axis) { anchor.style.display = 'none'; return; }
      const a = axis.getBoundingClientRect();
      const m = main.getBoundingClientRect();
      anchor.style.display = 'flex';
      anchor.style.setProperty('--tz-top', `${a.top - m.top}px`);
      anchor.style.setProperty('--tz-left', `${a.left - m.left}px`);
      anchor.style.setProperty('--tz-width', `${a.width}px`);
      anchor.style.setProperty('--tz-height', `${a.height}px`);
    };
    const id = requestAnimationFrame(place);
    window.addEventListener('resize', place);
    return () => { cancelAnimationFrame(id); window.removeEventListener('resize', place); };
  }, [view, currentDate, sidebarWidth, displayTz]);

  // Deep link from a meeting-invite banner (/:orgSlug/calendar/:eventId): once the
  // event is in the loaded window, open its detail popup (centered — no anchor).
  const openedEventRef = useRef(null);
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: open the popup once the deep-linked event loads */
  useEffect(() => {
    // Keyed on the navigation too, not just the id: the menu bar popover can ask
    // for the same meeting twice, and the second ask must reopen the popup.
    const ask = `${eventId}:${locationKey}`;
    if (!eventId || openedEventRef.current === ask) return;
    const evt = events.find(e => e.id === eventId);
    if (!evt) return; // still loading the window for this date
    openedEventRef.current = ask;
    setSelectedEvent(evt);
    setPopupPosition({ top: window.innerHeight / 2 - 160, left: window.innerWidth / 2 - 160 });
    if (evt.start_at) setCurrentDate(new Date(evt.start_at));
  }, [eventId, locationKey, events, setCurrentDate]);
  /* eslint-enable react-hooks/set-state-in-effect */

  // Filter events by active account + calendar visibility
  const filteredEvents = events.filter(e => {
    if (activeAccountKey && e._accountKey !== activeAccountKey) return false;
    if (!visibleCalendarIds.has(e.calendar_id)) return false;
    return true;
  });

  // FullCalendar event format
  const sortedCalendarIds = storeCalendars.map(c => c.id).sort();
  // Record the assignment so the day previews and the menu bar popover — which
  // never see this whole list — draw each calendar in the same pastel.
  const calendarIdsSig = sortedCalendarIds.join(',');
  useEffect(() => {
    if (calendarIdsSig) rememberPastels(calendarIdsSig.split(','));
  }, [calendarIdsSig]);
  const fcEvents = filteredEvents.map(evt => {
    const pastel = getPastel(evt.calendar_id || '', sortedCalendarIds);
    return {
      id: evt.id,
      title: evt.title,
      start: evt.start_at,
      end: evt.end_at,
      allDay: evt.all_day,
      backgroundColor: pastel,
      borderColor: pastel,
      textColor: EVENT_TEXT,
      editable: isEventMovable(evt, storeCalendars, userEmail, externalAccounts),
      extendedProps: evt,
    };
  });

  // Blocked windows render hatched; only the owner ever sees them (the API
  // only returns your own), and clicking one offers to remove it.
  const fcBlocked = (isRealOrgId(orgId) && !activeAccountKey ? blockedTimes : []).map(b => ({
    id: `blocked-${b.id}`,
    title: 'Blocked',
    start: b.start_at,
    end: b.end_at,
    classNames: [styles.blockedEvent],
    // Not draggable/resizable: the global `editable` flag would otherwise route
    // a drop into updateEvent() with no event id, desyncing the box from the
    // stored window. Move a block by removing + redrawing it.
    editable: false,
    startEditable: false,
    durationEditable: false,
    extendedProps: { blocked_time: b },
  }));

  // Zones render as background bands behind the events — never busy, never
  // draggable — in the time-grid views only: a month cell or the agenda list
  // would just paint a whole day for a two-hour zone.
  const fcZones = (user && view !== 'month' && view !== 'agenda' ? zones : [])
    .filter(z => !hiddenZoneCategories.has(z.category_id))
    .map((z) => {
      const cat = categoryFor(z, zoneCategories);
      const active = isActive(z, zoneNow);
      return {
        id: `zone-${z.id}`,
        title: z.name,
        start: z.start_at,
        end: z.end_at,
        display: 'background',
        classNames: [styles.zoneEvent, active ? styles.zoneActive : ''].filter(Boolean),
        extendedProps: { zone: z, zoneCategory: cat, zoneActive: active },
      };
    });

  // A single click waits out the double-click window before opening the popup,
  // so a double-click goes straight to the view without the popup flashing up.
  const clickTimer = useRef(null);
  useEffect(() => () => clearTimeout(clickTimer.current), []);
  const handleEventClick = useCallback((info) => {
    if (info.event.extendedProps?.blocked_time) {
      setConfirmUnblock(info.event.extendedProps.blocked_time);
      return;
    }
    clearTimeout(clickTimer.current);
    // Double-click opens the full view — for every event, your own included;
    // the view offers Edit when the event is yours to change.
    if (info.jsEvent.detail >= 2) {
      setSelectedEvent(null);
      setEditorReadOnly(true);
      setEditorEvent(info.event.extendedProps);
      setEditorDefaults(null);
      return;
    }
    const rect = info.el.getBoundingClientRect();
    const evt = info.event.extendedProps;
    // ponytail: fixed 250ms, not the OS double-click setting (the web can't read it).
    clickTimer.current = setTimeout(() => {
      setSelectedEvent(evt);
      setPopupPosition({ top: rect.top, left: rect.right + 8 });
    }, 250);
  }, []);

  // Drag on empty time: offer "New event" or (MX, timed selections only)
  // "Block time". A single choice goes straight to the editor as before.
  const [selectChoice, setSelectChoice] = useState(null);
  const handleDateSelect = (selectInfo) => {
    const defaults = {
      start_at: selectInfo.startStr,
      end_at: selectInfo.endStr,
      all_day: selectInfo.allDay,
    };
    selectInfo.view.calendar.unselect();
    if ((user || (isRealOrgId(orgId) && !activeAccountKey)) && !selectInfo.allDay) {
      const x = selectInfo.jsEvent?.clientX ?? window.innerWidth / 2;
      const y = selectInfo.jsEvent?.clientY ?? window.innerHeight / 2;
      setSelectChoice({ defaults, x, y });
      return;
    }
    setEditorReadOnly(false);
    setEditorDefaults(defaults);
    setEditorEvent(null);
  };

  const openEditorFromChoice = () => {
    setEditorReadOnly(false);
    setEditorDefaults(selectChoice.defaults);
    setEditorEvent(null);
    setSelectChoice(null);
  };

  const zoneFromChoice = () => {
    setZoneEditor({ defaults: selectChoice.defaults });
    setSelectChoice(null);
  };

  const blockFromChoice = async () => {
    const { defaults } = selectChoice;
    setSelectChoice(null);
    try {
      await api.createBlockedTime(orgId, { start_at: defaults.start_at, end_at: defaults.end_at });
      setBlockedReload(n => n + 1);
    } catch (e) {
      log.warn('Calendar', `block time failed: ${e?.message || e}`);
    }
  };

  // Close the selection choice on Escape or any outside click.
  useEffect(() => {
    if (!selectChoice) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') setSelectChoice(null); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [selectChoice]);


  const handleEventDidMount = useCallback((info) => {
    const el = info.el;
    const { zone, zoneCategory } = info.event.extendedProps;
    if (zone) {
      el.style.setProperty('--zone', zoneColorVar(zoneCategory?.color));
      // The label opens the zone; the rest of the band stays a drag target, so
      // you can still draw a meeting inside a zone. Swallow the press on the
      // label so FullCalendar doesn't start a selection under it.
      const label = el.querySelector('[data-zone-label]');
      if (label) {
        const swallow = (e) => e.stopPropagation();
        label.addEventListener('pointerdown', swallow);
        label.addEventListener('mousedown', swallow);
        label.addEventListener('click', (e) => { e.stopPropagation(); setZoneEditor({ zone }); });
      }
      el.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        e.stopPropagation();
        setZoneMenu({ zone, x: e.clientX, y: e.clientY });
      });
      return;
    }
    // 3D raised effect on top of FullCalendar's native background
    el.style.setProperty('box-shadow', 'inset 0 1px 0 rgba(255,255,255,0.35), inset 0 -1px 0 rgba(0,0,0,0.1), 0 1px 2px rgba(0,0,0,0.15)');
    // Month view lists timed events as text rather than filled blocks, so the
    // calendar's identity has to live in the text itself. Drop FullCalendar's
    // dot (CSS) and tint the label instead — mixed toward --text-primary so it
    // stays readable on both the light and dark surface.
    if (el.classList.contains('fc-daygrid-dot-event')) {
      el.style.setProperty('--event-color', info.event.backgroundColor);
      el.style.setProperty('color', 'color-mix(in srgb, var(--event-color) 65%, var(--text-primary))');
    }
    // Brand the block with the real meeting-provider logo (Zoom/Meet/Teams…),
    // parked top-right where there's open space, so the meeting type reads at a
    // glance without crowding the title.
    const evt = info.event.extendedProps;
    const provider = detectMeetingProvider(evt.location, evt.description, evt.title);
    if (provider && !el.querySelector(`.${styles.eventBrand}`)) {
      el.classList.add(styles.branded);
      el.insertAdjacentHTML('beforeend', `<span class="${styles.eventBrand}">${meetingProviderSvg(provider, 18)}</span>`);
    }
  }, []);

  // A zone band's label: category, name, and — while it runs — the time left.
  const renderEventContent = useCallback((arg) => {
    const { zone, zoneCategory, zoneActive } = arg.event.extendedProps;
    if (!zone) return true; // FullCalendar's own rendering
    return (
      <button type="button" className={styles.zoneLabel} data-zone-label aria-label={`Zone: ${zone.name}`}>
        <span className={styles.zoneCategory}>
          <span className={styles.zoneDot} />
          {zoneCategory?.name || 'Zone'}
          {zoneActive && <span className={styles.zoneLeft}>{remaining(zone, zoneNow)} left</span>}
        </span>
        <span className={styles.zoneName}>{zone.name}</span>
      </button>
    );
  }, [zoneNow]);

  // Drag and resize both land here. A repeating event or one with guests asks
  // first (this/all events, mail the guests or not); anything else just moves.
  // The box stays where it was dropped meanwhile. The dialog stays up while the
  // move saves; a refused move (asked or not) reopens it with the reason, and
  // Cancel puts the box back.
  const [pendingMove, setPendingMove] = useState(null);
  const commitMove = async (pending, choice) => {
    setPendingMove({ ...pending, saving: true, error: null });
    try {
      await rescheduleEvent(pending.evt, { ...pending.move, ...choice });
      setPendingMove(null);
    } catch (e) {
      log.warn('Calendar', `move failed: ${e?.message || e}`);
      setPendingMove({ ...pending, saving: false, error: e?.message || String(e) });
    }
  };
  const handleEventMove = (info) => {
    const evt = info.event.extendedProps;
    // FullCalendar's delta is wall-clock in the shown zone, so a series moved
    // "an hour later" stays an hour later on both sides of a DST change.
    const delta = info.delta || info.startDelta;
    const move = {
      ...movedTimes(info.event),
      all_day: info.event.allDay,
      shift_seconds: Math.round((delta.days || 0) * 86400 + delta.milliseconds / 1000),
    };
    const fmt = new Intl.DateTimeFormat(navigator.language, info.event.allDay
      ? { weekday: 'short', day: 'numeric', month: 'short', timeZone: displayTz }
      : { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', timeZone: displayTz });
    // The dialog wears the event's channel icon, as the calendar sidebar does.
    const acct = evt._accountKey ? allAccounts.find(a => a.key === evt._accountKey) : null;
    const pending = {
      evt, info, move,
      channel: {
        type: acct?.provider_type
          || (evt._source === 'local' ? (evt._calendarSource === 'google' ? PROVIDER.GMAIL : evt._calendarSource) : PROVIDER.INBOX2),
        iconUrl: acct?.icon_url || null,
      },
      // All-day ends are exclusive (midnight after the last day), so a range
      // ends a day earlier; a one-day event shows just its date.
      when: (() => {
        const { start, end, allDay } = info.event;
        const last = end && allDay ? new Date(end.getTime() - 86400000) : end;
        return last && last > start ? fmt.formatRange(start, last) : fmt.format(start);
      })(),
      // A resize only changes the length; the dialog says so.
      resized: !!info.startDelta,
      recurring: evt._source === 'local' ? !!evt._seriesId : !!evt.is_recurring,
      // ponytail: "All events" only for same-day moves; shifting a series onto
      // another weekday needs its BYDAY rewritten, which no path does yet.
      allAllowed: info.event.startStr.slice(0, 10) === info.oldEvent.startStr.slice(0, 10),
      hasGuests: hasGuests(evt, userEmail, externalAccounts),
      // Graph mails attendees on every organizer change, with no way to opt out.
      canSkipMail: !(evt._source === 'local' && evt._calendarSource === 'microsoft'),
    };
    if (!pending.recurring && !pending.hasGuests) {
      // Nothing to ask; the dialog only appears if the move is refused.
      pending.silent = true;
      commitMove(pending, { scope: 'this', notify: true });
      return;
    }
    setPendingMove(pending);
  };

  const setView = useCalendarStore(s => s.setView);
  const prevViewRef = useRef(null);

  const handleNavLinkDayClick = useCallback((date) => {
    const api = calendarRef.current?.getApi();
    if (!api) return;
    // If already in day view, go back to previous view
    if (api.view.type === 'timeGridDay') {
      const prev = prevViewRef.current || 'timeGridWeek';
      api.changeView(prev, date);
      const viewKey = Object.entries(VIEW_MAP).find(([, v]) => v === prev)?.[0] || 'week';
      setView(viewKey);
    } else {
      prevViewRef.current = api.view.type;
      setCurrentDate(date);
      setView('day');
      api.changeView('timeGridDay', date);
    }
  }, [setCurrentDate, setView]);

  const setVisibleRange = useCalendarStore(s => s.setVisibleRange);
  // The Saturday-start week is the weekend's "now" view: it shows while the
  // calendar is focused on today's own Saturday or Sunday (Today, or picking
  // either in the mini calendar). Focus anywhere else — last Monday, or
  // wherever prev/next lead — and it's an ordinary Mon–Sun week. Derived from
  // the focus date alone, so every way of navigating agrees.
  const onTodaysWeekend = (d) => {
    if (!weekendNow || !d) return false;
    const today = new Date(`${ymdIn(new Date())}T00:00:00Z`);
    const sat = new Date(today.getTime() - (today.getUTCDay() === 0 ? 86_400_000 : 0)).toISOString().slice(0, 10);
    const sun = new Date(new Date(`${sat}T00:00:00Z`).getTime() + 86_400_000).toISOString().slice(0, 10);
    return [sat, sun].includes(ymdIn(new Date(d)));
  };
  const firstDay = view === 'week' && onTodaysWeekend(currentDate) ? 6 : 1;
  // Prev/next always land on a Monday, so paging never falls back into the
  // weekend view: from Sat–Fri, next is the Mon–Sun week its Mon–Fri belong
  // to and prev the one its weekend closes; from a Mon–Sun week, ±7 days.
  const pageWeek = useCallback((dir) => {
    const api = calendarRef.current?.getApi();
    if (!api) return;
    if (api.view.type !== 'timeGridWeek') {
      if (dir > 0) api.next(); else api.prev();
      return;
    }
    const start = api.view.currentStart;
    const days = dowIn(start) === 6 ? (dir > 0 ? 2 : -5) : dir * 7;
    // Noon of the target day: whole-day steps from midnight can land an hour
    // short of it across a DST change.
    api.gotoDate(new Date(start.getTime() + (days * 24 + 12) * 3_600_000));
  }, [dowIn]);
  const toolbarButtons = useMemo(() => ({
    prev: { hint: 'Previous', click: () => pageWeek(-1) },
    next: { hint: 'Next', click: () => pageWeek(1) },
    // Today also sets the focus itself: on this Mon–Sun week the range
    // doesn't change, so datesSet wouldn't report it.
    today: { text: 'today', hint: 'Today', click: () => { setCurrentDate(new Date()); calendarRef.current?.getApi().today(); } },
  }), [pageWeek, setCurrentDate]);

  const handleDatesSet = useCallback((dateInfo) => {
    // Use the period anchor, NOT dateInfo.start: the latter is the padded grid
    // start (activeStart), which in month/week view falls in the PREVIOUS month
    // (July's grid opens Mon Jun 29). Feeding that back into currentDate snapped
    // the mini-calendar's month back on every prev/next, so navigation looked dead.
    //
    // And not currentStart either, but the date the calendar is focused on
    // (getDate: what Today, gotoDate and the mini calendar set). currentStart
    // is the week's first day; writing it back re-pointed the calendar at it
    // and lost the focus the weekend view is decided by.
    setCurrentDate(dateInfo.view.calendar.getDate());
    setVisibleRange(dateInfo.start, dateInfo.end);
    // Mirror FullCalendar's own toolbar back into the store — its view buttons
    // bypass setView, so the store (and the sidebar's active-view highlight
    // that reads it) silently disagreed with the grid.
    const viewKey = Object.entries(VIEW_MAP).find(([, v]) => v === dateInfo.view.type)?.[0];
    if (viewKey) setView(viewKey);
  }, [setCurrentDate, setVisibleRange, setView]);

  const handleClosePopup = useCallback(() => {
    setSelectedEvent(null);
    setPopupPosition(null);
  }, []);

  // The popup's View: the full view first, always — Edit and Delete live there.
  const handleEditEvent = useCallback((event) => {
    setEditorReadOnly(true);
    setEditorEvent(event);
    setEditorDefaults(null);
    setSelectedEvent(null);
  }, []);

  const handleCloseEditor = useCallback(() => {
    setEditorEvent(null);
    setEditorDefaults(null);
    setSearchParams((p) => { p.delete('new'); return p; }, { replace: true });
  }, [setSearchParams]);

  const handleSaveEvent = useCallback(async (eventData) => {
    if (editorEvent) {
      await updateEvent(editorEvent.id, eventData);
    } else {
      await createEvent(eventData);
      setLastCalendar(eventData.calendar_id);
    }
    handleCloseEditor();
  }, [editorEvent, updateEvent, createEvent, handleCloseEditor]);

  // `decline`: an invite being deleted — tell the organizer first (Google/Graph
  // mail the reply; the API sends a METHOD:REPLY), then remove it.
  const handleDeleteEvent = useCallback(async (event, { decline = false } = {}) => {
    if (decline) await rsvp(event, 'declined');
    await deleteEvent(event);
    handleClosePopup();
    handleCloseEditor();
  }, [rsvp, deleteEvent, handleClosePopup, handleCloseEditor]);

  // RSVP from the read-only invite view; bound to the event the editor is showing.
  const handleEditorRsvp = useCallback((status) => {
    if (editorEvent) return rsvp(editorEvent, status);
  }, [editorEvent, rsvp]);

  // "Prep zone" on a meeting's popup: a zone that ends as the meeting starts.
  const handlePrepZone = useCallback(async (event, minutes) => {
    handleClosePopup();
    try {
      await useZoneStore.getState().createZone(prepZoneParams(event, minutes, useZoneStore.getState().categories));
    } catch (e) {
      log.warn('Calendar', `prep zone failed: ${e?.message || e}`);
    }
  }, [handleClosePopup]);

  // Answering an attendee's counter-proposal closes the detail popup either
  // way: accepting moves the event, declining removes the pending row.
  const handleRespondProposal = useCallback(async (event, attendee, action) => {
    handleClosePopup();
    try {
      await respondToProposal(event, attendee, action);
    } catch { /* the hook's refetch reconciles */ }
  }, [respondToProposal, handleClosePopup]);

  return (
    <>
      <div className={styles.body}>
        <CalendarSidebar
          width={sidebarWidth}
          accounts={allAccounts}
          onNewEvent={() => {
            setEditorReadOnly(false);
            setEditorDefaults({ start_at: new Date().toISOString(), end_at: new Date(Date.now() + 3600000).toISOString() });
            setEditorEvent(null);
          }}
          onEventClick={(evt, rect) => {
            setSelectedEvent(evt);
            setPopupPosition({ top: rect.top, left: rect.right + 8 });
          }}
          onNewZone={user ? () => setZoneEditor({ defaults: null }) : undefined}
          onZoneClick={(zone) => setZoneEditor({ zone })}
        />
        <div className={styles.resizeHandle} role="presentation" onMouseDown={startSidebarResize} />

        <div className={styles.calendarMain} ref={calendarMainRef}>
          <div className={styles.tzAnchor} ref={tzAnchorRef}>
            <TimeZonePicker value={displayTz} onChange={setDisplayTz} />
          </div>
          <FullCalendar
            ref={calendarRef}
            plugins={[dayGridPlugin, timeGridPlugin, interactionPlugin, listPlugin, intlTimeZonePlugin]}
            initialView={VIEW_MAP[view] || 'timeGridWeek'}
            initialDate={currentDate}
            customButtons={toolbarButtons}
            headerToolbar={{
              left: 'prev,next today',
              center: 'title',
              right: 'dayGridMonth,timeGridWeek,timeGridDay,listWeek',
            }}
            events={[...fcZones, ...fcEvents, ...fcBlocked]}
            eventContent={renderEventContent}
            editable
            selectable
            selectMirror
            dayMaxEvents
            weekends
            nowIndicator
            slotMinTime="06:00:00"
            slotMaxTime="22:00:00"
            scrollTime="09:00:00"
            timeZone={displayTz}
            locale={navigator.language}
            // Calendar-wide, not under `views`: FullCalendar takes week
            // boundaries from the top-level option and ignores a per-view one.
            firstDay={firstDay}
            slotDuration="00:30:00"
            snapDuration="00:15:00"
            businessHours={{
              daysOfWeek: [1, 2, 3, 4, 5],
              startTime: '09:00',
              endTime: '17:00',
            }}
            height="100%"
            allDaySlot
            allDayText=""
            navLinks
            navLinkDayClick={handleNavLinkDayClick}
            eventClick={handleEventClick}
            select={handleDateSelect}
            eventDidMount={handleEventDidMount}
            eventDrop={handleEventMove}
            eventResize={handleEventMove}
            // Timed ↔ all-day would need a new end FullCalendar doesn't give.
            eventAllow={(drop, dragged) => drop.allDay === dragged.allDay}
            datesSet={handleDatesSet}
            dayHeaderFormat={{ weekday: 'short', day: 'numeric' }}
            dayHeaderClassNames={nextWeekClass}
            dayCellClassNames={nextWeekClass}
            slotLabelFormat={{ hour: 'numeric', minute: '2-digit', meridiem: 'short' }}
            views={{
              dayGridMonth: {
                // Month columns are weekdays, not dates: the page-level
                // {weekday, day} format printed a bogus day number in the header.
                dayHeaderFormat: { weekday: 'short' },
              },
              timeGridWorkWeek: {
                type: 'timeGrid',
                duration: { days: 5 },
                buttonText: 'Work week',
              },
            }}
          />
        </div>
      </div>

      {selectChoice && (
        <>
          <div className={styles.selectChoiceBackdrop} role="presentation" onMouseDown={() => setSelectChoice(null)} />
          <div
            className={styles.selectChoice}
            ref={(el) => {
              if (!el) return;
              // Measured, not guessed: the menu is 2 or 3 items tall. Near the
              // bottom it opens upwards from the pointer instead of running off.
              const { offsetWidth: w, offsetHeight: h } = el;
              const { x, y } = selectChoice;
              const top = y + h > window.innerHeight - 8 ? y - h : y;
              el.style.setProperty('--choice-x', `${Math.max(8, Math.min(x, window.innerWidth - w - 8))}px`);
              el.style.setProperty('--choice-y', `${Math.max(8, top)}px`);
            }}
            role="menu"
          >
            <button type="button" className={styles.selectChoiceItem} onClick={openEditorFromChoice}>
              <Icon name="calendar" size={16} className={styles.selectChoiceIcon} />
              <span className={styles.selectChoiceText}>
                New event
                <span className={styles.selectChoiceHint}>Invite people to it</span>
              </span>
            </button>
            <button type="button" className={styles.selectChoiceItem} onClick={zoneFromChoice}>
              <Icon name="scope" size={16} className={styles.selectChoiceIcon} />
              <span className={styles.selectChoiceText}>
                New zone
                <span className={styles.selectChoiceHint}>Focus time, still bookable</span>
              </span>
            </button>
            {isRealOrgId(orgId) && !activeAccountKey && (
              <button type="button" className={styles.selectChoiceItem} onClick={blockFromChoice}>
                <Icon name="nosign" size={16} className={styles.selectChoiceIcon} />
                <span className={styles.selectChoiceText}>
                  Block time
                  <span className={styles.selectChoiceHint}>Shows you as busy</span>
                </span>
              </button>
            )}
          </div>
        </>
      )}
      <ContextMenu
        open={!!zoneMenu}
        position={zoneMenu}
        onClose={() => setZoneMenu(null)}
        items={zoneMenu ? [
          { label: 'Edit zone', icon: 'pencil', onSelect: () => setZoneEditor({ zone: zoneMenu.zone }) },
          { separator: true },
          ...(isRepeating(zoneMenu.zone)
            ? [{ label: 'Delete this zone', icon: 'trash', danger: true, onSelect: () => setConfirmZoneDelete({ zone: zoneMenu.zone, only: true }) }]
            : []),
          { label: isRepeating(zoneMenu.zone) ? 'Delete series' : 'Delete zone', icon: 'trash', danger: true, onSelect: () => setConfirmZoneDelete({ zone: zoneMenu.zone }) },
        ] : []}
      />
      <ConfirmDialog
        open={!!confirmZoneDelete}
        title="Delete zone?"
        message={confirmZoneDelete?.only ? 'Only this day goes; the other repeats stay.'
          : isRepeating(confirmZoneDelete?.zone) ? 'Every repeat of this zone goes too.' : 'This removes it from your calendar.'}
        confirmLabel="Delete"
        onCancel={() => setConfirmZoneDelete(null)}
        onConfirm={async () => {
          try {
            await useZoneStore.getState().deleteZone(confirmZoneDelete.zone, { only: confirmZoneDelete.only });
          } catch (e) {
            log.warn('Calendar', `zone delete failed: ${e?.message || e}`);
          }
          setConfirmZoneDelete(null);
        }}
      />
      <ConfirmDialog
        open={!!confirmUnblock}
        title="Remove blocked time?"
        message="People can book this time again."
        confirmLabel="Remove"
        onCancel={() => setConfirmUnblock(null)}
        onConfirm={async () => {
          try {
            await api.deleteBlockedTime(orgId, confirmUnblock.id);
            setBlockedReload(n => n + 1);
          } catch (e) {
            log.warn('Calendar', `unblock failed: ${e?.message || e}`);
          }
          setConfirmUnblock(null);
        }}
      />
      {selectedEvent && popupPosition && (
        <EventDetailPopup
          event={selectedEvent}
          position={popupPosition}
          onClose={handleClosePopup}
          onView={handleEditEvent}
          onRespondProposal={handleRespondProposal}
          canEdit={selectedEditable}
          onPrepZone={user ? handlePrepZone : undefined}
        />
      )}

      {pendingMove && !(pendingMove.silent && !pendingMove.error) && (
        <MoveEventDialog
          open
          channel={pendingMove.channel}
          title={pendingMove.evt.title}
          resized={pendingMove.resized}
          when={pendingMove.when}
          saving={pendingMove.saving}
          error={pendingMove.error}
          recurring={pendingMove.recurring}
          allAllowed={pendingMove.allAllowed}
          hasGuests={pendingMove.hasGuests}
          canSkipMail={pendingMove.canSkipMail}
          onConfirm={(choice) => commitMove(pendingMove, choice)}
          onCancel={() => { pendingMove.info.revert(); setPendingMove(null); }}
        />
      )}

      {zoneEditor && (
        <ZoneEditor
          zone={zoneEditor.zone}
          defaults={zoneEditor.defaults}
          onClose={() => setZoneEditor(null)}
        />
      )}

      {(editorEvent || editorDefaults || plannerDefaults) && (
        <EventEditor
          event={editorEvent}
          defaults={editorDefaults || plannerDefaults}
          orgSlug={orgSlug}
          calendars={editorCalendars}
          onSave={handleSaveEvent}
          onClose={handleCloseEditor}
          readOnly={editorReadOnly}
          onEdit={editorReadOnly && isEventEditable(editorEvent, storeCalendars) ? () => setEditorReadOnly(false) : undefined}
          onDelete={editorEvent && isEventDeletable(editorEvent, storeCalendars) ? (opts) => handleDeleteEvent(editorEvent, opts) : undefined}
          isInvite={!!editorEvent && isInvite(editorEvent, userEmail, externalAccounts)}
          myRsvp={editorEvent ? myRsvpForEvent(editorEvent, userEmail, externalAccounts) : null}
          // Answering only makes sense on someone else's meeting.
          onRsvp={editorEvent && isInvite(editorEvent, userEmail, externalAccounts) ? handleEditorRsvp : undefined}
        />
      )}

    </>
  );
}
