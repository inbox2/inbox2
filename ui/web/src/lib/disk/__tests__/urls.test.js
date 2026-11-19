import { describe, it, expect, vi } from 'vitest'
import {
  crumbUrl, diskOrg, findOrgWith, idSegment, idFromSegment, pathUrl, nodeUrl, previewUrl, parseDiskPath, tokenFromLinkPath, shortId, sameNode, shareRoot, VIEWS, DRIVE_SEGMENT, SHARED_SEGMENT,
} from '../model'

const sid = (c) => c.repeat(21)
const A = sid('A')
const B = 'x-y_z-0123456789abcde' // nanoid characters include - and _
const croot = { id: `dnd_${sid('R')}`, short_id: sid('R'), name: null, sealed: false, kind: 'folder', share_slug: null }
const mroot = { id: `dnd_${sid('M')}`, short_id: sid('M'), name: 'Marketing', sealed: false, kind: 'folder', share_slug: 'marketing' }
const n = (short, name, x = {}) => ({ id: `dnd_${short}`, short_id: short, name, sealed: false, kind: 'folder', ...x })
const after = (url) => url.replace(/^\/disk\/?/, '')

describe('ids in segments', () => {
  it('takes the last 21 characters, never splitting on "-"', () => {
    expect(idFromSegment(`Logos-${A}`)).toBe(A)
    expect(idFromSegment(`Logos-${B}`)).toBe(B)
    expect(idFromSegment(B)).toBe(B)
    expect(idFromSegment(`report-2026-${B}`)).toBe(B)
  })
  it('a name that itself ends in id-like text still yields the real id', () => {
    const name = `copy of ${sid('Q')}`
    expect(idFromSegment(idSegment(n(B, name)))).toBe(B)
    expect(idFromSegment(`${sid('Z')}-${A}`)).toBe(A)
  })
  it('refuses segments without an id', () => {
    expect(idFromSegment('Logos')).toBe(null)
    expect(idFromSegment(`x${A}`)).toBe(null)
    expect(idFromSegment('a b-c'.repeat(5))).toBe(null)
  })
  it('compares nodes by short id, whether given a key or a short id', () => {
    expect(shortId(`dnd_${A}`)).toBe(A)
    expect(sameNode(`dnd_${A}`, A)).toBe(true)
    expect(sameNode({ short_id: A }, `dnd_${A}`)).toBe(true)
  })
  it('never names a sealed item', () => {
    expect(idSegment(n(A, null, { sealed: true }))).toBe(`sealed-${A}`)
  })
})

