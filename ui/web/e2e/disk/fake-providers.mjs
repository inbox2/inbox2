// Local stand-ins for Google Drive, Microsoft 365 and Dropbox, for spec F10.
// The e2e Rails points the importers here through DISK_IMPORT_<P>_<NAME>_URL
// (env.js; Disk::ImportSource.url refuses those in production). One small HTTP
// server serves each provider's consent redirect, token exchange and the file
// API calls the adapters make (api/app/services/disk/importer/*.rb), over one
// fixed tree:
//
//   personal: Projects/ (shared with Cal and an outsider, public link)
//               Specs/spec.txt, notes.txt, Plan.txt + plan.txt (case clash)
//             old-name.txt, doomed.txt, corrupt.bin (served bytes never match
//             the hash), Roadmap (a Doc / Paper doc: markdown), Budget (a Sheet:
//             xlsx), Deck (Slides: pptx, Google), Team notebook (no content)
//   shared:   the team space with team.txt (+ a SharePoint list on Microsoft)
//   members:  Cal's drive (cal.txt) and Stan's (no inbox2 member)
//
// bigDoc (Google): adds a Doc whose export is over the 5 MB page limit.
// Pass 2 (POST /_ctl/<p> {pass: 2}): notes.txt changed, old-name.txt renamed
// new-name.txt, doomed.txt deleted; reported through each source's change feed.
// Faults, each once when armed: a 429 with Retry-After on the first listing,
// Microsoft's 410 on the delta link, a revoked grant (401 + invalid_grant until
// the person connects again), Dropbox's data transport cap. holdAfter: n lets n
// downloads through, then holds the rest until {release: true}.
//
//   node fake-providers.mjs <port> <samples dir>
import http from 'node:http'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const PORT = Number(process.argv[2] || 4623)
const SAMPLES = process.argv[3]
const ORIGIN = `http://127.0.0.1:${PORT}`
const EMAIL = { ivy: 'ivy@imp.e2e.test', cal: 'cal@imp.e2e.test', stan: 'stan@imp.e2e.test', out: 'pat@outside.e2e.test' }
const NAMES = { google: 'Google Team', microsoft: 'SharePoint Team', dropbox: 'Dropbox Team' }
const sample = (n) => fs.readFileSync(path.join(SAMPLES, n))
const T1 = '2026-09-01T10:00:00Z'
const T2 = '2026-09-02T10:00:00Z'

