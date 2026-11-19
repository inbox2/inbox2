import { useState, useRef, useEffect, useCallback } from 'react'
import useDismiss from '../../hooks/useDismiss'
import ContactPopup from '../ContactPopup/ContactPopup'
import ContextMenu from '../DropdownMenu/ContextMenu'
import AddressContextMenu from '../DropdownMenu/AddressContextMenu'
import FileIcon from '../FileIcon'
import { parseAddressList } from '../../lib/emailAddress'
import styles from './MessageDetails.module.css'

function RecipientChip({ name, email, explicit, onViewSender }) {
  const [open, setOpen] = useState(false)
  const [anchorRect, setAnchorRect] = useState(null)
  const ref = useRef(null)
  const chipRef = useRef(null)
  const hoverTimeout = useRef(null)

  const show = () => {
    if (chipRef.current) setAnchorRect(chipRef.current.getBoundingClientRect())
    setOpen(true)
  }

  // The popup portals to <body>, so it isn't inside `ref`: presses inside it
  // (marked with data-contact-popup) don't count as outside.
  const close = useCallback(() => setOpen(false), [])
  useDismiss(ref, close, open, { ignore: ['[data-contact-popup]'] })

  useEffect(() => () => clearTimeout(hoverTimeout.current), [])

  const handleMouseEnter = () => {
    clearTimeout(hoverTimeout.current)
    hoverTimeout.current = setTimeout(() => show(), 300)
  }

  const handleMouseLeave = () => {
    clearTimeout(hoverTimeout.current)
    hoverTimeout.current = setTimeout(() => setOpen(false), 200)
  }

  // Hover bridge: keep the card open while the pointer is over it (it portals
  // outside the chip wrapper, so leaving the chip would otherwise close it).
  const handlePopupMouseEnter = () => clearTimeout(hoverTimeout.current)
  const handlePopupMouseLeave = () => {
    clearTimeout(hoverTimeout.current)
    hoverTimeout.current = setTimeout(() => setOpen(false), 200)
  }

  const copyEmail = () => {
    navigator.clipboard.writeText(email)
    setOpen(false)
  }

  const sendEmail = () => {
    window.open(`mailto:${email}`)
    setOpen(false)
  }

  const toggle = () => { if (open) setOpen(false); else show() }

  return (
    // Right-click opens the copy menu instead: drop the hover card (and a pending one).
    <span className={styles.recipientChipWrap} ref={ref} role="presentation" onMouseEnter={handleMouseEnter} onMouseLeave={handleMouseLeave}
      onContextMenuCapture={() => { clearTimeout(hoverTimeout.current); setOpen(false) }}>
      <AddressContextMenu email={email} name={explicit ? name : ''}>
        <span ref={chipRef} className={styles.recipientChip} role="button" tabIndex={0} onClick={toggle}
          onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } }}>
          {name || email}
        </span>
      </AddressContextMenu>
      {open && (
        <ContactPopup
          anchorRect={anchorRect}
          name={name}
          email={email}
          onClose={() => setOpen(false)}
          onCopyEmail={copyEmail}
          onSendEmail={sendEmail}
          onViewSender={onViewSender ? () => { setOpen(false); onViewSender(email); } : undefined}
          onMouseEnter={handlePopupMouseEnter}
          onMouseLeave={handlePopupMouseLeave}
        />
      )}
    </span>
  )
}

function RecipientRow({ label, value, onViewSender }) {
  const recipients = parseAddressList(value)
  if (recipients.length === 0) return null
  return (
    <div className={styles.recipientLine}>
      <span className={styles.recipientLabel}>{label}:</span>
      <span className={styles.recipientChips}>
        {recipients.map((r, i) => (
          <RecipientChip key={r.email + i} name={r.name} email={r.email} explicit={r.explicit} onViewSender={onViewSender} />
        ))}
      </span>
    </div>
  )
}

