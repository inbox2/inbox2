import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link, Navigate, useLocation, useNavigate, useOutletContext, useSearchParams } from 'react-router'
import Breadcrumbs from '../../components/Breadcrumbs'
import BulkBar from '../../components/BulkBar'
import StarToggle from '../../components/StarToggle'
import FilterBar from '../../components/FilterBar'
import FileTypeIcon, { ActionIcon } from '../../components/FileTypeIcon'
import SlideOver from '../../components/SlideOver'
import Skeleton from '../../components/Skeleton'
import ContextMenu from '../../components/DropdownMenu/ContextMenu'
import DropdownMenu from '../../components/DropdownMenu/DropdownMenu'
import { MgmtButton, MgmtConfirm } from '../../components/management'
import useDebounce from '../../hooks/useDebounce'
import useDelayedFlag from '../../hooks/useDelayedFlag'
import useContextMenuTrigger from '../../hooks/useContextMenuTrigger'
import useDiskListing, { useDiskNode } from '../../hooks/useDiskListing'
import useDiskStore from '../../stores/diskStore'
import diskApi, { KEEP_BOTH, listingParams, REPLACE, SEAL } from '../../lib/disk/api'
import { EMPTY_FILTERS, hasActiveFilters, matchesFilters, sortNodes, defaultDir, TILE_SIZES } from '../../lib/disk/listing'
import { pathSegments, formatPath, nodeLabel } from '../../lib/disk/paths'
import { fileType } from '../../lib/disk/fileTypes'
import { crumbUrl, diskPath, diskSplat, drivePath, findOrgWith, editableAsPage, editUrl, EVENT_TEXT, IMPORT_SEGMENT, importableAsPage, plainSize, idFromSegment, idSegment, KIND, nodeUrl, parseDiskPath, pathUrl, previewUrl, ROLE, ROLE_LABEL, roleAtLeast, sameNode, shareRoot, shortId, SOURCE, teamLetter, VIEWS } from '../../lib/disk/model'
import SharesOverview from './SharesOverview'
import ImportPage from './ImportPage'
import formatBytes from '../../lib/formatBytes'
import { DISK_VIEW_MODE, DISK_TILE_SIZE } from '../../lib/storageKeys'
import { useE2ee } from '../../lib/e2eeStore'
import Dropzone from '../../components/Dropzone'
import { enqueue } from '../../lib/disk/upload'
import { openEngineForUpload } from '../../lib/disk/engine/rendition'
import { downloadFile, downloadVersion, downloadZip, saveUrl, zipReport } from '../../lib/disk/download'
import NodeList, { NodeListSkeleton, RenameField } from './NodeList'
import PreviewPane from './preview/PreviewPane'
import { BulkShareDialog, ConflictDialog, LinkDialog, MoveDialog, PeopleDialog, ShareSettingsDialog } from './DiskDialogs'
import useSealed, { scopeIdOf, useSealedSearch } from './sealed/useSealed'
import { CreateSealedDialog, CrossSealDialog, MoveToSealedShareDialog, SealedBanner, SealedLinkDialog, SealedMembersDialog, UnlockDialog } from './sealed/SealedUI'
import SealedPreview from './sealed/SealedPreview'
import useSealedStore from '../../stores/sealedStore'
import styles from './DiskBrowser.module.css'

// Typing into a field keeps the page's keys out; a checkbox (the row selectors) is not typing.
const isTyping = (el) => !!el && (/^(TEXTAREA|SELECT)$/.test(el.tagName) || el.isContentEditable
  || (el.tagName === 'INPUT' && !['checkbox', 'radio', 'button'].includes(el.type)))

// Drops a separator at the start or right after another one.
// A long folder name keeps its start and its end (where "v2" or a date usually is): "Quarterly re…ts 2026".
const TITLE_MAX = 48
const middleCut = (s, max) => (s.length <= max ? s : `${s.slice(0, Math.ceil((max - 1) / 2))}…${s.slice(s.length - Math.floor((max - 1) / 2))}`)
const tidySeparators = (out, it) => (it.separator && (!out.length || out.at(-1).separator) ? out : [...out, it])

// The page editor (Tiptap, Yjs, tables) loads only when a page opens.
const PageView = lazy(() => import('./page/PageView'))
const MarkdownFileEditor = lazy(() => import('./page/MarkdownFileEditor'))

function readViewMode() {
  try { return localStorage.getItem(DISK_VIEW_MODE) === 'grid' ? 'grid' : 'list' } catch { return 'list' }
}

function readTileSize() {
  let px = NaN
  try { px = Number(localStorage.getItem(DISK_TILE_SIZE)) } catch { /* storage blocked */ }
  return px >= TILE_SIZES.min && px <= TILE_SIZES.max ? px : TILE_SIZES.initial
}

/* Every Disk URL (/disk/*, or the root on disk.inbox2.com) lands here (lib/disk/model.js has the
 * scheme). A drive, a share or an id resolves to a folder, a page (the editor)
 * or a file (its folder with the file previewed). The id is the authority: once
 * the node loads, a stale path is replaced with the current one. Each location
 * mounts its own Browser so filters and selection start fresh, while the store
 * keeps the previous listing on screen until the next lands. */
export default function DiskBrowser() {
  const splat = diskSplat(useLocation().pathname)
  const ctx = useOutletContext()
  const { search } = useLocation()
  const hint = useLocation().state
  const route = useMemo(() => parseDiskPath(splat), [splat])
  const shares = ctx.drives?.shares || []
  const share = route.shareSlug ? shares.find((s) => s.slug === route.shareSlug || s.slug?.toLowerCase() === route.shareSlug.toLowerCase()) : null
  const nodeId = route.id || share?.root_node_id || null
  const { node, error } = useDiskNode(ctx.orgId, route.id)
  const viewDef = route.view ? VIEWS.find((v) => v.slug === route.view) : null
  // ?edit=<name>-<id>: a markdown file in the page editor ("Edit as page", spec F6).
  const editId = idFromSegment(new URLSearchParams(search).get('edit'))
  const { node: editNode } = useDiskNode(ctx.orgId, editId)

  if (route.redirect) return <Navigate to={`${drivePath('C')}${search}`} replace />
  if (route.notFound) return <NotFound />
  if (route.shareSlug && ctx.drives && !share) return <Elsewhere key={`s:${ctx.orgId}:${route.shareSlug}`} ctx={ctx} shareSlug={route.shareSlug} />
  if (route.overview) return <SharesOverview />
  if (route.imports) return <ImportPage />
  if (editId) return sameNode(editNode, editId) ? <Suspense fallback={null}><MarkdownFileEditor key={editId} ctx={ctx} node={editNode} /></Suspense> : null
  const folderId = nodeId || (viewDef ? null : ctx.drives?.c_drive.id)
  // The drives are still loading (a share slug or C:\ resolves through them): the page frame, nothing fetched yet.
  if (!viewDef && !folderId) return <Browser key="pending" ctx={ctx} folderId={null} viewDef={null} pending />
  if (route.id) {
    const kind = sameNode(node, route.id) ? node.kind : hint?.kind || (hint?.path ? KIND.FOLDER : null)
    if (error?.status === 404) return <Elsewhere key={`n:${ctx.orgId}:${route.id}`} ctx={ctx} nodeId={route.id} />
    if (kind === KIND.PAGE && sameNode(node, route.id)) return <Suspense fallback={null}><PageView key={route.id} ctx={ctx} node={node} /></Suspense>
    if (kind === KIND.FILE && sameNode(node, route.id)) {
      const parentPath = node.path?.length > 1 ? node.path.slice(0, -1) : [{ short_id: shortId(node.parent_id), name: 'folder', kind: 'folder' }]
      return <Navigate to={previewUrl(pathUrl(parentPath), node)} replace />
    }
    // Kind not known yet (a deep link): the folder page's frame, with nothing fetched until it is.
    if (kind !== KIND.FOLDER) return <Browser key={shortId(folderId)} ctx={ctx} folderId={folderId} viewDef={null} pending />
  }
  return <Browser key={route.view || shortId(folderId)} ctx={ctx} folderId={folderId} viewDef={viewDef} />
}

/* Not in this org: colleagues paste links, and a node id is unique across orgs, so the
 * person's other orgs are tried (a node by id, a share by slug) and Disk switches to the
 * one that has it. The link carried the sender's drive letter; the address is corrected
 * to the viewer's own letter for that team. Not found anywhere: the not-found screen. */
