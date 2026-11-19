import { useRef, useEffect, memo } from 'react'
import { motion } from 'motion/react'
import Icon from '../Icon'
import ChannelAvatar from '../ChannelAvatar/ChannelAvatar'
import QuickActions from '../QuickActions'
import { META_KIND, CHANNEL_BRAND, NEUTRAL_BRAND } from '../../lib/providerTypes'
import styles from './SocialListRow.module.css'

// Per-kind badge shown before the preview text (comments/mentions are public
// post replies, not DMs — the glyphs mirror the Comments/Mentions folder views).
const KIND_BADGE = {
  [META_KIND.COMMENT]: { icon: 'bubble.left.fill', label: 'Comment' },
  [META_KIND.MENTION]: { icon: 'at', label: 'Mention' },
}

// A platform-style conversation row for social channels: large round avatar with
// a channel glyph, sender + time, and a single last-message preview line. Shares
// the same callback surface as ConversationItem so the list wiring is unchanged.
function SocialListRow({
  sender, avatar, channel, kind, preview, time, unread, count, pinned,
  active, selected, onClick, onContextMenu, onHover, onHoverEnd,
  onForward, onMarkRead, onArchive, onTrash,
}) {
  const cls = [styles.item]
  if (active) cls.push(styles.active)
  if (unread) cls.push(styles.unread)
  if (selected) cls.push(styles.selected)

  const brand = CHANNEL_BRAND[channel] || NEUTRAL_BRAND
  const badge = KIND_BADGE[kind]

  // Brand accent on the avatar's channel ring — set via a custom property so no
  // inline styles are emitted (ESLint bans style={{}}).
  const rootRef = useRef(null)
  useEffect(() => {
    if (rootRef.current) rootRef.current.style.setProperty('--brand-accent', brand.accent)
  }, [brand.accent])

  return (
    <motion.div
      ref={rootRef}
      className={cls.join(' ')}
      exit={{ opacity: 0, height: 0, paddingTop: 0, paddingBottom: 0 }}
      transition={{ duration: 0.22, ease: [0.16, 1, 0.3, 1] }}
      onClick={onClick}
      onContextMenu={(e) => { e.preventDefault(); if (onContextMenu) onContextMenu(e); }}
      onMouseEnter={onHover}
      onMouseLeave={onHoverEnd}
    >
      <QuickActions
        className={styles.quickActions}
        unread={unread}
        onForward={onForward}
        onMarkRead={onMarkRead}
        onArchive={onArchive}
        onTrash={onTrash}
      />
      <ChannelAvatar name={sender} src={avatar} brand={brand} size={37} badgeSize={20} unread={unread} />
      <div className={styles.body}>
        <div className={styles.topRow}>
          <span className={styles.sender} dir="auto">{sender}</span>
          {count > 1 && <span className={styles.count}>{count}</span>}
          <span className={styles.time}>{time}</span>
        </div>
        <div className={styles.preview}>
          {badge && (
            <span className={styles.kindBadge} title={badge.label}>
              <Icon name={badge.icon} size={11} className={styles.kindIcon} />
            </span>
          )}
          <span className={styles.previewText} dir="auto">{preview}</span>
          {pinned && <span className={styles.pin} title="Pinned"><Icon name="pin.fill" size={12} /></span>}
          {unread && <span className={styles.dot} />}
        </div>
      </div>
    </motion.div>
  )
}

export default memo(SocialListRow)
