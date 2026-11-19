// Disk uploads (docs/plans/disk-build.md section 8, spec F2): bytes go from the
// browser straight to storage in parts through presigned URLs; Rails only
// reserves, hands out part URLs and completes.
//
//   enqueue → reserve (POST /uploads, idempotency key = our local id)
//           → GET /uploads/:id for the parts storage already holds (resume)
//           → PUT the missing parts, a few at a time, retrying with backoff
//           → complete with the sha256 when the file is small enough to hash
//
// The upload id lives in IndexedDB until completion, so after a reload the
// panel can offer to resume once the same file is picked again.
import diskApi, { KEEP_BOTH, QUOTA_FULL, READ_ONLY, REPLACE, SEAL, UPLOAD_CLOSED } from './api'
import { resumeStore } from './uploadResume'
import { makeThumbnail } from './thumbnail'
import { sha256Stream } from './sha256'
import useUploadStore, { UPLOAD_STATE as S } from '../../stores/uploadStore'
import useDiskStore from '../../stores/diskStore'
import log from '../log'

export const FILE_CONCURRENCY = 2
export const PART_CONCURRENCY = 4
export const URL_BATCH = 100 // the API's limit per POST /uploads/:id/parts
// Hash only what streams through in seconds; above this the server checks part sizes alone.
// ponytail: hashing reads the file a second time; fold it into the part reads if big files need sha256.
export const HASH_LIMIT = 512 * 1024 ** 2
export const SKIP = 'skip'

// ── pure helpers (unit tested) ──────────────────────────────────────────────

/** Byte ranges for each part: [{ number, start, end }], end exclusive. An empty file has none. */
export function planParts(size, partBytes) {
  if (!size) return []
  const count = Math.ceil(size / partBytes)
  return Array.from({ length: count }, (_, i) => ({
    number: i + 1,
    start: i * partBytes,
    end: Math.min(size, (i + 1) * partBytes),
  }))
}

/** Resume reconciliation: the planned parts storage does not hold at their exact size. */
export function missingParts(plan, stored = []) {
  const have = new Map(stored.map((p) => [p.number, p.size_bytes]))
  return plan.filter((p) => have.get(p.number) !== p.end - p.start)
}

/** Bytes already safe in storage, for the progress bar on resume. */
export const storedBytes = (plan, stored = []) =>
  plan.reduce((sum, p) => sum + (missingParts([p], stored).length ? 0 : p.end - p.start), 0)

/** Network drops, timeouts, throttling, server errors and expired part URLs are worth another try. */
export function isRetryable(err) {
  if (err?.aborted) return false
  const s = err?.status
  return err?.expired || s === 0 || s == null || s === 408 || s === 429 || s >= 500
}

/** Exponential backoff with jitter: 0.5 to 1 times base * 2^attempt, capped. */
export const backoff = (attempt, base = 500, cap = 15_000, rand = Math.random) =>
  Math.min(cap, base * 2 ** attempt) * (0.5 + rand() / 2)

const delay = (ms) => new Promise((r) => setTimeout(r, ms))

/** Runs fn(attempt) until it succeeds, a non-retryable error, or `tries` attempts. */
export async function withRetry(fn, { tries = 6, sleep = delay, signal } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn(attempt)
    } catch (e) {
      if (signal?.aborted || attempt >= tries - 1 || !isRetryable(e)) throw e
      await sleep(backoff(attempt))
    }
  }
}

/** After a derived object's PUT: the version records it only once this call lands, so it is worth retrying. */
export const confirmDerived = (orgId, versionId, variant) => withRetry(() => diskApi.derivedLanded(orgId, versionId, variant))

/** Runs worker(item) over items with at most `limit` in flight. Stops on the first failure. */
export async function pool(items, limit, worker) {
  let next = 0
  const run = async () => {
    while (next < items.length) await worker(items[next++])
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, run))
}

// ── storage calls ───────────────────────────────────────────────────────────

const errorWith = (message, extra) => Object.assign(new Error(message), extra)