// ── the tree ────────────────────────────────────────────────────────────────
// kind: folder | file | doc (markdown) | sheet (xlsx) | slides (pptx) | none
function tree(space, pass, provider, big = false) {
  if (space === 'shared') return [{ id: 'x-team', name: 'team.txt', kind: 'file', body: 'team\n' }]
  if (space === 'cal') return [{ id: 'x-cal', name: 'cal.txt', kind: 'file', body: 'cal\n' }]
  if (space === 'stan') return [{ id: 'x-stan', name: 'stan.txt', kind: 'file', body: 'stan\n' }]
  const items = [
    { id: 'f-projects', name: 'Projects', kind: 'folder', shared: true },
    { id: 'f-specs', name: 'Specs', kind: 'folder', parent: 'f-projects' },
    { id: 'x-spec', name: 'spec.txt', kind: 'file', parent: 'f-specs', body: 'spec v1\n' },
    { id: 'x-notes', name: 'notes.txt', kind: 'file', parent: 'f-projects', body: pass === 2 ? 'notes v2, changed at the source\n' : 'notes v1\n', mtime: pass === 2 ? T2 : T1 },
    { id: 'x-plan-a', name: 'Plan.txt', kind: 'file', parent: 'f-projects', body: 'upper\n' },
    { id: 'x-plan-b', name: 'plan.txt', kind: 'file', parent: 'f-projects', body: 'lower\n' },
    { id: 'x-old', name: pass === 2 ? 'new-name.txt' : 'old-name.txt', kind: 'file', body: 'renamed at the source\n' },
    ...(pass === 2 ? [] : [{ id: 'x-doomed', name: 'doomed.txt', kind: 'file', body: 'deleted at the source\n' }]),
    { id: 'x-corrupt', name: 'corrupt.bin', kind: 'file', body: 'the real bytes\n', corrupt: true },
    { id: 'n-notebook', name: 'Team notebook', kind: 'none' },
  ]
  // Microsoft holds Office files as files: nothing to convert.
  if (provider !== 'microsoft') {
    items.push({ id: 'd-roadmap', name: 'Roadmap', kind: 'doc', body: '# Roadmap\n\n## Next\n\n- Ship the importer\n- Tell customers\n' })
    items.push({ id: 'd-budget', name: 'Budget', kind: 'sheet' })
  }
  if (provider === 'google') items.push({ id: 'd-deck', name: 'Deck', kind: 'slides' })
  // bigDoc: a Doc whose markdown export is over Disk's 5 MB page limit.
  if (big) items.push({ id: 'd-big', name: 'Big notes', kind: 'doc', body: `# Big notes\n\n${'A long line of meeting notes that goes on.\n'.repeat(140_000)}` })
  return items.map((i) => ({ mtime: T1, parent: null, ...i }))
}
const CHANGED = ['x-notes', 'x-old'] // pass 1 -> 2, plus x-doomed deleted
const sharing = [{ email: EMAIL.cal, role: 'writer' }, { email: EMAIL.out, role: 'reader' }]
const spaceSharing = [{ email: EMAIL.ivy, role: 'organizer' }, ...sharing]
const exportBytes = (i) => (i.kind === 'doc' ? Buffer.from(i.body) : sample(i.kind === 'sheet' ? 'budget.xlsx' : 'deck.pptx'))
const served = (i) => Buffer.from(i.corrupt ? i.body.replace('real', 'altered') : i.body)

// ── hashes the sources publish ──────────────────────────────────────────────
const md5 = (b) => crypto.createHash('md5').update(b).digest('hex')
function quickXor(buf) { // learn.microsoft.com/onedrive/developer/code-snippets/quickxorhash
  const W = 160n
  const MASK = (1n << W) - 1n
  let block = 0n
  for (let i = 0; i < buf.length; i++) {
    const v = BigInt(buf[i]) << BigInt((i * 11) % 160)
    block ^= (v & MASK) | (v >> W)
  }
  const out = Buffer.alloc(20)
  for (let j = 0; j < 20; j++) out[j] = Number((block >> BigInt(8 * j)) & 0xffn)
  const len = Buffer.alloc(8)
  len.writeBigUInt64LE(BigInt(buf.length))
  for (let j = 0; j < 8; j++) out[12 + j] ^= len[j]
  return out.toString('base64')
}
function contentHash(buf) { // Dropbox: SHA-256 of each 4 MiB block's SHA-256
  const blocks = []
  for (let o = 0; o < Math.max(buf.length, 1); o += 4 * 1024 * 1024) blocks.push(crypto.createHash('sha256').update(buf.subarray(o, o + 4 * 1024 * 1024)).digest())
  return crypto.createHash('sha256').update(buf.length ? Buffer.concat(blocks) : Buffer.alloc(0)).digest('hex')
}

// ── state and control ───────────────────────────────────────────────────────
const fresh = () => ({ bigDoc: false, pass: 1, throttleOnce: false, goneOnce: false, revoked: false, capOnce: false, holdAfter: null, downloads: 0, calls: [] })
const state = { google: fresh(), microsoft: fresh(), dropbox: fresh() }
let release = null
let held = new Promise((r) => { release = r })
async function gate(s) {
  s.downloads += 1
  if (s.holdAfter !== null && s.downloads > s.holdAfter) await held
}

