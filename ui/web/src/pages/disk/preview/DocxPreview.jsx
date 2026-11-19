import { useCallback, useEffect, useState } from 'react'
import { fetchBlob } from './fetchBytes'
import SandboxFrame from './SandboxFrame'
import styles from './Preview.module.css'

/* Word (.docx) through docx-preview, drawn straight into the sandboxed frame:
   text, headings, tables, images (as data URLs). An approximate view. */
export default function DocxPreview({ node, url, onReady, onError }) {
  const [blob, setBlob] = useState(null)
  useEffect(() => {
    const ctl = new AbortController()
    fetchBlob(url, ctl.signal).then(setBlob).catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => ctl.abort()
  }, [url, onError])
  const fill = useCallback(async (doc) => {
    if (!blob) return
    try {
      const { renderAsync } = await import('docx-preview')
      doc.body.style.padding = '0'
      doc.body.style.background = '#e9e5db'
      await renderAsync(blob, doc.body, doc.head, { useBase64URL: true, inWrapper: true, ignoreLastRenderedPageBreak: true })
      onReady()
    } catch (e) {
      onError(e)
    }
  }, [blob, onReady, onError])
  return blob ? (
    <div className={styles.doc}>
      <p className={styles.note}>Quick view: layout can differ from Word.</p>
      <SandboxFrame title={node.name} fill={fill} />
    </div>
  ) : null
}
