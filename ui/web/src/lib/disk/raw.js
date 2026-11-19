// Camera RAW (CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2, PEF, SRW): every camera
// stores a JPEG it developed itself inside the file, most at full or near-full
// size. Thumbnails and the preview use the largest one; nothing demosaics.
// ponytail: embedded JPEG only; developing the sensor data (exposure, white
// balance) needs libraw-wasm, add it when someone edits RAW in the browser.

export const RAW_EXTENSIONS = ['cr2', 'cr3', 'nef', 'nrw', 'arw', 'dng', 'raf', 'orf', 'rw2', 'pef', 'srw']

const u16 = (b, o, le) => (le ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1])
const u32 = (b, o, le) => (le ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16)) + b[o + 3] * 2 ** 24 : b[o] * 2 ** 24 + ((b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]))

/** The Orientation tag (1 to 8) of the TIFF header at `t`, or 1. CR2, NEF, ARW, DNG, ORF, RW2 and PEF are TIFFs. */
export function tiffOrientation(b, t = 0) {
  const le = b[t] === 0x49 && b[t + 1] === 0x49
  if (!le && !(b[t] === 0x4d && b[t + 1] === 0x4d)) return 1
  const ifd = t + u32(b, t + 4, le)
  if (ifd + 2 > b.length) return 1
  for (let i = 0, n = u16(b, ifd, le); i < n; i++) {
    const e = ifd + 2 + i * 12
    if (e + 12 > b.length) break
    if (u16(b, e, le) === 0x0112) return u16(b, e + 8, le) || 1
  }
  return 1
}

/** Walks a JPEG's markers from its SOI: { w, h, orientation } of a decodable (baseline or progressive) JPEG, else null. */
export function jpegInfo(b, at) {
  let o = at + 2
  let orientation = 1
  while (o + 9 < b.length && b[o] === 0xff) {
    const m = b[o + 1]
    const len = u16(b, o + 2, false)
    if (m === 0xe1 && u32(b, o + 4, false) === 0x45786966) orientation = tiffOrientation(b, o + 10) // "Exif"
    if (m >= 0xc0 && m <= 0xc2) return { h: u16(b, o + 5, false), w: u16(b, o + 7, false), orientation }
    if (m === 0xda || len < 2) return null // scan data before a frame header, or garbage
    o += 2 + len
  }
  return null
}

/** The largest embedded JPEG: { at, w, h, orientation } or null. */
export function largestJpeg(b) {
  let best = null
  for (let i = b.indexOf(0xff); i >= 0 && i + 3 < b.length; i = b.indexOf(0xff, i + 1)) {
    // SOI, then any APPn, a quantisation or a Huffman table (vendors start previews with each). The
    // sensor data's own lossless JPEG is weeded out by jpegInfo, which only accepts baseline/progressive SOF0-2.
    const next = b[i + 3]
    if (b[i + 1] !== 0xd8 || b[i + 2] !== 0xff || !((next & 0xf0) === 0xe0 || next === 0xdb || next === 0xc4)) continue
    const info = jpegInfo(b, i)
    if (info && info.w * info.h > (best ? best.w * best.h : 0)) best = { at: i, ...info }
  }
  return best
}

// Orientation -> clockwise degrees; the mirrored ones (2, 4, 5, 7) no camera writes.
const DEGREES = { 3: 180, 6: 90, 8: 270 }

/** The RAW's embedded JPEG as an upright Blob, or null when it holds none. */
export async function rawJpeg(blob) {
  const b = new Uint8Array(await blob.arrayBuffer())
  const jpeg = largestJpeg(b)
  if (!jpeg) return null
  const out = blob.slice(jpeg.at, blob.size, 'image/jpeg') // decoders stop at EOI, so the tail is harmless
  // The JPEG's own Exif orientation the browser applies; else the RAW's, which we apply.
  const deg = jpeg.orientation === 1 ? DEGREES[tiffOrientation(b)] : 0
  if (!deg) return out
  const bmp = await createImageBitmap(out)
  try {
    const side = deg !== 180
    const canvas = new OffscreenCanvas(side ? bmp.height : bmp.width, side ? bmp.width : bmp.height)
    const ctx = canvas.getContext('2d')
    ctx.translate(canvas.width / 2, canvas.height / 2)
    ctx.rotate((deg * Math.PI) / 180)
    ctx.drawImage(bmp, -bmp.width / 2, -bmp.height / 2)
    return await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.92 })
  } finally {
    bmp.close()
  }
}
