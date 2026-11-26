/* global Buffer, process */
// Section 6.13 vectors. Every expected value is checked against crypto.js here and,
// independently, by scripts/disk-vectors-check.mjs. Regenerate (only when the
// format changes on purpose): DISK_VECTORS_WRITE=1 yarn vitest run --project unit vectors
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { beforeAll, describe, expect, it } from 'vitest'
import * as X from '../crypto'

const here = path.dirname(fileURLToPath(import.meta.url))
const FILE = path.join(here, 'vectors.json')
const hex = (b) => Buffer.from(b).toString('hex')
const unhex = (h) => new Uint8Array(Buffer.from(h, 'hex'))
const rep = (byte, n) => byte.repeat(n)

// Fixed inputs. Ids are public keys as the API hands them out.
const IN = {
  scope: 'dnd_scoperoot00000000000A',
  node: 'dnd_filenode000000000000B',
  node2: 'dnd_copynode000000000000C',
  version: 'dvr_version0000000000000D',
  version2: 'dvr_version0000000000000E',
  link: 'dln_link0000000000000000F',
  Ks1: rep('11', 32),
  Ks2: rep('22', 32),
  Kv: rep('33', 32),
  identitySeed: rep('44', 32),
  prefix: rep('55', 16),
  thumbPrefix: rep('66', 16),
  secret: rep('77', 32),
  salt: rep('88', 16),
  password: 'correct horse battery staple',
  nonce: (k) => rep(k, 24),
}

let S
let queue = []
const fixed = (n) => {
  const next = queue.shift()
  if (!next || next.length !== n) throw new Error(`vector random source: wanted ${n} bytes`)
  return next
}
const withNonces = (nonces, fn) => { queue = nonces.map(unhex); const r = fn(); expect(queue).toHaveLength(0); return r }

function build() {
  const Ks1 = unhex(IN.Ks1)
  const Ks2 = unhex(IN.Ks2)
  const Kv = unhex(IN.Kv)
  const prefix = unhex(IN.prefix)
  const v = []
  const add = (name, inputs, expected) => v.push({ name, inputs, expected })

  add('AD', { label: 'disk/example/v1', fields: [{ id: IN.node }, { int: 7 }, { flag: 1 }, { bytes: 'a1b2' }] },
    { ad: hex(X.AD('disk/example/v1', IN.node, 7, true, unhex('a1b2'))) })
  add('KDF', { key: IN.Ks1, label: 'disk/meta/v1' }, { out: hex(X.KDF(Ks1, 'disk/meta/v1')) })
  const sk = X.scopeKeys(Ks1)
  const vk = X.versionKeys(Kv)
  add('scope keys', { Ks: IN.Ks1 }, { E: hex(sk.E), M: hex(sk.M), W: hex(sk.W), P: hex(sk.P) })
  add('version keys', { Kv: IN.Kv }, { C: hex(vk.C), F: hex(vk.F), T: hex(vk.T), R: hex(vk.R) })
  const envAd = X.AD('disk/example/v1', IN.node)
  add('ENV', { key: IN.Ks1, ad: hex(envAd), plaintext: hex(X.utf8('hello')), nonce: IN.nonce('a0') },
    { env: hex(X.ENV(Ks1, envAd, X.utf8('hello'), unhex(IN.nonce('a0')))) })

  const id = S.crypto_box_seed_keypair(unhex(IN.identitySeed))
  const sealedGrant = X.sealGrant(Ks1, id.publicKey) // randomised: stored as an input, checked by opening
  add('key grant (open)', { identitySeed: IN.identitySeed, publicKey: hex(id.publicKey), sealed: hex(sealedGrant) }, { Ks: IN.Ks1 })

  add('epoch chain', { scope: IN.scope, epoch: 2, Ks: IN.Ks2, previous: IN.Ks1, nonce: IN.nonce('a1') },
    { previous_key_wrapped: hex(withNonces([IN.nonce('a1')], () => X.wrapPreviousKey(Ks2, IN.scope, 2, Ks1))) })
  add('metadata', { Ks: IN.Ks1, node: IN.node, meta: { name: 'Q4 plan é.pdf', mime: 'application/pdf' }, nonce: IN.nonce('a2') },
    { json: '{"mime":"application/pdf","name":"Q4 plan é.pdf"}', metadata_ciphertext: hex(withNonces([IN.nonce('a2')], () => X.sealMeta(Ks1, IN.node, { name: 'Q4 plan é.pdf', mime: 'application/pdf' }))) })
  add('version key wrap', { Ks: IN.Ks1, node: IN.node, version: IN.version, Kv: IN.Kv, nonce: IN.nonce('a3') },
    { wrapped_key: hex(withNonces([IN.nonce('a3')], () => X.wrapVersionKey(Ks1, IN.node, IN.version, Kv))) })

  // Content: 40 bytes in 16-byte chunks -> 16, 16, 8 (short last chunk).
  const plain = new Uint8Array(40).map((_, i) => i)
  const cb = 16
  const chunks = [0, 1, 2].map((i) => X.sealChunk(vk.C, prefix, i, i === 2, plain.subarray(i * cb, (i + 1) * cb)))
  add('content chunks', { Kv: IN.Kv, prefix: IN.prefix, chunk_bytes: cb, plaintext: hex(plain) }, { chunks: chunks.map(hex), object: hex(X.concat(...chunks)) })
  const empty = X.sealChunk(vk.C, prefix, 0, true, new Uint8Array(0))
  add('empty file', { Kv: IN.Kv, prefix: IN.prefix, chunk_bytes: cb }, { object: hex(empty) })

  const tags = X.concat(...chunks.map((c) => c.subarray(c.length - 16)))
  const manifest = X.buildManifest({ nodeId: IN.node, versionId: IN.version, size: 40, chunkBytes: cb, prefix, tags })
  add('manifest', { Kv: IN.Kv, node: IN.node, version: IN.version, nonce: IN.nonce('a4'), object: hex(X.concat(...chunks)) },
    { json: X.canonicalJson(manifest), manifest_ciphertext: hex(withNonces([IN.nonce('a4')], () => X.sealManifest(Kv, manifest))) })

  const thumbPlain = X.utf8('not really a png')
  add('thumbnail object', { Kv: IN.Kv, prefix: IN.thumbPrefix, plaintext: hex(thumbPlain) }, { object: hex(X.sealDerived('thumbnail', Kv, thumbPlain, unhex(IN.thumbPrefix))) })

  for (const password of [null, IN.password]) {
    const keys = X.linkKeys({ secret: unhex(IN.secret), salt: unhex(IN.salt), password })
    const nonce = IN.nonce(password ? 'a6' : 'a5')
    add(`link ${password ? 'with' : 'without'} password`,
      { secret: IN.secret, secret_b64url: X.b64url(unhex(IN.secret)), salt: IN.salt, password, link: IN.link, version: IN.version, Kv: IN.Kv, name: 'Q4 plan é.pdf', mime: 'application/pdf', nonce },
      {
        pw_key: hex(keys.pwKey), wrap_key: hex(keys.wrapKey), verifier: keys.verifier ? hex(keys.verifier) : null,
        wrapped_payload: hex(withNonces([nonce], () => X.sealLinkPayload(keys.wrapKey, IN.link, IN.version, { Kv, mime: 'application/pdf', name: 'Q4 plan é.pdf' }))),
      })
  }

  const yState = unhex('0101a1b2c3d4')
  add('page snapshot', { Ks: IN.Ks2, node: IN.node, epoch: 2, seq: 7, state: hex(yState), nonce: IN.nonce('a7') },
    { sealed_snapshot: hex(withNonces([IN.nonce('a7')], () => X.sealPageSnapshot(Ks2, IN.node, 2, 7, yState))) })
  add('page update', { Ks: IN.Ks2, node: IN.node, epoch: 2, seq: 8, update: hex(yState.subarray(2)), nonce: IN.nonce('a8') },
    { sealed_update: hex(withNonces([IN.nonce('a8')], () => X.sealPageUpdate(Ks2, IN.node, 2, 8, yState.subarray(2)))) })
  add('page awareness', { Ks: IN.Ks2, node: IN.node, epoch: 2, update: hex(yState.subarray(4)), nonce: IN.nonce('a9') },
    { sealed_awareness: hex(withNonces([IN.nonce('a9')], () => X.sealAwareness(Ks2, IN.node, 2, yState.subarray(4)))) })
  return v
}

