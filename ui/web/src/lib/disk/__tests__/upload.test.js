import { describe, it, expect, vi } from 'vitest'
import { planParts, missingParts, storedBytes, isRetryable, backoff, withRetry, pool, folderPaths } from '../upload'
import { rendererFor, previewPlan, RENDERERS } from '../preview/registry'
import { parseCsv, guessDelimiter } from '../preview/csv'
import { entryPaths, zipPlan, zipReport } from '../download'

const MiB = 1024 ** 2

describe('part planning', () => {
  it('splits into fixed parts with a short last one', () => {
    expect(planParts(20 * MiB, 8 * MiB)).toEqual([
      { number: 1, start: 0, end: 8 * MiB },
      { number: 2, start: 8 * MiB, end: 16 * MiB },
      { number: 3, start: 16 * MiB, end: 20 * MiB },
    ])
    expect(planParts(8 * MiB, 8 * MiB)).toHaveLength(1)
    expect(planParts(0, 8 * MiB)).toEqual([])
  })

  it('handles a 1 GB+ file without overflow or gaps', () => {
    const size = 1.5 * 1024 ** 3 + 7
    const plan = planParts(size, 16 * MiB)
    expect(plan.at(-1).end).toBe(size)
    expect(plan.reduce((s, p) => s + (p.end - p.start), 0)).toBe(size)
  })
})

describe('resume reconciliation', () => {
  const plan = planParts(20 * MiB, 8 * MiB)
  it('skips parts storage holds at their full size', () => {
    const stored = [{ number: 1, size_bytes: 8 * MiB }, { number: 3, size_bytes: 4 * MiB }]
    expect(missingParts(plan, stored).map((p) => p.number)).toEqual([2])
    expect(storedBytes(plan, stored)).toBe(12 * MiB)
  })
  it('sends a part again when storage holds the wrong size', () => {
    expect(missingParts(plan, [{ number: 2, size_bytes: 3 }]).map((p) => p.number)).toEqual([1, 2, 3])
  })
  it('sends everything when nothing is stored', () => {
    expect(missingParts(plan, [])).toHaveLength(3)
    expect(storedBytes(plan)).toBe(0)
  })
})

describe('retry', () => {
  it('retries network, throttling, server errors and expired URLs only', () => {
    expect(isRetryable({ status: 0 })).toBe(true)
    expect(isRetryable({ status: 503 })).toBe(true)
    expect(isRetryable({ status: 429 })).toBe(true)
    expect(isRetryable({ status: 403, expired: true })).toBe(true)
    expect(isRetryable({ status: 403 })).toBe(false)
    expect(isRetryable({ status: 409 })).toBe(false)
    expect(isRetryable({ status: 422 })).toBe(false)
    expect(isRetryable({ aborted: true, status: 0 })).toBe(false)
  })

  it('backs off exponentially, with jitter and a cap', () => {
    expect(backoff(0, 500, 15_000, () => 1)).toBe(500)
    expect(backoff(3, 500, 15_000, () => 1)).toBe(4000)
    expect(backoff(3, 500, 15_000, () => 0)).toBe(2000)
    expect(backoff(10, 500, 15_000, () => 1)).toBe(15_000)
  })

  it('gives up after `tries`, and at once on a refusal', async () => {
    const sleep = vi.fn(async () => {})
    const flaky = vi.fn().mockRejectedValueOnce({ status: 0 }).mockRejectedValueOnce({ status: 502 }).mockResolvedValue('ok')
    await expect(withRetry(flaky, { sleep })).resolves.toBe('ok')
    expect(flaky).toHaveBeenCalledTimes(3)
    expect(sleep).toHaveBeenCalledTimes(2)

    const down = vi.fn().mockRejectedValue({ status: 500 })
    await expect(withRetry(down, { tries: 3, sleep })).rejects.toEqual({ status: 500 })
    expect(down).toHaveBeenCalledTimes(3)

    const refused = vi.fn().mockRejectedValue({ status: 422 })
    await expect(withRetry(refused, { sleep })).rejects.toEqual({ status: 422 })
    expect(refused).toHaveBeenCalledTimes(1)
  })

  it('stops retrying once cancelled', async () => {
    const ctl = new AbortController()
    const fn = vi.fn(async () => { ctl.abort(); throw { status: 0 } })
    await expect(withRetry(fn, { signal: ctl.signal, sleep: async () => {} })).rejects.toEqual({ status: 0 })
    expect(fn).toHaveBeenCalledTimes(1)
  })
})

