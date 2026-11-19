import { describe, it, expect, vi } from 'vitest'

// The console's mount: /console/ on the mail host (and dev, desktop), the root on console.inbox2.com.
describe('console host', () => {
  const load = async (hostname) => {
    vi.resetModules()
    vi.stubGlobal('window', { location: { hostname } })
    try { return await import('../consoleHost') } finally { vi.unstubAllGlobals() }
  }

  it('mail host: under /console', async () => {
    const c = await load('mail.inbox2.com')
    expect(c.CONSOLE_HOST).toBe(false)
    expect(c.consolePath()).toBe('/console')
    expect(c.consolePath('domains')).toBe('/console/domains')
    expect(c.isConsolePath('/console/people')).toBe(true)
    expect(c.isConsolePath('/domains')).toBe(false)
    expect(c.isConsolePath('/consoles')).toBe(false)
  })

  it('console host: at the root; /disk is the admin page, /disk/... is Disk', async () => {
    const c = await load('console.inbox2.com')
    expect(c.CONSOLE_HOST).toBe(true)
    expect(c.consolePath()).toBe('/')
    expect(c.consolePath('billing')).toBe('/billing')
    expect(['/', '/domains', '/domains/acme', '/team/o/m', '/disk', '/console/rules'].every(c.isConsolePath)).toBe(true)
    expect(c.isConsolePath('/disk/c/Clients-x')).toBe(false)
    expect(c.isConsolePath('/acme/mail')).toBe(false)
  })
})
