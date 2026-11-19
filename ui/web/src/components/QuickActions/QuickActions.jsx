import Icon from '../Icon'
import styles from './QuickActions.module.css'

/**
 * Hover quick-actions for a conversation row — Forward, Mark read/unread,
 * Archive, Trash. Shared across ConversationItem (inbox), EmailCard + MiniCard
 * (unified inbox).
 *
 * The parent owns positioning + the hover reveal (opacity) via `className`;
 * this component owns the button visuals and event isolation. It stops pointer
 * and click propagation so a button press neither selects/opens the row nor
 * starts a dnd-kit drag (EmailCard/MiniCard are draggables).
 */
export default function QuickActions({ unread, onForward, onMarkRead, onArchive, onTrash, className }) {
  if (!onForward && !onMarkRead && !onArchive && !onTrash) return null

  const fire = (handler) => (e) => {
    e.stopPropagation()
    e.preventDefault()
    handler?.()
  }
  const stop = (e) => e.stopPropagation()

  return (
    <div
      className={[styles.bar, className].filter(Boolean).join(' ')}
      role="presentation"
      onPointerDown={stop}
      onMouseDown={stop}
      onClick={stop}
    >
      {onForward && (
        <button
          type="button"
          className={`${styles.btn} ${styles.colorTeal}`}
          title="Forward"
          aria-label="Forward"
          onClick={fire(onForward)}
        >
          <Icon name="arrowshape.turn.up.right" size={13} />
        </button>
      )}
      {onMarkRead && (
        <button
          type="button"
          className={`${styles.btn} ${styles.colorBlue}`}
          title={unread ? 'Mark as read' : 'Mark as unread'}
          aria-label={unread ? 'Mark as read' : 'Mark as unread'}
          onClick={fire(onMarkRead)}
        >
          <Icon name={unread ? 'envelope.open' : 'envelope.badge'} size={13} />
        </button>
      )}
      {onArchive && (
        <button
          type="button"
          className={`${styles.btn} ${styles.colorRose}`}
          title="Archive"
          aria-label="Archive"
          onClick={fire(onArchive)}
        >
          <Icon name="archivebox" size={13} />
        </button>
      )}
      {onTrash && (
        <button
          type="button"
          className={`${styles.btn} ${styles.colorRed}`}
          title="Move to trash"
          aria-label="Move to trash"
          onClick={fire(onTrash)}
        >
          <Icon name="trash" size={13} />
        </button>
      )}
    </div>
  )
}
