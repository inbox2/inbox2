import { useEffect, useRef, useCallback } from 'react'
import { createPortal } from 'react-dom'
import Icon from '../Icon'
import SubmenuItem from './SubmenuItem'
import styles from './DropdownMenu.module.css'

const EDGE = 8

// The buttons of one menu level (submenu triggers included, separators skipped).
function levelItems(menu) {
  return [...menu.children].flatMap((c) => {
    if (c.tagName === 'BUTTON') return [c]
    const trigger = c.querySelector(':scope > button')
    return trigger ? [trigger] : []
  })
}

/**
 * Context menu — same visual style as DropdownMenu but positioned
 * at an arbitrary {x, y} screen coordinate (e.g. from a right-click).
 * It stays on screen near an edge, focuses its first item, moves with the
 * arrow keys / Home / End (Right and Left enter and leave a submenu), and
 * Escape, Tab or choosing an item hand focus back to what had it before.
 *
 * Props:
 *   open     — boolean, whether the menu is visible
 *   position — { x, y } in viewport pixels
 *   items    — same shape as DropdownMenu items; `icon` is an SF Symbol name or a node;
 *              `{ heading }` is a non-interactive label (e.g. "3 items selected")
 *   onClose  — called when the menu should dismiss
 */
export default function ContextMenu({ open, position, items, onClose, variant }) {
  const menuRef = useRef(null)
  const openerRef = useRef(null)
  const restoreRef = useRef(false)

  const menuCallbackRef = useCallback((node) => {
    menuRef.current = node
    if (node && position) {
      const x = Math.max(EDGE, Math.min(position.x, window.innerWidth - node.offsetWidth - EDGE))
      const y = Math.max(EDGE, Math.min(position.y, window.innerHeight - node.offsetHeight - EDGE))
      node.style.setProperty('--menu-top', `${y}px`)
      node.style.setProperty('--menu-left', `${x}px`)
    }
  }, [position])

  // Remember the opener, focus the first item; on close, give focus back when
  // the close came from the keyboard or an item (not a click elsewhere).
  useEffect(() => {
    if (!open) return undefined
    openerRef.current = document.activeElement
    restoreRef.current = false
    const menu = menuRef.current
    if (menu) levelItems(menu)[0]?.focus({ preventScroll: true })
    return () => {
      const opener = openerRef.current
      if (restoreRef.current && opener?.isConnected) opener.focus({ preventScroll: true })
    }
  }, [open])

  const close = useCallback((restore) => {
    restoreRef.current = restore
    onClose()
  }, [onClose])

  useEffect(() => {
    if (!open) return
    // React runs this effect inside the right-click that opened the menu, so that
    // same contextmenu event still reaches the window listener below: ignore it.
    const openedAt = performance.now()
    const handler = (e) => {
      if (e.timeStamp < openedAt || menuRef.current?.contains(e.target)) return
      close(false)
    }
    const escHandler = (e) => {
      if (e.key === 'Escape') close(true)
    }
    window.addEventListener('mousedown', handler)
    window.addEventListener('keydown', escHandler)
    window.addEventListener('contextmenu', handler)
    return () => {
      window.removeEventListener('mousedown', handler)
      window.removeEventListener('keydown', escHandler)
      window.removeEventListener('contextmenu', handler)
    }
  }, [open, close])

  if (!open || !position) return null

  // Keys stay in the menu: the page's own shortcuts (j/k, arrows, e) must not
  // act on the list behind it while the menu has focus.
  const onKeyDown = (e) => {
    e.stopPropagation()
    const active = document.activeElement
    const level = active?.closest('[role="menu"]')
    if (!level) return
    const list = levelItems(level)
    const i = list.indexOf(active)
    const to = {
      ArrowDown: list[(i + 1) % list.length],
      ArrowUp: list[(i - 1 + list.length) % list.length],
      Home: list[0],
      End: list[list.length - 1],
      ArrowRight: active.getAttribute('aria-haspopup') ? active.nextElementSibling?.querySelector('button') : null,
      ArrowLeft: level !== menuRef.current ? level.previousElementSibling : null,
    }[e.key]
    if (to) { e.preventDefault(); to.focus(); return }
    if (e.key === 'Escape' || e.key === 'Tab') {
      e.preventDefault()
      close(true)
    }
  }

  return createPortal(
    <div
      ref={menuCallbackRef}
      className={styles.menu}
      data-align="left"
      data-variant={variant}
      data-m-tokens={variant === 'light' ? '' : undefined}
      role="menu"
      tabIndex={-1}
      onKeyDown={onKeyDown}
    >
      {items.map((item, i) => {
        if (item.separator) return <div key={i} className={styles.separator} />
        if (item.heading) return <div key={i} className={styles.menuHeading}>{item.heading}</div>
        if (item.submenu) return <SubmenuItem key={item.value ?? i} item={item} onClose={() => close(true)} />
        return (
          <button
            key={item.value ?? i}
            type="button"
            role="menuitem"
            className={`${styles.menuItem} ${item.danger ? styles.menuItemDanger : ''}`}
            onClick={() => {
              item.onSelect?.()
              close(true)
            }}
          >
            {typeof item.icon === 'string'
              ? <Icon name={item.icon} size={12} className={styles.menuItemIcon} />
              : item.icon && <span className={styles.menuItemIcon}>{item.icon}</span>}
            <span className={styles.menuItemLabel}>{item.label}</span>
            {item.shortcut && <span className={styles.menuItemShortcut}>{item.shortcut}</span>}
          </button>
        )
      })}
    </div>,
    document.body
  )
}
