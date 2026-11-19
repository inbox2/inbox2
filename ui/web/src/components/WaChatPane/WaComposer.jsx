import { useRef, useState } from 'react'
import Icon from '../Icon'
import Spinner from '../Spinner'
import { waSend, waPickFiles, waActionsStatus, waRequestAccessibility } from '../../lib/localWhatsApp'
import WaErrorDialog from './WaErrorDialog'
import styles from './WaComposer.module.css'

const fileName = (path) => path.split('/').pop()

/**
 * Reply to a local WhatsApp chat: Inbox2 types it into WhatsApp Desktop and
 * presses Send there (whatsapp_actions.rs), so it goes out from the person's
 * own WhatsApp. Attachments go first, one message each, then the text.
 * Enter sends, Shift+Enter is a new line. Each item leaves the box only once
 * WhatsApp's database shows it, so a failed send loses nothing and resends nothing.
 */
export default function WaComposer({ chat, onPending, onSettled }) {
  const textareaRef = useRef(null)
  const [files, setFiles] = useState([])
  const [hasText, setHasText] = useState(false)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState(null)

  const attach = async () => {
    const picked = await waPickFiles().catch(e => { setError(String(e?.message || e)); return [] })
    if (picked.length) setFiles(f => [...f, ...picked.filter(p => !f.includes(p))])
  }

  // A ref, not state: a second Enter in the same tick must not start a second send.
  const busy = useRef(false)
  const send = async () => {
    const text = textareaRef.current?.value?.trim() || ''
    if ((!text && !files.length) || busy.current) return
    busy.current = true
    setSending(true)
    setError(null)
    const queue = files
    const left = [...queue]
    let textLeft = text
    try {
      // The first send is where macOS is asked for Accessibility (its own prompt).
      const { trusted } = await waActionsStatus()
      if (!trusted && !(await waRequestAccessibility())) {
        setError('no_ax: To send, allow Inbox2 under System Settings › Privacy & Security › Accessibility, then press Send again.')
        return
      }
      // Out of the box and into the thread at once (onPending); back into the
      // box if it fails. One item per call, attachments first, each confirmed
      // against WhatsApp's database, so a failure part-way resends nothing.
      if (textareaRef.current) { textareaRef.current.value = ''; grow(textareaRef.current) }
      setHasText(false)
      setFiles([])
      const one = async (item, run) => {
        const id = `wa-pending-${Date.now()}-${Math.random().toString(36).slice(2)}`
        onPending?.({ id, at: Date.now(), ...item })
        try {
          await run()
        } catch (e) {
          onSettled?.(id, false)
          throw e
        }
        onSettled?.(id, true)
      }
      for (const f of queue) {
        await one({ file: f }, () => waSend(chat.id, null, [f]))
        left.shift()
      }
      if (text) {
        await one({ text }, () => waSend(chat.id, text, []))
        textLeft = ''
      }
    } catch (e) {
      setError(String(e?.message || e))
      setFiles(list => [...left, ...list.filter(f => !left.includes(f))])
      const box = textareaRef.current
      if (textLeft && box && !box.value) {
        box.value = textLeft
        grow(box)
        setHasText(true)
      }
    } finally {
      busy.current = false
      setSending(false)
      textareaRef.current?.focus()
    }
  }

  const onKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault()
      send()
    }
  }

  // One line that grows with the text, up to a few lines (then it scrolls).
  const grow = (el) => {
    el.style.setProperty('height', 'auto')
    el.style.setProperty('height', `${Math.min(el.scrollHeight, 132)}px`)
  }

  const ready = hasText || files.length > 0
  return (
    <div className={styles.bar}>
      <WaErrorDialog error={error} title="Couldn't send" onClose={() => setError(null)} />
      {files.length > 0 && (
        <ul className={styles.files} aria-label="Attachments">
          {files.map(f => (
            <li key={f} className={styles.file}>
              <Icon name="paperclip" size={10} />
              <span className={styles.fileName} title={f}>{fileName(f)}</span>
              <button type="button" className={styles.fileRemove} onClick={() => setFiles(list => list.filter(x => x !== f))} aria-label={`Remove ${fileName(f)}`} disabled={sending}>
                <Icon name="xmark" size={8} />
              </button>
            </li>
          ))}
        </ul>
      )}
      <div className={styles.row}>
        <button type="button" className={styles.iconButton} onClick={attach} disabled={sending} aria-label="Attach files" title="Attach files">
          <Icon name="paperclip" size={16} />
        </button>
        <div className={styles.field}>
          <textarea
            ref={textareaRef}
            className={styles.input}
            rows={1}
            placeholder={`Message ${chat.name}`}
            dir="auto"
            onKeyDown={onKeyDown}
            onInput={(e) => { grow(e.target); setHasText(!!e.target.value.trim()) }}
            disabled={sending}
          />
          <button type="button" className={styles.send} onClick={send} disabled={sending || !ready} aria-label={sending ? 'Sending' : 'Send'} title="Send (Enter)">
            {sending ? <Spinner size={14} label="Sending" /> : <Icon name="paperplane.fill" size={15} />}
          </button>
        </div>
      </div>
    </div>
  )
}
