import { useEffect, useRef, useState } from 'react'
import { fetchBuffer } from './fetchBytes'
import styles from './Preview.module.css'

// PDFium scale per zoom step; 4/3 (96 / 72 dpi) is 100%.
const ZOOMS = [2 / 3, 1, 4 / 3, 5 / 3, 2, 8 / 3]

/* PDF through PDFium (WASM): one page drawn at a time, so page 150 of 200 is
   as quick as page 1. Search reads page text and jumps to the next match. */
export default function PdfPreview({ url, onReady, onError }) {
  const [doc, setDoc] = useState(null)
  const [page, setPage] = useState(0)
  const [jump, setJump] = useState(null) // what is being typed into the page number, until it names a real page
  const [zoom, setZoom] = useState(2)
  // The page fits the pane's width until the person zooms (a phone pane is narrower than 133%).
  const [fit, setFit] = useState(true)
  const [query, setQuery] = useState('')
  const [hit, setHit] = useState(null)
  const canvasRef = useRef(null)

  useEffect(() => {
    const ctl = new AbortController()
    let opened
    ;(async () => {
      const [{ openPdf }, buf] = await Promise.all([import('../../../lib/disk/preview/pdfium'), fetchBuffer(url, ctl.signal)])
      opened = await openPdf(new Uint8Array(buf))
      if (ctl.signal.aborted) return opened.close()
      setDoc(opened)
    })().catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => { ctl.abort(); opened?.close() }
  }, [url, onError])

  useEffect(() => {
    if (!doc || !canvasRef.current) return
    try {
      const img = doc.render(page, ZOOMS[zoom] * (window.devicePixelRatio || 1))
      const c = canvasRef.current
      c.width = img.width
      c.height = img.height
      c.style.setProperty('--w', `${img.width / (window.devicePixelRatio || 1)}px`)
      c.getContext('2d').putImageData(img, 0, 0)
      onReady()
    } catch (e) {
      onError(e)
    }
  }, [doc, page, zoom, onReady, onError])

  const find = () => {
    const q = query.trim().toLowerCase()
    if (!q || !doc) return
    for (let k = 1; k <= doc.pages; k++) {
      const i = (page + k) % doc.pages
      if (doc.text(i).toLowerCase().includes(q)) { setPage(i); setHit(i); return }
    }
    setHit(-1)
  }

  return (
    <div className={styles.pdf}>
      {doc && (
        <div className={styles.tools}>
          <form className={styles.find} onSubmit={(e) => { e.preventDefault(); find() }}>
            <input type="search" value={query} onChange={(e) => { setQuery(e.target.value); setHit(null) }} placeholder="Find in PDF" aria-label="Find in PDF" />
            {hit === -1 && <span className={styles.toolText}>No match</span>}
          </form>
          <button type="button" className={styles.tool} disabled={page === 0} onClick={() => setPage(page - 1)} aria-label="Previous page">‹</button>
          <label className={styles.pageField}>
            <input
              type="text" inputMode="numeric" value={jump ?? page + 1} aria-label="Page" size={String(doc.pages).length}
              onFocus={(e) => e.target.select()}
              onChange={(e) => {
                const text = e.target.value.replace(/\D/g, '')
                const n = Number(text) - 1
                if (text && n >= 0 && n < doc.pages) { setPage(n); setJump(null) } else setJump(text)
              }}
              onBlur={() => setJump(null)}
            />
            / {doc.pages}
          </label>
          <button type="button" className={styles.tool} disabled={page >= doc.pages - 1} onClick={() => setPage(page + 1)} aria-label="Next page">›</button>
        </div>
      )}
      <div className={styles.stage}>
        <div className={styles.pdfPage}><canvas ref={canvasRef} className={[styles.canvas, fit ? styles.canvasFit : ''].join(' ')} /></div>
        {/* Zoom floats over the page's bottom right, outside the scroller so it stays put. */}
        {doc && (
          <div className={styles.zoom} role="group" aria-label="Zoom">
            <button type="button" className={styles.tool} disabled={zoom === 0} onClick={() => { setFit(false); setZoom(zoom - 1) }} aria-label="Zoom out">−</button>
            <span className={styles.toolText}>{fit ? 'Fit' : `${Math.round(ZOOMS[zoom] * 75)}%`}</span>
            <button type="button" className={styles.tool} disabled={zoom === ZOOMS.length - 1} onClick={() => { setFit(false); setZoom(zoom + 1) }} aria-label="Zoom in">+</button>
          </div>
        )}
      </div>
    </div>
  )
}
