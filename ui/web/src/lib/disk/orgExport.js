// The org export (spec F11): everything in Disk as one zip built in the browser
// from GET /disk/admin/export pages, streamed one file at a time. Pages go in as
// markdown; sealed items cannot be read by anyone but their key holders, so they
// are listed as skipped, except a sealed page whose scope key this browser holds:
// it is opened here and added as markdown (spec F7). manifest.json carries
// members, shares, grants and links.
import diskApi from './api'
import { openZipTarget } from './download'

/** How one export entry goes into the zip: { action: 'folder' | 'file' | 'page' | 'sealedPage' | 'skip', path, reason } */
export function exportAction(entry) {
  if (entry.sealed && entry.kind === 'page' && entry.scope_id) return { action: 'sealedPage', path: `${entry.path}.md`, reason: 'sealed, and this browser does not hold its key' }
  if (entry.sealed || !entry.included) return { action: 'skip', path: entry.path, reason: 'sealed' }
  if (entry.kind === 'folder') return { action: 'folder', path: `${entry.path}/` }
  if (entry.kind === 'page') return { action: 'page', path: entry.path }
  if (!entry.url) return { action: 'skip', path: entry.path, reason: 'no content yet' }
  return { action: 'file', path: entry.path }
}

/**
 * Builds and saves the export. onProgress({ done, bytes }) after each item.
 * Returns { done, skipped: [{ path, reason }] }. Cancel with `signal`.
 */
export async function exportOrg(orgId, zipName, { onProgress = () => {}, signal } = {}) {
  const { ZipWriter, TextReader, configure } = await import('@zip.js/zip.js')
  configure({ useWebWorkers: false })
  const target = await openZipTarget(zipName)
  const zip = new ZipWriter(target.stream || target.writer, { level: 0, zip64: true })
  const skipped = []
  let done = 0
  let bytes = 0
  let cursor
  let first = true
  do {
    if (signal?.aborted) throw Object.assign(new Error('Cancelled'), { aborted: true })
    const { export: page } = await diskApi.exportPage(orgId, cursor)
    if (first && page.manifest) await zip.add('manifest.json', new TextReader(JSON.stringify(page.manifest, null, 2)))
    first = false
    for (const entry of page.entries) {
      if (signal?.aborted) throw Object.assign(new Error('Cancelled'), { aborted: true })
      const step = exportAction(entry)
      try {
        if (step.action === 'skip') skipped.push({ path: step.path, reason: step.reason })
        else if (step.action === 'folder') await zip.add(step.path, undefined, { directory: true })
        else if (step.action === 'page') await zip.add(step.path, new TextReader(entry.markdown || ''))
        else if (step.action === 'sealedPage') {
          const markdown = await sealedPageMarkdown(orgId, entry).catch(() => null)
          if (markdown == null) skipped.push({ path: step.path, reason: step.reason })
          else await zip.add(step.path, new TextReader(markdown))
        }
        else {
          const res = await fetch(entry.url, { signal })
          if (!res.ok) throw new Error(`HTTP ${res.status}`)
          await zip.add(step.path, res.body)
          bytes += entry.size_bytes || 0
        }
      } catch (e) {
        if (signal?.aborted) throw e
        skipped.push({ path: step.path, reason: `failed: ${e.message}` })
      }
      done++
      onProgress({ done, bytes })
    }
    cursor = page.next_cursor
  } while (cursor)
  if (skipped.length) {
    const list = skipped.map((s) => `${s.path}\t${s.reason}`).join('\n')
    await zip.add('SKIPPED.txt', new TextReader(`Items not in this export, and why:\n\n${list}\n`))
  }
  target.done(await zip.close())
  return { done, skipped }
}

// A sealed page opened with its scope key, when this browser already holds it (no prompt); else throws.
async function sealedPageMarkdown(orgId, entry) {
  const [{ default: sealedStore }, sealed, { stateToMarkdown }] = await Promise.all([
    import('../../stores/sealedStore'), import('./sealed'), import('./pages'),
  ])
  const scope = await sealedStore.getState().open(orgId, entry.scope_id)
  if (!scope) throw new Error('no key')
  const { page } = await diskApi.page(orgId, entry.id)
  return stateToMarkdown((await sealed.openSealedPage(scope, entry.id, page)).state)
}
