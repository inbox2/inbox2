import { create } from 'zustand'
import diskApi from '../lib/disk/api'

// Disk client state (docs/plans/disk-build.md section 3, Loading).
//   drives    GET /disk: C:\ root, visible shares, quota
//   listings  key -> { nodes, count, total, nextCursor, gen }; a key is one source
//             (a folder with its sort and filters, a view, a search). gen counts
//             first-page loads, so a "load more" page fetched before a reload is dropped.
//   lastKey   the listing shown last, kept on screen (dimmed) while the next loads
//   rev       bumped after a write; open listings revalidate in place
//   epoch     bumped when the org changes or the store is reset: a request started
//             before that lands nowhere (every async write checks it)
// ponytail: listings are never evicted; cap them if a session browses thousands of folders.
const useDiskStore = create((set, get) => ({
  orgId: null,
  epoch: 0,
  drives: null,
  drivesError: null,
  listings: {},
  errors: {},
  pending: {},
  details: {},
  lastKey: null,
  rev: 0,

  /** A token for an async write: { org, epoch }. Pass it back to the setters. */
  ticket(org) {
    return { org, epoch: get().epoch }
  },
  /** Whether a request started with this ticket may still write. */
  current(t) {
    return !t || (t.epoch === get().epoch && (!t.org || !get().orgId || t.org === get().orgId))
  },

  async loadDrives(org) {
    const t = get().ticket(org)
    try {
      const drives = await diskApi.drives(org)
      if (get().current(t)) set({ drives, drivesError: null })
    } catch (e) {
      if (get().current(t)) set({ drivesError: e })
    }
  },

  // GET /nodes/:id: the node with its visible path and my access. { node } | { error }
  async loadDetail(org, id) {
    const t = get().ticket(org)
    try {
      const { node } = await diskApi.node(org, id)
      if (get().current(t)) set((s) => ({ details: { ...s.details, [id]: { node } } }))
    } catch (error) {
      if (get().current(t)) set((s) => ({ details: { ...s.details, [id]: { error } } }))
    }
  },

  setPending(key, on, t) {
    if (!get().current(t)) return
    set((s) => ({ pending: { ...s.pending, [key]: on } }))
  },

  /**
   * A first page replaces the listing and starts a new generation; an appended
   * page only lands when it was fetched for the generation still shown (`gen`).
   */
  setListing(key, data, { append = false, gen, ticket } = {}) {
    if (!get().current(ticket)) return false
    const prev = get().listings[key]
    if (append && (!prev || prev.gen !== gen)) return false
    const nodes = append ? [...prev.nodes, ...data.nodes] : data.nodes
    const nextGen = append ? prev.gen : (prev?.gen || 0) + 1
    set((s) => ({
      listings: { ...s.listings, [key]: { nodes, count: data.count, total: data.total, nextCursor: data.next_cursor ?? null, gen: nextGen } },
      errors: { ...s.errors, [key]: null },
      lastKey: key,
    }))
    return true
  },

  setError(key, error, t) {
    if (!get().current(t)) return
    set((s) => ({ errors: { ...s.errors, [key]: error }, lastKey: key }))
  },

  /** After a write: revalidate what is open, and the sidebar (quota, shares). */
  invalidate(org) {
    set((s) => ({ rev: s.rev + 1 }))
    if (org) get().loadDrives(org)
  },

  /** Entering Disk for an org: drop what belongs to another org, keep a cache for this one. */
  enterOrg(orgId) {
    if (get().orgId && get().orgId !== orgId) get().reset()
    set({ orgId })
  },

  /** Drop everything; requests still in flight land nowhere. */
  reset() {
    set((s) => ({ epoch: s.epoch + 1, drives: null, drivesError: null, listings: {}, errors: {}, pending: {}, details: {}, lastKey: null }))
  },
}))

export default useDiskStore