const send = (res, status, body, headers = {}) => {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body ?? {}))
  res.writeHead(status, { 'Content-Type': Buffer.isBuffer(body) ? 'application/octet-stream' : 'application/json', 'Content-Length': buf.length, ...headers })
  res.end(buf)
}
const json = (res, body, headers) => send(res, 200, body, headers)
const redirect = (res, to) => { res.writeHead(302, { Location: to }); res.end() }
const readBody = (req) => new Promise((r) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => r(Buffer.concat(c).toString())) })

// Consent: always granted, straight back to inbox2 with a code. Reconnecting clears a revoked grant.
function authorize(p, url, res) {
  state[p].revoked = false
  state[p].calls.push({ authorize: Object.fromEntries(url.searchParams) })
  const back = new URL(url.searchParams.get('redirect_uri'))
  back.searchParams.set('code', `code-${p}`)
  back.searchParams.set('state', url.searchParams.get('state'))
  redirect(res, back.toString())
}

// A token response. Microsoft's carries the tenant id in its claims; Google's
// service-account grant names the person it acts as.
function token(p, form, res) {
  const s = state[p]
  if (form.grant_type === 'refresh_token' && s.revoked) return send(res, 400, { error: 'invalid_grant', error_description: 'Token has been revoked' })
  let access = `at-${p}`
  if (form.grant_type === 'urn:ietf:params:oauth:grant-type:jwt-bearer') {
    const claims = JSON.parse(Buffer.from(form.assertion.split('.')[1], 'base64url').toString())
    access = `sa:${claims.sub}`
  }
  if (p === 'microsoft') access = `x.${Buffer.from(JSON.stringify({ tid: 'fake-tenant' })).toString('base64url')}.${access}`
  json(res, { access_token: access, refresh_token: `rt-${p}`, expires_in: 3600, token_type: 'bearer', scope: form.scope, account_id: 'dbid:ivy', team_id: 'dbtid:team' })
}

// The person a member-space token or header acts as.
const SPACE_OF = { [EMAIL.cal]: 'cal', [EMAIL.stan]: 'stan', 'u-cal': 'cal', 'u-stan': 'stan', 'dbmid:cal': 'cal', 'dbmid:stan': 'stan' }

// ── Google Drive v3 ─────────────────────────────────────────────────────────
const GMIME = { folder: 'application/vnd.google-apps.folder', doc: 'application/vnd.google-apps.document', sheet: 'application/vnd.google-apps.spreadsheet', slides: 'application/vnd.google-apps.presentation', none: 'application/vnd.google-apps.form' }
function google(sub, url, req, res) {
  const s = state.google
  const auth = req.headers.authorization || ''
  if (s.revoked) return send(res, 401, { error: { message: 'Invalid Credentials' } })
  const drive = url.searchParams.get('driveId')
  const space = drive ? 'shared' : (SPACE_OF[auth.replace('Bearer sa:', '')] || 'personal')
  const root = drive || `root-${space}`
  const items = tree(space, s.pass, 'google', s.bigDoc && space === 'personal')
  const meta = (i) => ({
    id: i.id, name: i.name, mimeType: GMIME[i.kind] || 'text/plain', parents: [i.parent || root], modifiedTime: i.mtime, trashed: false,
    shared: !!i.shared, ...(i.kind === 'file' ? { size: String(Buffer.byteLength(i.body)), md5Checksum: md5(Buffer.from(i.body)) } : {}),
  })
  // Drive addresses a file by id alone: look in every space.
  const find = (id) => items.find((i) => i.id === id) || ['personal', 'shared', 'cal', 'stan'].flatMap((sp) => tree(sp, s.pass, 'google')).find((i) => i.id === id)
  let m
  if (sub === '/drives') return json(res, { drives: [{ id: 'drv-team', name: NAMES.google }] })
  if (sub === '/directory') return json(res, { users: [{ id: 'u-cal', primaryEmail: EMAIL.cal, name: { fullName: 'Cal Colleague' } }, { id: 'u-stan', primaryEmail: EMAIL.stan, name: { fullName: 'Stan Stranger' } }] })
  if (sub === '/files/root') return json(res, { id: root })
  if (sub === '/changes/startPageToken') return json(res, { startPageToken: `t${s.pass}` })
  if (sub === '/files') {
    if (s.throttleOnce && space === 'personal') { s.throttleOnce = false; return send(res, 429, { error: { message: 'Rate Limit Exceeded' } }, { 'Retry-After': '6' }) }
    const page = Number(url.searchParams.get('pageToken') || 0)
    const list = items.slice(page, page + 5).map(meta)
    return json(res, { files: list, ...(page + 5 < items.length ? { nextPageToken: String(page + 5) } : {}) })
  }
  if (sub === '/changes') {
    const from = url.searchParams.get('pageToken')
    if (from === `t${s.pass}`) return json(res, { changes: [], newStartPageToken: from })
    const changes = CHANGED.map((id) => ({ fileId: id, removed: false, file: meta(find(id)) })).concat([{ fileId: 'x-doomed', removed: true }])
    return json(res, { changes: space === 'personal' ? changes : [], newStartPageToken: `t${s.pass}` })
  }
  if ((m = sub.match(/^\/files\/([^/]+)\/permissions$/))) {
    const list = m[1] === root ? spaceSharing : sharing
    const perms = list.map((x) => ({ type: 'user', role: x.role, emailAddress: x.email }))
    return json(res, { permissions: m[1] === root ? perms : [...perms, { type: 'anyone', role: 'reader' }] })
  }
  if ((m = sub.match(/^\/files\/([^/]+)\/export$/))) {
    const i = find(m[1])
    return gate(s).then(() => send(res, 200, exportBytes(i)))
  }
  if ((m = sub.match(/^\/files\/([^/]+)$/))) {
    const i = find(m[1])
    if (!i) return send(res, 404, { error: { message: 'File not found' } })
    if (url.searchParams.get('alt') !== 'media') return json(res, meta(i))
    s.calls.push({ download: i.id })
    return gate(s).then(() => send(res, 200, served(i)))
  }
  return send(res, 404, { error: { message: `fake google: no ${sub}` } })
}

