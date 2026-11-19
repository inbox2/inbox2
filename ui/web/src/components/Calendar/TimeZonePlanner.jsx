import { useState, useEffect, useLayoutEffect, useMemo, useRef, useContext, useCallback } from 'react';
import { useNavigate, useParams } from 'react-router';
import { format } from 'date-fns';
import Modal from '../Modal/Modal';
import MiniCalendar from './MiniCalendar';
import Button from '../Button/Button';
import IconButton from '../IconButton';
import Icon from '../Icon';
import { AuthContext } from '../../hooks/AuthProvider';
import { isRealOrgId } from '../../lib/org';
import useDismiss from '../../hooks/useDismiss';
import useCalendarStore from '../../stores/calendarStore';
import { TZ_PLANNER_LABELS, TZ_PLANNER_ZONES } from '../../lib/storageKeys';
import {
  LOCAL_TZ, abbrOf, cityOf, regionOf, searchZones, shortOffset,
  wallParts, offsetMinutes, wallToInstant,
} from '../../lib/timeZones';
import styles from './TimeZonePlanner.module.css';

const WORK_START = 9;
const WORK_END = 18; // exclusive
const DAY_START = 7;
const DAY_END = 22; // exclusive

const DEFAULT_ZONES = [...new Set([LOCAL_TZ, 'America/New_York', 'Asia/Karachi'])];

const loadZones = () => {
  try {
    const saved = JSON.parse(localStorage.getItem(TZ_PLANNER_ZONES));
    return Array.isArray(saved) && saved.length ? saved : DEFAULT_ZONES;
  } catch { return DEFAULT_ZONES; }
};

// Names the user typed over the city name — local to this machine, and gone
// again when the row is cleared back to its city.
const loadLabels = () => {
  try { return JSON.parse(localStorage.getItem(TZ_PLANNER_LABELS)) || {}; } catch { return {}; }
};

// 'YYYY-MM-DD' for the day the base zone is currently on.
const todayIn = (tz) => {
  const { year, month, day } = wallParts(tz, new Date());
  return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
};

const isoDay = (d) => format(d, 'yyyy-MM-dd');

const shiftDay = (iso, days) => {
  const [y, m, d] = iso.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + days));
  return t.toISOString().slice(0, 10);
};

const hhmm = (tz, date) => new Intl.DateTimeFormat(navigator.language, {
  timeZone: tz, hour: '2-digit', minute: '2-digit',
}).format(date);

const dayLabel = (tz, date, opts = { weekday: 'short', month: 'short', day: 'numeric' }) =>
  new Intl.DateTimeFormat(navigator.language, { timeZone: tz, ...opts }).format(date);

const bandOf = (h) => {
  if (h >= WORK_START && h < WORK_END) return styles.work;
  if (h >= DAY_START && h < DAY_END) return styles.day;
  return styles.night;
};

// Schematic, not astronomical: the day band's edges stand in for sunrise and
// sunset, and 12:00 for high noon. ponytail: real solar times would mean a
// lat/long table for 418 zones — say so if the difference ever matters.
const MARKS = { [DAY_START]: 'sunrise', 12: 'noon', [DAY_END]: 'night' };
const MARK_ICON = { sunrise: 'sun', noon: 'sun.max.fill', night: 'moon.fill' };

