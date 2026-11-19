import { useEffect, useRef, useState, useCallback } from 'react'
import { createPortal } from 'react-dom'
import Icon from '../Icon'
import SubmenuItem from './SubmenuItem'
import styles from './DropdownMenu.module.css'

export default function DropdownMenu({ trigger, items, value, align = 'right', direction = 'down', variant, open: controlledOpen, onOpenChange }) {
  // Controlled when `open` is supplied; otherwise the menu owns its own state.
  // This lets callers (e.g. the composer's "/" shortcut) open it programmatically.
  const isControlled = controlledOpen !== undefined
  const [uncontrolledOpen, setUncontrolledOpen] = useState(false)
  const open = isControlled ? controlledOpen : uncontrolledOpen
  const triggerRef = useRef(null)
  const menuRef = useRef(null)

  // Stable setter that reads the latest `open` from a ref, so the effect below
  // doesn't need to re-subscribe its listeners on every render.
  const openRef = useRef(open)
  useEffect(() => { openRef.current = open }, [open])
  const setOpen = useCallback((next) => {
    const resolved = typeof next === 'function' ? next(openRef.current) : next
    if (!isControlled) setUncontrolledOpen(resolved)
    onOpenChange?.(resolved)
  }, [isControlled, onOpenChange])

  const handleToggle = useCallback(() => {
    setOpen(prev => !prev)
  }, [setOpen])

  // Position menu after it mounts. `direction="up"` anchors the menu's bottom
  // to the trigger's top so it grows upward (for triggers near the viewport edge).
  // Either way it flips to the other side when it would not fit and that side has
  // more room, so a trigger near the bottom of the window never opens off-screen.
  const menuCallbackRef = useCallback((node) => {
    menuRef.current = node
    if (node && triggerRef.current) {
      const r = triggerRef.current.getBoundingClientRect()
      const h = node.offsetHeight
      const below = window.innerHeight - r.bottom - 8
      const above = r.top - 8
      const up = direction === 'up' ? !(h > above && below > above) : h > below && above > below
      node.dataset.direction = up ? 'up' : 'down'
      if (up) {
        node.style.setProperty('--menu-bottom', `${window.innerHeight - r.top + 4}px`)
      } else {
        node.style.setProperty('--menu-top', `${r.bottom + 4}px`)
      }
      node.style.setProperty('--menu-left', align === 'right' ? `${r.right}px` : `${r.left}px`)
    }
  }, [align, direction])

  useEffect(() => {
    if (!open) return
    const handler = (e) => {
      if (triggerRef.current?.contains(e.target)) return
      if (menuRef.current?.contains(e.target)) return
      setOpen(false)
    }
    const escHandler = (e) => {
      if (e.key === 'Escape') setOpen(false)
    }
    window.addEventListener('mousedown', handler)
    window.addEventListener('keydown', escHandler)
    return () => {
      window.removeEventListener('mousedown', handler)
      window.removeEventListener('keydown', escHandler)
    }
  }, [open, setOpen])

  return (
    <>
      <div ref={triggerRef} role="presentation" onClick={handleToggle} className={styles.triggerWrap}>
        {trigger}
      </div>
      {open && createPortal(
        <div
          ref={menuCallbackRef}
          className={styles.menu}
          data-align={align}
          data-direction={direction}
          data-variant={variant}
          data-m-tokens={variant === 'light' ? '' : undefined}
        >
          {items.map((item, i) => {
            if (item.separator) return <div key={i} className={styles.separator} />
            if (item.submenu) return <SubmenuItem key={item.value ?? i} item={item} onClose={() => setOpen(false)} />
            const active = value != null && item.value === value
            return (
              <button
                key={item.value ?? i}
                className={`${styles.menuItem} ${active ? styles.menuItemActive : ''} ${item.danger ? styles.menuItemDanger : ''}`}
                onClick={() => {
                  item.onSelect?.()
                  setOpen(false)
                }}
              >
                {item.icon && <Icon name={item.icon} size={12} className={styles.menuItemIcon} />}
                <span className={styles.menuItemLabel}>{item.label}</span>
                {item.shortcut && <span className={styles.menuItemShortcut}>{item.shortcut}</span>}
                {active && <Icon name="checkmark" size={10} className={styles.menuItemCheck} />}
              </button>
            )
          })}
        </div>,
        document.body
      )}
    </>
  )
}
