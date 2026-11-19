// Sealed Disk, the format (docs/plans/disk-build.md section 6, byte for byte).
// Pure functions over libsodium; nothing here touches the network or the DOM.
// Call `await init()` once, then everything is synchronous.
//
// Field types in AD(): a string is an id (its UTF-8), a number or bigint is an
// integer (u64be), a boolean is a flag (one byte), a Uint8Array is raw bytes
// (only 6.9 uses one; see the note at linkKeys).
import { ready } from '../e2ee'

let S = null
export async function init() {
  S = await ready()
  return S
}

// Every random value comes from randombytes_buf (6.3). Tests swap this for a
// fixed source to make vectors; production never calls setRandomForTests.
let random = (n) => S.randombytes_buf(n)
export function setRandomForTests(fn) {
  random = fn || ((n) => S.randombytes_buf(n))
}

const te = new TextEncoder()
const td = new TextDecoder('utf-8', { fatal: true })
export const utf8 = (s) => te.encode(s)

export const TAG_BYTES = 16
export const ENV_VERSION = 0x01
export const ENV_MIN = 1 + 24 + TAG_BYTES // 41
export const DERIVED_HEADER = 29
export const DERIVED_CHUNK = 1024 * 1024
export const CHUNK_MEDIA = 1024 * 1024 // build guide section 1: 1 MiB for audio and video
export const CHUNK_DEFAULT = 4 * 1024 * 1024 // 4 MiB otherwise

export const LABEL = {
  EPOCH: 'disk/epoch/v1',
  META: 'disk/meta/v1',
  WRAP: 'disk/wrap/v1',
  PAGE: 'disk/page/v1',
  CONTENT: 'disk/content/v1',
  MANIFEST: 'disk/manifest/v1',
  THUMB: 'disk/thumb/v1',
  RENDITION: 'disk/rendition/v1',
  CHUNK: 'disk/chunk/v1',
  THUMB_CHUNK: 'disk/thumb/chunk/v1',
  RENDITION_CHUNK: 'disk/rendition/chunk/v1',
  LINK_KEY: 'disk/link/key/v1',
  LINK: 'disk/link/v1',
  LINK_VERIFIER: 'disk/link/verifier/v1',
  PAGE_SNAP: 'disk/page/snap/v1',
  PAGE_UPDATE: 'disk/page/update/v1',
  PAGE_AWARE: 'disk/page/aware/v1',
}

export class SealError extends Error {}
const refuse = (msg) => { throw new SealError(msg) }

// ── 6.3 encoding ────────────────────────────────────────────────────────────

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) { out.set(p, o); o += p.length }
  return out
}

export function u64be(n) {
  const b = new Uint8Array(8)
  new DataView(b.buffer).setBigUint64(0, BigInt(n))
  return b
}

export function u32be(n) {
  const b = new Uint8Array(4)
  new DataView(b.buffer).setUint32(0, n)
  return b
}

function field(f) {
  if (typeof f === 'string') return utf8(f)
  if (typeof f === 'number' || typeof f === 'bigint') return u64be(f)
  if (typeof f === 'boolean') return Uint8Array.of(f ? 1 : 0)
  if (f instanceof Uint8Array) return f
  throw new TypeError(`AD field of unknown type: ${typeof f}`)
}

export function AD(label, ...fields) {
  const parts = [utf8(label), Uint8Array.of(0)]
  for (const f of fields) {
    const bytes = field(f)
    if (bytes.length > 0xffff) throw new RangeError('AD field over 65535 bytes')
    parts.push(Uint8Array.of(bytes.length >> 8, bytes.length & 0xff), bytes)
  }
  return concat(...parts)
}

export const KDF = (key, label) => S.crypto_generichash(32, utf8(label), key)

export function ENV(key, ad, plaintext, nonce = random(24)) {
  const ct = S.crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, ad, null, nonce, key)
  return concat(Uint8Array.of(ENV_VERSION), nonce, ct)
}

export function openENV(key, ad, env) {
  if (!(env instanceof Uint8Array) || env.length < ENV_MIN) refuse('envelope too short')
  if (env[0] !== ENV_VERSION) refuse('unknown envelope version')
  try {
    return S.crypto_aead_xchacha20poly1305_ietf_decrypt(null, env.subarray(25), ad, env.subarray(1, 25), key)
  } catch {
    return refuse('envelope failed authentication')
  }
}

