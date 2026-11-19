import { useState } from 'react';
import { addDays, format } from 'date-fns';
import Modal from '../Modal/Modal';
import Button from '../Button/Button';
import Switch from '../Switch/Switch';
import Icon from '../Icon';
import ConfirmDialog from '../ConfirmDialog/ConfirmDialog';
import DateField from '../DateField/DateField';
import useZoneStore from '../../stores/zoneStore';
import { MAX_ZONE_MS, ZONE_COLORS, ZONE_REPEATS, zoneColorVar } from '../../lib/zones';
import ZoneCategoriesDialog from './ZoneCategoriesDialog';
import log from '../../lib/log';
import styles from './ZoneEditor.module.css';

const tint = (color) => (el) => el?.style.setProperty('--zone', zoneColorVar(color));

// Local wall-clock parts <-> ISO. The end time is read on the start's date, or
// the next day when it isn't after the start (22:00–02:00 runs overnight).
const toParts = (iso) => {
  const d = new Date(iso);
  return { date: format(d, 'yyyy-MM-dd'), time: format(d, 'HH:mm') };
};
const toIso = (date, time) => new Date(`${date}T${time}`).toISOString();

/**
 * Create or edit a calendar zone (docs/Calendar.md "Zones"): a soft focus
 * block that never marks you busy. `zone` edits one; `defaults` ({start_at,
 * end_at}) prefills a new one from a drag on the grid.
 */
