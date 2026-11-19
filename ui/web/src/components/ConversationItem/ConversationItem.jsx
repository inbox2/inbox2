import { memo } from 'react'
import { motion } from 'motion/react'
import Avatar from '../Avatar'
import Icon from '../Icon'
import QuickActions from '../QuickActions'
import Tag from '../Tag'
import { TAG_PRESETS } from '../Tag/presets'
import styles from './ConversationItem.module.css'

function ConversationItem({ sender, subject, snippet, time, unread, tags, assignee, count, hasAttachment, quadrant, priority, viewers, folder, active, selected, onClick, onContextMenu, onHover, onHoverEnd, onForward, onMarkRead, onArchive, onTrash }) {
  const cls = [styles.item]
  if (active) cls.push(styles.active)
  if (unread) cls.push(styles.unread)
  if (selected) cls.push(styles.selected)

  return (
    <motion.div
      className={cls.join(' ')}
      // Exit (delete/archive/trash, incl. the Backspace shortcut): fade to 0 and
      // collapse the row's height so the list closes the gap smoothly. Kept on the
      // root (not a wrapper) so the .item sibling order — and :nth-child zebra
      // striping — is preserved. AnimatePresence in ConversationList drives it.
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
      <div className={styles.row}>
        {unread && <div className={styles.dot} />}
        {quadrant && (
          <span
            className={styles.triageChip}
            ref={(el) => { if (el) el.style.setProperty('--triage-color', quadrant.color) }}
          >
            <Icon name={quadrant.icon} size={12} className={styles.triageIcon} />
            <span className={styles.triagePop}>
              <Icon name={quadrant.icon} size={10} className={styles.triageIcon} />
              {quadrant.statusLabel || quadrant.label}
            </span>
          </span>
        )}
        <span className={styles.sender} dir="auto">{sender}</span>
        {count > 1 && <span className={styles.count}>{count}</span>}
        {!!hasAttachment && <Icon name="paperclip" size={11} className={styles.attachIcon} />}
        {folder && (
          <span className={styles.folderBadge}>
            <Icon name="tray.full" size={9} className={styles.folderIcon} />
            {folder}
          </span>
        )}
        {priority && (
          <span className={`${styles.priorityChip} ${styles[`priority_${priority.tone}`] || ''}`}>{priority.badge}</span>
        )}
        <span className={styles.time}>{time}</span>
      </div>
      <div className={styles.subject} dir="auto">{subject}</div>
      <div className={styles.snippet} dir="auto">{snippet}</div>
      {(tags?.length > 0 || assignee || viewers?.length > 0) && (
        <div className={styles.meta}>
          {tags?.map(t => {
            const preset = TAG_PRESETS[t.name.toLowerCase()] || {}
            return (
              <Tag key={t.name} bg={t.bg || preset.bg} fg={t.fg || preset.fg} variant={t.style}>
                {t.style === 'square' ? t.name.toUpperCase() : t.name}
              </Tag>
            )
          })}
          {assignee && <Avatar name={assignee} size={14} />}
          {viewers?.map(v => (
            <span key={v} className={styles.viewer}>
              <span className={styles.viewerDot} />viewing
            </span>
          ))}
        </div>
      )}
    </motion.div>
  )
}

export default memo(ConversationItem)
