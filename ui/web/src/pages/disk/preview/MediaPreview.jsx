import { useEffect, useRef, useState } from 'react'
import { fileType } from '../../../lib/disk/fileTypes'
import { WAVEFORM_MAX_BYTES, decodePeaks, waveformSupported } from '../../../lib/disk/waveform'
import { fetchBuffer } from './fetchBytes'
import styles from './Preview.module.css'

/* Native <video> and <audio>. They read the presigned URL with range requests,
   so seeking a large file never downloads the whole of it. The URL lasts five
   minutes: on an error the player asks once for a fresh one and keeps its place.
   Audio up to WAVEFORM_MAX_BYTES also gets a waveform, read whole and decoded
   in the browser (a sealed file through its blob or service-worker URL). */
export default function MediaPreview({ node, url, refreshUrl, onReady, onError }) {
  const [src, setSrc] = useState(url)
  const [retried, setRetried] = useState(false)
  const media = useRef(null)
  const audio = fileType(node).preview === 'audio'
  const onFail = async (e) => {
    const el = e.currentTarget
    const unplayable = () => onError(new Error('This format does not play in this browser'))
    if (retried) return unplayable()
    setRetried(true)
    const at = el.currentTime
    try {
      const fresh = await refreshUrl()
      // Presigned URLs repeat within a second: the same src wouldn't reload or fail again.
      if (fresh === src) return unplayable()
      setSrc(fresh)
      el.addEventListener('loadedmetadata', () => { el.currentTime = at }, { once: true })
    } catch (err) {
      onError(err)
    }
  }
  const seek = (fraction) => { if (media.current?.duration) media.current.currentTime = fraction * media.current.duration }
  const Tag = audio ? 'audio' : 'video'
  return (
    <div className={styles.media}>
      {audio && node.size_bytes <= WAVEFORM_MAX_BYTES && waveformSupported() && <Waveform url={url} media={media} onSeek={seek} />}
      <Tag ref={media} className={audio ? styles.audio : styles.video} src={src} controls preload="metadata" onLoadedMetadata={onReady} onError={onFail}>
        Your browser can&apos;t play this file.
      </Tag>
    </div>
  )
}

/* Bars drawn from the decoded peaks, the played part in the accent colour;
   clicking seeks. Keyboard seeking stays with the player's own controls. A file
   the browser cannot decode leaves the plain player. Colours come from the
   stylesheet's --wave and --wave-played. */
function Waveform({ url, media, onSeek }) {
  const canvas = useRef(null)
  const [peaks, setPeaks] = useState(null) // Float32Array | false when decoding failed

  useEffect(() => {
    let live = true
    const ctl = new AbortController()
    fetchBuffer(url, ctl.signal).then((b) => decodePeaks(b))
      .then((p) => { if (live) setPeaks(p) })
      .catch(() => { if (live) setPeaks(false) })
    return () => { live = false; ctl.abort() }
  }, [url])

  useEffect(() => {
    const c = canvas.current
    const el = media.current
    if (!peaks || !c || !el) return undefined
    const top = Math.max(...peaks) || 1
    let frame = 0
    const draw = () => {
      const dpr = window.devicePixelRatio || 1
      const w = c.clientWidth
      const h = c.clientHeight
      if (c.width !== Math.round(w * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(h * dpr) }
      const g = c.getContext('2d')
      g.setTransform(dpr, 0, 0, dpr, 0, 0)
      g.clearRect(0, 0, w, h)
      const css = getComputedStyle(c)
      const progress = el.duration ? el.currentTime / el.duration : 0
      const bw = w / peaks.length
      peaks.forEach((p, i) => {
        const bh = Math.max(2, (p / top) * (h - 4))
        g.fillStyle = (i + 0.5) / peaks.length <= progress ? css.getPropertyValue('--wave-played') : css.getPropertyValue('--wave')
        g.fillRect(i * bw + 0.5, (h - bh) / 2, Math.max(1, bw - 1.5), bh)
      })
      c.dataset.progress = progress.toFixed(3)
    }
    // One loop at a time: timeupdate fires ~4×/s, and each call would start another.
    const loop = () => { cancelAnimationFrame(frame); draw(); if (!el.paused) frame = requestAnimationFrame(loop) }
    const events = ['timeupdate', 'seeked', 'loadedmetadata', 'play']
    events.forEach((ev) => el.addEventListener(ev, loop))
    window.addEventListener('resize', draw)
    draw()
    return () => {
      cancelAnimationFrame(frame)
      events.forEach((ev) => el.removeEventListener(ev, loop))
      window.removeEventListener('resize', draw)
    }
  }, [peaks, media])

  if (peaks === false) return null
  const seek = (e) => {
    const r = e.currentTarget.getBoundingClientRect()
    onSeek(Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)))
  }
  return <canvas ref={canvas} className={styles.waveform} role="img" aria-label="Waveform. Click to seek." data-ready={peaks ? 'true' : 'false'} onClick={seek} />
}
