// Sealed Disk on the page (section 6): scopes, names, uploads, copies and
// restores, moves between scopes, downloads and previews, thumbnails, key
// holders and rotation, and single-file links. The format is lib/disk/crypto.js;
// media and large files stream through the Disk service worker (lib/disk/sw.js).
import api from '../api'
import diskApi, { SEAL } from './api'
import { previewPlan } from './preview/registry'
import { partsStillMatch, pool, rangeDigest, withRetry } from './upload'
import { diskWorker } from './swRegister'
import * as X from './crypto'

const base = (org) => `/orgs/${encodeURIComponent(org)}/disk`
const enc = encodeURIComponent
const qs = (o) => {
  const p = Object.entries(o).filter(([, v]) => v != null && v !== '')
  return p.length ? `?${new URLSearchParams(p)}` : ''
}

// ── Endpoints (build guide 6 and 7, Disk sealing API) ───────────────────────
export const sealedEndpoints = {
  // { scope: { id, epoch, rotation_due, grant: { epoch, sealed_key } | null, grants: [...],
  //   epochs: [{ epoch, previous_key_wrapped }], holders: [{ id, name, agent, role, has_key }], links: [{ id, node_id, ... }] } }
  scope: (org, id) => api.get(`${base(org)}/scopes/${enc(id)}`),
  rotate: (org, id, body) => api.post(`${base(org)}/scopes/${enc(id)}/rotate`, body),
  transfer: (org, id, body) => api.post(`${base(org)}/scopes/${enc(id)}/transfer`, body), // { membership_id, sealed_key, epoch }
  memberKeys: (org, ids) => api.get(`${base(org)}/keys/members${qs({ ids: ids.join(',') })}`), // { members: [{ membership_id, public_key }] }
  createNode: (org, body) => api.post(`${base(org)}/nodes`, body), // sealed: { parent_id, kind, id, metadata_ciphertext, key_epoch, sealed_key?, staged? }
  createShare: (org, body) => api.post(`${base(org)}/shares`, body), // { sealed: true, name, icon, color, sealed_key }
  rename: (org, id, body) => api.patch(`${base(org)}/nodes/${enc(id)}`, body), // { metadata_ciphertext, key_epoch }
  reserve: (org, body) => api.post(`${base(org)}/uploads`, body),
  complete: (org, id, body) => api.post(`${base(org)}/uploads/${enc(id)}/complete`, body),
  copy: (org, id, targetId) => api.post(`${base(org)}/nodes/${enc(id)}/copy`, { target_id: targetId, on_conflict: 'keep_both' }), // { upload }
  restore: (org, versionId) => api.post(`${base(org)}/versions/${enc(versionId)}/restore`), // { upload }
  move: (org, id, body) => api.post(`${base(org)}/nodes/${enc(id)}/move`, body), // { target_id, key_epoch, nodes, versions, pages }
  switch: (org, sourceId, stagedId) => api.post(`${base(org)}/nodes/${enc(sourceId)}/switch`, { staged_id: stagedId }),
  addShareHolder: (org, shareId, mid, body) => api.put(`${base(org)}/shares/${enc(shareId)}/members/${enc(mid)}`, body), // { role, sealed_key, epoch }
  addFolderHolder: (org, rootId, mid, body) => api.put(`${base(org)}/nodes/${enc(rootId)}/grants/${enc(mid)}`, body),
  createLink: (org, nodeId, body) => api.post(`${base(org)}/nodes/${enc(nodeId)}/links`, body), // { id, version_id, kdf_salt, wrapped_payload, password_verifier, expires_at, hide_download }
  pageUpdate: (org, id, body) => api.post(`${base(org)}/pages/${enc(id)}/updates`, body), // { update, epoch, seq }
  pageSnapshot: (org, id, body) => api.put(`${base(org)}/pages/${enc(id)}`, body), // { sealed_snapshot, epoch, seq }
}

const codeOf = (e) => e?.data?.code

/** Retries a sealed create with a fresh proposed id when the API says the id is taken (6.5). */
export async function withProposedId(prefix, fn, tries = 3) {
  for (let i = 0; ; i++) {
    try {
      return await fn(X.proposeId(prefix))
    } catch (e) {
      if (codeOf(e) !== SEAL.ID_TAKEN || i >= tries - 1) throw e
    }
  }
}

// ── Scopes ──────────────────────────────────────────────────────────────────

const scopes = new Map() // `${org}/${scopeId}` -> opened scope; memory only
const offers = new Map() // `${version}/${variant}` -> { register, url() } for the service worker

/** Forgets every key on this page and in the service worker (sign-out, lock, account switch, revocation). */
export function clearSealed() {
  scopes.clear()
  offers.clear()
  navigator.serviceWorker?.controller?.postMessage({ clear: true })
}
export const forgetScope = (orgId, scopeId) => scopes.delete(`${orgId}/${scopeId}`)
/** An already opened scope, or undefined. */
export const scopeFor = (orgId, scopeId) => scopes.get(`${orgId}/${scopeId}`)

export class NoKey extends Error {}

