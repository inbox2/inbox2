import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import Icon from '../Icon'
import PreviewPane from '../../pages/disk/preview/PreviewPane'
import ZoomImage from './ZoomImage'
import { trapTab } from '../../lib/focusTrap'
import { MEDIA } from '../../lib/waMessages'
import { waChatMedia, waMediaUrl, waOpenMedia, waRevealMedia, waSaveMedia } from '../../lib/localWhatsApp'
import log from '../../lib/log'
import styles from './WaMediaViewer.module.css'

// WhatsApp's media types in the chat's gallery (wa_chat_media `kind`).
const GALLERY_KIND = { 1: MEDIA.IMAGE, 2: MEDIA.VIDEO, 11: MEDIA.GIF }
const VISUAL = new Set([MEDIA.IMAGE, MEDIA.VIDEO, MEDIA.GIF])

const when = (ms) => (ms ? new Date(ms).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : '')
const fallbackName = (a) => a.name || { [MEDIA.IMAGE]: 'Photo', [MEDIA.VIDEO]: 'Video', [MEDIA.GIF]: 'GIF', [MEDIA.AUDIO]: 'Voice message' }[a.kind] || 'Attachment'

/**
 * The media viewer: a popup inside Inbox2 for one WhatsApp attachment. Photos
 * zoom and pan (ZoomImage); videos, GIFs and voice notes play; documents (PDF,
 * Word, Excel, PowerPoint, CSV, Markdown, code, ZIP) go through Disk's preview
 * engine. Photos and videos step through the whole chat with ← →. Actions:
 * Download (to ~/Downloads), Save as…, Open in default app, Show in Finder,
 * Copy image. Esc closes.
 */
