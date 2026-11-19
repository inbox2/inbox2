// Downloads (spec F2): one file through its presigned URL; several items or a
// folder as a zip built in the browser from GET /nodes/:id/tree and each file's
// own presigned URL, streamed into the zip one file at a time.
import diskApi from './api'

/** Starts a browser download of a URL the API signed (it answers as an attachment). */
export function saveUrl(url, filename = '') {
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.rel = 'noopener'
  document.body.append(a)
  a.click()
  a.remove()
}

export async function downloadFile(orgId, node) {
  const { download } = await diskApi.download(orgId, node.id)
  saveUrl(download.url, node.name || '')
}

export async function downloadVersion(orgId, version, name) {
  const { download } = await diskApi.versionDownload(orgId, version.id)
  saveUrl(download.url, name || '')
}

/**
 * Zip paths for a folder and the flat tree under it: [{ node, path }], folders
 * included (their path ends in "/"). Sealed items keep a null path (left out until sealing ships).
 */
export function entryPaths(root, nodes) {
  const byId = new Map(nodes.map((n) => [n.id, n]))
  const cache = new Map([[root.id, root.name]])
  const pathOf = (n) => {
    if (cache.has(n.id)) return cache.get(n.id)
    const parent = byId.get(n.parent_id) || (n.parent_id === root.id ? root : null)
    const p = parent ? `${pathOf(parent)}/${n.name}` : n.name
    cache.set(n.id, p)
    return p
  }
  // Sealed items stay in the list with no path, so zipPlan can count them as left out.
  return nodes.map((n) => ({
    node: n,
    path: (n.sealed && !n.opened) || !n.name ? null : n.kind === 'folder' ? `${pathOf(n)}/` : pathOf(n),
  }))
}

async function treeOf(orgId, folder, names = (x) => x) {
  const nodes = []
  let cursor
  do {
    const d = await diskApi.tree(orgId, folder.id, cursor)
    nodes.push(...names(d.nodes))
    cursor = d.next_cursor
  } while (cursor)
  return [{ node: folder, path: `${folder.name}/` }, ...entryPaths(folder, nodes)]
}

/** Writes to a file the person picks when the browser can (no size ceiling), else to a Blob in memory. */
export async function openZipTarget(name) {
  if (window.showSaveFilePicker) {
    const handle = await window.showSaveFilePicker({ suggestedName: name, types: [{ description: 'Zip', accept: { 'application/zip': ['.zip'] } }] })
    return { stream: await handle.createWritable(), done: () => {} }
  }
  // ponytail: the Blob fallback holds the whole zip in memory (Safari, Firefox); a service-worker stream lifts that.
  const { BlobWriter } = await import('@zip.js/zip.js')
  const writer = new BlobWriter('application/zip')
  return { writer, done: (blob) => saveUrl(URL.createObjectURL(blob), name) }
}

/**
 * Splits the entries for a zip: folders, files with content, pages (exported as
 * .md), and what is left out with why. Sealed items are left out until sealing ships.
 */
export function zipPlan(entries) {
  const plan = { folders: [], files: [], pages: [], omitted: [] }
  for (const e of entries) {
    const n = e.node
    if ((n.sealed && !n.opened) || !n.name) plan.omitted.push({ name: n.name || 'Sealed item', reason: 'sealed' })
    else if (n.kind === 'folder') plan.folders.push(e)
    else if (n.kind === 'page') plan.pages.push({ ...e, path: `${e.path}.md` })
    else if (!n.current_version_id) plan.omitted.push({ name: n.name, reason: 'not uploaded yet' })
    else plan.files.push(e)
  }
  return plan
}

/** One line for the UI: what was zipped and what was not. */
export function zipReport({ zipped, omitted }) {
  if (!omitted.length) return `Zip saved with ${zipped} ${zipped === 1 ? 'item' : 'items'}.`
  const why = {}
  omitted.forEach((o) => { why[o.reason] = (why[o.reason] || 0) + 1 })
  const parts = Object.entries(why).map(([reason, n]) => `${n} ${reason}`)
  return `Zip saved with ${zipped} ${zipped === 1 ? 'item' : 'items'}. Left out: ${parts.join(', ')} (${omitted.slice(0, 3).map((o) => o.name).join(', ')}${omitted.length > 3 ? ', ...' : ''}).`
}

/**
 * Zips the selected nodes (folders walked through their tree; pages as .md
 * from their saved markdown). A file that fails is left out and reported, not
 * fatal. onProgress gets { done, total }. Returns { zipped, omitted: [{ name, reason }] }.
 */
export async function downloadZip(orgId, selection, zipName, onProgress = () => {}, sealed = null) {
  // sealed (inside an open scope): { names(nodes), file(node) -> bytes, page(node) -> markdown }; opened
  // in this browser, so sealed files and pages are zipped only where the key is held (spec F7).
  const lists = await Promise.all(selection.map((n) => (n.kind === 'folder' && (!n.sealed || sealed) ? treeOf(orgId, n, sealed?.names) : [{ node: n, path: n.name }])))
  const plan = zipPlan(lists.flat())
  const omitted = [...plan.omitted]
  const total = plan.files.length + plan.pages.length
  const totalBytes = plan.files.reduce((s, e) => s + (e.node.size_bytes || 0), 0)

  const { ZipWriter, TextReader, configure } = await import('@zip.js/zip.js')
  configure({ useWebWorkers: false })
  const target = await openZipTarget(zipName)
  const zip = new ZipWriter(target.stream || target.writer, { level: 0, zip64: totalBytes > 0xf0000000 })
  let done = 0
  for (const e of plan.folders) await zip.add(e.path, undefined, { directory: true })
  for (const e of plan.pages) {
    try {
      const markdown = e.node.sealed ? await sealed.page(e.node) : (await diskApi.page(orgId, e.node.id)).page.markdown
      await zip.add(e.path, new TextReader(markdown || ''))
    } catch (err) {
      omitted.push({ name: e.node.name, reason: 'failed', detail: err.message })
    }
    onProgress({ done: ++done, total })
  }
  for (const e of plan.files) {
    try {
      if (e.node.sealed) {
        const { Uint8ArrayReader } = await import('@zip.js/zip.js')
        await zip.add(e.path, new Uint8ArrayReader(await sealed.file(e.node)))
      } else {
        const { download } = await diskApi.download(orgId, e.node.id)
        const res = await fetch(download.url)
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        await zip.add(e.path, res.body)
      }
    } catch (err) {
      omitted.push({ name: e.node.name, reason: 'failed', detail: err.message })
    }
    onProgress({ done: ++done, total })
  }
  const blob = await zip.close()
  target.done(blob)
  return { zipped: done - omitted.filter((o) => o.reason === 'failed').length, omitted }
}