/**
 * Opens a sealed scope with the unlocked identity ({ publicKey, privateKey }).
 * Returns { id, epoch, rotationDue, key, keyFor(e), holders, links }. Throws
 * NoKey when this member holds no key (an admin who is not a member, a
 * disabled member, or one added before their key was sealed).
 */
export async function openScope(orgId, scopeId, identity, { refresh = false } = {}) {
  const k = `${orgId}/${scopeId}`
  if (!refresh && scopes.has(k)) return scopes.get(k)
  await X.init()
  const { scope } = await sealedEndpoints.scope(orgId, scopeId)
  if (!scope.grant) throw new NoKey('You hold no key to this sealed folder')
  const mine = new Map(scope.grants.map((g) => [g.epoch, g.sealed_key]))
  const chain = new Map(scope.epochs.map((e) => [e.epoch, X.unb64(e.previous_key_wrapped)]))
  const top = scope.grant.epoch
  const key = X.openGrant(X.unb64(scope.grant.sealed_key), identity.publicKey, identity.privateKey)
  const cache = new Map([[top, key]])
  const opened = {
    id: scope.id,
    epoch: scope.epoch,
    current: top === scope.epoch, // false: a rotation happened and this member was not re-granted
    rotationDue: !!scope.rotation_due,
    key,
    holders: scope.holders || [],
    links: scope.links || [],
    keyFor(e) {
      if (cache.has(e)) return cache.get(e)
      // A grant for that epoch opens directly; otherwise walk back from the newest one held.
      const k2 = mine.has(e)
        ? X.openGrant(X.unb64(mine.get(e)), identity.publicKey, identity.privateKey)
        : X.walkBack(key, top, e, scope.id, (n) => chain.get(n) || missing(n))
      cache.set(e, k2)
      return k2
    },
  }
  scopes.set(k, opened)
  return opened
}
const missing = (n) => { throw new X.SealError(`epoch ${n} is not in the chain`) }

/**
 * Names, types and plaintext sizes of sealed nodes: each gets name, mime,
 * opened: true and size_bytes as plaintext (6.6: computed from the stored size;
 * the manifest is the authority once a version is opened). Failures get sealedError.
 */
export function openNames(scope, nodes) {
  return nodes.map((n) => {
    if (!n.sealed || !n.metadata_ciphertext || n.opened) return n
    try {
      const meta = X.openMeta(scope.keyFor(n.key_epoch), n.id, X.unb64(n.metadata_ciphertext))
      const size = n.kind === 'file' ? X.plainSize(n.size_bytes || 0, chunkBytesFor(meta.mime)) : n.size_bytes
      return { ...n, name: meta.name, mime: meta.mime, opened: true, stored_bytes: n.size_bytes, size_bytes: size }
    } catch (e) {
      return { ...n, sealedError: e.message }
    }
  })
}

/** Sealed metadata for a node under the current epoch: { metadata_ciphertext, key_epoch }. */
export const sealName = (scope, nodeId, name, mime = null) => ({ metadata_ciphertext: X.b64(X.sealMeta(scope.key, nodeId, { name, mime })), key_epoch: scope.epoch })

// ── Names inside a scope: unique per folder, case-insensitively, kept by the client (build guide 10) ──

/** "a.pdf" -> "a (1).pdf"; folders keep dots in their name (Disk::Node.suffixed). */
export function suffixed(name, n, folder = false) {
  if (!n) return name
  const dot = folder ? -1 : name.lastIndexOf('.')
  const ext = dot > 0 ? name.slice(dot) : ''
  return `${name.slice(0, name.length - ext.length)} (${n})${ext}`
}
/** The first free name: name, "name (1)", "name (2)", ... against taken (lower-case names). */
export function freeName(name, taken, folder = false) {
  let n = 0
  while (taken.has(suffixed(name, n, folder).toLowerCase())) n++
  return suffixed(name, n, folder)
}
/** The opened names of a sealed folder's children: Map(lower-case name -> node). */
export async function namesIn(orgId, scope, folderId) {
  const out = new Map()
  let cursor
  do {
    const d = await diskApi.children(orgId, folderId, {}, cursor)
    openNames(scope, d.nodes).forEach((n) => { if (n.name) out.set(n.name.toLowerCase(), n) })
    cursor = d.next_cursor
  } while (cursor)
  return out
}
/** A clash with a sealed name, answered like the API's 409 so the same choices apply. */
export const nameTaken = (name, node) => Object.assign(new Error(`An item named "${name}" already exists here`), { status: 409, sealedClash: true, node })

// ── New scopes, folders, pages, renames ─────────────────────────────────────

/** A sealed folder on the caller's own C:\ (a new scope at epoch 1, 6.2). */
export async function createSealedRoot({ orgId, parentId, name, identity }) {
  await X.init()
  const Ks = X.newKey()
  return withProposedId('dnd', (id) => sealedEndpoints.createNode(orgId, {
    parent_id: parentId, kind: 'folder', sealed: true, id,
    metadata_ciphertext: X.b64(X.sealMeta(Ks, id, { name, mime: null })), key_epoch: 1,
    sealed_key: X.b64(X.sealGrant(Ks, identity.publicKey)),
  }))
}

