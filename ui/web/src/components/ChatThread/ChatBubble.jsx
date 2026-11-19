import { memo } from 'react'
import Avatar from '../Avatar'
import Icon from '../Icon'
import formatBytes from '../../lib/formatBytes'
import { handleAnchorClick } from '../../lib/openLink'
import MediaAttachment from './MediaAttachment'
import styles from './ChatThread.module.css'

// A single chat message bubble. Aligns by `isInbound` (inbound left/neutral,
// outbound right/brand-accent). No collapse, no actions menu, no email header —
// this is the chat counterpart to MessageCard. `bodyHtml` is pre-escaped +
// linkified by ChatThread, so it's safe to inject.
function ChatBubble({ onOpenMedia, deleted, rowId, bodyHtml, isInbound, time, senderName, senderLabel, avatarSrc, showAvatar, isDraft, pending, attachments, reaction, enriching, focused }) {
  const cls = [styles.row, isInbound ? styles.inbound : styles.outbound]
  if (focused) cls.push(styles.focused)
  if (pending) cls.push(styles.pending)
  // Typed media (local WhatsApp) sits above the caption, WhatsApp-style; the
  // older plain attachments (Meta) keep their chips below the text.
  const media = (attachments || []).filter(a => a.kind)
  const plain = (attachments || []).filter(a => !a.kind)
  // A lone sticker has no bubble behind it; media with no text hugs its frame.
  const bubbleCls = [styles.bubble]
  if (media.length === 1 && media[0].kind === 'sticker' && !bodyHtml) bubbleCls.push(styles.bubbleBare)
  else if (media.length > 0) bubbleCls.push(styles.bubbleMedia)
  return (
    <div className={cls.join(' ')} data-chat-bubble data-row-id={rowId}>
      {isInbound && (
        <div className={styles.gutter}>
          {showAvatar && <Avatar name={senderName} src={avatarSrc} size={28} />}
        </div>
      )}
      <div className={styles.bubbleWrap}>
        <div className={bubbleCls.join(' ')} role="presentation" onClick={handleAnchorClick}>
          {senderLabel && <div className={styles.senderLabel} dir="auto">{senderLabel}</div>}
          {media.length > 0 && (
            <div className={styles.mediaStack}>
              {media.map(a => <MediaAttachment key={a.attachmentId} a={a} onOpen={onOpenMedia} />)}
            </div>
          )}
          {bodyHtml
            ? <div className={deleted ? `${styles.text} ${styles.deleted}` : styles.text} dangerouslySetInnerHTML={{ __html: bodyHtml }} />
            : (media.length === 0 && <div className={styles.text}>{enriching ? '…' : ''}</div>)}
          {plain.length > 0 && (
            <div className={styles.attachments}>
              {plain.map((a, i) => {
                const isImg = (a.mimeType || '').startsWith('image/') && a.url
                const key = a.attachmentId || i
                if (isImg && a.onOpen) {
                  return (
                    <button key={key} type="button" className={styles.attachImgBtn} onClick={a.onOpen} aria-label={`Open ${a.name || 'image'}`}>
                      <img src={a.url} alt={a.name} className={styles.attachImg} />
                    </button>
                  )
                }
                if (isImg) return <img key={key} src={a.url} alt={a.name} className={styles.attachImg} />
                const chip = (
                  <>
                    <Icon name={a.icon || 'paperclip'} size={11} />
                    <span className={styles.attachName}>{a.name}</span>
                    {a.size != null && <span className={styles.attachSize}>{formatBytes(a.size)}</span>}
                  </>
                )
                return a.onOpen
                  ? <button key={key} type="button" className={`${styles.attachChip} ${styles.attachChipBtn}`} onClick={a.onOpen}>{chip}</button>
                  : <span key={key} className={styles.attachChip}>{chip}</span>
              })}
            </div>
          )}
          {/* Time tucked into the bubble's trailing corner (WhatsApp-style). */}
          <span className={styles.time}>
            {isDraft && <span className={styles.draftTag}>Draft</span>}
            {pending ? 'Sending…' : time}
          </span>
          {reaction && <span className={styles.reaction}>{reaction}</span>}
        </div>
      </div>
    </div>
  )
}

export default memo(ChatBubble)
