import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { format, isValid, parse } from 'date-fns';
import Popover from '../Popover/Popover';
import MiniCalendar from '../Calendar/MiniCalendar';
import Icon from '../Icon';
import styles from './DateField.module.css';

// The app's date picker. Never <input type="date">: the native popup is browser
// chrome no stylesheet reaches, so it drops a white system calendar over the
// dark Aero surface (and ignores every theme). This is a button that reads
// like an input, opening the catalog MiniCalendar in a Popover.
//
//   value     'yyyy-MM-dd' — or 'yyyy-MM-ddTHH:mm' when `time` is set (the
//             datetime-local shape, so existing callers keep their state as-is)
//   onChange  (string) => void, same shape as value; '' when cleared
//   min       lower bound in the same shape; earlier days are disabled
//   time      also render a time input next to the date
//   className applied to the trigger and the time input, so a caller's own
//             input look (underline, inset…) carries over
const DATE = 'yyyy-MM-dd';
const TIME = 'HH:mm';

const splitValue = (v = '') => ({ date: v.slice(0, 10), time: v.slice(11, 16) });
const parseDate = (s) => {
  if (!s) return null;
  const d = parse(s, DATE, new Date());
  return isValid(d) ? d : null;
};

export default function DateField({ value = '', onChange, min, time = false, className = '', placeholder = 'Pick a date', id, 'aria-label': ariaLabel, disabled }) {
  const [open, setOpen] = useState(false);
  const [rect, setRect] = useState(null);
  const triggerRef = useRef(null);
  const { date, time: clock } = splitValue(value);
  const selected = useMemo(() => parseDate(date), [date]);
  const minDate = useMemo(() => parseDate(splitValue(min).date), [min]);
  // The month on screen while browsing; snaps back to the value on open.
  const [view, setView] = useState(null);

  const emit = useCallback((nextDate, nextClock) => {
    if (!nextDate) { onChange?.(''); return; }
    onChange?.(time ? `${nextDate}T${nextClock || '00:00'}` : nextDate);
  }, [onChange, time]);

  const toggle = () => {
    if (disabled) return;
    if (!open) { setRect(triggerRef.current.getBoundingClientRect()); setView(selected || minDate || new Date()); }
    setOpen(o => !o);
  };
  const close = useCallback(() => { setOpen(false); triggerRef.current?.focus(); }, []);

  // Keyboard reach (F4): the selected (else today's) day takes focus when the
  // popover opens, so arrows/tab/enter work without a mouse.
  const popRef = useRef(null);
  useEffect(() => {
    if (!open) return;
    const id = requestAnimationFrame(() => {
      const el = popRef.current?.querySelector('[aria-pressed="true"]') || popRef.current?.querySelector('button:not(:disabled)');
      el?.focus();
    });
    return () => cancelAnimationFrame(id);
  }, [open]);

  // The Popover closes on any outside mousedown — the trigger included — so a
  // click on the trigger while open would close-then-reopen. Swallow that one.
  const onTriggerMouseDown = (e) => { if (open) e.preventDefault(); };

  return (
    <span className={styles.field}>
      <button
        ref={triggerRef}
        id={id}
        type="button"
        className={`${styles.trigger} ${className}`}
        onClick={toggle}
        onMouseDown={onTriggerMouseDown}
        aria-label={ariaLabel}
        aria-haspopup="dialog"
        aria-expanded={open}
        disabled={disabled}
      >
        <Icon name="calendar" size={12} />
        <span className={selected ? styles.value : styles.placeholder}>
          {selected ? format(selected, 'd MMM yyyy') : placeholder}
        </span>
      </button>
      {time && (
        <input
          type="time"
          className={`${styles.time} ${className}`}
          value={clock}
          disabled={disabled}
          aria-label={ariaLabel ? `${ariaLabel} time` : 'Time'}
          onChange={(e) => emit(date || format(new Date(), DATE), e.target.value)}
        />
      )}
      <Popover open={open} anchorRect={rect} onClose={close} className={styles.layer}>
        <div ref={popRef} className={styles.pop} role="dialog" aria-label="Choose a date">
          <MiniCalendar
            selectedDate={view}
            minDate={minDate}
            highlightVisible={false}
            onSelect={setView}
            onOpenDay={(day) => { emit(format(day, DATE), clock); close(); }}
          />
        </div>
      </Popover>
    </span>
  );
}

export { DATE as DATE_FORMAT, TIME as TIME_FORMAT };
