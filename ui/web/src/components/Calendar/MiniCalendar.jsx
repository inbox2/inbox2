import { useMemo, useCallback, useState } from 'react';
import {
  startOfMonth, endOfMonth, startOfWeek, endOfWeek,
  eachDayOfInterval, format, isSameMonth, isSameDay,
  addDays, addMonths, subMonths, isWeekend, isWithinInterval,
} from 'date-fns';
import useCalendarStore from '../../stores/calendarStore';
import Icon from '../Icon';
import Popover from '../Popover/Popover';
import DayPeek from './DayPeek';
import styles from './MiniCalendar.module.css';

const WEEKDAYS = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
const FALLBACK_DATE = new Date();
const EMPTY = [];

// `span`: 'month' (default) or 'wide' — the latter runs from mid-previous month
// to mid-next month, so the surrounding weeks are visible without navigating.
// Pass `events` to enable the hover preview of a day (DayPeek).
// `onOpenDay` fires only on a real day click (never on month paging, which also
// goes through onSelect) — the rail uses it to jump to the calendar page.
// `minDate` disables earlier days; `highlightVisible={false}` drops the
// main-calendar range tint (DateField uses it as a plain picker).
export default function MiniCalendar({ selectedDate, onSelect, onOpenDay, eventDates, events = EMPTY, span = 'month', minDate, highlightVisible = true }) {
  const viewDate = useMemo(() => selectedDate || FALLBACK_DATE, [selectedDate]);
  const eventDateSet = useMemo(() => new Set(eventDates || []), [eventDates]);
  const [peek, setPeek] = useState(null);
  const visibleStart = useCalendarStore(s => highlightVisible ? s.visibleStart : null);
  const rawVisibleEnd = useCalendarStore(s => highlightVisible ? s.visibleEnd : null);
  // FullCalendar end is exclusive (start of next day), so subtract 1ms
  const visibleEnd = useMemo(
    () => rawVisibleEnd ? new Date(rawVisibleEnd.getTime() - 1) : null,
    [rawVisibleEnd]
  );

  const weeks = useMemo(() => {
    const wide = span === 'wide';
    const rangeStart = wide ? addDays(startOfMonth(subMonths(viewDate, 1)), 14) : startOfMonth(viewDate);
    const rangeEnd = wide ? addDays(startOfMonth(addMonths(viewDate, 1)), 13) : endOfMonth(viewDate);
    const calStart = startOfWeek(rangeStart, { weekStartsOn: 1 });
    const calEnd = endOfWeek(rangeEnd, { weekStartsOn: 1 });
    const allDays = eachDayOfInterval({ start: calStart, end: calEnd });
    const rows = [];
    for (let i = 0; i < allDays.length; i += 7) {
      rows.push(allDays.slice(i, i + 7));
    }
    return rows;
  }, [viewDate, span]);

  // Events grouped by local day, so the hover preview is a map lookup.
  const eventsByDay = useMemo(() => {
    const map = new Map();
    for (const e of events) {
      const k = format(e.start, 'yyyy-MM-dd');
      if (!map.has(k)) map.set(k, []);
      map.get(k).push(e);
    }
    return map;
  }, [events]);

  const handlePrev = useCallback(() => {
    onSelect(subMonths(viewDate, 1));
  }, [viewDate, onSelect]);

  const handleNext = useCallback(() => {
    onSelect(addMonths(viewDate, 1));
  }, [viewDate, onSelect]);

  const openPeek = useCallback((day, el) => {
    if (!events.length) return;
    setPeek({ day, rect: el.getBoundingClientRect() });
  }, [events.length]);

  const today = new Date();

  return (
    <div className={`${styles.mini}${span === 'wide' ? ` ${styles.wide}` : ''}`} role="presentation" onMouseLeave={() => setPeek(null)}>
      <div className={styles.header}>
        <button className={styles.navBtn} onClick={handlePrev} aria-label="Previous month">
          <Icon name="chevron.left" size={10} />
        </button>
        <span className={styles.monthLabel}>
          {viewDate.toLocaleDateString(undefined, { month: 'long', year: 'numeric' })}
        </span>
        <button className={styles.navBtn} onClick={handleNext} aria-label="Next month">
          <Icon name="chevron.right" size={10} />
        </button>
      </div>

      <div className={styles.grid}>
        <div className={styles.weekdayRow}>
          {WEEKDAYS.map(d => (
            <div key={d} className={styles.weekday}>{d}</div>
          ))}
        </div>

        {weeks.map((week, wi) => {
          // Highlight the row if any of its days fall within the main calendar's visible range
          const isVisibleWeek = visibleStart && visibleEnd && week.some(d =>
            isWithinInterval(d, { start: visibleStart, end: visibleEnd })
          );

          return (
            <div
              key={wi}
              className={[
                styles.weekRow,
                isVisibleWeek && styles.weekRowVisible,
              ].filter(Boolean).join(' ')}
            >
              {week.map(day => {
                const inMonth = isSameMonth(day, viewDate);
                const dayIsToday = isSameDay(day, today);
                const weekend = isWeekend(day);
                const hasEvents = eventDateSet.has(format(day, 'yyyy-MM-dd'));
                const selected = selectedDate && isSameDay(day, selectedDate);
                const disabled = minDate && day < minDate && !isSameDay(day, minDate);
                // Mark days that are in the main calendar's visible range
                const inVisibleRange = visibleStart && visibleEnd &&
                  isWithinInterval(day, { start: visibleStart, end: visibleEnd });

                const cls = [
                  styles.day,
                  !inMonth && styles.dayOutside,
                  weekend && inMonth && styles.dayWeekend,
                  dayIsToday && styles.dayToday,
                  inVisibleRange && !dayIsToday && inMonth && styles.dayInRange,
                  hasEvents && styles.dayHasEvents,
                  selected && styles.daySelected,
                  peek && isSameDay(peek.day, day) && styles.dayPeeked,
                ].filter(Boolean).join(' ');

                return (
                  <button
                    key={day.toISOString()}
                    className={cls}
                    disabled={disabled}
                    aria-pressed={selected || undefined}
                    aria-label={format(day, 'EEEE d MMMM yyyy')}
                    onClick={() => { onSelect(day); onOpenDay?.(day); }}
                    onMouseEnter={(e) => openPeek(day, e.currentTarget)}
                    onFocus={(e) => openPeek(day, e.currentTarget)}
                  >
                    {format(day, 'd')}
                  </button>
                );
              })}
            </div>
          );
        })}
      </div>

      {peek && (
        <Popover
          open
          anchorRect={peek.rect}
          placement="left"
          closeOnOutsideClick={false}
          onClose={() => setPeek(null)}
        >
          <DayPeek day={peek.day} events={eventsByDay.get(format(peek.day, 'yyyy-MM-dd')) || EMPTY} />
        </Popover>
      )}
    </div>
  );
}
