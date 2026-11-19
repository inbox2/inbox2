import { useRef } from 'react'

const TEXT_FIELD = 'input, textarea, select, [contenteditable="true"]'
const LONG_PRESS_MS = 500
// A long press is followed by contextmenu (some browsers) and a click; swallow both.
const AFTER_PRESS_MS = 700

/**
 * Handlers that open a custom context menu from all three inputs spec F1 asks for:
 * right-click, the menu key or Shift+F10 on the focused element, and a half-second
 * touch press. Text fields keep the browser's own menu. Spread the result on the
 * row, tile or list container and render the library's ContextMenu at the point.
 *
 *   onOpen  ({ x, y }, target) => void
 */
export default function useContextMenuTrigger(onOpen) {
  const press = useRef(null)
  const pressedAt = useRef(0)

  const endPress = () => {
    if (press.current) clearTimeout(press.current.timer)
    press.current = null
  }

  return {
    onContextMenu(e) {
      if (e.target.closest(TEXT_FIELD)) return
      e.preventDefault()
      if (Date.now() - pressedAt.current < AFTER_PRESS_MS) return
      onOpen({ x: e.clientX, y: e.clientY }, e.target)
    },
    onKeyDown(e) {
      if (e.key !== 'ContextMenu' && !(e.key === 'F10' && e.shiftKey)) return
      if (e.target.closest(TEXT_FIELD)) return
      e.preventDefault()
      const r = e.target.getBoundingClientRect()
      onOpen({ x: r.left + 24, y: r.bottom }, e.target)
    },
    onPointerDown(e) {
      if (e.pointerType !== 'touch' || e.target.closest(TEXT_FIELD)) return
      const { clientX: x, clientY: y, target } = e
      endPress()
      press.current = {
        x, y,
        timer: setTimeout(() => {
          press.current = null
          pressedAt.current = Date.now()
          onOpen({ x, y }, target)
        }, LONG_PRESS_MS),
      }
    },
    onPointerMove(e) {
      if (press.current && Math.hypot(e.clientX - press.current.x, e.clientY - press.current.y) > 10) endPress()
    },
    onPointerUp: endPress,
    onPointerCancel: endPress,
    onClickCapture(e) {
      if (Date.now() - pressedAt.current < AFTER_PRESS_MS) {
        e.preventDefault()
        e.stopPropagation()
      }
    },
  }
}
