import { useMemo, useState, useCallback, useRef } from 'react';
import Icon from '../Icon';
import useAvailability from '../../hooks/useAvailability';
import styles from './SchedulingAssistant.module.css';

/**
 * Scheduling assistant — the Exchange/Google "Find a time" grid.
 *
 * People down the left, the day across the top, busy time shaded, and a
 * draggable selection showing where the meeting would land. Picking a
 * suggestion or dragging the selection hands a new start/end back to the editor.
 *
 * Availability is MX-only (see useAvailability). An outside guest has no
 * calendar here, so their row reads "no availability" rather than being drawn
 * as free — the distinction matters when you are about to double-book someone.
 */

// The grid covers a working-ish day rather than all 24 hours; off-hours are
// still reachable by typing a time in the editor.
const GRID_START_HOUR = 7;
const GRID_END_HOUR = 21;
const SLOT_MINUTES = 30;
const SLOTS_PER_HOUR = 60 / SLOT_MINUTES;
const TOTAL_SLOTS = (GRID_END_HOUR - GRID_START_HOUR) * SLOTS_PER_HOUR;

function startOfGrid(day) {
  const d = new Date(day);
  d.setHours(GRID_START_HOUR, 0, 0, 0);
  return d;
}

// Fractional slot position of a timestamp within the drawn grid.
function slotOffset(date, gridStart) {
  return (date.getTime() - gridStart.getTime()) / (SLOT_MINUTES * 60 * 1000);
}

function clampPercent(value) {
  return Math.max(0, Math.min(100, value));
}