/** JSON with keys sorted at every level and no insignificant whitespace (6.3). */
export function canonicalJson(value) {
  const sort = (v) => (Array.isArray(v) ? v.map(sort)
    : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sort(v[k])])) : v)
  return JSON.stringify(sort(value))
}
const jsonBytes = (v) => utf8(canonicalJson(v))
const parseJson = (bytes) => {
  try { return JSON.parse(td.decode(bytes)) } catch { return refuse('sealed JSON is not valid') }
}

export const b64 = (bytes) => S.to_base64(bytes, S.base64_variants.ORIGINAL)
export const unb64 = (str) => S.from_base64(str, S.base64_variants.ORIGINAL)
export const b64url = (bytes) => S.to_base64(bytes, S.base64_variants.URLSAFE_NO_PADDING)
export const unb64url = (str) => S.from_base64(str, S.base64_variants.URLSAFE_NO_PADDING)

// ── 6.5 client-proposed ids ─────────────────────────────────────────────────

const NANOID = 'useandom-26T198340PX75pxJACKVERYMINDBUSHWOLF_GQZbfghjklqvwyzrict'
/** A public id for a sealed create: prefix_ + 21 nanoid characters from randombytes_buf (6.5). */
export function proposeId(prefix) {
  const r = random(21)
  return `${prefix}_${Array.from(r, (b) => NANOID[b & 63]).join('')}`
}

// ── 6.6 sizes: the stored size is ciphertext; the plaintext size follows ────

export { plainSize } from './model'

// ── 6.4 keys ────────────────────────────────────────────────────────────────

export const newKey = () => random(32)

/** E, M, W and P of a scope key. K_s itself is never an encryption key. */
export function scopeKeys(Ks) {
  return { E: KDF(Ks, LABEL.EPOCH), M: KDF(Ks, LABEL.META), W: KDF(Ks, LABEL.WRAP), P: KDF(Ks, LABEL.PAGE) }
}

/** C, F, T and R of a version key. */
export function versionKeys(Kv) {
  return { C: KDF(Kv, LABEL.CONTENT), F: KDF(Kv, LABEL.MANIFEST), T: KDF(Kv, LABEL.THUMB), R: KDF(Kv, LABEL.RENDITION) }
}

// ── 6.5 records ─────────────────────────────────────────────────────────────

/** disk_key_grants.sealed_key: K_s[e] sealed to a holder's X25519 identity public key. */
export const sealGrant = (Ks, publicKey) => S.crypto_box_seal(Ks, publicKey)
export function openGrant(sealed, publicKey, privateKey) {
  let k
  try {
    k = S.crypto_box_seal_open(sealed, publicKey, privateKey)
  } catch {
    refuse('key grant does not open with this identity')
  }
  return k.length === 32 ? k : refuse('key grant is not a 32-byte key')
}

/** disk_scope_epochs.previous_key_wrapped on the row for epoch e (e >= 2). */
export function wrapPreviousKey(Ks, scopeId, e, KsPrev) {
  if (!(e >= 2)) throw new RangeError('epoch 1 has no previous key')
  return ENV(scopeKeys(Ks).E, AD(LABEL.EPOCH, scopeId, e - 1), KsPrev)
}
export function unwrapPreviousKey(Ks, scopeId, e, wrapped) {
  const k = openENV(scopeKeys(Ks).E, AD(LABEL.EPOCH, scopeId, e - 1), wrapped)
  return k.length === 32 ? k : refuse('previous epoch key is not 32 bytes')
}

/**
 * Walks back from the epoch key a holder has to an older one.
 * chain(e) returns previous_key_wrapped for epoch e (bytes). Returns K_s[target].
 */
export function walkBack(Ks, epoch, target, scopeId, chain) {
  if (target > epoch || target < 1) refuse(`epoch ${target} is not reachable from ${epoch}`)
  let k = Ks
  for (let e = epoch; e > target; e--) k = unwrapPreviousKey(k, scopeId, e, chain(e))
  return k
}

