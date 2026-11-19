import DropdownMenu from '../DropdownMenu/DropdownMenu';
import Icon from '../Icon';
import { PANE_MODE, PANE_MODE_ITEMS as ITEMS } from '../../hooks/usePaneMode';
import styles from './PaneMode.module.css';

// The Rider-style three-way pane mode picker + the edge strip a non-pinned
// pane collapses to. `pane` is a usePaneMode() result.

// `trigger` overrides the quiet default button (the reading pane passes a
// full ToolbarButton so it sits level with Reply/Archive).
export function PaneModeMenu({ pane, icon = 'ellipsis', label, align = 'right', direction, className, trigger }) {
  return (
    <DropdownMenu
      align={align}
      direction={direction}
      value={pane.mode}
      items={ITEMS.map((i) => ({ ...i, onSelect: () => pane.setMode(i.value) }))}
      trigger={trigger || (
        <button type="button" className={`${styles.button} ${className || ''}`} title={label} aria-label={label}>
          <Icon name={icon} size={icon === 'ellipsis' ? 12 : 14} />
        </button>
      )}
    />
  );
}

// Floating: the strip button pops the pane. Hidden: it opens the mode menu —
// the only way back, by design.
export function PaneStrip({ pane, icon, label, align }) {
  return (
    <div className={styles.strip} data-pane-strip>
      {pane.mode === PANE_MODE.HIDDEN ? (
        <PaneModeMenu pane={pane} icon={icon} label={label} align={align} className={styles.stripButton} />
      ) : (
        <button
          type="button"
          className={`${styles.button} ${styles.stripButton}`}
          onClick={() => pane.setOpen((o) => !o)}
          title={label}
          aria-label={label}
          aria-expanded={pane.open}
        >
          <Icon name={icon} size={14} />
        </button>
      )}
    </div>
  );
}
