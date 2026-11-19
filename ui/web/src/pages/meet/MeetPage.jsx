import { useState, useEffect, useMemo, useRef, useCallback } from 'react';
import { useParams } from 'react-router';
import api from '../../lib/api';
import { ManagementLayout, MgmtButton } from '../../components/management';
import styles from './MeetPage.module.css';

// Public meet-link scheduler (docs/Calendar.md): /meet/:token, no auth — the
// token IS the capability. Shows the invitee's busy/free week (never event
// details), in the visitor's time zone with up to three zones side by side on
// the axis, and turns a slot click into a meeting REQUEST — the page is
// explicit that nothing is booked until the invitee accepts.
const TURNSTILE_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
const DAY_START_MIN = 7 * 60;   // grid window 07:00–21:00 in the primary zone
const DAY_END_MIN = 21 * 60;
const SLOT_MIN = 30;
const MAX_ZONES = 3;
const LOCAL_TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
const ALL_ZONES = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : [];

const WDAY = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
const cityOf = (tz) => (tz || '').split('/').pop().replace(/_/g, ' ');

function shortOffset(tz) {
  try {
    const parts = new Intl.DateTimeFormat('en-US', { timeZone: tz, timeZoneName: 'shortOffset' }).formatToParts(new Date());
    return parts.find((p) => p.type === 'timeZoneName')?.value || '';
  } catch { return ''; }
}

// {year, month, day, hour, minute, weekday} of an absolute time in a zone.
function tzParts(date, tz) {
  const dtf = new Intl.DateTimeFormat('en-GB', {
    timeZone: tz, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', weekday: 'short',
  });
  const parts = {};
  for (const p of dtf.formatToParts(date)) parts[p.type] = p.value;
  parts.hour = parts.hour === '24' ? '00' : parts.hour;
  return parts;
}

// Wall clock in `tz` → absolute Date. Standard two-pass offset correction so
// DST transitions resolve; no tz library needed.
function zonedTimeToUtc(y, m, d, hh, mm, tz) {
  let ts = Date.UTC(y, m - 1, d, hh, mm);
  for (let i = 0; i < 2; i += 1) {
    const p = tzParts(new Date(ts), tz);
    const asUtc = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute);
    ts += Date.UTC(y, m - 1, d, hh, mm) - asUtc;
  }
  return new Date(ts);
}

// Mirrors the server's working-hours check (MeetAvailability): evaluated in
// the invitee's zone, slot must start and finish inside one working day.
function withinWorkingHours(startAbs, endAbs, wh) {
  if (!wh) return true;
  const s = tzParts(startAbs, wh.timezone);
  if (!wh.days.includes(WDAY[s.weekday])) return false;
  const startMin = +s.hour * 60 + +s.minute;
  if (startMin < wh.start_minute) return false;
  const e = tzParts(endAbs, wh.timezone);
  return s.day === e.day && (+e.hour * 60 + +e.minute) <= wh.end_minute;
}

// The 7 calendar dates of the week `offset` weeks after the current one (Mon-first).
function weekDays(tz, offset) {
  const today = tzParts(new Date(), tz);
  const base = Date.UTC(+today.year, +today.month - 1, +today.day, 12);
  const monday = base - ((WDAY[today.weekday] + 6) % 7) * 86400000 + offset * 7 * 86400000;
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(monday + i * 86400000);
    return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() };
  });
}

// A calendar date as "Mon, Sep 21" — the date is zone-free, so format it in UTC.
function dayLabel({ y, m, d }) {
  return new Date(Date.UTC(y, m - 1, d, 12)).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });
}

function timeIn(date, tz) {
  return date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: tz });
}

function dateIn(date, tz) {
  return date.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short', timeZone: tz });
}

