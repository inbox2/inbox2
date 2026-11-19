import { useCallback, useEffect, useState } from 'react'
import { fetchText } from './fetchBytes'
import SandboxFrame from './SandboxFrame'
import styles from './Preview.module.css'

/* Markdown: marked, then DOMPurify, into the sandboxed frame. Raw shows the source. */
export default function MarkdownPreview({ node, url, onReady, onError }) {
  const [text, setText] = useState(null)
  const [html, setHtml] = useState(null)
  const [raw, setRaw] = useState(false)
  useEffect(() => {
    const ctl = new AbortController()
    ;(async () => {
      const [{ marked }, { default: DOMPurify }, src] = await Promise.all([import('marked'), import('dompurify'), fetchText(url, ctl.signal)])
      setText(src)
      setHtml(DOMPurify.sanitize(marked.parse(src, { async: false })))
      onReady()
    })().catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => ctl.abort()
  }, [url, onReady, onError])
  const fill = useCallback((doc) => { doc.body.innerHTML = html || '' }, [html])
  if (text == null) return null
  return (
    <div className={styles.doc}>
      <div className={styles.tools}>
        <button type="button" className={styles.tool} aria-pressed={!raw} onClick={() => setRaw(false)}>Rendered</button>
        <button type="button" className={styles.tool} aria-pressed={raw} onClick={() => setRaw(true)}>Raw</button>
      </div>
      {raw ? <pre className={styles.raw}>{text}</pre> : <SandboxFrame title={node.name} fill={fill} />}
    </div>
  )
}
