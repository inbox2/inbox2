// PDFium (the PDF engine inside Chrome) compiled to WASM, after
// docs/plans/disk-design/engine-spike/engine.js. Loaded on first use only; the
// .wasm ships as a separate asset, so it is never in the Disk chunk.
import wasmUrl from '@embedpdf/pdfium/pdfium.wasm?url'

let ready
function engine() {
  ready ||= (async () => {
    const { init } = await import('@embedpdf/pdfium')
    const wasmBinary = await (await fetch(wasmUrl)).arrayBuffer()
    const p = await init({ wasmBinary })
    p.PDFiumExt_Init()
    return p
  })()
  return ready
}

/** Opens PDF bytes. Call close() when done: handles live in WASM memory, the GC never sees them. */
export async function openPdf(bytes) {
  const p = await engine()
  const m = p.pdfium
  const ptr = m.wasmExports.malloc(bytes.length)
  m.HEAPU8.set(bytes, ptr)
  const doc = p.FPDF_LoadMemDocument(ptr, bytes.length, '')
  if (!doc) {
    m.wasmExports.free(ptr)
    throw new Error(`PDFium could not open this document (error ${p.FPDF_GetLastError()})`)
  }
  return {
    pages: p.FPDF_GetPageCount(doc),
    /** One page as ImageData at `scale` (1 = 72 dpi). */
    render(i, scale = 1.5) {
      const page = p.FPDF_LoadPage(doc, i)
      if (!page) throw new Error(`PDFium could not load page ${i + 1}`)
      let bmp = 0
      try {
        const w = Math.max(1, Math.round(p.FPDF_GetPageWidthF(page) * scale))
        const h = Math.max(1, Math.round(p.FPDF_GetPageHeightF(page) * scale))
        bmp = p.FPDFBitmap_Create(w, h, 0)
        if (!bmp) throw new Error(`PDFium could not allocate a ${w}x${h} bitmap`)
        p.FPDFBitmap_FillRect(bmp, 0, 0, w, h, 0xffffffff)
        p.FPDF_RenderPageBitmap(bmp, page, 0, 0, w, h, 0, 0x10) // FPDF_REVERSE_BYTE_ORDER: RGBA out
        const buf = p.FPDFBitmap_GetBuffer(bmp)
        return new ImageData(new Uint8ClampedArray(m.HEAPU8.buffer, buf, w * h * 4).slice(), w, h)
      } finally {
        if (bmp) p.FPDFBitmap_Destroy(bmp)
        p.FPDF_ClosePage(page)
      }
    },
    /** A page's text, for search. */
    text(i) {
      const page = p.FPDF_LoadPage(doc, i)
      if (!page) return ''
      const tp = p.FPDFText_LoadPage(page)
      try {
        const n = p.FPDFText_CountChars(tp)
        if (n <= 0) return ''
        const out = m.wasmExports.malloc((n + 1) * 2)
        try {
          p.FPDFText_GetText(tp, 0, n, out)
          return new TextDecoder('utf-16le').decode(m.HEAPU8.slice(out, out + n * 2))
        } finally {
          m.wasmExports.free(out)
        }
      } finally {
        p.FPDFText_ClosePage(tp)
        p.FPDF_ClosePage(page)
      }
    },
    close() {
      p.FPDF_CloseDocument(doc)
      m.wasmExports.free(ptr)
    },
  }
}