export default function WaMediaViewer({ chatId, chatName, item, onClose }) {
  const [gallery, setGallery] = useState(null)
  const [current, setCurrent] = useState(item)
  const [status, setStatus] = useState(null)
  const panel = useRef(null)
  const zoom = useRef(null)
  const closeBtn = useRef(null)

  // The chat's photos and videos, for ← →; only when the opened item is one.
  useEffect(() => {
    if (!VISUAL.has(item.kind)) return undefined
    let live = true
    waChatMedia(chatId)
      .then((list) => {
        if (!live) return
        setGallery(list.map((m) => ({
          kind: GALLERY_KIND[m.kind] || MEDIA.IMAGE,
          waId: m.id,
          path: m.path,
          thumb: m.thumb,
          url: waMediaUrl(m.path),
          thumbUrl: waMediaUrl(m.thumb),
          name: m.name,
          at: m.at,
          sender: m.from_me ? 'You' : (m.sender || chatName),
        })))
      })
      .catch((e) => log.warn('WhatsApp', `media list failed: ${e}`))
    return () => { live = false }
  }, [chatId, chatName, item.kind])

  const index = gallery ? gallery.findIndex((g) => g.waId === current.waId) : -1
  // The gallery entry carries who sent it and when; the opened item may not.
  const shown = index >= 0 ? { ...gallery[index], ...current, sender: gallery[index].sender, at: gallery[index].at } : current
  const step = useCallback((d) => {
    if (index < 0) return
    const next = gallery[index + d]
    if (next) { setCurrent(next); setStatus(null) }
  }, [gallery, index])

  // Focus moves into the viewer, and back to what opened it (the attachment) on close.
  useEffect(() => {
    const opener = document.activeElement
    closeBtn.current?.focus()
    return () => { if (opener?.isConnected) opener.focus() }
  }, [])
  // Keys: Esc closes, ← → step, + − 0 r zoom a photo. Typing in a field (PDF search) is left alone.
  useEffect(() => {
    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); onClose(); return }
      if (e.key === 'Tab') { trapTab(e, panel.current); return }
      const t = e.target
      if (t?.tagName === 'INPUT' || t?.tagName === 'TEXTAREA' || t?.isContentEditable || e.metaKey || e.ctrlKey || e.altKey) return
      // A focused player keeps its own keys (← → seek).
      if (t?.closest?.('video, audio')) return
      if (e.key === 'ArrowLeft') step(-1)
      else if (e.key === 'ArrowRight') step(1)
      else if (shown.kind === MEDIA.IMAGE && zoom.current) {
        if (e.key === '+' || e.key === '=') zoom.current.zoomIn()
        else if (e.key === '-') zoom.current.zoomOut()
        else if (e.key === '0') zoom.current.fit()
        else if (e.key === 'r' || e.key === 'R') zoom.current.rotate()
        else return
      } else return
      e.preventDefault()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [onClose, step, shown.kind])

  const name = fallbackName(shown)
  const run = (label, fn) => async () => {
    try {
      const out = await fn()
      if (out !== undefined) setStatus(out)
    } catch (e) {
      log.warn('WhatsApp', `${label} failed: ${e}`)
      setStatus(`${label} didn't work: ${e?.message || e}`)
    }
  }
  const download = run('Download', async () => {
    const saved = await waSaveMedia(shown.path, shown.name, false)
    return saved ? `Saved to Downloads: ${saved.split('/').pop()}` : undefined
  })
  const saveAs = run('Save as', async () => {
    const saved = await waSaveMedia(shown.path, shown.name, true)
    return saved ? `Saved: ${saved}` : undefined
  })
  const copyImage = run('Copy', async () => {
    // The clipboard takes PNG: draw the photo once and copy that.
    const bitmap = await createImageBitmap(await (await fetch(shown.url)).blob())
    const canvas = document.createElement('canvas')
    canvas.width = bitmap.width
    canvas.height = bitmap.height
    canvas.getContext('2d').drawImage(bitmap, 0, 0)
    const png = await new Promise((ok) => canvas.toBlob(ok, 'image/png'))
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': png })])
    return 'Image copied'
  })

  // Disk's preview engine reads a file "node": its name drives the renderer.
  const node = useMemo(() => ({
    kind: 'file', id: `wa-${shown.waId}`, name: shown.name || 'attachment', size_bytes: shown.size || 0, mime: '',
  }), [shown.waId, shown.name, shown.size])
  const loadUrl = useCallback(async () => shown.url, [shown.url])

  let body
  if (!shown.path) {
    body = <p className={styles.note}>This isn't downloaded on this Mac. Download it in WhatsApp to see it here.</p>
  } else if (shown.kind === MEDIA.IMAGE) {
    body = <ZoomImage key={shown.waId} ref={zoom} src={shown.url} alt={name} />
  } else if (shown.kind === MEDIA.VIDEO || shown.kind === MEDIA.GIF) {
    const gif = shown.kind === MEDIA.GIF
    body = <video key={shown.waId} className={styles.video} src={shown.url} poster={shown.thumbUrl || undefined} controls={!gif} autoPlay loop={gif} muted={gif} playsInline />
  } else if (shown.kind === MEDIA.AUDIO) {
    body = <VoicePlayer key={shown.waId} src={shown.url} />
  } else {
    body = (
      <div className={`management ${styles.sheet}`}>
        <PreviewPane key={shown.waId} node={node} loadUrl={loadUrl} onDownload={download} />
      </div>
    )
  }

  return createPortal(
    <div className={styles.backdrop} role="presentation" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div ref={panel} className={styles.panel} role="dialog" aria-modal="true" aria-label={name}>
        <header className={styles.bar}>
          <div className={styles.title}>
            <span className={styles.name} dir="auto" title={name}>{name}</span>
            <span className={styles.sub}>
              {[shown.sender, when(shown.at), chatName].filter(Boolean).join(' · ')}
              {index >= 0 && gallery.length > 1 && <span className={styles.count}>{index + 1} of {gallery.length}</span>}
            </span>
          </div>
          {status && <span className={styles.status} role="status">{status}</span>}
          {shown.path && (
            <div className={styles.actions}>
              <button type="button" className={styles.action} onClick={download} title="Save to Downloads"><Icon name="arrow.down.circle" size={13} /> Download</button>
              <button type="button" className={styles.action} onClick={saveAs} title="Choose where to save it">Save as…</button>
              {shown.kind === MEDIA.IMAGE && (
                <button type="button" className={styles.iconAction} onClick={copyImage} aria-label="Copy image" title="Copy image"><Icon name="doc.on.doc" size={13} /></button>
              )}
              <button type="button" className={styles.iconAction} onClick={run('Open', () => waOpenMedia(shown.path))} aria-label="Open in default app" title="Open in default app"><Icon name="arrow.up.right" size={13} /></button>
              <button type="button" className={styles.iconAction} onClick={run('Show in Finder', () => waRevealMedia(shown.path))} aria-label="Show in Finder" title="Show in Finder"><Icon name="folder" size={13} /></button>
            </div>
          )}
          <button ref={closeBtn} type="button" className={styles.iconAction} onClick={onClose} aria-label="Close" title="Close (Esc)"><Icon name="xmark" size={13} /></button>
        </header>
        <div className={styles.body}>
          {index > 0 && (
            <button type="button" className={`${styles.nav} ${styles.prev}`} onClick={() => step(-1)} aria-label="Previous" title="Previous (←)"><Icon name="chevron.left" size={18} /></button>
          )}
          {body}
          {index >= 0 && index < gallery.length - 1 && (
            <button type="button" className={`${styles.nav} ${styles.next}`} onClick={() => step(1)} aria-label="Next" title="Next (→)"><Icon name="chevron.right" size={18} /></button>
          )}
        </div>
      </div>
    </div>,
    document.body,
  )
}

// A voice note, or what to do when WebKit can't decode it.
function VoicePlayer({ src }) {
  const [failed, setFailed] = useState(false)
  if (failed) return <p className={styles.note}>This voice note doesn't play here. Use Open in default app above.</p>
  return <audio className={styles.audio} src={src} controls autoPlay onError={() => setFailed(true)} />
}
