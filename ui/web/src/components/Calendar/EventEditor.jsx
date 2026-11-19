import { useState, useCallback, useMemo, useEffect } from 'react';
import { format } from 'date-fns';
import { ToolbarButton } from '../ToolbarGroup';
import Checkbox from '../Checkbox/Checkbox';
import TagInput from '../TagInput/TagInput';
import MgmtSelect from '../management/MgmtSelect';
import Switch from '../Switch/Switch';
import FromSelect from '../FromSelect/FromSelect';
import useContactSuggestions from '../../hooks/useContactSuggestions';
import SchedulingAssistant from './SchedulingAssistant';
import Icon from '../Icon';
import MeetingProviderIcon from '../MeetingProviderIcon/MeetingProviderIcon';
import ConfirmDialog from '../ConfirmDialog/ConfirmDialog';
import Linkify from '../Linkify';
import { EVENT_PREVIEW } from '../../lib/storageKeys';
import DateField from '../DateField/DateField';
import { NO_REPEAT, REPEAT_FREQS, WEEKDAYS, buildRRule, describeRepeat, parseRRule, repeatDays } from '../../lib/recurrence';
import { PROVIDER } from '../../lib/providerTypes';
import MoveEventDialog from './MoveEventDialog';
import styles from './EventEditor.module.css';

// The video-meeting a provider can mint for an event it owns: Google Meet on a
// Google calendar, Teams on a Microsoft one (docs/Calendar.md). Which of these
// a calendar offers is decided by its owner and arrives on `conferenceOptions`.
const CONFERENCE_LABELS = {
  meet: 'Google Meet',
  teams: 'Microsoft Teams',
};

const RSVP_OPTIONS = [
  { status: 'accepted', label: 'Accept', cls: 'rsvpAccept' },
  { status: 'tentative', label: 'Maybe', cls: 'rsvpMaybe' },
  { status: 'declined', label: 'Decline', cls: 'rsvpDecline' },
];

// Normalize a provider RSVP value to our canonical status. Google/Microsoft
// camelCase ("needsAction") and the API snake_case ("needs_action") both reduce
// to one of accepted | declined | tentative | needs_action.
function normalizeRsvp(raw) {
  if (!raw) return null;
  const s = String(raw).replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase();
  return s === 'needs_action' ? null : s;
}

