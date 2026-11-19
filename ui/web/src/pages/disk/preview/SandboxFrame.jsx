import { useCallback, useEffect, useRef } from 'react'
import styles from './Preview.module.css'

// No scripts (sandbox without allow-scripts) and no remote loads (CSP): only
// inline styles and data/blob images. allow-same-origin lets the parent fill the
// document; NEVER add allow-popups-to-escape-sandbox (WebKit then revokes
// same-origin; see EmailFrame.jsx).
const CSP = "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; media-src data: blob:"
const BASE = 'html,body{margin:0;background:#fff;color:#182242;font:15px/1.55 Inter,system-ui,sans-serif}body{padding:20px 24px}img{max-width:100%}table{border-collapse:collapse}td,th{border:1px solid #dcd8ce;padding:4px 8px;font-size:12px}pre,code{font:12.5px ui-monospace,monospace;background:#f4efe4;border-radius:4px}pre{padding:12px;overflow:auto}'
const SRCDOC = `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${CSP}"><style>${BASE}</style></head><body></body></html>`

/**
 * A sandboxed frame for previews that produce HTML (markdown, docx, sheets,
 * slides). `fill(doc)` gets the frame's document once it has loaded and may
 * be async; it runs again when `fill` changes.
 */
export default function SandboxFrame({ title, fill }) {
  const ref = useRef(null)
  const run = useCallback(() => {
    const doc = ref.current?.contentDocument
    if (!doc?.body || doc.URL !== 'about:srcdoc') return // not the initial about:blank
    doc.body.replaceChildren()
    fill(doc)
  }, [fill])
  useEffect(() => {
    if (ref.current?.contentDocument?.readyState === 'complete') run() // fill changed after load
  }, [run])
  return (
    <iframe
      ref={ref}
      className={styles.frame}
      title={title}
      sandbox="allow-same-origin"
      srcDoc={SRCDOC}
      onLoad={run}
    />
  )
}
