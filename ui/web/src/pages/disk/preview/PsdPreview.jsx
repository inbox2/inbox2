import { useEffect, useState } from 'react'
import { fetchBuffer } from './fetchBytes'
import styles from './Preview.module.css'

/* Photoshop: the flattened composite the file stores, read by ag-psd (layers are skipped). */
export default function PsdPreview({ node, url, onReady, onError }) {
  const [src, setSrc] = useState(null)
  useEffect(() => {
    const ctl = new AbortController()
    let objectUrl
    ;(async () => {
      const [{ readPsd }, buf] = await Promise.all([import('ag-psd'), fetchBuffer(url, ctl.signal)])
      const psd = readPsd(buf, { skipLayerImageData: true, skipThumbnail: true })
      if (!psd.canvas) throw new Error('This file has no flattened image saved in it')
      const blob = await new Promise((r) => psd.canvas.toBlob(r, 'image/png'))
      objectUrl = URL.createObjectURL(blob)
      setSrc(objectUrl)
    })().catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => { ctl.abort(); if (objectUrl) URL.revokeObjectURL(objectUrl) }
  }, [url, onError])
  return src ? (
    <div className={styles.media}><div className={styles.imageWrap}><img className={styles.image} src={src} alt={node.name} onLoad={onReady} /></div></div>
  ) : null
}
