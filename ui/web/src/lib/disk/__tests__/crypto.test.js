// Sealed format: refusals (6.3, 6.6), range and part maths, streaming sealing.
import { beforeAll, describe, expect, it } from 'vitest'
import * as X from '../crypto'

const NODE = 'dnd_aaaaaaaaaaaaaaaaaaaaa'
const VER = 'dvr_bbbbbbbbbbbbbbbbbbbbb'
const VER2 = 'dvr_ccccccccccccccccccccc'
const bytes = (n, seed = 1) => new Uint8Array(n).map((_, i) => (i * 31 + seed) & 0xff)
let Ks, Kv, prefix, C

beforeAll(async () => {
  await X.init()
  Ks = X.newKey()
  Kv = X.newKey()
  prefix = X.newKey().subarray(0, 16)
  C = X.versionKeys(Kv).C
})

function sealAll(plain, cb) {
  const n = X.chunkCount(plain.length, cb)
  const chunks = Array.from({ length: n }, (_, i) => X.sealChunk(C, prefix, i, i === n - 1, plain.subarray(i * cb, (i + 1) * cb)))
  const tags = X.concat(...chunks.map((c) => c.subarray(c.length - 16)))
  return { chunks, object: X.concat(...chunks), manifest: X.buildManifest({ nodeId: NODE, versionId: VER, size: plain.length, chunkBytes: cb, prefix, tags }) }
}
const opened = (m) => ({ ...m, prefixBytes: X.unb64(m.prefix) })

describe('envelope refusals', () => {
  const ad = () => X.AD(X.LABEL.META, NODE)
  it('wrong key', () => expect(() => X.openENV(X.newKey(), ad(), X.ENV(Ks, ad(), bytes(5)))).toThrow(X.SealError))
  it('altered AD field', () => expect(() => X.openENV(Ks, X.AD(X.LABEL.META, 'dnd_xxxxxxxxxxxxxxxxxxxxx'), X.ENV(Ks, ad(), bytes(5)))).toThrow('authentication'))
  it('wrong first byte', () => {
    const e = X.ENV(Ks, ad(), bytes(5))
    e[0] = 2
    expect(() => X.openENV(Ks, ad(), e)).toThrow('version')
  })
  it('short envelope', () => expect(() => X.openENV(Ks, ad(), new Uint8Array(40).fill(1))).toThrow('short'))
  it('stale epoch: metadata sealed under epoch 1 does not open with epoch 2', () => {
    const Ks2 = X.newKey()
    expect(() => X.openMeta(Ks2, NODE, X.sealMeta(Ks, NODE, { name: 'a' }))).toThrow(X.SealError)
  })
  it('walks the epoch chain back and not forward', () => {
    const k = [null, X.newKey(), X.newKey(), X.newKey()]
    const chain = { 2: X.wrapPreviousKey(k[2], NODE, 2, k[1]), 3: X.wrapPreviousKey(k[3], NODE, 3, k[2]) }
    expect(X.walkBack(k[3], 3, 1, NODE, (e) => chain[e])).toEqual(k[1])
    expect(() => X.walkBack(k[2], 2, 3, NODE, (e) => chain[e])).toThrow('not reachable')
    expect(() => X.walkBack(k[3], 3, 1, 'dnd_other0000000000000000', (e) => chain[e])).toThrow(X.SealError)
  })
})

