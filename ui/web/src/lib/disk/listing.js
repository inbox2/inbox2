// Client-side sort and filter for Disk listings (spec F1 sorting, F2 filters).
// Nodes follow the API shape: { id, kind, name, mime, sealed, size_bytes,
// content_modified_at, modified_by: { id, name } }. Sealed nodes arrive
// nameless; the caller fills `name` and `mime` from the decrypted metadata.
import { fileType } from './fileTypes'

export const FAMILIES = [
  { value: 'folders', label: 'Folders' },
  { value: 'documents', label: 'Documents' },
  { value: 'sheets', label: 'Sheets' },
  { value: 'slides', label: 'Slides' },
  { value: 'images', label: 'Images' },
  { value: 'media', label: 'Media' },
  { value: 'pages', label: 'Pages' },
  { value: 'other', label: 'Other' },
]

export const MODIFIED_WINDOWS = [
  { value: '', label: 'Any time' },
  { value: 'today', label: 'Today' },
  { value: '7', label: 'Last 7 days' },
  { value: '30', label: 'Last 30 days' },
]

export const SORT_KEYS = [
  { value: 'name', label: 'Name' },
  { value: 'modified', label: 'Modified' },
  { value: 'by', label: 'Modified by' },
  { value: 'size', label: 'Size' },
]

/** The FilterBar value with nothing set. */
export const EMPTY_FILTERS = { q: '', everywhere: false, types: [], modified: '', by: '', sealed: false }

const isFolder = (n) => n.kind === 'folder'

export function familyOf(node) {
  if (isFolder(node)) return 'folders'
  if (node.kind === 'page') return 'pages'
  return fileType(node).family
}

/** Start of the modified window, in ms, or null for "any time". */
export function windowStart(modified, now = Date.now()) {
  if (!modified) return null
  if (modified === 'today') {
    const d = new Date(now)
    d.setHours(0, 0, 0, 0)
    return d.getTime()
  }
  return now - Number(modified) * 86_400_000
}

export function hasActiveFilters(f) {
  return Boolean(f.q || f.types.length || f.modified || f.by || f.sealed)
}

/** Does a node pass the filters (query, type families, modified window, person, sealed)? */
export function matchesFilters(node, f, now = Date.now()) {
  if (f.q && !(node.name || '').toLowerCase().includes(f.q.trim().toLowerCase())) return false
  if (f.types.length && !f.types.includes(familyOf(node))) return false
  if (f.by && node.modified_by?.id !== f.by) return false
  if (f.sealed && !node.sealed) return false
  const start = windowStart(f.modified, now)
  if (start != null && !(Date.parse(node.content_modified_at) >= start)) return false
  return true
}

const byName = (a, b) => (a.name || '').localeCompare(b.name || '', undefined, { numeric: true, sensitivity: 'base' })

const COMPARE = {
  name: byName,
  modified: (a, b) => (Date.parse(a.content_modified_at) || 0) - (Date.parse(b.content_modified_at) || 0),
  by: (a, b) => (a.modified_by?.name || '').localeCompare(b.modified_by?.name || ''),
  size: (a, b) => (a.size_bytes ?? -1) - (b.size_bytes ?? -1),
}

/** New array: folders above everything else, then by `key` (dir 1 or -1), name breaks ties. */
export function sortNodes(nodes, key = 'name', dir = 1) {
  const cmp = COMPARE[key] || byName
  return [...nodes].sort((a, b) => (isFolder(b) - isFolder(a)) || dir * cmp(a, b) || byName(a, b))
}

/** The direction a sort key starts in: size and modified start largest/newest first. */
export const defaultDir = (key) => (key === 'size' || key === 'modified' ? -1 : 1)

// Grid tile width in px for FilterBar's size slider.
export const TILE_SIZES = { min: 120, max: 360, step: 8, initial: 168 }
