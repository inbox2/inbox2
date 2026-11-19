import { resolveWorkspace } from '../workspace'
// Disk vocabulary the client needs to draw controls. Each list mirrors a
// server constant; the server validates, so a drift shows as a 422, not bad data.

// Disk::ROLES, lowest first.
export const ROLE = { VIEW: 'view', EDIT: 'edit', MANAGE: 'manage' }
export const ROLES = [ROLE.VIEW, ROLE.EDIT, ROLE.MANAGE]
export const roleAtLeast = (role, needed) => ROLES.indexOf(role) >= ROLES.indexOf(needed)
export const ROLE_LABEL = { view: 'Can view', edit: 'Can edit', manage: 'Can manage' }

// Disk::Node::KIND_*
export const KIND = { FOLDER: 'folder', FILE: 'file', PAGE: 'page' }

// Disk::Share::OPENNESS and ORG_ROLES.
export const OPENNESS = { ORG: 'org', ASSIGNED: 'assigned' }
export const SHARE_ORG_ROLES = [ROLE.VIEW, ROLE.EDIT]

// A share's company (2026-10-04): one payer, several distinct companies, one per domain.
// share.domain is { id, name } or null for the whole organization; an open share reaches
// only people who see its domain (Disk::Share#open_to?).
export const openTo = (share) => (share?.domain ? `Everyone at ${share.domain.name}` : 'Everyone in the organization')
/** Options for a company picker: the whole org, then each domain. */
export const companyOptions = (domains) => [{ value: '', label: 'Whole organization' }, ...(domains || []).map((d) => ({ value: d.id, label: d.name }))]

// Disk::Share::ICONS: the emblems the API accepts. null is a plain folder (no emblem).
export const SHARE_ICONS = ['marketing', 'sales', 'finance', 'hr', 'product', 'design', 'support', 'business', 'analytics', 'procurement', 'legal', 'engineering']

// Disk::Share::TEMPLATES names (POST /shares/templates takes names only).
export const SHARE_TEMPLATES = [
  { name: 'Marketing', icon: 'marketing' },
  { name: 'Sales', icon: 'sales' },
  { name: 'Finance', icon: 'finance' },
  { name: 'HR', icon: 'hr' },
  { name: 'Product', icon: 'product' },
  { name: 'Design', icon: 'design' },
  { name: 'Support', icon: 'support' },
]

// Disk::Access::SOURCE_* as serialized.
export const SOURCE = { CUSTODIAN: 'custodian', ADMIN: 'admin', SHARE_MEMBER: 'share_member', SHARE_DEFAULT: 'share_default', GRANT: 'grant' }

// The four views and their GET /views/:name.
/** /disk/import: importers (spec F10); the API's OAuth callback returns here with ?org=&source=&status=. */
export const IMPORT_SEGMENT = 'import'

export const VIEWS = [
  { slug: 'shared-with-me', icon: 'people', label: 'Shared with me', empty: 'Folders and files people share with you by name show up here.' },
  { slug: 'recent', icon: 'clock', label: 'Recent', empty: 'Files you open show up here.' },
  { slug: 'starred', icon: 'star', label: 'Starred', empty: 'Star a folder or file to keep it here.' },
  { slug: 'trash', icon: 'trash', label: 'Trash', empty: 'Deleted items stay here for 30 days.' },
]

// Disk::Event::ACTIONS as a sentence after the actor's name.
export const EVENT_TEXT = {
  created: 'created it', renamed: 'renamed it', moved: 'moved it', copied: 'copied it', trashed: 'deleted it',
  restored: 'restored it', purged: 'deleted it forever', uploaded: 'uploaded it', version_added: 'uploaded a new version',
  version_restored: 'restored an older version', granted: 'shared it with someone', grant_changed: 'changed someone\'s access',
  ungranted: 'removed someone\'s access', link_created: 'made a public link', link_revoked: 'revoked a public link',
  link_used: 'opened it through a public link', page_saved: 'edited it', page_restored: 'restored an older version',
  agent_granted: 'gave an agent access', agent_ungranted: 'took an agent\'s access away', reassigned: 'took it over from someone who left',
  saved_from_mail: 'saved it from mail', switched: 'moved it into or out of a sealed folder',
  share_created: 'created the share', share_updated: 'changed the share', share_trashed: 'deleted the share',
  share_restored: 'restored the share', member_added: 'added a member', member_changed: 'changed a member\'s role',
  member_removed: 'removed a member', key_rotated: 'renewed the key', key_transferred: 'gave the key to someone else',
  sealed_abandoned: 'abandoned the sealed folders of someone who left',
}

