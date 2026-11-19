/* global sodium, ServiceWorkerGlobalScope */
// The Disk service worker (docs/plans/disk-build.md 6.11). A classic script:
// served as /disk-sw.js after libsodium (see vite.config.js diskServiceWorker),
// so no import or export here. It makes a sealed version look like an ordinary
// seekable URL, /disk/sealed/<version id>/<variant>, to the tab that owns it.
//
// - Keys arrive only from a page, filed under that page's client id (the message
//   event's source, never the body). They are C, T or R, never K_v or a scope key.
// - A fetch is served only from the requesting client's own entries.
// - When it lacks something it asks the requesting client alone, with a
//   one-use id, and waits 5 s at most (then 503).
// - Ciphertext URLs are used only on the configured storage origins.
// - It never sends key material in any message.
// - It also brokers exact-view conversions between a Disk tab and the engine
//   window, so file bytes never cross a BroadcastChannel (createBroker below).
//
// The pure parts sit on globalThis.DiskSW for the unit tests; the range maths
// repeats lib/disk/crypto.js (a classic worker cannot import it), and a test
// holds the two equal.

const TAG = 16
const HEADER = 29
const NEED_TIMEOUT_MS = 5000
const VARIANTS = {
  content: { label: 'disk/chunk/v1', offset: 0 },
  thumbnail: { label: 'disk/thumb/chunk/v1', offset: HEADER },
  rendition: { label: 'disk/rendition/chunk/v1', offset: HEADER },
}
const SEALED_PATH = /^\/disk\/sealed\/(dvr_[A-Za-z0-9_-]{21})\/(content|thumbnail|rendition)$/

const chunkCount = (size, cb) => Math.max(1, Math.ceil(size / cb))
function chunkCipherRange(i, size, cb, offset = 0) {
  const start = offset + i * (cb + TAG)
  return [start, start + Math.max(0, Math.min(cb, size - i * cb)) + TAG - 1]
}

/**
 * Range header -> { start, end, partial } or null for 416. No header means the
 * whole file. Accepts bytes=a-b, bytes=a- and bytes=-n; one range only.
 */
function parseRange(header, size) {
  if (header == null || header === '') return size ? { start: 0, end: size - 1, partial: false } : { start: 0, end: -1, partial: false }
  const m = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim())
  if (!m || (m[1] === '' && m[2] === '')) return null
  let start
  let end
  if (m[1] === '') {
    const n = Number(m[2])
    if (n === 0) return null
    start = Math.max(0, size - n)
    end = size - 1
  } else {
    start = Number(m[1])
    end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1)
  }
  if (!Number.isSafeInteger(start) || start >= size || end < start) return null
  return { start, end, partial: true }
}

function utf8(s) { return new TextEncoder().encode(s) }
function chunkAd(label, i, last) {
  const l = utf8(label)
  const out = new Uint8Array(l.length + 1 + 2 + 8 + 2 + 1)
  out.set(l, 0)
  let o = l.length + 1
  out[o + 1] = 8
  new DataView(out.buffer).setBigUint64(o + 2, BigInt(i))
  o += 10
  out[o + 1] = 1
  out[o + 2] = last ? 1 : 0
  return out
}
function chunkNonce(prefix, i) {
  const n = new Uint8Array(24)
  n.set(prefix)
  new DataView(n.buffer).setBigUint64(16, BigInt(i))
  return n
}

function validRegistration(r) {
  return !!r && typeof r.version === 'string' && VARIANTS[r.variant]
    && r.key instanceof Uint8Array && r.key.length === 32
    && r.prefix instanceof Uint8Array && r.prefix.length === 16
    && Number.isSafeInteger(r.size) && r.size >= 0
    && Number.isSafeInteger(r.chunk_bytes) && r.chunk_bytes > 0
}

/**
 * Entries per client and correlated requests. post(clientId, message) sends to
 * one client; randomId() makes the 16-byte hex request ids.
 */
