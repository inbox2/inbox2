import { useEffect, useState } from 'react'
import { NavLink } from 'react-router'
import FileTypeIcon from '../../../components/FileTypeIcon'
import Skeleton from '../../../components/Skeleton'
import diskApi from '../../../lib/disk/api'
import { pathUrl } from '../../../lib/disk/model'
import useDiskStore from '../../../stores/diskStore'
import styles from './Page.module.css'

// One level of pages under a folder or a page; a page's own sub-pages open beneath it.
function Level({ orgId, slug, basePath, parentId, current, openIds, depth, nameOf }) {
  const [pages, setPages] = useState(null)
  const rev = useDiskStore((s) => s.rev)
  useEffect(() => {
    let live = true
    diskApi.children(orgId, parentId, { type: 'pages', sort: 'name', dir: 'asc' })
      .then((d) => { if (live) setPages(d.nodes.filter((n) => n.kind === 'page')) })
      .catch(() => { if (live) setPages([]) })
    return () => { live = false }
  }, [orgId, parentId, rev])
  if (!pages) return <Skeleton variant="text" count={2} />
  return (
    <ul className={styles.treeList} role={depth ? 'group' : 'tree'} aria-label={depth ? undefined : 'Pages'}>
      {pages.map((p) => (
        <li key={p.id} role="treeitem" aria-expanded={openIds.has(p.id)} aria-current={p.id === current ? 'page' : undefined}>
          <NavLink to={pathUrl([...basePath, p])} state={{ kind: 'page' }} className={[styles.treeItem, p.id === current ? styles.treeOn : ''].join(' ')}>
            {p.sealed ? nameOf?.(p) || 'Sealed page' : p.name}
          </NavLink>
          {openIds.has(p.id) && <Level orgId={orgId} slug={slug} basePath={[...basePath, p]} parentId={p.id} current={current} openIds={openIds} depth={depth + 1} nameOf={nameOf} />}
        </li>
      ))}
    </ul>
  )
}

/* The left rail (mockup: .wtree): the pages next to this one, with the open
   page's ancestors and its own sub-pages expanded, and New page. */
export default function PageTree({ orgId, slug, page, nameOf }) {
  const path = page.path || []
  // Ancestors that are pages are open; the rail starts at the nearest folder above them.
  // ponytail: path segments carry no kind, so the parent of the page is taken as the rail's root.
  const root = page.parent_id
  const openIds = new Set([page.id, ...path.map((p) => p.id)])
  const newPage = async () => {
    await diskApi.createPage(orgId, root, 'Untitled')
    useDiskStore.getState().invalidate(orgId)
  }
  return (
    <aside className={styles.tree} aria-label="Pages here">
      <div className={styles.treeHead}><FileTypeIcon kind="page" size={18} />Pages here</div>
      {root && <Level orgId={orgId} slug={slug} basePath={path.slice(0, -1)} parentId={root} current={page.id} openIds={openIds} depth={0} nameOf={nameOf} />}
      <button type="button" className={styles.treeNew} onClick={newPage}>+ New page</button>
    </aside>
  )
}
