// Disk endpoints (docs/plans/disk-build.md section 7), all under
// /api/v1/orgs/:org_id/disk. Shapes come from api/app/serializers/disk/*.
// Errors are the shared ApiClient's: `status` 403 (plan without Disk, or a
// role that does not allow it), 404 (not visible), 409 (name clash).
import api from '../api'

const base = (org) => `/orgs/${encodeURIComponent(org)}/disk`
const enc = encodeURIComponent

/** Keep both on a name clash ("a (1).pdf") instead of answering 409. */
export const KEEP_BOTH = 'keep_both'
/** Upload over an existing file as its new version. */
export const REPLACE = 'replace'
/** The error code on a 422 when the org's pooled quota is full (Disk::Quota::FULL). */
export const QUOTA_FULL = 'disk_quota_exceeded'
/** 403 while Disk is read-only after a downgrade (spec F8). */
export const READ_ONLY = 'disk_read_only'
/** 409 from parts or completion of an upload no longer taking them (an epoch_changed one was sealed under a rotated key). */
export const UPLOAD_CLOSED = 'upload_closed'
/** 422 from attach-from-Disk when the file is over the mail size limit. */
export const ATTACHMENT_TOO_LARGE = 'disk_attachment_too_large'
/** Sealing (build guide 6.5 to 6.9; Disk::Sealing on the API). */
export const SEAL = {
  ID_TAKEN: 'disk_id_taken', // 409: a proposed id is in use; propose another
  EPOCH_CHANGED: 'epoch_changed', // 409 { current_epoch }: refetch the grant and retry
  ROTATION_REQUIRED: 'rotation_required', // 409: a holder left; a manager must rotate first
  SEALED_WHOLE: 'disk_sealed_whole', // a grant inside a scope: offer "Move to a new sealed share"
  USE_ROTATE: 'disk_use_rotate', // removing a holder goes through rotate
  NO_IDENTITY_KEY: 'disk_no_identity_key',
  CROSS_SEAL: 'disk_cross_seal', // across a seal boundary without the sealing client's fields
}
/** 409 from removing a member whose sealed folders only they can open. */
export const SEALED_BLOCKERS = 'disk_sealed_blockers'

function qs(params) {
  const sp = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '') sp.set(k, v)
  const s = sp.toString()
  return s ? `?${s}` : ''
}

/** The browser's IANA time zone, so "today" means the person's own day. */
export const localZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'

/** The modified filter as the API takes it: "<n>d", or "today" with the time zone. */
export function modifiedParams(modified, tz = localZone()) {
  if (!modified) return {}
  return modified === 'today' ? { modified: 'today', tz } : { modified: `${modified}d` }
}

/** Query params for GET /nodes/:id/children from the FilterBar value. */
export function listingParams(value, tz) {
  return {
    sort: value.sort,
    dir: value.dir < 0 ? 'desc' : 'asc',
    type: value.types.join(','),
    ...modifiedParams(value.modified, tz),
    by: value.by,
    sealed: value.sealed ? 'true' : '',
  }
}

// false: ask (409 on a clash); true: keep both; KEEP_BOTH or REPLACE: that choice.
const conflict = (choice) => (choice === true ? { on_conflict: KEEP_BOTH } : choice ? { on_conflict: choice } : {})

/** True for the refusal removing a member gets while their C:\ still holds files (Membership#release_disk_drive). */

