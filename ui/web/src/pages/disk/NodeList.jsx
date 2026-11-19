import { useEffect, useRef } from 'react'
import FileTypeIcon from '../../components/FileTypeIcon'
import formatBytes from '../../lib/formatBytes'
import { formatMailTime } from '../../lib/relativeTime'
import { formatPath, pathSegments, nodeLabel } from '../../lib/disk/paths'
import { KIND } from '../../lib/disk/model'
import AccessCell from './AccessCell'
import Thumb, { FolderPeek } from './Thumb'
import { fileType } from '../../lib/disk/fileTypes'
import styles from './NodeList.module.css'

function NodeIcon({ node, size }) {
  // Trashed items read as faded, so the trash never looks like a live folder.
  if (node.trashed_at) return <span className={styles.trashed}><TypeIcon node={node} size={size} /></span>
  return <TypeIcon node={node} size={size} />
}

function TypeIcon({ node, size }) {
  if (node.kind === KIND.FOLDER) return <FileTypeIcon kind="folder" sealed={node.sealed} size={size} />
  if (node.kind === KIND.PAGE) return <FileTypeIcon kind="page" size={size * 1.07} />
  return <FileTypeIcon name={node.name} mime={node.mime} type={node.sealed && !node.opened ? 'key' : undefined} size={size * 1.07} />
}

function Highlight({ text, q }) {
  if (!q) return text
  const i = text.toLowerCase().indexOf(q.toLowerCase())
  if (i < 0) return text
  return <>{text.slice(0, i)}<mark className={styles.mark}>{text.slice(i, i + q.length)}</mark>{text.slice(i + q.length)}</>
}

export function RenameField({ node, onRename, onCancel }) {
  const ref = useRef(null)
  useEffect(() => {
    const el = ref.current
    if (!el) return
    el.focus()
    // Select the name without its extension, as Finder and Explorer do.
    const dot = node.kind === KIND.FOLDER ? -1 : el.value.lastIndexOf('.')
    el.setSelectionRange(0, dot > 0 ? dot : el.value.length)
  }, [node])
  const done = useRef(false)
  const submit = (value) => {
    if (done.current) return
    done.current = true
    const name = value.trim()
    if (name && name !== node.name) onRename(node, name)
    else onCancel()
  }
  return (
    <input
      ref={ref}
      className={styles.rename}
      defaultValue={node.name}
      aria-label={`Rename ${node.name}`}
      onKeyDown={(e) => {
        e.stopPropagation()
        if (e.key === 'Enter') submit(e.currentTarget.value)
        if (e.key === 'Escape') { done.current = true; onCancel({ escape: true }) } // Escape, not an unchanged name, undoes New folder
      }}
      onBlur={(e) => submit(e.currentTarget.value)}
    />
  )
}

function Name({ node, q, showPath, renaming, onRename, onRenameCancel, onOpen, isTile }) {
  if (renaming) return <RenameField node={node} onRename={onRename} onCancel={onRenameCancel} />
  const label = nodeLabel(node)
  const where = showPath && node.path ? formatPath(pathSegments(node.drive, node.path.slice(0, -1))) : null
  return (
    <button
      type="button"
      className={isTile ? styles.tileName : styles.name}
      onClick={() => onOpen(node)}
      title={node.sealed && !node.opened ? 'Sealed: open to unlock your key' : undefined}
    >
      {!isTile && <NodeIcon node={node} size={28} />}
      <span className={styles.nameText}>
        <Highlight text={label} q={q} />
        {where && <span className={styles.loc}>{where}</span>}
      </span>
      {node.sealed && <span className={styles.lock}>sealed</span>}
      {node.starred && <span className={styles.star} aria-label="Starred">★</span>}
    </button>
  )
}

const SORTABLE = [['name', 'Name'], ['modified', 'Modified'], ['by', 'By']]

/**
 * The folder listing in list or grid form (mockup: the table and .tiles).
 * Click model (spec F1): a click on the row or tile selects, the title or a
 * double click opens. Rows carry data-index for the keyboard and right-click
 * handlers that DiskBrowser attaches to the wrapper.
 */