function fmtTime(date) {
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

function initials(name, email) {
  const source = (name || email || '?').trim();
  const parts = source.split(/[\s@.]+/).filter(Boolean);
  return ((parts[0]?.[0] || '') + (parts[1]?.[0] || '')).toUpperCase() || '?';
}

export default function SchedulingAssistant({
  orgSlug,
  emails,
  startAt,
  endAt,
  onPick,
  onClose,
}) {
  const start = useMemo(() => (startAt ? new Date(startAt) : new Date()), [startAt]);
  const end = useMemo(() => (endAt ? new Date(endAt) : new Date(start.getTime() + 30 * 60000)), [endAt, start]);
  const durationMinutes = Math.max(5, Math.round((end - start) / 60000));

  const [day, setDay] = useState(() => { const d = new Date(start); d.setHours(0, 0, 0, 0); return d; });

  const { attendees, suggestions, loading } = useAvailability(orgSlug, {
    emails,
    day,
    durationMinutes,
  });

  const gridStart = useMemo(() => startOfGrid(day), [day]);
  const gridRef = useRef(null);

  // ── Selection (the meeting itself), expressed in slot units ───────
  // Derived from the editor's own time fields rather than synced into state:
  // `anchorKey` changes whenever they do, which discards a stale local drag on
  // its own. Position is measured within the selection's OWN day, so paging to
  // another day keeps the same time-of-day.
  const selectionLength = durationMinutes / SLOT_MINUTES;
  const anchorKey = `${start.getTime()}|${durationMinutes}`;
  const [dragOverride, setDragOverride] = useState(null);
  const selectionFrom = dragOverride?.key === anchorKey
    ? dragOverride.from
    : slotOffset(start, startOfGrid(start));

  const commit = useCallback((fromSlot) => {
    const clamped = Math.max(0, Math.min(TOTAL_SLOTS - selectionLength, Math.round(fromSlot)));
    const newStart = new Date(gridStart.getTime() + clamped * SLOT_MINUTES * 60000);
    const newEnd = new Date(newStart.getTime() + durationMinutes * 60000);
    // Clear the local override — the new props become the source of truth.
    setDragOverride(null);
    onPick?.(newStart, newEnd);
  }, [gridStart, durationMinutes, onPick, selectionLength]);

  // Dragging the selection band. Pointer events keep mouse and touch on one path.
  const dragRef = useRef(null);
  const handlePointerDown = useCallback((e) => {
    const rect = gridRef.current?.getBoundingClientRect();
    if (!rect) return;
    dragRef.current = { originX: e.clientX, originFrom: selectionFrom, width: rect.width, moved: false };
    e.currentTarget.setPointerCapture?.(e.pointerId);
  }, [selectionFrom]);

  const handlePointerMove = useCallback((e) => {
    const drag = dragRef.current;
    if (!drag) return;
    const deltaSlots = ((e.clientX - drag.originX) / drag.width) * TOTAL_SLOTS;
    drag.moved = true;
    setDragOverride({
      key: anchorKey,
      from: Math.max(0, Math.min(TOTAL_SLOTS - selectionLength, drag.originFrom + deltaSlots)),
    });
  }, [anchorKey, selectionLength]);

  const handlePointerUp = useCallback(() => {
    const drag = dragRef.current;
    if (!drag) return;
    dragRef.current = null;
    // A press without movement is a click on the band, not a drag.
    if (drag.moved) commit(selectionFrom);
  }, [commit, selectionFrom]);

  // Clicking an empty cell moves the meeting there; arrow keys nudge it.
  const handleGridClick = useCallback((e) => {
    const rect = gridRef.current?.getBoundingClientRect();
    if (!rect) return;
    // Centre the meeting on the click rather than starting it there.
    commit((((e.clientX - rect.left) / rect.width) * TOTAL_SLOTS) - (selectionLength / 2));
  }, [commit, selectionLength]);

  const handleKeyDown = useCallback((e) => {
    if (e.key === 'ArrowRight') { e.preventDefault(); commit(selectionFrom + 1); }
    else if (e.key === 'ArrowLeft') { e.preventDefault(); commit(selectionFrom - 1); }
    else if (e.key === 'Escape') { onClose?.(); }
  }, [commit, selectionFrom, onClose]);

  const shiftDay = useCallback((days) => {
    setDay(d => { const next = new Date(d); next.setDate(next.getDate() + days); return next; });
  }, []);

  const hourMarks = useMemo(() => (
    Array.from({ length: GRID_END_HOUR - GRID_START_HOUR }, (_, i) => GRID_START_HOUR + i)
  ), []);

  const selectionStart = new Date(gridStart.getTime() + selectionFrom * SLOT_MINUTES * 60000);
  const selectionEnd = new Date(selectionStart.getTime() + durationMinutes * 60000);

  // Whose day the current selection collides with — the headline the whole
  // panel exists to answer.
  const conflicts = attendees.filter(a => a.availability_known && (a.busy || []).some(b => (
    new Date(b.start) < selectionEnd && new Date(b.end) > selectionStart
  )));
  const awayConflicts = conflicts.filter(a => (a.busy || []).some(b => (
    b.out_of_office && new Date(b.start) < selectionEnd && new Date(b.end) > selectionStart
  )));

  return (
    <div className={styles.panel} role="dialog" aria-label="Scheduling assistant">
      <div className={styles.header}>
        <span className={styles.headerTitle}>Find a time</span>
        <div className={styles.dayNav}>
          <button type="button" className={styles.navButton} onClick={() => shiftDay(-1)} aria-label="Previous day">
            <Icon name="chevron.left" size={12} />
          </button>
          <span className={styles.dayLabel}>
            {day.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })}
          </span>
          <button type="button" className={styles.navButton} onClick={() => shiftDay(1)} aria-label="Next day">
            <Icon name="chevron.right" size={12} />
          </button>
        </div>
        <button type="button" className={styles.headerClose} onClick={onClose} aria-label="Close">
          <Icon name="xmark" size={12} />
        </button>
      </div>

      <div className={styles.status}>
        {loading ? (
          <span className={styles.statusMuted}>Checking calendars…</span>
        ) : conflicts.length === 0 ? (
          <span className={styles.statusOk}>
            <Icon name="checkmark.circle" size={13} /> Everyone is free from {fmtTime(selectionStart)} to {fmtTime(selectionEnd)}
          </span>
        ) : (
          <span className={styles.statusClash}>
            <Icon name="exclamationmark.triangle" size={13} />
            {awayConflicts.length === conflicts.length
              ? ` ${conflicts.map(c => c.name || c.email).join(', ')} ${conflicts.length === 1 ? 'is' : 'are'} out of office`
              : ` Clashes with ${conflicts.map(c => c.name || c.email).join(', ')}`}
          </span>
        )}
      </div>

      <div className={styles.gridWrap}>
        {/* Hour ruler */}
        <div className={styles.rulerRow}>
          <div className={styles.rowLabelSpacer} />
          <div className={styles.ruler}>
            {hourMarks.map(h => (
              <div key={h} className={styles.rulerMark}>
                {new Date(2000, 0, 1, h).toLocaleTimeString(undefined, { hour: 'numeric' })}
              </div>
            ))}
          </div>
        </div>

        {/* One row per attendee */}
        <div className={styles.rows}>
          {/* No attendees yet: still draw one lane, or the band would collapse
              onto the hour ruler with nothing to sit in. */}
          {attendees.length === 0 && !loading && (
            <div className={styles.row}>
              <div className={styles.rowLabel}>
                <span className={styles.rowName}>Just you. Invite people to compare.</span>
              </div>
              <div className={styles.track}>
                {hourMarks.map(h => <div key={h} className={styles.trackHour} />)}
              </div>
            </div>
          )}

          {attendees.map(person => (
            <div key={person.email} className={styles.row}>
              <div className={styles.rowLabel} title={person.email}>
                <span className={styles.avatar} aria-hidden="true">{initials(person.name, person.email)}</span>
                <span className={styles.rowName}>
                  {person.name || person.email}
                  {!person.internal && <span className={styles.guestTag}>guest</span>}
                  {person.out_of_office && (
                    <span
                      className={styles.oooTag}
                      title={person.out_of_office.message || 'Out of office'}
                    >
                      OOO
                    </span>
                  )}
                </span>
              </div>

              <div className={styles.track}>
                {hourMarks.map(h => <div key={h} className={styles.trackHour} />)}

                {!person.availability_known ? (
                  <div className={styles.unknown}>No availability</div>
                ) : (
                  (person.busy || []).map((block, i) => {
                    const from = clampPercent((slotOffset(new Date(block.start), gridStart) / TOTAL_SLOTS) * 100);
                    const to = clampPercent((slotOffset(new Date(block.end), gridStart) / TOTAL_SLOTS) * 100);
                    if (to <= 0 || from >= 100) return null;
                    return (
                      <div
                        key={`${block.start}-${i}`}
                        // Out-of-office is drawn differently: a shaded row is
                        // otherwise indistinguishable from a wall of meetings.
                        className={`${styles.busy} ${block.out_of_office ? styles.busyOutOfOffice : ''}`}
                        // A block with no title is one we are only allowed to
                        // know the shape of — say "Busy", never guess.
                        title={block.out_of_office
                          ? (person.out_of_office?.message || 'Out of office')
                          : (block.title || 'Busy')}
                        ref={(el) => {
                          el?.style.setProperty('--busy-left', `${from}%`);
                          el?.style.setProperty('--busy-width', `${Math.max(to - from, 0.6)}%`);
                        }}
                      />
                    );
                  })
                )}
              </div>
            </div>
          ))}
        </div>

        {/* Selection band — sits above every row so it reads as one column */}
        <div
          className={styles.overlay}
          ref={gridRef}
          onClick={handleGridClick}
          onKeyDown={handleKeyDown}
          role="slider"
          tabIndex={0}
          aria-label="Meeting time"
          aria-valuetext={`${fmtTime(selectionStart)} to ${fmtTime(selectionEnd)}`}
          aria-valuenow={Math.round(selectionFrom)}
          aria-valuemin={0}
          aria-valuemax={TOTAL_SLOTS}
        >
          <div
            className={`${styles.selection} ${conflicts.length ? styles.selectionClash : ''}`}
            onPointerDown={handlePointerDown}
            onPointerMove={handlePointerMove}
            onPointerUp={handlePointerUp}
            ref={(el) => {
              el?.style.setProperty('--sel-left', `${clampPercent((selectionFrom / TOTAL_SLOTS) * 100)}%`);
              el?.style.setProperty('--sel-width', `${(selectionLength / TOTAL_SLOTS) * 100}%`);
            }}
          >
            <span className={styles.selectionLabel}>{fmtTime(selectionStart)}</span>
          </div>
        </div>
      </div>

      {/* Ranked slots that suit everybody */}
      <div className={styles.suggestions}>
        <div className={styles.suggestionsLabel}>Suggested times</div>
        {loading && <span className={styles.statusMuted}>…</span>}
        {!loading && suggestions.length === 0 && (
          <span className={styles.statusMuted}>No slot works for everyone in this window.</span>
        )}
        <div className={styles.suggestionList}>
          {suggestions.map(slot => {
            const from = new Date(slot.start);
            const to = new Date(slot.end);
            const offHours = (slot.outside_working_hours || []).length > 0;
            return (
              <button
                key={slot.start}
                type="button"
                className={`${styles.suggestion} ${offHours ? styles.suggestionOffHours : ''}`}
                onClick={() => {
                  const d = new Date(from); d.setHours(0, 0, 0, 0);
                  setDay(d);
                  setDragOverride(null);
                  onPick?.(from, to);
                }}
                title={offHours ? 'Outside working hours for some attendees' : 'Everyone is free'}
              >
                {from.toLocaleDateString(undefined, { weekday: 'short' })} {fmtTime(from)}
                {offHours && <Icon name="moon" size={10} className={styles.offHoursIcon} />}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