/** A sealed share: its name stays plain (admins see and manage it), its key is sealed to the creator. */
export async function createSealedShare({ orgId, name, icon, color, identity }) {
  await X.init()
  const Ks = X.newKey()
  return sealedEndpoints.createShare(orgId, { sealed: true, name, icon, color, sealed_key: X.b64(X.sealGrant(Ks, identity.publicKey)) })
}

/** A folder or page inside an open scope, under a free name (keep both). staged: invisible until switched (6.8). */
export async function createSealedChild({ orgId, scope, parentId, name, kind = 'folder', staged = false }) {
  const free = freeName(name, await namesIn(orgId, scope, parentId), kind === 'folder')
  return withProposedId('dnd', (id) => sealedEndpoints.createNode(orgId, { parent_id: parentId, kind, id, ...sealName(scope, id, free), ...(staged ? { staged: true } : {}) }))
}

/** A sealed rename; keepBoth picks a free name, otherwise a clash throws nameTaken (409). */
export async function renameSealed(orgId, scope, node, name, keepBoth = false) {
  const taken = await namesIn(orgId, scope, node.parent_id)
  const other = taken.get(name.toLowerCase())
  let final = name
  if (other && other.id !== node.id) {
    if (!keepBoth) throw nameTaken(name, other)
    taken.delete(node.name?.toLowerCase())
    final = freeName(name, taken, node.kind === 'folder')
  }
  return sealedEndpoints.rename(orgId, node.id, sealName(scope, node.id, final, node.mime ?? null))
}

// ── Versions ────────────────────────────────────────────────────────────────

/** K_v and the checked manifest of a version ({ id, key_epoch, wrapped_key, manifest_ciphertext }). */
export function openVersion(scope, nodeId, version) {
  const Kv = X.unwrapVersionKey(scope.keyFor(version.key_epoch), nodeId, version.id, X.unb64(version.wrapped_key))
  const manifest = X.openManifest(Kv, nodeId, version.id, X.unb64(version.manifest_ciphertext))
  return { Kv, manifest }
}

/** The version a node's current_version_id names, with its sealed fields. */
export async function currentVersion(orgId, node) {
  let cursor
  do {
    const d = await diskApi.versions(orgId, node.id, cursor)
    const v = d.versions.find((x) => x.id === node.current_version_id)
    if (v) return v
    cursor = d.next_cursor
  } while (cursor)
  throw new Error('This file has no version yet')
}

/** Every version of a node (for moves between scopes). */
async function allVersions(orgId, nodeId) {
  const out = []
  let cursor
  do {
    const d = await diskApi.versions(orgId, nodeId, cursor)
    out.push(...d.versions)
    cursor = d.next_cursor
  } while (cursor)
  return out
}

// ── Upload ──────────────────────────────────────────────────────────────────

const isMedia = (mime) => /^(video|audio)\//.test(mime || '')
/** Section 1: 1 MiB chunks for audio and video, 4 MiB otherwise. */
export const chunkBytesFor = (mime) => (isMedia(mime) ? X.CHUNK_MEDIA : X.CHUNK_DEFAULT)

function sealer(file, C, prefix, chunkBytes, partBytes) {
  const worker = new Worker(new URL('./sealWorker.js', import.meta.url), { type: 'module' })
  let seq = 0
  const waiting = new Map()
  worker.onmessage = ({ data }) => {
    const w = waiting.get(data.id)
    waiting.delete(data.id)
    if (data.error) w?.reject(new Error(data.error))
    else w?.resolve(data)
  }
  const call = (msg) => new Promise((resolve, reject) => { const id = ++seq; waiting.set(id, { resolve, reject }); worker.postMessage({ ...msg, id }) })
  return {
    ready: call({ start: { file, C, prefix, chunkBytes, partBytes } }),
    part: (n) => call({ part: n }),
    stop: () => worker.terminate(),
  }
}

/**
 * Seals and uploads one file (6.6, section 8), resuming when `resume` holds
 * { upload_id, prefix, wrapped_key, epoch, node_id, version_id, chunk_bytes }
 * from IndexedDB. onReserved(record) is called with that record to keep.
 * report(sentBytes, totalBytes). staged: invisible until switched (6.8).
 * A rotation since the reservation answers 409 epoch_changed: the caller
 * cancels the upload and starts again with a fresh K_v.
 */
