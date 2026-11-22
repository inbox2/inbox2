import { describe, expect, it, vi } from 'vitest'

vi.mock('../api', () => ({ default: { getToken: async () => 't' } }))
vi.mock('../e2eeStore', () => ({ identityKeys: () => null }))

const { statusLine, count } = await import('../diskFinder')

describe('Disk in Finder status line', () => {
  const on = { enabled: true, approved: true }

  it('walks the states in order of what the member must do', () => {
    expect(statusLine(null).text).toBe('Off')
    expect(statusLine({ enabled: true, approved: false }).tone).toBe('warn')
    expect(statusLine({ ...on, paused: true }).text).toBe('Paused')
    expect(statusLine({ ...on, last_error: 'signed out' }).text).toBe('Sign in again to keep your files up to date.')
    expect(statusLine({ ...on, last_error: 'storage full' }).tone).toBe('error')
    expect(statusLine({ ...on, last_error: 'offline: timed out', uploading: 4 }).text).toBe("No connection. 4 changes upload when you're back online.")
    expect(statusLine({ ...on, last_error: 'no permission: x' }).tone).toBe('error')
    expect(statusLine({ ...on, uploading: 1 }).text).toBe('Uploading 1 file')
    expect(statusLine(on)).toEqual({ tone: 'ok', text: 'Up to date' })
  })

  it('counts', () => {
    expect(count(1, 'file')).toBe('1 file')
    expect(count(3, 'file')).toBe('3 files')
  })
})
