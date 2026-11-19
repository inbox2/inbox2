// Installs the exact-view engine (LibreOffice WASM) into Cache Storage, once
// per device (spec F5b). Versioned apart from the app: manifest.json names the
// version and every file's parts; a new version installs beside the old one
// and replaces it only after it verifies.
//
//   fetch parts (resume: parts already cached are skipped) → check each part's sha256
//   → join + gunzip each file → check the file's sha256 → mark the version ready
//   → delete older versions
//
// The download runs at module level, so it continues when the slide-over closes.
import useEngineStore, { ENGINE } from '../../../stores/engineStore'
import { sha256Stream } from '../sha256'
import log from '../../log'
import { ENGINE_BASE, currentSupport, engineDeclined } from './env'
import {
  cacheNameFor, cachedBytes, downloadBytes, fileKey, installedBytes, missingParts, needsStorageWarning, partKey,
  staleEngineCaches, ENGINE_CACHE_PREFIX,
} from './logic'

const set = (patch) => useEngineStore.setState(patch)
// Cache keys are same-origin URLs under a path nothing serves.
const keyUrl = (key) => `/__disk-engine/${key}`
const READY_KEY = 'ready'

async function fetchManifest() {
  const res = await fetch(`${ENGINE_BASE}/manifest.json`, { cache: 'no-cache' })
  if (!res.ok) throw new Error(`Exact view isn't available right now (${res.status}).`)
  return res.json()
}

/** The verified installed engine: { manifest, cache } or null. */
export async function installed() {
  if (typeof caches === 'undefined') return null
  for (const name of (await caches.keys()).filter((n) => n.startsWith(ENGINE_CACHE_PREFIX))) {
    const cache = await caches.open(name)
    const ready = await cache.match(keyUrl(READY_KEY))
    if (ready) return { manifest: await ready.json(), cache }
  }
  return null
}

/** Reads what is installed into the store; then, quietly, fetches a newer version if there is one. */
export async function refreshEngine({ update = true } = {}) {
  try {
    const have = await installed()
    if (have) set({ status: ENGINE.READY, version: have.manifest.version, size: installedBytes(have.manifest) })
    else if (!running) set({ status: ENGINE.NONE })
    const manifest = await fetchManifest().then((m) => (Array.isArray(m?.files) ? m : null)).catch(() => null)
    if (manifest) set({ downloadSize: downloadBytes(manifest) })
    if (update && have && manifest && manifest.version !== have.manifest.version) installEngine({ background: true }).catch(() => {})
  } catch (e) {
    log.warn('DiskEngine', e.message)
  }
}

/**
 * A member opened an Office file: download the engine when this device has none,
 * can run it, and they have not turned it down (spec F5b, decided 2026-11-09: the
 * download waits for the first Office file, it no longer starts when Disk opens).
 */
export async function ensureEngine() {
  await refreshEngine()
  const { status, downloadSize } = useEngineStore.getState()
  if (status !== ENGINE.NONE || !downloadSize || !currentSupport().ok || engineDeclined()) return
  // A device low on space keeps quick view; the preview bar still offers the download.
  if (needsStorageWarning(await navigator.storage?.estimate?.().catch(() => null), downloadSize * 3)) return
  installEngine().catch(() => {})
}

