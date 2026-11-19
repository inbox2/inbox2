// Pure parts of the Disk service worker (6.11): range parsing, request
// correlation, entry ownership, and agreement with crypto.js.
import { beforeAll, describe, expect, it, vi } from 'vitest'
import * as X from '../crypto'
import '../sw.js'

const W = globalThis.DiskSW
const VER = 'dvr_vvvvvvvvvvvvvvvvvvvvv'
const reg = (over = {}) => ({ version: VER, variant: 'content', key: new Uint8Array(32).fill(1), prefix: new Uint8Array(16).fill(2), size: 100, chunk_bytes: 16, mime: 'video/mp4', ...over })

beforeAll(() => X.init())

describe('range parsing', () => {
  it.each([
    [null, 100, { start: 0, end: 99, partial: false }],
    ['bytes=0-', 100, { start: 0, end: 99, partial: true }],
    ['bytes=10-19', 100, { start: 10, end: 19, partial: true }],
    ['bytes=90-500', 100, { start: 90, end: 99, partial: true }],
    ['bytes=-10', 100, { start: 90, end: 99, partial: true }],
    ['bytes=-500', 100, { start: 0, end: 99, partial: true }],
    ['bytes=100-', 100, null],
    ['bytes=20-10', 100, null],
    ['bytes=-0', 100, null],
    ['bytes=-', 100, null],
    ['bytes=0-1,5-6', 100, null],
    ['items=0-1', 100, null],
    ['bytes=0-', 0, null],
  ])('%s of %i', (h, size, want) => expect(W.parseRange(h, size)).toEqual(want))
})

describe('agrees with crypto.js', () => {
  it('range maths', () => {
    for (const [size, cb] of [[0, 16], [1, 16], [16, 16], [17, 16], [1000, 64], [5 * 1024 * 1024 + 3, 1024 * 1024]]) {
      expect(W.chunkCount(size, cb)).toBe(X.chunkCount(size, cb))
      for (let i = 0; i < X.chunkCount(size, cb); i++) for (const off of [0, 29]) expect(W.chunkCipherRange(i, size, cb, off)).toEqual(X.chunkCipherRange(i, size, cb, off))
    }
  })
  it('chunk AD and nonce, and opens what crypto.js sealed', async () => {
    const S = await X.init()
    expect(W.chunkAd('disk/chunk/v1', 5, true)).toEqual(X.AD('disk/chunk/v1', 5, true))
    const key = X.newKey()
    const prefix = X.newKey().subarray(0, 16)
    const ct = X.sealChunk(key, prefix, 3, false, X.utf8('abc'), X.LABEL.THUMB_CHUNK)
    expect(S.crypto_aead_xchacha20poly1305_ietf_decrypt(null, ct, W.chunkAd('disk/thumb/chunk/v1', 3, false), W.chunkNonce(prefix, 3), key)).toEqual(X.utf8('abc'))
  })
})

function setup() {
  const sent = []
  let n = 0
  const state = W.createState({ post: (clientId, msg) => sent.push({ clientId, msg }), randomId: () => `id${n++}` })
  return { state, sent }
}

