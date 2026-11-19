import { useEffect, useMemo, useState } from 'react';
import { format } from 'date-fns';
import Checkbox from '../Checkbox/Checkbox';
import IconButton from '../IconButton';
import ZoneCategoriesDialog from './ZoneCategoriesDialog';
import useZoneStore from '../../stores/zoneStore';
import { categoryFor, isActive, progress, remaining, zoneColorVar } from '../../lib/zones';
import side from './CalendarSidebar.module.css';
import styles from './ZoneSection.module.css';

const tint = (color) => (el) => el?.style.setProperty('--zone', zoneColorVar(color));

/**
 * The calendar sidebar's Zones block (docs/Calendar.md "Zones"): the zone
 * running now with its countdown, the next few, and a show/hide per category.
 */
export default function ZoneSection({ onNewZone, onZoneClick }) {
  const zones = useZoneStore(s => s.zones);
  const categories = useZoneStore(s => s.categories);
  const hidden = useZoneStore(s => s.hiddenCategoryIds);
  const toggleCategory = useZoneStore(s => s.toggleCategory);

  const [managing, setManaging] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 30000);
    return () => clearInterval(t);
  }, []);

  const current = zones.find(z => isActive(z, now)) || null;
  const next = useMemo(
    () => zones.filter(z => Date.parse(z.start_at) > now).slice(0, 3),
    [zones, now]
  );
  const counts = useMemo(() => {
    const m = new Map();
    // Distinct zones, not days: a weekday zone counts once.
    const seen = new Set();
    for (const z of zones) {
      if (Date.parse(z.end_at) <= now || seen.has(z.series_id)) continue;
      seen.add(z.series_id);
      m.set(z.category_id, (m.get(z.category_id) || 0) + 1);
    }
    return m;
  }, [zones, now]);

  const currentCat = current ? categoryFor(current, categories) : null;

  return (
    <div className={side.section}>
      <div className={`${side.sectionTitle} ${styles.titleRow}`}>
        <span>Zones</span>
        <span className={styles.titleActions}>
          <IconButton icon="gear" size={20} iconSize={11} className={styles.headerBtn} onClick={() => setManaging(true)} aria-label="Zone categories" />
          <IconButton icon="plus" size={20} iconSize={11} className={styles.headerBtn} onClick={onNewZone} aria-label="New zone" />
        </span>
      </div>

      {current && (
        <button type="button" className={styles.now} ref={tint(currentCat?.color)} onClick={() => onZoneClick(current)}>
          <span className={styles.nowLabel}>
            <span className={styles.dot} />
            {currentCat?.name || 'Zone'} · in the zone
          </span>
          <span className={styles.nowName}>{current.name}</span>
          <span className={styles.nowClock}>
            <span className={styles.nowLeft}>{remaining(current, now)} left</span>
            <span className={styles.nowUntil}>until {format(new Date(current.end_at), 'HH:mm')}</span>
          </span>
          <span className={styles.track}>
            <span className={styles.fill} ref={(el) => el?.style.setProperty('--zone-progress', `${Math.round(progress(current, now) * 100)}%`)} />
          </span>
        </button>
      )}

      {next.map(z => {
        const cat = categoryFor(z, categories);
        return (
          <button key={z.id} type="button" className={styles.upcoming} ref={tint(cat?.color)} onClick={() => onZoneClick(z)}>
            <span className={styles.swatch} />
            <span className={styles.upcomingName}>{z.name}</span>
            <span className={styles.upcomingWhen}>{format(new Date(z.start_at), 'EEE HH:mm')}</span>
          </button>
        );
      })}

      {categories.map(c => (
        <div key={c.id} className={side.calendarItem} role="presentation" onClick={() => toggleCategory(c.id)}>
          {/* ponytail: readOnly — the row's onClick toggles, same as the calendar rows above */}
          <Checkbox checked={!hidden.has(c.id)} readOnly aria-label={`Show ${c.name} zones`} />
          <span className={styles.swatch} ref={tint(c.color)} />
          <span className={side.calendarName}>{c.name}</span>
          {counts.get(c.id) > 0 && <span className={styles.count}>{counts.get(c.id)}</span>}
        </div>
      ))}
      {managing && <ZoneCategoriesDialog onClose={() => setManaging(false)} />}
    </div>
  );
}
