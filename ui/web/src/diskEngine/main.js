// The Disk exact-view engine window (disk-engine.html). Cross-origin isolated,
// so LibreOffice WASM gets its threads. Converts what Disk tabs send through the
// Disk service worker (lib/disk/sw.js brokers: the bytes and the PDF go only
// between the asking tab and this window), one file at a time, from the engine
// Cache Storage holds. The BroadcastChannel only says whether a window is open.
// One engine window per browser: a second one closes itself.
import { convertToPdf, releaseConverter } from '../lib/disk/engine/converter'
import { CHANNEL } from '../lib/disk/engine/protocol'
import { TAB_LOCK } from '../lib/disk/engine/client'
import { AUTH_SIGNED_OUT, onAuthBroadcast } from '../lib/authBroadcast'
import './engine.css'

const IDLE_CLOSE_MS = 10 * 60_000
const TAB_CHECK_MS = 3000
const READY = 'Disk exact view. Closes with Disk.'
const root = document.getElementById('engine')
const say = (text) => { root.textContent = text }

if (!crossOriginIsolated) {
  say('This page needs its isolation headers to run the engine. Close it and try again from Disk.')
} else {
  navigator.locks.request('inbox2-disk-engine', { ifAvailable: true }, async (lock) => {
    if (!lock) { say('Already open in another window.'); setTimeout(() => window.close(), 1500); return }
    const bc = new BroadcastChannel(CHANNEL)
    const jobs = new Map()
    let idle
    const touch = () => {
      clearTimeout(idle)
      idle = setTimeout(() => close(), IDLE_CLOSE_MS)
    }
    const close = () => { bc.postMessage({ type: 'closing' }); releaseConverter(); window.close() }
    say(READY)
    // Signed out in any tab: nothing of the account stays open here.
    onAuthBroadcast(({ kind }) => { if (kind === AUTH_SIGNED_OUT) close() })
    window.addEventListener('pagehide', () => bc.postMessage({ type: 'closing' }))
    // Close once the last Disk tab is gone (each holds TAB_LOCK shared).
    setInterval(async () => {
      const { held = [], pending = [] } = await navigator.locks.query()
      if (![...held, ...pending].some((l) => l.name === TAB_LOCK)) close()
    }, TAB_CHECK_MS)
    // Discovery only: no file data on this channel.
    bc.onmessage = ({ data }) => { if (data?.type === 'ping') bc.postMessage({ type: 'pong', busy: jobs.size }) }
    const sw = navigator.serviceWorker
    const worker = sw && (sw.controller || (await Promise.race([sw.ready, new Promise((ok) => setTimeout(ok, 5000))]))?.active)
    if (!worker) { say('Disk is not set up in this browser yet. Close this window and open Disk again.'); return }
    sw.addEventListener('message', async ({ data }) => {
      if (data?.cancelConvert) return jobs.get(data.cancelConvert)?.cancel()
      const req = data?.convert
      if (!req) return
      touch()
      say(`Converting ${req.name}...`)
      const job = convertToPdf(new Uint8Array(req.bytes), req.name)
      jobs.set(req.id, job)
      try {
        const pdf = await job.promise
        worker.postMessage({ converted: { id: req.id, pdf } }, [pdf.buffer])
      } catch (e) {
        worker.postMessage({ convertFailed: { id: req.id, message: e.aborted ? 'Cancelled' : (e.message || 'Conversion failed'), aborted: !!e.aborted } })
      } finally {
        jobs.delete(req.id)
        if (!jobs.size) say(READY)
      }
    })
    sw.startMessages()
    worker.postMessage({ engineHello: true })
    bc.postMessage({ type: 'pong', busy: 0 })
    touch()
    await new Promise(() => {}) // hold the lock while the window lives
  })
}