export default function EventEditor({ event, defaults, orgSlug, calendars = [], onSave, onClose, readOnly = false, onEdit, onDelete, isInvite = false, myRsvp = null, onRsvp }) {
  const isNew = !event;
  const initial = event || defaults || {};

  const [title, setTitle] = useState(initial.title || '');
  // The invite-email preview, toggled like the composer's (read-only views are
  // nothing but the invite card, so they always show it).
  const [showPreview, setShowPreview] = useState(() => {
    try { return localStorage.getItem(EVENT_PREVIEW) === 'true'; } catch { return false; }
  });
  const previewShown = readOnly || showPreview;
  const [description, setDescription] = useState(initial.description || '');
  const [location, setLocation] = useState(initial.location || '');
  const [startAt, setStartAt] = useState(formatDateTimeLocal(initial.start_at, initial.all_day));
  const [endAt, setEndAt] = useState(formatDateTimeLocal(initial.end_at, initial.all_day));
  const [allDay, setAllDay] = useState(initial.all_day || false);
  const [attendees, setAttendees] = useState(initial.attendees || []);
  const [calendarId, setCalendarId] = useState(initial.calendar_id || calendars[0]?.id || '');
  const [conference, setConference] = useState('');
  // An edit opens on the series' own rule (an exception row carries the
  // master's as `series_rule`).
  const [initialRepeat] = useState(() => (isNew ? NO_REPEAT : parseRRule(initial.series_rule || initial.recurrence_rule, formatDateTimeLocal(initial.start_at, initial.all_day))));
  const [repeat, setRepeat] = useState(initialRepeat);
  const repeatTouched = JSON.stringify(repeat) !== JSON.stringify(initialRepeat);
  const recurring = !isNew && !!initial.is_recurring;
  // Saving an edited series asks which part first: { payload, saving, error }.
  const [pendingSave, setPendingSave] = useState(null);
  const patchRepeat = (changes) => setRepeat(r => ({ ...r, ...changes }));
  const [attendeeQuery, setAttendeeQuery] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [myResponse, setMyResponse] = useState(normalizeRsvp(myRsvp));
  const [showScheduler, setShowScheduler] = useState(false);
  const [rsvpSaving, setRsvpSaving] = useState(false);

  // Closing an edited form asks first (Escape, ✕ and Discard alike). Dirty =
  // the form differs from how it opened; switching the view to Edit keeps the
  // same snapshot, since the fields were filled from the event all along.
  const form = JSON.stringify([title, description, location, startAt, endAt, allDay, attendees, calendarId, conference, repeat]);
  const [pristine] = useState(form);
  const dirty = !readOnly && form !== pristine;
  const [confirmClose, setConfirmClose] = useState(false);
  const requestClose = useCallback(() => (dirty ? setConfirmClose(true) : onClose()), [dirty, onClose]);

  // Delete, from the view. An invite asks whether to decline to the organizer
  // first (Google Calendar's "Send / Don't send"): removing it alone tells
  // nobody. Your own event gets a plain confirmation.
  const [askDecline, setAskDecline] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState(null);
  const runDelete = async (opts) => {
    setAskDecline(false);
    setConfirmDelete(false);
    setDeleteError(null);
    setDeleting(true);
    try {
      await onDelete(opts);
    } catch (e) {
      // A Tauri command rejects with a plain string, not an Error.
      setDeleteError((typeof e === 'string' ? e : e?.message) || "Couldn't delete the event.");
    } finally {
      setDeleting(false);
    }
  };

  useEffect(() => {
    const onKey = (e) => {
      // A field that used Escape itself (an open suggestion list) wins.
      if (e.key !== 'Escape' || e.defaultPrevented) return;
      e.preventDefault();
      e.stopPropagation();
      if (pendingSave) { if (!pendingSave.saving) setPendingSave(null); }
      else if (showScheduler) setShowScheduler(false);
      else if (askDecline) setAskDecline(false);
      else requestClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [requestClose, showScheduler, askDecline, pendingSave]);

  // RSVP chips are interactive only in the read-only invite view (a received
  // invite). In compose mode they stay a static mockup of the email being sent.
  const rsvpInteractive = readOnly && !!onRsvp;

  const handleRsvp = useCallback(async (status) => {
    if (!onRsvp) return;
    const prev = myResponse;
    setMyResponse(status); // optimistic highlight; resync reconciles
    setRsvpSaving(true);
    try {
      await onRsvp(status);
    } catch {
      setMyResponse(prev); // revert on failure
    } finally {
      setRsvpSaving(false);
    }
  }, [onRsvp, myResponse]);

  // Which calendar the event lands on decides who can mint a meeting link for
  // it, so the video-call choice follows the picker.
  const selectedCalendar = useMemo(
    () => calendars.find(c => c.id === calendarId) || calendars[0] || null,
    [calendars, calendarId],
  );
  const conferenceOptions = selectedCalendar?.conferenceOptions || [];
  const conferenceChoice = conferenceOptions.includes(conference) ? conference : '';

  const { contacts } = useContactSuggestions(orgSlug);

  const attendeeSuggestions = useMemo(() => {
    const q = attendeeQuery.trim().toLowerCase();
    if (!q || q.length < 1) return [];
    const addedEmails = new Set(attendees.map(a => a.email));
    return contacts
      .filter(c => !addedEmails.has(c.email))
      .filter(c =>
        c.email.toLowerCase().includes(q) ||
        (c.name && c.name.toLowerCase().includes(q))
      )
      .slice(0, 8);
  }, [attendeeQuery, contacts, attendees]);

  // Addresses the scheduling assistant should draw a row for.
  const attendeeEmails = useMemo(
    () => attendees.map(a => a.email).filter(Boolean),
    [attendees],
  );

  // The assistant hands back a concrete slot; both time fields move together so
  // the meeting keeps its length.
  // A date-only value ("2026-09-21", what the all-day input hands back) parses
  // as UTC midnight, which is the day before anywhere west of Greenwich — read
  // it as a local wall clock instead.
  const localDate = (v) => new Date(v.length === 10 ? `${v}T00:00` : v);

  // Moving the start drags the end along, keeping the meeting the length it
  // already was — Google/Outlook behaviour. Only a shorter-than-nothing end
  // gets corrected on its own (the input's `min` stops most of those).
  const handleStartChange = useCallback((value) => {
    if (!value) { setStartAt(value); return; }
    const gap = startAt && endAt ? localDate(endAt) - localDate(startAt) : 0;
    setStartAt(value);
    if (gap > 0) {
      const nextEnd = new Date(localDate(value).getTime() + gap);
      setEndAt(format(nextEnd, allDay ? "yyyy-MM-dd'T'00:00" : "yyyy-MM-dd'T'HH:mm"));
    }
  }, [startAt, endAt, allDay]);

  const handleEndChange = useCallback((value) => {
    // The picker's own `min` covers typing; a pasted/typed earlier end lands
    // back on the start rather than saving a negative meeting.
    if (value && startAt && localDate(value) < localDate(startAt)) { setEndAt(startAt); return; }
    setEndAt(value);
  }, [startAt]);

  const handlePickSlot = useCallback((newStart, newEnd) => {
    setStartAt(format(newStart, "yyyy-MM-dd'T'HH:mm"));
    setEndAt(format(newEnd, "yyyy-MM-dd'T'HH:mm"));
  }, []);

  const buildPayload = () => ({
    title: title.trim() || '(Unnamed event)',
    description: description.trim() || null,
    location: location.trim() || null,
    // An all-day event is a pair of calendar dates, so it must not go
    // through a UTC instant: 00:30 local east of Greenwich converts to
    // 22:30Z the day before, and the event lands a day early (the ICS
    // writes `VALUE=DATE` off the UTC clock).
    start_at: allDay ? startAt.slice(0, 10) : new Date(startAt).toISOString(),
    end_at: allDay ? endAt.slice(0, 10) : new Date(endAt).toISOString(),
    all_day: allDay,
    attendees: attendees.length > 0 ? attendees : undefined,
    // selectedCalendar, not calendarId: with calendars still loading when
    // the editor opened, calendarId is '' while the picker already shows
    // (and this saves to) the first calendar in the list.
    calendar_id: selectedCalendar?.id || undefined,
    conference: conferenceChoice || undefined,
    // A new event's rule, or an edit's changed one (null = stop repeating).
    // Left out when untouched, so a title edit can't rewrite the series' rule.
    ...(isNew || repeatTouched ? { recurrence_rule: buildRRule(repeat, startAt, allDay) || (isNew ? undefined : null) } : {}),
    // The zone a repeat expands in, so a weekly 14:00 stays 14:00 across DST.
    // New events only: re-homing an existing one would re-expand its series.
    timezone: isNew ? Intl.DateTimeFormat().resolvedOptions().timeZone : undefined,
  });

  const save = async (payload) => {
    setSaving(true);
    setError(null);
    try {
      await onSave(payload);
      return null;
    } catch (e) {
      // A Tauri command rejects with a plain string (SyncError serializes as
      // one), so `e.message` is undefined and the provider's reason — the only
      // thing that explains a refused save — would be dropped on the floor.
      const msg = (typeof e === 'string' ? e : e?.message) || 'Couldn’t save the event. Try again.';
      setError(msg);
      return msg;
    } finally {
      setSaving(false);
    }
  };

  const handleSave = () => {
    const payload = buildPayload();
    if (recurring) setPendingSave({ payload });
    else save(payload);
  };

  const confirmSeriesSave = async ({ scope, notify }) => {
    setPendingSave(p => ({ ...p, saving: true, error: null }));
    const failed = await save({ ...pendingSave.payload, scope, notify });
    setPendingSave(p => (failed ? { ...p, saving: false, error: failed } : null));
  };

  // Format for preview
  const startDate = startAt ? new Date(startAt) : null;
  const endDate = endAt ? new Date(endAt) : null;
  const dateFmt = { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' };
  const timeFmt = { hour: 'numeric', minute: '2-digit' };
  let previewTime = '';
  if (startDate && endDate) {
    const dateStr = startDate.toLocaleDateString(undefined, dateFmt);
    if (allDay) {
      const endCheck = new Date(endDate); endCheck.setDate(endCheck.getDate() - 1);
      previewTime = startDate.toDateString() === endCheck.toDateString()
        ? dateStr
        : `${startDate.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })} – ${endCheck.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })}`;
    } else {
      previewTime = `${dateStr}\n${startDate.toLocaleTimeString(undefined, timeFmt)} – ${endDate.toLocaleTimeString(undefined, timeFmt)}`;
    }
  }
  const eventTitle = title.trim() || '(Unnamed event)';
  const repeatText = describeRepeat(repeat, startAt);
  const repeatUnit = REPEAT_FREQS.find(f => f.key === repeat.freq)?.unit;

  return (
    <div className={`${styles.popup} ${readOnly ? styles.popupReadOnly : ''} ${previewShown ? '' : styles.popupNoPreview}`}>
      {/* ── Header bar ──────────────────────────── */}
      <div className={styles.header}>
        <span className={styles.headerTitle}>{readOnly ? 'Event details' : isNew ? 'New event' : 'Edit event'}</span>
        <button type="button" className={styles.headerClose} onClick={requestClose}>
          <Icon name="xmark" size={12} />
        </button>
      </div>

      {/* ── Split body: form left, preview right.
          Read-only invites hide the form and show just the invite card. ── */}
      <div className={`${styles.body} ${readOnly ? styles.bodyReadOnly : ''}`}>
        {/* Left — form fields (hidden for read-only invites) */}
        {!readOnly && (
        <div className={styles.formPane}>
          {/* Which calendar (and so which account) the event is created on.
              Only on create — moving an existing event between accounts would
              mean deleting and re-inviting, which this editor doesn't do. */}
          {isNew && calendars.length > 0 && (
            <div className={`${styles.fieldRow} ${styles.fieldRowMiddle}`}>
              <Icon name="tray.full" size={16} className={styles.fieldIcon} />
              {/* The compose header's From picker: same job — which account is
                  this going out as — so the same channel icon and the same look. */}
              <div className={styles.fieldPicker}>
                <FromSelect
                  value={selectedCalendar?.id || ''}
                  identities={calendars}
                  onChange={setCalendarId}
                />
              </div>
            </div>
          )}

          <div className={styles.fieldRow}>
            <Icon name="calendar" size={16} className={styles.fieldIcon} />
            <input
              className={styles.fieldInput}
              type="text"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="New event"
              autoFocus
            />
          </div>

          <div className={styles.fieldRow}>
            <Icon name="person.2" size={16} className={styles.fieldIcon} />
            <TagInput
              values={attendees}
              onChange={setAttendees}
              placeholder="Invite people"
              suggestions={attendeeSuggestions}
              onQueryChange={setAttendeeQuery}
            />
          </div>

          <div className={styles.fieldRow}>
            <Icon name="clock" size={16} className={styles.fieldIcon} />
            <div className={styles.timeBlock}>
              <div className={styles.allDayRow}>
                <Checkbox checked={allDay} onChange={(e) => setAllDay(e.target.checked)}>
                  All day
                </Checkbox>
                <div className={styles.allDayActions}>
                  {/* Repeat sits on this line, in view: on its own row below
                      the times it read as part of the form's fold. On an
                      existing series, Save asks which part (this / following
                      / all) the change is for. */}
                  <span className={styles.repeatPick}>
                    <Icon name="arrow.triangle.2.circlepath" size={13} className={styles.repeatIcon} />
                    <MgmtSelect
                      bare
                      compact
                      className={styles.repeatLinkSelect}
                      aria-label="Repeat"
                      value={repeat.freq}
                      onChange={(e) => (e.target.value === 'custom' ? setRepeat(initialRepeat) : patchRepeat({ freq: e.target.value }))}
                    >
                      {REPEAT_FREQS.map(f => <option key={f.key} value={f.key}>{f.label}</option>)}
                      {/* A rule the editor can't draw (2nd Tuesday, …) stays as it is. */}
                      {initialRepeat.freq === 'custom' && <option value="custom">Custom (as set elsewhere)</option>}
                    </MgmtSelect>
                  </span>
                  {/* All-day events have no slot to negotiate, so the assistant
                      only offers itself for timed meetings. */}
                  {!allDay && (
                    <button
                      type="button"
                      className={styles.findTimeLink}
                      onClick={() => setShowScheduler(v => !v)}
                      aria-expanded={showScheduler}
                    >
                      {showScheduler ? 'Hide availability' : 'Find a time'}
                    </button>
                  )}
                </div>
              </div>
              <div className={styles.timeRow}>
                <DateField
                  className={styles.timeInput}
                  time={!allDay}
                  aria-label="Starts"
                  value={allDay ? startAt.split('T')[0] : startAt}
                  onChange={handleStartChange}
                />
                <span className={styles.timeSep}>to</span>
                <DateField
                  className={styles.timeInput}
                  time={!allDay}
                  aria-label="Ends"
                  value={allDay ? endAt.split('T')[0] : endAt}
                  min={allDay ? startAt.split('T')[0] : startAt}
                  onChange={handleEndChange}
                />
              </div>
              {repeat.freq !== 'none' && repeat.freq !== 'custom' && (
                <>
                  {/* Every N · Ends — one line. */}
                  <div className={styles.repeatRow}>
                    <span className={styles.repeatLabel}>Every</span>
                    <input
                      className={`${styles.timeInput} ${styles.repeatNumber}`}
                      type="number"
                      min={1}
                      aria-label="Repeat interval"
                      value={repeat.interval}
                      onChange={(e) => patchRepeat({ interval: e.target.value })}
                    />
                    <span className={styles.repeatLabel}>{repeatUnit}{Number(repeat.interval) > 1 ? 's' : ''}</span>
                    <span className={styles.repeatSep}>·</span>
                    <span className={styles.repeatLabel}>Ends</span>
                    <MgmtSelect
                      bare
                      compact
                      className={styles.repeatSelect}
                      aria-label="Repeat ends"
                      value={repeat.ends}
                      // "On date" opens on the start's day, never on nothing.
                      onChange={(e) => patchRepeat({ ends: e.target.value, ...(e.target.value === 'on' && !(repeat.until >= startAt.slice(0, 10)) ? { until: startAt.slice(0, 10) } : {}) })}
                    >
                      <option value="never">Never</option>
                      <option value="on">On date</option>
                      <option value="after">After</option>
                    </MgmtSelect>
                    {repeat.ends === 'on' && (
                      <DateField
                        className={`${styles.timeInput} ${styles.repeatUntil}`}
                        aria-label="Repeat until"
                        value={repeat.until}
                        min={startAt.slice(0, 10)}
                        onChange={(v) => patchRepeat({ until: v })}
                      />
                    )}
                    {repeat.ends === 'after' && (
                      <>
                        <input
                          className={`${styles.timeInput} ${styles.repeatNumber}`}
                          type="number"
                          min={1}
                          aria-label="Number of times"
                          value={repeat.count}
                          onChange={(e) => patchRepeat({ count: e.target.value })}
                        />
                        <span className={styles.repeatLabel}>times</span>
                      </>
                    )}
                  </div>
                  {repeat.freq === 'WEEKLY' && (
                    <div className={styles.repeatDays} role="group" aria-label="Repeat on">
                      {WEEKDAYS.map(d => {
                        const on = repeatDays(repeat, startAt).includes(d.code);
                        return (
                          <button
                            key={d.code}
                            type="button"
                            className={`${styles.repeatDay} ${on ? styles.repeatDayOn : ''}`}
                            aria-pressed={on}
                            aria-label={d.name}
                            onClick={() => {
                              const cur = repeatDays(repeat, startAt);
                              const next = on ? cur.filter(c => c !== d.code) : [...cur, d.code];
                              // Unticking the last day leaves the start's own weekday.
                              patchRepeat({ days: next });
                            }}
                          >{d.short}</button>
                        );
                      })}
                    </div>
                  )}
                </>
              )}
            </div>
          </div>

          {showScheduler && !allDay && (
            <SchedulingAssistant
              orgSlug={orgSlug}
              emails={attendeeEmails}
              startAt={startAt}
              endAt={endAt}
              onPick={handlePickSlot}
              onClose={() => setShowScheduler(false)}
            />
          )}

          {/* The provider mints the link when the event is created — Meet on a
              Google calendar, Teams on a Microsoft one — and it comes back on
              the event, so there is nothing to paste into Location. */}
          {isNew && conferenceOptions.length > 0 && (
            <div className={`${styles.fieldRow} ${styles.fieldRowMiddle}`}>
              {/* The provider's own logo when we know which one it is — a
                  generic camera only while the choice is still open. */}
              {conferenceChoice || conferenceOptions.length === 1 ? (
                <span className={styles.fieldBrandIcon}>
                  <MeetingProviderIcon provider={conferenceChoice || conferenceOptions[0]} size={16} />
                </span>
              ) : (
                <Icon name="video" size={16} className={styles.fieldIcon} />
              )}
              {/* One provider (every local calendar, and the usual inbox2 one)
                  is a yes/no, so it's a switch. A member with both Google and
                  Microsoft conferencing connected has an actual choice to make
                  and gets the picker instead. */}
              {conferenceOptions.length === 1 ? (
                <div className={styles.fieldSwitch}>
                  <Switch
                    id="event-conference"
                    label={`Add ${CONFERENCE_LABELS[conferenceOptions[0]] || conferenceOptions[0]}`}
                    checked={!!conferenceChoice}
                    onChange={(on) => setConference(on ? conferenceOptions[0] : '')}
                  />
                </div>
              ) : (
                <MgmtSelect
                  bare
                  compact
                  className={styles.fieldSelect}
                  aria-label="Video call"
                  value={conferenceChoice}
                  onChange={(e) => setConference(e.target.value)}
                >
                  <option value="">No video call</option>
                  {conferenceOptions.map(o => (
                    <option key={o} value={o}>Add {CONFERENCE_LABELS[o] || o}</option>
                  ))}
                </MgmtSelect>
              )}
            </div>
          )}

          <div className={styles.fieldRow}>
            <Icon name="location" size={16} className={styles.fieldIcon} />
            <input
              className={styles.fieldInput}
              type="text"
              value={location}
              onChange={(e) => setLocation(e.target.value)}
              placeholder="Location"
            />
          </div>

          <div className={styles.fieldRow}>
            <Icon name="doc.text" size={16} className={styles.fieldIcon} />
            <textarea
              className={styles.fieldTextarea}
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Notes"
              rows={3}
            />
          </div>

          {error && <div className={styles.error}>{error}</div>}
        </div>
        )}

        {/* Right — branded invite email preview (the read-only invite view) */}
        {previewShown && (
        <div className={styles.previewPane}>
          <div className={styles.previewLabel}>{readOnly ? (onRsvp ? 'Invitation' : 'Event') : 'Invite email preview'}</div>

          <div className={styles.emailFrame}>
            {/* Email header */}
            <div className={styles.emailHeader}>
              <img src="/logo-mark.png" alt="inbox2" className={styles.emailLogoImg} />
              <div className={styles.emailSubject}>Invitation: {eventTitle}</div>
            </div>

            {/* Gradient stripe */}
            <div className={styles.emailStripe} />

            {/* Email body */}
            <div className={styles.emailBody}>
              <div className={styles.emailGreeting}>
                You have been invited to an event.
              </div>

              {/* Event card */}
              <div className={styles.eventCard}>
                <div className={styles.eventCardTitle}>{eventTitle}</div>

                <div className={styles.eventCardRow}>
                  <span className={styles.eventCardLabel}>When</span>
                  <span>{allDay && 'All day · '}{previewTime?.split('\n').map((line, i) => (
                    <span key={i}>{i > 0 && ' · '}{line}</span>
                  ))}</span>
                </div>

                {repeatText && (
                  <div className={styles.eventCardRow}>
                    <span className={styles.eventCardLabel}>Repeats</span>
                    <span>{repeatText}</span>
                  </div>
                )}

                {conferenceChoice && (
                  <div className={styles.eventCardRow}>
                    <span className={styles.eventCardLabel}>Video</span>
                    <span className={styles.eventCardVideo}>
                      <MeetingProviderIcon provider={conferenceChoice} size={13} />
                      {CONFERENCE_LABELS[conferenceChoice]} link
                    </span>
                  </div>
                )}

                {location && (
                  <div className={styles.eventCardRow}>
                    <span className={styles.eventCardLabel}>Where</span>
                    <span><Linkify text={location} className={styles.cardLink} /></span>
                  </div>
                )}

                {description && (
                  <div className={styles.eventCardRow}>
                    <span className={styles.eventCardLabel}>Notes</span>
                    <span className={styles.eventCardDesc}><Linkify text={description} className={styles.cardLink} /></span>
                  </div>
                )}

                {attendees.length > 0 && (
                  <div className={styles.eventCardRow}>
                    <span className={styles.eventCardLabel}>Who</span>
                    <span>{attendees.map(a => a.name || a.email).join(', ')}</span>
                  </div>
                )}
              </div>

              {/* RSVP buttons */}
              <div className={styles.rsvpSection}>
                <div className={styles.rsvpPrompt}>Will you attend?</div>
                <div className={styles.rsvpButtons}>
                  {RSVP_OPTIONS.map(opt => {
                    const cls = `${styles.rsvpBtn} ${styles[opt.cls]}`
                      + `${myResponse === opt.status ? ` ${styles.rsvpActive}` : ''}`
                      + `${rsvpInteractive ? ` ${styles.rsvpInteractive}` : ''}`;
                    return rsvpInteractive ? (
                      <button key={opt.status} type="button" className={cls}
                        disabled={rsvpSaving} onClick={() => handleRsvp(opt.status)}>
                        {opt.label}
                      </button>
                    ) : (
                      <span key={opt.status} className={cls}>{opt.label}</span>
                    );
                  })}
                </div>
              </div>
            </div>

            {/* Email footer */}
            <div className={styles.emailFooter}>
              <img src="/logo-mark.png" alt="inbox2" className={styles.emailFooterImg} />
              <div className={styles.emailFooterText}>
                This invitation was sent via inbox2.
                {attendees.length > 0 && ` An .ics calendar file is attached.`}
              </div>
            </div>
          </div>
        </div>
        )}
      </div>

      {/* ── Footer ──────────────────────────────── */}
      <div className={styles.footer}>
        {readOnly && askDecline ? (
          <>
            <span className={styles.footerNote}>
              Let {initial.organizer_name || initial.organizer_email} know you won&apos;t attend?
            </span>
            <ToolbarButton onClick={() => setAskDecline(false)}>Cancel</ToolbarButton>
            <ToolbarButton icon="trash" onClick={() => runDelete()}>Delete only</ToolbarButton>
            <ToolbarButton icon="xmark.circle" variant="compose" onClick={() => runDelete({ decline: true })}>
              Decline &amp; delete
            </ToolbarButton>
          </>
        ) : readOnly ? (
          <>
            {onDelete && (
              <ToolbarButton icon="trash" color="rose" disabled={deleting}
                onClick={() => (isInvite ? setAskDecline(true) : setConfirmDelete(true))}>
                {deleting ? 'Deleting…' : 'Delete'}
              </ToolbarButton>
            )}
            {deleteError && <span className={styles.footerError} role="alert">{deleteError}</span>}
            <span className={styles.footerSpacer} />
            <ToolbarButton icon="xmark" variant={onEdit ? undefined : 'compose'} onClick={requestClose}>
              Close
            </ToolbarButton>
            {/* The view of an event that's yours to change: same window, now the form. */}
            {onEdit && (
              <ToolbarButton icon="pencil" variant="compose" onClick={onEdit}>
                Edit
              </ToolbarButton>
            )}
          </>
        ) : (
          <>
            <Checkbox
              className={styles.previewToggle}
              checked={showPreview}
              onChange={(e) => {
                setShowPreview(e.target.checked);
                try { localStorage.setItem(EVENT_PREVIEW, String(e.target.checked)); } catch { /* private mode */ }
              }}
            >Preview</Checkbox>
            <span className={styles.footerSpacer} />
            <ToolbarButton icon="xmark" onClick={requestClose}>
              Discard
            </ToolbarButton>
            <ToolbarButton
              icon={isNew ? 'plus.circle' : 'checkmark.circle'}
              variant="compose"
              onClick={handleSave}
              disabled={saving}
            >
              {saving ? 'Saving...' : 'Save'}
            </ToolbarButton>
          </>
        )}
      </div>
      {pendingSave && (
        <MoveEventDialog
          open
          editing
          recurring
          allAllowed
          channel={{ type: PROVIDER.INBOX2 }}
          title={title.trim() || '(Unnamed event)'}
          when={previewTime.replace('\n', ' · ')}
          // A new rule can't belong to one instance — it's a series change.
          scopes={repeatTouched ? ['following', 'all'] : ['this', 'following', 'all']}
          hasGuests={attendees.length > 0}
          canSkipMail
          saving={pendingSave.saving}
          error={pendingSave.error}
          onConfirm={confirmSeriesSave}
          onCancel={() => setPendingSave(null)}
        />
      )}
      <ConfirmDialog
        open={confirmDelete}
        title="Delete this event?"
        message={`"${initial.title || '(Unnamed event)'}" will be removed from your calendar.`}
        confirmLabel="Delete"
        onConfirm={() => runDelete()}
        onCancel={() => setConfirmDelete(false)}
      />
      <ConfirmDialog
        open={confirmClose}
        title="Discard changes?"
        message={isNew ? "This event hasn't been saved." : "Your changes to this event haven't been saved."}
        confirmLabel="Discard"
        cancelLabel="Keep editing"
        onConfirm={() => { setConfirmClose(false); onClose(); }}
        onCancel={() => setConfirmClose(false)}
      />
    </div>
  );
}

function formatDateTimeLocal(dateStr, allDay = false) {
  if (!dateStr) return '';
  // An all-day event is a calendar date, never an instant. `new Date('2026-09-18')`
  // is UTC midnight, which is the 17th anywhere west of Greenwich — so reading one
  // through a local Date walks it back a day on every open. Take the date as written.
  if (allDay || /^\d{4}-\d{2}-\d{2}$/.test(dateStr)) return `${String(dateStr).slice(0, 10)}T00:00`;
  try {
    const d = new Date(dateStr);
    return format(d, "yyyy-MM-dd'T'HH:mm");
  } catch {
    return '';
  }
}
