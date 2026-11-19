import { describe, it, expect, vi, beforeEach } from 'vitest'

// The API, deferred by hand so each test chooses when the server answers.
const calls = {}
const deferred = () => { let resolve, reject; const p = new Promise((a, b) => { resolve = a; reject = b }); return { p, resolve, reject } }
vi.mock('../api', () => {
  const api = {
    startUpload: vi.fn(() => { calls.start = deferred(); return calls.start.p }),
    upload: vi.fn(async () => ({ upload: { id: 'dup_1', state: 'reserved', part_bytes: 8 << 20 }, parts: [] })),
    uploadParts: vi.fn(),
    completeUpload: vi.fn(() => { calls.complete = deferred(); return calls.complete.p }),
    cancelUpload: vi.fn(async () => ({})),
    drives: vi.fn(async () => ({ shares: [] })),
    children: vi.fn(async () => ({ nodes: [], next_cursor: null })),
    createFolder: vi.fn(),
  }
  return { default: api, KEEP_BOTH: 'keep_both', REPLACE: 'replace', QUOTA_FULL: 'disk_quota_exceeded' }
})

const { enqueue, pause, resume, cancel, activeAttempt } = await import('../upload')
const { default: useUploadStore } = await import('../../../stores/uploadStore')
const tick = () => new Promise((r) => setTimeout(r, 5))
const until = async (ok) => { for (let i = 0; i < 400 && !ok(); i++) await tick() } // libsodium loads on the first hash
const only = () => useUploadStore.getState().items.at(-1)

describe('upload races', () => {
  beforeEach(() => useUploadStore.setState({ items: [], conflictAll: null }))

  it('pause then resume keeps the new attempt when the old one unwinds', async () => {
    await enqueue('org_1', 'dnd_parent', [{ file: new File([], 'a.txt'), relativePath: 'a.txt' }])
    const id = only().id
    await tick()
    const first = activeAttempt(id)
    const firstStart = calls.start
    pause(id)
    resume(id)
    await tick()
    const second = activeAttempt(id)
    expect(second).not.toBe(first)
    firstStart.resolve({ upload: { id: 'dup_1' } }) // the old attempt learns its fate and unwinds
    await tick()
    expect(activeAttempt(id)).toBe(second)
    expect(only().state).toBe('running')
    calls.complete = null
    calls.start.resolve({ upload: { id: 'dup_1' } })
    await until(() => calls.complete)
    calls.complete.resolve({ node: { id: 'dnd_new', name: 'a.txt' }, version: null })
    await tick()
    expect(only().state).toBe('done')
    expect(activeAttempt(id)).toBe(null)
  })

  it('cancel while completing: the server committed, so it shows as uploaded and says so', async () => {
    await enqueue('org_1', 'dnd_parent', [{ file: new File([], 'b.txt'), relativePath: 'b.txt' }])
    const id = only().id
    await tick()
    calls.complete = null
    calls.start.resolve({ upload: { id: 'dup_2' } })
    await until(() => calls.complete)
    expect(calls.complete).toBeTruthy()
    const pending = calls.complete
    await cancel(id)
    expect(only().state).toBe('cancelled')
    pending.resolve({ node: { id: 'dnd_b', name: 'b.txt' }, version: null })
    await tick()
    expect(only().state).toBe('done')
    expect(only().note).toMatch(/Too late/)
  })

  it('cancel before completing never calls complete', async () => {
    calls.complete = null
    await enqueue('org_1', 'dnd_parent', [{ file: new File([], 'c.txt'), relativePath: 'c.txt' }])
    const id = only().id
    await tick()
    const started = calls.start
    await cancel(id)
    started.resolve({ upload: { id: 'dup_3' } })
    await new Promise((r) => setTimeout(r, 300))
    expect(calls.complete).toBe(null)
    expect(only().state).toBe('cancelled')
  })
})

describe('resume checks the re-picked file', async () => {
  const { partsStillMatch, rangeDigest } = await import('../upload')
  const bytes = (seed) => new Uint8Array(3000).map((_, i) => (i * 7 + seed) & 0xff)
  const ranges = { 1: [0, 1024], 2: [1024, 2048], 3: [2048, 3000] }
  const rangeOf = (n) => ranges[n]
  it('the same file resumes; changed bytes with the same name, size and time restart', async () => {
    const original = new File([bytes(1)], 'a.bin', { lastModified: 5 })
    const digests = { 1: await rangeDigest(original, 0, 1024), 2: await rangeDigest(original, 1024, 2048) }
    const stored = [{ number: 1 }, { number: 2 }]
    expect(await partsStillMatch(new File([bytes(1)], 'a.bin', { lastModified: 5 }), stored, digests, rangeOf)).toBe(true)
    const edited = bytes(1)
    edited[1500] ^= 1 // inside part 2
    expect(await partsStillMatch(new File([edited], 'a.bin', { lastModified: 5 }), stored, digests, rangeOf)).toBe(false)
    // A stored part with no recorded digest cannot be trusted.
    expect(await partsStillMatch(original, [{ number: 3 }], digests, rangeOf)).toBe(false)
  })
})