export default function TimeZonePlanner({ open, onClose }) {
  const [zones, setZones] = useState(loadZones);
  const [day, setDay] = useState(() => todayIn(loadZones()[0]));
  // The comparison ruler — worldtimebuddy's black box. Always on a column;
  // starts on the hour it is right now in the base zone.
  const [picked, setPicked] = useState(null); // the clicked hour column, if any
  const [hover, setHover] = useState(null); // the ruler follows the pointer, then snaps back
  const [labels, setLabels] = useState(loadLabels);
  const [editing, setEditing] = useState(null); // tz whose name is being typed
  const [draft, setDraft] = useState('');
  const [calOpen, setCalOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [now, setNow] = useState(() => new Date());
  const addRef = useRef(null);
  const navigate = useNavigate();
  const { orgSlug } = useParams();
  // Same org resolution the command palette uses — the planner is mounted above
  // the route tree, so useParams only has a slug on the pages that carry one.
  const currentOrgSlug = useContext(AuthContext)?.currentOrgSlug;
  const org = isRealOrgId(orgSlug) ? orgSlug : (isRealOrgId(currentOrgSlug) ? currentOrgSlug : null);
  const setCurrentDate = useCalendarStore((s) => s.setCurrentDate);
  const active = hover ?? picked;
  const gridRef = useRef(null);
  const dateRef = useRef(null);
  const boxRef = useRef(null);

  const base = zones[0] || LOCAL_TZ;
  const dayDate = useMemo(() => { const [y, m, d] = day.split('-').map(Number); return new Date(y, m - 1, d); }, [day]);

  useEffect(() => { localStorage.setItem(TZ_PLANNER_ZONES, JSON.stringify(zones)); }, [zones]);
  useEffect(() => { localStorage.setItem(TZ_PLANNER_LABELS, JSON.stringify(labels)); }, [labels]);

  const nameOf = (tz) => labels[tz] || cityOf(tz);

  // Blank (or the city name back) drops the override rather than storing it.
  const commitName = () => {
    if (!editing) return;
    const typed = draft.trim();
    setLabels((l) => {
      const next = { ...l };
      if (!typed || typed === cityOf(editing)) delete next[editing];
      else next[editing] = typed;
      return next;
    });
    setEditing(null);
  };

  // Click away from the month grid (or Escape) to put it away.
  const closeCal = useCallback(() => setCalOpen(false), []);
  useDismiss(dateRef, closeCal, calOpen);

  // The row clocks tick; no need to be sharper than a minute.
  useEffect(() => {
    if (!open) return undefined;
    const id = setInterval(() => setNow(new Date()), 60000);
    return () => clearInterval(id);
  }, [open]);

  // The selected column is one rectangle drawn over every row (per-cell borders
  // broke into dashes at the row gaps), so it gets measured off the real cell.
  useLayoutEffect(() => {
    const box = boxRef.current;
    const grid = gridRef.current;
    if (active == null || !box || !grid) return undefined;
    // offsetLeft/Width, not getBoundingClientRect: the modal opens with a
    // scale animation, and a rect measured mid-transform placed the box half a
    // cell off until the first hover re-measured it.
    const place = () => {
      const cell = grid.querySelector(`[data-col="${active}"]`);
      if (!cell) return;
      box.style.setProperty('--pick-left', `${cell.offsetLeft - 6}px`);
      box.style.setProperty('--pick-width', `${cell.offsetWidth + 12}px`);
    };
    place();
    window.addEventListener('resize', place);
    return () => window.removeEventListener('resize', place);
  }, [active, zones, day]);

  // The 24 instants that are hours 0…23 of `day` in the base zone.
  const columns = useMemo(() => {
    const [y, m, d] = day.split('-').map(Number);
    return Array.from({ length: 24 }, (_, h) => wallToInstant(base, y, m, d, h));
  }, [day, base]);

  const rows = useMemo(() => zones.map((tz) => {
    const diff = (offsetMinutes(tz, columns[12]) - offsetMinutes(base, columns[12])) / 60;
    return {
      tz,
      diff,
      cells: columns.map((at) => ({ at, ...wallParts(tz, at) })),
    };
  }), [zones, columns, base]);

  // A column everybody can make a meeting in — the whole point of the grid.
  const overlap = useMemo(() => columns.map((_, i) => rows.length > 1
    && rows.every((r) => r.cells[i].hour >= WORK_START && r.cells[i].hour < WORK_END)), [rows, columns]);

  const matches = useMemo(
    () => (query.trim() ? searchZones(query, 8).filter((z) => !zones.includes(z)) : []),
    [query, zones],
  );

  // Hand the slot under the ruler to the calendar's new-event editor.
  const scheduleMeeting = () => {
    if (picked == null) return;
    const at = columns[picked];
    setCurrentDate(at);
    onClose();
    navigate(`${org ? `/${org}` : ''}/calendar?new=${encodeURIComponent(at.toISOString())}`);
  };

  const addZone = (tz) => {
    setZones((z) => (z.includes(tz) ? z : [...z, tz]));
    setQuery('');
    addRef.current?.focus();
  };

  return (
    <Modal open={open} onClose={onClose} className={styles.modal}>
      <div className={styles.head}>
        <h2 className={styles.title}><Icon name="globe" size={15} /> Timezone planner</h2>
        <div className={styles.dateNav}>
          <IconButton icon="chevron.left" size="sm" aria-label="Previous day" onClick={() => setDay((d) => shiftDay(d, -1))} />
          <div className={styles.dateAnchor} ref={dateRef}>
            <button
              type="button"
              className={styles.date}
              onClick={() => setCalOpen((o) => !o)}
            >
              {format(dayDate, 'EEE d MMM yyyy')}
            </button>
            {calOpen && (
              <div className={styles.calPanel}>
                <MiniCalendar
                  selectedDate={dayDate}
                  onSelect={(d) => setDay(isoDay(d))}
                  onOpenDay={() => setCalOpen(false)}
                />
              </div>
            )}
          </div>
          <IconButton icon="chevron.right" size="sm" aria-label="Next day" onClick={() => setDay((d) => shiftDay(d, 1))} />
          <button type="button" className={styles.today} onClick={() => { setDay(todayIn(base)); setCalOpen(false); }}>
            Today
          </button>
        </div>
      </div>

      <div className={styles.addRow}>
        <input
          ref={addRef}
          type="text"
          className={styles.add}
          placeholder="Add a place or timezone…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        {matches.length > 0 && (
          <ul className={styles.suggest}>
            {matches.map((tz) => (
              <li key={tz}>
                <button type="button" className={styles.suggestBtn} onMouseDown={() => addZone(tz)}>
                  <span>{cityOf(tz)}<span className={styles.suggestRegion}>{regionOf(tz)}</span></span>
                  <span className={styles.suggestTz}>{abbrOf(tz)} · {shortOffset(tz)}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className={styles.grid} ref={gridRef} role="presentation" onMouseLeave={() => setHover(null)}>
        {active != null && <div className={styles.pickBox} ref={boxRef} />}
        {rows.map((row, ri) => (
          <div key={row.tz} className={styles.row}>
            <div className={styles.label}>
              <div className={styles.labelTop}>
                {editing === row.tz ? (
                  <input
                    autoFocus
                    className={styles.rename}
                    value={draft}
                    aria-label={`Name for ${cityOf(row.tz)}`}
                    onChange={(e) => setDraft(e.target.value)}
                    onBlur={commitName}
                    onKeyDown={(e) => { if (e.key === 'Enter') commitName(); }}
                  />
                ) : (
                  <button
                    type="button"
                    className={styles.city}
                    title="Click to rename. The name stays on this device."
                    onClick={() => { setEditing(row.tz); setDraft(nameOf(row.tz)); }}
                  >
                    {nameOf(row.tz)}
                  </button>
                )}
                <span className={styles.abbr}>{abbrOf(row.tz)}</span>
                {ri === 0
                  ? <span className={styles.baseTag}>base</span>
                  : <span className={styles.diff}>{row.diff >= 0 ? `+${row.diff}` : row.diff}h</span>}
              </div>
              <div className={styles.labelSub}>
                {row.tz === LOCAL_TZ ? 'Your timezone' : regionOf(row.tz)} · {shortOffset(row.tz)}
              </div>
            </div>

            <div className={styles.clock}>
              <span className={styles.time}>{hhmm(row.tz, now)}</span>
              <span className={styles.date2}>{dayLabel(row.tz, now)}</span>
            </div>

            <div className={styles.cells}>
              {row.cells.map((c, i) => (
                <button
                  type="button"
                  key={c.at.getTime()}
                  data-col={i}
                  className={[
                    styles.cell,
                    bandOf(c.hour),
                    overlap[i] ? styles.overlap : '',
                  ].filter(Boolean).join(' ')}
                  onClick={() => setPicked(i)}
                  onMouseEnter={() => setHover(i)}
                  onFocus={() => setHover(i)}
                >
                  {MARKS[c.hour] && (
                    <Icon name={MARK_ICON[MARKS[c.hour]]} size={10} className={styles.mark} />
                  )}
                  {c.hour === 0
                    ? <span className={styles.midnight}>{dayLabel(row.tz, c.at, { month: 'short', day: 'numeric' })}</span>
                    : c.hour}
                </button>
              ))}
            </div>

            {ri > 0 && (
              <IconButton
                className={styles.remove}
                icon="xmark"
                size="sm"
                iconSize={11}
                aria-label={`Remove ${nameOf(row.tz)}`}
                onClick={() => setZones((z) => z.filter((t) => t !== row.tz))}
              />
            )}
          </div>
        ))}
      </div>

      <div className={styles.legend}>
        <span><i className={`${styles.swatch} ${styles.work}`} /> working hours</span>
        <span><i className={`${styles.swatch} ${styles.day}`} /> daylight</span>
        <span><i className={`${styles.swatch} ${styles.night}`} /> night</span>
        <span><i className={`${styles.swatch} ${styles.overlap}`} /> everyone at work</span>
        <span><Icon name="sun" size={11} /> sunrise <Icon name="sun.max.fill" size={11} /> midday <Icon name="moon.fill" size={11} /> night</span>
        <Button
          className={styles.schedule}
          onClick={scheduleMeeting}
          disabled={picked == null}
          title={picked == null ? 'Click an hour to pick the slot' : undefined}
        >
          <Icon name="calendar" size={13} /> Schedule meeting
        </Button>
      </div>
    </Modal>
  );
}
