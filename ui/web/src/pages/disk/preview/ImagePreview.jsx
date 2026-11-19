import { useEffect, useRef, useState } from 'react'
import { extensionOf } from '../../../lib/disk/fileTypes'
import styles from './Preview.module.css'

/* Native <img>: JPEG, PNG, GIF, WebP, AVIF, BMP, and HEIC/TIFF where the browser decodes them.
   SVG is drawn as an image, which never runs its scripts or loads its references. */
export default function ImagePreview({ node, url, onReady, onError }) {
  const [rotate, setRotate] = useState(0)
  const [actual, setActual] = useState(false)
  const imgRef = useRef(null)
  useEffect(() => { imgRef.current?.style.setProperty('--rotate', `${rotate}deg`) }, [rotate])
  // Storage answers application/octet-stream, and browsers sniff raster images but
  // never SVG: give the bytes their type here. Still an <img>, so still no scripts.
  const svg = extensionOf(node.name) === 'svg'
  const [svgSrc, setSvgSrc] = useState(null)
  const src = svg ? svgSrc : url
  useEffect(() => {
    if (!svg) return undefined
    let live = true
    let made
    fetch(url).then((r) => (r.ok ? r.blob() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((b) => { made = URL.createObjectURL(new Blob([b], { type: 'image/svg+xml' })); if (live) setSvgSrc(made) })
      .catch((e) => { if (live) onError(e) })
    return () => { live = false; if (made) URL.revokeObjectURL(made) }
  }, [svg, url, onError])
  return (
    <div className={styles.media}>
      <div className={styles.tools}>
        <button type="button" className={styles.tool} onClick={() => setActual((a) => !a)} aria-pressed={actual}>{actual ? 'Fit' : '100%'}</button>
        <button type="button" className={styles.tool} onClick={() => setRotate((r) => (r + 90) % 360)} >Rotate</button>
      </div>
      <div className={[styles.imageWrap, actual ? styles.actual : ''].join(' ')}>
        {src && <img ref={imgRef} className={styles.image} src={src} alt={node.name} onLoad={onReady} onError={() => onError(new Error('This image does not open in this browser'))} />}
      </div>
    </div>
  )
}
