import { useState } from 'react'
import ContextMenu from './ContextMenu'
import { copyText } from '../../lib/otp'
import { formatMailbox } from '../../lib/emailAddress'
import styles from './AddressContextMenu.module.css'

/**
 * Right-click on an email address (From/To/Cc/Bcc, the context panel) →
 * Copy address / Copy name and address. Keyboard: the ContextMenu key or
 * Shift+F10 on it (and Enter/Space on the `focusable` wrapper). `name` is only a
 * name the header supplied (parseAddress `explicit`), never one derived from the
 * address. `focusable` makes the wrapper itself a tab stop — for plain text;
 * leave it off when the child is already focusable (a chip).
 */
export default function AddressContextMenu({ email, name, focusable = false, children }) {
  const [menu, setMenu] = useState(null)
  if (!email) return children

  const items = [
    { value: 'copy', icon: 'doc.on.doc', label: 'Copy address', onSelect: () => copyText(email) },
    ...(name && name !== email
      ? [{ value: 'copy-full', icon: 'person.fill', label: 'Copy name and address', onSelect: () => copyText(formatMailbox(name, email)) }]
      : []),
  ]

  // A keyboard-raised menu has no pointer position: open it under the target.
  const openAt = (e, x, y) => {
    const r = e.target.getBoundingClientRect()
    setMenu(x || y ? { x, y } : { x: r.left, y: r.bottom })
  }
  const onContextMenu = (e) => { e.preventDefault(); e.stopPropagation(); openAt(e, e.clientX, e.clientY) }
  const onKeyDown = (e) => {
    const activate = focusable && e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')
    if (activate || e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10')) {
      e.preventDefault(); e.stopPropagation(); openAt(e)
    }
  }

  return (
    // eslint-disable-next-line jsx-a11y/no-static-element-interactions -- role is set when focusable; otherwise it only catches events from a focusable child
    <span onContextMenu={onContextMenu} onKeyDown={onKeyDown}
      {...(focusable ? { tabIndex: 0, role: 'button', 'aria-haspopup': 'menu', className: styles.trigger } : {})}>
      {children}
      {/* The menu portals to <body> but React events still bubble through the tree:
          stop item clicks reaching a clickable ancestor (the card header collapses). */}
      {/* eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions -- event barrier, not a control */}
      <span onClick={(e) => e.stopPropagation()}>
        <ContextMenu open={!!menu} position={menu} items={items} onClose={() => setMenu(null)} />
      </span>
    </span>
  )
}