describe('entries and correlation', () => {
  it('files a registration under the sender, never another client', () => {
    const { state } = setup()
    state.message('tabA', { register: reg() })
    expect(state.entry('tabA', VER, 'content')).toBeTruthy()
    expect(state.entry('tabB', VER, 'content')).toBeNull()
    state.message('tabA', { register: reg({ key: new Uint8Array(16) }) }) // not a 32-byte key
    state.message('tabA', { register: reg({ variant: 'other' }) })
    expect(state.size).toBe(1)
  })
  it('asks only the requesting client and accepts its reply once', async () => {
    const { state, sent } = setup()
    const p = state.ask('tabA', 'key', VER, 'content')
    expect(sent).toEqual([{ clientId: 'tabA', msg: { need: 'key', id: 'id0', version: VER, variant: 'content' } }])
    state.message('tabB', { reply: 'id0', register: reg() }) // another tab: dropped
    state.message('tabA', { reply: 'id0', register: reg({ variant: 'thumbnail' }) }) // not what was asked: dropped
    state.message('tabA', { reply: 'nope', register: reg() }) // unknown id
    expect(state.pendingCount).toBe(1)
    state.message('tabA', { reply: 'id0', register: reg() })
    expect((await p).version).toBe(VER)
    expect(state.entry('tabB', VER, 'content')).toBeNull()
    state.message('tabA', { reply: 'id0', register: reg({ size: 5 }) }) // replayed: no effect
    expect(state.entry('tabA', VER, 'content').size).toBe(100)
  })
  it('URL replies too, and times out to null', async () => {
    vi.useFakeTimers()
    const { state } = setup()
    const p = state.ask('tabA', 'url', VER, 'content')
    state.message('tabA', { reply: 'id0', url: 'https://s/x' })
    expect(await p).toBe('https://s/x')
    const late = state.ask('tabA', 'url', VER, 'content')
    vi.advanceTimersByTime(5000)
    expect(await late).toBeNull()
    expect(state.pendingCount).toBe(0)
    vi.useRealTimers()
  })
  it('drops entries of clients that went away', () => {
    const { state } = setup()
    state.message('tabA', { register: reg() })
    state.message('tabB', { register: reg() })
    state.keepOnly(new Set(['tabB']))
    expect(state.entry('tabA', VER, 'content')).toBeNull()
    expect(state.entry('tabB', VER, 'content')).toBeTruthy()
  })
  it('clear drops only the sender\'s entries and requests', async () => {
    const { state } = setup()
    state.message('tabA', { register: reg() })
    state.message('tabB', { register: reg() })
    const pa = state.ask('tabA', 'url', VER, 'content')
    const pb = state.ask('tabB', 'url', VER, 'content')
    state.message('tabB', { clear: true })
    expect(state.entry('tabB', VER, 'content')).toBeNull()
    expect(state.entry('tabA', VER, 'content')).toBeTruthy()
    expect(await pb).toBeNull()
    state.message('tabA', { reply: 'id0', url: 'https://s/x' })
    expect(await pa).toBe('https://s/x')
  })
  it('matches only sealed paths', () => {
    expect(W.SEALED_PATH.test(`/disk/sealed/${VER}/content`)).toBe(true)
    expect(W.SEALED_PATH.test(`/disk/sealed/${VER}/other`)).toBe(false)
    expect(W.SEALED_PATH.test('/acme/disk/c')).toBe(false)
  })
})

describe('exact-view broker', () => {
  const ENGINE = 'https://app.test/disk-engine.html'
  const make = () => { let n = 0; return W.createBroker({ newId: () => `k${n++}` }) }
  it('only a window at /disk-engine becomes the engine', () => {
    const b = make()
    expect(b.hello('tabX', 'https://app.test/acme/disk/c')).toBe(false)
    expect(b.engine).toBeNull()
    expect(b.hello('eng', ENGINE)).toBe(true)
    expect(b.engine).toBe('eng')
  })
  it('without an engine the asking tab gets a failure, nobody else', () => {
    expect(make().request('tabA', { id: 'r1', name: 'a.docx', bytes: new Uint8Array(1) })).toEqual(['tabA', { convertFailed: { id: 'r1', message: 'No exact-view window is open.', aborted: false } }])
  })
  it('forwards to the engine under its own id and returns the result to the asking tab only, once', () => {
    const b = make()
    b.hello('eng', ENGINE)
    const bytes = new Uint8Array([1, 2])
    const [to, msg] = b.request('tabA', { id: 'r1', name: 'a.docx', bytes })
    expect(to).toBe('eng')
    expect(msg.convert).toEqual({ id: 'k0', name: 'a.docx', bytes })
    const pdf = new Uint8Array([9])
    expect(b.result('tabB', { id: 'k0', pdf }, true)).toBeNull() // only the engine may answer
    expect(b.result('eng', { id: 'nope', pdf }, true)).toBeNull()
    expect(b.result('eng', { id: 'k0', pdf }, true)).toEqual(['tabA', { converted: { id: 'r1', pdf } }])
    expect(b.result('eng', { id: 'k0', pdf }, true)).toBeNull() // used once
  })
  it('cancels only the asking tab\'s request and fails pending ones when the engine goes', () => {
    const b = make()
    b.hello('eng', ENGINE)
    b.request('tabA', { id: 'r1', name: 'a', bytes: new Uint8Array(1) })
    b.request('tabB', { id: 'r2', name: 'b', bytes: new Uint8Array(1) })
    expect(b.cancel('tabB', 'r1')).toBeNull()
    expect(b.cancel('tabA', 'r1')).toEqual(['eng', { cancelConvert: 'k0' }])
    expect(b.keepOnly(new Set(['tabA', 'tabB']))).toEqual([
      ['tabA', { convertFailed: { id: 'r1', message: 'The exact-view window closed.', aborted: false } }],
      ['tabB', { convertFailed: { id: 'r2', message: 'The exact-view window closed.', aborted: false } }],
    ])
    expect(b.engine).toBeNull()
  })
})