// Agent::DISK_PERMISSIONS: what an agent may do in Disk over MCP, within its grants.
export const AGENT_DISK_PERMISSIONS = [
  { value: 'disk_read', label: 'Read files and pages' },
  { value: 'disk_write', label: 'Upload, edit pages, rename and move' },
  { value: 'disk_manage', label: 'Share and delete' },
]

// ── URLs (decided 2026-10-03, org dropped from the path 2026-10-04; api/app/services/disk/web_path.rb builds the same) ──
//   /disk/c                               C:\ (my disk: the person's own, the same from every team, 2026-10-07)
//   /disk/<letter>                        a team's shared disk: D:\, E:\, F:\ ... one letter per team the person
//                                         belongs to (organizations[].drive_letter), in the order they joined
//   /disk/<letter>/<share-slug>           a share's top folder
//   /disk/<letter>/<share-slug>/Brand/Logos-<short_id>   any folder, file or page:
//   /disk/c/Clients/Invoices-<short_id>           names down from the root, id last
//   /disk/shared/<name>-<short_id>        reached through a grant, no visible way down from a root
//   ?open=<name>-<short_id>               a file previewed on its folder
//   /disk/<view>, /disk/import            shared-with-me, recent, starred, trash; the importers
//   ?org=<slug or id>                     selects that org (API-made links about an org, the import callback)
// Disk works on one org at a time (diskOrg below): the letter in the URL, else the member's remembered
// choice, else the org they are acting in. A letter is the viewer's own (someone else's E:\ may be
// your D:\), so a node or share the letter's org lacks is looked for in the person's other orgs
// before not-found (findOrgWith); the id is the authority and the URL is corrected.
// The short id is the authority; the rest of the path is decoration, corrected
// with a history replace when a rename or move made it stale. Sealed items show
// "sealed-<id>", never a name. Public link URLs come from the API.

// A node's short id: 21 nanoid characters, which may contain - and _. The last 21
// characters of the final segment, never split on "-".
export const SHORT_ID_LENGTH = 21
const SHORT_ID = /^[A-Za-z0-9_-]{21}$/
export const DRIVE_SEGMENT = { C: 'c', D: 'd' }
export const FIRST_TEAM_LETTER = 'D'
const TEAM_LETTERS = Array.from({ length: 23 }, (_, i) => String.fromCharCode(FIRST_TEAM_LETTER.charCodeAt(0) + i)) // D..Z
export const teamLetter = (org) => org?.drive_letter || FIRST_TEAM_LETTER
// The letter of the team Disk is on, set by DiskLayout; drivePath('D') and share URLs use it, so
// callers need not carry the org around (Disk works on one team at a time).
let currentLetter = FIRST_TEAM_LETTER
export const setTeamLetter = (letter) => { currentLetter = (letter || FIRST_TEAM_LETTER).toUpperCase() }
export const teamDriveLabel = (letter = currentLetter) => `${letter}:\\`
export const SHARED_SEGMENT = 'shared'

/** The short id of a node or a node key ("dnd_<short>"); compare nodes with this. */
export const shortId = (x) => (typeof x === 'string' ? x : x?.short_id || x?.id || '').slice(-SHORT_ID_LENGTH)
export const sameNode = (a, b) => !!a && !!b && shortId(a) === shortId(b)

/** The id at the end of a segment ("<name>-<id>" or a bare id), or null. */
export function idFromSegment(segment) {
  const s = segment || ''
  const id = s.slice(-SHORT_ID_LENGTH)
  if (!SHORT_ID.test(id)) return null
  return s.length === SHORT_ID_LENGTH || s[s.length - SHORT_ID_LENGTH - 1] === '-' ? id : null
}

