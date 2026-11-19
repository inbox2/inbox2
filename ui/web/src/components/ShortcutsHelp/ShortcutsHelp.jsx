import Modal from '../Modal/Modal';
import Icon from '../Icon';
import { SHORTCUTS, CATEGORY_ORDER, formatShortcut } from '../../lib/shortcuts';
import styles from './ShortcutsHelp.module.css';

/**
 * Keyboard shortcuts reference overlay (opened with `?`).
 * Lists every entry in the registry grouped by category — the registry is the
 * single source of truth, so this stays in sync automatically.
 */
export default function ShortcutsHelp({ open, onClose }) {
  const groups = CATEGORY_ORDER
    .map(category => ({ category, items: SHORTCUTS.filter(s => s.category === category) }))
    .filter(g => g.items.length > 0);

  return (
    <Modal open={open} onClose={onClose} className={styles.panel}>
      <h2 className={styles.title}>Keyboard shortcuts</h2>
      <div className={styles.groups}>
        {groups.map(group => (
          <section key={group.category} className={styles.group}>
            <h3 className={styles.groupTitle}>{group.category}</h3>
            <ul className={styles.list}>
              {group.items.map(item => (
                <li key={item.id} className={styles.row}>
                  <span className={styles.label}>
                    {item.icon && <Icon name={item.icon} size={13} className={styles.rowIcon} />}
                    {item.label}
                  </span>
                  <kbd className={styles.key}>{formatShortcut(item.display)}</kbd>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    </Modal>
  );
}