export async function uploadSealed({ orgId, scope, parentId, file, name = file.name, replaceNodeId = null, mime = file.type || 'application/octet-stream', resume, onReserved = () => {}, onPart = () => {}, report = () => {}, signal, staged = false, idempotencyKey }) {
  await X.init()
  let rec = resume
  let Kv
  let prefix
  if (rec) {
    Kv = X.unwrapVersionKey(scope.keyFor(rec.epoch), rec.node_id, rec.version_id, X.unb64(rec.wrapped_key))
    prefix = X.unb64(rec.prefix)
  } else {
    Kv = X.newKey()
    prefix = X.newKey().slice(0, 16)
    const chunkBytes = chunkBytesFor(mime)
    const common = { size_bytes: X.cipherSize(file.size, chunkBytes), sealed: true, chunk_bytes: chunkBytes, key_epoch: scope.epoch, idempotency_key: idempotencyKey }
    // A replace is a new version of the existing node (its name stays); a new file brings its id and name.
    const { upload } = replaceNodeId
      ? await sealedEndpoints.reserve(orgId, { node_id: replaceNodeId, ...common })
      : await withProposedId('dnd', (id) => sealedEndpoints.reserve(orgId, {
        parent_id: parentId, ...common, id, ...sealName(scope, id, name, mime), ...(staged ? { staged: true } : {}),
      }))
    rec = {
      upload_id: upload.id, node_id: upload.node_id, version_id: upload.version_id, epoch: upload.key_epoch,
      chunk_bytes: upload.chunk_bytes, prefix: X.b64(prefix), wrapped_key: X.b64(X.wrapVersionKey(scope.keyFor(upload.key_epoch), upload.node_id, upload.version_id, Kv)),
    }
    await onReserved(rec)
  }
  const { upload, parts: stored = [] } = await diskApi.upload(orgId, rec.upload_id)
  if (upload.state === 'done') return { done: true, node_id: rec.node_id }
  const chunkBytes = rec.chunk_bytes
  const partBytes = upload.part_bytes
  const total = X.cipherSize(file.size, chunkBytes)
  const numbers = Array.from({ length: X.partCount(file.size, chunkBytes, partBytes) }, (_, i) => i + 1)
  const have = new Set(stored.map((p) => p.number))
  // Each sent part's plaintext range is digested; a resume reuses stored parts only if the re-picked file still matches.
  const plainRange = (n) => { const p = X.partPlan(n, file.size, chunkBytes, partBytes); return [p.first * chunkBytes, Math.min(file.size, (p.last + 1) * chunkBytes)] }
  const digests = { ...(rec.digests || {}) }
  if (stored.length && !(await partsStillMatch(file, stored, digests, plainRange))) throw Object.assign(new Error('The file changed since this upload started'), { fileChanged: true })
  const tags = new Uint8Array(X.chunkCount(file.size, chunkBytes) * X.TAG_BYTES)
  const s = sealer(file, versionC(Kv), prefix, chunkBytes, partBytes)
  try {
    await s.ready
    let sent = stored.reduce((a, p) => a + (p.size_bytes || 0), 0)
    report(sent, total)
    const urls = new Map()
    const todo = numbers.filter((n) => !have.has(n))
    const urlFor = async (n) => {
      if (!urls.has(n)) (await diskApi.uploadParts(orgId, rec.upload_id, todo.filter((x) => x >= n).slice(0, 100))).parts.forEach((p) => urls.set(p.number, p.url))
      return urls.get(n)
    }
    const keepTags = (got) => got.forEach(([i, tag]) => tags.set(tag, i * X.TAG_BYTES))
    await pool(todo, 3, (n) => withRetry(async () => {
      if (signal?.aborted) throw Object.assign(new Error('Stopped'), { aborted: true })
      const { bytes, tags: got } = await s.part(n)
      keepTags(got)
      const res = await fetch(await urlFor(n), { method: 'PUT', body: bytes, signal })
      if (!res.ok) {
        if (res.status === 403) urls.clear()
        throw Object.assign(new Error(`The upload failed (${res.status})`), { status: res.status })
      }
      digests[n] = await rangeDigest(file, ...plainRange(n))
      await onPart(rec, digests)
      report((sent += bytes.length), total)
    }, { signal }))
    // Parts sent before a reload: seal their chunks again for the tags only (deterministic).
    for (const n of numbers.filter((x) => have.has(x))) keepTags((await s.part(n)).tags)
    const manifest = X.buildManifest({ nodeId: rec.node_id, versionId: rec.version_id, size: file.size, chunkBytes, prefix, tags })
    try {
      return { ...(await sealedEndpoints.complete(orgId, rec.upload_id, { wrapped_key: rec.wrapped_key, manifest_ciphertext: X.b64(X.sealManifest(Kv, manifest)) })), Kv }
    } catch (e) {
      if (codeOf(e) === SEAL.EPOCH_CHANGED) e.epochChanged = true
      throw e
    }
  } finally {
    s.stop()
  }
}
const versionC = (Kv) => X.versionKeys(Kv).C

/** Folders a dropped tree needs inside a sealed folder: path -> id, reusing same-named ones. */
export async function ensureSealedFolders(orgId, scope, parentId, entries) {
  const ids = new Map([['', parentId]])
  const known = new Map()
  const dirs = new Set()
  for (const { relativePath } of entries) {
    const parts = relativePath.split('/').slice(0, -1)
    parts.forEach((_, i) => dirs.add(parts.slice(0, i + 1).join('/')))
  }
  for (const path of [...dirs].sort((a, b) => a.split('/').length - b.split('/').length)) {
    const parent = ids.get(path.split('/').slice(0, -1).join('/'))
    const name = path.split('/').at(-1)
    if (!known.has(parent)) {
      const m = new Map()
      let cursor
      do {
        const d = await diskApi.children(orgId, parent, { type: 'folders' }, cursor)
        openNames(scope, d.nodes).forEach((n) => { if (n.name) m.set(n.name.toLowerCase(), n.id) })
        cursor = d.next_cursor
      } while (cursor)
      known.set(parent, m)
    }
    let id = known.get(parent).get(name.toLowerCase())
    if (!id) {
      ;({ node: { id } } = await createSealedChild({ orgId, scope, parentId: parent, name }))
      known.get(parent).set(name.toLowerCase(), id)
    }
    ids.set(path, id)
  }
  return ids
}