// onPrepareDrag(a) / onDragOut(e, a): the chip drags its file out of the window (desktop).
function AttachmentChip({ attachment, onOpen, onForward, onSaveAs, onSaveToDisk, onPrepareDrag, onDragOut }) {
  const [menu, setMenu] = useState(null) // { x, y } when the context menu is open
  const [busy, setBusy] = useState(false) // a download (open / save-as) is in flight
  // A drag refused because the file isn't on this Mac yet: the chip shakes once.
  const [refused, setRefused] = useState(false)
  useEffect(() => {
    if (!refused) return undefined
    const t = setTimeout(() => setRefused(false), 500)
    return () => clearTimeout(t)
  }, [refused])

  // Wrap an async action so the chip shows a spinner (in place of the file icon)
  // while it downloads. Re-entrancy guarded so a second click is a no-op.
  const run = (fn) => async () => {
    if (!fn || busy) return
    setBusy(true)
    try { await fn(attachment) } finally { setBusy(false) }
  }

  const handleContextMenu = (e) => {
    e.preventDefault()
    e.stopPropagation()
    setMenu({ x: e.clientX, y: e.clientY })
  }

  const items = [
    { value: 'open', icon: 'arrow.up.right', label: 'Open', onSelect: run(onOpen) },
    { value: 'forward', icon: 'arrowshape.turn.up.right', label: 'Forward', onSelect: run(onForward) },
    { separator: true },
    { value: 'save-as', icon: 'tray.and.arrow.down', label: 'Save as…', onSelect: run(onSaveAs) },
    ...(onSaveToDisk && !attachment.sealed ? [{ value: 'save-to-disk', icon: 'externaldrive', label: 'Save to Disk…', onSelect: () => onSaveToDisk(attachment) }] : []),
  ]

  // The ContextMenu portals to <body>, but React events bubble through the
  // component tree, not the DOM — so it must be a *sibling* of the clickable
  // chip, not a child, or a menu-item click would also fire the chip's onClick
  // ("Open") and open the file alongside the chosen action.
  return (
    <>
      <span className={`${styles.attachmentChip}${refused ? ` ${styles.attachmentRefused}` : ''}`}
        title={refused ? 'Open it once, then you can drag it out' : attachment.name} role="button" tabIndex={0}
        draggable={!!onDragOut}
        onPointerEnter={onPrepareDrag ? () => onPrepareDrag(attachment) : undefined}
        onDragStart={onDragOut ? (e) => { if (!onDragOut(e, attachment)) setRefused(true) } : undefined}
        onClick={run(onOpen)}
        onContextMenu={handleContextMenu}
        onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); run(onOpen)() } }}>
        {busy
          ? <span className={styles.attachmentSpinner} aria-label="Working" />
          : <FileIcon filename={attachment.name} size={16} />}
        <span className={styles.attachmentName}>{attachment.name}</span>
        {attachment.size && <span className={styles.attachmentSize}>{attachment.size}</span>}
      </span>
      <ContextMenu open={!!menu} position={menu} items={items} onClose={() => setMenu(null)} />
    </>
  )
}

export default function MessageDetails({ message, expanded, attachments, onAttachmentClick, onAttachmentForward, onAttachmentSaveAs, onAttachmentSaveToDisk, onAttachmentPrepareDrag, onAttachmentDragOut, onViewSender }) {
  if (!message) return null

  const recipients = [
    { label: 'To', value: message.to_address },
    { label: 'Cc', value: message.cc_address },
    { label: 'Bcc', value: message.bcc_address },
  ].filter(f => f.value)

  const expandedFields = [
    { label: 'Date', value: message.created_at ? new Date(message.created_at).toLocaleString() : null },
    { label: 'Subject', value: message.subject },
    { label: 'Message-ID', value: message.message_id_header },
    { label: 'In-Reply-To', value: message.in_reply_to },
    { label: 'References', value: message.references_header },
    { label: 'Content-Type', value: message.content_type },
  ].filter(f => f.value)

  const hasAttachments = attachments && attachments.length > 0

  if (recipients.length === 0 && !hasAttachments && !expanded) return null

  return (
    <div className={styles.metaBlock}>
      {recipients.map(f => (
        <RecipientRow key={f.label} label={f.label} value={f.value} onViewSender={onViewSender} />
      ))}
      {hasAttachments && (
        <div className={styles.attachmentList}>
          {attachments.map((a, i) => (
            <AttachmentChip
              key={a.name || i}
              attachment={a}
              onOpen={onAttachmentClick}
              onForward={onAttachmentForward}
              onSaveAs={onAttachmentSaveAs}
              onSaveToDisk={onAttachmentSaveToDisk}
              onPrepareDrag={onAttachmentPrepareDrag}
              onDragOut={onAttachmentDragOut}
            />
          ))}
        </div>
      )}
      {expanded && (
        <div className={styles.details}>
          {expandedFields.map(f => (
            <div key={f.label} className={styles.field}>
              <span className={styles.label}>{f.label}</span>
              <span className={styles.value}>{f.value}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