beforeAll(async () => {
  S = await X.init()
  X.setRandomForTests(fixed)
})

describe('section 6.13 vectors', () => {
  it('match vectors.json', () => {
    const fresh = build()
    if (process.env.DISK_VECTORS_WRITE) fs.writeFileSync(FILE, `${JSON.stringify({ format: 'disk sealed v1 (disk-build.md 6)', vectors: fresh }, null, 2)}\n`)
    const stored = JSON.parse(fs.readFileSync(FILE, 'utf8')).vectors
    const byName = Object.fromEntries(stored.map((x) => [x.name, x]))
    for (const v of fresh) {
      // The key grant is randomised: the stored one must still open to the same key.
      if (v.name === 'key grant (open)') continue
      expect(byName[v.name]?.expected, v.name).toEqual(v.expected)
    }
    const g = byName['key grant (open)'].inputs
    const id = S.crypto_box_seed_keypair(unhex(g.identitySeed))
    expect(hex(X.openGrant(unhex(g.sealed), id.publicKey, id.privateKey))).toBe(IN.Ks1)
  }, 60_000) // the password vector runs Argon2id: 8 s on the 8 shared cores of the Pushleft runner

  it('opens what it seals', () => {
    X.setRandomForTests(null)
    const Ks = X.newKey()
    const Kv = X.newKey()
    expect(X.openMeta(Ks, IN.node, X.sealMeta(Ks, IN.node, { name: 'a', mime: null }))).toEqual({ name: 'a', mime: null })
    expect(X.unwrapVersionKey(Ks, IN.node, IN.version, X.wrapVersionKey(Ks, IN.node, IN.version, Kv))).toEqual(Kv)
    const thumb = X.utf8('x'.repeat(3000))
    expect(X.openDerived('thumbnail', Kv, X.sealDerived('thumbnail', Kv, thumb))).toEqual(thumb)
    X.setRandomForTests(fixed)
  })
})
