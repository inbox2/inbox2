import { describe, it, expect, vi } from 'vitest'
import { AUTH_SIGNED_IN, AUTH_SIGNED_OUT, announceAuth, onAuthBroadcast, reactionTo } from '../authBroadcast'

describe('reactionTo', () => {
  const me = { userId: 'usr_1', signedOut: false }
  it('signs a tab out when its account signs out elsewhere', () => {
    expect(reactionTo(me, { kind: AUTH_SIGNED_OUT, userId: 'usr_1' })).toBe('sign-out')
    expect(reactionTo(me, { kind: AUTH_SIGNED_OUT, userId: null })).toBe('sign-out')
  })
  it('ignores another account signing out, a second sign-out, and tabs with nobody signed in', () => {
    expect(reactionTo(me, { kind: AUTH_SIGNED_OUT, userId: 'usr_2' })).toBe('ignore')
    expect(reactionTo({ ...me, signedOut: true }, { kind: AUTH_SIGNED_OUT, userId: 'usr_1' })).toBe('ignore')
    expect(reactionTo({ userId: null, signedOut: false }, { kind: AUTH_SIGNED_OUT, userId: 'usr_1' })).toBe('ignore')
    expect(reactionTo({ userId: null, signedOut: false }, { kind: AUTH_SIGNED_IN, userId: 'usr_1' })).toBe('ignore')
  })
  it('resumes when the same account signs in again, reloads for another account', () => {
    expect(reactionTo({ ...me, signedOut: true }, { kind: AUTH_SIGNED_IN, userId: 'usr_1' })).toBe('resume')
    expect(reactionTo(me, { kind: AUTH_SIGNED_IN, userId: 'usr_1' })).toBe('ignore')
    expect(reactionTo({ ...me, signedOut: true }, { kind: AUTH_SIGNED_IN, userId: 'usr_2' })).toBe('reload')
    expect(reactionTo(me, { kind: AUTH_SIGNED_IN, userId: 'usr_2' })).toBe('reload')
  })
})

describe('announceAuth / onAuthBroadcast', () => {
  it('carries only the kind and the user id to another tab, and drops anything else', async () => {
    const other = new BroadcastChannel('inbox2-auth')
    const raw = []
    other.onmessage = ({ data }) => raw.push(data)
    announceAuth(AUTH_SIGNED_OUT, 'usr_1')
    announceAuth('token', 'secret')
    await vi.waitFor(() => expect(raw).toHaveLength(1))
    expect(raw[0]).toEqual({ kind: AUTH_SIGNED_OUT, userId: 'usr_1' })

    const got = []
    const off = onAuthBroadcast((m) => got.push(m))
    other.postMessage({ kind: AUTH_SIGNED_IN, userId: 'usr_2', token: 'x' })
    other.postMessage({ kind: 'nonsense' })
    await vi.waitFor(() => expect(got).toHaveLength(1))
    expect(got[0]).toEqual({ kind: AUTH_SIGNED_IN, userId: 'usr_2' })
    off()
    other.close()
  })
})
