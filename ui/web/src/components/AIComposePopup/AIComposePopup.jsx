import { useEffect, useRef, useState, useCallback } from 'react'
import Modal from '../Modal/Modal'
import Button from '../Button/Button'
import Icon from '../Icon'
import {
  isGenerativeReady,
  initializeGenerative,
  generativeUnavailableReason,
  generate,
} from '../../lib/ai'
import log from '../../lib/log'
import styles from './AIComposePopup.module.css'

const SYSTEM_PROMPT =
  'You are an assistant that drafts email replies on behalf of the user. ' +
  'Write a clear, concise, professional reply in the first person. ' +
  'Output only the reply body — no subject line, no quoted original, no preamble or sign-off placeholders.'

// Plain-text view of the most recent messages, newest last, for prompt context.
function buildThreadText(messages) {
  if (!messages || messages.length === 0) return ''
  return messages
    .slice(-3)
    .map(msg => {
      const body = (msg.body_plain || (msg.body_html || '').replace(/<[^>]+>/g, ' '))
        .replace(/\s+\n/g, '\n')
        .trim()
      return `From: ${msg.from_address}\n${body}`
    })
    .join('\n\n---\n\n')
}

/**
 * "Generate with AI" — drafts a reply with the on-device generative model.
 *
 * @param {Object} props
 * @param {boolean} props.open
 * @param {() => void} props.onClose
 * @param {(text: string) => void} props.onInsert  Insert the draft into the composer.
 * @param {Array} props.messages   Thread messages for context.
 * @param {string} [props.senderName]
 * @param {string} [props.seed]    Pre-fill the instruction (e.g. the user's current draft).
 */
export default function AIComposePopup({ open, onClose, onInsert, messages, senderName, seed = '' }) {
  // status: 'preparing' | 'ready' | 'unavailable' | 'generating' | 'done' | 'error'
  // This component is mounted only while open, so useState initializers reset
  // it each time it appears — no effect-driven reset needed.
  const [status, setStatus] = useState('preparing')
  const [reason, setReason] = useState(null)
  const [instruction, setInstruction] = useState(seed)
  const [draft, setDraft] = useState('')
  const instructionRef = useRef(null)

  // Prepare the on-device backend on mount.
  useEffect(() => {
    let cancelled = false

    ;(async () => {
      if (isGenerativeReady()) {
        if (!cancelled) setStatus('ready')
        return
      }
      const ok = await initializeGenerative()
      if (cancelled) return
      if (ok && isGenerativeReady()) {
        setStatus('ready')
      } else {
        setReason(generativeUnavailableReason())
        setStatus('unavailable')
      }
    })()

    return () => { cancelled = true }
  }, [])

  // Focus the instruction field once the model is ready.
  useEffect(() => {
    if (open && status === 'ready') instructionRef.current?.focus()
  }, [open, status])

  const handleGenerate = useCallback(async () => {
    setStatus('generating')
    setReason(null)
    const threadText = buildThreadText(messages)
    const userInput =
      (threadText ? `Email thread to reply to:\n${threadText}\n\n` : '') +
      `Write a reply${senderName ? ` to ${senderName}` : ''} that ${instruction.trim() || 'responds appropriately to the message above'}.`

    try {
      const result = await generate(SYSTEM_PROMPT, userInput)
      const text = (result || '').trim()
      if (!text) {
        setReason('The draft came back empty. Try asking another way.')
        setStatus('error')
        return
      }
      setDraft(text)
      setStatus('done')
    } catch (e) {
      log.warn('AIComposePopup', `Generation failed: ${e?.message || e}`)
      setReason(e?.message || 'Couldn’t write a draft. Try again.')
      setStatus('error')
    }
  }, [messages, senderName, instruction])

  const handleInsert = useCallback(() => {
    if (!draft.trim()) return
    onInsert?.(draft.trim())
    onClose?.()
  }, [draft, onInsert, onClose])

  return (
    <Modal open={open} onClose={onClose} className={styles.panel}>
      <div className={styles.header}>
        <Icon name="wand.and.stars" size={16} className={styles.headerIcon} />
        <h3 className={styles.title}>Generate with AI</h3>
      </div>

      {status === 'preparing' && (
        <p className={styles.note}>Getting the on-device AI ready…</p>
      )}

      {status === 'unavailable' && (
        <p className={styles.error}>
          On-device AI isn’t available here{reason ? `: ${reason}` : '.'}
        </p>
      )}

      {status !== 'preparing' && status !== 'unavailable' && (
        <>
          <label className={styles.label} htmlFor="ai-instruction">
            What should the reply say?
          </label>
          <textarea
            id="ai-instruction"
            ref={instructionRef}
            className={styles.instruction}
            value={instruction}
            placeholder="e.g. politely decline and suggest next week instead"
            onChange={e => setInstruction(e.target.value)}
            disabled={status === 'generating'}
          />

          {(status === 'done' || status === 'generating') && (
            <>
              <label className={styles.label} htmlFor="ai-draft">Draft</label>
              <textarea
                id="ai-draft"
                className={styles.draft}
                value={draft}
                placeholder={status === 'generating' ? 'Writing…' : ''}
                onChange={e => setDraft(e.target.value)}
                disabled={status === 'generating'}
              />
            </>
          )}

          {status === 'error' && reason && (
            <p className={styles.error}>{reason}</p>
          )}

          <div className={styles.actions}>
            <Button variant="ghost" onClick={onClose}>Cancel</Button>
            <div className={styles.actionsRight}>
              <Button
                variant="secondary"
                onClick={handleGenerate}
                disabled={status === 'generating'}
              >
                {status === 'generating'
                  ? 'Generating…'
                  : status === 'done'
                    ? 'Regenerate'
                    : 'Generate'}
              </Button>
              {status === 'done' && (
                <Button onClick={handleInsert} disabled={!draft.trim()}>
                  Insert
                </Button>
              )}
            </div>
          </div>
        </>
      )}
    </Modal>
  )
}
