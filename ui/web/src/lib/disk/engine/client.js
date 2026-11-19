// Disk's side of the exact-view engine. Browsers only give WASM threads to a
// cross-origin isolated top-level document, and Disk is not isolated (so mail
// and Disk switch instantly and sign-in popups keep their opener). Measured
// 2026-10-03 in headless Chromium 151, Firefox 153 and WebKit 26.5: an iframe
// under a non-isolated page is never isolated, credentialless or not; a window
// opened on a COOP + COEP page is, and same-origin BroadcastChannel reaches it
// although COOP cuts its opener. So the engine runs in a small window on
// /disk-engine.html, opened from a click, and Disk talks to it over the channel.
import { CHANNEL, ENGINE_PAGE } from './protocol'

let channel = null
let open = false
const listeners = new Set()

function bc() {
  if (channel) return channel
  channel = new BroadcastChannel(CHANNEL)
  channel.onmessage = ({ data }) => {
    if (data?.type === 'pong') setOpen(true)
    if (data?.type === 'closing') setOpen(false)
  }
  return channel
}

function setOpen(v) {
  if (open === v) return
  open = v
  listeners.forEach((fn) => fn(v))
}

/** Subscribe to whether an engine window is open. Returns an unsubscribe. */
export function onEngineWindow(fn) {
  listeners.add(fn)
  bc().postMessage({ type: 'ping' })
  return () => listeners.delete(fn)
}

/** Whether an engine window answers within `ms`. */
export function engineWindowOpen(ms = 400) {
  return new Promise((resolve) => {
    if (open) return resolve(true)
    const off = onEngineWindow((v) => { if (v) { off(); resolve(true) } })
    setTimeout(() => { off(); resolve(open) }, ms)
  })
}

/** Held by every open Disk tab; the engine window closes once nobody holds it. */
export const TAB_LOCK = 'inbox2-disk-tab'

/** Marks this tab as a Disk tab while mounted. Returns a release function. */
export function holdDiskTab() {
  if (!navigator.locks) return () => {}
  let release
  navigator.locks.request(TAB_LOCK, { mode: 'shared' }, () => new Promise((r) => { release = r })).catch(() => {})
  return () => release?.()
}

// Small and in the bottom-right corner, out of the way. Browsers clamp the
// size to their minimum (about 100 to 250 px wide) and may ignore the position.
const features = () => {
  const w = 320
  const h = 110
  const left = Math.max(0, (screen.availLeft || 0) + screen.availWidth - w - 24)
  const top = Math.max(0, (screen.availTop || 0) + screen.availHeight - h - 64)
  return `popup,width=${w},height=${h},left=${left},top=${top}`
}

/**
 * Opens the engine window, or reuses the one another tab opened. Call it from
 * a click (popup blockers allow that). Resolves when the window answers;
 * rejects when the browser blocked it. Disk keeps the focus.
 */
export async function openEngineWindow() {
  // Another tab's window answers a ping within a few ms; wait briefly so a
  // second window is not opened (well inside the click's activation window).
  if (await engineWindowOpen(250)) return
  const w = window.open(ENGINE_PAGE, 'inbox2-disk-engine', features())
  // COOP cuts the handle, so the engine page cannot be blurred from here;
  // focusing this window back is what browsers allow (honoured unevenly).
  window.focus()
  return new Promise((resolve, reject) => {
    const off = onEngineWindow((v) => { if (v) { off(); clearTimeout(t); resolve() } })
    const t = setTimeout(() => { off(); reject(new Error(w ? "The exact-view window didn't start." : 'Your browser blocked the exact-view window. Allow pop-ups for this site.')) }, 15_000)
  })
}

/**
 * Converts Office bytes to PDF in the engine window, through the Disk service
 * worker: it forwards the bytes to the engine window only and returns the PDF
 * to this tab only, so no other page sees either (the BroadcastChannel above is
 * discovery only). Returns { promise (Uint8Array), cancel }.
 */
export function convertInEngine(bytes, name) {
  const id = (crypto.randomUUID && crypto.randomUUID()) || `${Date.now()}-${Math.random()}`
  const sw = navigator.serviceWorker
  let onMessage
  let target
  let stop
  const promise = new Promise((resolve, reject) => {
    stop = reject
    if (!sw) return reject(new Error("Exact view doesn't work in this browser."))
    onMessage = ({ data }) => {
      const done = data?.converted?.id === id ? data.converted : null
      const failed = data?.convertFailed?.id === id ? data.convertFailed : null
      if (!done && !failed) return
      sw.removeEventListener('message', onMessage)
      if (done) resolve(new Uint8Array(done.pdf))
      else reject(Object.assign(new Error(failed.message), { aborted: failed.aborted }))
    }
    sw.addEventListener('message', onMessage)
    sw.startMessages()
    Promise.race([sw.ready, new Promise((ok) => setTimeout(ok, 5000))]).then((reg) => {
      target = sw.controller || reg?.active
      if (!target) throw new Error('Reload Disk and try again.')
      const own = bytes.slice() // the transfer moves this copy, never the caller's array
      target.postMessage({ convert: { id, name, bytes: own } }, [own.buffer])
    }).catch((e) => { sw.removeEventListener('message', onMessage); reject(e) })
  })
  return {
    promise,
    cancel: () => {
      target?.postMessage({ cancelConvert: id })
      sw?.removeEventListener('message', onMessage)
      stop?.(Object.assign(new Error('Cancelled'), { aborted: true }))
    },
  }
}
