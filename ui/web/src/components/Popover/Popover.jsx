import { useRef, useEffect, useCallback } from 'react'
import { createPortal } from 'react-dom'
import { positionFromAnchor, clampToViewport } from './positioning'
import styles from './Popover.module.css'

/**
 * Anchored, scrim-less, portal-to-body popover for arbitrary content.
 *
 * Not a menu (use DropdownMenu / ContextMenu) and not a modal (use Modal —
 * it has a scrim + centering). This floats next to an anchor, clamps itself
 * to the viewport, flips when it would overflow, and closes on Escape or an
 * outside mousedown.
 *
 * Position is supplied either way:
 *   anchorRect — a DOMRect (or rect-like). Placed relative to it via `placement`.
 *   position   — an explicit { top, left }. Clamped to the viewport.
 * Exactly one is expected; if both are given, anchorRect wins.
 *
 * Props:
 *   open                 — whether the popover is visible
 *   anchorRect           — DOMRect|rect-like to anchor against
 *   position             — { top, left } explicit point (alternative to anchorRect)
 *   placement            — 'bottom' | 'top' | 'left' | 'right' (default 'bottom')
 *   offset               — gap between anchor and popover (default 6)
 *   onClose              — called on Escape and outside mousedown
 *   closeOnOutsideClick  — close when a mousedown lands outside (default true)
 *   className            — extra class(es) on the popover surface
 *   styleVars            — [name, value] CSS custom-property pairs applied to the
 *                          surface (e.g. brandVars() — keeps callers inline-style-free)
 *   children             — popover contents
 *   ...rest              — forwarded to the surface (e.g. onMouseEnter/Leave)
 */
export default function Popover({
  open,
  anchorRect,
  position,
  placement = 'bottom',
  offset = 6,
  onClose,
  closeOnOutsideClick = true,
  className,
  styleVars,
  children,
  ...rest
}) {
  const popoverRef = useRef(null)

  // Apply caller-supplied CSS custom properties (e.g. per-channel brand vars)
  // onto the surface — avoids inline styles while letting CSS Modules theme off them.
  useEffect(() => {
    const node = popoverRef.current
    if (!node || !open || !styleVars) return
    for (const [name, value] of styleVars) node.style.setProperty(name, value)
  }, [open, styleVars])

  // Measure + place after mount and whenever the anchor/point/placement changes.
  useEffect(() => {
    const node = popoverRef.current
    if (!node || !open) return
    const size = { width: node.offsetWidth, height: node.offsetHeight }
    let coords
    if (anchorRect) {
      coords = positionFromAnchor(anchorRect, size, { placement, offset })
    } else if (position) {
      coords = clampToViewport(position, size)
    } else {
      return
    }
    node.style.setProperty('--popover-top', `${coords.top}px`)
    node.style.setProperty('--popover-left', `${coords.left}px`)
  }, [open, anchorRect, position, placement, offset])

  // Escape closes.
  useEffect(() => {
    if (!open) return
    const handler = (e) => { if (e.key === 'Escape') onClose?.() }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [open, onClose])

  // Outside mousedown closes.
  useEffect(() => {
    if (!open || !closeOnOutsideClick) return
    const handler = (e) => {
      if (popoverRef.current && !popoverRef.current.contains(e.target)) onClose?.()
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open, closeOnOutsideClick, onClose])

  // Stable ref callback so consumers can pass extra refs in future without churn.
  const setRef = useCallback((node) => { popoverRef.current = node }, [])

  if (!open) return null
  if (!anchorRect && !position) return null

  const classes = [styles.popover, className].filter(Boolean).join(' ')

  return createPortal(
    <div ref={setRef} className={classes} {...rest}>
      {children}
    </div>,
    document.body
  )
}
