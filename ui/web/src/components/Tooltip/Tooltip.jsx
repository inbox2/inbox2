import { useState, useRef, useEffect, useCallback } from 'react'
import { createPortal } from 'react-dom'
import styles from './Tooltip.module.css'

export default function Tooltip({ content, children }) {
  const [visible, setVisible] = useState(false)
  const triggerRef = useRef(null)
  const tipRef = useRef(null)

  const position = useCallback(() => {
    const trigger = triggerRef.current
    const tip = tipRef.current
    if (!trigger || !tip) return
    const rect = trigger.getBoundingClientRect()
    const tipW = tip.offsetWidth
    const tipH = tip.offsetHeight
    let left = rect.left + rect.width / 2 - tipW / 2
    if (left < 4) left = 4
    if (left + tipW > window.innerWidth - 4) left = window.innerWidth - tipW - 4
    tip.style.setProperty('--tip-x', `${left}px`)

    // Flip below trigger when there's not enough room above
    if (rect.top - 6 - tipH < 4) {
      tip.style.setProperty('--tip-y', `${rect.bottom + 6}px`)
      tip.dataset.placement = 'below'
    } else {
      tip.style.setProperty('--tip-y', `${rect.top - 6}px`)
      tip.dataset.placement = 'above'
    }
  }, [])

  useEffect(() => {
    if (!visible) return
    // Double rAF: first lets the browser lay out the portal, second measures it
    const id = requestAnimationFrame(() => requestAnimationFrame(position))
    return () => cancelAnimationFrame(id)
  }, [visible, position])

  return (
    <>
      <span
        ref={triggerRef}
        className={styles.trigger}
        role="presentation"
        onMouseEnter={() => setVisible(true)}
        onMouseLeave={() => setVisible(false)}
      >
        {children}
      </span>
      {visible && createPortal(
        <div ref={tipRef} className={styles.tooltip}>
          {content}
        </div>,
        document.body
      )}
    </>
  )
}