function Elsewhere({ ctx, nodeId, shareSlug }) {
  const [missing, setMissing] = useState(false)
  const { orgId, organizations, switchOrg } = ctx
  const { pathname, search } = useLocation()
  const navigate = useNavigate()
  useEffect(() => {
    let live = true
    const has = nodeId ? (o) => diskApi.node(o.id, nodeId).then(() => true)
      : (o) => diskApi.shares(o.id).then((d) => d.shares.some((x) => x.slug === shareSlug))
    findOrgWith(organizations, orgId, has).then((o) => {
      if (!live) return
      if (!o) return setMissing(true)
      switchOrg(o)
      const [, ...rest] = diskSplat(pathname).split('/')
      navigate(`${[drivePath('D', teamLetter(o)), ...rest].join('/')}${search}`, { replace: true })
    })
    return () => { live = false }
  }, [orgId, organizations, switchOrg, nodeId, shareSlug, pathname, search, navigate])
  return missing ? <NotFound /> : <div className={styles.sec} aria-busy="true"><Skeleton variant="row" count={4} /></div>
}

function NotFound({ message = "This folder doesn't exist, or it hasn't been shared with you." }) {
  return (
    <div className={styles.emptyCard} role="alert">
      <FileTypeIcon kind="folder" size={72} />
      <p><b>Not found.</b><br />{message}</p>
      <MgmtButton as={Link} to={drivePath('C')} variant="glass" size="sm">Go to My disk</MgmtButton>
    </div>
  )
}