async function digest(buf) {
  const h = await crypto.subtle.digest('SHA-256', buf)
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

let running = null

/**
 * Downloads and installs the engine. One run at a time; a second call joins it.
 * background: do not show progress (an update while the old version still works).
 */
export function installEngine({ background = false } = {}) {
  if (running) return running.promise
  const ctl = new AbortController()
  const promise = run(ctl.signal, background).finally(() => { running = null })
  running = { ctl, promise }
  return promise
}

/** Stops a download. Parts already fetched stay cached for the next try; nothing half-installed is used. */
export function cancelInstall() {
  running?.ctl.abort()
}

async function run(signal, background) {
  const manifest = await fetchManifest()
  const cache = await caches.open(cacheNameFor(manifest.version))
  // Not awaited: Firefox asks the person, and the promise waits on their answer.
  navigator.storage?.persist?.().catch(() => false)
  const have = new Set((await cache.keys()).map((r) => new URL(r.url).pathname.replace('/__disk-engine/', '')))
  const total = downloadBytes(manifest)
  let loaded = cachedBytes(manifest, have)
  if (!background) set({ status: ENGINE.DOWNLOADING, loaded, total, error: null })
  try {
    for (const part of missingParts(manifest, have)) {
      const res = await fetch(`${ENGINE_BASE}/${manifest.version}/${part.path}`, { signal })
      if (!res.ok) throw new Error(`The exact view download failed (${res.status}).`)
      const buf = await res.arrayBuffer()
      if (await digest(buf) !== part.sha256) throw new Error('The exact view download was damaged.')
      await cache.put(keyUrl(partKey(part.path)), new Response(buf))
      loaded += part.bytes
      if (!background) set({ loaded })
    }
    if (!background) set({ status: ENGINE.VERIFYING })
    for (const file of manifest.files) {
      if (have.has(fileKey(file.name))) continue
      const blobs = await Promise.all(file.parts.map(async (p) => (await cache.match(keyUrl(partKey(p.path)))).blob()))
      const [toHash, toStore] = new Blob(blobs).stream().pipeThrough(new DecompressionStream('gzip')).tee()
      const [hash] = await Promise.all([sha256Stream(toHash, signal), cache.put(keyUrl(fileKey(file.name)), new Response(toStore))])
      if (hash !== file.sha256) {
        await Promise.all([cache.delete(keyUrl(fileKey(file.name))), ...file.parts.map((p) => cache.delete(keyUrl(partKey(p.path))))])
        throw new Error('The exact view download was damaged.')
      }
      await Promise.all(file.parts.map((p) => cache.delete(keyUrl(partKey(p.path)))))
    }
    await cache.put(keyUrl(READY_KEY), new Response(JSON.stringify(manifest), { headers: { 'Content-Type': 'application/json' } }))
    for (const old of staleEngineCaches(await caches.keys(), manifest.version)) await caches.delete(old)
    set({ status: ENGINE.READY, version: manifest.version, size: installedBytes(manifest), loaded: total, total, error: null })
  } catch (e) {
    if (signal.aborted) {
      if (!background) set({ status: (await installed()) ? ENGINE.READY : ENGINE.NONE })
      throw Object.assign(new Error('Cancelled'), { aborted: true })
    }
    const full = e?.name === 'QuotaExceededError'
    const message = full ? 'This device is out of space for exact view.' : e.message
    if (!background) set({ status: (await installed()) ? ENGINE.READY : ENGINE.ERROR, error: message })
    throw Object.assign(e, { message })
  }
}

/** Removes every installed engine version (Settings › Remove). */
export async function removeEngine() {
  cancelInstall()
  for (const n of (await caches.keys()).filter((x) => x.startsWith(ENGINE_CACHE_PREFIX))) await caches.delete(n)
  set({ status: ENGINE.NONE, version: null, size: 0, loaded: 0 })
}

/** The installed engine's files as Blobs (for the converter), checked against the manifest's sizes. */
export async function engineFiles() {
  const have = await installed()
  if (!have) throw new Error('The engine is not installed')
  const out = {}
  for (const f of have.manifest.files) {
    const res = await have.cache.match(keyUrl(fileKey(f.name)))
    const blob = res && await res.blob()
    if (!blob || blob.size !== f.bytes) {
      // A damaged install: drop it so the next use downloads again (spec F5b: detected and re-fetched).
      await caches.delete(cacheNameFor(have.manifest.version))
      set({ status: ENGINE.NONE, version: null, size: 0 })
      throw new Error('The engine on this device was damaged and has been removed; download it again')
    }
    out[f.name] = blob
  }
  return out
}
