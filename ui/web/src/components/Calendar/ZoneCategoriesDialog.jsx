import { useState } from 'react';
import Modal from '../Modal/Modal';
import Button from '../Button/Button';
import IconButton from '../IconButton';
import useZoneStore from '../../stores/zoneStore';
import { ZONE_COLORS, zoneColorVar } from '../../lib/zones';
import log from '../../lib/log';
import styles from './ZoneCategoriesDialog.module.css';

const tint = (color) => (el) => el?.style.setProperty('--zone', zoneColorVar(color));

/** One colour row: the six palette keys, the current one ringed. */
function Swatches({ value, onPick, label }) {
  return (
    <div className={styles.swatches} role="group" aria-label={label}>
      {ZONE_COLORS.map(color => (
        <button
          key={color}
          type="button"
          ref={tint(color)}
          className={`${styles.swatch} ${value === color ? styles.swatchOn : ''}`}
          aria-label={color}
          aria-pressed={value === color}
          onClick={() => onPick(color)}
        />
      ))}
    </div>
  );
}

function CategoryRow({ category }) {
  const updateCategory = useZoneStore(s => s.updateCategory);
  const deleteCategory = useZoneStore(s => s.deleteCategory);
  const [name, setName] = useState(category.name);
  const [confirming, setConfirming] = useState(false);

  const save = (params) => updateCategory(category.id, params)
    .catch((e) => log.warn('Zones', `category update failed: ${e?.message || e}`));

  return (
    <li className={styles.row} ref={tint(category.color)}>
      <span className={styles.dot} />
      <input
        className={styles.name}
        value={name}
        aria-label="Category name"
        onChange={(e) => setName(e.target.value)}
        onBlur={() => { if (name.trim() && name.trim() !== category.name) save({ name: name.trim() }); }}
        onKeyDown={(e) => { if (e.key === 'Enter') e.currentTarget.blur(); }}
      />
      <Swatches value={category.color} onPick={(color) => save({ color })} label={`${category.name} colour`} />
      {confirming ? (
        <span className={styles.confirm}>
          <Button variant="danger-link" onClick={() => deleteCategory(category.id).catch((e) => log.warn('Zones', `category delete failed: ${e?.message || e}`))}>Delete</Button>
          <Button variant="ghost" onClick={() => setConfirming(false)}>Keep</Button>
        </span>
      ) : (
        <IconButton icon="trash" size="sm" aria-label={`Delete ${category.name}`} onClick={() => setConfirming(true)} />
      )}
    </li>
  );
}

/**
 * Zone categories (docs/Calendar.md "Zones"): rename, recolour, add, delete.
 * Deleting one leaves its zones uncategorised — they keep their place on the
 * calendar, just in the default colour.
 */
export default function ZoneCategoriesDialog({ onClose }) {
  const categories = useZoneStore(s => s.categories);
  const createCategory = useZoneStore(s => s.createCategory);
  const [draft, setDraft] = useState({ name: '', color: 'teal' });

  const add = async () => {
    if (!draft.name.trim()) return;
    try {
      await createCategory({ name: draft.name.trim(), color: draft.color });
      setDraft({ name: '', color: draft.color });
    } catch (e) {
      log.warn('Zones', `category create failed: ${e?.message || e}`);
    }
  };

  return (
    <Modal open onClose={onClose} className={styles.panel}>
      <div className={styles.header}>
        <h2 className={styles.title}>Zone categories</h2>
        <p className={styles.subtitle}>A zone takes its colour from its category. Deleting one leaves its zones uncategorised.</p>
      </div>
      <ul className={styles.list}>
        {categories.map(c => <CategoryRow key={c.id} category={c} />)}
      </ul>
      <div className={styles.add} ref={tint(draft.color)}>
        <span className={styles.dot} />
        <input
          className={styles.name}
          value={draft.name}
          placeholder="New category"
          aria-label="New category name"
          onChange={(e) => setDraft({ ...draft, name: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Enter') add(); }}
        />
        <Swatches value={draft.color} onPick={(color) => setDraft({ ...draft, color })} label="New category colour" />
        <Button variant="secondary" onClick={add}>Add</Button>
      </div>
      <div className={styles.footer}>
        <Button onClick={onClose}>Done</Button>
      </div>
    </Modal>
  );
}