/** disk_nodes.metadata_ciphertext. meta: { name, mime } (mime null for folders and pages). */
export const sealMeta = (Ks, nodeId, meta) => ENV(scopeKeys(Ks).M, AD(LABEL.META, nodeId), jsonBytes({ mime: meta.mime ?? null, name: meta.name }))
export function openMeta(Ks, nodeId, sealed) {
  const m = parseJson(openENV(scopeKeys(Ks).M, AD(LABEL.META, nodeId), sealed))
  if (typeof m?.name !== 'string') refuse('metadata has no name')
  return { name: m.name, mime: m.mime ?? null }
}

/** disk_versions.wrapped_key. */
export const wrapVersionKey = (Ks, nodeId, versionId, Kv) => ENV(scopeKeys(Ks).W, AD(LABEL.WRAP, nodeId, versionId), Kv)
export function unwrapVersionKey(Ks, nodeId, versionId, wrapped) {
  const k = openENV(scopeKeys(Ks).W, AD(LABEL.WRAP, nodeId, versionId), wrapped)
  return k.length === 32 ? k : refuse('version key is not 32 bytes')
}

// ── 6.6 content: range maths (pure; the service worker keeps its own copy, tested equal) ──

export const chunkCount = (size, cb) => Math.max(1, Math.ceil(size / cb))
export const cipherSize = (size, cb) => size + chunkCount(size, cb) * TAG_BYTES
/** [start, end] inclusive byte range of chunk i in the stored object (offset: header bytes before chunk 0). */
export function chunkCipherRange(i, size, cb, offset = 0) {
  const start = offset + i * (cb + TAG_BYTES)
  const plain = Math.min(cb, size - i * cb)
  return [start, start + Math.max(0, plain) + TAG_BYTES - 1]
}
/** Chunks covering plaintext bytes start..end inclusive, and the ciphertext range to fetch. */
export function chunksForRange(start, end, size, cb, offset = 0) {
  const n = chunkCount(size, cb)
  const first = Math.floor(start / cb)
  const last = Math.min(n - 1, Math.floor(end / cb))
  return { first, last, cipherStart: chunkCipherRange(first, size, cb, offset)[0], cipherEnd: chunkCipherRange(last, size, cb, offset)[1] }
}

/**
 * Upload part n (1-based) of a stored object of `total` bytes cut into parts of
 * partBytes: which chunks overlap it and which slice of their concatenated
 * ciphertext it is. Chunk and part boundaries differ (chunks are cb + 16), so
 * a chunk can straddle two parts; it is sealed once for each, identically.
 */
export function partPlan(n, size, cb, partBytes) {
  const total = cipherSize(size, cb)
  const start = (n - 1) * partBytes
  const end = Math.min(total, n * partBytes) - 1
  if (start > end) throw new RangeError(`part ${n} is past the end`)
  const unit = cb + TAG_BYTES
  const first = Math.floor(start / unit)
  const last = Math.floor(end / unit)
  return { first, last, skip: start - first * unit, length: end - start + 1 }
}
export const partCount = (size, cb, partBytes) => Math.ceil(cipherSize(size, cb) / partBytes)

// ── 6.6 content: chunks ─────────────────────────────────────────────────────

export const chunkNonce = (prefix, i) => concat(prefix, u64be(i))
export const sealChunk = (key, prefix, i, last, plain, label = LABEL.CHUNK) =>
  S.crypto_aead_xchacha20poly1305_ietf_encrypt(plain, AD(label, i, last), null, chunkNonce(prefix, i), key)
export function openChunk(key, prefix, i, last, sealed, label = LABEL.CHUNK) {
  try {
    return S.crypto_aead_xchacha20poly1305_ietf_decrypt(null, sealed, AD(label, i, last), chunkNonce(prefix, i), key)
  } catch {
    return refuse(`chunk ${i} failed authentication`)
  }
}

/** base64(BLAKE2b-256 over all chunk tags in order) for the manifest. */
export const tagsDigest = (tags) => S.crypto_generichash(32, tags)

/**
 * Seals a Blob or Uint8Array chunk by chunk without holding it whole.
 * Yields { index, sealed }; `tags` fills in as it goes. Reads one chunk at a time.
 */