// ── Copy, restore, move between scopes (6.8) ────────────────────────────────

/**
 * Copies one sealed file into a folder of `target` (the same scope or another):
 * the API copies the object and answers { upload }; completing it with the
 * re-wrapped key, manifest and name makes the copy visible.
 */
export async function copySealedFile({ orgId, source, target, node, targetId, keepBoth = true }) {
  const taken = await namesIn(orgId, target, targetId)
  if (taken.has(node.name.toLowerCase()) && !keepBoth) throw nameTaken(node.name, taken.get(node.name.toLowerCase()))
  const name = freeName(node.name, taken)
  const version = await currentVersion(orgId, node)
  const { Kv, manifest } = openVersion(source, node.id, version)
  const { upload } = await sealedEndpoints.copy(orgId, node.id, targetId)
  const toKey = target.keyFor(upload.key_epoch)
  return sealedEndpoints.complete(orgId, upload.id, X.rewrapVersion({
    Ks: toKey, Kv, manifest, nodeId: upload.node_id, versionId: upload.version_id, meta: { name, mime: node.mime },
  }))
}

/** Before moving sealed nodes into a sealed folder: the clashes there (by opened name), [{ node, clash }]. */
export async function moveClashes(orgId, target, targetId, nodes) {
  const taken = await namesIn(orgId, target, targetId)
  return nodes.map((n) => ({ node: n, clash: taken.get(n.name?.toLowerCase()) })).filter((x) => x.clash && x.clash.id !== x.node.id)
}

/** Restores an old version: a new version on the same node with K_v re-wrapped under the current epoch. */
export async function restoreSealedVersion({ orgId, scope, node, version }) {
  const { Kv, manifest } = openVersion(scope, node.id, version)
  const { upload } = await sealedEndpoints.restore(orgId, version.id)
  return sealedEndpoints.complete(orgId, upload.id, X.rewrapVersion({ Ks: scope.keyFor(upload.key_epoch), Kv, manifest, nodeId: upload.node_id, versionId: upload.version_id }))
}

/**
 * Moves a sealed node (and its subtree) into another sealed scope (6.8):
 * every node's name and every version's key re-sealed under the target, every
 * saved page re-snapshotted covering its update_seq. Objects are not touched.
 */
export async function moveAcrossScopes({ orgId, from, to, node, targetId, name = null }) {
  const all = [node]
  if (node.kind === 'folder') {
    let cursor
    do {
      const d = await diskApi.tree(orgId, node.id, cursor)
      all.push(...d.nodes.filter((n) => n.id !== node.id))
      cursor = d.next_cursor
    } while (cursor)
  }
  const nodes = []
  const versions = []
  const pages = []
  for (const n of all) {
    const meta = X.openMeta(from.keyFor(n.key_epoch), n.id, X.unb64(n.metadata_ciphertext))
    if (n === node && name) meta.name = name // kept both: the moved item takes a free name at the target
    nodes.push({ id: n.id, metadata_ciphertext: X.b64(X.sealMeta(to.key, n.id, meta)) })
    if (n.kind === 'file') {
      for (const v of await allVersions(orgId, n.id)) {
        const Kv = X.unwrapVersionKey(from.keyFor(v.key_epoch), n.id, v.id, X.unb64(v.wrapped_key))
        versions.push({ id: v.id, wrapped_key: X.b64(X.wrapVersionKey(to.key, n.id, v.id, Kv)) })
      }
    }
    if (n.kind === 'page') {
      const { page } = await diskApi.page(orgId, n.id)
      if (page.sealed_snapshot || page.updates?.length) {
        const { state, seq } = await openSealedPage(from, n.id, page)
        pages.push({ id: n.id, sealed_snapshot: X.b64(X.sealPageSnapshot(to.key, n.id, to.epoch, seq, state)), seq })
      }
    }
  }
  return sealedEndpoints.move(orgId, node.id, { target_id: targetId, key_epoch: to.epoch, nodes, versions, pages })
}

// ── Download and preview ────────────────────────────────────────────────────

/** Files at or under this are opened on the page into a Blob; larger and media stream through the worker. */
export const BLOB_LIMIT = 64 * 1024 * 1024
/**
 * Without a service worker (the desktop app's custom-scheme webview, a browser
 * without them), media and large files are opened chunk by chunk into a Blob up
 * to this size; above it the person is sent to the browser. ponytail: one fixed
 * ceiling; a streamed save to disk would lift it where the platform allows.
 */
export const NO_WORKER_LIMIT = 1024 * 1024 * 1024

