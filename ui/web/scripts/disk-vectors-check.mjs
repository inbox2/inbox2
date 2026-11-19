// Independent check of the sealed Disk vectors (spec F7b: "opens with an
// independent script"). Written only from docs/plans/disk-build.md section 6,
// sharing no code with src/lib/disk/crypto.js: libsodium and Node Buffers only.
//   node scripts/disk-vectors-check.mjs [path/to/vectors.json]
import fs from 'node:fs'
import sodium from 'libsodium-wrappers-sumo'

await sodium.ready
const file = process.argv[2] || new URL('../src/lib/disk/__tests__/vectors.json', import.meta.url)
const { vectors } = JSON.parse(fs.readFileSync(file, 'utf8'))
const H = (h) => Buffer.from(h, 'hex')
const hex = (b) => Buffer.from(b).toString('hex')

// 6.3: u64be, AD, KDF, ENV, sorted compact JSON.
const be64 = (n) => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n)); return b }
const be32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b }
const lp = (b) => { const l = Buffer.alloc(2); l.writeUInt16BE(b.length); return Buffer.concat([l, b]) }
const ad = (label, ...fields) => Buffer.concat([Buffer.from(label, 'utf8'), Buffer.from([0]), ...fields.map(lp)])
const id = (s) => Buffer.from(s, 'utf8')
const int = be64
const flag = (f) => Buffer.from([f ? 1 : 0])
const kdf = (key, label) => sodium.crypto_generichash(32, Buffer.from(label, 'utf8'), key)
const env = (key, a, pt, nonce) => Buffer.concat([Buffer.from([1]), nonce, sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(pt, a, null, nonce, key)])
const openEnv = (key, a, e) => {
  if (e[0] !== 1 || e.length < 41) throw new Error('bad envelope')
  return sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(null, e.subarray(25), a, e.subarray(1, 25), key)
}
const sorted = (v) => (Array.isArray(v) ? v.map(sorted) : v && typeof v === 'object' ? Object.keys(v).sort().reduce((o, k) => ((o[k] = sorted(v[k])), o), {}) : v)
const json = (v) => Buffer.from(JSON.stringify(sorted(v)), 'utf8')
const b64 = (b) => Buffer.from(b).toString('base64')

const chunk = (key, prefix, i, last, pt, label = 'disk/chunk/v1') =>
  sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(pt, ad(label, int(i), flag(last)), null, Buffer.concat([prefix, be64(i)]), key)
function chunked(key, prefix, pt, cb, label) {
  const n = Math.max(1, Math.ceil(pt.length / cb))
  return Array.from({ length: n }, (_, i) => Buffer.from(chunk(key, prefix, i, i === n - 1, pt.subarray(i * cb, (i + 1) * cb), label)))
}