export async function* sealChunks(source, C, prefix, cb, label = LABEL.CHUNK) {
  const size = source.size ?? source.length
  const n = chunkCount(size, cb)
  for (let i = 0; i < n; i++) yield { index: i, sealed: sealChunk(C, prefix, i, i === n - 1, await readSlice(source, i * cb, Math.min(size, (i + 1) * cb)), label) }
}

async function readSlice(source, a, b) {
  if (source instanceof Uint8Array) return source.subarray(a, b)
  return new Uint8Array(await source.slice(a, b).arrayBuffer())
}

/**
 * The bytes of upload part n, sealed from `source` on demand: only the chunks
 * that overlap the part are read and sealed. onTag(i, tag) sees each chunk tag.
 */
export async function sealPart(n, source, C, prefix, cb, partBytes, onTag = () => {}) {
  const size = source.size ?? source.length
  const plan = partPlan(n, size, cb, partBytes)
  const nChunks = chunkCount(size, cb)
  const out = new Uint8Array(plan.length)
  let o = 0
  let skip = plan.skip
  for (let i = plan.first; i <= plan.last; i++) {
    const sealed = sealChunk(C, prefix, i, i === nChunks - 1, await readSlice(source, i * cb, Math.min(size, (i + 1) * cb)))
    onTag(i, sealed.subarray(sealed.length - TAG_BYTES))
    const take = sealed.subarray(skip, skip + (plan.length - o))
    out.set(take, o)
    o += take.length
    skip = 0
  }
  return out
}

/**
 * Opens plaintext bytes start..end (inclusive) from the ciphertext of chunks
 * first..last (as chunksForRange planned). Checks the length first and the
 * last flag on the final chunk.
 */
export function openRange(C, prefix, size, cb, start, end, sealed, label = LABEL.CHUNK) {
  const plan = chunksForRange(start, end, size, cb)
  if (sealed.length !== plan.cipherEnd - plan.cipherStart + 1) refuse('range response has the wrong length')
  const n = chunkCount(size, cb)
  const parts = []
  let o = 0
  for (let i = plan.first; i <= plan.last; i++) {
    const [a, b] = chunkCipherRange(i, size, cb)
    const plain = openChunk(C, prefix, i, i === n - 1, sealed.subarray(o, o + b - a + 1), label)
    o += b - a + 1
    const base = i * cb
    parts.push(plain.subarray(Math.max(0, start - base), Math.min(plain.length, end + 1 - base)))
  }
  return concat(...parts)
}

/** Opens a whole stored object against its manifest: lengths, every chunk, the last flag and tags. */
export function openWhole(C, manifest, stored) {
  const { size, chunk_bytes: cb, chunks } = manifest
  if (stored.length !== cipherSize(size, cb)) refuse('stored object has the wrong length')
  const out = new Uint8Array(size)
  const tags = new Uint8Array(chunks * TAG_BYTES)
  for (let i = 0; i < chunks; i++) {
    const [a, b] = chunkCipherRange(i, size, cb)
    const piece = stored.subarray(a, b + 1)
    out.set(openChunk(C, manifest.prefixBytes, i, i === chunks - 1, piece), i * cb)
    tags.set(piece.subarray(piece.length - TAG_BYTES), i * TAG_BYTES)
  }
  if (b64(tagsDigest(tags)) !== manifest.tags) refuse('chunk tags do not match the manifest')
  return out
}

// ── 6.6 manifest ────────────────────────────────────────────────────────────

export function buildManifest({ nodeId, versionId, size, chunkBytes, prefix, tags }) {
  return { chunk_bytes: chunkBytes, chunks: chunkCount(size, chunkBytes), node: nodeId, prefix: b64(prefix), size, tags: b64(tagsDigest(tags)), v: 1, version: versionId }
}
export const sealManifest = (Kv, manifest) => ENV(versionKeys(Kv).F, AD(LABEL.MANIFEST, manifest.node, manifest.version), jsonBytes(manifest))

/**
 * Opens and checks a manifest (6.6): the ids must be the ones asked for, and
 * size, chunk size, count and prefix come only from here. Returns the manifest
 * plus prefixBytes.
 */