// ── Microsoft Graph ─────────────────────────────────────────────────────────
function microsoft(sub, url, req, res) {
  const s = state.microsoft
  const G = `${ORIGIN}/microsoft/graph`
  if (s.revoked && !sub.startsWith('/dl/') && !/^Bearer x\.[^.]+\.org-token$/.test(req.headers.authorization || '')) return send(res, 401, { error: { code: 'InvalidAuthenticationToken', message: 'Access token has expired' } })
  if (sub === '/me') return json(res, { mail: EMAIL.ivy, userPrincipalName: EMAIL.ivy })
  if (sub === '/users') return json(res, { value: [{ id: 'u-cal', displayName: 'Cal Colleague', mail: EMAIL.cal }, { id: 'u-stan', displayName: 'Stan Stranger', mail: EMAIL.stan }] })
  if (sub === '/sites/getAllSites') return json(res, { value: [{ id: 'site-team', displayName: NAMES.microsoft }] })
  if (sub === '/sites/site-team/drives') return json(res, { value: [{ id: 'drv-team', name: 'Documents', driveType: 'documentLibrary' }] })
  if (sub === '/sites/site-team/lists') return json(res, { value: [{ id: 'l-tasks', displayName: 'Tasks', list: { template: 'genericList' } }, { id: 'l-docs', displayName: 'Documents', list: { template: 'documentLibrary' } }] })
  if (sub === '/drives/drv-team') return json(res, { id: 'drv-team', sharePointIds: { siteId: 'site-team' } })
  let m = sub.match(/^\/dl\/(\w+)\/(.+)$/)
  if (m) {
    const i = tree(m[1], s.pass, 'microsoft').find((x) => x.id === m[2])
    s.calls.push({ download: i.id, auth: req.headers.authorization || null })
    return gate(s).then(() => send(res, 200, served(i)))
  }
  m = sub.match(/^(\/me\/drive|\/drives\/drv-team|\/users\/(u-\w+)\/drive)(\/.*)$/)
  if (!m) return send(res, 404, { error: { code: 'itemNotFound', message: `fake graph: no ${sub}` } })
  const [, drive, user, rest] = m
  const space = drive === '/drives/drv-team' ? 'shared' : user ? SPACE_OF[user] : 'personal'
  const root = `root-${space}`
  const items = tree(space, s.pass, 'microsoft')
  const find = (id) => items.find((i) => i.id === id)
  const meta = (i) => {
    const base = { id: i.id, name: i.name, parentReference: { id: i.parent || root }, lastModifiedDateTime: i.mtime, ...(i.shared ? { shared: { scope: 'users' } } : {}) }
    if (i.kind === 'folder') return { ...base, folder: { childCount: 1 } }
    if (i.kind === 'none') return { ...base, package: { type: 'oneNote' } }
    const body = Buffer.from(i.body)
    return { ...base, size: body.length, file: { hashes: { quickXorHash: quickXor(body) } }, '@microsoft.graph.downloadUrl': `${G}/dl/${space}/${i.id}` }
  }
  const delta = (token) => `${G}${drive}/root/delta?token=${token}`
  if (rest === '/root') return json(res, { id: root })
  if (rest === '/root/delta') {
    const token = url.searchParams.get('token')
    if (!token && s.throttleOnce && space === 'personal') { s.throttleOnce = false; return send(res, 429, { error: { code: 'activityLimitReached' } }, { 'Retry-After': '6' }) }
    if (!token) return json(res, { value: [{ id: root, name: 'root', root: {}, folder: {} }, ...items.slice(0, 4).map(meta)], '@odata.nextLink': delta('page2') })
    if (token === 'page2') return json(res, { value: items.slice(4).map(meta), '@odata.deltaLink': delta(`d${s.pass}`) })
    if (token === `d${s.pass}`) return json(res, { value: [], '@odata.deltaLink': delta(`d${s.pass}`) })
    if (s.goneOnce) { s.goneOnce = false; return send(res, 410, { error: { code: 'resyncRequired', message: 'The delta token is no longer valid' } }, { Location: delta('resync') }) }
    const changes = space === 'personal' ? [...CHANGED.map((id) => meta(find(id))), { id: 'x-doomed', deleted: { state: 'deleted' } }] : []
    return json(res, { value: changes, '@odata.deltaLink': delta(`d${s.pass}`) })
  }
  if (rest === '/root/permissions' || (m = rest.match(/^\/items\/([^/]+)\/permissions$/))) {
    const list = rest === '/root/permissions' ? spaceSharing.map((x) => ({ ...x, role: x.role === 'organizer' ? 'owner' : x.role })) : sharing
    const perms = list.map((x) => ({ roles: [x.role === 'writer' ? 'write' : x.role === 'owner' ? 'owner' : 'read'], grantedToV2: { user: { email: x.email, displayName: x.email } } }))
    return json(res, { value: rest === '/root/permissions' ? perms : [...perms, { roles: ['read'], link: { scope: 'anonymous', type: 'view' } }] })
  }
  if ((m = rest.match(/^\/items\/([^/]+)$/))) {
    const i = find(m[1])
    return i ? json(res, meta(i)) : send(res, 404, { error: { code: 'itemNotFound' } })
  }
  return send(res, 404, { error: { code: 'itemNotFound', message: `fake graph: no ${sub}` } })
}

