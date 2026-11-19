import { describe, it, expect } from 'vitest'
import { largestJpeg, tiffOrientation } from '../raw'

// A minimal JPEG head: SOI, an APP1 Exif block or an empty DQT, then SOF0 with the size.
function jpeg(w, h, orientation) {
  const app1 = orientation
    ? [0xff, 0xe1, 0, 30, 0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff(orientation)]
    : [0xff, 0xdb, 0, 2]
  return [0xff, 0xd8, ...app1, 0xff, 0xc0, 0, 11, 8, h >> 8, h & 255, w >> 8, w & 255, 1, 1, 0x11, 0, 0xff, 0xd9]
}
// Little-endian TIFF header with one IFD entry: Orientation.
const tiff = (o) => [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, o, 0, 0, 0]

describe('camera RAW embedded JPEG', () => {
  it('picks the largest decodable JPEG and skips the lossless sensor stream', () => {
    const lossless = [0xff, 0xd8, 0xff, 0xc4, 0, 4, 0, 0, 0xff, 0xc3, 0, 11, 8, 0x40, 0, 0x60, 0, 1, 1, 0x11, 0]
    const b = new Uint8Array([...tiff(6), 1, 2, 3, ...jpeg(160, 120), 9, 9, ...jpeg(6000, 4000, 1), ...lossless])
    const best = largestJpeg(b)
    expect([best.w, best.h, best.orientation]).toEqual([6000, 4000, 1])
    expect(b[best.at + 1]).toBe(0xd8)
    expect(tiffOrientation(b)).toBe(6)
  })

  it('reads the JPEG’s own Exif orientation', () => {
    expect(largestJpeg(new Uint8Array(jpeg(300, 200, 8))).orientation).toBe(8)
  })

  it('accepts a preview that starts with another APPn or a Huffman table', () => {
    const app2 = [0xff, 0xd8, 0xff, 0xe2, 0, 2, 0xff, 0xc0, 0, 11, 8, 0, 100, 0, 200, 1, 1, 0x11, 0]
    expect(largestJpeg(new Uint8Array(app2))).toMatchObject({ w: 200, h: 100 })
  })

  it('finds nothing in a file without a JPEG', () => {
    expect(largestJpeg(new Uint8Array([0xff, 0xd8, 0xff, 0xc4, 1, 2, 3]))).toBeNull()
    expect(tiffOrientation(new Uint8Array([1, 2, 3, 4]))).toBe(1)
  })
})