function createState({ post, randomId, timeout = NEED_TIMEOUT_MS, setTimer = setTimeout, clearTimer = clearTimeout }) {
  const entries = new Map() // clientId -> Map("version/variant" -> entry)
  const pending = new Map() // request id -> { clientId, need, version, variant, done }
  const keyOf = (version, variant) => `${version}/${variant}`

  function file(clientId, r) {
    if (!clientId || !validRegistration(r)) return false
    if (!entries.has(clientId)) entries.set(clientId, new Map())
    entries.get(clientId).set(keyOf(r.version, r.variant), {
      version: r.version, variant: r.variant, key: r.key, prefix: r.prefix, size: r.size, chunk_bytes: r.chunk_bytes, mime: r.mime || 'application/octet-stream',
    })
    return true
  }

  return {
    entry: (clientId, version, variant) => entries.get(clientId)?.get(keyOf(version, variant)) || null,
    /** A message from a client: a registration, a reply, or clear. */
    message(sourceId, data) {
      if (!sourceId || !data || typeof data !== 'object') return
      // A tab's own sign-out, lock or revocation: only its entries go, never another tab's.
      if (data.clear) { this.forget(sourceId); return }
      if (data.register && data.reply == null) { file(sourceId, data.register); return }
      if (typeof data.reply !== 'string') return
      const p = pending.get(data.reply)
      if (!p || p.clientId !== sourceId) return // unknown id, or not the client asked: dropped
      if (p.need === 'key') {
        const r = data.register
        if (!r || r.version !== p.version || r.variant !== p.variant || !file(sourceId, r)) return
        pending.delete(data.reply)
        p.done(this.entry(sourceId, p.version, p.variant))
      } else {
        if (typeof data.url !== 'string') return
        pending.delete(data.reply)
        p.done(data.url)
      }
    },
    /** Asks the one client for a key or a URL; resolves null after the timeout. */
    ask(clientId, need, version, variant) {
      const id = randomId()
      return new Promise((resolve) => {
        const timer = setTimer(() => { pending.delete(id); resolve(null) }, timeout)
        pending.set(id, { clientId, need, version, variant, done: (v) => { clearTimer(timer); resolve(v) } })
        post(clientId, { need, id, version, variant })
      })
    },
    /** Drops one client's entries and fails its pending requests. */
    forget(clientId) {
      entries.delete(clientId)
      for (const [id, p] of pending) if (p.clientId === clientId) { pending.delete(id); p.done(null) }
    },
    /** Drops entries of clients that are gone. */
    keepOnly(liveIds) { for (const id of [...entries.keys()]) if (!liveIds.has(id)) entries.delete(id) },
    clear() {
      entries.clear()
      for (const [id, p] of pending) { pending.delete(id); p.done(null) }
    },
    get size() { return [...entries.values()].reduce((n, m) => n + m.size, 0) },
    get pendingCount() { return pending.size },
  }
}

// ── exact-view broker ───────────────────────────────────────────────────────
// Office bytes and the PDF made from them never cross a BroadcastChannel (any
// same-origin page could listen). A Disk tab hands the file to this worker; the
// worker forwards it to the one engine window (/disk-engine.html, a client like
// any other at scope "/") and hands the result back to the requesting tab only.
const ENGINE_PATH = /^\/disk-engine(\.html)?$/

function createBroker({ newId }) {
  let engine = null
  const pending = new Map() // our id -> { clientId, id (the tab's) }
  const failed = (clientId, id, message, aborted = false) => [clientId, { convertFailed: { id, message, aborted } }]
  return {
    get engine() { return engine },
    /** A window at /disk-engine(.html) becomes the engine; any other page is ignored. */
    hello(sourceId, url) {
      let path = ''
      try { path = new URL(url).pathname } catch { /* not a URL */ }
      if (!sourceId || !ENGINE_PATH.test(path)) return false
      engine = sourceId
      return true
    },
    /** A tab's { id, name, bytes }: [to, message] for the engine, or a failure back to the tab. */
    request(sourceId, req) {
      if (!sourceId || !req || typeof req.id !== 'string') return null
      if (!engine) return failed(sourceId, req.id, 'No exact-view window is open.')
      if (sourceId === engine) return null
      const key = newId()
      pending.set(key, { clientId: sourceId, id: req.id })
      return [engine, { convert: { id: key, name: req.name, bytes: req.bytes } }]
    },
    /** The engine's answer: only from the engine, only for a pending id, once, only to the tab that asked. */
    result(sourceId, res, ok) {
      if (!res || sourceId !== engine) return null
      const p = pending.get(res.id)
      if (!p) return null
      pending.delete(res.id)
      return ok ? [p.clientId, { converted: { id: p.id, pdf: res.pdf } }] : failed(p.clientId, p.id, res.message || 'Conversion failed', res.aborted)
    },
    cancel(sourceId, id) {
      for (const [key, p] of pending) if (p.clientId === sourceId && p.id === id) return engine ? [engine, { cancelConvert: key }] : null
      return null
    },
    /** Clients that went away: a gone engine fails every pending request; a gone tab's requests are dropped. */
    keepOnly(liveIds) {
      const out = []
      if (engine && !liveIds.has(engine)) {
        engine = null
        for (const [key, p] of pending) { pending.delete(key); out.push(failed(p.clientId, p.id, 'The exact-view window closed.')) }
      }
      for (const [key, p] of pending) if (!liveIds.has(p.clientId)) pending.delete(key)
      return out
    },
    get pendingCount() { return pending.size },
  }
}

globalThis.DiskSW = { parseRange, chunkCount, chunkCipherRange, chunkAd, chunkNonce, createState, createBroker, SEALED_PATH, VARIANTS, validRegistration }

// ── the worker itself ───────────────────────────────────────────────────────

