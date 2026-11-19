// Upload-time renditions (spec F5b): when the uploading device has the engine,
// convert the Office file to PDF after the upload finishes and store it beside
// the version (PUT /versions/:id/rendition; renditions do not count against
// quota). Best effort: never blocks or fails the upload.
import diskApi from '../api'
import { extensionOf } from '../fileTypes'
import useEngineStore, { ENGINE } from '../../../stores/engineStore'
import useUploadStore from '../../../stores/uploadStore'
import log from '../../log'
import { convertInEngine, engineWindowOpen, openEngineWindow } from './client'
import { currentSupport, engineDeclined, exactAlways } from './env'
import { confirmDerived } from '../upload'
import { ENGINE_FORMATS } from './logic'

const MAX_SOURCE = 100 * 1024 ** 2

export const isEngineFormat = (name) => ENGINE_FORMATS.has(extensionOf(name))

/** What to do for this upload: 'convert', 'offer' (engine missing; ask once) or null. */
export function renditionPlan(name, size) {
  if (!isEngineFormat(name) || size > MAX_SOURCE || !currentSupport().ok) return null
  const { status } = useEngineStore.getState()
  if (status === ENGINE.READY) return 'convert'
  return engineDeclined() ? null : 'offer'
}

// A finished upload is no click, so it cannot open the engine window. Each
// rendition is queued (uploadStore.renditions) and made at once when an engine
// window is open; otherwise the upload panel offers "Make exact views for N
// files", whose click opens the window (makeQueuedRenditions). With "always
// use exact view" set, the Upload button opens the window from its own click
// (openEngineForUpload), after the file picker: measured 2026-10-04 in
// headless Chromium, Firefox and WebKit, one click opens both in that order,
// while Chromium drops the picker when window.open comes first.

const uploads = () => useUploadStore.getState()
let draining = false

/** Queue a rendition for a finished upload (Kv set for a sealed one) and make it now if a window is open. */
export function queueRendition({ orgId, file, name, versionId, Kv = null }) {
  uploads().addRendition({ id: `${versionId}`, orgId, file, name, versionId, Kv })
  return drainRenditions()
}

async function makeOne({ orgId, file, name, versionId, Kv }) {
  const pdf = await convertInEngine(new Uint8Array(await file.arrayBuffer()), name).promise
  if (Kv) {
    // Sealed under R (6.6, the 29-byte header format) before it leaves this device: no plaintext rendition is stored.
    const { uploadDerived } = await import('../sealed')
    return uploadDerived({ orgId, Kv, versionId, variant: 'rendition', bytes: pdf })
  }
  const { upload } = await diskApi.renditionUrl(orgId, versionId)
  const res = await fetch(upload.url, { method: 'PUT', body: new Blob([pdf]) })
  if (!res.ok) throw new Error(`The rendition did not upload (${res.status})`)
  await confirmDerived(orgId, versionId, 'rendition')
}

/** Works through the queue while an engine window answers; returns quietly when none does. */
export async function drainRenditions() {
  if (draining || !uploads().renditions.length) return
  if (!(await engineWindowOpen())) return
  if (draining) return // another call took the queue while this one waited for the window
  draining = true
  uploads().setRenditionsRunning(true)
  try {
    for (let next = uploads().renditions[0]; next; next = uploads().renditions[0]) {
      try {
        await makeOne(next)
      } catch (e) {
        log.warn('DiskUpload', `rendition for a ${extensionOf(next.name)}: ${e.message}`)
      } finally {
        uploads().dropRendition(next.id)
      }
    }
  } finally {
    draining = false
    uploads().setRenditionsRunning(false)
  }
}

/** The panel's "Make exact views" click: opens the engine window (inside the click), then works through the queue. */
export async function makeQueuedRenditions() {
  await openEngineWindow()
  return drainRenditions()
}

/**
 * Called from the Upload button's click, after the file picker opened: when
 * this device has the engine and the member chose to always use exact view,
 * open the engine window now, while the click still allows it (openEngineWindow
 * waits at most 250 ms for another tab's window first, inside WebKit's
 * one-second activation window).
 */
export function openEngineForUpload() {
  if (exactAlways() !== 'yes' || useEngineStore.getState().status !== ENGINE.READY || !currentSupport().ok) return
  // The window may answer after the upload finished; drain then, or the queue waits for a click.
  openEngineWindow().then(drainRenditions).catch(() => {})
}
