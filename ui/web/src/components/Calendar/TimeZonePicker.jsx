import { useState, useRef, useEffect, useMemo, useCallback } from 'react';
import Icon from '../Icon';
import useDismiss from '../../hooks/useDismiss';
import usePlannerStore from '../../stores/plannerStore';
import { LOCAL_TZ, abbrOf, cityOf, searchZones, shortOffset } from '../../lib/timeZones';
import styles from './TimeZonePicker.module.css';

export default function TimeZonePicker({ value, onChange }) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const rootRef = useRef(null);
  const inputRef = useRef(null);

  const overridden = value !== LOCAL_TZ;

  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  // Close on outside click / Escape.
  const close = useCallback(() => setOpen(false), []);
  useDismiss(rootRef, close, open);

  const matches = useMemo(() => searchZones(query), [query]);

  const pick = (tz) => { onChange(tz); setOpen(false); };

  return (
    <div className={styles.root} ref={rootRef}>
      <button
        type="button"
        className={`${styles.chip} ${overridden ? styles.overridden : ''}`}
        onClick={() => { setQuery(''); setOpen((o) => !o); }}
        title={`Times in ${value} (${abbrOf(value)}, ${shortOffset(value)})${overridden ? `. Your time zone is ${LOCAL_TZ}` : ', your time zone'}`}
      >
        {abbrOf(value)}
      </button>

      {open && (
        <div className={styles.panel}>
          <input
            ref={inputRef}
            className={styles.search}
            type="text"
            placeholder="Search timezone…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          <ul className={styles.list}>
            {!overridden ? null : (
              <li>
                <button type="button" className={styles.reset} onClick={() => pick(LOCAL_TZ)}>
                  ↺ Back to local ({cityOf(LOCAL_TZ)})
                </button>
              </li>
            )}
            {matches.map((tz) => (
              <li key={tz}>
                <button
                  type="button"
                  className={`${styles.option} ${tz === value ? styles.active : ''}`}
                  onClick={() => pick(tz)}
                >
                  <span className={styles.optCity}>{cityOf(tz)}</span>
                  <span className={styles.optZone}>
                    <span className={styles.optAbbr}>{abbrOf(tz)}</span>
                    {shortOffset(tz)}
                  </span>
                </button>
              </li>
            ))}
            {matches.length === 0 && <li className={styles.empty}>No match</li>}
          </ul>
          <button
            type="button"
            className={styles.plannerLink}
            onClick={() => { setOpen(false); usePlannerStore.getState().openPlanner(); }}
          >
            <Icon name="globe" size={13} /> Timezone planner
          </button>
        </div>
      )}
    </div>
  );
}
