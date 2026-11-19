// Moving and copying across a seal boundary (6.8): unsealed into a sealed
// scope, or sealed into an unsealed place. The client re-uploads each file and
// page one at a time. A move commits each item in three steps: stage the
// destination (invisible until switched), verify it by reading back its size
// and manifest, switch (the API links it, unlinks the source and revokes its
// links, then purges the source). Folders are recreated at the destination and
// the emptied source folders deleted at the end. The job lives in IndexedDB so
// a reload can resume it; finished items are skipped. Sealing a folder in place
// (Seal on its menu) is this job from the folder's contents into a new sealed
// folder of the same name beside it, with removeAfter: the emptied original,
// deleted once every item has switched.
import diskApi from './api'
import { bytesToBase64, pageTitle, stateToMarkdown } from './pages'
import { planParts, sha256Hex, withRetry } from './upload'

export const TO_SEALED = 'to_sealed'
export const TO_PLAIN = 'to_plain'
// Copying sealed items into a sealed folder (the same scope or another): file by file, page by page (6.8).
export const SEALED_COPY = 'sealed_copy'
export const ITEM = { TODO: 'todo', STAGED: 'staged', DONE: 'done', FAILED: 'failed' }

// ── the job store (its own database, so the uploads store's version is untouched) ──
const DB = 'inbox2-disk-jobs'
function db() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1)
    req.onupgradeneeded = () => req.result.createObjectStore('jobs', { keyPath: 'id' })
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}
async function tx(mode, fn) {
  try {
    const d = await db()
    return await new Promise((resolve, reject) => {
      const t = d.transaction('jobs', mode)
      const r = fn(t.objectStore('jobs'))
      t.oncomplete = () => resolve(r?.result)
      t.onerror = () => reject(t.error)
    })
  } catch {
    return undefined // private windows: the job runs, it just cannot resume after a reload
  }
}
export const jobStore = {
  put: (job) => tx('readwrite', (s) => s.put(job)),
  del: (id) => tx('readwrite', (s) => s.delete(id)),
  all: async () => (await tx('readonly', (s) => s.getAll())) || [],
}

/**
 * Plans a job: the sources (with their subtrees) flattened into folders to
 * recreate and files and pages to carry, children before their parent pages.
 * names(nodes) opens sealed names on the sealed side.
 */
export async function planJob({ orgId, op, direction, sources, targetId, scopeId, fromScopeId = null, names = (n) => n, removeAfter = null }) {
  const folders = []
  const items = []
  const walk = async (node, parentKey) => {
    if (node.kind === 'folder') {
      const key = `f${folders.length}`
      folders.push({ key, sourceId: node.id, name: node.name, parentKey })
      const kids = []
      let cursor
      do {
        const d = await diskApi.children(orgId, node.id, {}, cursor)
        kids.push(...names(d.nodes))
        cursor = d.next_cursor
      } while (cursor)
      for (const k of kids) await walk(k, key)
    } else {
      items.push({ sourceId: node.id, kind: node.kind, name: node.name, mime: node.mime ?? null, currentVersionId: node.current_version_id ?? null, parentKey, state: ITEM.TODO })
    }
  }
  for (const s of sources) await walk(s, null)
  const id = (crypto.randomUUID && crypto.randomUUID()) || `${Date.now()}`
  return { id, orgId, op, direction, targetId, scopeId, fromScopeId, folders, items, created: {}, done: false, removeAfter }
}

/** Uploads plaintext as an unsealed file (staged for a move). Returns { node, version }. */
async function uploadPlain(orgId, parentId, name, blob, staged) {
  const { upload } = await diskApi.startUpload(orgId, { parent_id: parentId, name, size_bytes: blob.size, idempotency_key: `${parentId}:${name}:${blob.size}:${staged}`, on_conflict: 'keep_both', ...(staged ? { staged: true } : {}) })
  const parts = planParts(blob.size, upload.part_bytes)
  for (let i = 0; i < parts.length; i += 100) {
    const batch = parts.slice(i, i + 100)
    const { parts: urls } = await diskApi.uploadParts(orgId, upload.id, batch.map((p) => p.number))
    for (const p of batch) {
      const url = urls.find((u) => u.number === p.number).url
      await withRetry(async () => {
        const res = await fetch(url, { method: 'PUT', body: blob.slice(p.start, p.end, '') })
        if (!res.ok) throw Object.assign(new Error(`The upload failed (${res.status})`), { status: res.status })
      })
    }
  }
  return diskApi.completeUpload(orgId, upload.id, await sha256Hex(blob))
}

/**
 * Runs (or resumes) a job one item at a time. sealed: lib/disk/sealed.js;
 * scope: the sealed side's opened scope. onProgress(job) after every step.
 */