// XHR, not fetch: fetch has no upload progress. The slice carries no type, so
// no Content-Type header is sent to the presigned URL.
function putPart(url, blob, onProgress, signal) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('PUT', url)
    xhr.upload.onprogress = (e) => onProgress(e.loaded)
    xhr.onload = () => (xhr.status < 300
      ? resolve()
      : reject(errorWith(`The upload failed (${xhr.status})`, { status: xhr.status, expired: xhr.status === 403 })))
    xhr.onerror = () => reject(errorWith('The connection dropped', { status: 0 }))
    xhr.onabort = () => reject(errorWith('Stopped', { aborted: true }))
    if (signal.aborted) return xhr.abort()
    signal.addEventListener('abort', () => xhr.abort(), { once: true })
    xhr.send(blob)
  })
}

// ── resume safety: a re-picked file must have the bytes the stored parts came from ──

/** SHA-256 hex of bytes start..end of a file (native, cheap), or null where SubtleCrypto is missing. */
export async function rangeDigest(file, start, end) {
  if (!globalThis.crypto?.subtle) return null
  const d = await crypto.subtle.digest('SHA-256', await file.slice(start, end).arrayBuffer())
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, '0')).join('')
}

/**
 * Whether every part storage already holds was cut from these bytes: digests
 * maps part number -> the digest recorded when that part was sent; rangeOf(n)
 * is the file range it covers. A part with no recorded digest, or a browser
 * that cannot hash, counts as a mismatch: the upload starts again rather than
 * mixing two revisions in one object.
 */
export async function partsStillMatch(file, stored, digests, rangeOf) {
  for (const p of stored) {
    const want = digests?.[p.number]
    if (!want) return false
    const [a, b] = rangeOf(p.number)
    if ((await rangeDigest(file, a, b)) !== want) return false
  }
  return true
}

/** sha256 hex of a file, streamed so a big file is never held whole. */
export const sha256Hex = (file, signal) => sha256Stream(file.stream(), signal)

// ── the queue ───────────────────────────────────────────────────────────────