/** Downloads and opens a whole version on the page (lengths, every chunk, last flag, tags). Returns plaintext bytes. */
export async function sealedBytes({ orgId, scope, nodeId, version, signal }) {
  const { Kv, manifest } = openVersion(scope, nodeId, version)
  const { download } = await diskApi.versionDownload(orgId, version.id)
  return openStored(Kv, manifest, download.url, signal)
}
async function openStored(Kv, manifest, url, signal) {
  const res = await fetch(url, { signal, credentials: 'omit', referrerPolicy: 'no-referrer' })
  if (!res.ok) throw new Error(`The file didn't load (${res.status})`)
  return X.openWhole(versionC(Kv), manifest, new Uint8Array(await res.arrayBuffer()))
}
/**
 * A whole version opened chunk by chunk as it downloads, into a Blob: never
 * the ciphertext and the plaintext in memory at once. Same checks as openWhole:
 * lengths, every chunk, the last flag and the tags.
 */
export async function sealedBlob({ orgId, scope, nodeId, version, mime, signal, url }) {
  const { Kv, manifest } = openVersion(scope, nodeId, version)
  const src = url || (await diskApi.versionDownload(orgId, version.id)).download.url
  const res = await fetch(src, { signal, credentials: 'omit', referrerPolicy: 'no-referrer' })
  if (!res.ok) throw new Error(`The file didn't load (${res.status})`)
  return streamToBlob(Kv, manifest, res, mime)
}
async function streamToBlob(Kv, manifest, res, mime) {
  const C = versionC(Kv)
  const { size, chunk_bytes: cb, chunks } = manifest
  const want = X.cipherSize(size, cb)
  const parts = []
  const tags = new Uint8Array(chunks * X.TAG_BYTES)
  let buf = new Uint8Array(0)
  let i = 0
  let got = 0
  const reader = res.body.getReader()
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    got += value.length
    if (got > want) throw new X.SealError('stored object has the wrong length')
    buf = buf.length ? X.concat(buf, value) : value
    while (i < chunks) {
      const [a, b] = X.chunkCipherRange(i, size, cb)
      const len = b - a + 1
      if (buf.length < len) break
      const piece = buf.subarray(0, len)
      parts.push(X.openChunk(C, manifest.prefixBytes, i, i === chunks - 1, piece))
      tags.set(piece.subarray(len - X.TAG_BYTES), i * X.TAG_BYTES)
      buf = buf.slice(len)
      i++
    }
  }
  if (got !== want || i !== chunks) throw new X.SealError('stored object has the wrong length')
  if (X.b64(X.tagsDigest(tags)) !== manifest.tags) throw new X.SealError('chunk tags do not match the manifest')
  return new Blob(parts, { type: mime || 'application/octet-stream' })
}

function listen() {
  if (listen.on || !navigator.serviceWorker) return
  listen.on = true
  navigator.serviceWorker.addEventListener('message', async (e) => {
    const d = e.data
    const offer = d && typeof d.id === 'string' && offers.get(`${d.version}/${d.variant}`)
    if (!offer || !e.source) return
    if (d.need === 'key') e.source.postMessage({ reply: d.id, register: offer.register })
    if (d.need === 'url') e.source.postMessage({ reply: d.id, url: await offer.url() })
  })
}

/**
 * A same-origin URL that plays or downloads a sealed version through the
 * worker (6.11), or null when there is no worker (no storage origins, or a
 * browser without service workers). The worker is at scope "/" and claims
 * every tab on activation, so a tab that came from mail is controlled too.
 */
export async function sealedUrl({ orgId, scope, nodeId, version, mime, url }) {
  const controller = await diskWorker()
  if (!controller) return null
  listen()
  const { Kv, manifest } = openVersion(scope, nodeId, version)
  const variant = 'content'
  const register = { version: version.id, variant, key: versionC(Kv), prefix: manifest.prefixBytes, size: manifest.size, chunk_bytes: manifest.chunk_bytes, mime: mime || 'application/octet-stream' }
  offers.set(`${version.id}/${variant}`, { register, url: url || (async () => (await diskApi.versionDownload(orgId, version.id)).download.url) })
  controller.postMessage({ register })
  return `/disk/sealed/${version.id}/${variant}`
}

/**
 * A sealed file through the existing preview registry: { node, plan, url, revoke }.
 * node is the opened one (name, type, plaintext size); small files become a
 * blob: URL, media and large files a worker URL, so every F5 renderer applies.
 */
export async function sealedPreview({ orgId, scope, node, version, signal }) {
  const [opened] = openNames(scope, [node])
  if (opened.sealedError) throw new X.SealError(opened.sealedError)
  const { manifest } = openVersion(scope, node.id, version)
  const plain = { ...opened, sealed: false, size_bytes: manifest.size }
  const plan = previewPlan(plain)
  const none = { node: plain, plan, url: null, revoke: () => {} }
  if (!plan.renderer) return none
  if (isMedia(opened.mime) || manifest.size > BLOB_LIMIT) {
    const url = await sealedUrl({ orgId, scope, nodeId: node.id, version, mime: opened.mime })
    if (url) return { node: plain, plan, url, revoke: () => offers.delete(`${version.id}/content`) }
    // No worker here: open it in memory if that is sane, else send the person to the browser.
    if (manifest.size > NO_WORKER_LIMIT) return { ...none, plan: { reason: 'browser', limit: NO_WORKER_LIMIT } }
  }
  const url = URL.createObjectURL(await sealedBlob({ orgId, scope, nodeId: node.id, version, mime: opened.mime, signal }))
  return { node: plain, plan, url, revoke: () => URL.revokeObjectURL(url) }
}