export async function runJob(job, { sealed, scope, from = null, onProgress = () => {}, signal }) {
  const { orgId, direction, op } = job
  const move = op === 'move'
  const toSealed = direction === TO_SEALED || direction === SEALED_COPY
  const save = async () => { await jobStore.put(job); onProgress({ ...job }) }
  await save()

  // Folders first, parents before children.
  for (const f of job.folders) {
    if (job.created[f.key]) continue
    const parentId = f.parentKey ? job.created[f.parentKey] : job.targetId
    const { node } = toSealed
      ? await sealed.createSealedChild({ orgId, scope, parentId, name: f.name })
      : await diskApi.createFolder(orgId, parentId, f.name, true)
    job.created[f.key] = node.id
    await save()
  }

  // Sub-pages are switched before the page above them: deepest first.
  for (const it of job.items) {
    if (signal?.aborted) throw Object.assign(new Error('Stopped'), { aborted: true })
    if (it.state === ITEM.DONE || it.state === ITEM.FAILED) continue
    const parentId = it.parentKey ? job.created[it.parentKey] : job.targetId
    try {
      if (it.state === ITEM.TODO) {
        it.stagedId = direction === SEALED_COPY
          ? await copySealed(it, parentId, { orgId, sealed, from, to: scope })
          : await carry(it, parentId, { orgId, toSealed, sealed, scope, staged: move })
        it.state = move ? ITEM.STAGED : ITEM.DONE
        await save()
      }
      if (it.state === ITEM.STAGED) {
        await diskApi.node(orgId, it.stagedId) // verify: the staged node exists for its creator (size checked in carry)
        await sealed.sealedEndpoints.switch(orgId, it.sourceId, it.stagedId)
        it.state = ITEM.DONE
        await save()
      }
    } catch (e) {
      if (e.aborted) throw e
      it.state = ITEM.FAILED
      it.reason = e.message
      await save()
    }
  }

  // A move leaves the source folders empty: delete them, deepest first. The plan was
  // fixed when Seal was clicked; anything that arrived since (an upload still running,
  // another tab, a grantee, the importer, an agent) must survive. So each folder goes
  // to the Trash and is purged only if the server finds nothing beneath it; one that
  // is not empty stays in the Trash, listed in job.kept.
  if (move && job.items.every((i) => i.state === ITEM.DONE)) {
    job.kept = []
    const remove = async (id) => {
      await diskApi.trash(orgId, id)
      await diskApi.purge(orgId, id, { emptyOnly: true }).catch((e) => { if (e?.status === 409) job.kept.push(id); else throw e })
    }
    for (const f of [...job.folders].reverse()) await remove(f.sourceId).catch(() => {})
    if (job.removeAfter) await remove(job.removeAfter).catch(() => {})
  }
  job.done = true
  await save()
  await jobStore.del(job.id)
  return job
}

// One sealed file or page into a sealed folder (same or another scope). Returns the new node id.
// A file: the API copies the object, the client re-wraps K_v for the new ids. A page: a new sealed
// page whose first snapshot is the source's opened state, sealed under the target (POST /nodes, PUT /pages).
async function copySealed(it, parentId, { orgId, sealed, from, to }) {
  if (it.kind === 'page') {
    const { page } = await diskApi.page(orgId, it.sourceId)
    const { state } = await sealed.openSealedPage(from, it.sourceId, page)
    const { node } = await sealed.createSealedChild({ orgId, scope: to, parentId, name: it.name, kind: 'page' })
    const X = await import('./crypto')
    await sealed.sealedEndpoints.pageSnapshot(orgId, node.id, { sealed_snapshot: X.b64(X.sealPageSnapshot(to.key, node.id, to.epoch, 0, state)), epoch: to.epoch, seq: 0 })
    return node.id
  }
  const res = await sealed.copySealedFile({ orgId, source: from, target: to, node: { id: it.sourceId, name: it.name, mime: it.mime, current_version_id: it.currentVersionId }, targetId: parentId })
  return res.node?.id
}

// One file or page to the other side. Returns the new (staged) node id.
async function carry(it, parentId, { orgId, toSealed, sealed, scope, staged }) {
  if (it.kind === 'page') {
    const { page } = await diskApi.page(orgId, it.sourceId)
    if (toSealed) {
      // Markdown with no Yjs state (written by an agent or imported) would seal as an empty page and the
      // original would then be purged: fail the item instead, so it stays where it is.
      if (!page.ydoc && page.markdown) throw new Error('Open this page once, then try again.')
      const { node } = await sealed.createSealedChild({ orgId, scope, parentId, name: it.name, kind: 'page', staged })
      const Y = await import('yjs')
      const state = page.ydoc ? Uint8Array.from(atob(page.ydoc), (c) => c.charCodeAt(0)) : Y.encodeStateAsUpdate(new Y.Doc())
      const X = await import('./crypto')
      await sealed.sealedEndpoints.pageSnapshot(orgId, node.id, { sealed_snapshot: X.b64(X.sealPageSnapshot(scope.key, node.id, scope.epoch, 0, state)), epoch: scope.epoch, seq: 0 })
      return node.id
    }
    const { state } = await sealed.openSealedPage(scope, it.sourceId, page)
    const markdown = await stateToMarkdown(state)
    const { node } = await sealed.sealedEndpoints.createNode(orgId, { parent_id: parentId, kind: 'page', name: it.name || pageTitle(markdown), on_conflict: 'keep_both', ...(staged ? { staged: true } : {}) })
    await diskApi.savePage(orgId, node.id, { ydoc: bytesToBase64(state), markdown, base_revision: 0 })
    return node.id
  }
  if (toSealed) {
    const { download } = await diskApi.download(orgId, it.sourceId)
    const blob = await (await fetch(download.url)).blob()
    const file = new File([blob], it.name, { type: it.mime || blob.type })
    const res = await sealed.uploadSealed({ orgId, scope, parentId, file, mime: it.mime || blob.type, staged })
    // Verify: the manifest this upload wrote opens and says the right size.
    const { manifest } = sealed.openVersion(scope, res.node.id, res.version)
    if (manifest.size !== file.size) throw new Error('The sealed copy has the wrong size')
    return res.node.id
  }
  const node = { id: it.sourceId }
  const { node: full } = await diskApi.node(orgId, it.sourceId)
  node.current_version_id = full.current_version_id
  const version = await sealed.currentVersion(orgId, node)
  const bytes = await sealed.sealedBytes({ orgId, scope, nodeId: it.sourceId, version })
  const res = await uploadPlain(orgId, parentId, it.name, new Blob([bytes], { type: it.mime || '' }), staged)
  if (res.version?.size_bytes != null && res.version.size_bytes !== bytes.length) throw new Error('The copy has the wrong size')
  return res.node.id
}