export default function ZoneEditor({ zone, defaults, onClose }) {
  const categories = useZoneStore(s => s.categories);
  const createZone = useZoneStore(s => s.createZone);
  const updateZone = useZoneStore(s => s.updateZone);
  const deleteZone = useZoneStore(s => s.deleteZone);
  const createCategory = useZoneStore(s => s.createCategory);

  // A new zone with nothing to go on starts now and runs an hour.
  const [{ start, end }] = useState(() => {
    const seed = zone || defaults || {};
    const now = Date.now();
    return {
      start: toParts(seed.start_at || new Date(now).toISOString()),
      end: toParts(seed.end_at || new Date(now + 3600000).toISOString()),
    };
  });

  const [name, setName] = useState(zone?.name || '');
  const [note, setNote] = useState(zone?.note || '');
  const [categoryId, setCategoryId] = useState(zone ? zone.category_id : (categories[0]?.id ?? null));
  const [date, setDate] = useState(start.date);
  const [startTime, setStartTime] = useState(start.time);
  const [endTime, setEndTime] = useState(end.time);
  const [notify, setNotify] = useState(zone ? zone.notify : true);
  const [blocks, setBlocks] = useState(zone ? !!zone.blocks : false);
  const [repeat, setRepeat] = useState(zone?.repeat || 'none');
  const [repeatUntil, setRepeatUntil] = useState(zone?.repeat_until || '');
  const [managing, setManaging] = useState(false);
  const repeating = zone && zone.repeat && zone.repeat !== 'none';
  const [newCat, setNewCat] = useState(null); // { name, color } while adding one
  const [error, setError] = useState(null);
  const [saving, setSaving] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const startIso = date && startTime ? toIso(date, startTime) : null;
  const sameDayEnd = date && endTime ? Date.parse(toIso(date, endTime)) : null;
  const overnight = startIso && sameDayEnd != null && sameDayEnd <= Date.parse(startIso);
  // Next *calendar* day, rebuilt from the date — not +24h, which is 23 or 25
  // hours on a DST night.
  const endIso = sameDayEnd == null ? null
    : overnight ? toIso(format(addDays(new Date(`${date}T00:00`), 1), 'yyyy-MM-dd'), endTime)
      : new Date(sameDayEnd).toISOString();
  const minutes = startIso && endIso ? Math.round((Date.parse(endIso) - Date.parse(startIso)) / 60000) : 0;
  const length = minutes >= 60
    ? `${Math.floor(minutes / 60)}h${minutes % 60 ? ` ${minutes % 60}m` : ''}`
    : minutes > 0 ? `${minutes}m` : '';

  const save = async () => {
    if (!name.trim()) { setError('Give the zone a name.'); return; }
    if (minutes <= 0 || minutes * 60000 > MAX_ZONE_MS) { setError('A zone runs for up to 24 hours.'); return; }
    setSaving(true);
    const params = {
      name: name.trim(), note: note.trim() || null, category_id: categoryId, start_at: startIso, end_at: endIso, notify, blocks,
      repeat, repeat_until: repeat !== 'none' && repeatUntil ? repeatUntil : null,
    };
    // Its own zone, so "weekdays 16:00" keeps meaning 16:00 here across DST.
    if (!zone) params.time_zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    // A prep zone moved by hand stops following its meeting — otherwise the
    // next calendar load would snap it straight back.
    if (zone?.anchor_event_id && (startIso !== new Date(zone.start_at).toISOString() || endIso !== new Date(zone.end_at).toISOString())) {
      params.anchor_event_id = null;
      params.anchor_minutes = null;
    }
    try {
      // An occurrence id retimes the whole series by the same amount (API).
      if (zone) await updateZone(zone.id, params);
      else await createZone(params);
      onClose();
    } catch (e) {
      log.warn('Zones', `save failed: ${e?.message || e}`);
      setError('Couldn’t save the zone. Try again.');
      setSaving(false);
    }
  };

  const addCategory = async () => {
    if (!newCat?.name.trim()) return;
    try {
      const cat = await createCategory({ name: newCat.name.trim(), color: newCat.color });
      if (cat) setCategoryId(cat.id);
      setNewCat(null);
    } catch (e) {
      log.warn('Zones', `category create failed: ${e?.message || e}`);
    }
  };

  return (
    // While the category manager is up, Escape/overlay belong to it alone.
    <Modal open onClose={managing ? () => {} : onClose} className={styles.panel}>
      <div className={styles.header}>
        <h2 className={styles.title}>{zone ? 'Edit zone' : 'New zone'}</h2>
        <p className={styles.subtitle}>
          {blocks ? 'Marks time on your calendar. People see you as busy.' : 'Marks time on your calendar. People can still book it.'}
        </p>
      </div>

      <div className={styles.body}>
        <label className={styles.field}>
          <span className={styles.label}>Name</span>
          <input
            className={styles.input}
            value={name}
            onChange={(e) => { setName(e.target.value); setError(null); }}
            placeholder="Project Atlas"
            autoFocus
          />
        </label>

        <div className={styles.field}>
          <span className={styles.label} id="zone-category-label">Category</span>
          <div className={styles.chips} role="group" aria-labelledby="zone-category-label">
            {categories.map(c => (
              <button
                key={c.id}
                type="button"
                ref={tint(c.color)}
                className={`${styles.chip} ${categoryId === c.id ? styles.chipOn : ''}`}
                aria-pressed={categoryId === c.id}
                onClick={() => setCategoryId(c.id)}
              >
                <span className={styles.dot} />
                {c.name}
              </button>
            ))}
            {!newCat && (
              <button type="button" className={styles.chipAdd} onClick={() => setNewCat({ name: '', color: 'teal' })}>
                <Icon name="plus" size={11} />
                Category
              </button>
            )}
            <button type="button" className={styles.manage} onClick={() => setManaging(true)}>Edit categories…</button>
          </div>
          {newCat && (
            <div className={styles.newCat}>
              <input
                className={styles.input}
                value={newCat.name}
                onChange={(e) => setNewCat({ ...newCat, name: e.target.value })}
                onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); addCategory(); } }}
                placeholder="Category name"
                aria-label="New category name"
                autoFocus
              />
              <div className={styles.swatches} role="group" aria-label="Category colour">
                {ZONE_COLORS.map(color => (
                  <button
                    key={color}
                    type="button"
                    ref={tint(color)}
                    className={`${styles.swatch} ${newCat.color === color ? styles.swatchOn : ''}`}
                    aria-label={color}
                    aria-pressed={newCat.color === color}
                    onClick={() => setNewCat({ ...newCat, color })}
                  />
                ))}
              </div>
              <Button variant="secondary" onClick={addCategory}>Add</Button>
              <Button variant="ghost" onClick={() => setNewCat(null)}>Cancel</Button>
            </div>
          )}
        </div>

        <div className={styles.field}>
          <span className={styles.label}>When</span>
          <div className={styles.when}>
            <DateField className={styles.input} aria-label="Date" value={date} onChange={(v) => { setDate(v); setError(null); }} />
            <input type="time" className={styles.input} aria-label="Starts" value={startTime} onChange={(e) => { setStartTime(e.target.value); setError(null); }} />
            <span className={styles.dash}>–</span>
            <input type="time" className={styles.input} aria-label="Ends" value={endTime} onChange={(e) => { setEndTime(e.target.value); setError(null); }} />
            {length && <span className={styles.length}>{length}{overnight ? ' · ends next day' : ''}</span>}
          </div>
          <div className={styles.when}>
            <select className={styles.input} aria-label="Repeat" value={repeat} onChange={(e) => setRepeat(e.target.value)}>
              {ZONE_REPEATS.map(r => <option key={r.key} value={r.key}>{r.label}</option>)}
            </select>
            {repeat !== 'none' && (
              <label className={styles.until}>
                <span>until</span>
                <DateField className={styles.input} aria-label="Repeat until" value={repeatUntil} min={date} onChange={setRepeatUntil} />
              </label>
            )}
          </div>
          {repeating && <span className={styles.hint}>Changes apply to every repeat of this zone.</span>}
        </div>

        <label className={styles.field}>
          <span className={styles.label}>What you’ll work on <span className={styles.optional}>(optional)</span></span>
          <textarea className={styles.textarea} rows={2} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Ship the onboarding flow draft" />
        </label>

        <div className={styles.toggles}>
          <Switch
            id="zone-notify"
            label="Show the zone card when it starts"
            description="Stays on screen until you dismiss it"
            checked={notify}
            onChange={setNotify}
          />
          <Switch
            id="zone-blocks"
            label="Block this time"
            description="Meet links and colleagues see you as busy"
            checked={blocks}
            onChange={setBlocks}
          />
        </div>

        {error && <div className={styles.error} role="alert">{error}</div>}
      </div>

      <div className={styles.footer}>
        {zone && (
          <Button variant="danger-link" className={styles.delete} onClick={() => setConfirmDelete(true)}>{repeating ? 'Delete all repeats' : 'Delete zone'}</Button>
        )}
        <Button variant="secondary" onClick={onClose}>Cancel</Button>
        <Button onClick={save} disabled={saving}>{zone ? 'Save' : 'Create zone'}</Button>
      </div>

      <ConfirmDialog
        open={confirmDelete}
        title={repeating ? 'Delete every repeat?' : 'Delete this zone?'}
        message={repeating
          ? `“${zone?.name}” will be removed from every day it repeats on.`
          : `“${zone?.name}” will be removed from your calendar.`}
        confirmLabel="Delete"
        onCancel={() => setConfirmDelete(false)}
        onConfirm={async () => {
          try { await deleteZone(zone); onClose(); }
          catch (e) { log.warn('Zones', `delete failed: ${e?.message || e}`); setConfirmDelete(false); }
        }}
      />
      {managing && <ZoneCategoriesDialog onClose={() => setManaging(false)} />}
    </Modal>
  );
}