describe('pool', () => {
  it('keeps at most `limit` workers in flight and runs every item', async () => {
    let live = 0
    let peak = 0
    const done = []
    await pool([1, 2, 3, 4, 5, 6, 7], 3, async (n) => {
      live++
      peak = Math.max(peak, live)
      await new Promise((r) => setTimeout(r, 1))
      done.push(n)
      live--
    })
    expect(peak).toBe(3)
    expect(done.sort()).toEqual([1, 2, 3, 4, 5, 6, 7])
  })
})

describe('folder uploads', () => {
  it('lists the folders a drop needs, parents first', () => {
    expect(folderPaths([
      { relativePath: 'Q4/Budget/b.xlsx' }, { relativePath: 'Q4/plan.docx' }, { relativePath: 'a.pdf' },
    ])).toEqual(['Q4', 'Q4/Budget'])
  })
})

describe('preview registry', () => {
  const f = (name, x = {}) => ({ kind: 'file', name, sealed: false, size_bytes: 1000, current_version_id: 'dvr_1', ...x })
  it('resolves renderers by type', () => {
    expect(rendererFor(f('a.PDF'))).toBe('pdf')
    expect(rendererFor(f('a.png'))).toBe('image')
    expect(rendererFor(f('a.svg'))).toBe('image')
    expect(rendererFor(f('a.psd'))).toBe('psd')
    expect(rendererFor(f('a.mov'))).toBe('video')
    expect(rendererFor(f('a.flac'))).toBe('audio')
    expect(rendererFor(f('README.md'))).toBe('markdown')
    expect(rendererFor(f('app.rb'))).toBe('code')
    expect(rendererFor(f('server.log'))).toBe('code')
    expect(rendererFor(f('data.csv'))).toBe('csv')
    expect(rendererFor(f('book.xlsx'))).toBe('sheet')
    expect(rendererFor(f('plan.docx'))).toBe('docx')
    expect(rendererFor(f('deck.pptx'))).toBe('pptx')
    expect(rendererFor(f('assets.zip'))).toBe('zip')
    expect(rendererFor(f('shot.CR3'))).toBe('raw')
  })
  it('has no renderer where the plan has none yet', () => {
    for (const name of ['old.doc', 'a.odt', 'a.rtf', 'deck.key', 'a.ppt', 'x.fig', 'a.rar', 'a.eps', 'disk.iso']) {
      expect(rendererFor(f(name))).toBeNull()
    }
  })
  it('leaves HEIC and TIFF to browsers that decode them', () => {
    expect(rendererFor(f('p.heic'))).toBeNull()
    expect(rendererFor(f('p.heic'), { safari: true })).toBe('image')
  })
  it('never previews sealed files, folders or pages', () => {
    expect(previewPlan(f('a.pdf', { sealed: true }))).toEqual({ reason: 'sealed' })
    expect(rendererFor({ kind: 'folder', name: 'x' })).toBeNull()
    expect(rendererFor({ kind: 'page', name: 'x' })).toBeNull()
  })
  it('applies each renderer’s size limit; streamed media has none', () => {
    expect(previewPlan(f('a.pdf', { size_bytes: RENDERERS.pdf.maxBytes + 1 }))).toEqual({ reason: 'too-large', limit: RENDERERS.pdf.maxBytes })
    expect(previewPlan(f('a.pdf'))).toEqual({ renderer: 'pdf' })
    expect(previewPlan(f('big.mp4', { size_bytes: 50 * 1024 ** 3 }))).toEqual({ renderer: 'video' })
    expect(previewPlan(f('x.fig'))).toEqual({ reason: 'none' })
    expect(previewPlan(f('a.pdf', { current_version_id: null }))).toEqual({ reason: 'empty' })
  })
})

describe('csv', () => {
  it('parses quotes, doubled quotes, embedded newlines and CRLF', () => {
    const { rows } = parseCsv('a,b,c\r\n1,"x, y","he said ""hi"""\n2,"two\nlines",z\n')
    expect(rows).toEqual([['a', 'b', 'c'], ['1', 'x, y', 'he said "hi"'], ['2', 'two\nlines', 'z']])
  })
  it('guesses tabs and semicolons, and stops at maxRows', () => {
    expect(guessDelimiter('a\tb\tc\n1\t2\t3')).toBe('\t')
    expect(guessDelimiter('a;b;c\n')).toBe(';')
    const { rows, truncated } = parseCsv('a\n1\n2\n3\n', { maxRows: 2 })
    expect(rows).toEqual([['a'], ['1']])
    expect(truncated).toBe(true)
  })
})