export function openManifest(Kv, nodeId, versionId, sealed) {
  const m = parseJson(openENV(versionKeys(Kv).F, AD(LABEL.MANIFEST, nodeId, versionId), sealed))
  if (m.node !== nodeId || m.version !== versionId) refuse('manifest belongs to another version')
  if (m.v !== 1) refuse('unknown manifest version')
  const int = (x) => Number.isSafeInteger(x) && x >= 0
  if (!int(m.size) || !int(m.chunk_bytes) || m.chunk_bytes < 1 || !int(m.chunks)) refuse('manifest sizes are not integers')
  if (m.chunks !== chunkCount(m.size, m.chunk_bytes)) refuse('manifest chunk count does not match its size')
  let prefixBytes
  try { prefixBytes = unb64(m.prefix) } catch { refuse('manifest prefix is not base64') }
  if (prefixBytes.length !== 16) refuse('manifest prefix is not 16 bytes')
  if (typeof m.tags !== 'string' || unb64(m.tags).length !== 32) refuse('manifest tags are not 32 bytes')
  return { ...m, prefixBytes }
}

// ── 6.6 thumbnails and renditions ───────────────────────────────────────────

const DERIVED = {
  thumbnail: { key: 'T', label: LABEL.THUMB_CHUNK },
  rendition: { key: 'R', label: LABEL.RENDITION_CHUNK },
}

/** The stored thumbnail or rendition object: 29-byte header, then 1 MiB chunks under T or R. */
export function sealDerived(variant, Kv, plain, prefix = random(16)) {
  const { key, label } = DERIVED[variant]
  const K = versionKeys(Kv)[key]
  const n = chunkCount(plain.length, DERIVED_CHUNK)
  const chunks = []
  for (let i = 0; i < n; i++) chunks.push(sealChunk(K, prefix, i, i === n - 1, plain.subarray(i * DERIVED_CHUNK, (i + 1) * DERIVED_CHUNK), label))
  return concat(Uint8Array.of(0x01), prefix, u64be(plain.length), u32be(DERIVED_CHUNK), ...chunks)
}

export function derivedHeader(stored) {
  if (stored.length < DERIVED_HEADER) refuse('derived object shorter than its header')
  if (stored[0] !== 0x01) refuse('unknown derived object version')
  const dv = new DataView(stored.buffer, stored.byteOffset, DERIVED_HEADER)
  const size = dv.getBigUint64(17)
  if (size > BigInt(Number.MAX_SAFE_INTEGER)) refuse('derived object size out of range')
  const cb = dv.getUint32(25)
  if (cb < 1) refuse('derived object chunk size is zero')
  return { prefix: stored.slice(1, 17), size: Number(size), chunkBytes: cb }
}

export function openDerived(variant, Kv, stored) {
  const { key, label } = DERIVED[variant]
  const { prefix, size, chunkBytes } = derivedHeader(stored)
  const body = stored.subarray(DERIVED_HEADER)
  if (body.length !== cipherSize(size, chunkBytes)) refuse('derived object has the wrong length')
  return openRange(versionKeys(Kv)[key], prefix, size, chunkBytes, 0, Math.max(0, size - 1), body, label).subarray(0, size)
}

// ── 6.9 public link to one sealed file ──────────────────────────────────────

/**
 * pw_key, wrap_key and verifier for a link (6.9). Interpretation, reported:
 * salt and pw_key enter AD() as raw-bytes fields (u16be length || bytes);
 * 6.3 names only id, integer and flag fields. The password is its UTF-8.
 */
export function linkKeys({ secret, salt, password }) {
  const pwKey = password
    ? S.crypto_pwhash(32, utf8(password), salt, S.crypto_pwhash_OPSLIMIT_MODERATE, S.crypto_pwhash_MEMLIMIT_MODERATE, S.crypto_pwhash_ALG_ARGON2ID13)
    : new Uint8Array(32)
  const wrapKey = S.crypto_generichash(32, AD(LABEL.LINK_KEY, salt, pwKey), secret)
  const verifier = password ? S.crypto_generichash(32, utf8(LABEL.LINK_VERIFIER), pwKey) : null
  return { pwKey, wrapKey, verifier }
}

/** A new link's secrets: { secret (32), salt (16) }. The secret goes in the URL fragment, base64url. */
export const newLinkSecrets = () => ({ secret: random(32), salt: random(16) })

