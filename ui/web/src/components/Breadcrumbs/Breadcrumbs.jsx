import { useState, useRef, useEffect } from 'react'
import Popover from '../Popover'
import styles from './Breadcrumbs.module.css'

/**
 * DOS-style path, `C:\Projects\Q4`, with a blinking cursor. Every segment is a
 * button; the last one is the current folder. When the bar is narrow the middle
 * segments fold into a "..." button that opens them as a menu.
 *
 *   segments   [{ id, label }], drive first (lib/disk/paths.js pathSegments)
 *   onNavigate (segment, index) => void
 */
export default function Breadcrumbs({ segments, onNavigate }) {
  const [menuRect, setMenuRect] = useState(null)
  const menuRef = useRef(null)
  const moreRef = useRef(null)
  const last = segments.length - 1
  const middle = segments.length > 3 ? segments.slice(1, -1) : []

  useEffect(() => {
    if (menuRect) menuRef.current?.querySelector('button')?.focus()
  }, [menuRect])

  const closeMenu = () => {
    setMenuRect(null)
    moreRef.current?.focus()
  }

  const onMenuKey = (e) => {
    const items = [...menuRef.current.querySelectorAll('button')]
    const i = items.indexOf(document.activeElement)
    const to = { ArrowDown: items[(i + 1) % items.length], ArrowUp: items[(i - 1 + items.length) % items.length], Home: items[0], End: items.at(-1) }[e.key]
    if (to) { e.preventDefault(); to.focus() }
    if (e.key === 'Tab') setMenuRect(null)
  }

  const crumb = (seg, i) => (
    <button
      type="button"
      className={styles.seg}
      aria-current={i === last ? 'location' : undefined}
      onClick={() => onNavigate(seg, i)}
    >
      {seg.label}
    </button>
  )

  return (
    <nav className={styles.crumbs} aria-label="Path">
      <ol className={styles.list}>
        {segments.map((seg, i) => (
          <li key={seg.id ?? `drive-${i}`} className={middle.includes(seg) ? styles.middle : undefined}>
            {i > 1 && <span className={styles.sep} aria-hidden="true">\</span>}
            {crumb(seg, i)}
          </li>
        )).flatMap((li, i) => (i === 1 && middle.length ? [
          <li key="more" className={styles.more}>
            <button
              ref={moreRef}
              type="button"
              className={styles.seg}
              aria-label={`${middle.length} more folders`}
              aria-haspopup="menu"
              aria-expanded={Boolean(menuRect)}
              // Keep the Popover's outside-mousedown from closing the menu before this click toggles it.
              onMouseDown={(e) => menuRect && e.stopPropagation()}
              onClick={(e) => setMenuRect(menuRect ? null : e.currentTarget.getBoundingClientRect())}
            >
              ...
            </button>
          </li>,
          li,
        ] : [li]))}
      </ol>
      <span className={styles.cursor} aria-hidden="true">_</span>
      <Popover open={Boolean(menuRect)} anchorRect={menuRect} onClose={closeMenu} className={`management ${styles.menu}`}>
        <div ref={menuRef} role="menu" tabIndex={-1} aria-label="Folders in the path" onKeyDown={onMenuKey}>
          {middle.map((seg) => (
            <button
              key={seg.id}
              type="button"
              role="menuitem"
              className={styles.menuItem}
              onClick={() => { setMenuRect(null); onNavigate(seg, segments.indexOf(seg)) }}
            >
              {seg.label}
            </button>
          ))}
        </div>
      </Popover>
    </nav>
  )
}