describe('zip paths', () => {
  it('nests the tree under the folder and skips sealed items', () => {
    const root = { id: 'r', name: 'Q4', kind: 'folder' }
    const nodes = [
      { id: 'b', name: 'Budget', kind: 'folder', parent_id: 'r' },
      { id: 'x', name: 'b.xlsx', kind: 'file', parent_id: 'b' },
      { id: 'p', name: 'plan.docx', kind: 'file', parent_id: 'r' },
      { id: 's', name: null, kind: 'file', parent_id: 'r', sealed: true },
    ]
    expect(entryPaths(root, nodes).map((e) => e.path)).toEqual(['Q4/Budget/', 'Q4/Budget/b.xlsx', 'Q4/plan.docx', null])
  })
})

describe('zip plan and report', () => {
  const e = (node, path) => ({ node, path })
  it('exports pages as .md, counts sealed and empty files as left out', () => {
    const plan = zipPlan([
      e({ id: 'f', kind: 'folder', name: 'Q4' }, 'Q4/'),
      e({ id: 'a', kind: 'file', name: 'a.pdf', current_version_id: 'dvr_1' }, 'Q4/a.pdf'),
      e({ id: 'p', kind: 'page', name: 'Plan' }, 'Q4/Plan'),
      e({ id: 's', kind: 'file', name: null, sealed: true }, null),
      e({ id: 'u', kind: 'file', name: 'half.mov', current_version_id: null }, 'Q4/half.mov'),
    ])
    expect(plan.folders.map((x) => x.path)).toEqual(['Q4/'])
    expect(plan.files.map((x) => x.path)).toEqual(['Q4/a.pdf'])
    expect(plan.pages.map((x) => x.path)).toEqual(['Q4/Plan.md'])
    expect(plan.omitted).toEqual([{ name: 'Sealed item', reason: 'sealed' }, { name: 'half.mov', reason: 'not uploaded yet' }])
  })
  it('says what was left out', () => {
    expect(zipReport({ zipped: 2, omitted: [] })).toBe('Zip saved with 2 items.')
    expect(zipReport({ zipped: 1, omitted: [{ name: 'x', reason: 'sealed' }, { name: 'y', reason: 'failed' }] }))
      .toBe('Zip saved with 1 item. Left out: 1 sealed, 1 failed (x, y).')
  })
})

describe('org export plan', async () => {
  const { exportAction } = await import('../orgExport')
  it('maps entries to zip actions', () => {
    expect(exportAction({ kind: 'folder', path: 'D/Marketing/Brand', included: true })).toEqual({ action: 'folder', path: 'D/Marketing/Brand/' })
    expect(exportAction({ kind: 'page', path: 'C/sara/Plan.md', included: true })).toEqual({ action: 'page', path: 'C/sara/Plan.md' })
    // A sealed page is opened in the browser when it holds the scope key; a sealed file never is.
    expect(exportAction({ kind: 'page', sealed: true, included: false, scope_id: 'dnd_s', path: 'D/Vault/dnd_p (sealed)' })).toMatchObject({ action: 'sealedPage', path: 'D/Vault/dnd_p (sealed).md' })
    expect(exportAction({ kind: 'file', sealed: true, included: false, scope_id: 'dnd_s', path: 'D/Vault/dnd_f (sealed)' })).toMatchObject({ action: 'skip' })
    expect(exportAction({ kind: 'file', path: 'D/x/a.pdf', included: true, url: 'https://s/a' })).toEqual({ action: 'file', path: 'D/x/a.pdf' })
    expect(exportAction({ kind: 'file', path: 'D/x/b', included: true, url: null })).toEqual({ action: 'skip', path: 'D/x/b', reason: 'no content yet' })
    expect(exportAction({ kind: 'file', path: 'D/x/dnd_1 (sealed)', sealed: true, included: false })).toEqual({ action: 'skip', path: 'D/x/dnd_1 (sealed)', reason: 'sealed' })
  })
})
