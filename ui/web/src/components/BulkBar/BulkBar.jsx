import { MgmtButton } from '../management'
import { ActionIcon } from '../FileTypeIcon'
import styles from './BulkBar.module.css'

/**
 * Selection bar that replaces the page actions while items are selected (spec F2).
 * Renders nothing at count 0.
 *
 *   count    number selected
 *   actions  [{ label, icon (ActionIcon name), onSelect, primary?, danger? }]
 *   onClear  clears the selection
 */
export default function BulkBar({ count, actions, onClear }) {
  if (!count) return null
  return (
    <div className={styles.bar} role="toolbar" aria-label="Selected items">
      <b className={styles.count} role="status">{count} selected</b>
      {actions.map((a) => (
        <MgmtButton key={a.label} size="sm" variant={a.danger ? 'danger' : a.primary ? 'dark' : 'glass'} onClick={a.onSelect}>
          {a.icon && <ActionIcon name={a.icon} />}
          {a.label}
        </MgmtButton>
      ))}
      <MgmtButton size="sm" variant="glass" aria-label="Clear selection" onClick={onClear}>
        <ActionIcon name="x" />
      </MgmtButton>
    </div>
  )
}