// ── Dropbox API v2 ──────────────────────────────────────────────────────────
function dropbox(sub, req, res, body) {
  const s = state.dropbox
  if (s.revoked) return send(res, 401, { error_summary: 'expired_access_token/' })
  const arg = req.headers['dropbox-api-arg'] ? JSON.parse(req.headers['dropbox-api-arg']) : body ? JSON.parse(body) : {}
  const root = req.headers['dropbox-api-path-root']
  const space = root ? 'shared' : SPACE_OF[req.headers['dropbox-api-select-user']] || 'personal'
  const items = tree(space, s.pass, 'dropbox')
  const find = (idOrPath) => items.find((i) => `id:${i.id}` === idOrPath || pathOf(i) === idOrPath)
  const pathOf = (i) => (i.parent ? `${pathOf(find(`id:${i.parent}`))}/${i.name}` : `/${i.name}`).toLowerCase()
  const entry = (i) => {
    const name = i.kind === 'doc' ? `${i.name}.paper` : i.kind === 'sheet' ? `${i.name}.gsheet` : i.kind === 'none' ? `${i.name}.web` : i.name
    const p = (i.parent ? pathOf(find(`id:${i.parent}`)) : '') + `/${name}`.toLowerCase()
    const base = { id: `id:${i.id}`, name, path_lower: p, path_display: p }
    if (i.kind === 'folder') return { '.tag': 'folder', ...base, ...(i.shared ? { sharing_info: { shared_folder_id: `sf-${i.id}` } } : {}) }
    const file = { '.tag': 'file', ...base, server_modified: i.mtime, has_explicit_shared_members: false }
    if (i.kind === 'doc') return { ...file, size: 0, is_downloadable: false, export_info: { export_as: 'markdown', export_options: ['markdown', 'html'] } }
    if (i.kind === 'sheet') return { ...file, size: 0, is_downloadable: false, export_info: { export_as: 'xlsx' } }
    if (i.kind === 'none') return { ...file, size: 0, is_downloadable: false }
    const b = Buffer.from(i.body)
    return { ...file, size: b.length, content_hash: contentHash(b), is_downloadable: true }
  }
  const members = (list) => ({
    users: list.filter((x) => x.role !== 'reader').map((x) => ({ access_type: { '.tag': x.role === 'organizer' ? 'owner' : 'editor' }, user: { email: x.email } })),
    invitees: list.filter((x) => x.role === 'reader').map((x) => ({ access_type: { '.tag': 'viewer' }, invitee: { '.tag': 'email', email: x.email } })),
    groups: [],
  })
  switch (sub) {
    case '/api/2/users/get_current_account': return json(res, { email: EMAIL.ivy, account_id: 'dbid:ivy' })
    case '/api/2/team/token/get_authenticated_admin': return json(res, { admin_profile: { team_member_id: 'dbmid:ivy', email: EMAIL.ivy } })
    case '/api/2/team/members/list_v2': return json(res, { has_more: false, members: [['dbmid:cal', EMAIL.cal, 'Cal Colleague'], ['dbmid:stan', EMAIL.stan, 'Stan Stranger']].map(([id, email, name]) => ({ profile: { team_member_id: id, email, status: { '.tag': 'active' }, name: { display_name: name } } })) })
    case '/api/2/team/namespaces/list': return json(res, { has_more: false, namespaces: [{ namespace_id: 'ns-team', name: NAMES.dropbox, namespace_type: { '.tag': 'team_folder' } }] })
    case '/api/2/files/list_folder': {
      if (s.throttleOnce && space === 'personal') { s.throttleOnce = false; return send(res, 429, { error_summary: 'too_many_requests/' }, { 'Retry-After': '6' }) }
      return json(res, { entries: items.map(entry), cursor: `c${s.pass}`, has_more: false })
    }
    case '/api/2/files/list_folder/continue': {
      if (arg.cursor === `c${s.pass}` || space !== 'personal') return json(res, { entries: [], cursor: `c${s.pass}`, has_more: false })
      // A rename is a deletion at the old path and the file at the new one, same id.
      const entries = [entry(find('id:x-notes')), { '.tag': 'deleted', name: 'old-name.txt', path_lower: '/old-name.txt' }, entry(find('id:x-old')), { '.tag': 'deleted', name: 'doomed.txt', path_lower: '/doomed.txt' }]
      return json(res, { entries, cursor: `c${s.pass}`, has_more: false })
    }
    case '/api/2/files/get_metadata': {
      const i = find(arg.path)
      return i ? json(res, entry(i)) : send(res, 409, { error_summary: 'path/not_found/' })
    }
    case '/api/2/sharing/list_folder_members': return json(res, members(arg.shared_folder_id === 'ns-team' ? spaceSharing : sharing))
    case '/api/2/sharing/list_file_members': return json(res, members(sharing))
    case '/content/2/files/download':
    case '/content/2/files/export': {
      if (s.capOnce) {
        s.capOnce = false
        return send(res, 403, { error_summary: 'invalid_account_type/', error: { '.tag': 'invalid_account_type' }, user_message: { locale: 'en', text: 'Your team has used all of its data transport API calls for the month.' } })
      }
      const i = find(arg.path)
      const bytes = sub.endsWith('export') ? exportBytes(i) : served(i)
      s.calls.push({ download: i.id })
      const result = sub.endsWith('export') ? { export_metadata: { name: i.name, size: bytes.length }, file_metadata: entry(i) } : entry(i)
      return gate(s).then(() => send(res, 200, bytes, { 'Dropbox-API-Result': JSON.stringify(result).replace(/[^\x20-\x7e]/g, '') }))
    }
    default: return send(res, 404, { error_summary: `fake dropbox: no ${sub}` })
  }
}

