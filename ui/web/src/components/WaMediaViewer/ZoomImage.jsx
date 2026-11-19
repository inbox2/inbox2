import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from 'react'
import Icon from '../Icon'
import styles from './WaMediaViewer.module.css'

const MIN = 1
const MAX = 8
const clamp = (v) => Math.min(MAX, Math.max(MIN, v))

/**
 * A photo that zooms and pans: scroll or pinch zooms toward the pointer, drag
 * pans once zoomed, double-click toggles 2.5×, and the toolbar (or the keys the
 * viewer forwards: + − 0 r) zooms, fits and rotates. Fit (1×) is the whole
 * photo inside the stage.
 */
const ZoomImage = forwardRef(function ZoomImage({ src, alt }, ref) {
  const stage = useRef(null)
  const [view, setView] = useState({ scale: 1, x: 0, y: 0, rot: 0 })
  const drag = useRef(null)

  // Zoom to `next` around a point given relative to the stage's centre.
  const zoomAt = useCallback((next, px = 0, py = 0) => {
    setView((v) => {
      const scale = clamp(next)
      if (scale === MIN) return { ...v, scale, x: 0, y: 0 }
      const k = scale / v.scale
      return { ...v, scale, x: px - (px - v.x) * k, y: py - (py - v.y) * k }
    })
  }, [])
  const fromCentre = (e) => {
    const r = stage.current.getBoundingClientRect()
    return [e.clientX - r.left - r.width / 2, e.clientY - r.top - r.height / 2]
  }

  useImperativeHandle(ref, () => ({
    zoomIn: () => setView((v) => ({ ...v, scale: clamp(v.scale * 1.4) })),
    zoomOut: () => zoomAt(view.scale / 1.4),
    fit: () => setView((v) => ({ ...v, scale: 1, x: 0, y: 0 })),
    rotate: () => setView((v) => ({ ...v, rot: (v.rot + 90) % 360 })),
  }), [zoomAt, view.scale])

  // Wheel and pinch (a pinch arrives as wheel + ctrlKey): non-passive, so the page doesn't scroll.
  useEffect(() => {
    const el = stage.current
    const onWheel = (e) => {
      e.preventDefault()
      const [px, py] = fromCentre(e)
      setView((v) => {
        const scale = clamp(v.scale * Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002)))
        if (scale === MIN) return { ...v, scale, x: 0, y: 0 }
        const k = scale / v.scale
        return { ...v, scale, x: px - (px - v.x) * k, y: py - (py - v.y) * k }
      })
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [])

  // The transform lives in custom properties (no inline styles).
  useEffect(() => {
    const el = stage.current
    el.style.setProperty('--zoom', String(view.scale))
    el.style.setProperty('--pan-x', `${view.x}px`)
    el.style.setProperty('--pan-y', `${view.y}px`)
    el.style.setProperty('--rot', `${view.rot}deg`)
  }, [view])

  const onPointerDown = (e) => {
    if (view.scale === 1 || e.button !== 0) return
    drag.current = { id: e.pointerId, sx: e.clientX, sy: e.clientY, x: view.x, y: view.y }
    stage.current.setPointerCapture(e.pointerId)
  }
  const onPointerMove = (e) => {
    const d = drag.current
    if (!d || d.id !== e.pointerId) return
    setView((v) => ({ ...v, x: d.x + e.clientX - d.sx, y: d.y + e.clientY - d.sy }))
  }
  const onPointerUp = () => { drag.current = null }
  const onDoubleClick = (e) => {
    const [px, py] = fromCentre(e)
    zoomAt(view.scale > 1 ? 1 : 2.5, px, py)
  }

  return (
    <div className={styles.zoomWrap}>
      <div
        ref={stage}
        className={`${styles.stage} ${view.scale > 1 ? styles.stagePan : ''}`}
        role="presentation"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onDoubleClick={onDoubleClick}
      >
        <img className={styles.zoomImg} src={src} alt={alt} draggable={false} />
      </div>
      <div className={styles.zoomBar} role="toolbar" aria-label="Zoom">
        <button type="button" className={styles.zoomBtn} onClick={() => zoomAt(view.scale / 1.4)} disabled={view.scale <= MIN} aria-label="Zoom out" title="Zoom out (−)"><Icon name="minus" size={12} /></button>
        <span className={styles.zoomPct} aria-live="polite">{Math.round(view.scale * 100)}%</span>
        <button type="button" className={styles.zoomBtn} onClick={() => zoomAt(view.scale * 1.4)} disabled={view.scale >= MAX} aria-label="Zoom in" title="Zoom in (+)"><Icon name="plus" size={12} /></button>
        <button type="button" className={styles.zoomBtn} onClick={() => setView((v) => ({ ...v, scale: 1, x: 0, y: 0 }))} title="Fit (0)">Fit</button>
        <button type="button" className={styles.zoomBtn} onClick={() => setView((v) => ({ ...v, rot: (v.rot + 90) % 360 }))} aria-label="Rotate" title="Rotate (R)"><Icon name="arrow.clockwise" size={12} /></button>
      </div>
    </div>
  )
})

export default ZoomImage