const diskApi = {
  // { c_drive: node, shares: [share], quota: { pool_bytes, used_bytes, ... } }
  drives: (org) => api.get(base(org)),

  // Nodes
  node: (org, id) => api.get(`${base(org)}/nodes/${enc(id)}`), // { node: { ...node, path, access: { role, sources } } }
  children: (org, id, params, cursor) => api.get(`${base(org)}/nodes/${enc(id)}/children${qs({ ...params, cursor })}`), // { nodes, count, total, next_cursor }
  createFolder: (org, parentId, name, keepBoth) => api.post(`${base(org)}/nodes`, { parent_id: parentId, name, kind: 'folder', ...conflict(keepBoth) }),
  rename: (org, id, name, keepBoth) => api.patch(`${base(org)}/nodes/${enc(id)}`, { name, ...conflict(keepBoth) }),
  star: (org, id, starred) => api.patch(`${base(org)}/nodes/${enc(id)}`, { starred }),
  move: (org, id, targetId, keepBoth) => api.post(`${base(org)}/nodes/${enc(id)}/move`, { target_id: targetId, ...conflict(keepBoth) }),
  // { node, revoked? } — a move to another drive or share revokes its links and grants: revoked: { links, grants, agent_grants }
  copy: (org, id, targetId, keepBoth) => api.post(`${base(org)}/nodes/${enc(id)}/copy`, { target_id: targetId, ...conflict(keepBoth) }),
  trash: (org, id) => api.delete(`${base(org)}/nodes/${enc(id)}`),
  restore: (org, id) => api.post(`${base(org)}/nodes/${enc(id)}/restore`), // { node, restored_to_root }
  purge: (org, id, { emptyOnly = false } = {}) => api.delete(`${base(org)}/nodes/${enc(id)}/purge${emptyOnly ? '?empty_only=1' : ''}`),
  // op: move | trash | restore. { results: [{ id, ok, error, node }] }
  bulk: (org, op, ids, targetId, keepBoth) => api.post(`${base(org)}/nodes/bulk`, { op, ids, target_id: targetId, ...conflict(keepBoth) }),

  // Sharing with people (unsealed nodes)
  grants: (org, id) => api.get(`${base(org)}/nodes/${enc(id)}/grants`), // { grants: [{ role, membership: { id, name }, granted_by }] }
  setGrant: (org, id, membershipId, role) => api.put(`${base(org)}/nodes/${enc(id)}/grants/${enc(membershipId)}`, { role }),
  removeGrant: (org, id, membershipId) => api.delete(`${base(org)}/nodes/${enc(id)}/grants/${enc(membershipId)}`),

  // Uploads (section 8): reserve, presigned part URLs, resume state, complete, cancel.
  // on_conflict: keep_both | replace. Quota refusal is 422 with data.code === QUOTA_FULL.
  startUpload: (org, attrs) => api.post(`${base(org)}/uploads`, attrs), // { upload: { id, part_bytes, part_count, ... } }
  uploadParts: (org, id, numbers) => api.post(`${base(org)}/uploads/${enc(id)}/parts`, { numbers }), // { parts: [{ number, url, expires_at }] }
  upload: (org, id) => api.get(`${base(org)}/uploads/${enc(id)}`), // { upload, parts: [{ number, etag, size_bytes }] }
  completeUpload: (org, id, sha256) => api.post(`${base(org)}/uploads/${enc(id)}/complete`, sha256 ? { sha256 } : {}), // { node, version }
  cancelUpload: (org, id) => api.delete(`${base(org)}/uploads/${enc(id)}`),

  // Downloads: short-lived presigned GETs. { download: { url, expires_at, size_bytes, variant } }
  download: (org, id) => api.get(`${base(org)}/nodes/${enc(id)}/download`),
  versionDownload: (org, versionId, variant) => api.get(`${base(org)}/versions/${enc(versionId)}/download${qs({ variant })}`),
  tree: (org, id, cursor) => api.get(`${base(org)}/nodes/${enc(id)}/tree${qs({ cursor })}`), // { nodes, next_cursor }
  versions: (org, id, cursor) => api.get(`${base(org)}/nodes/${enc(id)}/versions${qs({ cursor })}`), // { versions: [...], next_cursor }
  restoreVersion: (org, versionId) => api.post(`${base(org)}/versions/${enc(versionId)}/restore`),
  // A presigned PUT for a version's thumbnail. { upload: { url, expires_at } }
  thumbnailUrl: (org, versionId) => api.put(`${base(org)}/versions/${enc(versionId)}/thumbnail`),
  // The same for an exact-view PDF rendition (spec F5b; exempt from quota).
  renditionUrl: (org, versionId) => api.put(`${base(org)}/versions/${enc(versionId)}/rendition`),
  // After the PUT succeeded: the version records the object only now. variant: 'thumbnail' | 'rendition'.
  derivedLanded: (org, versionId, variant) => api.put(`${base(org)}/versions/${enc(versionId)}/${variant}`, { landed: true }),

  // Pages (spec F6). { page: { revision, ydoc (base64), markdown, sealed }, role }
  createPage: (org, parentId, name, keepBoth = true) => api.post(`${base(org)}/nodes`, { parent_id: parentId, name, kind: 'page', ...conflict(keepBoth) }),
  page: (org, id) => api.get(`${base(org)}/pages/${enc(id)}`),
  // { ydoc, markdown, base_revision, restored_from }. 409 when someone saved since: data.current_revision.
  savePage: (org, id, body) => api.put(`${base(org)}/pages/${enc(id)}`, body), // { page, node }
  pageVersions: (org, id, cursor) => api.get(`${base(org)}/pages/${enc(id)}/versions${qs({ cursor })}`), // + next_cursor // { versions: [{ revision, created_at, author, size_bytes }] }
  pageVersion: (org, id, revision) => api.get(`${base(org)}/pages/${enc(id)}/versions/${enc(revision)}`), // { version: { ..., ydoc, markdown } }

  // Public links (spec F4). token and url come back only from create.
  links: (org, id) => api.get(`${base(org)}/nodes/${enc(id)}/links`), // { links: [...] }
  createLink: (org, id, attrs) => api.post(`${base(org)}/nodes/${enc(id)}/links`, attrs), // { link: { ..., token, url } }
  revokeLink: (org, linkId) => api.delete(`${base(org)}/links/${enc(linkId)}`),

  // A preview that failed in the browser (spec F5), counted. renderer and reason are short codes.
  previewFailure: (org, id, renderer, reason) => api.post(`${base(org)}/nodes/${enc(id)}/preview-failures`, { renderer, reason }),

  // Importers (spec F10). sources: offered providers only, with connection and spaces.
  importSources: (org) => api.get(`${base(org)}/imports/sources`), // { sources: [{ provider, label, folder_name, connected, account_email, org_available, org_connected, org_account, spaces: [{ id, kind, name, email, member_id }], spaces_error }] }
  importConnect: (org, provider, reach) => api.post(`${base(org)}/imports/${enc(provider)}/connect`, { reach }), // { authorize_url }
  importDisconnect: (org, provider, reach) => api.delete(`${base(org)}/imports/${enc(provider)}/connection${qs({ reach })}`),
  imports: (org, cursor) => api.get(`${base(org)}/imports${qs({ cursor })}`), // { imports, next_cursor }
  startImport: (org, provider, spaces, targetId) => api.post(`${base(org)}/imports`, { provider, spaces, target_id: targetId }), // { imports }
  importStatus: (org, id) => api.get(`${base(org)}/imports/${enc(id)}`), // { import }
  resumeImport: (org, id) => api.post(`${base(org)}/imports/${enc(id)}/resume`),
  cancelImport: (org, id) => api.delete(`${base(org)}/imports/${enc(id)}`),
  importReport: (org, id, cursor) => api.get(`${base(org)}/imports/${enc(id)}/report${qs({ cursor })}`), // { report: { import, unmatched_people, unresolved_groups, entries, next_cursor } }

  // Console (spec F11; owners and admins). Read-only orgs answer writes with 403 and data.code READ_ONLY.
  adminUsage: (org) => api.get(`${base(org)}/admin/usage`), // { usage: { quota, quota_override_gb, settings, members: [{ member, bytes }], shares: [{ share, bytes }] } }
  adminLinks: (org, cursor) => api.get(`${base(org)}/admin/links${qs({ cursor })}`), // { links: [link + node (with path)], next_cursor }
  adminEvents: (org, filters, cursor) => api.get(`${base(org)}/admin/events${qs({ ...filters, cursor })}`), // { events: [event + item { kind, sealed, name } + share_name], next_cursor }; filters: share, member, type, from, to
  adminRevokeLink: (org, id) => api.delete(`${base(org)}/admin/links/${enc(id)}`),
  adminSettings: (org, attrs) => api.put(`${base(org)}/admin/settings`, attrs), // { settings }
  exportPage: (org, cursor) => api.get(`${base(org)}/admin/export${qs({ cursor })}`), // { export: { manifest (first page), entries, next_cursor } }

  // Agents (spec F12): which folders an agent may reach over MCP.
  agentGrants: (org, agentId) => api.get(`${base(org)}/agents/${enc(agentId)}/grants`), // { grants: [{ role, agent_id, node, granted_by }] }
  setAgentGrant: (org, agentId, nodeId, role) => api.put(`${base(org)}/agents/${enc(agentId)}/grants/${enc(nodeId)}`, { role }),
  removeAgentGrant: (org, agentId, nodeId) => api.delete(`${base(org)}/agents/${enc(agentId)}/grants/${enc(nodeId)}`),

  // Mail (spec F9), MX mail only. Not under /disk: under the org's messages.
  saveToDisk: (org, messageId, attachmentId, attrs) => api.post(`/orgs/${enc(org)}/messages/${enc(messageId)}/attachments/${enc(attachmentId)}/save-to-disk`, attrs), // { node }
  // On a draft. 422 data.code ATTACHMENT_TOO_LARGE with data.limit_bytes: offer a link instead.
  attachFromDisk: (org, messageId, nodeId) => api.post(`/orgs/${enc(org)}/messages/${enc(messageId)}/attachments/from-disk`, { node_id: nodeId }), // { attachment }

  events: (org, id, cursor) => api.get(`${base(org)}/nodes/${enc(id)}/events${qs({ cursor })}`), // { events: [{ action, detail, created_at, actor: { id, name, agent }, link_id }], next_cursor }

  search: (org, q, scope, modified) => api.get(`${base(org)}/search${qs({ q, scope, ...modifiedParams(modified) })}`), // { results: [node with path] }
  // name: shared-with-me | recent | starred | trash. { nodes, next_cursor }
  view: (org, name, cursor) => api.get(`${base(org)}/views/${name}${qs({ cursor })}`),

  // Shares on D:\
  shares: (org, trashed) => api.get(`${base(org)}/shares${qs({ trashed: trashed ? 'true' : '' })}`),
  createShare: (org, attrs) => api.post(`${base(org)}/shares`, attrs),
  updateShare: (org, id, attrs) => api.patch(`${base(org)}/shares/${enc(id)}`, attrs),
  deleteShare: (org, id, confirmName) => api.delete(`${base(org)}/shares/${enc(id)}${qs({ confirm_name: confirmName })}`),
  restoreShare: (org, id) => api.post(`${base(org)}/shares/${enc(id)}/restore`),
  purgeShare: (org, id) => api.delete(`${base(org)}/shares/${enc(id)}/purge`),
  shareTemplates: (org, names, domainId) => api.post(`${base(org)}/shares/templates`, { names, domain_id: domainId || null }),
  shareMembers: (org, id) => api.get(`${base(org)}/shares/${enc(id)}/members`), // { members: [{ membership_id, name, role }] }
  setShareMember: (org, id, membershipId, role) => api.put(`${base(org)}/shares/${enc(id)}/members/${enc(membershipId)}`, { role }),
  removeShareMember: (org, id, membershipId) => api.delete(`${base(org)}/shares/${enc(id)}/members/${enc(membershipId)}`),
}

export default diskApi