// ── routing ─────────────────────────────────────────────────────────────────
http.createServer(async (req, res) => {
  const url = new URL(req.url, ORIGIN)
  const body = req.method === 'POST' ? await readBody(req) : ''
  const [, p, ...rest] = url.pathname.split('/')
  const sub = `/${rest.join('/')}`
  try {
    if (p === '_health') return json(res, { ok: true })
    if (p === '_ctl') { // POST /_ctl/<p> {pass, throttleOnce, goneOnce, revoked, capOnce, holdAfter, release, reset}; GET answers the state
      const s = state[rest[0]]
      const set = body ? JSON.parse(body) : {}
      if (set.reset) Object.assign(s, fresh())
      if (set.release || set.reset) { release(); held = new Promise((r) => { release = r }); s.holdAfter = null; s.downloads = 0 }
      for (const k of ['bigDoc', 'pass', 'throttleOnce', 'goneOnce', 'revoked', 'capOnce', 'holdAfter']) if (k in set) s[k] = set[k]
      if ('holdAfter' in set) s.downloads = 0
      return json(res, s)
    }
    if (!state[p]) return send(res, 404, { error: 'unknown provider' })
    if (sub === '/authorize') return authorize(p, url, res)
    if (sub === '/token' || /^\/login\/[^/]+\/oauth2\/v2\.0\/token$/.test(sub)) {
      const form = Object.fromEntries(new URLSearchParams(body))
      state[p].calls.push({ token: form.grant_type })
      if (sub.startsWith('/login/')) return json(res, { access_token: `x.${Buffer.from(JSON.stringify({ tid: 'fake-tenant' })).toString('base64url')}.org-token`, expires_in: 3600 })
      return token(p, form, res)
    }
    if (p === 'microsoft' && sub === '/login/organizations/v2.0/adminconsent') { // tenant admin consent
      state.microsoft.calls.push({ authorize: Object.fromEntries(url.searchParams) })
      const back = new URL(url.searchParams.get('redirect_uri'))
      back.searchParams.set('admin_consent', 'True')
      back.searchParams.set('tenant', 'fake-tenant')
      back.searchParams.set('state', url.searchParams.get('state'))
      return redirect(res, back.toString())
    }
    if (p === 'google' && sub === '/userinfo') return json(res, { email: EMAIL.ivy })
    state[p].calls.push({ call: `${req.method} ${sub}${url.search}` })
    if (p === 'google') return google(sub.replace(/^\/drive\/v3/, ''), url, req, res)
    if (p === 'microsoft') return microsoft(sub.replace(/^\/graph/, ''), url, req, res)
    return dropbox(sub, req, res, body)
  } catch (e) {
    send(res, 500, { error: String(e?.stack || e) })
  }
}).listen(PORT, '127.0.0.1', () => console.log(`fake providers on ${ORIGIN}`))
