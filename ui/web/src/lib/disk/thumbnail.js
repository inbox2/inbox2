// Thumbnails made in the browser at upload (spec F5: the server never decodes
// an image). Images, camera RAW, video and PDFs; everything else shows its type icon.
import { extensionOf, fileType } from './fileTypes'
import { RAW_EXTENSIONS, rawJpeg } from './raw'

export const THUMB_PX = 480 // sharp on a 2x screen up to the grid's largest tile
const MAX_SOURCE = 50 * 1024 ** 2 // past this a thumbnail costs more than it is worth
const MAX_RAW = 200 * 1024 ** 2 // RAW files run large; the embedded JPEG makes them cheap
const VIDEO_TIMEOUT_MS = 15_000 // a codec this browser cannot play never answers

async function toWebp(source, w, h) {
  const scale = Math.min(1, THUMB_PX / Math.max(w, h))
  const canvas = new OffscreenCanvas(Math.max(1, Math.round(w * scale)), Math.max(1, Math.round(h * scale)))
  canvas.getContext('2d').drawImage(source, 0, 0, canvas.width, canvas.height)
  return canvas.convertToBlob({ type: 'image/webp', quality: 0.8 })
}

async function imageThumb(blob) {
  const bmp = await createImageBitmap(blob).catch(() => null) // HEIC and TIFF decode in Safari only
  if (!bmp) return null
  try { return await toWebp(bmp, bmp.width, bmp.height) } finally { bmp.close() }
}

// A frame a second in (or a tenth of a short clip), read through an object URL so a large video is never loaded whole.
async function videoThumb(file) {
  const v = document.createElement('video')
  v.muted = true
  v.preload = 'auto'
  v.src = URL.createObjectURL(file)
  const event = (name) => new Promise((resolve, reject) => {
    v.addEventListener(name, resolve, { once: true })
    v.addEventListener('error', () => reject(new Error('This video does not play in this browser')), { once: true })
    setTimeout(() => reject(new Error(`No ${name} from the video`)), VIDEO_TIMEOUT_MS)
  })
  try {
    await event('loadeddata')
    v.currentTime = Math.min(1, (v.duration || 0) / 10)
    await event('seeked')
    return v.videoWidth ? await toWebp(v, v.videoWidth, v.videoHeight) : null
  } finally {
    URL.revokeObjectURL(v.src)
    v.removeAttribute('src')
    v.load()
  }
}

/** A small webp Blob for the file, or null when it has no thumbnail. */
export async function makeThumbnail(file, name = file.name) {
  if (typeof OffscreenCanvas === 'undefined') return null
  const { preview } = fileType({ name, mime: file.type })
  if (preview === 'video') return videoThumb(file)
  if (RAW_EXTENSIONS.includes(extensionOf(name))) {
    if (file.size > MAX_RAW) return null
    const jpeg = await rawJpeg(file)
    return jpeg && imageThumb(jpeg)
  }
  if (file.size > MAX_SOURCE) return null
  if (preview === 'image') return imageThumb(file)
  if (preview === 'pdf') {
    const { openPdf } = await import('./preview/pdfium')
    const doc = await openPdf(new Uint8Array(await file.arrayBuffer()))
    try {
      const img = doc.render(0, 0.6)
      return await toWebp(await createImageBitmap(img), img.width, img.height)
    } finally {
      doc.close()
    }
  }
  return null
}