const files = new Map() // local id -> File (not in the store: Files are not state)
// local id -> the running attempt's AbortController. Each attempt (run) has its own;
// a run only ever removes its own, so a pause and quick resume cannot unseat the new attempt.
const controllers = new Map()
/** The running attempt's controller for an item, or null (for tests and the panel). */
export const activeAttempt = (id) => controllers.get(id) || null
const stopped = () => errorWith('Stopped', { aborted: true })
const store = () => useUploadStore.getState()
const item = (id) => store().items.find((it) => it.id === id)
const newId = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`)

function pump() {
  const running = store().items.filter((it) => it.state === S.RUNNING).length
  const queued = store().items.filter((it) => it.state === S.QUEUED)
  queued.slice(0, Math.max(0, FILE_CONCURRENCY - running)).forEach((it) => run(it.id))
}

async function run(id) {
  const ctl = new AbortController()
  controllers.set(id, ctl)
  store().patch(id, { state: S.RUNNING, error: null })
  try {
    await upload(id, ctl.signal)
  } catch (e) {
    if (e.aborted || ctl.signal.aborted) return
    const it = item(id)
    if (e.status === 409 && !it?.uploadId) {
      const all = store().conflictAll
      if (all) return resolveConflict(id, all)
      store().patch(id, { state: S.CONFLICT, error: e.message })
      return
    }
    const quota = e.status === 422 && e.data?.code === QUOTA_FULL
    const message = e.status === 403 && e.data?.code !== READ_ONLY ? "You can only view this folder, so you can't upload here." : e.message
    store().patch(id, { state: S.ERROR, error: message, quota })
    log.warn('DiskUpload', `${it?.name}: ${e.message}`)
  } finally {
    ctl.abort() // stop sibling part uploads still running after a failure
    if (controllers.get(id) === ctl) controllers.delete(id)
    pump()
  }
}

async function upload(id, signal) {
  const it = item(id)
  const file = files.get(id)
  if (it.sealed) return uploadSealedItem(id, file, signal)
  let uploadId = it.uploadId
  if (!uploadId) {
    const { upload: u } = await withRetry(() => diskApi.startUpload(it.orgId, {
      // A new version of a known file (enqueueVersion) names the file, not a folder and a name.
      ...(it.nodeId ? { node_id: it.nodeId } : { parent_id: it.parentId, name: it.name }),
      size_bytes: file.size,
      idempotency_key: it.restartKey || it.id, // a restart after a changed file needs its own reservation
      ...(it.onConflict ? { on_conflict: it.onConflict } : {}),
    }), { signal })
    uploadId = u.id
    store().patch(id, { uploadId })
    await resumeStore.put({
      id, orgId: it.orgId, uploadId, parentId: it.parentId, name: it.name,
      size: file.size, lastModified: file.lastModified, relativePath: it.relativePath,
    })
  }

  if (signal.aborted) throw stopped()
  const { upload: u, parts: stored } = await withRetry(() => diskApi.upload(it.orgId, uploadId), { signal })
  if (signal.aborted) throw stopped()
  if (u.state === 'done') return finish(id)
  if (u.state !== 'reserved') throw errorWith('This upload stopped. Start it again.', { status: 410 })
  const plan = planParts(file.size, u.part_bytes)
  // Resuming with a re-picked file: reuse stored parts only if their bytes still match; else start over.
  const record = (await resumeStore.all()).find((r) => r.id === id) || { id, orgId: it.orgId, uploadId, parentId: it.parentId, name: it.name, size: file.size, lastModified: file.lastModified, relativePath: it.relativePath }
  const digests = { ...(record.digests || {}) }
  const rangeOf = (n) => { const p = plan.find((x) => x.number === n); return [p.start, p.end] }
  if (stored.length && !(await partsStillMatch(file, stored, digests, rangeOf))) {
    await diskApi.cancelUpload(it.orgId, uploadId).catch(() => null)
    await resumeStore.del(id)
    store().patch(id, { uploadId: null, restartKey: newId(), note: 'The file changed since this upload started, so it started again.' })
    return upload(id, signal)
  }
  const todo = missingParts(plan, stored)
  const base = storedBytes(plan, stored)
  const inflight = new Map()
  const report = () => store().patch(id, { loaded: base + [...inflight.values()].reduce((a, b) => a + b, 0) })
  report()

  const hash = file.size <= HASH_LIMIT ? sha256Hex(file, signal).catch(() => null) : Promise.resolve(null)

  // Part URLs last 15 minutes: fetch them in batches as the queue reaches them.
  const urls = new Map()
  const urlFor = async (number) => {
    if (!urls.has(number)) {
      const batch = todo.map((p) => p.number).filter((n) => n >= number).slice(0, URL_BATCH)
      const { parts } = await withRetry(() => diskApi.uploadParts(it.orgId, uploadId, batch), { signal })
      parts.forEach((p) => urls.set(p.number, p.url))
    }
    return urls.get(number)
  }

  await pool(todo, PART_CONCURRENCY, (part) => withRetry(async () => {
    const url = await urlFor(part.number)
    try {
      await putPart(url, file.slice(part.start, part.end, ''), (n) => { inflight.set(part.number, n); report() }, signal)
      digests[part.number] = await rangeDigest(file, part.start, part.end)
      await resumeStore.put({ ...record, digests })
    } catch (e) {
      inflight.delete(part.number)
      if (e.expired) urls.clear()
      throw e
    }
  }, { signal }))

  const sha = await hash
  // Cancelled while the last parts went up: do not complete (cancel() releases the reservation).
  if (signal.aborted || item(id)?.state === S.CANCELLED) throw stopped()
  const { node, version } = await withRetry(() => diskApi.completeUpload(it.orgId, uploadId, sha), { signal })
  // Cancelled while completing: the server has committed the file, so say so rather than disagree with it.
  if (signal.aborted || item(id)?.state === S.CANCELLED) {
    store().patch(id, { state: S.DONE, nodeId: node?.id, loaded: file.size, error: null, note: 'Too late to cancel. The file is uploaded.' })
    files.delete(id)
    await resumeStore.del(id)
    useDiskStore.getState().invalidate(it.orgId)
    return
  }
  store().patch(id, { loaded: file.size })
  return finish(id, node, version)
}

async function finish(id, node, version) {
  const it = item(id)
  const file = files.get(id)
  store().patch(id, { state: S.DONE, nodeId: node?.id })
  files.delete(id)
  await resumeStore.del(id)
  useDiskStore.getState().invalidate(it.orgId)
  // An exact-view rendition when this device has the engine; an offer of the engine when it has not.
  if (version && file) {
    import('./engine/rendition').then(({ renditionPlan, queueRendition }) => {
      const plan = renditionPlan(node.name, file.size)
      if (plan === 'offer') store().setEngineOffer(true)
      if (plan === 'convert') queueRendition({ orgId: it.orgId, file, name: node.name, versionId: version.id }).catch((e) => log.warn('DiskUpload', `rendition for ${node.name}: ${e.message}`))
    })
  }
  // Thumbnails are best effort and never block the upload (spec F5: made in the browser at upload).
  if (version && file) {
    makeThumbnail(file, node.name)
      .then(async (blob) => {
        if (!blob) return
        const { upload: put } = await diskApi.thumbnailUrl(it.orgId, version.id)
        const res = await fetch(put.url, { method: 'PUT', body: blob.slice(0, blob.size, '') }) // typeless, like the parts
        if (!res.ok) throw new Error(`storage refused it (${res.status})`)
        await confirmDerived(it.orgId, version.id, 'thumbnail')
        useDiskStore.getState().invalidate(it.orgId)
      })
      .catch((e) => log.warn('DiskUpload', `thumbnail for ${node.name}: ${e.message}`))
  }
}

// ── sealed uploads (6.6) ────────────────────────────────────────────────────

// Sealed: chunks are sealed in a worker as parts go up; the upload id, nonce
// prefix and wrapped K_v sit in IndexedDB so a reload can resume once the
// scope is open again. A rotation since the reservation means a fresh K_v:
// the reservation is dropped and the file starts again, once.
async function uploadSealedItem(id, file, signal, again = true) {
  const it = item(id)
  const sealed = await import('./sealed')
  const scope = sealed.scopeFor(it.orgId, it.sealed.scopeId)
  if (!scope) throw errorWith('Unlock sealed files in Disk to upload here.', { status: 0 })
  const record = it.uploadId ? (await resumeStore.all()).find((r) => r.id === id)?.sealedRecord : null
  // Names in a sealed folder are unique only because the client checks (build guide 10): same choices as a 409.
  let name = file.name
  let replaceNodeId = null
  if (!record) {
    const taken = await sealed.namesIn(it.orgId, scope, it.parentId)
    const clash = taken.get(file.name.toLowerCase())
    if (clash && !it.onConflict) throw sealed.nameTaken(file.name, clash)
    if (clash && it.onConflict === REPLACE) {
      if (clash.kind !== 'file') throw errorWith(`A folder named "${clash.name}" already exists here`, { status: 0 })
      replaceNodeId = clash.id
    } else if (clash) name = sealed.freeName(file.name, taken)
  }
  let res
  try {
    res = await sealed.uploadSealed({
      // A restart needs its own idempotency key: the first one would hand back the aborted reservation.
      orgId: it.orgId, scope, parentId: it.parentId, file, name, replaceNodeId, resume: record, signal, idempotencyKey: `${it.restartKey || id}${again ? '' : '-again'}`,
      onPart: async (rec, digests) => {
        await resumeStore.put({ id, orgId: it.orgId, uploadId: rec.upload_id, parentId: it.parentId, name: it.name, size: file.size,
          lastModified: file.lastModified, relativePath: it.relativePath, sealed: it.sealed, sealedRecord: { ...rec, digests } })
      },
      onReserved: async (rec) => {
        store().patch(id, { uploadId: rec.upload_id })
        await resumeStore.put({ id, orgId: it.orgId, uploadId: rec.upload_id, parentId: it.parentId, name: it.name, size: file.size,
          lastModified: file.lastModified, relativePath: it.relativePath, sealed: it.sealed, sealedRecord: rec })
      },
      report: (sent, total) => store().patch(id, { loaded: total ? Math.round((sent / total) * file.size) : 0 }),
    })
  } catch (e) {
    if (signal.aborted || e.aborted) throw e
    // The re-picked file differs from the one the stored parts came from: a fresh K_v and prefix, from the start.
    if (e.fileChanged) {
      await diskApi.cancelUpload(it.orgId, item(id)?.uploadId).catch(() => null)
      await resumeStore.del(id)
      store().patch(id, { uploadId: null, restartKey: newId(), note: 'The file changed since this upload started, so it started again.' })
      return uploadSealedItem(id, file, signal, again)
    }
    // The key rotated (epoch_changed) or the upload is otherwise closed: its part URLs and
    // completion stay refused, so resuming (Retry) can never work. Start a new upload, once.
    if (![SEAL.EPOCH_CHANGED, UPLOAD_CLOSED].includes(e?.data?.code) || !again) throw e
    const uploadId = item(id)?.uploadId
    await diskApi.cancelUpload(it.orgId, uploadId).catch(() => null)
    await resumeStore.del(id)
    store().patch(id, { uploadId: null })
    await (await import('../../stores/sealedStore')).default.getState().reopen(it.orgId, it.sealed.scopeId)
    return uploadSealedItem(id, file, signal, false)
  }
  if (res.done) return finish(id)
  store().patch(id, { loaded: file.size, state: S.DONE, nodeId: res.node?.id })
  files.delete(id)
  await resumeStore.del(id)
  useDiskStore.getState().invalidate(it.orgId)
  // A sealed rendition under R when this device has the engine (never a plaintext one), best effort.
  import('./engine/rendition').then(({ renditionPlan, queueRendition }) => {
    if (renditionPlan(file.name, file.size) === 'convert') queueRendition({ orgId: it.orgId, file, name: file.name, versionId: res.version.id, Kv: res.Kv }).catch((e) => log.warn('DiskUpload', `sealed rendition: ${e.message}`))
  })
  // A sealed thumbnail under T, best effort (6.6).
  makeThumbnail(file, file.name)
    .then(async (blob) => { if (blob) await sealed.uploadDerived({ orgId: it.orgId, Kv: res.Kv, versionId: res.version.id, variant: 'thumbnail', bytes: new Uint8Array(await blob.arrayBuffer()) }) })
    .catch((e) => log.warn('DiskUpload', `sealed thumbnail: ${e.message}`))
}

// ── folders ─────────────────────────────────────────────────────────────────

async function folderChildren(orgId, parentId) {
  const out = new Map()
  let cursor
  do {
    const d = await diskApi.children(orgId, parentId, { type: 'folders' }, cursor)
    d.nodes.forEach((n) => { if (n.name) out.set(n.name.toLowerCase(), n.id) })
    cursor = d.next_cursor
  } while (cursor)
  return out
}

/** The folders a dropped tree needs, parents before children: ['Q4', 'Q4/Budget']. */
export function folderPaths(entries) {
  const dirs = new Set()
  for (const { relativePath } of entries) {
    const parts = relativePath.split('/').slice(0, -1)
    parts.forEach((_, i) => dirs.add(parts.slice(0, i + 1).join('/')))
  }
  return [...dirs].sort((a, b) => a.split('/').length - b.split('/').length)
}

// Creates (or reuses, by name) every folder the drop needs; returns path -> folder id.
async function ensureFolders(orgId, parentId, entries) {
  const ids = new Map([['', parentId]])
  const known = new Map()
  for (const path of folderPaths(entries)) {
    const parent = ids.get(path.split('/').slice(0, -1).join('/'))
    const name = path.split('/').at(-1)
    if (!known.has(parent)) known.set(parent, await folderChildren(orgId, parent))
    let id = known.get(parent).get(name.toLowerCase())
    if (!id) {
      ;({ node: { id } } = await diskApi.createFolder(orgId, parent, name, false))
      known.get(parent).set(name.toLowerCase(), id)
    }
    ids.set(path, id)
  }
  return ids
}

// ── public actions ──────────────────────────────────────────────────────────

/**
 * Queue dropped or picked files into a folder. Folders in relativePath are
 * created first (existing ones with the same name are reused). onConflict
 * answers a name clash up front (KEEP_BOTH | REPLACE) where no panel can ask.
 * Returns the queued items' ids.
 */
export async function enqueue(orgId, parentId, entries, { sealed = null, onConflict = null } = {}) {
  if (!entries.length) return []
  // sealed: { scopeId } when the folder is inside a sealed scope; its folders are created sealed.
  const dirs = sealed
    ? await (await import('./sealed')).ensureSealedFolders(orgId, (await import('./sealed')).scopeFor(orgId, sealed.scopeId), parentId, entries)
    : await ensureFolders(orgId, parentId, entries)
  const list = entries.map(({ file, relativePath }) => {
    const id = newId()
    files.set(id, file)
    return {
      id, orgId, name: file.name, relativePath, size: file.size, loaded: 0, state: S.QUEUED, error: null,
      parentId: dirs.get(relativePath.split('/').slice(0, -1).join('/')), uploadId: null, onConflict, sealed,
    }
  })
  store().add(list)
  pump()
  return list.map((it) => it.id) // to follow in the upload store
}

/**
 * Queue a new version of an existing unsealed file (Edit as page saving its
 * markdown): POST /uploads with node_id, through the same queue, panel and
 * resume as any upload. Returns the local id to follow in the upload store.
 */
export function enqueueVersion(orgId, node, file) {
  const id = newId()
  files.set(id, file)
  store().add([{
    id, orgId, name: node.name, relativePath: node.name, size: file.size, loaded: 0, state: S.QUEUED, error: null,
    parentId: node.parent_id, nodeId: node.id, uploadId: null, onConflict: null, sealed: null,
  }])
  pump()
  return id
}

/** Name clash answer: keep both, replace (a new version of the existing file) or skip. applyAll answers the rest too. */
export function resolveConflict(id, choice, applyAll = false) {
  if (applyAll) {
    store().setConflictAll(choice)
    store().items.filter((it) => it.state === S.CONFLICT && it.id !== id).forEach((it) => resolveConflict(it.id, choice))
  }
  if (choice === SKIP) {
    files.delete(id)
    store().patch(id, { state: S.CANCELLED, error: 'Skipped' })
    return
  }
  store().patch(id, { state: S.QUEUED, onConflict: choice === REPLACE ? REPLACE : KEEP_BOTH, error: null })
  pump()
}

export function pause(id) {
  controllers.get(id)?.abort()
  store().patch(id, { state: S.PAUSED })
}

export function resume(id) {
  store().patch(id, { state: S.QUEUED, error: null })
  pump()
}

export const retry = resume

export async function cancel(id) {
  const it = item(id)
  if (!it || it.state === S.DONE || it.state === S.CANCELLED) return
  controllers.get(id)?.abort()
  store().patch(id, { state: S.CANCELLED })
  files.delete(id)
  await resumeStore.del(id)
  if (it?.uploadId) await diskApi.cancelUpload(it.orgId, it.uploadId).catch(() => null)
}

/** After a reload: list uploads left unfinished in this browser for the org. */
export async function restoreInterrupted(orgId) {
  const records = (await resumeStore.all()).filter((r) => r.orgId === orgId)
  const shown = new Set(store().items.map((it) => it.id))
  store().add(records.filter((r) => !shown.has(r.id)).map((r) => ({
    ...r, loaded: 0, state: S.INTERRUPTED, error: null, onConflict: null,
  })))
}

/** Resume an interrupted upload once the person picks the same file again. */
export function reattach(id, file) {
  const it = item(id)
  if (!it || file.name !== it.name || file.size !== it.size || (it.lastModified && file.lastModified !== it.lastModified)) {
    return false
  }
  files.set(id, file)
  resume(id)
  return true
}