describe('building and parsing', () => {
  it('round-trips C:\\ paths', () => {
    const url = pathUrl([croot, n(sid('C'), 'Clients'), n(A, 'Invoices 2026')])
    expect(url).toBe(`/disk/c/Clients/Invoices%202026-${A}`)
    expect(parseDiskPath(after(url))).toEqual({ drive: 'C', id: A })
    expect(pathUrl([croot])).toBe('/disk/c')
    expect(parseDiskPath('c')).toEqual({ drive: 'C', root: true })
  })

  it('round-trips share paths by the share slug', () => {
    expect(pathUrl([mroot])).toBe('/disk/d/marketing')
    expect(parseDiskPath('d/marketing')).toEqual({ drive: 'D', letter: 'D', shareSlug: 'marketing' })
    const url = pathUrl([mroot, n(sid('B'), 'Brand'), n(B, 'Logos')])
    expect(url).toBe(`/disk/d/marketing/Brand/Logos-${B}`)
    expect(parseDiskPath(after(url))).toEqual({ drive: 'D', letter: 'D', id: B })
    expect(pathUrl([shareRoot({ root_node_id: `dnd_${sid('M')}`, name: 'Marketing', slug: 'marketing' })])).toBe('/disk/d/marketing')
  })

  it('encodes spaces, slashes, unicode and dots, and decodes them back', () => {
    for (const name of ['Q4 plan: 50% done', 'Café ünïcode', 'a.b.c', '..', '#hash?query']) {
      const url = pathUrl([croot, n(A, name)])
      expect(url).not.toMatch(/[ #?%](?![0-9A-F]{2})/)
      expect(parseDiskPath(after(url))).toEqual({ drive: 'C', id: A })
    }
  })

  it('a stale path still resolves by its id', () => {
    expect(parseDiskPath(`d/old-share/Gone/Renamed-${A}`)).toEqual({ drive: 'D', letter: 'D', id: A })
    expect(parseDiskPath(`c/anything/at/all-${B}`)).toEqual({ drive: 'C', id: B })
  })

  it('an item reached only through a grant is /shared/<name>-<id>', () => {
    const url = pathUrl([n(sid('G'), 'Contracts'), n(A, 'x')])
    expect(url).toBe(`/disk/shared/x-${A}`)
    expect(parseDiskPath(after(url))).toEqual({ id: A })
    expect(nodeUrl(n(B, 'a.pdf', { kind: 'file' }))).toBe(`/disk/shared/a.pdf-${B}`)
  })

  it('previews a file on its folder', () => {
    expect(previewUrl('/disk/d/marketing', n(A, 'Brand guide.pdf'))).toBe(`/disk/d/marketing?open=Brand%20guide.pdf-${A}`)
  })

  it('sends each breadcrumb to its folder', () => {
    const p = [croot, n(sid('C'), 'Clients'), n(A, 'Invoices')]
    expect(crumbUrl('C', p, 0)).toBe('/disk/c')
    expect(crumbUrl('C', p, 1)).toBe(`/disk/c/Clients-${sid('C')}`)
    expect(crumbUrl('C', p, 2)).toBe(`/disk/c/Clients/Invoices-${A}`)
    expect(crumbUrl('D', [mroot, n(A, 'Brand')], 0)).toBe('/disk/d')
    expect(crumbUrl('D', [mroot, n(A, 'Brand')], 1)).toBe('/disk/d/marketing')
  })

  it('keeps views, drives and /shared/ apart; the old /f/ route is gone', () => {
    const slugs = VIEWS.map((v) => v.slug)
    for (const reserved of [DRIVE_SEGMENT.C, DRIVE_SEGMENT.D, SHARED_SEGMENT]) expect(slugs).not.toContain(reserved)
    expect(parseDiskPath('shared-with-me')).toEqual({ view: 'shared-with-me' })
    expect(parseDiskPath('shared')).toEqual({ notFound: true })
    expect(parseDiskPath('recent')).toEqual({ view: 'recent' })
    expect(parseDiskPath('')).toEqual({ redirect: 'c' })
    expect(parseDiskPath('d')).toEqual({ drive: 'D', letter: 'D', overview: true })
    // One letter per team (2026-10-07): E:\ is the person's second team; the letter rides along for diskOrg.
    expect(parseDiskPath('e/finance')).toEqual({ drive: 'D', letter: 'E', shareSlug: 'finance' })
    expect(parseDiskPath('E')).toEqual({ drive: 'D', letter: 'E', overview: true })
    // f is a drive letter now, so the never-shipped /f/<id> form reads as a share slug on F:\ (and 404s there).
    expect(parseDiskPath(`f/${A}`)).toEqual({ drive: 'D', letter: 'F', shareSlug: A })
    expect(parseDiskPath('c/NoIdHere')).toEqual({ notFound: true })
    // The service worker's /disk/sealed/ prefix is never a Disk page.
    expect(parseDiskPath(`sealed/dvr_${A}/content`)).toEqual({ notFound: true })
  })

  it('reads the token from either link shape', () => {
    expect(tokenFromLinkPath('q4-plan', 'tok')).toBe('tok')
    expect(tokenFromLinkPath('tok', undefined)).toBe('tok')
  })
})

describe('import route', async () => {
  const { parseDiskPath } = await import('../model')
  it('parses /disk/import', () => {
    expect(parseDiskPath('import')).toEqual({ imports: true })
    expect(parseDiskPath('import/x')).toEqual({ notFound: true })
  })
})

describe('which org Disk is on', () => {
  const acme = { id: 'org_a', slug: 'acme', name: 'Acme', domains: [{ slug: 'acme-com' }] }
  const beta = { id: 'org_b', slug: 'beta', name: 'Beta', domains: [] }
  const orgs = [acme, beta]
  it('takes the wanted org (slug, domain slug or id) when the person belongs to it, else the current, else the first', () => {
    expect(diskOrg(orgs, 'beta', acme)).toBe(beta)
    expect(diskOrg(orgs, 'acme-com', beta)).toBe(acme)
    expect(diskOrg(orgs, 'org_b', null)).toBe(beta)
    expect(diskOrg(orgs, 'someone-else', beta)).toBe(beta)
    expect(diskOrg(orgs, null, null)).toBe(acme)
    expect(diskOrg([], 'acme', null)).toBe(null)
  })
  it('looks for a node in the other orgs, skipping the current one and orgs that refuse', async () => {
    const asked = []
    const has = async (o) => { asked.push(o.id); if (o.id === 'org_x') throw new Error('403'); return o.id === 'org_b' }
    expect(await findOrgWith([acme, { id: 'org_x' }, beta], 'org_a', has)).toBe(beta)
    expect(asked).toEqual(['org_x', 'org_b'])
    expect(await findOrgWith(orgs, 'org_a', async () => false)).toBe(null)
  })
})

describe('the mount: /disk/ on the mail host, the root on disk.inbox2.com', () => {
  const load = async (hostname) => {
    vi.resetModules()
    vi.stubGlobal('window', { location: { hostname } })
    try { return await import('../model') } finally { vi.unstubAllGlobals() }
  }
  it('mail host: under /disk', async () => {
    const m = await load('mail.inbox2.com')
    expect(m.diskPath('c')).toBe('/disk/c')
    expect(m.diskPath()).toBe('/disk')
    expect(m.diskSplat('/disk/c/Clients-x')).toBe('c/Clients-x')
    expect(m.isDiskPath('/disk/recent')).toBe(true)
    expect(m.isDiskPath('/c')).toBe(false)
    expect(m.isDiskPath('/diskette/mail')).toBe(false)
  })
  it('disk host: at the root, an old /disk/ path still parses', async () => {
    const m = await load('disk.inbox2.com')
    expect(m.diskPath('c')).toBe('/c')
    expect(m.diskPath()).toBe('/')
    expect(m.pathUrl([croot, n(A, 'Clients')])).toBe(`/c/Clients-${A}`)
    expect(m.diskSplat('/d/marketing')).toBe('d/marketing')
    expect(m.diskSplat('/disk/d/marketing')).toBe('d/marketing')
    expect(m.parseDiskPath(m.diskSplat('/'))).toEqual({ redirect: 'c' })
    expect(['/', '/c', '/d/x', '/shared/x', '/recent', '/import'].every(m.isDiskPath)).toBe(true)
    expect(m.isDiskPath('/acme/mail')).toBe(false)
  })
})
