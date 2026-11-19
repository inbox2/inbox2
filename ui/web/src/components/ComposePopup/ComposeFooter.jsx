import { ToolbarButton } from '../ToolbarGroup'
import Button from '../Button/Button'
import Tooltip from '../Tooltip'
import Icon from '../Icon'
import styles from './ComposeFooter.module.css'

export default function ComposeFooter({ saveStatus, sending, sendError, onSend, onDiscard, sendDisabled = false, sendDisabledTitle }) {
  const statusLabel = {
    saved: 'Saved',
    saving: 'Saving...',
    unsaved: 'Unsaved',
    error: 'Save failed',
  }

  const sendButton = (
    <Button variant={sendDisabled ? 'secondary' : undefined} onClick={onSend} disabled={sending || sendDisabled}>
      <Icon name="paperplane.fill" size={14} />
      {sending ? 'Sending…' : 'Send'}
    </Button>
  )

  return (
    <div className={styles.footer}>
      <div className={styles.left}>
        {sendError ? (
          <span className={styles.sendError} role="alert">
            <Icon name="exclamationmark.triangle.fill" size={12} />
            {sendError}
          </span>
        ) : (
          <span className={styles.status}>
            {saveStatus === 'saved' && <Icon name="checkmark.circle" size={12} />}
            {statusLabel[saveStatus] || ''}
          </span>
        )}
      </div>
      <div className={styles.right}>
        <ToolbarButton icon="trash" onClick={onDiscard} disabled={sending}>Discard</ToolbarButton>
        {sendDisabled && sendDisabledTitle
          ? <Tooltip content={sendDisabledTitle}>{sendButton}</Tooltip>
          : sendButton}
      </div>
    </div>
  )
}