describe('chunks and manifest', () => {
  const cb = 64
  const plain = bytes(200)
  it('swapped chunk index', () => {
    const { chunks } = sealAll(plain, cb)
    expect(() => X.openChunk(C, prefix, 1, false, chunks[0])).toThrow('chunk 1')
  })
  it('missing last flag: the final chunk only opens with last = 1', () => {
    const { chunks } = sealAll(plain, cb)
    expect(() => X.openChunk(C, prefix, 3, false, chunks[3])).toThrow(X.SealError)
    expect(X.openChunk(C, prefix, 3, true, chunks[3])).toEqual(plain.subarray(192))
  })
  it('truncated stream: dropping the last chunk fails', () => {
    const { object, manifest } = sealAll(plain, cb)
    expect(() => X.openWhole(C, opened(manifest), object.subarray(0, 3 * (cb + 16)))).toThrow('wrong length')
    // Same length as a 3-chunk file claims, but chunk 2 was sealed with last = 0.
    const fake = { ...opened(manifest), size: 192, chunks: 3 }
    expect(() => X.openWhole(C, fake, object.subarray(0, 3 * (cb + 16)))).toThrow('chunk 2')
  })
  it('opens the whole object and checks tags', () => {
    const { object, manifest } = sealAll(plain, cb)
    expect(X.openWhole(C, opened(manifest), object)).toEqual(plain)
    expect(() => X.openWhole(C, { ...opened(manifest), tags: X.b64(new Uint8Array(32)) }, object)).toThrow('tags')
  })
  it('another version\'s manifest is refused', () => {
    const { manifest } = sealAll(plain, cb)
    const sealed = X.sealManifest(Kv, manifest)
    expect(() => X.openManifest(Kv, NODE, VER2, sealed)).toThrow(X.SealError)
    // Sealed for VER2 under the right AD but naming VER inside: refused by the id check.
    const lying = X.ENV(X.versionKeys(Kv).F, X.AD(X.LABEL.MANIFEST, NODE, VER2), X.utf8(X.canonicalJson(manifest)))
    expect(() => X.openManifest(Kv, NODE, VER2, lying)).toThrow('another version')
    expect(X.openManifest(Kv, NODE, VER, sealed).size).toBe(200)
  })
  it.each([['size', 300], ['chunk_bytes', 32], ['chunks', 5]])('altered %s is refused', (field, value) => {
    const { manifest } = sealAll(plain, cb)
    const bad = X.sealManifest(Kv, { ...manifest, [field]: value })
    expect(() => X.openManifest(Kv, NODE, VER, bad)).toThrow('chunk count')
  })
  it('altered size that keeps the count fails on the range length', () => {
    const { object, manifest } = sealAll(plain, cb)
    const m = X.openManifest(Kv, NODE, VER, X.sealManifest(Kv, { ...manifest, size: 199 }))
    expect(() => X.openWhole(C, m, object)).toThrow('wrong length')
  })
  it('empty file is one empty chunk', () => {
    const { object, manifest } = sealAll(new Uint8Array(0), cb)
    expect(object.length).toBe(16)
    expect(manifest.chunks).toBe(1)
    expect(X.openWhole(C, opened(manifest), object)).toEqual(new Uint8Array(0))
  })
})

describe('range maths', () => {
  it('maps plaintext ranges to chunks and opens them', () => {
    const cb = 64
    const plain = bytes(200)
    const { object } = sealAll(plain, cb)
    for (const [a, b] of [[0, 0], [0, 199], [63, 64], [100, 150], [192, 199], [199, 199], [64, 127]]) {
      const plan = X.chunksForRange(a, b, 200, cb)
      const got = X.openRange(C, prefix, 200, cb, a, b, object.subarray(plan.cipherStart, plan.cipherEnd + 1))
      expect(got).toEqual(plain.subarray(a, b + 1))
    }
  })
  it('refuses a range response of the wrong length', () => {
    const { object } = sealAll(bytes(200), 64)
    const plan = X.chunksForRange(10, 20, 200, 64)
    expect(() => X.openRange(C, prefix, 200, 64, 10, 20, object.subarray(plan.cipherStart, plan.cipherEnd))).toThrow('wrong length')
  })
})

describe('upload parts', () => {
  it.each([
    [200, 64, 100], [200, 64, 80], [200, 64, 1000], [0, 64, 100], [4096, 1024, 1040], [5000, 1024, 777],
  ])('size %i chunk %i part %i: sealed parts concatenate to the stored object', async (size, cb, pb) => {
    const plain = bytes(size, 7)
    const { object, chunks } = sealAll(plain, cb)
    const n = X.partCount(size, cb, pb)
    expect(n).toBe(Math.ceil(object.length / pb))
    const tags = new Uint8Array(chunks.length * 16)
    const parts = []
    for (let p = n; p >= 1; p--) parts[p - 1] = await X.sealPart(p, plain, C, prefix, cb, pb, (i, t) => tags.set(t, i * 16))
    parts.slice(0, -1).forEach((p) => expect(p.length).toBe(pb))
    expect(X.concat(...parts)).toEqual(object)
    expect(tags).toEqual(X.concat(...chunks.map((c) => c.subarray(c.length - 16))))
  })
  it('reads a Blob a chunk at a time', async () => {
    const plain = bytes(300)
    const out = []
    for await (const c of X.sealChunks(new Blob([plain]), C, prefix, 128)) out.push(c.sealed)
    expect(X.concat(...out)).toEqual(sealAll(plain, 128).object)
  })
})

