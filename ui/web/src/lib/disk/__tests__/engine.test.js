import { describe, it, expect, vi } from 'vitest'
import {
  missingParts, cachedBytes, downloadBytes, installedBytes, staleEngineCaches, otherAccountCaches,
  lruEvict, engineSupport, needsStorageWarning, SerialQueue, partKey, fileKey, cacheNameFor,
} from '../engine/logic'

const manifest = {
  version: 'v2',
  files: [
    { name: 'soffice.wasm', bytes: 1000, sha256: 'a', parts: [{ path: 'w.000', bytes: 300, sha256: '1' }, { path: 'w.001', bytes: 200, sha256: '2' }] },
    { name: 'soffice.js', bytes: 50, sha256: 'b', parts: [{ path: 'j.000', bytes: 20, sha256: '3' }] },
  ],
}

describe('engine download plan', () => {
  it('sizes the download and the install', () => {
    expect(downloadBytes(manifest)).toBe(520)
    expect(installedBytes(manifest)).toBe(1050)
  })

  it('resumes: skips cached parts and whole assembled files', () => {
    const have = new Set([partKey('w.000')])
    expect(missingParts(manifest, have).map((p) => p.path)).toEqual(['w.001', 'j.000'])
    expect(cachedBytes(manifest, have)).toBe(300)
    const assembled = new Set([fileKey('soffice.wasm')])
    expect(missingParts(manifest, assembled).map((p) => p.path)).toEqual(['j.000'])
    expect(cachedBytes(manifest, assembled)).toBe(500)
  })
})

describe('versions and accounts', () => {
  it('evicts every engine version but the verified one, and nothing else', () => {
    const names = ['disk-engine-v1', 'disk-engine-v2', 'disk-conv-u1', 'other']
    expect(staleEngineCaches(names, 'v2')).toEqual(['disk-engine-v1'])
    expect(staleEngineCaches(names, 'v3')).toEqual(['disk-engine-v1', 'disk-engine-v2'])
    expect(cacheNameFor('v2')).toBe('disk-engine-v2')
  })

  it('finds conversion caches of other accounts', () => {
    expect(otherAccountCaches(['disk-conv-u1', 'disk-conv-u2', 'disk-engine-v1'], 'u1')).toEqual(['disk-conv-u2'])
  })
})

describe('conversion cache LRU', () => {
  const index = { a: { bytes: 40, at: 3 }, b: { bytes: 40, at: 1 }, c: { bytes: 40, at: 2 } }
  it('drops least recently used first until it fits', () => {
    expect(lruEvict(index, 100)).toEqual(['b'])
    expect(lruEvict(index, 100, 50)).toEqual(['b', 'c'])
    expect(lruEvict(index, 1000)).toEqual([])
  })
})

describe('when to offer', () => {
  const base = { isolated: true, hasCaches: true, phone: false, saveData: false, effectiveType: '4g' }
  it('withholds on unsupported browsers, phones and metered links', () => {
    expect(engineSupport(base)).toEqual({ ok: true })
    expect(engineSupport({ ...base, isolated: false }).reason).toBe('unsupported')
    expect(engineSupport({ ...base, phone: true }).reason).toBe('phone')
    expect(engineSupport({ ...base, saveData: true }).reason).toBe('metered')
    expect(engineSupport({ ...base, effectiveType: 'slow-2g' }).reason).toBe('metered')
    expect(engineSupport({ ...base, effectiveType: '3g' }).reason).toBe('metered')
  })
  it('asks first when storage is short', () => {
    expect(needsStorageWarning({ quota: 1000, usage: 900 }, 100)).toBe(true)
    expect(needsStorageWarning({ quota: 10_000, usage: 0 }, 100)).toBe(false)
    expect(needsStorageWarning(null, 100)).toBe(false)
  })
})

describe('SerialQueue', () => {
  it('runs one job at a time, in order', async () => {
    const q = new SerialQueue()
    const log = []
    let live = 0
    const job = (n) => async () => {
      live++
      expect(live).toBe(1)
      await new Promise((r) => setTimeout(r, 1))
      log.push(n)
      live--
      return n
    }
    const r = await Promise.all([q.add(job(1)).promise, q.add(job(2)).promise, q.add(job(3)).promise])
    expect(r).toEqual([1, 2, 3])
    expect(log).toEqual([1, 2, 3])
    expect(q.size).toBe(0)
  })

  it('cancels a waiting job and signals a running one', async () => {
    const q = new SerialQueue()
    const seen = vi.fn()
    const running = q.add((signal) => new Promise((resolve) => {
      signal.addEventListener('abort', () => { seen(); resolve('stopped') })
    }))
    const waiting = q.add(async () => 'never')
    waiting.cancel()
    await expect(waiting.promise).rejects.toMatchObject({ aborted: true })
    running.cancel()
    await expect(running.promise).resolves.toBe('stopped')
    expect(seen).toHaveBeenCalled()
  })

  it('keeps going after a failure', async () => {
    const q = new SerialQueue()
    const bad = q.add(async () => { throw new Error('nope') })
    const good = q.add(async () => 'ok')
    await expect(bad.promise).rejects.toThrow('nope')
    await expect(good.promise).resolves.toBe('ok')
  })
})