/** Saves a sealed file: a worker URL with the download attribute, or a blob when there is no worker. */
export async function downloadSealed({ orgId, scope, node }) {
  const version = await currentVersion(orgId, node)
  const { manifest } = openVersion(scope, node.id, version)
  const viaWorker = manifest.size > BLOB_LIMIT && await sealedUrl({ orgId, scope, nodeId: node.id, version, mime: node.mime })
  if (!viaWorker && manifest.size > NO_WORKER_LIMIT) throw new Error('This sealed file is too large to save from here. Open Disk in your browser to download it.')
  const href = viaWorker || URL.createObjectURL(await sealedBlob({ orgId, scope, nodeId: node.id, version, mime: node.mime }))
  const a = document.createElement('a')
  a.href = href
  a.download = node.name || 'file'
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
  if (!viaWorker) setTimeout(() => URL.revokeObjectURL(href), 60_000)
}

// ── Thumbnails and renditions (6.6) ─────────────────────────────────────────

/** Seals and uploads a thumbnail or rendition after its version exists. */
export async function uploadDerived({ orgId, Kv, versionId, variant, bytes }) {
  await X.init()
  const object = X.sealDerived(variant, Kv, bytes)
  const { upload } = await (variant === 'thumbnail' ? diskApi.thumbnailUrl(orgId, versionId) : diskApi.renditionUrl(orgId, versionId))
  const res = await fetch(upload.url, { method: 'PUT', body: object })
  if (!res.ok) throw new Error(`Storage refused the ${variant} (${res.status})`)
  await (await import('./upload')).confirmDerived(orgId, versionId, variant)
}

/** Opens a sealed thumbnail or rendition into a Blob. */
export async function derivedBlob({ orgId, scope, nodeId, version, variant, mime }) {
  const { Kv } = openVersion(scope, nodeId, version)
  const { download } = await diskApi.versionDownload(orgId, version.id, variant)
  const res = await fetch(download.url, { credentials: 'omit', referrerPolicy: 'no-referrer' })
  if (!res.ok) throw new Error(`The ${variant} did not load (${res.status})`)
  return new Blob([X.openDerived(variant, Kv, new Uint8Array(await res.arrayBuffer()))], { type: mime })
}

// ── Holders and rotation (6.7) ──────────────────────────────────────────────

async function publicKeys(orgId, ids) {
  if (!ids.length) return new Map()
  const { members } = await sealedEndpoints.memberKeys(orgId, ids)
  return new Map(members.map((m) => [m.membership_id, m.public_key ? X.unb64(m.public_key) : null]))
}

/** Adds a key holder with a role: the current K_s sealed to their identity key in the same request. */
export async function addHolder({ orgId, scope, shareId, membershipId, role }) {
  await X.init()
  const pk = (await publicKeys(orgId, [membershipId])).get(membershipId)
  if (!pk) throw Object.assign(new Error('This person has no encryption key yet.'), { data: { code: SEAL.NO_IDENTITY_KEY } })
  const body = { role, sealed_key: X.b64(X.sealGrant(scope.key, pk)), epoch: scope.epoch }
  return shareId ? sealedEndpoints.addShareHolder(orgId, shareId, membershipId, body) : sealedEndpoints.addFolderHolder(orgId, scope.id, membershipId, body)
}

/** Hands the scope key to another member with manage (offboarding, 6.7). */
export async function transferScope({ orgId, scope, membershipId }) {
  await X.init()
  const pk = (await publicKeys(orgId, [membershipId])).get(membershipId)
  if (!pk) throw new Error('This person has no encryption key yet.')
  return sealedEndpoints.transfer(orgId, scope.id, { membership_id: membershipId, sealed_key: X.b64(X.sealGrant(scope.key, pk)), epoch: scope.epoch })
}

/**
 * Removes key holders (remove: [] clears rotation_due), granting every holder
 * who stays the new key. Holders come from GET /scopes (active role holders).
 */
export async function rotateScope({ orgId, scope, remove }) {
  await X.init()
  const stay = scope.holders.map((h) => h.id).filter((id) => !remove.includes(id))
  const keys = await publicKeys(orgId, stay)
  const without = stay.filter((id) => !keys.get(id))
  if (without.length) throw new Error(`${without.length === 1 ? 'A key holder has' : `${without.length} key holders have`} no encryption key, so they can't get the new key.`)
  const { body } = X.buildRotation({ scopeId: scope.id, epoch: scope.epoch, Ks: scope.key, remove, holders: stay.map((id) => ({ membership_id: id, public_key: keys.get(id) })) })
  const res = await sealedEndpoints.rotate(orgId, scope.id, body)
  forgetScope(orgId, scope.id)
  return res
}

