import { describe, it, expect } from 'vitest'
import { fileType, extensionOf, typeForIcon, FILE_ICONS, GENERIC } from '../fileTypes'
import { pathSegments, formatPath, parsePath, nodeLabel, SEALED_PLACEHOLDER } from '../paths'
import { listingParams } from '../api'
import { sortNodes, matchesFilters, familyOf, hasActiveFilters, windowStart, EMPTY_FILTERS } from '../listing'
import { filesFromDataTransfer, filesFromInput } from '../dropFiles'

describe('fileTypes', () => {
  it('maps extensions case-insensitively', () => {
    expect(fileType({ name: 'Q4 plan.DOCX' })).toMatchObject({ icon: 'word', family: 'documents', preview: 'document' })
    expect(fileType({ name: 'assets.tar.gz' }).icon).toBe('archive')
    expect(fileType({ name: '.env' }).icon).toBe('config')
    expect(fileType({ name: 'hero.heic' })).toMatchObject({ icon: 'image', family: 'images', preview: 'image' })
  })

  it('applies per-extension preview overrides', () => {
    expect(fileType({ name: 'deck.key' })).toMatchObject({ icon: 'slides', preview: null })
    expect(fileType({ name: 'deck.pptx' }).preview).toBe('slides')
    expect(fileType({ name: 'schema.sql' })).toMatchObject({ icon: 'database', preview: 'text' })
  })

  it('falls back to MIME, then the MIME top-level type, then generic', () => {
    expect(fileType({ name: 'README', mime: 'text/markdown; charset=utf-8' }).icon).toBe('markdown')
    expect(fileType({ name: 'clip', mime: 'video/x-unknown' }).icon).toBe('video')
    expect(fileType({ name: 'blob.xyz', mime: 'application/octet-stream' })).toBe(GENERIC)
    expect(fileType()).toBe(GENERIC)
  })

  it('has the 35 file icons (39 with folder, shared, sealed and page)', () => {
    expect(FILE_ICONS).toHaveLength(35)
    expect(typeForIcon('link').label).toBe('Link')
    expect(extensionOf('noext')).toBe('')
  })
})

describe('paths', () => {
  const cAnc = [{ id: 'root', name: null, sealed: false }, { id: 'a', name: 'Projects', sealed: false }, { id: 'b', name: null, sealed: true }]

  it('builds C:\\ paths, skipping the nameless root and showing decrypted sealed names', () => {
    const segs = pathSegments('C', cAnc, { b: 'Q4' })
    expect(segs).toEqual([{ id: 'root', label: 'C:\\', drive: 'C' }, { id: 'a', label: 'Projects' }, { id: 'b', label: 'Q4' }])
    expect(formatPath(segs)).toBe('C:\\Projects\\Q4')
  })

  it('shows a placeholder for a sealed name not yet decrypted', () => {
    expect(pathSegments('C', cAnc).at(-1).label).toBe(SEALED_PLACEHOLDER)
  })

  it('builds D:\\ paths with the share root named', () => {
    const segs = pathSegments('D', [{ id: 's', name: 'Marketing', sealed: false }, { id: 'l', name: 'Launch 2026', sealed: false }])
    expect(segs[0]).toEqual({ id: null, label: 'D:\\', drive: 'D' })
    expect(formatPath(segs)).toBe('D:\\Marketing\\Launch 2026')
    expect(formatPath(pathSegments('D', []))).toBe('D:\\')
  })

  it('starts a grantee path at what was shared, not at a root', () => {
    const segs = pathSegments('C', [{ id: 'g', name: 'Contracts', sealed: false }])
    expect(segs[0]).toEqual({ id: null, label: 'C:\\', drive: 'C' })
    expect(formatPath(segs)).toBe('C:\\Contracts')
  })

  it('parses typed paths', () => {
    expect(parsePath('d:\\Marketing\\\\Launch 2026\\')).toEqual({ drive: 'D', names: ['Marketing', 'Launch 2026'] })
    expect(parsePath('C:\\')).toEqual({ drive: 'C', names: [] })
    expect(parsePath('Marketing/Launch')).toBeNull()
  })
})