export const sealLinkPayload = (wrapKey, linkId, versionId, { Kv, mime, name }) =>
  ENV(wrapKey, AD(LABEL.LINK, linkId, versionId), jsonBytes({ k: b64(Kv), mime: mime ?? null, name }))
export function openLinkPayload(wrapKey, linkId, versionId, sealed) {
  const p = parseJson(openENV(wrapKey, AD(LABEL.LINK, linkId, versionId), sealed))
  const Kv = unb64(p.k || '')
  if (Kv.length !== 32) refuse('link key is not 32 bytes')
  return { Kv, mime: p.mime ?? null, name: p.name }
}

// ── 6.10 sealed pages ───────────────────────────────────────────────────────

export const sealPageSnapshot = (Ks, nodeId, e, seq, state) => ENV(scopeKeys(Ks).P, AD(LABEL.PAGE_SNAP, nodeId, e, seq), state)
export const openPageSnapshot = (Ks, nodeId, e, seq, sealed) => openENV(scopeKeys(Ks).P, AD(LABEL.PAGE_SNAP, nodeId, e, seq), sealed)
export const sealPageUpdate = (Ks, nodeId, e, seq, update) => ENV(scopeKeys(Ks).P, AD(LABEL.PAGE_UPDATE, nodeId, e, seq), update)
export const openPageUpdate = (Ks, nodeId, e, seq, sealed) => openENV(scopeKeys(Ks).P, AD(LABEL.PAGE_UPDATE, nodeId, e, seq), sealed)
export const sealAwareness = (Ks, nodeId, e, update) => ENV(scopeKeys(Ks).P, AD(LABEL.PAGE_AWARE, nodeId, e), update)
export const openAwareness = (Ks, nodeId, e, sealed) => openENV(scopeKeys(Ks).P, AD(LABEL.PAGE_AWARE, nodeId, e), sealed)

// ── 6.7 rotation, 6.8 re-wraps ──────────────────────────────────────────────

/**
 * The POST /scopes/:id/rotate body (6.7). holders: every key holder who stays,
 * [{ membership_id, public_key (bytes) }]; remove: membership ids (may be empty,
 * which clears rotation_due). Returns { body, key } where key is K_s[e + 1].
 */
export function buildRotation({ scopeId, epoch, Ks, remove, holders }) {
  const removed = new Set(remove)
  if (holders.some((h) => removed.has(h.membership_id))) throw new Error('a removed member cannot also hold the new key')
  const key = newKey()
  return {
    key,
    body: {
      remove: [...remove],
      epoch: epoch + 1,
      previous_key_wrapped: b64(wrapPreviousKey(key, scopeId, epoch + 1, Ks)),
      grants: holders.map((h) => ({ membership_id: h.membership_id, sealed_key: b64(sealGrant(key, h.public_key)) })),
    },
  }
}

/**
 * Copy inside a scope, or restore (a copy onto the same node): new ids, same
 * K_v, prefix and chunks, re-wrapped under the current epoch (6.8). The
 * manifest is re-sealed for the new ids. meta only for a copy.
 */
export function rewrapVersion({ Ks, Kv, manifest, nodeId, versionId, meta }) {
  const fresh = { ...manifest, node: nodeId, version: versionId }
  delete fresh.prefixBytes
  const out = {
    wrapped_key: b64(wrapVersionKey(Ks, nodeId, versionId, Kv)),
    manifest_ciphertext: b64(sealManifest(Kv, fresh)),
  }
  if (meta) out.metadata_ciphertext = b64(sealMeta(Ks, nodeId, meta))
  return out
}

/** Sealed scope to sealed scope (6.8): new metadata and version wraps under the target. Objects untouched. */
export function rewrapAcross({ fromKs, toKs, nodeId, metadata, versions }) {
  return {
    metadata_ciphertext: b64(sealMeta(toKs, nodeId, openMeta(fromKs, nodeId, metadata))),
    versions: versions.map((v) => ({ id: v.id, wrapped_key: b64(wrapVersionKey(toKs, nodeId, v.id, unwrapVersionKey(v.Ks || fromKs, nodeId, v.id, v.wrapped))) })),
  }
}
