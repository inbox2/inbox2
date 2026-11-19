import { useCallback, useEffect, useState } from 'react'
import { fetchBuffer } from './fetchBytes'
import SandboxFrame from './SandboxFrame'
import styles from './Preview.module.css'

const MAX_ROWS = 5000

/* Spreadsheets (xlsx, xls, ods, numbers) through SheetJS, every sheet as a tab
   with its cached values; no recalculation, charts or pivots. */
export default function SheetPreview({ node, url, onReady, onError }) {
  const [book, setBook] = useState(null)
  const [sheet, setSheet] = useState(0)
  useEffect(() => {
    const ctl = new AbortController()
    ;(async () => {
      const [XLSX, buf] = await Promise.all([import('xlsx'), fetchBuffer(url, ctl.signal)])
      const wb = XLSX.read(buf, { sheetRows: MAX_ROWS, cellHTML: false })
      setBook({ XLSX, wb })
      onReady()
    })().catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => ctl.abort()
  }, [url, onReady, onError])
  const fill = useCallback((doc) => {
    if (!book) return
    const { XLSX, wb } = book
    doc.body.innerHTML = XLSX.utils.sheet_to_html(wb.Sheets[wb.SheetNames[sheet]], { header: '', footer: '' })
  }, [book, sheet])
  if (!book) return null
  return (
    <div className={styles.doc}>
      <p className={styles.note}>Shows saved values, up to {MAX_ROWS.toLocaleString()} rows a sheet.</p>
      <SandboxFrame title={node.name} fill={fill} />
      <div className={styles.tabs} role="tablist" aria-label="Sheets">
        {book.wb.SheetNames.map((n, i) => (
          <button key={n} type="button" role="tab" aria-selected={i === sheet} className={styles.tab} onClick={() => setSheet(i)}>{n}</button>
        ))}
      </div>
    </div>
  )
}