const checks = {
  AD: ({ label, fields }) => ({ ad: hex(ad(label, ...fields.map((f) => ('id' in f ? id(f.id) : 'int' in f ? int(f.int) : 'flag' in f ? flag(f.flag) : H(f.bytes))))) }),
  KDF: ({ key, label }) => ({ out: hex(kdf(H(key), label)) }),
  'scope keys': ({ Ks }) => Object.fromEntries([['E', 'epoch'], ['M', 'meta'], ['W', 'wrap'], ['P', 'page']].map(([k, l]) => [k, hex(kdf(H(Ks), `disk/${l}/v1`))])),
  'version keys': ({ Kv }) => Object.fromEntries([['C', 'content'], ['F', 'manifest'], ['T', 'thumb'], ['R', 'rendition']].map(([k, l]) => [k, hex(kdf(H(Kv), `disk/${l}/v1`))])),
  ENV: ({ key, ad: a, plaintext, nonce }) => {
    const e = env(H(key), H(a), H(plaintext), H(nonce))
    if (hex(openEnv(H(key), H(a), e)) !== plaintext) throw new Error('ENV does not open')
    return { env: hex(e) }
  },
  'key grant (open)': ({ identitySeed, sealed }) => {
    const kp = sodium.crypto_box_seed_keypair(H(identitySeed))
    return { Ks: hex(sodium.crypto_box_seal_open(H(sealed), kp.publicKey, kp.privateKey)) }
  },
  'epoch chain': ({ scope, epoch, Ks, previous, nonce }) => {
    const E = kdf(H(Ks), 'disk/epoch/v1')
    const w = env(E, ad('disk/epoch/v1', id(scope), int(epoch - 1)), H(previous), H(nonce))
    if (hex(openEnv(E, ad('disk/epoch/v1', id(scope), int(epoch - 1)), w)) !== previous) throw new Error('chain does not walk back')
    return { previous_key_wrapped: hex(w) }
  },
  metadata: ({ Ks, node, meta, nonce }) => {
    const j = json({ mime: meta.mime, name: meta.name })
    return { json: j.toString('utf8'), metadata_ciphertext: hex(env(kdf(H(Ks), 'disk/meta/v1'), ad('disk/meta/v1', id(node)), j, H(nonce))) }
  },
  'version key wrap': ({ Ks, node, version, Kv, nonce }) => ({ wrapped_key: hex(env(kdf(H(Ks), 'disk/wrap/v1'), ad('disk/wrap/v1', id(node), id(version)), H(Kv), H(nonce))) }),
  'content chunks': ({ Kv, prefix, chunk_bytes, plaintext }) => {
    const cs = chunked(kdf(H(Kv), 'disk/content/v1'), H(prefix), H(plaintext), chunk_bytes)
    return { chunks: cs.map(hex), object: hex(Buffer.concat(cs)) }
  },
  'empty file': ({ Kv, prefix, chunk_bytes }) => ({ object: hex(Buffer.concat(chunked(kdf(H(Kv), 'disk/content/v1'), H(prefix), Buffer.alloc(0), chunk_bytes))) }),
  manifest: ({ Kv, node, version, nonce, object }, all) => {
    const c = all['content chunks'].inputs
    const obj = H(object)
    const n = Math.max(1, Math.ceil(H(c.plaintext).length / c.chunk_bytes))
    const tags = Buffer.concat(Array.from({ length: n }, (_, i) => {
      const end = Math.min(obj.length, (i + 1) * (c.chunk_bytes + 16))
      return obj.subarray(end - 16, end)
    }))
    const m = { chunk_bytes: c.chunk_bytes, chunks: n, node, prefix: b64(H(c.prefix)), size: H(c.plaintext).length, tags: b64(sodium.crypto_generichash(32, tags)), v: 1, version }
    const j = json(m)
    return { json: j.toString('utf8'), manifest_ciphertext: hex(env(kdf(H(Kv), 'disk/manifest/v1'), ad('disk/manifest/v1', id(node), id(version)), j, H(nonce))) }
  },
  'thumbnail object': ({ Kv, prefix, plaintext }) => {
    const pt = H(plaintext)
    const MiB = 1024 * 1024
    const head = Buffer.concat([Buffer.from([1]), H(prefix), be64(pt.length), be32(MiB)])
    return { object: hex(Buffer.concat([head, ...chunked(kdf(H(Kv), 'disk/thumb/v1'), H(prefix), pt, MiB, 'disk/thumb/chunk/v1')])) }
  },
  'page snapshot': ({ Ks, node, epoch, seq, state, nonce }) => ({ sealed_snapshot: hex(env(kdf(H(Ks), 'disk/page/v1'), ad('disk/page/snap/v1', id(node), int(epoch), int(seq)), H(state), H(nonce))) }),
  'page update': ({ Ks, node, epoch, seq, update, nonce }) => ({ sealed_update: hex(env(kdf(H(Ks), 'disk/page/v1'), ad('disk/page/update/v1', id(node), int(epoch), int(seq)), H(update), H(nonce))) }),
  'page awareness': ({ Ks, node, epoch, update, nonce }) => ({ sealed_awareness: hex(env(kdf(H(Ks), 'disk/page/v1'), ad('disk/page/aware/v1', id(node), int(epoch)), H(update), H(nonce))) }),
}
function link({ secret, secret_b64url, salt, password, link: linkId, version, Kv, name, mime, nonce }) {
  if (Buffer.from(secret_b64url, 'base64url').toString('hex') !== secret) throw new Error('secret base64url differs')
  const pw = password
    ? Buffer.from(sodium.crypto_pwhash(32, Buffer.from(password, 'utf8'), H(salt), sodium.crypto_pwhash_OPSLIMIT_MODERATE, sodium.crypto_pwhash_MEMLIMIT_MODERATE, sodium.crypto_pwhash_ALG_ARGON2ID13))
    : Buffer.alloc(32)
  const wrap = sodium.crypto_generichash(32, ad('disk/link/key/v1', H(salt), pw), H(secret))
  return {
    pw_key: hex(pw),
    wrap_key: hex(wrap),
    verifier: password ? hex(sodium.crypto_generichash(32, Buffer.from('disk/link/verifier/v1', 'utf8'), pw)) : null,
    wrapped_payload: hex(env(wrap, ad('disk/link/v1', id(linkId), id(version)), json({ k: b64(H(Kv)), mime, name }), H(nonce))),
  }
}
checks['link without password'] = link
checks['link with password'] = link

const all = Object.fromEntries(vectors.map((v) => [v.name, v]))
let failed = 0
for (const v of vectors) {
  const fn = checks[v.name]
  const got = fn ? fn(v.inputs, all) : null
  const ok = got && JSON.stringify(got) === JSON.stringify(v.expected)
  if (!ok) failed++
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${v.name}${fn ? '' : ' (no independent check)'}`)
}
const required = ['AD', 'KDF', 'ENV', 'key grant (open)', 'epoch chain', 'metadata', 'version key wrap', 'content chunks', 'empty file', 'manifest', 'thumbnail object', 'link without password', 'link with password', 'page snapshot', 'page update']
const missing = required.filter((n) => !all[n])
if (missing.length) { failed++; console.log(`FAIL missing vectors: ${missing.join(', ')}`) }
console.log(failed ? `${failed} failed` : `all ${vectors.length} vectors reproduced`)
process.exit(failed ? 1 : 0)
