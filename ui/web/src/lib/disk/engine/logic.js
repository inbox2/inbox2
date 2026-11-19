// Pure rules for the exact-view engine (spec F5b), kept apart so they are unit tested.
//
// Manifest (made by scripts/disk-engine-pack.mjs, served at ${base}/manifest.json):
//   { version, files: [{ name, bytes, sha256, parts: [{ path, bytes, sha256 }] }] }
// Each file is gzip-compressed and cut into parts of a few MiB, so a download
// resumes part by part and every part fits any static host's size limit.

export const ENGINE_CACHE_PREFIX = 'disk-engine-'
export const CONVERSION_CACHE_PREFIX = 'disk-conv-'

export const cacheNameFor = (version) => `${ENGINE_CACHE_PREFIX}${version}`
export const partKey = (path) => `part/${path}`
export const fileKey = (name) => `file/${name}`

/** Bytes to download for the whole engine (compressed). */
export const downloadBytes = (manifest) =>
  manifest.files.reduce((s, f) => s + f.parts.reduce((t, p) => t + p.bytes, 0), 0)

/** Bytes the engine takes once installed (uncompressed). */
export const installedBytes = (manifest) => manifest.files.reduce((s, f) => s + f.bytes, 0)

/**
 * What is left to fetch: parts of files not yet assembled, minus parts already cached.
 * `have` is a Set of cache keys.
 */
export function missingParts(manifest, have) {
  return manifest.files
    .filter((f) => !have.has(fileKey(f.name)))
    .flatMap((f) => f.parts.filter((p) => !have.has(partKey(p.path))).map((p) => ({ file: f.name, ...p })))
}

/** Bytes already safe locally, for the progress bar on resume. */
export function cachedBytes(manifest, have) {
  return manifest.files.reduce((s, f) => (have.has(fileKey(f.name))
    ? s + f.parts.reduce((t, p) => t + p.bytes, 0)
    : s + f.parts.filter((p) => have.has(partKey(p.path))).reduce((t, p) => t + p.bytes, 0)), 0)
}

/** Engine caches to delete: every engine version but `keep` (the verified current one). */
export const staleEngineCaches = (names, keep) =>
  names.filter((n) => n.startsWith(ENGINE_CACHE_PREFIX) && n !== cacheNameFor(keep))

/** Conversion caches that belong to someone else on this device. */
export const otherAccountCaches = (names, accountId) =>
  names.filter((n) => n.startsWith(CONVERSION_CACHE_PREFIX) && n !== `${CONVERSION_CACHE_PREFIX}${accountId}`)

/**
 * Least recently used first: the keys to drop so the index fits `cap` bytes
 * after adding `incoming`. index: { key: { bytes, at } }.
 */
export function lruEvict(index, cap, incoming = 0) {
  const entries = Object.entries(index).sort((a, b) => a[1].at - b[1].at)
  let total = entries.reduce((s, [, v]) => s + v.bytes, 0) + incoming
  const drop = []
  for (const [key, v] of entries) {
    if (total <= cap) break
    drop.push(key)
    total -= v.bytes
  }
  return drop
}

/** Formats the engine converts to PDF (LibreOffice). */
export const ENGINE_FORMATS = new Set(['doc', 'docx', 'odt', 'rtf', 'xls', 'xlsx', 'ods', 'ppt', 'pptx', 'odp'])

/**
 * Whether to offer the engine here (spec F5b: withheld on unsupported
 * browsers, phones and metered or data-saver connections).
 * env: { isolated, phone, saveData, effectiveType, hasCaches }
 */
export function engineSupport(env) {
  if (!env.isolated || !env.hasCaches) return { ok: false, reason: 'unsupported' }
  if (env.phone) return { ok: false, reason: 'phone' }
  if (env.saveData || /(^|-)2g$|^3g$/.test(env.effectiveType || '')) return { ok: false, reason: 'metered' }
  return { ok: true }
}

/** Ask before downloading when free storage would drop under twice the engine. */
export const needsStorageWarning = (estimate, need) =>
  !!estimate?.quota && estimate.quota - (estimate.usage || 0) < need * 2

/**
 * One job at a time, in order. add(fn) returns a promise for fn's result and a
 * cancel() that drops the job if it has not started (a running one is
 * stopped by its own signal).
 */
export class SerialQueue {
  constructor() {
    this.jobs = []
    this.running = null
  }

  get size() {
    return this.jobs.length + (this.running ? 1 : 0)
  }

  add(fn) {
    const ctl = new AbortController()
    let job
    const promise = new Promise((resolve, reject) => {
      job = { fn, ctl, resolve, reject }
      this.jobs.push(job)
    })
    this._next()
    return {
      promise,
      cancel: () => {
        ctl.abort()
        const i = this.jobs.indexOf(job)
        if (i >= 0) {
          this.jobs.splice(i, 1)
          job.reject(Object.assign(new Error('Cancelled'), { aborted: true }))
        }
      },
    }
  }

  async _next() {
    if (this.running || !this.jobs.length) return
    const job = this.jobs.shift()
    this.running = job
    try {
      job.resolve(await job.fn(job.ctl.signal))
    } catch (e) {
      job.reject(e)
    } finally {
      this.running = null
      this._next()
    }
  }
}

/** The exact-view line's states (ExactViewBar). CONFIRM: little free storage, ask first. */
export const EXACT = {
  OFFER: 'offer',
  CONFIRM: 'confirm', // little free storage: ask first
  DOWNLOADING: 'downloading',
  VERIFYING: 'verifying',
  READY: 'ready',
  CONVERTING: 'converting',
  FAILED: 'failed',
  ASK_ALWAYS: 'ask-always',
}
