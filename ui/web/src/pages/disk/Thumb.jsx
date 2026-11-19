import { useEffect, useRef, useState } from 'react'
import diskApi from '../../lib/disk/api'
import useDiskStore from '../../stores/diskStore'
import FileTypeIcon from '../../components/FileTypeIcon'
import { KIND } from '../../lib/disk/model'
import styles from './NodeList.module.css'

// version id -> { url, at } | null (no thumbnail). Presigned GETs last five
// minutes, so a cached URL is reused for four.
// The listing's has_thumbnail keeps tiles without one from asking at all.
const cache = new Map()
const FRESH_MS = 4 * 60_000

async function thumbUrl(orgId, versionId) {
  const hit = cache.get(versionId)
  if (hit === null) return null
  if (hit && Date.now() - hit.at < FRESH_MS) return hit.url
  try {
    const { download } = await diskApi.versionDownload(orgId, versionId, 'thumbnail')
    cache.set(versionId, { url: download.url, at: Date.now() })
    return download.url
  } catch (e) {
    if (e.status === 404) cache.set(versionId, null)
    return null
  }
}

/* A grid tile's thumbnail, asked for when the tile scrolls into view; the type icon until then or without one. */
// load: a sealed thumbnail opened on this page (6.6), resolving to a blob: URL or null.
export default function Thumb({ orgId, versionId, load, children }) {
  const ref = useRef(null)
  const [url, setUrl] = useState(null)
  useEffect(() => {
    const el = ref.current
    if (!el || !versionId) return undefined
    let live = true
    const io = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return
      io.disconnect()
      ;(load ? load().catch(() => null) : thumbUrl(orgId, versionId)).then((u) => { if (live) setUrl(u) })
    })
    io.observe(el)
    return () => { live = false; io.disconnect() }
  }, [orgId, versionId, load])
  return (
    <span ref={ref} className={styles.thumbBox}>
      {url ? <img className={styles.thumbImg} src={url} alt="" onError={() => setUrl(null)} /> : children}
    </span>
  )
}

const PEEK = 4
// folder id -> { rev, items } so a scroll back up refetches nothing; a write bumps rev.
const peekCache = new Map()

// Up to four live children of a folder: images with a thumbnail first, then
// whatever else is in there (sorted the way the listing sorts, folders first).
// ponytail: two small listing calls per folder tile; a children_preview field on the serializer if listings get slow.
async function peekChildren(orgId, folderId, rev) {
  const hit = peekCache.get(folderId)
  if (hit && hit.rev === rev) return hit.items
  const seen = new Set()
  const items = []
  const take = (nodes) => nodes.forEach((n) => { if (items.length < PEEK && !seen.has(n.id)) { seen.add(n.id); items.push(n) } })
  try {
    take((await diskApi.children(orgId, folderId, { type: 'images', limit: PEEK })).nodes.filter((n) => n.has_thumbnail))
    if (items.length < PEEK) take((await diskApi.children(orgId, folderId, { limit: PEEK * 2 })).nodes)
  } catch { /* a folder we may list but not peek into shows its icon alone */ }
  peekCache.set(folderId, { rev, items })
  return items
}

function PeekIcon({ node }) {
  if (node.kind === KIND.FOLDER) return <FileTypeIcon kind="folder" sealed={node.sealed} size={30} />
  if (node.kind === KIND.PAGE) return <FileTypeIcon kind="page" size={30} />
  return <FileTypeIcon name={node.name} mime={node.mime} type={node.sealed ? 'key' : undefined} size={30} />
}

function PeekItem({ orgId, node }) {
  const [url, setUrl] = useState(null)
  useEffect(() => {
    let live = true
    if (node.has_thumbnail && node.current_version_id) thumbUrl(orgId, node.current_version_id).then((u) => { if (live) setUrl(u) })
    return () => { live = false }
  }, [orgId, node])
  return (
    <span className={styles.peekCell}>
      {url ? <img className={styles.peekImg} src={url} alt="" onError={() => setUrl(null)} /> : <PeekIcon node={node} />}
    </span>
  )
}

/* A folder tile: a small folder icon in the corner over a peek at what is inside, loaded when the tile scrolls into view. */
export function FolderPeek({ orgId, node, children }) {
  const ref = useRef(null)
  const rev = useDiskStore((s) => s.rev)
  const [items, setItems] = useState(null)
  useEffect(() => {
    const el = ref.current
    if (!el || node.sealed) return undefined // sealed children carry ciphertext only
    let live = true
    const io = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return
      io.disconnect()
      peekChildren(orgId, node.id, rev).then((v) => { if (live) setItems(v) })
    })
    io.observe(el)
    return () => { live = false; io.disconnect() }
  }, [orgId, node.id, node.sealed, rev])
  return (
    <span ref={ref} className={styles.peekBox}>
      <span className={styles.peekHead}>{children}</span>
      <span className={styles.peekBody}>
        {node.sealed && <span className={styles.peekStack}><span className={styles.peekCell}><FileTypeIcon kind="folder" sealed keyBadge size={30} /></span></span>}
        {items?.length > 0 && (
          <span className={items.every((n) => n.has_thumbnail) ? styles.peekGrid : styles.peekStack}>
            {items.map((n) => <PeekItem key={n.id} orgId={orgId} node={n} />)}
          </span>
        )}
      </span>
    </span>
  )
}
