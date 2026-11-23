import { useRef, useState, useEffect, useCallback, useContext } from 'react'
import useDismiss from '../../hooks/useDismiss'
import ToolbarGroup, { ToolbarButton } from '../ToolbarGroup'
import Button from '../Button/Button'
import Icon from '../Icon'
import ConfirmDialog from '../ConfirmDialog'
import DropdownMenu from '../DropdownMenu/DropdownMenu'
import AIComposePopup from '../AIComposePopup/AIComposePopup'
import { triageSubmenu } from '../../lib/conversationActions'
import { displayName, replyFromAddress } from '../../lib/emailAddress'
import useFromIdentities from '../../hooks/useFromIdentities'
import useDrafts from '../../hooks/useDrafts'
import api from '../../lib/localFirstApi'
import log from '../../lib/log'
import useUndoStore from '../../stores/undoStore'
import { buildQuotedHtml as buildMessageQuote, plainTextToHtml } from '../../lib/draftBuilders'
import { loadSignatures, signatureFor, signatureBlock, signatureText } from '../../lib/signatures'
import { AuthContext } from '../../hooks/AuthProvider'
import styles from './Composer.module.css'

function buildQuotedHtml(messages) {
  return (messages || []).map(msg => buildMessageQuote(msg)).join('')
}

