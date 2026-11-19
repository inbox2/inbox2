// DOS-style Disk paths: C:\Contracts\2026, D:\Marketing\Launch 2026.
//
// `ancestors` is the API's path list, root first: [{ id, name, sealed }].
// On C:\ the root folder has no name; on D:\ the root is the share's folder
// and carries the share's name. A grantee's path starts at what was shared
// with them, not at a root. Sealed nodes come without a name, so the caller
// passes the names it decrypted as { [id]: name }.

import { teamDriveLabel } from './model'

export const SEALED_PLACEHOLDER = 'Sealed'

/** A node's display name: sealed nodes arrive nameless until the sealing client decrypts them. */
// A sealed node opened on this page (lib/disk/sealed.js openNames) carries its name and opened: true.
export const nodeLabel = (n, decryptedNames = {}) => (n.sealed && !n.opened ? (decryptedNames[n.id] ?? SEALED_PLACEHOLDER) : n.name)

/**
 * Breadcrumb segments, drive first: [{ id, label }]. The drive segment also
 * carries `drive`; its id is the C:\ root when the path starts there, else null.
 */
export function pathSegments(drive, ancestors = [], decryptedNames = {}) {
  const first = ancestors[0]
  const fromRoot = first && first.name == null && !first.sealed
  const rest = fromRoot ? ancestors.slice(1) : ancestors
  return [
    { id: fromRoot ? first.id : null, label: drive === 'D' ? teamDriveLabel() : `${drive}:\\`, drive },
    ...rest.map((a) => ({
      id: a.id,
      label: a.sealed ? (decryptedNames[a.id] ?? SEALED_PLACEHOLDER) : (a.name ?? ''),
    })),
  ]
}

/** 'C:\Projects\Q4' from segments (or from drive + ancestors). */
export function formatPath(segments) {
  const [drive, ...rest] = segments
  return drive.label + rest.map((s) => s.label).join('\\')
}

/** { drive, names } from a typed path, or null. Trailing and doubled backslashes are ignored. */
export function parsePath(text) {
  const m = /^\s*([A-Za-z]):\\(.*?)\s*$/.exec(text || '')
  if (!m) return null
  return { drive: m[1].toUpperCase(), names: m[2].split('\\').filter(Boolean) }
}