export default function NodeList({
  nodes, view, selected, focusIndex, q, showPath, access, sort, onSort,
  renamingId, onRename, onRenameCancel, onPick, onOpen, onToggle, onToggleAll, dim, thumbOrg, tile,
}) {
  const tilesRef = useRef(null)
  useEffect(() => { if (tile) tilesRef.current?.style.setProperty('--tile', `${tile}px`) }, [tile, view])
  const allSelected = nodes.length > 0 && nodes.every((n) => selected.has(n.id))
  const common = (n) => ({ q, showPath, renaming: renamingId === n.id, onRename, onRenameCancel, onOpen })
  const rowEvents = (i) => ({
    'data-index': i,
    onClick: (e) => { if (!e.target.closest('button, input, [data-access]')) onPick(i, e) },
    onDoubleClick: (e) => { if (!e.target.closest('button, input, [data-access]')) onOpen(nodes[i]) },
  })

  if (view === 'grid') {
    return (
      <div ref={tilesRef} className={[styles.tiles, dim ? styles.dim : ''].join(' ')} role="listbox" aria-multiselectable="true" aria-label="Items">
        {nodes.map((n, i) => (
          <div
            key={n.id}
            className={[styles.tile, selected.has(n.id) ? styles.picked : ''].join(' ')}
            role="option"
            aria-selected={selected.has(n.id)}
            tabIndex={focusIndex === i ? 0 : -1}
            {...rowEvents(i)}
          >
            {thumbOrg && n.kind === KIND.FOLDER && !n.trashed_at
              ? <FolderPeek orgId={thumbOrg} node={n}><NodeIcon node={n} size={22} /><Name node={n} isTile {...common(n)} /></FolderPeek>
              : thumbOrg && n.current_version_id && n.has_thumbnail !== false && ['image', 'pdf', 'video'].includes(fileType(n).preview)
                ? <Thumb orgId={thumbOrg} versionId={n.current_version_id} load={n.sealed ? n.thumb : undefined}><NodeIcon node={n} size={52} /></Thumb>
                : <NodeIcon node={n} size={52} />}
            {!(thumbOrg && n.kind === KIND.FOLDER && !n.trashed_at) && <Name node={n} isTile {...common(n)} />}
            <small className={styles.tileMeta}>{n.kind === KIND.FILE ? formatBytes(n.size_bytes) : ''}</small>
          </div>
        ))}
      </div>
    )
  }

  const th = (key, label) => (
    <th key={key} aria-sort={sort.key === key ? (sort.dir > 0 ? 'ascending' : 'descending') : undefined} className={key !== 'name' ? styles.hideSm : undefined}>
      <button type="button" className={styles.sortBtn} onClick={() => onSort(key)}>
        {label}<span className={styles.arrow} aria-hidden="true">{sort.dir > 0 ? '▲' : '▼'}</span>
      </button>
    </th>
  )

  return (
    <div className={[styles.card, dim ? styles.dim : ''].join(' ')}>
      <table className={styles.table}>
        <Cols access={!!access} />
        <thead>
          <tr>
            <th className={styles.c}>
              <MgmtCheckbox  className={styles.ck} aria-label="Select all" checked={allSelected} onChange={(e) => onToggleAll(e.target.checked)} />
            </th>
            {SORTABLE.map(([k, l]) => th(k, l))}
            {access && <th className={styles.hideSm}>Access</th>}
            <th aria-sort={sort.key === 'size' ? (sort.dir > 0 ? 'ascending' : 'descending') : undefined} className={styles.n}>
              <button type="button" className={styles.sortBtn} onClick={() => onSort('size')}>
                Size<span className={styles.arrow} aria-hidden="true">{sort.dir > 0 ? '▲' : '▼'}</span>
              </button>
            </th>
          </tr>
        </thead>
        <tbody>
          {nodes.map((n, i) => (
            <tr key={n.id} className={selected.has(n.id) ? styles.picked : undefined} {...rowEvents(i)}>
              <td className={styles.c}>
                <MgmtCheckbox
                  
                  className={styles.ck}
                  aria-label={`Select ${nodeLabel(n)}`}
                  checked={selected.has(n.id)}
                  onChange={(e) => onToggle(i, e.target.checked)}
                  tabIndex={-1}
                />
              </td>
              <td className={styles.nameCell}><Name node={n} {...common(n)} /></td>
              <td className={`${styles.m} ${styles.hideSm}`}>{formatMailTime(n.content_modified_at || n.created_at)}</td>
              <td className={`${styles.m} ${styles.hideSm}`}>{n.modified_by?.name || ''}</td>
              {access && <td className={`${styles.hideSm} ${styles.accessCell}`}><AccessCell node={n} {...access} /></td>}
              <td className={styles.n}>{n.kind === KIND.FILE ? formatBytes(n.size_bytes) : ''}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Cols({ access }) {
  return (
    <colgroup>
      <col className={styles.colCheck} />
      <col />
      <col className={`${styles.colMod} ${styles.hideSm}`} />
      <col className={`${styles.colBy} ${styles.hideSm}`} />
      {access && <col className={`${styles.colAccess} ${styles.hideSm}`} />}
      <col className={styles.colSize} />
    </colgroup>
  )
}

/** The loading twin: the same table, columns and row height, with bars in the cells. */
export function NodeListSkeleton({ view, rows = 8, access }) {
  if (view === 'grid') {
    return (
      <div className={styles.tiles} aria-hidden="true">
        {Array.from({ length: rows }, (_, i) => (
          <div key={i} className={`${styles.tile} ${styles.skTile}`}>
            <span className={styles.skIcon} /><span className={styles.skBar} /><span className={styles.skBar} />
          </div>
        ))}
      </div>
    )
  }
  return (
    <div className={styles.card} aria-hidden="true">
      <table className={styles.table}>
        <Cols access={access} />
        <thead><tr><th className={styles.c} /><th>Name</th><th className={styles.hideSm}>Modified</th><th className={styles.hideSm}>By</th>{access && <th className={styles.hideSm}>Access</th>}<th className={styles.n}>Size</th></tr></thead>
        <tbody>
          {Array.from({ length: rows }, (_, i) => (
            <tr key={i} className={styles.skRow}>
              <td className={styles.c} />
              <td className={styles.nameCell}><span className={styles.skName}><span className={styles.skIcon} /><span className={styles.skBar} /></span></td>
              <td className={styles.hideSm}><span className={styles.skBar} /></td>
              <td className={styles.hideSm}><span className={styles.skBar} /></td>
              {access && <td className={styles.hideSm}><span className={styles.skBar} /></td>}
              <td className={styles.n}><span className={styles.skBar} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

import { MgmtCheckbox } from '../../components/management';