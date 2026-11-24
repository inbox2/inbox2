import { useEffect, useRef, useState } from 'react'
import Icon from '../Icon'
import styles from './DropdownMenu.module.css'

/**
 * A submenu entry (`{ label, icon, submenu: [...] }`) shared by DropdownMenu and
 * ContextMenu. Recursive, so a submenu may nest another (Triage › Move to Space ›).
 * Opens on hover and on keyboard focus (CSS :focus-within), so Tab reaches every
 * item. A sub-item with `checked` shows a checkmark.
 */
/**
 * A row that does its own thing on click, with a trailing … that opens a submenu
 * of more actions (`{ label, icon, onSelect, more: [...] }`): one row per thing
 * instead of a second list repeating the first. The submenu opens on hover or
 * focus of the … only, so moving down the list doesn't pop it on every row.
 */
export function MoreItem({ item, onClose }) {
  const wrapRef = useRef(null)
  const subRef = useRef(null)
  const closeTimer = useRef(null)
  const [open, setOpen] = useState(false)
  useEffect(() => () => clearTimeout(closeTimer.current), [])

  function place() {
    const wrap = wrapRef.current, sub = subRef.current
    if (!wrap || !sub) return
    const r = wrap.getBoundingClientRect()
    wrap.toggleAttribute('data-flip', r.right + sub.offsetWidth > window.innerWidth && r.left - sub.offsetWidth >= 0)
    const overflow = r.top + sub.offsetHeight - (window.innerHeight - 8)
    wrap.style.setProperty('--submenu-shift', `${Math.max(0, Math.min(overflow, r.top - 8))}px`)
  }
  const show = () => { clearTimeout(closeTimer.current); setOpen(true); requestAnimationFrame(place) }
  // Leaving the row closes it after a beat, so the pointer can cross the gap into the menu.
  const hideSoon = () => { clearTimeout(closeTimer.current); closeTimer.current = setTimeout(() => setOpen(false), 250) }

  return (
    <div ref={wrapRef} className={`${styles.submenuWrap} ${styles.moreRow}`} role="presentation"
      data-open={open ? '' : undefined}
      onMouseLeave={hideSoon}
      onBlur={(e) => { if (!wrapRef.current?.contains(e.relatedTarget)) setOpen(false) }}>
      <button type="button" role="menuitem" className={styles.menuItem} data-more-row=""
        onClick={() => { item.onSelect?.(); onClose() }}>
        {typeof item.icon === 'string'
          ? <Icon name={item.icon} size={12} className={styles.menuItemIcon} />
          : item.icon && <span className={styles.menuItemIcon}>{item.icon}</span>}
        <span className={styles.menuItemLabel}>{item.label}</span>
      </button>
      <button type="button" role="menuitem" className={styles.moreButton} aria-haspopup="menu" aria-expanded={open}
        aria-label={`More for ${item.label}`}
        onMouseEnter={show} onFocus={show}
        // Always opens: a tap fires enter/focus first, so a toggle would shut it again.
        onClick={show}>
        <Icon name="ellipsis" size={11} />
      </button>
      <div ref={subRef} className={styles.submenu} role="menu" tabIndex={-1} onMouseEnter={show}>
        {item.more.map((sub, j) => (
          <button key={sub.value ?? j} type="button" role="menuitem" className={styles.menuItem}
            onClick={() => { sub.onSelect?.(); onClose() }}>
            {sub.icon && <Icon name={sub.icon} size={12} className={styles.menuItemIcon} />}
            <span className={styles.menuItemLabel}>{sub.label}</span>
          </button>
        ))}
      </div>
    </div>
  )
}

export default function SubmenuItem({ item, onClose }) {
  const wrapRef = useRef(null)
  const subRef = useRef(null)

  // Keep the opened submenu inside the window: flip it leftwards past the right
  // edge, and lift it when it would run off the bottom. Measured on open (the
  // :hover / :focus-within rule has already displayed it by the time these fire).
  function place() {
    const wrap = wrapRef.current, sub = subRef.current
    if (!wrap || !sub) return
    const r = wrap.getBoundingClientRect()
    const w = sub.offsetWidth, h = sub.offsetHeight
    wrap.toggleAttribute('data-flip', r.right + w > window.innerWidth && r.left - w >= 0)
    const overflow = r.top + h - (window.innerHeight - 8)
    wrap.style.setProperty('--submenu-shift', `${Math.max(0, Math.min(overflow, r.top - 8))}px`)
  }

  return (
    <div ref={wrapRef} className={styles.submenuWrap} role="presentation" onMouseEnter={place} onFocus={place}>
      <button type="button" className={styles.menuItem} aria-haspopup="menu">
        {item.icon && <Icon name={item.icon} size={12} className={styles.menuItemIcon} />}
        <span className={styles.menuItemLabel}>{item.label}</span>
        <Icon name="chevron.right" size={8} className={styles.submenuChevron} />
      </button>
      <div ref={subRef} className={styles.submenu} role="menu">
        {item.submenu.map((sub, j) => {
          if (sub.separator) return <div key={j} className={styles.separator} />
          if (sub.submenu) return <SubmenuItem key={sub.value ?? j} item={sub} onClose={onClose} />
          return (
            <button
              key={sub.value ?? j}
              type="button"
              role="menuitem"
              className={styles.menuItem}
              onClick={() => { sub.onSelect?.(); onClose() }}
            >
              {sub.icon && <Icon name={sub.icon} size={12} className={styles.menuItemIcon} />}
              <span className={styles.menuItemLabel}>{sub.label}</span>
              {sub.shortcut && <span className={styles.menuItemShortcut}>{sub.shortcut}</span>}
              {sub.checked && <Icon name="checkmark" size={10} className={styles.menuItemCheck} />}
            </button>
          )
        })}
      </div>
    </div>
  )
}
