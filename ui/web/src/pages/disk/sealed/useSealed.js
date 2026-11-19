import { useEffect, useMemo, useRef, useState } from 'react'
import { refreshIdentity, useE2ee } from '../../../lib/e2eeStore'
import diskApi from '../../../lib/disk/api'
import useSealedStore from '../../../stores/sealedStore'

/** The scope a node belongs to: the first sealed segment of its path, or itself when it is a scope root. */
export function scopeIdOf(node) {
  if (!node) return null
  const seg = node.path?.find((s) => s.sealed)
  return seg ? seg.id : node.sealed ? node.id : null
}

// Sealed ancestors' details (for their names in breadcrumbs): id -> node.
const ancestors = new Map()
// Opened sealed thumbnails: version id -> Promise<blob: URL | null>.
const thumbs = new Map()
function sealedThumb(lib, orgId, scope, node) {
  if (!thumbs.has(node.current_version_id)) {
    thumbs.set(node.current_version_id, lib.currentVersion(orgId, node)
      .then((version) => lib.derivedBlob({ orgId, scope, nodeId: node.id, version, variant: 'thumbnail', mime: 'image/webp' }))
      .then((blob) => URL.createObjectURL(blob))
      .catch(() => null))
  }
  return thumbs.get(node.current_version_id)
}

/**
 * Sealed state for one Disk location (spec F7). folder: the open folder (with
 * path); nodes: its listing. Opens the folder's scope and the scopes of
 * sealed folder roots listed in an unsealed folder, and returns:
 *   scopeId, entry ({ status, scope }), scope (when open)
 *   nodes   the listing with sealed names, types and plaintext sizes filled in
 *   names   id -> name for breadcrumbs (pathSegments' decryptedNames)
 *   lib     lib/disk/sealed.js once loaded (it carries libsodium, so only when needed)
 */
export default function useSealed(orgId, folder, nodes = [], extra = []) {
  const { identityStatus } = useE2ee()
  const scopeId = scopeIdOf(folder)
  const rootIds = scopeId ? [] : nodes.filter((n) => n.sealed && n.kind === 'folder').map((n) => n.id)
  const ids = [...new Set([scopeId, ...rootIds, ...extra.map(scopeIdOf)].filter(Boolean))]
  const idKey = ids.join(',')
  const needed = ids.length > 0
  const scopes = useSealedStore((s) => s.scopes)
  const [lib, setLib] = useState(null)
  const [, setTick] = useState(0)

  useEffect(() => {
    if (needed && !lib) import('../../../lib/disk/sealed').then(setLib)
  }, [needed, lib])
  useEffect(() => {
    if (!orgId) return
    const open = useSealedStore.getState().open
    idKey.split(',').filter(Boolean).forEach((id) => open(orgId, id))
  }, [orgId, idKey, identityStatus])
  // Learn whether this account has an identity key (and whether it is unlocked) once sealed items show up.
  useEffect(() => { if (needed && identityStatus === 'unknown') refreshIdentity() }, [needed, identityStatus])
  // Locking after an unlock: forget the keys (here and in the service worker), then ask again.
  const was = useRef(identityStatus)
  useEffect(() => {
    if (was.current === 'unlocked' && identityStatus !== 'unlocked') {
      useSealedStore.getState().clear().then(() => {
        const open = useSealedStore.getState().open
        idKey.split(',').filter(Boolean).forEach((id) => open(orgId, id))
      })
    }
    was.current = identityStatus
  }, [identityStatus, idKey, orgId])

  const entry = scopeId ? scopes[`${orgId}/${scopeId}`] || null : null
  const scope = entry?.status === 'open' ? entry.scope : null

  // Breadcrumb names: the folder itself and every sealed ancestor in its scope.
  const sealedPath = useMemo(() => (folder?.path || []).filter((s) => s.sealed && !ancestors.has(s.id) && s.id !== folder.id).map((s) => s.id), [folder])
  useEffect(() => {
    if (!scope || !sealedPath.length) return
    let live = true
    Promise.all(sealedPath.map((id) => diskApi.node(orgId, id).then(({ node }) => ancestors.set(id, node)).catch(() => {})))
      .then(() => { if (live) setTick((t) => t + 1) })
    return () => { live = false }
  }, [orgId, scope, sealedPath])

  const out = useMemo(() => {
    if (!lib) return nodes
    return nodes.map((n) => {
      const sid = scopeId || (n.sealed ? n.id : null)
      const e = sid && scopes[`${orgId}/${sid}`]
      if (e?.status !== 'open') return n
      const o = lib.openNames(e.scope, [n])[0]
      return o.opened && o.kind === 'file' && o.has_thumbnail ? { ...o, thumb: () => sealedThumb(lib, orgId, e.scope, o) } : o
    })
  }, [lib, nodes, scopeId, scopes, orgId])

  const names = {}
  if (lib && scope && folder) {
    for (const n of [folder, ...(folder.path || []).map((s) => ancestors.get(s.id)).filter(Boolean)]) {
      if (!n?.sealed || !n.metadata_ciphertext) continue
      const [o] = lib.openNames(scope, [n])
      if (o.name) names[n.id] = o.name
    }
  }
  return { scopeId, entry, scope, nodes: out, names, lib }
}

/**
 * Search inside an open scope (the server never sees sealed names): the
 * scope's whole tree, names opened here, filtered by q. null while loading.
 */
export function useSealedSearch(orgId, lib, scope, q) {
  const [tree, setTree] = useState(null)
  const scopeKey = scope?.id
  useEffect(() => {
    if (!lib || !scope || !q) return undefined
    let live = true
    ;(async () => {
      const all = []
      let cursor
      do {
        const d = await diskApi.tree(orgId, scope.id, cursor)
        all.push(...d.nodes)
        cursor = d.next_cursor
      } while (cursor && live)
      if (live) setTree(lib.openNames(scope, all))
    })().catch(() => { if (live) setTree([]) })
    return () => { live = false }
    // the tree is fetched once per scope; typing filters it
  }, [orgId, lib, scopeKey, !!q]) // eslint-disable-line react-hooks/exhaustive-deps
  if (!q || !scope) return null
  if (!tree) return null
  const needle = q.toLowerCase()
  return tree.filter((n) => n.id !== scope.id && n.name?.toLowerCase().includes(needle))
}
