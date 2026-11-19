import { useCallback, useEffect, useState } from 'react'
import { fetchBuffer } from './fetchBytes'
import SandboxFrame from './SandboxFrame'
import styles from './Preview.module.css'

/* PowerPoint (.pptx) through pptx-renderer, slides in order inside the
   sandboxed frame. Static: no animations, transitions or notes. */
export default function PptxPreview({ node, url, onReady, onError }) {
  const [buf, setBuf] = useState(null)
  useEffect(() => {
    const ctl = new AbortController()
    fetchBuffer(url, ctl.signal).then(setBuf).catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => ctl.abort()
  }, [url, onError])
  const fill = useCallback(async (doc) => {
    if (!buf) return
    try {
      const { PptxViewer, RECOMMENDED_ZIP_LIMITS } = await import('@aiden0z/pptx-renderer')
      doc.body.style.background = '#e9e5db'
      // Slides fit the pane's width. The gutter is reserved up front so the vertical
      // scrollbar appearing after the first slide cannot push them wider than the frame.
      doc.documentElement.style.scrollbarGutter = 'stable'
      doc.documentElement.style.overflowX = 'hidden'
      doc.body.style.padding = '12px'
      const host = doc.body.appendChild(doc.createElement('div'))
      // The renderer puts 20px under every slide, the last included: even the spacing out
      // so the space under the last slide equals the space above the first.
      host.dataset.slides = ''
      doc.head.appendChild(doc.createElement('style')).textContent =
        '[data-slides]>*{margin-bottom:12px!important}[data-slides]>*:last-child{margin-bottom:0!important}'
      const viewer = await PptxViewer.open(buf, host, { fitMode: 'contain', zipLimits: RECOMMENDED_ZIP_LIMITS, lazySlides: true, lazyMedia: true })
      // Full screen and window resizes change the pane's width: fit again.
      const view = doc.defaultView
      if (view?.ResizeObserver) new view.ResizeObserver(() => viewer.setFitMode?.('contain')).observe(doc.documentElement)
      onReady()
    } catch (e) {
      onError(e)
    }
  }, [buf, onReady, onError])
  return buf ? (
    <div className={styles.doc}>
      <p className={styles.note}>Quick view: fonts and some shapes can differ from PowerPoint.</p>
      <SandboxFrame title={node.name} fill={fill} />
    </div>
  ) : null
}
