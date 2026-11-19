import { useEffect, useState } from 'react'
import { rawJpeg } from '../../../lib/disk/raw'
import { fetchBlob } from './fetchBytes'
import ImagePreview from './ImagePreview'

/* Camera RAW: the JPEG the camera embedded (lib/disk/raw.js), shown like any image. */
export default function RawPreview({ node, url, onReady, onError }) {
  const [src, setSrc] = useState(null)
  useEffect(() => {
    const ctl = new AbortController()
    let objectUrl
    fetchBlob(url, ctl.signal)
      .then(rawJpeg)
      .then((jpeg) => {
        if (!jpeg) throw new Error('This RAW file has no preview image saved in it')
        objectUrl = URL.createObjectURL(jpeg)
        if (!ctl.signal.aborted) setSrc(objectUrl)
      })
      .catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => { ctl.abort(); if (objectUrl) URL.revokeObjectURL(objectUrl) }
  }, [url, onError])
  return src ? <ImagePreview node={node} url={src} onReady={onReady} onError={onError} /> : null
}