function Browser({ ctx, folderId, viewDef, pending = false }) {
  const { orgId, slug, drives, people } = ctx
  const navigate = useNavigate()
  const hint = useLocation().state // { drive, path } from the click that brought us here
  const [searchParams, setSearchParams] = useSearchParams()
  const invalidate = useCallback(() => useDiskStore.getState().invalidate(orgId), [orgId])

  const [value, setValue] = useState(() => ({
    ...EMPTY_FILTERS,
    sort: viewDef ? 'modified' : 'name',
    dir: viewDef ? -1 : 1,
    view: readViewMode(),
    tile: readTileSize(),
  }))
  const changeValue = (next) => {
    if (next.view !== value.view) { try { localStorage.setItem(DISK_VIEW_MODE, next.view) } catch { /* storage blocked */ } }
    if (next.tile !== value.tile) { try { localStorage.setItem(DISK_TILE_SIZE, String(next.tile)) } catch { /* storage blocked */ } }
    setValue(next)
  }

  const { node: folder, error: folderError } = useDiskNode(orgId, folderId && shortId(folderId))
  const role = viewDef ? ROLE.EDIT : folder?.access?.role
  // Read-only after a downgrade (spec F8): deleting still works, nothing else that writes.
  const canDelete = roleAtLeast(role, ROLE.EDIT)
  const canEdit = canDelete && ctx.writable !== false
  const share = folder?.share_id ? drives?.shares.find((s) => s.id === folder.share_id) : null
  const isTrash = viewDef?.slug === 'trash'

  const q = useDebounce(value.q.trim(), 250)
  const source = pending ? null : q
    ? { kind: 'search', q, scope: value.everywhere || viewDef ? 'all' : folderId, modified: value.modified }
    : viewDef ? { kind: 'view', name: viewDef.slug } : { kind: 'folder', id: shortId(folderId), params: listingParams(value) }
  const listing = useDiskListing(orgId, source)
  const clientSide = !!source && source.kind !== 'folder'
  const listed = useMemo(() => {
    const raw = listing.data?.nodes || []
    return clientSide ? sortNodes(raw.filter((n) => matchesFilters(n, { ...value, q: '' })), value.sort, value.dir) : raw
  }, [listing.data, clientSide, value])
  // Sealed (spec F7): names open here once the scope's key is; search inside a scope runs here too.
  const sealed = useSealed(orgId, folder, listed)
  const sealedHits = useSealedSearch(orgId, sealed.lib, sealed.scope, q)
  const nodes = sealedHits || sealed.nodes
  const scope = sealed.scope
  const inScope = !!sealed.scopeId
  const locked = (n) => n.sealed && !n.opened
  const { identityStatus } = useE2ee()
  const scopes = useSealedStore((st) => st.scopes)
  // The opened scope a sealed node belongs to: this folder's, or its own when it is a scope root listed here.
  const scopeOf = (n) => (inScope ? scope : n?.sealed ? scopes[`${orgId}/${n.id}`]?.scope || null : null)
  const lib = async () => sealed.lib || import('../../lib/disk/sealed')
  // Every sealed write: a rotation since the key was fetched gets the new grant and one retry;
  // a scope frozen by a departed holder points to the renewal.
  const sealedWrite = async (fn, s = scope) => {
    if (!s) throw new Error('Unlock your key to change sealed items.')
    try {
      return await fn(s, await lib())
    } catch (e) {
      if (e?.data?.code === SEAL.EPOCH_CHANGED) return fn(await useSealedStore.getState().reopen(orgId, s.id), await lib())
      if (e?.data?.code === SEAL.ROTATION_REQUIRED) throw new Error('A key holder left: renew the key before you change anything here.', { cause: e })
      throw e
    }
  }
  const showSkeleton = useDelayedFlag((listing.loading || pending) && !listing.data, 150)

  // ── selection ──
  const [selected, setSelected] = useState(() => new Set())
  const [anchor, setAnchor] = useState(null)
  const [focusIndex, setFocusIndex] = useState(0)
  const selNodes = nodes.filter((n) => selected.has(n.id))
  const listRef = useRef(null)

  const focusRow = (i) => {
    const row = listRef.current?.querySelector(`[data-index="${i}"]`)
    const target = row?.matches('[role="option"]') ? row : row?.querySelector('button')
    target?.focus({ preventScroll: true })
    row?.scrollIntoView({ block: 'nearest' })
  }
  const pick = (i, e = {}) => {
    const id = nodes[i]?.id
    if (!id) return
    if (e.shiftKey && anchor != null) {
      const [a, b] = [anchor, i].sort((x, y) => x - y)
      setSelected(new Set(nodes.slice(a, b + 1).map((n) => n.id)))
    } else if (e.metaKey || e.ctrlKey) {
      const next = new Set(selected)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      setSelected(next)
      setAnchor(i)
    } else {
      setSelected(new Set([id]))
      setAnchor(i)
    }
    setFocusIndex(i)
  }
  const clearSelection = () => setSelected(new Set())

  // ── feedback ──
  const [toast, setToast] = useState(null)
  useEffect(() => {
    if (!toast) return undefined
    const t = setTimeout(() => setToast(null), 4000)
    return () => clearTimeout(t)
  }, [toast])
  const say = (text) => setToast(text)
  const fail = (e) => say(e?.message || "That didn't work.")

  // ── dialogs, menu, preview ──
  const [dialog, setDialog] = useState(null)
  const [menu, setMenu] = useState(null)
  const [renamingId, setRenamingId] = useState(null)
  const [wantFull, setWantFull] = useState(false)
  // Dropzone's file picker, kept so the header button and the menu can open it.
  const chooseRef = useRef(null)
  // ?open=<name>-<id>: the id is what counts.
  const openId = idFromSegment(searchParams.get('open'))
  const { node: openRaw } = useDiskNode(orgId, openId)
  const setOpen = (n) => setSearchParams((sp) => {
    const next = new URLSearchParams(sp)
    if (n) next.set('open', idSegment(n))
    else next.delete('open')
    return next
  }, { replace: true })

  // A 409 asks once: keep both (the API picks "a (1)"), replace (copies of files:
  // a new version of the one there), or leave it.
  const withConflict = (fn, { replace = false } = {}) => fn(false).catch((e) => {
    if (e.status !== 409) throw e
    return new Promise((resolve, reject) => setDialog({
      type: 'conflict',
      message: e.message,
      onKeep: () => { setDialog(null); fn(KEEP_BOTH).then(resolve, reject) },
      onReplace: replace ? () => { setDialog(null); fn(REPLACE).then(resolve, reject) } : null,
      onCancel: () => { setDialog(null); resolve(null) },
    }))
  })

  // ── actions ──
  // URLs (lib/disk/model.js): a path of nodes from the top of what is visible, or a node on its own.
  const urlOf = (path) => pathUrl(path)
  const childPath = (n) => (n.path ? n.path : [...(folder?.path || []), n])
  const childUrl = (n) => (folder || n.path ? pathUrl(childPath(n)) : nodeUrl(n))
  const open = (n) => {
    if (locked(n)) return identityStatus === 'unlocked' ? say('You hold no key for this sealed item.') : setDialog({ type: 'unlock', node: n })
    if (isTrash) return say('Restore it first to open it.')
    if (n.kind === KIND.PAGE) return navigate(childUrl(n), { state: { kind: KIND.PAGE } })
    if (n.kind === KIND.FOLDER) {
      // Hand the next page the path it will show, so its breadcrumbs draw before its details load.
      return navigate(childUrl(n), { state: { kind: KIND.FOLDER, drive: n.drive, path: childPath(n) } })
    }
    setOpen(n)
  }
  const openFull = (n) => { setOpen(n); setWantFull(true) }
  // The sealed item clicked before unlocking opens once its scope has (useSealed reopens on unlock).
  // A ref, not state: the unlock itself re-renders the listing, which runs this.
  const pendingOpen = useRef(null) // { id, folderId }
  useEffect(() => {
    const p = pendingOpen.current
    if (!p) return
    if (p.folderId !== folderId) { pendingOpen.current = null; return }
    const n = nodes.find((x) => x.id === p.id)
    if (n && !locked(n)) { pendingOpen.current = null; open(n) }
  }, [nodes, folderId]) // eslint-disable-line react-hooks/exhaustive-deps
  // Until the folder's details land, the path the click handed over (hint) is the one on screen.
  const goUp = () => {
    const path = folder?.path || hint?.path || []
    const drive = folder?.drive || hint?.drive
    if (path.length > 1) navigate(urlOf(path.slice(0, -1)))
    else if (drive) navigate(drivePath(drive))
  }
  const openScope = openRaw?.sealed ? scopeOf(openRaw) : null
  const openNode = openScope && sealed.lib ? sealed.lib.openNames(openScope, [openRaw])[0] : openRaw
  const newPage = () => (inScope ? sealedWrite((s, L) => L.createSealedChild({ orgId, scope: s, parentId: folderId, name: 'Untitled', kind: KIND.PAGE })) : diskApi.createPage(orgId, folderId, 'Untitled'))
    .then(({ node }) => { invalidate(); navigate(childUrl(node), { state: { kind: KIND.PAGE } }) })
    .catch(fail)
  const newFolder = () => (inScope ? sealedWrite((s, L) => L.createSealedChild({ orgId, scope: s, parentId: folderId, name: 'New folder' })) : diskApi.createFolder(orgId, folderId, 'New folder', true))
    .then(({ node }) => { invalidate(); fresh.current = node.id; setRenamingId(node.id) })
    .catch(fail)
  // A folder New folder just made, until it is named: Escape on its name takes it away again
  // (trash, then purge, so it never shows in the trash).
  const fresh = useRef(null)
  const cancelRename = ({ escape } = {}) => {
    const id = renamingId
    setRenamingId(null)
    const wasFresh = !!id && fresh.current === id
    fresh.current = null // kept as it was (clicked away, unchanged name): an ordinary folder from now on
    if (!escape || !wasFresh) return
    diskApi.trash(orgId, id).then(() => diskApi.purge(orgId, id)).then(invalidate).catch(fail)
  }
  const rename = (n, name) => {
    fresh.current = null
    setRenamingId(null)
    // ponytail: sealed names are not checked for clashes (the API cannot see them); the client does not either yet.
    if (n.sealed) return withConflict((kb) => sealedWrite((s, L) => L.renameSealed(orgId, s, n, name, kb))).then((r) => { if (r) invalidate() }).catch(fail)
    withConflict((kb) => diskApi.rename(orgId, n.id, name, kb)).then((r) => { if (r) invalidate() }).catch(fail)
  }
  const star = (list, on) => Promise.all(list.map((n) => diskApi.star(orgId, n.id, on)))
    .then(() => { invalidate(); say(on ? 'Starred' : 'Removed from Starred') }).catch(fail)

  const bulk = async (op, list, target, keepBoth = false) => {
    const { results } = await diskApi.bulk(orgId, op, list.map((n) => n.id), target, keepBoth)
    invalidate()
    clearSelection()
    const failed = results.filter((r) => !r.ok)
    const clashes = failed.filter((r) => /already exists/.test(r.error || ''))
    if (op === 'move' && clashes.length && !keepBoth) {
      setDialog({
        type: 'conflict',
        message: `${clashes.length === 1 ? 'An item with the same name already exists' : `${clashes.length} items with the same name already exist`} there.`,
        onKeep: () => { setDialog(null); bulk(op, list.filter((n) => clashes.some((c) => c.id === n.id)), target, true).catch(fail) },
        onCancel: () => setDialog(null),
      })
    }
    const done = results.length - failed.length
    const verb = { move: 'moved', trash: 'moved to trash', restore: 'restored' }[op]
    say(failed.length
      ? `${done} ${verb}. ${failed.length} refused: ${failed[0].error}`
      : done === 1 ? `"${nodeLabel(list[0])}" ${verb}` : `${done} items ${verb}`)
    return failed
  }
  // A move across drives or shares, one item at a time so what was revoked can be reported.
  const moveAcross = async (list, target) => {
    const gone = { links: 0, grants: 0 }
    let done = 0
    for (const n of list) {
      const r = await withConflict((c) => diskApi.move(orgId, n.id, target, c)).catch((e) => { fail(e); return null })
      if (!r) continue
      done++
      gone.links += r.revoked?.links?.length || 0
      gone.grants += (r.revoked?.grants?.length || 0) + (r.revoked?.agent_grants?.length || 0)
    }
    invalidate()
    clearSelection()
    if (done) say(`${done === 1 ? 'Moved' : `${done} items moved`}.${gone.links ? ` ${gone.links} public ${gone.links === 1 ? 'link' : 'links'} stopped working.` : ''}${gone.grants ? ` ${gone.grants} ${gone.grants === 1 ? 'person or agent' : 'people and agents'} lost access.` : ''}`)
  }
  // Leaving its drive or share drops an item's public links and people's access: say so first.
  const plainMove = (list, target, root) => {
    const crossing = list.some((n) => (n.share_id || null) !== (root?.shareId || null) || (n.drive === 'C') !== (root?.drive === 'C'))
    if (crossing) setDialog({ type: 'moveWarn', list, target })
    else return bulk('move', list, target)
  }
  const trash = (list) => bulk('trash', list).catch(fail)
  const restore = (list) => bulk('restore', list).catch(fail)
  const purge = (list) => setDialog({ type: 'purge', list })
  const move = (list) => setDialog({ type: 'move', list })
  const copy = (n) => (n.sealed
    ? (n.kind === KIND.FILE
      ? sealedWrite((s, L) => L.copySealedFile({ orgId, source: s, target: s, node: n, targetId: n.parent_id })).then(() => { invalidate(); say('Copied') }).catch(fail)
      : scope ? setDialog({ type: 'cross', op: 'copy', direction: 'sealed_copy', list: [n], target: n.parent_id, scope, from: scope }) : say('Unlock your key first.'))
    : diskApi.copy(orgId, n.id, n.parent_id, true)
      .then(({ node }) => { invalidate(); say(`Copied as "${node.name}"`) }).catch(fail))
  // Moves and copies that touch a sealed scope (6.8): within one scope nothing changes cryptographically;
  // into another scope the keys are re-wrapped here; across the seal boundary a client job re-uploads.
  const transfer = async (op, list, target, root) => {
    const { node: t } = await diskApi.node(orgId, target)
    const toId = scopeIdOf(t)
    const anySealed = list.some((n) => n.sealed)
    if (anySealed && !list.every((n) => n.sealed)) return say('Move sealed and unsealed items separately.')
    if (!anySealed && !toId) return op === 'move' ? plainMove(list, target, root) : copyTo(list, target)
    const from = anySealed ? scopeOf(list[0]) : null
    if (anySealed && !from) return say('Unlock your key first.')
    const to = toId ? (toId === sealed.scopeId ? scope : await useSealedStore.getState().open(orgId, toId)) : null
    if (toId && !to) return say("You're not a key holder of the folder you picked.")
    if (anySealed && toId) {
      // A sealed copy is file by file and page by page, folders recreated: a client job with progress and resume.
      if (op === 'copy') return setDialog({ type: 'cross', op, list, target, direction: 'sealed_copy', scope: to, from })
      const L = await lib()
      // Sealed names are unique only because the client checks (build guide 10): ask before a clash, like a 409.
      const clashes = await L.moveClashes(orgId, to, target, list)
      if (clashes.length && !(await askKeepBoth(`${clashes.length === 1 ? `An item named "${clashes[0].node.name}" already exists` : `${clashes.length} items with the same name already exist`} there.`))) return
      const taken = await L.namesIn(orgId, to, target)
      const free = new Map(clashes.map(({ node }) => {
        const nm = L.freeName(node.name, taken, node.kind === KIND.FOLDER)
        taken.set(nm.toLowerCase(), node)
        return [node.id, nm]
      }))
      if (toId === from.id) {
        for (const [id, nm] of free) await sealedWrite((s) => L.sealedEndpoints.rename(orgId, id, L.sealName(s, id, nm, list.find((x) => x.id === id).mime ?? null)))
        await bulk('move', list, target)
      } else for (const n of list) await L.moveAcrossScopes({ orgId, from, to, node: n, targetId: target, name: free.get(n.id) }).catch(fail)
      invalidate()
      return clearSelection()
    }
    setDialog({ type: 'cross', op, list, target, direction: toId ? 'to_sealed' : 'to_plain', scope: toId ? to : from })
  }
  // A clash with a sealed name: the conflict dialog without Replace. Resolves true for keep both.
  const askKeepBoth = (message) => new Promise((resolve) => setDialog({
    type: 'conflict', message,
    onKeep: () => { setDialog(null); resolve(true) },
    onCancel: () => { setDialog(null); resolve(false) },
  }))
  // Copy to another folder, one item at a time so each name clash can ask.
  const copyTo = async (list, target) => {
    let done = 0
    for (const n of list) {
      const r = await withConflict((c) => diskApi.copy(orgId, n.id, target, c), { replace: n.kind === KIND.FILE }).catch((e) => { fail(e); return null })
      if (r) done++
    }
    invalidate()
    if (done) say(done === 1 ? 'Copied' : `${done} items copied`)
  }
  const shareWith = (n) => {
    if (!n.sealed) return setDialog({ type: 'people', node: n })
    // A sealed scope is shared whole: its root's key holders, or the offer to move a part into a new sealed share.
    if (!inScope || n.id === sealed.scopeId) return setDialog({ type: 'sealedMembers', node: n })
    setDialog({ type: 'sealedWhole', node: n })
  }
  const shareMany = (list) => (list.length === 1 ? shareWith(list[0]) : setDialog({ type: 'bulkShare', list }))
  const upload = (entries) => {
    if (!entries.length) return
    if (viewDef || q) return say('Open a folder to upload into it.')
    if (!canEdit) return say('You can view this folder but not upload to it.')
    if (inScope && !scope) return say('Unlock your key to upload into a sealed folder.')
    if (scope?.rotationDue) return say('A key holder left: renew the key before uploading here.')
    enqueue(orgId, folderId, entries, inScope ? { sealed: { scopeId: sealed.scopeId } } : undefined).catch(fail)
  }
  const download = (list) => {
    const s = list[0]?.sealed ? scopeOf(list[0]) : null
    if (list.some(locked)) return say('Unlock your key to download sealed items.')
    if (list.length === 1 && list[0].kind === KIND.FILE) return (s ? lib().then((L) => L.downloadSealed({ orgId, scope: s, node: list[0] })) : downloadFile(orgId, list[0])).catch(fail)
    const name = `${list.length === 1 ? list[0].name : title || 'Disk'}.zip`
    say('Preparing the zip...')
    return (s ? lib() : Promise.resolve(null))
      .then((L) => downloadZip(orgId, list, name, ({ done, total }) => say(`Zipping ${done} of ${total} files...`), L ? L.sealedZip(orgId, s) : null))
      .then((result) => say(zipReport(result)))
      .catch((e) => { if (e.name !== 'AbortError') fail(e) })
  }
  const copyLink = (n) => {
    const here = folder ? urlOf(folder.path) : nodeUrl({ short_id: shortId(n.parent_id), name: 'folder' })
    const url = window.location.origin + (n.kind === KIND.FILE ? previewUrl(n.path ? pathUrl(n.path.slice(0, -1)) : here, n) : childUrl(n))
    navigator.clipboard?.writeText(url).then(() => say('Link copied. Only people with access can open it.'), fail)
  }

  // The file picker, then (with "always use exact view" and the engine here) the engine window, from the
  // same click, so the uploads' exact views are made at once (spec F5b). That order works in every browser.
  const pickFiles = () => { chooseRef.current?.choose(); openEngineForUpload() }
  // Spec F6: a .md file opens in the page editor; a .docx becomes a new page beside it.
  const folderUrlOf = (n) => (folder ? urlOf(folder.path) : nodeUrl({ short_id: shortId(n.parent_id), name: 'folder' }))
  const editAsPage = (n) => navigate(editUrl(folderUrlOf(n), n))
  const importDocx = async (n) => {
    say(`Importing ${n.name}...`)
    try {
      const [{ docxToMarkdown }, { download }] = await Promise.all([import('../../lib/disk/docx'), diskApi.download(orgId, n.id)])
      const res = await fetch(download.url)
      if (!res.ok) throw new Error("The file didn't load.")
      const { markdown, dropped } = await docxToMarkdown(await res.blob())
      const { node: page } = await diskApi.createPage(orgId, n.parent_id, n.name.replace(/\.docx$/i, ''))
      await diskApi.savePage(orgId, page.id, { markdown, base_revision: 0 })
      invalidate()
      const left = dropped.images ? `, without its ${dropped.images === 1 ? 'image' : `${dropped.images} images`}` : ''
      say(`Imported as the page "${page.name}"${left}.`)
    } catch (e) {
      fail(e)
    }
  }

  // Seal on a folder's menu (spec F1, build guide 6.8): its contents move into a new sealed folder of the
  // same name beside it, item by item (stage, verify, switch), and the emptied original is deleted. The
  // contents are planned first, so a folder holding a sealed folder is refused before anything is made.
  const sealFolder = async (n) => {
    say('Checking the folder...')
    try {
      const { planJob } = await import('../../lib/disk/crossSeal')
      const plainOnly = (ns) => {
        if (ns.some((x) => x.sealed)) throw new Error('This folder has a sealed folder inside. Move it out first.')
        return ns
      }
      const kids = []
      let cursor
      do {
        const d = await diskApi.children(orgId, n.id, {}, cursor)
        kids.push(...d.nodes)
        cursor = d.next_cursor
      } while (cursor)
      const job = await planJob({ orgId, op: 'move', direction: 'to_sealed', sources: plainOnly(kids), targetId: null, scopeId: null, names: plainOnly, removeAfter: n.id })
      setToast(null)
      setDialog({ type: 'sealFolder', node: n, job })
    } catch (e) {
      fail(e)
    }
  }
  const sealCreated = async ({ node }) => {
    const { node: original, job } = dialog
    const to = await useSealedStore.getState().open(orgId, node.id)
    if (!to) {
      setDialog(null)
      return say('The sealed folder was made but could not be opened here. Unlock your key and move the files in.')
    }
    setDialog({ type: 'sealRun', name: original.name, scope: to, job: { ...job, targetId: node.id, scopeId: node.id } })
  }

  // ── context menu (spec F1: right-click, long press, menu key, Shift+F10) ──
  const I = (name) => <ActionIcon name={name} size={14} />
  // here: the menu for the folder whose page this is (the title's dropdown): no Open, and Delete
  // asks first and then leaves the page, as the foot's Delete link does.
  const itemMenu = (list, { here = false } = {}) => {
    const n = list[0]
    if (isTrash) {
      return [
        { label: list.length > 1 ? `Restore ${list.length} items` : 'Restore', icon: I('clock'), onSelect: () => restore(list) },
        { separator: true },
        { label: 'Delete forever', icon: I('trash'), danger: true, onSelect: () => purge(list) },
      ]
    }
    if (list.length > 1) {
      return [
        { heading: `${list.length} items selected` },
        { label: 'Download as zip', icon: I('download'), onSelect: () => download(list) },
        { label: 'Share...', icon: I('share'), onSelect: () => shareMany(list) },
        { label: 'Move to...', icon: I('move'), onSelect: () => move(list) },
        { label: 'Copy to...', icon: I('copy'), onSelect: () => setDialog({ type: 'copy', list }) },
        { label: 'Star', icon: I('star'), onSelect: () => star(list, true) },
        { separator: true },
        { label: `Delete ${list.length} items`, icon: I('trash'), danger: true, shortcut: 'Del', onSelect: () => trash(list) },
      ]
    }
    const shut = locked(n) // sealed and not opened: its key is not held here (yet)
    const editable = canEdit && !shut
    const isFolder = n.kind === KIND.FOLDER
    return [
      !shut && !here && { label: n.kind === KIND.FILE ? 'Preview' : 'Open', icon: I('eye'), shortcut: 'Enter', onSelect: () => open(n) },
      !shut && !isFolder && n.current_version_id && { label: 'Open full screen', icon: I('expand'), onSelect: () => openFull(n) },
      editable && editableAsPage(n) && n.current_version_id && { label: 'Edit as page', icon: I('page'), onSelect: () => editAsPage(n) },
      editable && importableAsPage(n) && n.current_version_id && { label: 'Import as page', icon: I('page'), onSelect: () => importDocx(n) },
      { separator: true },
      !shut && n.current_version_id && { label: 'Download', icon: I('download'), onSelect: () => download(list) },
      !shut && isFolder && { label: 'Download as zip', icon: I('download'), onSelect: () => download(list) },
      !shut && { label: n.sealed ? 'Key holders...' : 'Share...', icon: I('share'), onSelect: () => shareWith(n) },
      !shut && { label: 'Copy link', icon: I('link'), onSelect: () => copyLink(n) },
      // Sealed: a link only to a single file, with its key in the fragment (6.9).
      !shut && n.kind !== KIND.PAGE && (!n.sealed || n.kind === KIND.FILE) && drives?.settings?.links_enabled !== false && { label: 'Public link...', icon: I('link'), onSelect: () => setDialog({ type: n.sealed ? 'sealedLink' : 'link', node: n }) },
      { separator: true },
      editable && { label: 'Rename', icon: I('pencil'), shortcut: 'F2', onSelect: () => setRenamingId(n.id) },
      editable && { label: 'Move to...', icon: I('move'), onSelect: () => move(list) },
      editable && { label: 'Make a copy', icon: I('copy'), onSelect: () => copy(n) },
      !shut && { label: 'Copy to...', icon: I('copy'), onSelect: () => setDialog({ type: 'copy', list }) },
      { label: n.starred ? 'Remove star' : 'Star', icon: I('star'), onSelect: () => star(list, !n.starred) },
      canSealHere && n.parent_id === folder?.id && drives?.settings?.sealing_enabled && isFolder && !n.sealed && { label: 'Seal...', icon: I('lock'), onSelect: () => sealFolder(n) },
      !shut && n.current_version_id && { label: 'Versions', icon: I('clock'), onSelect: () => open(n) },
      { separator: true },
      here ? (share && sameNode(share.root_node_id, n.id) ? ctx.isAdmin && { label: 'Delete share', icon: I('trash'), danger: true, onSelect: () => setDialog({ type: 'deleteShare' }) }
        : canDelete && { label: 'Delete', icon: I('trash'), danger: true, onSelect: () => setDialog({ type: 'deleteFolder' }) })
        : canDelete && { label: 'Delete', icon: I('trash'), danger: true, shortcut: 'Del', onSelect: () => trash(list) },
    ].filter(Boolean).reduce(tidySeparators, []).filter((it, i, all) => !(it.separator && i === all.length - 1))
  }
  // A sealed C:\ folder is made by its custodian on their own C:\, never inside a scope (6.2).
  const canSealHere = !viewDef && canEdit && !inScope && folder?.drive === 'C' && folder?.access?.sources?.some((x) => x.kind === SOURCE.CUSTODIAN)
  const spaceMenu = () => [
    !viewDef && canEdit && { label: 'New folder', icon: I('folder'), onSelect: newFolder },
    !viewDef && canEdit && { label: 'New page', icon: I('page'), onSelect: newPage },
    !viewDef && canEdit && { label: 'Upload files', icon: I('upload'), onSelect: pickFiles },
    !viewDef && canEdit && { label: 'Upload folder', icon: I('upload'), onSelect: () => chooseRef.current?.choose('folder') },
    canSealHere && { label: 'New sealed folder', icon: I('folder'), onSelect: () => setDialog({ type: 'createSealed' }) },
    { label: 'Select all', icon: I('check'), onSelect: () => setSelected(new Set(nodes.map((n) => n.id))) },
  ].filter(Boolean)

  const trigger = useContextMenuTrigger((position, target) => {
    const row = target.closest?.('[data-index]')
    if (!row) return setMenu({ position, items: spaceMenu() })
    const i = Number(row.dataset.index)
    const n = nodes[i]
    const list = selected.has(n.id) ? selNodes : [n]
    if (!selected.has(n.id)) { setSelected(new Set([n.id])); setAnchor(i) }
    setMenu({ position, items: itemMenu(list) })
  })

  // ── keyboard (spec F1: arrows, Enter, Backspace, Esc, plus F2 and Delete) ──
  const onListKey = (e) => {
    trigger.onKeyDown(e)
    if (e.defaultPrevented || isTyping(e.target)) return
    const row = e.target.closest('[data-index]')
    const i = row ? Number(row.dataset.index) : -1
    const grid = value.view === 'grid'
    const step = { ArrowDown: 1, ArrowUp: -1, ...(grid ? { ArrowRight: 1, ArrowLeft: -1 } : {}) }[e.key]
    if (step && nodes.length) {
      e.preventDefault()
      const j = Math.max(0, Math.min(nodes.length - 1, i < 0 ? 0 : i + step))
      pick(j, { shiftKey: e.shiftKey })
      focusRow(j)
    } else if (e.key === 'Enter' && row && row.matches('[role="option"]')) {
      e.preventDefault()
      open(nodes[i])
    } else if (e.key === 'F2' && canEdit) {
      const n = row ? nodes[i] : selNodes[0]
      if (n && !locked(n)) { e.preventDefault(); setRenamingId(n.id) }
    } else if (e.key === 'Delete' && selNodes.length && canDelete && !isTrash) {
      e.preventDefault()
      trash(selNodes)
    } else if (e.key.toLowerCase() === 'a' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      setSelected(new Set(nodes.map((n) => n.id)))
    }
  }

  // Page-level keys: Backspace goes up a level, Esc clears the selection.
  const busy = !!(dialog || menu || openId || renamingId)
  useEffect(() => {
    const onKey = (e) => {
      if (busy || e.defaultPrevented) return
      if (isTyping(document.activeElement)) return
      if (e.key === 'Backspace' && !viewDef) { e.preventDefault(); goUp() }
      if (e.key === 'Escape' && selected.size) clearSelection()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  })

  // The id is the authority: once the folder is known, a stale path (a rename or
  // move since the link was made) is swapped for the current one, without a new history entry.
  const location = useLocation()
  useEffect(() => {
    if (!folder || !sameNode(folder, folderId) || viewDef) return
    const want = folder.drive === 'C' && folder.path?.length === 1 && folder.path[0].name == null && !folder.path[0].sealed
      ? drivePath('C')
      : pathUrl(folder.path || [])
    const same = (a, b) => { try { return decodeURIComponent(a) === decodeURIComponent(b) } catch { return a === b } }
    if (!same(location.pathname, want)) navigate(`${want}${location.search}`, { replace: true, state: location.state })
  }, [folder, folderId, viewDef, slug, drives, location.pathname, location.search, location.state, navigate])

  // ── header ──
  if (folderError?.status === 404 || listing.error?.status === 404) return <NotFound />
  // A sealed share's top folder has no sealed name: the share's own name (never encrypted) stands for it.
  const crumbNames = share?.sealed ? { [share.root_node_id]: share.name, ...sealed.names } : sealed.names
  const segments = folder ? pathSegments(folder.drive, folder.path, crumbNames) : hint?.path ? pathSegments(hint.drive, hint.path, crumbNames) : null
  const isCRoot = folder && folder.drive === 'C' && segments?.length === 1 && segments[0].id === folder.id
  const isShareRoot = share && sameNode(share.root_node_id, folderId)
  const title = viewDef?.label || (isCRoot ? 'My disk' : segments ? segments.at(-1).label : '')
  const sub = viewDef ? viewDef.empty
    : isCRoot ? 'Private to you. Share a folder to let someone in.'
      : isShareRoot ? `Share, ${share.member_count} ${share.member_count === 1 ? 'member' : 'members'}${share.archived_at ? ', archived (read-only)' : ''}`
        : folder ? `In ${formatPath(pathSegments(folder.drive, folder.path.slice(0, -1), crumbNames))}${inScope ? ', sealed' : ''}` : ''
  const onCrumb = (seg) => {
    navigate(crumbUrl(folder?.drive || hint?.drive || 'C', folder?.path || hint?.path || [], segments.indexOf(seg)))
  }

  const active = hasActiveFilters(value)
  const total = source?.kind === 'folder' ? listing.data?.total : listing.data?.nodes.length
  const shownCount = source?.kind === 'folder' ? listing.data?.count : nodes.length
  const countText = listing.data == null ? '' : active
    ? `${shownCount} of ${total} ${q ? 'items searched' : 'items'}`
    : `${total} ${total === 1 ? 'item' : 'items'}`
  // The Access column is there for every folder listing from the first frame, so it never pops in.
  const access = !viewDef && !q ? { orgId, share, where: segments ? formatPath(segments) : '' } : null
  const files = nodes.filter((n) => n.kind !== KIND.FOLDER && !locked(n))
  const openIdx = files.findIndex((n) => sameNode(n, openId))

  let body
  if (listing.error && !listing.data) {
    body = (
      <div className={styles.emptyCard} role="alert">
        <p><b>{listing.error.status === 403 ? "You don't have access to this." : "This didn't load."}</b><br />{listing.error.message}</p>
        <MgmtButton size="sm" variant="glass" onClick={invalidate}>Try again</MgmtButton>
      </div>
    )
  } else if (!listing.data) {
    body = showSkeleton ? <NodeListSkeleton view={value.view} access={!!access} /> : <div className={styles.placeholder} />
  } else if (!nodes.length && !listing.dim) {
    body = active ? (
      <div className={styles.emptyCard}>
        <ActionIcon name="search" size={28} />
        <p><b>Nothing matches{q ? ` "${q}"` : ''}.</b></p>
        <div className={styles.emptyActions}>
          {q && !value.everywhere && !viewDef && <MgmtButton size="sm" variant="glass" onClick={() => changeValue({ ...value, everywhere: true })}>Search everywhere</MgmtButton>}
          <MgmtButton size="sm" variant="glass" onClick={() => changeValue({ ...value, ...EMPTY_FILTERS })}>Clear filters</MgmtButton>
        </div>
      </div>
    ) : (
      <div className={styles.emptyCard}>
        {isShareRoot ? <FileTypeIcon kind="share" emblem={share.icon} color={share.color} size={84} /> : <FileTypeIcon kind="folder" size={84} />}
        <p><b>{viewDef ? `Nothing in ${viewDef.label} yet.` : 'Nothing here yet.'}</b><br />{viewDef ? viewDef.empty : 'Drop files here.'}</p>
        {!viewDef && canEdit && (
          <div className={styles.emptyActions}>
            {/* First run: bring files in from elsewhere (spec F10). */}
            {isCRoot && !inScope && <MgmtButton size="sm" variant="glass" as={Link} to={{ pathname: diskPath(IMPORT_SEGMENT), search: '?new=1' }}><ActionIcon name="download" />Import</MgmtButton>}
            <MgmtButton size="sm" variant="primary" onClick={pickFiles}><ActionIcon name="upload" />Upload</MgmtButton>
            <MgmtButton size="sm" variant="glass" onClick={newFolder}><ActionIcon name="folder" />New folder</MgmtButton>
            <MgmtButton size="sm" variant="glass" onClick={newPage}><ActionIcon name="page" />New page</MgmtButton>
          </div>
        )}
      </div>
    )
  } else {
    body = (
      <NodeList
        nodes={nodes}
        view={value.view}
        selected={selected}
        focusIndex={focusIndex}
        q={q}
        showPath={!!q}
        access={access}
        sort={{ key: value.sort, dir: value.dir }}
        onSort={(key) => changeValue({ ...value, sort: key, dir: value.sort === key ? -value.dir : defaultDir(key) })}
        renamingId={renamingId}
        onRename={rename}
        onRenameCancel={cancelRename}
        onPick={(i, e) => { pick(i, e); focusRow(i) }} // keys (F2, Delete, arrows) then act on what was clicked
        onOpen={open}
        onToggle={(i, on) => {
          const next = new Set(selected)
          if (on) next.add(nodes[i].id)
          else next.delete(nodes[i].id)
          setSelected(next)
          setAnchor(i)
        }}
        onToggleAll={(on) => setSelected(on ? new Set(nodes.map((n) => n.id)) : new Set())}
        dim={listing.dim}
        thumbOrg={orgId}
        tile={value.tile}
      />
    )
  }

  const bulkActions = isTrash
    ? [
        { label: 'Restore', icon: 'clock', primary: true, onSelect: () => restore(selNodes) },
        { label: 'Delete forever', icon: 'trash', danger: true, onSelect: () => purge(selNodes) },
      ]
    : [
        { label: 'Download', icon: 'download', primary: true, onSelect: () => download(selNodes) },
        { label: 'Share', icon: 'share', onSelect: () => shareMany(selNodes) },
        canEdit && { label: 'Move', icon: 'move', onSelect: () => move(selNodes) },
        { label: 'Star', icon: 'star', onSelect: () => star(selNodes, true) },
        canDelete && { label: 'Delete', icon: 'trash', danger: true, onSelect: () => trash(selNodes) },
      ].filter(Boolean)

  return (
    <Dropzone ref={chooseRef} onFiles={upload} label={`Drop to upload to ${title || 'this folder'}`}>
    {/* A click on empty space anywhere on the page clears the selection (portals, such as dialogs, are not "the page"). */}
    <div className={styles.page} role="presentation" onClick={(e) => { if (selected.size && e.currentTarget.contains(e.target) && !e.target.closest('[data-index], button, input, select, a, label, [data-access], [role="menu"]')) clearSelection() }}>
      {/* The row is kept while the path loads, so the page below it does not jump. */}
      {!viewDef && <div className={styles.crumbRow}>{segments && <Breadcrumbs segments={segments} onNavigate={onCrumb} />}</div>}
      <div className={styles.head}>
        <div className={styles.headText}>
          <h1 className={styles.title} title={title.length > TITLE_MAX ? title : undefined}>
            {folder && renamingId === folder.id ? <RenameField node={{ ...folder, name: title }} onRename={rename} onCancel={cancelRename} /> : middleCut(title, TITLE_MAX)}
            {/* The row menu, for the folder you are in. */}
            {folder && !isCRoot && !viewDef && (
              <DropdownMenu
                variant="light"
                align="left"
                trigger={<button type="button" className={styles.titleMenu} aria-haspopup="menu" aria-label={`Actions for ${title}`}><ActionIcon name="chevronDown" size={16} /></button>}
                items={itemMenu([{ ...folder, name: title }], { here: true })}
              />
            )}
            {/* Any folder you can name can be starred; not C:\ itself or the views. */}
            {folder && !isCRoot && !viewDef && <StarToggle on={folder.starred} label={title} onToggle={(on) => star([folder], on)} />}
          </h1>
          {sub && (
            <p className={styles.sub}>
              {sub}
              {/* A share's name, icon and colour: its managers change them, admins can delete it from there. */}
              {isShareRoot && roleAtLeast(role, ROLE.MANAGE) && <> · <button type="button" className={styles.subLink} onClick={() => setDialog({ type: 'shareSettings' })}>Edit share</button></>}
            </p>
          )}
        </div>
        {selNodes.length ? (
          <BulkBar count={selNodes.length} actions={bulkActions} onClear={clearSelection} />
        ) : !viewDef && (
          <div className={styles.acts}>
            {/* Shown (disabled) until the role is known, so they never pop in for editors. */}
            {inScope && scope && <MgmtButton variant="glass" onClick={() => setDialog({ type: 'sealedMembers', node: { id: sealed.scopeId } })}><ActionIcon name="share" />Key holders</MgmtButton>}
            {(canEdit || !folder) && (
              <div className={styles.split}>
                <MgmtButton variant="glass" className={styles.splitMain} disabled={!canEdit} onClick={newFolder}><ActionIcon name="folder" />New</MgmtButton>
                <DropdownMenu
                  variant="light"
                  trigger={<MgmtButton variant="glass" className={styles.splitMore} disabled={!canEdit} aria-haspopup="menu" aria-label="More to make"><ActionIcon name="chevronDown" /></MgmtButton>}
                  items={[
                    { label: 'Folder', icon: 'folder', onSelect: newFolder },
                    { label: 'Page', icon: 'doc.text.fill', onSelect: newPage },
                    ...(canSealHere ? [{ separator: true }, { label: 'Sealed folder', icon: 'lock.fill', onSelect: () => setDialog({ type: 'createSealed' }) }] : []),
                  ]}
                />
              </div>
            )}
            <MgmtButton
              variant="primary"
             
              disabled={!canEdit}
              title={canEdit ? 'You can also drop files on the list' : 'You can view this folder but not upload to it'}
              onClick={pickFiles}
            >
              <ActionIcon name="upload" />Upload
            </MgmtButton>
          </div>
        )}
      </div>

      {sealed.entry && (
        <SealedBanner entry={sealed.entry} shareName={share?.name} isManager={roleAtLeast(role, ROLE.MANAGE)}
          onRotate={() => setDialog({ type: 'sealedMembers', node: { id: sealed.scopeId } })} />
      )}
      <div className={styles.tools}>
        <FilterBar value={value} onChange={changeValue} people={people} placeholder={`Search in ${title || 'Disk'}`} />
      </div>

      <div
        ref={listRef}
        className={styles.view}
        role="presentation"
        aria-busy={listing.loading}
        {...trigger}
        onKeyDown={onListKey}
      >
        {body}
        {listing.data?.nextCursor && !q && (
          <div className={styles.more}><MgmtButton size="sm" variant="glass" onClick={() => listing.loadMore().catch(fail)}>Show more</MgmtButton></div>
        )}
        {/* Inside the view, so it sits under the list rather than under the view's minimum height. */}
        <p className={styles.count} role="status" aria-live="polite">{countText}</p>
      </div>
      {/* Deleting this folder, quietly at the foot of its page: a share by its owners and admins,
          any other folder by whoever may delete it (not C:\ itself or the views). */}
      {isShareRoot ? ctx.isAdmin && (
        <div className={styles.dangerFoot}>
          <button type="button" className={styles.deleteLink} onClick={() => setDialog({ type: 'deleteShare' })}>Delete share</button>
        </div>
      ) : folder && !isCRoot && !viewDef && canDelete && (
        <div className={styles.dangerFoot}>
          <button type="button" className={styles.deleteLink} onClick={() => setDialog({ type: 'deleteFolder' })}>Delete folder</button>
        </div>
      )}
      {toast && <div className={styles.toast} role="status" aria-live="polite">{toast}</div>}

      <ContextMenu open={!!menu} position={menu?.position} items={menu?.items || []} onClose={() => setMenu(null)} variant="light" />

      {openId && (
        <SlideOver
          open
          onClose={() => setOpen(null)}
          title={openNode ? <>{nodeLabel(openNode)} <StarToggle on={openNode.starred} label={nodeLabel(openNode)} size={18} onToggle={(on) => star([openNode], on)} /></> : ''}
          icon={openNode && <FileTypeIcon name={openNode.name} mime={openNode.mime} />}
          onPrev={openIdx > 0 ? () => setOpen(files[openIdx - 1]) : null}
          onNext={openIdx >= 0 && openIdx < files.length - 1 ? () => setOpen(files[openIdx + 1]) : null}
          actions={openNode && <>
            {!locked(openNode) && openNode.current_version_id && <MgmtButton variant="primary" size="sm" onClick={() => download([openNode])}><ActionIcon name="download" />Download</MgmtButton>}
            {!locked(openNode) && <MgmtButton variant="glass" size="sm" onClick={() => shareWith(openNode)}><ActionIcon name="share" />{openNode.sealed ? 'Key holders' : 'Share'}</MgmtButton>}
          </>}
        >
          {openNode ? <Details
            names={crumbNames}
            slug={slug}
            key={`${openNode.id}:${openNode.current_version_id}`}
            orgId={orgId}
            node={openNode}
            scope={openScope}
            canEdit={canEdit}
            full={wantFull}
            onFullDone={() => setWantFull(false)}
            share={drives?.shares.find((s) => s.id === openNode.share_id)}
            onDownload={() => download([openNode])}
            onChanged={invalidate}
            fail={fail}
          /> : <div className={styles.sec}><Skeleton variant="text" count={4} /></div>}
        </SlideOver>
      )}

      {dialog?.type === 'shareSettings' && share && (
        <ShareSettingsDialog
          orgId={orgId}
          share={share}
          domains={ctx.domains}
          onClose={() => setDialog(null)}
          onSaved={(s) => { setDialog(null); ctx.reloadDrives?.(); if (s.slug !== share.slug) navigate(pathUrl([shareRoot(s)]), { replace: true }) }}
        />
      )}
      {dialog?.type === 'copy' && (
        <MoveDialog
          orgId={orgId}
          drives={drives}
          verb="Copy"
          movingIds={dialog.list.filter((n) => n.kind === KIND.FOLDER).map((n) => n.id)}
          onClose={() => setDialog(null)}
          onPick={(target) => { const list = dialog.list; setDialog(null); transfer('copy', list, target).catch(fail) }}
        />
      )}
      {dialog?.type === 'link' && <LinkDialog orgId={orgId} node={dialog.node} onClose={() => setDialog(null)} />}
      {dialog?.type === 'sealedLink' && scopeOf(dialog.node) && <SealedLinkDialog orgId={orgId} scope={scopeOf(dialog.node)} node={dialog.node} onClose={() => setDialog(null)} />}
      {dialog?.type === 'sealedMembers' && (scopes[`${orgId}/${dialog.node.id}`]?.scope || (dialog.node.id === sealed.scopeId && scope)) && (
        <SealedMembersDialog
          orgId={orgId}
          scope={scopes[`${orgId}/${dialog.node.id}`]?.scope || scope}
          share={share && sameNode(share.root_node_id, dialog.node.id) ? share : null}
          people={people}
          isManager={dialog.node.id === sealed.scopeId ? roleAtLeast(role, ROLE.MANAGE) : true}
          onChanged={() => useSealedStore.getState().reopen(orgId, dialog.node.id).then(invalidate)}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog?.type === 'sealedWhole' && scope && (
        <MoveToSealedShareDialog orgId={orgId} node={dialog.node} from={scope} onClose={() => setDialog(null)}
          onDone={(sh) => { setDialog(null); useDiskStore.getState().invalidate(orgId); ctx.reloadDrives?.(); say(`Moved into the new sealed share ${sh.name}. Add people there.`) }} />
      )}
      {dialog?.type === 'unlock' && <UnlockDialog onClose={() => setDialog(null)} onUnlocked={() => { pendingOpen.current = { id: dialog.node.id, folderId }; setDialog(null) }} />}
      {dialog?.type === 'createSealed' && (
        <CreateSealedDialog orgId={orgId} kind="folder" cRootId={folderId} onClose={() => setDialog(null)}
          onCreated={({ node }) => { setDialog(null); invalidate(); if (node) navigate(childUrl(node), { state: { kind: KIND.FOLDER } }) }} />
      )}
      {dialog?.type === 'sealFolder' && (
        <CreateSealedDialog orgId={orgId} kind="folder" cRootId={dialog.node.parent_id} convert={dialog.node} onClose={() => setDialog(null)}
          onCreated={(res) => sealCreated(res).catch(fail)} />
      )}
      {dialog?.type === 'sealRun' && (
        <CrossSealDialog op="move" direction="to_sealed" count={dialog.job.items.length} job={dialog.job} scope={dialog.scope} autoStart
          title={`Sealing "${dialog.name}"`}
          onDone={(job) => { invalidate(); if (job.items.every((i) => i.state === 'done')) say(`"${dialog.name}" is sealed.`) }}
          onClose={() => { setDialog(null); invalidate() }} />
      )}
      {dialog?.type === 'cross' && (
        <CrossSealDialog
          op={dialog.op}
          direction={dialog.direction}
          count={dialog.list.length}
          scope={dialog.scope}
          from={dialog.from}
          plan={async () => {
            const L = await lib()
            const { planJob } = await import('../../lib/disk/crossSeal')
            const from = dialog.direction === 'to_plain' ? dialog.scope : dialog.from || null
            return planJob({ orgId, op: dialog.op, direction: dialog.direction, sources: dialog.list, targetId: dialog.target, scopeId: dialog.scope.id, fromScopeId: dialog.from?.id, names: from ? (ns) => L.openNames(from, ns) : undefined })
          }}
          onDone={() => { invalidate(); clearSelection() }}
          onClose={() => { setDialog(null); invalidate() }}
        />
      )}
      {dialog?.type === 'bulkShare' && (
        <BulkShareDialog orgId={orgId} nodes={dialog.list} people={people} onClose={() => setDialog(null)} />
      )}
      {dialog?.type === 'move' && (
        <MoveDialog
          orgId={orgId}
          drives={drives}
          movingIds={dialog.list.map((n) => n.id)}
          onClose={() => setDialog(null)}
          onPick={(target, _file, root) => { const list = dialog.list; setDialog(null); transfer('move', list, target, root).catch(fail) }}
        />
      )}
      {dialog?.type === 'people' && (
        <PeopleDialog orgId={orgId} node={dialog.node} share={drives?.shares.find((s) => s.id === dialog.node.share_id)} people={people} onClose={() => setDialog(null)} />
      )}
      {dialog?.type === 'conflict' && (
        <ConflictDialog message={dialog.message} onKeep={dialog.onKeep} onReplace={dialog.onReplace} onCancel={dialog.onCancel} />
      )}
      <MgmtConfirm
        open={dialog?.type === 'deleteShare' && !!share}
        danger
        title={`Delete ${share?.name}?`}
        message="Owners and admins can restore it for 30 days. Its public links stop working now."
        confirmText={share?.name}
        confirmLabel="Delete share"
        onConfirm={() => {
          setDialog(null)
          diskApi.deleteShare(orgId, share.id, share.name).then(() => { ctx.reloadDrives?.(); navigate(drivePath('D')) }).catch(fail)
        }}
        onClose={() => setDialog(null)}
      />
      <MgmtConfirm
        open={dialog?.type === 'deleteFolder' && !!folder}
        danger
        title={`Delete ${title}?`}
        message="It stays in Trash for 30 days. Its public links stop working now."
        confirmLabel="Delete folder"
        onConfirm={() => {
          setDialog(null)
          const up = folder.path?.length > 1 ? pathUrl(folder.path.slice(0, -1)) : drivePath(folder.drive)
          bulk('trash', [folder]).then((failed) => { if (!failed?.length) navigate(up) }).catch(fail)
        }}
        onClose={() => setDialog(null)}
      />
      <MgmtConfirm
        open={dialog?.type === 'moveWarn'}
        title="Move to another drive or share?"
        message="Public links stop working, and people and agents added by name lose access. Members of the new drive or share can open it."
        confirmLabel="Move"
        onConfirm={() => { const { list, target } = dialog; setDialog(null); moveAcross(list, target) }}
        onClose={() => setDialog(null)}
      />
      <MgmtConfirm
        open={dialog?.type === 'purge'}
        danger
        title={dialog?.list?.length > 1 ? `Delete ${dialog.list.length} items forever?` : `Delete "${dialog?.list ? nodeLabel(dialog.list[0]) : ''}" forever?`}
        confirmLabel="Delete forever"
        onConfirm={() => {
          const list = dialog.list
          setDialog(null)
          Promise.all(list.map((n) => diskApi.purge(orgId, n.id)))
            .then(() => { invalidate(); clearSelection(); say(list.length > 1 ? `${list.length} items deleted forever` : 'Deleted forever') })
            .catch(fail)
        }}
        onClose={() => setDialog(null)}
      />
    </div>
    </Dropzone>
  )
}

/* The slide-over body: the preview (package 5), what the file is, who can
   open it, and its versions with download and restore. */
function Details({ orgId, slug, node, scope, share, names, canEdit, full, onFullDone, onDownload, onChanged, fail }) {
  const [versions, setVersions] = useState(null)
  const [moreCursor, setMoreCursor] = useState(null)
  const [rev, setRev] = useState(0)
  useEffect(() => {
    if (node.kind !== KIND.FILE) return undefined
    let live = true
    diskApi.versions(orgId, node.id)
      .then((d) => { if (live) { setVersions(d.versions); setMoreCursor(d.next_cursor || null) } })
      .catch(() => { if (live) setVersions([]) })
    return () => { live = false }
  }, [orgId, node.id, node.kind, rev])
  const [events, setEvents] = useState(null)
  useEffect(() => {
    let live = true
    diskApi.events(orgId, node.id).then((d) => { if (live) setEvents(d.events.filter((e) => EVENT_TEXT[e.action]).slice(0, 8)) }).catch(() => {})
    return () => { live = false }
  }, [orgId, node.id, rev])
  const moreVersions = () => diskApi.versions(orgId, node.id, moreCursor)
    .then((d) => { setVersions((v) => [...v, ...d.versions]); setMoreCursor(d.next_cursor || null) })
    .catch(fail)
  const [startFull] = useState(full) // asked for by "Open full screen" as the panel opened
  useEffect(() => { if (full) onFullDone() }, [full, onFullDone])

  const where = formatPath(pathSegments(node.drive, (node.path || []).slice(0, -1), names))
  const sources = node.access?.sources || []
  const editable = canEdit || roleAtLeast(node.access?.role, ROLE.EDIT)
  const current = versions?.find((v) => v.current)
  const sourceText = (s) => ({
    [SOURCE.CUSTODIAN]: 'Your C:\\',
    [SOURCE.ADMIN]: "You're an owner or admin",
    [SOURCE.SHARE_MEMBER]: `Member of ${share?.name || 'the share'}`,
    [SOURCE.SHARE_DEFAULT]: `${share?.name || 'The share'} is open to everyone`,
    [SOURCE.GRANT]: 'Shared with you by name',
  }[s.kind])
  const sealedLib = () => import('../../lib/disk/sealed')
  const saveBlob = (blob, name) => saveUrl(URL.createObjectURL(blob), name)
  // Sealed: a restore re-wraps the old version's key under the current epoch (6.8); a version downloads opened here.
  const restore = (v) => (node.sealed
    ? sealedLib().then((L) => L.restoreSealedVersion({ orgId, scope, node, version: v }))
    : diskApi.restoreVersion(orgId, v.id))
    .then(() => { setRev((r) => r + 1); onChanged() })
    .catch(fail)
  const saveVersion = (v) => (node.sealed
    ? sealedLib().then(async (L) => saveBlob(await L.sealedBlob({ orgId, scope, nodeId: node.id, version: v, mime: node.mime }), node.name))
    : downloadVersion(orgId, v, node.name)).catch(fail)

  return (
    <>
      {node.kind === KIND.FILE && node.sealed && !node.opened
        ? <div className={styles.preview}><FileTypeIcon type="key" size={96} /><p className={styles.previewNote}>Sealed. Unlock your key to open it.</p></div>
        : node.kind === KIND.FILE && node.sealed && scope && current
          ? <SealedPreview orgId={orgId} scope={scope} node={node} version={current} startFull={startFull} onDownload={onDownload} />
          : node.kind === KIND.FILE && !node.sealed && versions
        ? <PreviewPane orgId={orgId} node={node} version={current} startFull={startFull} onDownload={onDownload} />
        : <div className={styles.preview}>
            {node.kind === KIND.PAGE
              ? <><FileTypeIcon kind="page" size={96} /><p className={styles.previewNote}>Open the page to read or edit it.</p></>
              : <Skeleton variant="text" count={4} />}
          </div>}
      <dl className={styles.meta}>
        <dt>Location</dt><dd className={styles.mono}>{where}</dd>
        <dt>Type</dt><dd>{node.kind === KIND.PAGE ? 'Page' : fileType(node).label}</dd>
        <dt>Size</dt><dd>{formatBytes(node.size_bytes)}</dd>
        <dt>Modified</dt><dd>{node.content_modified_at ? new Date(node.content_modified_at).toLocaleString() : ''}{node.modified_by ? ` by ${node.modified_by.name}` : ''}</dd>
        {node.origin && (
          <>
            <dt>From mail</dt>
            <dd>
              {node.origin.from}: <Link to={`/${slug}/search?q=${encodeURIComponent(node.origin.subject || node.origin.from || '')}`}>{node.origin.subject || '(no subject)'}</Link>
            </dd>
          </>
        )}
        {node.sealed && <><dt>Encryption</dt><dd><span className={styles.lock}>sealed</span> only key holders can open it</dd></>}
      </dl>
      <div className={styles.sec}>
        <h4 className={styles.secTitle}>Your access</h4>
        {sources.map((s, i) => (
          <div key={i} className={styles.person}><span>{sourceText(s)}</span><span>{ROLE_LABEL[s.role]}</span></div>
        ))}
      </div>
      {versions?.length > 0 && (
        <div className={styles.sec}>
          <h4 className={styles.secTitle}>Versions (kept 180 days)</h4>
          <ul className={styles.versions}>
            {versions.map((v) => (
              <li key={v.id} className={styles.version}>
                <span className={styles.versionText}>
                  <b>Version {v.number}{v.current ? ', current' : ''}</b>
                  <small>{new Date(v.created_at).toLocaleString()}{v.author ? ` by ${v.author.name}` : ''}, <span>{formatBytes(node.sealed ? plainSize(v.size_bytes, v.chunk_bytes) : v.size_bytes)}</span></small>
                </span>
                {(!node.sealed || scope) && <MgmtButton size="sm" variant="glass" onClick={() => saveVersion(v)}>Download</MgmtButton>}
                {!v.current && editable && <MgmtButton size="sm" variant="ghost" onClick={() => restore(v)}>Restore</MgmtButton>}
              </li>
            ))}
          </ul>
          {moreCursor && <MgmtButton size="sm" variant="glass" onClick={moreVersions}>Show older versions</MgmtButton>}
        </div>
      )}
      {events?.length > 0 && (
        <div className={styles.sec}>
          <h4 className={styles.secTitle}>Activity</h4>
          <ul className={styles.versions}>
            {events.map((e, i) => (
              <li key={i} className={styles.version}>
                <span className={styles.versionText}>
                  <b>{e.actor ? `${e.actor.name}${e.actor.agent ? ' (agent)' : ''}` : e.link_id ? 'Someone' : 'Disk'}</b> {EVENT_TEXT[e.action]}
                  <small>{new Date(e.created_at).toLocaleString()}</small>
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  )
}
