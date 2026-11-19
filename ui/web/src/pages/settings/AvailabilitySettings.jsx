import { useState, useEffect } from 'react';
import api from '../../lib/api';
import useTransientFlag from '../../hooks/useTransientFlag';
import Button from '../../components/Button/Button';
import DateField from '../../components/DateField/DateField';
import { MgmtSelect } from '../../components/management';
import styles from './settings.module.css';

// Settings › Scheduling › Availability (docs/Calendar.md): the time zone and
// working day that meet links and the scheduling assistant evaluate slots in,
// plus an out-of-office period that reads as busy and sends an auto-reply.
// Lives next to the meet links it drives (it used to sit on Account).
const DEVICE_TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
const ZONES = (() => {
  const all = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : [];
  return all.includes('UTC') ? all : ['UTC', ...all];
})();

export default function AvailabilitySettings() {
  const [timezone, setTimezone] = useState('UTC');
  const [workStart, setWorkStart] = useState('09:00');
  const [workEnd, setWorkEnd] = useState('17:00');
  const [workDays, setWorkDays] = useState([1, 2, 3, 4, 5]);
  const [ooo, setOoo] = useState(null); // { start, end, message } as served
  const [error, setError] = useState(null);
  const [saved, flashSaved] = useTransientFlag();

  useEffect(() => {
    api.getAccount().then(data => {
      const acct = data.account || data.user || {};
      setTimezone(acct.default_timezone || 'UTC');
      // The API always returns the resolved working day, never a raw null.
      const wh = acct.working_hours || {};
      setWorkStart(minutesToTime(wh.start_minute, '09:00'));
      setWorkEnd(minutesToTime(wh.end_minute, '17:00'));
      setWorkDays(Array.isArray(wh.days) ? wh.days : [1, 2, 3, 4, 5]);
      setOoo({
        start: acct.out_of_office_start || null,
        end: acct.out_of_office_end || null,
        message: acct.out_of_office_message || '',
      });
    }).catch(() => { /* load error */ });
  }, []);

  const handleSave = async () => {
    setError(null);
    try {
      await api.patch('/account', {
        default_timezone: timezone,
        working_hours: {
          start_minute: timeToMinutes(workStart),
          end_minute: timeToMinutes(workEnd),
          days: workDays,
        },
      });
      flashSaved();
    } catch (e) {
      setError(e?.message || "Couldn't save your availability");
    }
  };

  const toggleWorkDay = (day) => {
    setWorkDays(days => (days.includes(day) ? days.filter(d => d !== day) : [...days, day].sort()));
  };

  return (
    <>
      <h1 className={styles.settingsTitle}>Availability</h1>
      <p className={styles.settingsHint}>
        People can only book you inside your working hours. They see when you’re busy,
        never what the meeting is. Your Gmail and Outlook calendars count too.
      </p>

      <div className={styles.settingsField}>
        <label htmlFor="avail-timezone">Time zone</label>
        <div className={styles.inlineRow}>
          <MgmtSelect bare compact id="avail-timezone" value={timezone} onChange={e => setTimezone(e.target.value)}>
            {!ZONES.includes(timezone) && <option value={timezone}>{timezone}</option>}
            {ZONES.map(tz => <option key={tz} value={tz}>{tz.replace(/_/g, ' ')}</option>)}
          </MgmtSelect>
          {timezone !== DEVICE_TZ && (
            <Button variant="link" onClick={() => setTimezone(DEVICE_TZ)}>
              Use {DEVICE_TZ.replace(/_/g, ' ')}
            </Button>
          )}
        </div>
      </div>

      <div className={styles.settingsField}>
        <label htmlFor="work-start">Working hours</label>
        <div className={styles.inlineRow}>
          <input
            id="work-start"
            type="time"
            value={workStart}
            onChange={e => setWorkStart(e.target.value)}
            aria-label="Working day starts"
          />
          <span className={styles.inlineSep}>to</span>
          <input
            type="time"
            value={workEnd}
            onChange={e => setWorkEnd(e.target.value)}
            aria-label="Working day ends"
          />
        </div>
      </div>

      <div className={styles.settingsField}>
        <label id="work-days-label">Working days</label>
        <div className={styles.dayToggles} role="group" aria-labelledby="work-days-label">
          {WEEKDAYS.map(({ value, label }) => (
            <button
              key={value}
              type="button"
              className={`${styles.dayToggle} ${workDays.includes(value) ? styles.dayToggleOn : ''}`}
              onClick={() => toggleWorkDay(value)}
              aria-pressed={workDays.includes(value)}
            >
              {label}
            </button>
          ))}
        </div>
      </div>


      {error && <div className={styles.settingsError}>{error}</div>}

      <Button className={styles.settingsButton} onClick={handleSave}>
        {saved ? 'Saved' : 'Save availability'}
      </Button>

      {ooo && <OutOfOffice value={ooo} onChange={setOoo} />}
    </>
  );
}

