import { useCallback, useEffect } from 'react'
import useDiskStore from '../stores/diskStore'
import diskApi from '../lib/disk/api'

function fetchSource(org, src, cursor) {
  if (src.kind === 'folder') return diskApi.children(org, src.id, src.params, cursor)
  if (src.kind === 'view') return diskApi.view(org, src.name, cursor)
  return diskApi.search(org, src.q, src.scope, src.modified).then((d) => ({ nodes: d.results, next_cursor: null }))
}

/**
 * One Disk listing, loaded the way section 3 asks: a cached listing shows at
 * once and revalidates; with nothing cached, the previous listing stays on
 * screen dimmed until this one lands.
 *
 *   source  { kind: 'folder', id, params } | { kind: 'view', name } | { kind: 'search', q, scope } | null
 *   returns { data, dim, loading, error, loadMore }
 *           data: { nodes, count, total, nextCursor } (this listing, or the previous one while dim)
 */
export default function useDiskListing(org, source) {
  const key = source ? JSON.stringify(source) : null
  const rev = useDiskStore((s) => s.rev)
  const own = useDiskStore((s) => (key ? s.listings[key] : null))
  const last = useDiskStore((s) => (s.lastKey ? s.listings[s.lastKey] : null))
  const error = useDiskStore((s) => (key ? s.errors[key] : null))
  const loading = useDiskStore((s) => !!(key && s.pending[key]))

  useEffect(() => {
    if (!org || !key) return undefined
    const store = useDiskStore.getState()
    const ticket = store.ticket(org)
    let live = true
    store.setPending(key, true, ticket)
    fetchSource(org, JSON.parse(key))
      .then((d) => { if (live) store.setListing(key, d, { ticket }) })
      .catch((e) => { if (live) store.setError(key, e, ticket) })
      .finally(() => store.setPending(key, false, ticket))
    return () => { live = false }
  }, [org, key, rev])

  // The next page joins the listing it was asked for; if a write reloaded the
  // first page meanwhile (a new generation), this page is stale and is dropped.
  const loadMore = useCallback(async () => {
    const store = useDiskStore.getState()
    const cur = store.listings[key]
    if (!cur?.nextCursor) return
    const ticket = store.ticket(org)
    const d = await fetchSource(org, JSON.parse(key), cur.nextCursor)
    useDiskStore.getState().setListing(key, d, { append: true, gen: cur.gen, ticket })
  }, [org, key])

  return { data: own || (error ? null : last), dim: !own && !!last && !error, loading, error, loadMore }
}

/** GET /nodes/:id through the store: { node, error }, cached, revalidated after writes. */
export function useDiskNode(org, id) {
  const rev = useDiskStore((s) => s.rev)
  const entry = useDiskStore((s) => (id ? s.details[id] : null))
  useEffect(() => {
    if (org && id) useDiskStore.getState().loadDetail(org, id)
  }, [org, id, rev])
  return { node: entry?.node || null, error: entry?.error || null }
}
