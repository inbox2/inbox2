import { useEffect, useState } from 'react'
import { fetchText } from './fetchBytes'
import { parseCsv } from '../../../lib/disk/preview/csv'
import styles from './Preview.module.css'

const MAX_ROWS = 2000

/* CSV and TSV as a table; the first 2,000 rows (Download has the rest). */
export default function CsvPreview({ url, onReady, onError }) {
  const [data, setData] = useState(null)
  useEffect(() => {
    const ctl = new AbortController()
    fetchText(url, ctl.signal)
      .then((text) => { setData(parseCsv(text, { maxRows: MAX_ROWS })); onReady() })
      .catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => ctl.abort()
  }, [url, onReady, onError])
  if (!data) return null
  const [head, ...rows] = data.rows
  return (
    <div className={styles.doc}>
      <div className={styles.tableWrap}>
        <table className={styles.sheet}>
          <thead><tr>{(head || []).map((c, i) => <th key={i}>{c}</th>)}</tr></thead>
          <tbody>{rows.map((r, i) => <tr key={i}>{r.map((c, j) => <td key={j}>{c}</td>)}</tr>)}</tbody>
        </table>
      </div>
      {data.truncated && <p className={styles.note}>Showing the first {MAX_ROWS.toLocaleString()} rows. Download the file for the rest.</p>}
    </div>
  )
}
