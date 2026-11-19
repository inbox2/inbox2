import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import IconButton from '../IconButton'
import { focusables, trapTab } from '../../lib/focusTrap'
import styles from './Modal.module.css'

/**
 * Shared modal shell — overlay + panel + optional close button.
 *
 * Props:
 *   open        — whether the modal is visible
 *   onClose     — called on overlay click and Escape
 *   showClose   — render the close (×) button (default true)
 *   className   — extra class(es) on the panel
 *   overlayClassName — extra class(es) on the overlay
 *   titleId     — id of the heading inside the panel (→ aria-labelledby)
 *   aria-label  — accessible name when there is no heading to point at
 *   children    — panel contents
 *
 * Focus moves into the panel on open (first focusable, else the panel), Tab
 * wraps inside it, and focus returns to the opener on close.
 */
export default function Modal({
  open,
  onClose,
  showClose = true,
  className,
  overlayClassName,
  titleId,
  'aria-label': ariaLabel,
  children,
}) {
  const panelRef = useRef(null)

  useEffect(() => {
    if (!open) return
    const handler = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', handler, true)
    return () => window.removeEventListener('keydown', handler, true)
  }, [open, onClose])

  useEffect(() => {
    if (!open || !panelRef.current) return undefined
    const back = document.activeElement
    const panel = panelRef.current
    if (!panel.contains(document.activeElement)) {
      // Skip the × so a form's first field (or the panel itself) gets focus.
      const first = focusables(panel).find((el) => !el.dataset.modalClose) || panel
      first.focus()
    }
    return () => { if (back?.isConnected) back.focus() }
  }, [open])

  if (!open) return null

  const overlayClasses = [styles.overlay, overlayClassName].filter(Boolean).join(' ')
  const panelClasses = [styles.panel, className].filter(Boolean).join(' ')

  return createPortal(
    <div className={overlayClasses} role="presentation" onClick={onClose} data-overlay-open>
      <div
        ref={panelRef}
        className={panelClasses}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-label={titleId ? undefined : ariaLabel}
        tabIndex={-1}
        onClick={e => e.stopPropagation()}
        onKeyDown={(e) => trapTab(e, panelRef.current)}
      >
        {showClose && (
          <IconButton
            className={styles.close}
            icon="xmark"
            onClick={onClose}
            aria-label="Close"
            data-modal-close
          />
        )}
        {children}
      </div>
    </div>,
    document.body
  )
}
