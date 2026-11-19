// lib/disk/sealed.js against a fake API: scopes and the epoch chain, ids,
// rotation, copies and moves between scopes, single-file links, sealed pages.
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import * as X from '../crypto'

const routes = []
const calls = []
const fake = (method) => vi.fn(async (path, body) => {
  calls.push({ method, path, body })
  const r = routes.find((x) => x.method === method && x.match.test(path))
  if (!r) throw Object.assign(new Error(`no route ${method} ${path}`), { status: 404 })
  return r.reply(path, body)
})
vi.mock('../../api', () => ({ default: { get: fake('get'), post: fake('post'), put: fake('put'), patch: fake('patch'), delete: fake('delete') } }))
const on = (method, match, reply) => routes.unshift({ method, match, reply })

const S = await import('../sealed')
const ORG = 'org_test'
const ROOT = 'dnd_rootrootrootrootroot1'
const FILE = 'dnd_filefilefilefilefile1'
const VER = 'dvr_verververververververv'
let sodium
let me
const enc = (b) => X.b64(b)

beforeAll(async () => {
  sodium = await X.init()
  me = sodium.crypto_box_keypair()
})
beforeEach(() => { routes.length = 0; calls.length = 0; S.clearSealed() })

/** A scope at epoch 2 whose epoch-1 key is reachable through the chain; I hold only epoch 2. */
function scopeAt2() {
  const k1 = X.newKey()
  const k2 = X.newKey()
  on('get', /\/scopes\//, () => ({
    scope: {
      id: ROOT, epoch: 2, rotation_due: false,
      grant: { epoch: 2, sealed_key: enc(X.sealGrant(k2, me.publicKey)) },
      grants: [{ epoch: 2, sealed_key: enc(X.sealGrant(k2, me.publicKey)) }],
      epochs: [{ epoch: 2, previous_key_wrapped: enc(X.wrapPreviousKey(k2, ROOT, 2, k1)) }],
      holders: [{ id: 'mbr_me', name: 'Me', role: 'manage', has_key: true }, { id: 'mbr_b', name: 'B', role: 'view', has_key: true }],
      links: [],
    },
  }))
  return { k1, k2 }
}