const nameOf = (n) => (n.sealed || n.name == null ? (n.sealed ? 'sealed' : 'item') : n.name)
/** The last segment, unencoded: "<name>-<short_id>", or "sealed-<short_id>". */
export const idSegment = (node) => `${nameOf(node)}-${shortId(node)}`

// Where Disk is mounted. On its own host (disk.inbox2.com) it sits at the root: /c, /d/<share>, /recent.
// Everywhere else (mail.inbox2.com, dev) under /disk/. A Pages build with VITE_DISK_ORIGIN sends /disk/...
// on the mail host to that origin (routes.jsx DiskMount); dev has none and keeps /disk/.
const host = typeof window === 'undefined' ? '' : window.location.hostname
export const DISK_HOST = host.startsWith('disk.')
export const DISK_ORIGIN = (import.meta.env.VITE_DISK_ORIGIN || '').replace(/\/+$/, '')
// The mail host, where the disk host sends everything that is not Disk (routes.jsx AppRoutes).
export const MAIL_ORIGIN = (import.meta.env.VITE_MAIL_ORIGIN || '').replace(/\/+$/, '')
const BASE = DISK_HOST ? '' : '/disk'
// The first segments of a root-mounted Disk URL. Org slugs cannot shadow them: static routes win.
export const ROOT_SEGMENTS = [DRIVE_SEGMENT.C, ...TEAM_LETTERS.map((l) => l.toLowerCase()), SHARED_SEGMENT, IMPORT_SEGMENT, ...VIEWS.map((v) => v.slug)]

export const diskPath = (where = '') => (where ? `${BASE}/${where}` : BASE || '/')
/** What parseDiskPath reads: the pathname after the mount ("c/Clients-<id>"). */
export const diskSplat = (pathname) => pathname.replace(/^\/disk(?=\/|$)/, '').replace(/^\/+/, '')
/** Whether a pathname is a Disk page on this host. */
export function isDiskPath(pathname) {
  if (/^\/disk(\/|$)/.test(pathname)) return true
  return DISK_HOST && (pathname === '/' || ROOT_SEGMENTS.includes(pathname.split('/')[1]))
}
/** C:\, or the team's lettered drive ('D' means the current team; a letter names one). */
export const drivePath = (drive, letter) => diskPath(drive === 'C' ? DRIVE_SEGMENT.C : (letter || (drive === 'D' ? currentLetter : drive)).toLowerCase())

const enc = encodeURIComponent
const isCRoot = (n) => !!n && n.name == null && !n.sealed && !n.share_slug && (n.kind ?? 'folder') === 'folder'
const isRoot = (n) => !!n && (!!n.share_slug || isCRoot(n))

/**
 * The URL of the last node in `path`: the API's path segments (top first, each
 * with short_id, kind and, on a share's top folder, share_slug), cut to what the
 * viewer can see. A path that does not start at a root is a grant: /shared/.
 */
export function pathUrl(path = []) {
  const last = path.at(-1)
  const first = path[0]
  if (!last) return drivePath('C')
  if (!isRoot(first)) return diskPath(`${SHARED_SEGMENT}/${enc(idSegment(last))}`)
  const head = first.share_slug ? `${drivePath('D')}/${enc(first.share_slug)}` : drivePath('C')
  if (path.length === 1) return head
  return [head, ...path.slice(1, -1).map((n) => enc(nameOf(n))), enc(idSegment(last))].join('/')
}

/** A node's URL when its path is not known (views, search hits without one): resolved by id, corrected on load. */
export const nodeUrl = (node) => (node.path?.length ? pathUrl(node.path) : diskPath(`${SHARED_SEGMENT}/${enc(idSegment(node))}`))

/** A share's top folder as a path segment, for pathUrl. */
export const shareRoot = (share) => ({ id: share.root_node_id, short_id: shortId(share.root_node_id), name: share.name, kind: 'folder', share_slug: share.slug })

/** A file's preview: its folder's URL plus ?open=. */
export const previewUrl = (folderUrl, node) => `${folderUrl}?open=${enc(idSegment(node))}`

/** A markdown file open in the page editor ("Edit as page", spec F6): its folder's URL plus ?edit=. */
export const editUrl = (folderUrl, node) => `${folderUrl}?edit=${enc(idSegment(node))}`

