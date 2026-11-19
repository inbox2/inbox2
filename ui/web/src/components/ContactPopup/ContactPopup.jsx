import Avatar from '../Avatar'
import Icon from '../Icon'
import Popover from '../Popover/Popover'
import styles from './ContactPopup.module.css'

/**
 * Hover/click contact card for an email address.
 *
 * Two render modes:
 *   - Anchored: pass `anchorRect` (and usually `onClose`) and the card portals
 *     to <body>, anchored below the rect via <Popover>.
 *   - Inline: omit `anchorRect` and the card renders in place; the caller owns
 *     positioning via `className` (e.g. an absolutely-positioned wrapper) and
 *     dismissal. Used by Storybook and any caller that wants its own layout.
 */
export default function ContactPopup({
  name,
  email,
  onSendEmail,
  onCopyEmail,
  onViewSender,
  anchorRect,
  onClose,
  className,
  onMouseEnter,
  onMouseLeave,
}) {
  const card = (
    <>
      <div className={styles.header}>
        <Avatar name={name || email} email={email} size={32} />
        <div>
          <div className={styles.name}>{name}</div>
          <div className={styles.email}>{email}</div>
        </div>
      </div>
      <div className={styles.actions}>
        {onCopyEmail && (
          <button className={styles.action} onClick={onCopyEmail}>
            <Icon name="doc" size={12} /> Copy email
          </button>
        )}
        {onViewSender && (
          <button className={styles.action} onClick={onViewSender}>
            <Icon name="magnifyingglass" size={12} /> View all messages
          </button>
        )}
      </div>
      {onSendEmail && (
        <div className={styles.footer}>
          <button className={styles.footerBtn} onClick={onSendEmail}>
            <Icon name="paperplane" size={11} />
            Send email
          </button>
        </div>
      )}
    </>
  )

  // Anchored mode — portal + viewport-clamped placement via <Popover>.
  // Outside-click is left to the caller (which also drives hover-leave timing),
  // so we only let <Popover> handle Escape here.
  if (anchorRect) {
    return (
      <Popover
        open
        anchorRect={anchorRect}
        placement="bottom"
        onClose={onClose}
        closeOnOutsideClick={false}
        className={`${styles.popup} ${className || ''}`}
        data-contact-popup=""
        onMouseEnter={onMouseEnter}
        onMouseLeave={onMouseLeave}
      >
        {card}
      </Popover>
    )
  }

  // Inline mode — caller positions the card.
  return (
    <div
      className={`${styles.popup} ${className || ''}`}
      role="presentation"
      onMouseEnter={onMouseEnter}
      onMouseLeave={onMouseLeave}
    >
      {card}
    </div>
  )
}
