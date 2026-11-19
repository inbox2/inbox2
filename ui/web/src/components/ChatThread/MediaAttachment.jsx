import { memo, useEffect, useRef, useState } from 'react'
import Icon from '../Icon'
import FileTypeIcon from '../FileTypeIcon'
import formatBytes from '../../lib/formatBytes'
import { MEDIA, duration } from '../../lib/waMessages'
import styles from './ChatThread.module.css'

/**
 * One typed attachment inside a chat bubble (local WhatsApp, lib/waMessages
 * `MEDIA`): photos, stickers, GIFs, videos, voice notes, documents, link
 * previews, and media that never reached this Mac. Clicking opens the media
 * viewer (`onOpen(a)`). Space is reserved at the media's own aspect ratio, so a
 * thread doesn't jump as pictures load. Nothing here drags: an <img> or button
 * dragged in the feed would only show the browser's ghost image.
 */
function MediaAttachment({ a, onOpen }) {
  const ref = useRef(null)
  useEffect(() => {
    if (a.aspect > 0) ref.current?.style.setProperty('--aspect', String(a.aspect))
  }, [a.aspect])
  const noDrag = { draggable: false }
  const open = !a.missing && onOpen ? () => onOpen(a) : undefined

  switch (a.kind) {
    case MEDIA.IMAGE:
    case MEDIA.VIDEO:
    case MEDIA.GIF: {
      const label = a.kind === MEDIA.IMAGE ? 'photo' : a.kind === MEDIA.GIF ? 'GIF' : 'video'
      const picture = a.kind === MEDIA.GIF
        ? <video className={styles.mediaImg} src={a.url} autoPlay loop muted playsInline />
        : <img className={styles.mediaImg} src={a.kind === MEDIA.VIDEO ? a.thumbUrl : a.url} alt="" loading="lazy" draggable={false} />
      const inner = (
        <>
          {(a.kind !== MEDIA.VIDEO || a.thumbUrl) ? picture : <span className={styles.mediaBlank} />}
          {a.kind === MEDIA.VIDEO && (
            <>
              <span className={styles.play} aria-hidden="true"><Icon name="play.fill" size={18} /></span>
              {a.duration > 0 && <span className={styles.mediaBadge}>{duration(a.duration)}</span>}
            </>
          )}
          {a.missing && <span className={styles.mediaBadge}>Not on this Mac</span>}
        </>
      )
      return open
        ? <button ref={ref} type="button" className={styles.media} onClick={open} aria-label={`Open ${label}`} {...noDrag}>{inner}</button>
        : <div ref={ref} className={`${styles.media} ${styles.mediaMissing}`} title="Download it in WhatsApp to see it here">{inner}</div>
    }
    case MEDIA.STICKER:
      return <img className={styles.sticker} src={a.url} alt="Sticker" loading="lazy" {...noDrag} />
    case MEDIA.AUDIO:
      return <VoiceNote a={a} onOpen={onOpen} />
    case MEDIA.DOCUMENT: {
      const ext = (a.name || '').split('.').pop()?.toUpperCase()
      const body = (
        <>
          {a.thumbUrl && <img className={styles.docThumb} src={a.thumbUrl} alt="" loading="lazy" draggable={false} />}
          <span className={styles.docRow}>
            <FileTypeIcon name={a.name} size={28} />
            <span className={styles.docText}>
              <span className={styles.docName} dir="auto">{a.name}</span>
              <span className={styles.docMeta}>
                {[a.size ? formatBytes(a.size) : null, ext, a.missing ? 'not on this Mac' : null].filter(Boolean).join(' · ')}
              </span>
            </span>
          </span>
        </>
      )
      return open
        ? <button type="button" className={styles.doc} onClick={open} aria-label={`Open ${a.name}`} {...noDrag}>{body}</button>
        : <div className={`${styles.doc} ${styles.mediaMissing}`} title="Download it in WhatsApp to open it here">{body}</div>
    }
    case MEDIA.LINK:
      return (
        <span className={styles.linkCard}>
          <img className={styles.linkThumb} src={a.thumbUrl} alt="" loading="lazy" draggable={false} />
          {a.name && <span className={styles.linkTitle} dir="auto">{a.name}</span>}
        </span>
      )
    case MEDIA.MISSING:
      return (
        <span className={styles.attachChip} title="Download it in WhatsApp to see it here">
          <Icon name="arrow.down.circle" size={11} />
          <span className={styles.attachName}>{a.label}{a.duration > 0 ? ` ${duration(a.duration)}` : ''} · not on this Mac</span>
        </span>
      )
    default:
      return null
  }
}

// A voice note plays in the bubble. WebKit decodes Ogg Opus on recent macOS;
// where it can't, the note opens in the viewer (with Open in default app).
function VoiceNote({ a, onOpen }) {
  const [failed, setFailed] = useState(false)
  if (failed) {
    return (
      <button type="button" className={`${styles.attachChip} ${styles.attachChipBtn}`} onClick={() => onOpen?.(a)}>
        <Icon name="play.circle" size={11} />
        <span className={styles.attachName}>Voice message {duration(a.duration)}</span>
      </button>
    )
  }
  return <audio className={styles.voice} src={a.url} controls preload="metadata" onError={() => setFailed(true)} />
}

export default memo(MediaAttachment)
