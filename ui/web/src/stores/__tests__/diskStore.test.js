import { describe, it, expect, vi } from 'vitest'

let answer
vi.mock('../../lib/disk/api', () => ({ default: { drives: vi.fn(() => new Promise((r) => { answer = r })) } }))
const { default: useDiskStore } = await import('../diskStore')

describe('diskStore guards', () => {
  it('drops a drives answer for an org that is no longer shown', async () => {
    const s = useDiskStore.getState()
    s.enterOrg('org_a')
    const pending = s.loadDrives('org_a')
    useDiskStore.getState().enterOrg('org_b')
    answer({ shares: ['from a'] })
    await pending
    expect(useDiskStore.getState().drives).toBe(null)
  })

  it('drops listing writes from before a reset', () => {
    const s = useDiskStore.getState()
    const ticket = s.ticket('org_b')
    s.reset()
    expect(useDiskStore.getState().setListing('k', { nodes: [1] }, { ticket })).toBe(false)
    expect(useDiskStore.getState().listings.k).toBeUndefined()
  })

  it('drops a "load more" page fetched before the first page was reloaded', () => {
    const s = useDiskStore.getState()
    s.setListing('f', { nodes: ['a', 'b'], next_cursor: '2' })
    const gen = useDiskStore.getState().listings.f.gen
    s.setListing('f', { nodes: ['a', 'x', 'b'], next_cursor: '3' }) // a write revalidated page one
    expect(s.setListing('f', { nodes: ['c'] }, { append: true, gen })).toBe(false)
    expect(useDiskStore.getState().listings.f.nodes).toEqual(['a', 'x', 'b'])
    const now = useDiskStore.getState().listings.f.gen
    expect(s.setListing('f', { nodes: ['c'], next_cursor: null }, { append: true, gen: now })).toBe(true)
    expect(useDiskStore.getState().listings.f.nodes).toEqual(['a', 'x', 'b', 'c'])
  })
})