if (typeof ServiceWorkerGlobalScope !== 'undefined' && self instanceof ServiceWorkerGlobalScope) {
  // Storage origins come from the registration URL (?storage=a,b), set by the app's config.
  const allowed = new Set((new URL(self.location.href).searchParams.get('storage') || '').split(',').filter(Boolean))
  const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
  const state = createState({
    post: (clientId, msg) => self.clients.get(clientId).then((c) => c?.postMessage(msg)),
    randomId: () => hex(self.crypto.getRandomValues(new Uint8Array(16))),
  })
  const broker = createBroker({ newId: () => hex(self.crypto.getRandomValues(new Uint8Array(16))) })
  // Sends to one client, moving any ArrayBuffer (bytes, pdf) instead of copying it.
  const send = async (route) => {
    if (!route) return
    const [to, msg] = route
    const c = await self.clients.get(to)
    const body = msg.convert || msg.converted
    const buf = body && (body.bytes || body.pdf)
    const transfer = buf && buf.buffer instanceof ArrayBuffer ? [buf.buffer] : buf instanceof ArrayBuffer ? [buf] : []
    c?.postMessage(msg, transfer)
  }
  const sweep = () => self.clients.matchAll({ includeUncontrolled: true }).then((all) => {
    const live = new Set(all.map((c) => c.id))
    state.keepOnly(live)
    broker.keepOnly(live).forEach(send)
  })
  // A restarted worker has forgotten the engine window: find it among the clients.
  const findEngine = async () => {
    if (broker.engine) return
    for (const c of await self.clients.matchAll({ type: 'window', includeUncontrolled: true })) if (broker.hello(c.id, c.url)) return
  }

  self.addEventListener('install', () => self.skipWaiting())
  self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()))
  self.addEventListener('message', (e) => {
    const sourceId = e.source && e.source.id
    const d = e.data
    if (d && typeof d === 'object') {
      if (d.engineHello) return void broker.hello(sourceId, e.source.url)
      if (d.convert) return e.waitUntil(findEngine().then(() => send(broker.request(sourceId, d.convert))))
      if (d.converted) return e.waitUntil(send(broker.result(sourceId, d.converted, true)))
      if (d.convertFailed) return e.waitUntil(send(broker.result(sourceId, d.convertFailed, false)))
      if (d.cancelConvert) return e.waitUntil(send(broker.cancel(sourceId, d.cancelConvert)))
    }
    state.message(sourceId, d)
  })
  self.addEventListener('fetch', (e) => {
    const url = new URL(e.request.url)
    if (url.origin !== self.location.origin) return
    const m = SEALED_PATH.exec(url.pathname)
    if (!m) return // everything else goes to the network untouched
    const clientId = e.clientId || e.resultingClientId
    e.respondWith(serve(clientId, m[1], m[2], e.request))
    e.waitUntil(sweep())
  })

  const fail = (status, text, headers) => new Response(text, { status, headers: { 'Cache-Control': 'no-store', ...headers } })

  async function serve(clientId, version, variant, req) {
    if (!clientId) return fail(503, 'no client')
    await sodium.ready
    let f = state.entry(clientId, version, variant)
    if (!f) f = await state.ask(clientId, 'key', version, variant) // a restarted worker asks for the key first
    if (!f) return fail(503, 'the page did not supply the key')
    const range = parseRange(req.headers.get('range'), f.size)
    if (!range) return fail(416, null, { 'Content-Range': `bytes */${f.size}` })
    const src = await state.ask(clientId, 'url', version, variant)
    if (!src) return fail(503, 'the page did not supply the address')
    let origin
    try { origin = new URL(src).origin } catch { origin = null }
    if (!origin || !allowed.has(origin)) return fail(503, 'address is not on the storage host')

    const { label, offset } = VARIANTS[variant]
    const cb = f.chunk_bytes
    const total = chunkCount(f.size, cb)
    let i = Math.floor(range.start / cb)
    let pos = range.start
    const body = new ReadableStream({
      async pull(ctl) {
        if (pos > range.end || f.size === 0) return ctl.close()
        const [a, b] = chunkCipherRange(i, f.size, cb, offset)
        let sealed
        try {
          const res = await fetch(src, { headers: { Range: `bytes=${a}-${b}` }, signal: req.signal, credentials: 'omit', referrerPolicy: 'no-referrer' })
          sealed = new Uint8Array(await res.arrayBuffer())
          if (res.status !== 206 || sealed.length !== b - a + 1) throw new Error('range response has the wrong length')
        } catch (err) { return ctl.error(err) }
        let plain
        try { plain = sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(null, sealed, chunkAd(label, i, i === total - 1), chunkNonce(f.prefix, i), f.key) } catch { return ctl.error(new Error(`chunk ${i} failed authentication`)) }
        const base = i * cb
        ctl.enqueue(plain.subarray(pos - base, Math.min(plain.length, range.end + 1 - base)))
        pos = base + plain.length
        i++
      },
    }, { highWaterMark: 1 })
    const length = Math.max(0, range.end - range.start + 1)
    const headers = { 'Content-Type': f.mime, 'Accept-Ranges': 'bytes', 'Content-Length': String(length), 'Cache-Control': 'no-store', 'Cross-Origin-Resource-Policy': 'same-origin' }
    if (range.partial) headers['Content-Range'] = `bytes ${range.start}-${range.end}/${f.size}`
    return new Response(length ? body : null, { status: range.partial ? 206 : 200, headers })
  }
}
