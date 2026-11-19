// The engine's converter: LibreOffice WASM in its own worker (the package's
// WorkerBrowserConverter owns it), fed from the files Cache Storage holds.
// One conversion at a time; the worker and its memory are released after a
// few idle minutes or on cancel.
import { engineFiles } from './install'
import { SerialQueue } from './logic'

const IDLE_MS = 3 * 60_000
const FILES = {
  sofficeJs: 'soffice.js',
  sofficeWasm: 'soffice.wasm',
  sofficeData: 'soffice.data',
  sofficeWorkerJs: 'soffice.worker.js',
  browserWorkerJs: 'browser.worker.global.js',
}

const queue = new SerialQueue()
let converter = null
let urls = []
let idle = null

async function load() {
  if (converter) return converter
  const blobs = await engineFiles()
  // Blob URLs: the worker scripts must be same-origin, and the bytes come from the verified cache.
  const paths = {}
  for (const [opt, name] of Object.entries(FILES)) {
    const type = name.endsWith('.js') ? 'text/javascript' : name.endsWith('.wasm') ? 'application/wasm' : 'application/octet-stream'
    const url = URL.createObjectURL(new Blob([blobs[name]], { type }))
    urls.push(url)
    paths[opt] = url
  }
  const { WorkerBrowserConverter } = await import('@matbee/libreoffice-converter/browser')
  const c = new WorkerBrowserConverter(paths)
  await c.initialize()
  converter = c
  return c
}

/** Ends the worker and frees its memory. Safe to call any time. */
export function releaseConverter() {
  clearTimeout(idle)
  const c = converter
  converter = null
  c?.destroy().catch(() => {})
  urls.forEach((u) => URL.revokeObjectURL(u))
  urls = []
}

/**
 * Converts Office bytes to PDF. Returns { promise (Uint8Array), cancel }.
 * Cancelling a running conversion ends the worker; the next one starts it again.
 */
export function convertToPdf(bytes, name) {
  return queue.add(async (signal) => {
    clearTimeout(idle)
    const c = await load()
    const aborted = new Promise((_, reject) => signal.addEventListener('abort', () => {
      releaseConverter()
      reject(Object.assign(new Error('Cancelled'), { aborted: true }))
    }, { once: true }))
    try {
      const result = await Promise.race([c.convert(bytes, { outputFormat: 'pdf' }, name), aborted])
      return result.data
    } finally {
      idle = setTimeout(releaseConverter, IDLE_MS)
    }
  })
}
