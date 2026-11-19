import Icon from '../Icon'
import styles from './DraftBar.module.css'

export default function DraftPill({ draft, onRestore, onClose }) {
  const label = draft.subject || draft.toAddress || 'New message'

  return (
    <button
      className={styles.pill}
      onClick={onRestore}
      onKeyDown={e => {
        if (e.key === 'Delete' || e.key === 'Backspace') {
          e.preventDefault()
          onClose()
        }
      }}
      title={label}
    >
      <Icon name="square.and.pencil" size={12} />
      <span className={styles.pillLabel}>{label}</span>
      <button
        className={styles.pillClose}
        onClick={e => {
          e.stopPropagation()
          onClose()
        }}
        aria-label={`Close draft: ${label}`}
        tabIndex={-1}
      >
        <Icon name="xmark" size={10} />
      </button>
    </button>
  )
}