// Out of office as a state, not a form: off → one "Set out of office" button;
// on (or scheduled) → a status card with Edit and End now. Saved on its own,
// straight away — it is an action, not a preference. A period whose end has
// passed reads as off (the server already stops treating you as away then).
function OutOfOffice({ value, onChange }) {
  const [editing, setEditing] = useState(false);
  const [start, setStart] = useState('');
  const [end, setEnd] = useState('');
  const [message, setMessage] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const endAt = value.end ? new Date(value.end) : null;
  const startAt = value.start ? new Date(value.start) : null;
  const set = !!endAt && endAt > new Date();
  const started = set && (!startAt || startAt <= new Date());

  const save = async (next) => {
    setSaving(true);
    setError(null);
    try {
      await api.patch('/account', {
        // Empty clears the period rather than leaving a stale one.
        out_of_office_start: next ? new Date(next.start).toISOString() : '',
        out_of_office_end: next ? new Date(next.end).toISOString() : '',
        out_of_office_message: next ? next.message : '',
      });
      onChange(next
        ? { start: new Date(next.start).toISOString(), end: new Date(next.end).toISOString(), message: next.message }
        : { start: null, end: null, message: '' });
      setEditing(false);
    } catch (e) {
      setError(e?.message || "Couldn't update out of office");
    } finally {
      setSaving(false);
    }
  };

  const openEditor = () => {
    const now = new Date();
    setStart(set ? toLocalInput(value.start) : toLocalInput(now.toISOString()));
    setEnd(set ? toLocalInput(value.end) : '');
    setMessage(set ? value.message : '');
    setError(null);
    setEditing(true);
  };

  const valid = start && end && new Date(end) > new Date(start) && new Date(end) > new Date();

  return (
    <div className={styles.settingsField}>
      <label htmlFor={editing ? 'ooo-start' : undefined}>Out of office</label>

      {!editing && !set && (
        <Button variant="secondary" className={styles.oooButton} onClick={openEditor}>
          Set out of office
        </Button>
      )}

      {!editing && set && (
        <div className={styles.oooCard}>
          <div className={styles.oooCardText}>
            <span className={styles.oooStatus}>
              {started ? 'Out of office' : 'Scheduled'}
              {' · '}
              {started ? `until ${formatWhen(endAt)}` : `${formatWhen(startAt)} – ${formatWhen(endAt)}`}
            </span>
            <span className={styles.oooMessage}>
              {value.message || 'No automatic reply'}
            </span>
          </div>
          <Button variant="link" className={styles.schedRowBtn} onClick={openEditor}>Edit</Button>
          <Button variant="link" className={`${styles.schedRevoke} ${styles.schedRowBtn}`} onClick={() => save(null)} disabled={saving}>
            {started ? 'End now' : 'Cancel'}
          </Button>
        </div>
      )}

      {editing && (
        <div className={styles.oooCard}>
          <div className={styles.oooEditor}>
            <div className={styles.inlineRow}>
              <DateField id="ooo-start" time value={start} onChange={setStart} aria-label="Out of office from" />
              <span className={styles.inlineSep}>to</span>
              <DateField time value={end} min={start} onChange={setEnd} aria-label="Out of office until" />
            </div>
            <textarea
              rows={3}
              value={message}
              onChange={e => setMessage(e.target.value)}
              aria-label="Automatic reply"
              placeholder="Automatic reply, e.g. I'm on holiday until Monday and will reply when I'm back."
            />
            <p className={styles.settingsHint}>
              You show as busy until it ends by itself. Each person who emails you gets the reply once.
              Mailing lists and bulk mail get no reply.
            </p>
            {error && <div className={styles.settingsError}>{error}</div>}
            <div className={styles.inlineRow}>
              <Button onClick={() => save({ start, end, message })} disabled={!valid || saving} aria-busy={saving}>
                {set ? 'Update' : 'Turn on'}
              </Button>
              <Button variant="link" onClick={() => setEditing(false)}>Cancel</Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function formatWhen(date) {
  return date.toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

// Monday-first for a working week; values are JS getDay() numbers so they match
// what the server stores.
const WEEKDAYS = [
  { value: 1, label: 'Mon' },
  { value: 2, label: 'Tue' },
  { value: 3, label: 'Wed' },
  { value: 4, label: 'Thu' },
  { value: 5, label: 'Fri' },
  { value: 6, label: 'Sat' },
  { value: 0, label: 'Sun' },
];

// The API speaks minutes from local midnight; <input type="time"> speaks HH:MM.
function minutesToTime(minutes, fallback) {
  if (typeof minutes !== 'number') return fallback;
  const h = String(Math.floor(minutes / 60)).padStart(2, '0');
  const m = String(minutes % 60).padStart(2, '0');
  return `${h}:${m}`;
}

function timeToMinutes(value) {
  const [h, m] = String(value || '').split(':').map(Number);
  if (Number.isNaN(h) || Number.isNaN(m)) return 0;
  return (h * 60) + m;
}

// <input type="datetime-local"> wants a local-clock string with no zone suffix.
function toLocalInput(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
