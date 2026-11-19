import { useEffect, useId, useRef } from 'react'
import { createPortal } from 'react-dom'
import { ActionIcon } from '../FileTypeIcon'
import { trapTab } from '../../lib/focusTrap'
import styles from './SlideOver.module.css'

const TYPING = /^(INPUT|TEXTAREA|SELECT)$/

/**
 * Right-hand panel over the page (Disk's file preview, spec F5). Traps Tab,
 * closes on Escape or a scrim click, gives focus back to whatever opened it.
 * Left and right arrows step to the previous and next item. Full screen on phones.
 *
 *   open, onClose
 *   title     heading text; icon  node before it
 *   actions   node for the bar under the header (Download, Share, ...)
 *   onPrev, onNext  step handlers; pass null at either end to disable the button
 */
export default function SlideOver({ open, onClose, title, icon, actions, onPrev, onNext, children }) {
  const panelRef = useRef(null)
  const closeRef = useRef(null)
  const titleId = useId()

  useEffect(() => {
    if (!open) return undefined
    const back = document.activeElement
    closeRef.current?.focus()
    return () => { if (back?.isConnected) back.focus() }
  }, [open])

  // Stepping to the last item disables the button that had focus; keep focus in the panel.
  useEffect(() => {
    if (panelRef.current && document.activeElement === document.body) closeRef.current?.focus()
  }, [onPrev, onNext])

  if (!open) return null

  const onKeyDown = (e) => {
    if (e.key === 'Escape') { e.stopPropagation(); onClose(); return }
    if (e.key === 'Tab') { trapTab(e, panelRef.current); return }
    if (TYPING.test(e.target.tagName) || e.target.isContentEditable) return
    const step = { ArrowLeft: onPrev, ArrowRight: onNext }[e.key]
    if (step) { e.preventDefault(); step() }
  }

  return createPortal(
    <div className={`management ${styles.layer}`}>
      <div className={styles.scrim} onClick={onClose} aria-hidden="true" />
      <div ref={panelRef} className={styles.panel} role="dialog" aria-modal="true" aria-labelledby={titleId} onKeyDown={onKeyDown}>
        <div className={styles.head}>
          {icon}
          <h2 id={titleId} className={styles.title}>{title}</h2>
          {(onPrev !== undefined || onNext !== undefined) && <>
            <button type="button" className={styles.x} onClick={onPrev} disabled={!onPrev} aria-label="Previous" title="Previous (Left arrow)">
              <ActionIcon name="chevronLeft" />
            </button>
            <button type="button" className={styles.x} onClick={onNext} disabled={!onNext} aria-label="Next" title="Next (Right arrow)">
              <ActionIcon name="chevronRight" />
            </button>
          </>}
          <button ref={closeRef} type="button" className={styles.x} onClick={onClose} aria-label="Close" title="Close (Esc)">
            <ActionIcon name="x" />
          </button>
        </div>
        {actions && <div className={styles.bar}>{actions}</div>}
        <div className={styles.body}>{children}</div>
      </div>
    </div>,
    document.body,
  )
}