describe('derived objects', () => {
  it('29-byte header, refuses tampering', () => {
    const plain = bytes(1500)
    const obj = X.sealDerived('rendition', Kv, plain)
    expect(X.derivedHeader(obj)).toMatchObject({ size: 1500, chunkBytes: X.DERIVED_CHUNK })
    expect(X.openDerived('rendition', Kv, obj)).toEqual(plain)
    expect(() => X.openDerived('thumbnail', Kv, obj)).toThrow(X.SealError)
    const bad = obj.slice()
    bad[20] ^= 1 // size
    expect(() => X.openDerived('rendition', Kv, bad)).toThrow(X.SealError)
  })
})

describe('rotation and re-wraps', () => {
  it('builds a rotate body that the remaining holders open and walks back', async () => {
    const S = await X.init()
    const a = S.crypto_box_keypair()
    const body = X.buildRotation({ scopeId: NODE, epoch: 3, Ks, remove: ['mbr_gone'], holders: [{ membership_id: 'mbr_a', public_key: a.publicKey }] })
    expect(body.body).toMatchObject({ remove: ['mbr_gone'], epoch: 4 })
    const k4 = X.openGrant(X.unb64(body.body.grants[0].sealed_key), a.publicKey, a.privateKey)
    expect(X.unwrapPreviousKey(k4, NODE, 4, X.unb64(body.body.previous_key_wrapped))).toEqual(Ks)
    expect(() => X.buildRotation({ scopeId: NODE, epoch: 3, Ks, remove: ['mbr_a'], holders: [{ membership_id: 'mbr_a', public_key: a.publicKey }] })).toThrow()
  })
  it('re-wraps a copy for new ids without touching chunks', () => {
    const { manifest } = sealAll(bytes(100), 64)
    const out = X.rewrapVersion({ Ks, Kv, manifest, nodeId: 'dnd_new000000000000000000', versionId: VER2, meta: { name: 'copy', mime: null } })
    const m = X.openManifest(Kv, 'dnd_new000000000000000000', VER2, X.unb64(out.manifest_ciphertext))
    expect(m.prefix).toBe(manifest.prefix)
    expect(X.unwrapVersionKey(Ks, 'dnd_new000000000000000000', VER2, X.unb64(out.wrapped_key))).toEqual(Kv)
  })
  it('moves across scopes', () => {
    const to = X.newKey()
    const out = X.rewrapAcross({ fromKs: Ks, toKs: to, nodeId: NODE, metadata: X.sealMeta(Ks, NODE, { name: 'n', mime: 'a/b' }), versions: [{ id: VER, wrapped: X.wrapVersionKey(Ks, NODE, VER, Kv) }] })
    expect(X.openMeta(to, NODE, X.unb64(out.metadata_ciphertext)).name).toBe('n')
    expect(X.unwrapVersionKey(to, NODE, VER, X.unb64(out.versions[0].wrapped_key))).toEqual(Kv)
  })
})

describe('ids and sizes', () => {
  it('proposes prefix_ + 21 nanoid characters', () => {
    const id = X.proposeId('dnd')
    expect(id).toMatch(/^dnd_[A-Za-z0-9_-]{21}$/)
    expect(X.proposeId('dnd')).not.toBe(id)
  })
  it('computes the plaintext size from the stored size', () => {
    for (const [size, cb] of [[0, 64], [1, 64], [64, 64], [65, 64], [200, 64], [5 * 1024 * 1024 + 3, 1024 * 1024]]) {
      expect(X.plainSize(X.cipherSize(size, cb), cb)).toBe(size)
    }
  })
})