describe('scopes', () => {
  it('opens the grant and walks back to older epochs', async () => {
    const { k1, k2 } = scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    expect(scope.key).toEqual(k2)
    expect(scope.keyFor(1)).toEqual(k1)
    const n = { id: FILE, kind: 'file', sealed: true, key_epoch: 1, size_bytes: X.cipherSize(100, X.CHUNK_DEFAULT), metadata_ciphertext: enc(X.sealMeta(k1, FILE, { name: 'a.pdf', mime: 'application/pdf' })) }
    expect(S.openNames(scope, [n])[0]).toMatchObject({ name: 'a.pdf', mime: 'application/pdf', opened: true, size_bytes: 100 })
  })
  it('says NoKey to a role without a key', async () => {
    on('get', /\/scopes\//, () => ({ scope: { id: ROOT, epoch: 1, grant: null, grants: [], epochs: [], holders: [], links: [] } }))
    await expect(S.openScope(ORG, ROOT, me)).rejects.toBeInstanceOf(S.NoKey)
  })
  it('proposes another id when one is taken', async () => {
    let n = 0
    const got = await S.withProposedId('dnd', async (id) => {
      if (n++ === 0) throw Object.assign(new Error('taken'), { data: { code: 'disk_id_taken' } })
      return id
    })
    expect(got).toMatch(/^dnd_.{21}$/)
    expect(n).toBe(2)
  })
})

describe('rotation', () => {
  it('grants every holder who stays the new key, chained to the old', async () => {
    const { k2 } = scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    const b = sodium.crypto_box_keypair()
    on('get', /\/keys\/members/, () => ({ members: [{ membership_id: 'mbr_me', public_key: enc(me.publicKey) }, { membership_id: 'mbr_b', public_key: enc(b.publicKey) }] }))
    on('post', /\/rotate$/, () => ({ scope: {} }))
    await S.rotateScope({ orgId: ORG, scope, remove: ['mbr_b'] })
    const body = calls.find((c) => c.path.endsWith('/rotate')).body
    expect(body).toMatchObject({ remove: ['mbr_b'], epoch: 3 })
    expect(body.grants.map((g) => g.membership_id)).toEqual(['mbr_me'])
    const k3 = X.openGrant(X.unb64(body.grants[0].sealed_key), me.publicKey, me.privateKey)
    expect(X.unwrapPreviousKey(k3, ROOT, 3, X.unb64(body.previous_key_wrapped))).toEqual(k2)
  })
  it('refuses when a remaining holder has no identity key', async () => {
    scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    on('get', /\/keys\/members/, () => ({ members: [{ membership_id: 'mbr_me', public_key: enc(me.publicKey) }, { membership_id: 'mbr_b', public_key: null }] }))
    await expect(S.rotateScope({ orgId: ORG, scope, remove: [] })).rejects.toThrow('no encryption key')
  })
})

/** A sealed file version under the scope's epoch-2 key. */
function fileVersion(k, epoch = 2) {
  const Kv = X.newKey()
  const prefix = X.newKey().slice(0, 16)
  const plain = new Uint8Array(300).map((_, i) => i)
  const cb = 128
  const chunks = [0, 1, 2].map((i) => X.sealChunk(X.versionKeys(Kv).C, prefix, i, i === 2, plain.subarray(i * cb, (i + 1) * cb)))
  const tags = X.concat(...chunks.map((c) => c.subarray(c.length - 16)))
  const manifest = X.buildManifest({ nodeId: FILE, versionId: VER, size: 300, chunkBytes: cb, prefix, tags })
  const version = { id: VER, key_epoch: epoch, chunk_bytes: cb, current: true, wrapped_key: enc(X.wrapVersionKey(k, FILE, VER, Kv)), manifest_ciphertext: enc(X.sealManifest(Kv, manifest)) }
  on('get', /\/nodes\/.*\/versions/, () => ({ versions: [version], next_cursor: null }))
  return { Kv, version, plain, object: X.concat(...chunks) }
}

describe('copies, restores, moves', () => {
  it('copies into another scope: same K_v, wrapped and named for the new ids', async () => {
    const { k2 } = scopeAt2()
    const from = await S.openScope(ORG, ROOT, me)
    const { Kv } = fileVersion(k2)
    const tk = X.newKey()
    const to = { id: 'dnd_other', epoch: 4, key: tk, keyFor: () => tk }
    on('get', /\/children/, () => ({ nodes: [], next_cursor: null }))
    on('post', /\/copy$/, () => ({ upload: { id: 'upl_1', node_id: 'dnd_copycopycopycopycopy1', version_id: 'dvr_copycopycopycopycopy1', key_epoch: 4 } }))
    on('post', /\/complete$/, () => ({ node: {}, version: {} }))
    await S.copySealedFile({ orgId: ORG, source: from, target: to, node: { id: FILE, name: 'a.pdf', mime: 'application/pdf', current_version_id: VER }, targetId: 'dnd_t' })
    const body = calls.find((c) => c.path.endsWith('/complete')).body
    expect(X.unwrapVersionKey(tk, 'dnd_copycopycopycopycopy1', 'dvr_copycopycopycopycopy1', X.unb64(body.wrapped_key))).toEqual(Kv)
    expect(X.openManifest(Kv, 'dnd_copycopycopycopycopy1', 'dvr_copycopycopycopycopy1', X.unb64(body.manifest_ciphertext)).size).toBe(300)
    expect(X.openMeta(tk, 'dnd_copycopycopycopycopy1', X.unb64(body.metadata_ciphertext)).name).toBe('a.pdf')
  })
  it('restores an old version under the current epoch', async () => {
    const { k1, k2 } = scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    const { Kv, version } = fileVersion(k1, 1)
    on('post', /\/versions\/.*\/restore$/, () => ({ upload: { id: 'upl_2', node_id: FILE, version_id: 'dvr_newnewnewnewnewnewnew', key_epoch: 2 } }))
    on('post', /\/complete$/, () => ({}))
    await S.restoreSealedVersion({ orgId: ORG, scope, node: { id: FILE }, version })
    const body = calls.find((c) => c.path.endsWith('/complete')).body
    expect(X.unwrapVersionKey(k2, FILE, 'dvr_newnewnewnewnewnewnew', X.unb64(body.wrapped_key))).toEqual(Kv)
    expect(body.metadata_ciphertext).toBeUndefined()
  })
  it('moves a file into another scope re-sealing its name and every version key', async () => {
    const { k2 } = scopeAt2()
    const from = await S.openScope(ORG, ROOT, me)
    const { Kv } = fileVersion(k2)
    const tk = X.newKey()
    const to = { id: 'dnd_other', epoch: 4, key: tk, keyFor: () => tk }
    on('post', /\/move$/, () => ({ node: {} }))
    const node = { id: FILE, kind: 'file', key_epoch: 2, metadata_ciphertext: enc(X.sealMeta(k2, FILE, { name: 'a.pdf', mime: null })) }
    await S.moveAcrossScopes({ orgId: ORG, from, to, node, targetId: 'dnd_t' })
    const body = calls.find((c) => c.path.endsWith('/move')).body
    expect(body).toMatchObject({ target_id: 'dnd_t', key_epoch: 4, pages: [] })
    expect(X.openMeta(tk, FILE, X.unb64(body.nodes[0].metadata_ciphertext)).name).toBe('a.pdf')
    expect(X.unwrapVersionKey(tk, FILE, VER, X.unb64(body.versions[0].wrapped_key))).toEqual(Kv)
  })
  it('opens a whole version against its manifest', async () => {
    const { k2 } = scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    const { version, plain, object } = fileVersion(k2)
    on('get', /\/versions\/.*\/download/, () => ({ download: { url: 'https://store/x' } }))
    globalThis.fetch = vi.fn(async () => new Response(object))
    expect(await S.sealedBytes({ orgId: ORG, scope, nodeId: FILE, version })).toEqual(plain)
  })
})

describe('opening into a Blob without the worker', () => {
  it('streams chunk by chunk and checks lengths and tags', async () => {
    const { k2 } = scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    const { version, plain, object } = fileVersion(k2)
    // Arrives in awkward pieces, as a network would hand it over.
    const pieces = (bytes) => new ReadableStream({ start(c) { for (let i = 0; i < bytes.length; i += 77) c.enqueue(bytes.slice(i, i + 77)); c.close() } })
    globalThis.fetch = vi.fn(async () => new Response(pieces(object)))
    const blob = await S.sealedBlob({ orgId: ORG, scope, nodeId: FILE, version, url: 'https://store/x' })
    expect(new Uint8Array(await blob.arrayBuffer())).toEqual(plain)
    globalThis.fetch = vi.fn(async () => new Response(pieces(object.slice(0, -1))))
    await expect(S.sealedBlob({ orgId: ORG, scope, nodeId: FILE, version, url: 'https://store/x' })).rejects.toThrow('wrong length')
  })
})

describe('sealed names', () => {
  it('suffixes like the API and finds a free name case-insensitively', () => {
    expect(S.suffixed('a.pdf', 1)).toBe('a (1).pdf')
    expect(S.suffixed('v1.2', 2, true)).toBe('v1.2 (2)')
    expect(S.suffixed('.env', 1)).toBe('.env (1)')
    expect(S.freeName('A.pdf', new Set(['a.pdf', 'a (1).pdf']))).toBe('A (2).pdf')
  })
  it('a rename onto a taken name is a 409 unless keep both', async () => {
    const { k2 } = scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    const other = { id: 'dnd_o', kind: 'file', sealed: true, key_epoch: 2, metadata_ciphertext: enc(X.sealMeta(k2, 'dnd_o', { name: 'Plan.md', mime: null })) }
    on('get', /\/children/, () => ({ nodes: [other], next_cursor: null }))
    on('patch', /\/nodes\//, (_p, body) => ({ node: body }))
    const node = { id: FILE, kind: 'file', parent_id: ROOT, name: 'x.md', mime: null }
    await expect(S.renameSealed(ORG, scope, node, 'plan.md')).rejects.toMatchObject({ status: 409 })
    await S.renameSealed(ORG, scope, node, 'plan.md', true)
    const body = calls.find((c) => c.method === 'patch').body
    expect(X.openMeta(k2, FILE, X.unb64(body.metadata_ciphertext)).name).toBe('plan (1).md')
  })
})

describe('single-file links', () => {
  it('the viewer opens what the manager made, with the password', async () => {
    const { k2 } = scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    const { version } = fileVersion(k2)
    let sent
    on('post', /\/links$/, (_p, body) => { sent = body; return { link: { id: body.id, url: 'https://app/share/tok' } } })
    const link = await S.createSealedLink({ orgId: ORG, scope, node: { id: FILE, name: 'a.pdf', mime: 'application/pdf', current_version_id: VER }, password: 'pw' })
    const secret = link.url.split('#')[1]
    expect(link.url).toMatch(/^https:\/\/app\/share\/tok#[A-Za-z0-9_-]{43}$/)
    expect(sent.wrapped_payload).toBeTruthy()
    expect(await S.linkVerifier(secret, sent.kdf_salt, 'pw')).toBe(sent.password_verifier)
    const viewer = { kdf_salt: sent.kdf_salt, node: { id: FILE }, sealed_payload: { link_id: sent.id, version_id: VER, wrapped_payload: sent.wrapped_payload, manifest_ciphertext: version.manifest_ciphertext } }
    const opened = await S.openSealedLink({ secretB64url: secret, password: 'pw', link: viewer })
    expect(opened).toMatchObject({ name: 'a.pdf', mime: 'application/pdf', versionId: VER })
    expect(opened.manifest.size).toBe(300)
    await expect(S.openSealedLink({ secretB64url: secret, password: 'nope', link: viewer })).rejects.toThrow()
  }, 30_000)
})

describe('sealed pages', () => {
  it('rebuilds the state from the snapshot and the updates above it', async () => {
    const { k1, k2 } = scopeAt2()
    const scope = await S.openScope(ORG, ROOT, me)
    const Y = await import('yjs')
    const doc = new Y.Doc()
    doc.getText('t').insert(0, 'hello')
    const snap = Y.encodeStateAsUpdate(doc)
    const before = Y.encodeStateVector(doc)
    doc.getText('t').insert(5, ' world')
    const upd = Y.encodeStateAsUpdate(doc, before)
    const page = {
      sealed_snapshot: enc(X.sealPageSnapshot(k1, FILE, 1, 4, snap)), snapshot_epoch: 1, snapshot_seq: 4, update_seq: 5,
      updates: [{ seq: 5, epoch: 2, ciphertext: enc(X.sealPageUpdate(k2, FILE, 2, 5, upd)) }],
    }
    const { state, seq } = await S.openSealedPage(scope, FILE, page)
    const out = new Y.Doc()
    Y.applyUpdate(out, state)
    expect(out.getText('t').toString()).toBe('hello world')
    expect(seq).toBe(5)
  })
})

describe('cross-seal job plan', () => {
  it('flattens folders and carries files and pages', async () => {
    const { planJob } = await import('../crossSeal')
    on('get', /\/nodes\/dnd_f\/children/, () => ({ nodes: [{ id: 'dnd_a', kind: 'file', name: 'a.txt', mime: 'text/plain' }, { id: 'dnd_g', kind: 'folder', name: 'G' }], next_cursor: null }))
    on('get', /\/nodes\/dnd_g\/children/, () => ({ nodes: [{ id: 'dnd_p', kind: 'page', name: 'P' }], next_cursor: null }))
    const job = await planJob({ orgId: ORG, op: 'move', direction: 'to_sealed', sources: [{ id: 'dnd_f', kind: 'folder', name: 'F' }], targetId: 'dnd_t' })
    expect(job.folders.map((f) => [f.name, f.parentKey])).toEqual([['F', null], ['G', 'f0']])
    expect(job.items.map((i) => [i.name, i.kind, i.parentKey, i.state])).toEqual([['a.txt', 'file', 'f0', 'todo'], ['P', 'page', 'f1', 'todo']])
  })
})