// ── Single-file public links (6.9) ──────────────────────────────────────────

/**
 * Makes a public link to the current version of a sealed file. Returns the
 * link with url = `<url>#<secret>`; the secret never reaches the server.
 */
export async function createSealedLink({ orgId, scope, node, password, expiresAt, hideDownload }) {
  await X.init()
  const version = await currentVersion(orgId, node)
  const { Kv } = openVersion(scope, node.id, version)
  const { secret, salt } = X.newLinkSecrets()
  const keys = X.linkKeys({ secret, salt, password: password || null })
  const { link } = await withProposedId('dln', (id) => sealedEndpoints.createLink(orgId, node.id, {
    id, version_id: version.id, kdf_salt: X.b64(salt),
    wrapped_payload: X.b64(X.sealLinkPayload(keys.wrapKey, id, version.id, { Kv, mime: node.mime, name: node.name })),
    ...(keys.verifier ? { password_verifier: X.b64(keys.verifier) } : {}),
    expires_at: expiresAt || undefined, hide_download: !!hideDownload,
  }))
  return { ...link, url: `${link.url}#${X.b64url(secret)}` }
}

/** The verifier a sealed link's unlock sends, from the password and the link's salt. */
export async function linkVerifier(secretB64url, saltB64, password) {
  await X.init()
  return X.b64(X.linkKeys({ secret: X.unb64url(secretB64url), salt: X.unb64(saltB64), password }).verifier)
}

/** Opens an unlocked sealed link (GET /disk/links/:token with link.node): { Kv, name, mime, manifest, versionId }. */
export async function openSealedLink({ secretB64url, password, link }) {
  await X.init()
  const p = link.sealed_payload
  const { wrapKey } = X.linkKeys({ secret: X.unb64url(secretB64url), salt: X.unb64(link.kdf_salt), password: password || null })
  const payload = X.openLinkPayload(wrapKey, p.link_id, p.version_id, X.unb64(p.wrapped_payload))
  const manifest = X.openManifest(payload.Kv, link.node.id, p.version_id, X.unb64(p.manifest_ciphertext))
  return { ...payload, manifest, versionId: p.version_id }
}

/** Plaintext of a sealed link's file: whole for small files, or a worker URL for media and large ones. */
export async function sealedLinkSource({ opened, url, previewUrl }) {
  const { Kv, manifest, mime, versionId } = opened
  if (isMedia(mime) || manifest.size > BLOB_LIMIT) {
    const controller = await diskWorker()
    if (controller) {
      listen()
      const register = { version: versionId, variant: 'content', key: versionC(Kv), prefix: manifest.prefixBytes, size: manifest.size, chunk_bytes: manifest.chunk_bytes, mime: mime || 'application/octet-stream' }
      offers.set(`${versionId}/content`, { register, url: async () => previewUrl || url })
      controller.postMessage({ register })
      return { url: `/disk/sealed/${versionId}/content` }
    }
  }
  if (manifest.size > NO_WORKER_LIMIT) throw new Error('This file is too large to open here. Open the link in another browser.')
  const res = await fetch(previewUrl || url, { credentials: 'omit', referrerPolicy: 'no-referrer' })
  if (!res.ok) throw new Error(`The file didn't load (${res.status})`)
  return { url: URL.createObjectURL(await streamToBlob(Kv, manifest, res, mime)), blob: true }
}

// ── Sealed pages (6.10) ─────────────────────────────────────────────────────

/**
 * The plaintext Yjs state of a sealed page from GET /pages: the snapshot plus
 * the updates above it, in order. Returns { state (merged update), seq, updates }.
 */
export async function openSealedPage(scope, nodeId, page) {
  const Y = await import('yjs')
  const doc = new Y.Doc()
  let seq = page.snapshot_seq || 0
  if (page.sealed_snapshot) Y.applyUpdate(doc, X.openPageSnapshot(scope.keyFor(page.snapshot_epoch), nodeId, page.snapshot_epoch, page.snapshot_seq, X.unb64(page.sealed_snapshot)))
  for (const u of page.updates || []) {
    if (u.seq <= seq) continue
    Y.applyUpdate(doc, X.openPageUpdate(scope.keyFor(u.epoch), nodeId, u.epoch, u.seq, X.unb64(u.ciphertext)))
    seq = u.seq
  }
  const state = Y.encodeStateAsUpdate(doc)
  doc.destroy()
  return { state, seq: Math.max(seq, page.update_seq || 0) }
}

/** What downloadZip needs to zip sealed items opened in this browser (spec F7: pages as markdown only with the key). */
export function sealedZip(orgId, scope) {
  return {
    names: (nodes) => openNames(scope, nodes),
    file: async (node) => sealedBytes({ orgId, scope, nodeId: node.id, version: await currentVersion(orgId, node) }),
    page: async (node) => {
      const [{ page }, { stateToMarkdown }] = await Promise.all([diskApi.page(orgId, node.id), import('./pages')])
      return stateToMarkdown((await openSealedPage(scope, node.id, page)).state)
    },
  }
}