export default function Composer({
  placeholder = 'Reply... (/ for commands)',
  conversationId,
  replyTo,
  replySubject,
  defaultFrom = '',
  messages,
  orgId,
  executePriority,
  onNoteCreated,
  onSent,
}) {
  const { createDraft, sendInline } = useDrafts()
  // Reply from the address the thread was sent to, not the page default.
  const fromIdentities = useFromIdentities()
  const fromAddress = replyFromAddress(messages?.[messages.length - 1], fromIdentities, defaultFrom)
  // The From address's signature goes under the reply (spec 8.1.7). Read when
  // sending, so a quick first reply still waits for it.
  const fromOrgId = fromIdentities.find((i) => i.email.toLowerCase() === (fromAddress || '').toLowerCase())?.orgId
  const userId = useContext(AuthContext)?.user?.id
  const getSignature = () => loadSignatures(fromOrgId || null, userId).then((d) => signatureFor(d, fromAddress), () => null)
  const textareaRef = useRef(null)
  const fileInputRef = useRef(null)
  const [templates, setTemplates] = useState(null)
  const [templateOpen, setTemplateOpen] = useState(false)
  const [commandsOpen, setCommandsOpen] = useState(false)
  const [aiOpen, setAiOpen] = useState(false)
  const [aiSeed, setAiSeed] = useState('')
  const [sending, setSending] = useState(false)
  const [sendError, setSendError] = useState(null)
  const [pulse, setPulse] = useState(false)
  const [confirmDiscard, setConfirmDiscard] = useState(false)
  // The textarea is uncontrolled (perf); mirror only whether it holds text so
  // the Send button can activate (primary colour) once the user types something.
  const [hasText, setHasText] = useState(false)
  const templateMenuRef = useRef(null)

  // Clear the field and keep the has-text mirror in sync (programmatic clears
  // don't fire the textarea's onInput).
  const clearField = () => {
    if (textareaRef.current) textareaRef.current.value = ''
    setHasText(false)
  }

  // Reply (toolbar button or `r` shortcut) targets this inline composer:
  // scroll it into view, focus it, and briefly flash so the action is visible.
  useEffect(() => {
    const onReply = (e) => {
      const ta = textareaRef.current
      if (!ta) return
      e.preventDefault()
      ta.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
      ta.focus()
      setPulse(true)
      setTimeout(() => setPulse(false), 900)
    }
    document.addEventListener('inline-compose-reply', onReply)
    return () => document.removeEventListener('inline-compose-reply', onReply)
  }, [])

  // The reply threads under the newest message in the conversation — its key
  // rides along so the engine can hydrate In-Reply-To/References at send time.
  const replyParentKey = messages?.length ? messages[messages.length - 1].key : undefined

  // Set while a send or a hand-off to the full composer waits for the signature,
  // so a second click can't send twice or open a second draft.
  const busyRef = useRef(false)
  const [handingOff, setHandingOff] = useState(false)

  const handleMaximize = async () => {
    if (busyRef.current) return
    busyRef.current = true
    setHandingOff(true)
    try {
      const signature = await getSignature()
      const currentText = textareaRef.current?.value || ''
      const subject = replySubject
        ? (replySubject.startsWith('Re: ') ? replySubject : `Re: ${replySubject}`)
        : ''

      const quotedHtml = buildQuotedHtml(messages)

      await createDraft({
        conversationId,
        fromAddress,
        toAddress: replyTo || '',
        subject,
        bodyPlain: signature ? `${currentText}\n\n${signatureText(signature.html)}` : currentText,
        // plainTextToHtml escapes the user's text — `<` or `&` typed in the
        // reply must not be interpreted as markup in the outgoing HTML.
        bodyHtml: `${currentText ? `<p>${plainTextToHtml(currentText)}</p>` : '<p></p>'}${signature ? `<p></p>${signatureBlock(signature)}` : ''}`,
        quotedHtml,
        replyToMessageKey: replyParentKey,
        focus: 'body',
      })

      clearField()
    } finally {
      busyRef.current = false
      setHandingOff(false)
    }
  }

  const handleSend = async () => {
    const text = textareaRef.current?.value?.trim()
    if (!text || sending || busyRef.current) return
    // No resolvable recipient — escalate to the full composer so the user can address it.
    if (!replyTo) { handleMaximize(); return }
    busyRef.current = true

    const subject = replySubject
      ? (replySubject.startsWith('Re: ') ? replySubject : `Re: ${replySubject}`)
      : ''
    setSending(true)
    const signature = await getSignature()
    const bodyHtml = `<p>${plainTextToHtml(text)}</p>${signature ? `<br>${signatureBlock(signature)}` : ''}${buildQuotedHtml(messages)}`
    const sigText = signature ? signatureText(signature.html) : ''

    setSendError(null)
    try {
      const result = await sendInline({
        conversationId,
        fromAddress,
        toAddress: replyTo,
        subject,
        bodyHtml,
        bodyPlain: sigText ? `${text}\n\n${sigText}` : text,
        replyToMessageKey: replyParentKey,
      })
      // Accepted (sent or durably queued): clear the field either way.
      clearField()
      onSent?.()
      // A queued send (offline) isn't an error, but tell the user it hasn't
      // left yet so they don't expect immediate delivery.
      if (result?.status && result.status !== 'sent') {
        setSendError('You’re offline. It sends when you reconnect.')
      }
    } catch (e) {
      log.error('Composer', `Inline send failed: ${e?.message || e}`)
      // Keep the text in place so the user can retry; surface the failure.
      setSendError(e?.message || 'Your reply didn’t send. Try again.')
    } finally {
      busyRef.current = false
      setSending(false)
    }
  }

  const handleKeyDown = (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault()
      handleSend()
      return
    }
    // "/" on an empty field opens the commands menu (matches the placeholder hint).
    if (e.key === '/' && !textareaRef.current?.value) {
      e.preventDefault()
      openCommands(true)
      return
    }
    if (e.key === 'Escape') {
      // With text, confirm before discarding; otherwise just leave the field.
      if (textareaRef.current?.value.trim()) {
        e.preventDefault()
        e.stopPropagation()
        setConfirmDiscard(true)
      } else {
        e.preventDefault()
        e.stopPropagation()
        textareaRef.current?.blur()
      }
    }
  }

  const handleDiscardConfirm = () => {
    setConfirmDiscard(false)
    clearField()
    textareaRef.current?.blur()
  }

  const handleDiscardCancel = () => {
    setConfirmDiscard(false)
    textareaRef.current?.focus()
  }

  const handleAttach = () => {
    // Maximize to full compose popup for attachment support
    handleMaximize()
  }

  const handleNote = async () => {
    const body = textareaRef.current?.value?.trim()
    if (!body || !orgId || !conversationId) return

    try {
      await api.createNote(orgId, conversationId, { body })
      clearField()
      onNoteCreated?.()
    } catch (e) {
      // Keep the text in the box (clearField never ran) and say so — silence
      // here read as "saved" for a note that was never written.
      log.error('Composer', `Note save failed: ${e?.message || e}`)
      useUndoStore.getState().notify({
        description: "Couldn't save your note. Your text is still here.",
        variant: 'danger',
        icon: 'exclamationmark.triangle',
      })
    }
  }

  // Open the commands menu, lazily loading templates the first time so the
  // "Template" submenu is populated.
  const openCommands = (next) => {
    setCommandsOpen(next)
    if (next && templates === null && orgId) {
      api.getTemplates(orgId)
        .then(data => setTemplates(data.templates || []))
        .catch(() => setTemplates([]))
    }
  }

  const insertText = (text, { replace = false } = {}) => {
    const textarea = textareaRef.current
    if (!textarea || !text) return
    if (replace) {
      textarea.value = text
      textarea.focus()
      textarea.selectionStart = textarea.selectionEnd = text.length
      setHasText(!!text.trim())
      return
    }
    const start = textarea.selectionStart
    const end = textarea.selectionEnd
    const current = textarea.value
    textarea.value = current.substring(0, start) + text + current.substring(end)
    textarea.focus()
    textarea.selectionStart = textarea.selectionEnd = start + text.length
    setHasText(!!textarea.value.trim())
  }

  const handleTemplateToggle = async () => {
    if (templateOpen) {
      setTemplateOpen(false)
      return
    }
    if (!templates && orgId) {
      try {
        const data = await api.getTemplates(orgId)
        setTemplates(data.templates || [])
      } catch {
        setTemplates([])
      }
    }
    setTemplateOpen(true)
  }

  const handleTemplateSelect = (template) => {
    // Strip HTML tags for plain-text insertion at the cursor.
    const plain = template.body_html
      ?.replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .trim() || ''
    insertText(plain)
    setTemplateOpen(false)
  }

  // Close the toolbar template menu on outside click / Escape.
  const closeTemplateMenu = useCallback(() => setTemplateOpen(false), [])
  useDismiss(templateMenuRef, closeTemplateMenu, templateOpen)

  // Commands menu items: attach, note, template ▸, generate with AI, triage ▸.
  const templateSubmenu = !templates || templates.length === 0
    ? [{ value: 'template_empty', label: templates === null ? 'Loading…' : 'No templates yet' }]
    : templates.map(t => ({ value: `template_${t.id}`, label: t.name, onSelect: () => handleTemplateSelect(t) }))

  const commandItems = [
    { value: 'attach', icon: 'paperclip', label: 'Attach file', onSelect: handleAttach },
    { value: 'note', icon: 'note.text', label: 'Add internal note', onSelect: handleNote },
    { value: 'template', icon: 'list.bullet.rectangle', label: 'Choose template', submenu: templateSubmenu },
    { value: 'ai', icon: 'wand.and.stars', label: 'Generate with AI…', onSelect: () => { setAiSeed(textareaRef.current?.value || ''); setAiOpen(true) } },
    { separator: true },
    triageSubmenu([conversationId], executePriority),
  ]

  return (
    <div className={`${styles.composer}${pulse ? ` ${styles.pulse}` : ''}`}>
      <textarea
        ref={textareaRef}
        className={styles.input}
        placeholder={placeholder}
        dir="auto"
        data-inline-composer
        onKeyDown={handleKeyDown}
        onInput={(e) => { if (sendError) setSendError(null); setHasText(!!e.target.value.trim()) }}
      />

      {/* Slash-command menu — opens at the caret when "/" is typed into an empty field. */}
      <div className={styles.slashAnchorWrap}>
        <DropdownMenu
          align="left"
          direction="up"
          open={commandsOpen}
          onOpenChange={openCommands}
          trigger={<span className={styles.slashAnchor} aria-hidden="true" />}
          items={commandItems}
        />
      </div>

      <div className={styles.actions}>
        <div className={styles.actionsLeft}>
          <ToolbarGroup>
            <ToolbarButton icon="paperclip" onClick={handleAttach} disabled={handingOff}>Attach</ToolbarButton>
            <ToolbarButton icon="note.text" onClick={handleNote}>Note</ToolbarButton>
            <ToolbarButton icon="list.bullet.rectangle" onClick={handleTemplateToggle}>Template</ToolbarButton>
            <ToolbarButton
              icon="arrow.up.left.and.arrow.down.right"
              onClick={handleMaximize}
              disabled={handingOff}
              aria-busy={handingOff}
            />
          </ToolbarGroup>
        </div>
        {sendError && (
          <span className={styles.sendError} role="alert">{sendError}</span>
        )}
        <Button variant={hasText ? undefined : 'secondary'} onClick={handleSend} disabled={sending || !hasText}>
          <Icon name="paperplane.fill" size={14} />
          {sending ? 'Sending…' : 'Send'}
        </Button>
      </div>

      {templateOpen && (
        <div ref={templateMenuRef} className={styles.templateMenu}>
          {!templates || templates.length === 0 ? (
            <div className={styles.templateEmpty}>
              {templates === null ? 'Loading...' : 'No templates yet'}
            </div>
          ) : (
            templates.map(t => (
              <button
                key={t.id}
                className={styles.templateItem}
                onClick={() => handleTemplateSelect(t)}
              >
                {t.name}
              </button>
            ))
          )}
        </div>
      )}

      <input
        ref={fileInputRef}
        type="file"
        multiple
        className={styles.hiddenInput}
      />

      {aiOpen && (
        <AIComposePopup
          open
          onClose={() => setAiOpen(false)}
          onInsert={(text) => insertText(text, { replace: true })}
          messages={messages}
          senderName={replyTo ? displayName(replyTo) : undefined}
          seed={aiSeed}
        />
      )}

      <ConfirmDialog
        open={confirmDiscard}
        title="Discard reply?"
        message="You'll lose what you've written."
        confirmLabel="Discard"
        cancelLabel="Keep editing"
        variant="danger"
        onConfirm={handleDiscardConfirm}
        onCancel={handleDiscardCancel}
      />
    </div>
  )
}