export default function MeetPage() {
  const { token } = useParams();
  const [meet, setMeet] = useState(null);
  const [gone, setGone] = useState(false);
  const [zones, setZones] = useState([LOCAL_TZ]);
  const [addingZone, setAddingZone] = useState(false);
  const [weekOffset, setWeekOffset] = useState(0);
  // Availability cache per (week, refetch nonce): { periods, fetchedAt }.
  // Keyed writes keep the effect idempotent (no synchronous resets).
  const [busyByWeek, setBusyByWeek] = useState({});
  const [selected, setSelected] = useState(null); // absolute Date of slot start
  const [hover, setHover] = useState(null); // start of the meeting under the pointer
  const [availabilityNonce, setAvailabilityNonce] = useState(0);

  // Request form
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [note, setNote] = useState('');
  const [turnstileToken, setTurnstileToken] = useState('');
  const turnstileRef = useRef(null);
  const turnstileWidgetRef = useRef(null);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState(null);
  const [sent, setSent] = useState(null); // the requested slot, after success

  const primaryZone = zones[0];
  const duration = meet?.duration_minutes || 30;

  useEffect(() => {
    let alive = true;
    api.getMeet(token)
      .then((res) => { if (alive) setMeet(res?.meet || null); })
      .catch(() => { if (alive) setGone(true); });
    return () => { alive = false; };
  }, [token]);

  // The visible week: Monday of the visitor's current week (in the primary
  // zone) plus the offset. Days are pure calendar dates; each cell converts
  // its own wall time to an absolute instant, so DST days stay correct.
  const days = useMemo(() => weekDays(primaryZone, weekOffset), [primaryZone, weekOffset]);

  // Week picker: every week the booking window reaches into.
  const weekOptions = useMemo(() => {
    const today = tzParts(new Date(), primaryZone);
    const count = Math.max(1, Math.ceil(((WDAY[today.weekday] + 6) % 7 + (meet?.max_ahead_days || 28) + 1) / 7));
    return Array.from({ length: count }, (_, i) => {
      const w = weekDays(primaryZone, i);
      return { value: i, label: `${dayLabel(w[0])} – ${dayLabel(w[6])}` };
    });
  }, [primaryZone, meet]);

  const slotAbs = useCallback(
    (day, row) => {
      const minutes = DAY_START_MIN + row * SLOT_MIN;
      return zonedTimeToUtc(day.y, day.m, day.d, Math.floor(minutes / 60), minutes % 60, primaryZone);
    },
    [primaryZone]
  );

  const rows = (DAY_END_MIN - DAY_START_MIN) / SLOT_MIN;
  const weekStart = useMemo(() => slotAbs(days[0], 0), [days, slotAbs]);
  const weekEnd = useMemo(
    () => new Date(slotAbs(days[6], rows - 1).getTime() + SLOT_MIN * 60000),
    [days, rows, slotAbs]
  );

  const weekKey = `${weekStart.toISOString()}:${availabilityNonce}`;
  useEffect(() => {
    if (!meet || busyByWeek[weekKey]) return undefined;
    let alive = true;
    api.getMeetAvailability(token, weekStart.toISOString(), weekEnd.toISOString())
      .then((res) => {
        if (!alive) return;
        setBusyByWeek((prev) => ({
          ...prev,
          [weekKey]: {
            periods: (res?.busy || []).map((b) => ({ start: new Date(b.start), end: new Date(b.end) })),
            fetchedAt: Date.now(),
          },
        }));
      })
      .catch(() => {
        if (alive) setBusyByWeek((prev) => ({ ...prev, [weekKey]: { periods: [], fetchedAt: Date.now() } }));
      });
    return () => { alive = false; };
  }, [meet, token, weekKey, weekStart, weekEnd, busyByWeek]);

  const entry = busyByWeek[weekKey];
  const busy = entry?.periods || null;

  const isBusy = useCallback(
    (from, to) => (busy || []).some((b) => b.start < to && b.end > from),
    [busy]
  );

  // Booking window, anchored on the fetch instant (kept out of render so the
  // component stays pure). Server-side validation is the real gate anyway.
  const notBefore = entry && meet ? new Date(entry.fetchedAt + (meet.min_notice_minutes || 0) * 60000) : null;
  const notAfter = entry && meet ? new Date(entry.fetchedAt + (meet.max_ahead_days || 28) * 86400000) : null;

  // A slot the visitor can actually request: whole duration free, inside the
  // invitee's working day, inside the link's notice/lookahead window.
  // `minutes` defaults to the meeting length (can a meeting START here?); the
  // grid also asks about a single 30-minute cell (is THIS half hour free?), so
  // colour follows the calendar and only clickability follows the duration.
  const slotState = useCallback(
    (start, minutes = duration) => {
      const end = new Date(start.getTime() + minutes * 60000);
      if (!withinWorkingHours(start, end, meet?.working_hours)) return 'outside';
      if (!notBefore) return 'loading';
      if (isBusy(start, end)) return 'busy';
      if (start < notBefore || start > notAfter) return 'closed';
      return 'free';
    },
    [duration, meet, isBusy, notBefore, notAfter]
  );

  // Turnstile renders once a slot is picked.
  useEffect(() => {
    const siteKey = meet?.turnstile_site_key;
    if (!siteKey || !selected || sent) return undefined;
    let widgetId;
    const render = () => {
      if (!window.turnstile || !turnstileRef.current) return;
      widgetId = window.turnstile.render(turnstileRef.current, {
        sitekey: siteKey,
        theme: 'light',
        callback: (t) => setTurnstileToken(t),
        'expired-callback': () => setTurnstileToken(''),
        'error-callback': () => setTurnstileToken(''),
      });
    };
    if (window.turnstile) {
      render();
    } else if (!document.querySelector(`script[src="${TURNSTILE_SRC}"]`)) {
      const script = document.createElement('script');
      script.src = TURNSTILE_SRC;
      script.async = true;
      script.defer = true;
      script.onload = render;
      document.head.appendChild(script);
    } else {
      document.querySelector(`script[src="${TURNSTILE_SRC}"]`).addEventListener('load', render);
    }
    const track = () => { turnstileWidgetRef.current = widgetId; };
    track();
    return () => { if (widgetId && window.turnstile) window.turnstile.remove(widgetId); turnstileWidgetRef.current = null; };
  }, [meet, selected, sent]);

  const submit = async (e) => {
    e.preventDefault();
    if (meet?.turnstile_site_key && !turnstileToken) {
      setSubmitError('Complete the check first.');
      return;
    }
    setSubmitting(true);
    setSubmitError(null);
    try {
      await api.createMeetRequest(token, {
        name: name.trim(),
        email: email.trim(),
        note: note.trim() || undefined,
        start_at: selected.toISOString(),
        timezone: primaryZone,
        turnstile_token: turnstileToken || undefined,
      });
      setSent(selected);
      setSelected(null);
    } catch (err) {
      setSubmitError(err?.message || "Couldn't send your request. Try again.");
      // The slot may have just been taken — repaint the grid either way.
      setAvailabilityNonce((n) => n + 1);
      // Turnstile tokens are single-use and the server already consumed this
      // one — without a reset every retry fails verification.
      setTurnstileToken('');
      try { if (turnstileWidgetRef.current != null) window.turnstile?.reset(turnstileWidgetRef.current); } catch { /* widget gone */ }
    } finally {
      setSubmitting(false);
    }
  };

  const addZone = (tz) => {
    // Validity = the engine can format in it; the datalist is only a suggestion
    // source and ALL_ZONES is empty where supportedValuesOf is missing.
    try { new Intl.DateTimeFormat(undefined, { timeZone: tz }); } catch { return; }
    setZones((z) => (z.includes(tz) || z.length >= MAX_ZONES ? z : [...z, tz]));
    setAddingZone(false);
  };

  if (gone) {
    return (
      <ManagementLayout centered>
        <div className={styles.goneCard}>
          <h1>This link doesn’t work</h1>
          <p>Ask the person who shared it for a new one.</p>
        </div>
      </ManagementLayout>
    );
  }

  if (!meet) {
    return <ManagementLayout centered><div className={styles.goneCard}><p>Loading…</p></div></ManagementLayout>;
  }

  const inviteeName = meet.invitee?.name || 'the organizer';
  const firstName = inviteeName.split(' ')[0];
  const selEnd = selected ? new Date(selected.getTime() + duration * 60000) : null;
  const sentEnd = sent ? new Date(sent.getTime() + duration * 60000) : null;

  return (
    <ManagementLayout>
      <div className={styles.page}>
        <header className={styles.head}>
          {meet.invitee?.avatar_url
            ? <img className={styles.avatar} src={meet.invitee.avatar_url} alt="" />
            : <div className={styles.avatarFallback}>{inviteeName.slice(0, 1).toUpperCase()}</div>}
          <div>
            <h1 className={styles.title}>Meet with {inviteeName}</h1>
            <div className={styles.subtitle}>{meet.organization} · {duration}-minute meeting</div>
          </div>
        </header>
        <p className={styles.promise}>
          Pick a free time below to send a request. Once {firstName} accepts,
          you&rsquo;ll get a calendar invite by email.
        </p>

        <div className={styles.controls}>
          <div className={styles.weekNav}>
            <button type="button" onClick={() => setWeekOffset((w) => w - 1)} disabled={weekOffset <= 0} aria-label="Previous week">‹</button>
            <select
              className={styles.weekSelect}
              value={weekOffset}
              onChange={(e) => setWeekOffset(Number(e.target.value))}
              aria-label="Week"
            >
              {weekOptions.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
            <button
              type="button"
              onClick={() => setWeekOffset((w) => w + 1)}
              disabled={weekOffset >= weekOptions.length - 1}
              aria-label="Next week"
            >›</button>
          </div>
          {zones.map((tz, i) => (
            <span key={tz} className={styles.zoneChip}>
              {cityOf(tz)} <small>{shortOffset(tz)}{i === 0 && tz === LOCAL_TZ ? ' · yours' : ''}</small>
              {i > 0 && (
                <button type="button" aria-label={`Remove ${cityOf(tz)}`} onClick={() => setZones((z) => z.filter((x) => x !== tz))}>×</button>
              )}
            </span>
          ))}
          {zones.length < MAX_ZONES && (addingZone ? (
            <input
              className={styles.zoneInput}
              list="meet-zones"
              placeholder="Search a city…"
              autoFocus
              onChange={(e) => addZone(e.target.value)}
              onBlur={() => setAddingZone(false)}
              onKeyDown={(e) => { if (e.key === 'Escape') setAddingZone(false); }}
            />
          ) : (
            <button type="button" className={styles.zoneAdd} onClick={() => setAddingZone(true)}>+ Add time zone</button>
          ))}
          <datalist id="meet-zones">
            {ALL_ZONES.map((tz) => <option key={tz} value={tz}>{cityOf(tz)}</option>)}
          </datalist>
        </div>

        <div className={styles.gridScroll} data-loading={busy === null || undefined} aria-busy={busy === null}>
          {busy === null && <div className={styles.loadingPill} role="status">Checking availability…</div>}
          <table className={styles.grid}>
            <thead>
              <tr>
                <th className={styles.axisHead}>
                  {zones.map((tz) => <span key={tz}>{cityOf(tz).slice(0, 3).toUpperCase()}</span>)}
                </th>
                {days.map((day) => (
                  <th key={`${day.m}-${day.d}`}>{dateIn(slotAbs(day, 10), primaryZone)}</th>
                ))}
              </tr>
            </thead>
            <tbody onMouseLeave={() => setHover(null)}>
              {Array.from({ length: rows }, (_, row) => (
                <tr key={row}>
                  <th className={styles.axis}>
                    {row % 2 === 0 && zones.map((tz) => (
                      <span key={tz}>{timeIn(slotAbs(days[0], row), tz)}</span>
                    ))}
                  </th>
                  {days.map((day) => {
                    const start = slotAbs(day, row);
                    const t = start.getTime();
                    const cell = slotState(start, SLOT_MIN);
                    const canStart = cell === 'free' && slotState(start) === 'free';
                    // The span a click would request: the hovered one, else the chosen one.
                    const span = hover || selected;
                    const inSpan = span && t >= span.getTime() && t < span.getTime() + duration * 60000;
                    const spanHead = span && t === span.getTime();
                    const spanTail = span && t + SLOT_MIN * 60000 === span.getTime() + duration * 60000;
                    const cls = [
                      styles[cell],
                      inSpan && (hover ? styles.preview : styles.chosen),
                      inSpan && spanHead && styles.spanHead,
                      inSpan && spanTail && styles.spanTail,
                    ].filter(Boolean).join(' ');
                    const label = spanHead
                      ? `${timeIn(span, primaryZone)} – ${timeIn(new Date(span.getTime() + duration * 60000), primaryZone)}`
                      : null;
                    return (
                      <td key={`${day.d}-${row}`} className={cls} onMouseEnter={canStart ? undefined : () => setHover(null)}>
                        {canStart ? (
                          <button
                            type="button"
                            className={styles.slot}
                            aria-label={`Request ${dateIn(start, primaryZone)} ${timeIn(start, primaryZone)} – ${timeIn(new Date(t + duration * 60000), primaryZone)}`}
                            onMouseEnter={() => setHover(start)}
                            onFocus={() => setHover(start)}
                            onBlur={() => setHover(null)}
                            onClick={() => { setSelected(start); setHover(null); setSubmitError(null); }}
                          >
                            {label && <span className={styles.spanLabel}>{label}{hover && <em> · Request</em>}</span>}
                          </button>
                        ) : (
                          label && <span className={styles.spanLabel}>{label}</span>
                        )}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className={styles.legend}>
          <span><i className={styles.swFree} /> Available</span>
          <span><i className={styles.swBusy} /> Busy</span>
          <span><i className={styles.swOutside} /> Outside working hours</span>
          <span className={styles.legendHint}>
            Point at a green time to see the {duration}-minute slot. Click to request it.
          </span>
        </div>

        {selected && !sent && (
          <div className={styles.overlay} role="dialog" aria-modal="true">
            <form className={styles.panel} onSubmit={submit}>
              <h2>Request this time</h2>
              <div className={styles.slotLine}>
                <div className={styles.slotPrimary}>
                  {dateIn(selected, primaryZone)} · {timeIn(selected, primaryZone)} – {timeIn(selEnd, primaryZone)}
                </div>
                <div className={styles.slotAlt}>
                  {cityOf(primaryZone)} ({shortOffset(primaryZone)})
                  {zones.slice(1).map((tz) => (
                    <span key={tz}> · {timeIn(selected, tz)} – {timeIn(selEnd, tz)} in {cityOf(tz)}</span>
                  ))}
                </div>
              </div>
              <label className={styles.field}>
                Your name
                <input value={name} onChange={(e) => setName(e.target.value)} required autoFocus />
              </label>
              <label className={styles.field}>
                Your email
                <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
              </label>
              <label className={styles.field}>
                What&rsquo;s it about? <small>(optional)</small>
                <textarea rows={2} value={note} onChange={(e) => setNote(e.target.value)} />
              </label>
              {meet.turnstile_site_key && <div ref={turnstileRef} className={styles.turnstile} />}
              {submitError && <p className={styles.error}>{submitError}</p>}
              <div className={styles.panelActions}>
                <MgmtButton type="submit" disabled={submitting}>
                  {submitting ? 'Sending…' : 'Request meeting'}
                </MgmtButton>
                <button type="button" className={styles.cancel} onClick={() => setSelected(null)}>Cancel</button>
              </div>
              <p className={styles.fine}>
                {firstName} confirms every request. You&rsquo;ll get an email either way.
              </p>
            </form>
          </div>
        )}

        {sent && (
          <div className={styles.sentCard}>
            <div className={styles.sentCheck}>✓</div>
            <h2>Request sent</h2>
            <p>
              We&rsquo;ve asked {firstName} about <b>{dateIn(sent, primaryZone)}, {timeIn(sent, primaryZone)} – {timeIn(sentEnd, primaryZone)}</b>.
              You&rsquo;ll hear back at <code>{email}</code>.
            </p>
            <button type="button" className={styles.cancel} onClick={() => { setSent(null); setAvailabilityNonce((n) => n + 1); }}>
              Request another time
            </button>
          </div>
        )}

        <footer className={styles.foot}>powered by inbox2</footer>
      </div>
    </ManagementLayout>
  );
}