/** Files "Edit as page" opens: unsealed markdown no larger than a page (Disk::Page::MAX_BYTES). */
export const PAGE_MAX_BYTES = 5 * 1024 * 1024
export const editableAsPage = (n) => n.kind === 'file' && !n.sealed && /\.(md|markdown)$/i.test(n.name || '') && (n.size_bytes || 0) <= PAGE_MAX_BYTES
/** Files "Import as page" converts: unsealed .docx. */
export const importableAsPage = (n) => n.kind === 'file' && !n.sealed && /\.docx$/i.test(n.name || '')

/**
 * Where breadcrumb segment `index` goes (segments from paths.js pathSegments for
 * the same path): 0 is the drive, the rest are the path's folders.
 */
export function crumbUrl(drive, path, index) {
  if (isCRoot(path[0])) return pathUrl(path.slice(0, index + 1))
  if (index <= 0) return drivePath(drive)
  return pathUrl(path.slice(0, index))
}

// ── which org Disk is on ──

/**
 * The org Disk works on: `wanted` (a slug, domain slug or id: ?org=, an old URL's slug,
 * or the remembered choice) when the person belongs to it, else the org they are acting
 * in, else their first. resolveWorkspace is the app's one slug resolver.
 */
export function diskOrg(organizations, wanted, current, letter) {
  const orgs = organizations || []
  return (letter && orgByLetter(orgs, letter)) || (wanted && resolveWorkspace(orgs, wanted).org) || orgs.find((o) => o.id === current?.id) || orgs[0] || null
}

/** The person's team with this drive letter, or null (a letter in a link made by someone else). */
export const orgByLetter = (organizations, letter) => (organizations || []).find((o) => teamLetter(o) === String(letter || '').toUpperCase()) || null

/** The person's teams in drive-letter order, for the sidebar. */
export const teamsByLetter = (organizations) => [...(organizations || [])].sort((a, b) => teamLetter(a).localeCompare(teamLetter(b)))

/** The first of the person's other orgs for which has(org) resolves true (a node or share found there), or null. */
export async function findOrgWith(organizations, currentId, has) {
  for (const o of organizations || []) {
    if (o.id === currentId) continue
    try {
      if (await has(o)) return o
    } catch { /* not there, or no Disk in that org */ }
  }
  return null
}

/**
 * What a Disk URL asks for. `splat` is everything after /:slug/disk/.
 * { redirect } | { drive: 'C', root } | { drive: 'D', overview } | { view }
 * | { drive: 'D', shareSlug } | { id, drive? } | { notFound }
 */
export function parseDiskPath(splat) {
  const segs = String(splat || '').split('/').filter(Boolean).map((s) => { try { return decodeURIComponent(s) } catch { return s } })
  if (!segs.length) return { redirect: DRIVE_SEGMENT.C } // /disk opens C:\
  const [first, ...rest] = segs
  if (first === SHARED_SEGMENT) {
    const id = rest.length === 1 && idFromSegment(rest[0])
    return id ? { id } : { notFound: true }
  }
  const team = first.length === 1 && TEAM_LETTERS.includes(first.toUpperCase())
  if (first === DRIVE_SEGMENT.C || team) {
    const drive = first === DRIVE_SEGMENT.C ? 'C' : 'D'
    const letter = team ? first.toUpperCase() : undefined
    if (!rest.length) return drive === 'C' ? { drive, root: true } : { drive, letter, overview: true }
    if (drive === 'D' && rest.length === 1) return { drive, letter, shareSlug: rest[0] }
    const id = idFromSegment(rest.at(-1))
    return id ? { drive, letter, id } : { notFound: true }
  }
  if (rest.length === 0 && VIEWS.some((v) => v.slug === first)) return { view: first }
  if (rest.length === 0 && first === IMPORT_SEGMENT) return { imports: true }
  return { notFound: true }
}

/** The token from /share/<name>/<token> or /share/<token>. */
export const tokenFromLinkPath = (a, b) => b || a

/** A sealed version's plaintext size from its stored (ciphertext) size, 6.6: chunks carry a 16-byte tag each. */
export function plainSize(stored, cb) {
  if (!(stored > 0) || !(cb > 0)) return 0
  return stored - 16 * Math.ceil(stored / (cb + 16))
}