describe('listing', () => {
  const now = Date.parse('2026-10-03T12:00:00')
  const ago = (days) => new Date(now - days * 86_400_000).toISOString()
  const n = (id, kind, name, size, days, by = 'u1', x = {}) => ({
    id, kind, name, size_bytes: size, content_modified_at: ago(days), modified_by: { id: by, name: by === 'u1' ? 'Sara' : 'Jonas' }, sealed: false, ...x,
  })
  const nodes = [
    n('f1', 'folder', 'Press kit', null, 1),
    n('p1', 'file', 'teaser.mp4', 84e6, 2),
    n('p2', 'file', 'podcast.mp3', 31e6, 7.5, 'u2'),
    n('p3', 'file', 'Brand guidelines.pdf', 4e6, 5),
    n('p4', 'page', 'Launch playbook', 0, 0),
    n('p5', 'file', 'Budget 2026.xlsx', 88e3, 2, 'u2', { sealed: true }),
    n('p6', 'file', 'file10.txt', 1, 40),
    n('p7', 'file', 'file9.txt', 1, 40),
  ]

  it('keeps folders first and sorts size largest first', () => {
    expect(sortNodes(nodes, 'size', -1).map((x) => x.id).slice(0, 4)).toEqual(['f1', 'p1', 'p2', 'p3'])
  })

  it('sorts names naturally and breaks ties by name', () => {
    const ids = sortNodes(nodes, 'name', 1).map((x) => x.id)
    expect(ids.indexOf('p7')).toBeLessThan(ids.indexOf('p6'))
    expect(sortNodes(nodes, 'by', 1).at(-1).modified_by.name).toBe('Sara')
  })

  it('classifies families', () => {
    expect(nodes.map(familyOf)).toEqual(['folders', 'media', 'media', 'documents', 'pages', 'sheets', 'documents', 'documents'])
  })

  it('combines Media and Last 7 days (spec F2)', () => {
    const f = { ...EMPTY_FILTERS, types: ['media'], modified: '7' }
    expect(nodes.filter((x) => matchesFilters(x, f, now)).map((x) => x.id)).toEqual(['p1'])
    expect(hasActiveFilters(f)).toBe(true)
    expect(hasActiveFilters(EMPTY_FILTERS)).toBe(false)
  })

  it('filters by query, person, sealed and today', () => {
    const pick = (f) => nodes.filter((x) => matchesFilters(x, { ...EMPTY_FILTERS, ...f }, now)).map((x) => x.id)
    expect(pick({ q: ' BRAND ' })).toEqual(['p3'])
    expect(pick({ by: 'u2' })).toEqual(['p2', 'p5'])
    expect(pick({ sealed: true })).toEqual(['p5'])
    expect(pick({ modified: 'today' })).toEqual(['p4'])
    expect(windowStart('', now)).toBeNull()
  })
})

describe('dropFiles', () => {
  const fileEntry = (name) => ({ isFile: true, name, file: (res) => res({ name }) })
  const dirEntry = (name, children) => {
    let done = false
    return {
      isFile: false, name,
      createReader: () => ({ readEntries: (res) => { res(done ? [] : children); done = true } }),
    }
  }

  it('flattens dropped folders into relative paths', async () => {
    const tree = dirEntry('Q4', [fileEntry('plan.docx'), dirEntry('Budget', [fileEntry('b.xlsx')])])
    const dt = { items: [{ kind: 'file', webkitGetAsEntry: () => tree }, { kind: 'file', webkitGetAsEntry: () => fileEntry('a.pdf') }] }
    const out = await filesFromDataTransfer(dt)
    expect(out.map((x) => x.relativePath)).toEqual(['Q4/plan.docx', 'Q4/Budget/b.xlsx', 'a.pdf'])
    expect(out[0].file).toEqual({ name: 'plan.docx' })
  })

  it('falls back to the FileList without entry support', async () => {
    const dt = { items: [{ kind: 'file' }], files: [{ name: 'x.png', webkitRelativePath: '' }] }
    expect(await filesFromDataTransfer(dt)).toEqual([{ file: dt.files[0], relativePath: 'x.png' }])
    expect(filesFromInput([{ name: 'y', webkitRelativePath: 'dir/y' }])[0].relativePath).toBe('dir/y')
  })
})

describe('api', () => {
  it('turns the FilterBar value into the children query', () => {
    expect(listingParams({ ...EMPTY_FILTERS, sort: 'size', dir: -1, types: ['media', 'images'], modified: '7', by: 'mem_1', sealed: true }))
      .toEqual({ sort: 'size', dir: 'desc', type: 'media,images', modified: '7d', by: 'mem_1', sealed: 'true' })
    expect(listingParams({ ...EMPTY_FILTERS, sort: 'name', dir: 1, modified: 'today' }, 'Europe/Amsterdam'))
      .toEqual({ sort: 'name', dir: 'asc', type: '', modified: 'today', tz: 'Europe/Amsterdam', by: '', sealed: '' })
    expect(listingParams({ ...EMPTY_FILTERS, sort: 'name', dir: 1 })).not.toHaveProperty('modified')
  })

  it('labels sealed nodes without a name', () => {
    expect(nodeLabel({ sealed: true, id: 'x', name: null })).toBe(SEALED_PLACEHOLDER)
    expect(nodeLabel({ sealed: true, id: 'x' }, { x: 'Q4' })).toBe('Q4')
    expect(nodeLabel({ sealed: false, name: 'a.pdf' })).toBe('a.pdf')
  })
})
