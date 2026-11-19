import { useEffect, useState } from 'react'
import { NodeViewWrapper } from '@tiptap/react'
import FileTypeIcon from '../../../components/FileTypeIcon'
import diskApi from '../../../lib/disk/api'
import formatBytes from '../../../lib/formatBytes'
import { formatPath, pathSegments } from '../../../lib/disk/paths'
import styles from './Page.module.css'

/* A Disk file embedded in a page (mockup: .embed). Shows what the reader can
   see: a reader without access to the file gets a locked card. Click opens the preview. */
export default function DiskFileCard({ node, extension, selected }) {
  const { orgId, onOpen } = extension.options
  const { nodeId, name } = node.attrs
  const [file, setFile] = useState(null)
  const [locked, setLocked] = useState(false)
  useEffect(() => {
    if (!orgId || !nodeId) return undefined
    let live = true
    diskApi.node(orgId, nodeId)
      .then((d) => { if (live) setFile(d.node) })
      .catch(() => { if (live) setLocked(true) })
    return () => { live = false }
  }, [orgId, nodeId])
  const where = file?.path ? formatPath(pathSegments(file.drive, file.path.slice(0, -1))) : ''
  return (
    <NodeViewWrapper className={[styles.embed, selected ? styles.embedOn : ''].join(' ')} data-drag-handle>
      {locked ? (
        <span className={styles.embedLocked}>
          <FileTypeIcon kind="folder" sealed size={28} />
          <span><b>{name || 'A file'}</b><small>You don&apos;t have access to this file.</small></span>
        </span>
      ) : (
        <button type="button" className={styles.embedBtn} onClick={() => file && onOpen?.(file)} contentEditable={false}>
          <FileTypeIcon name={file?.name || name} mime={file?.mime} size={32} />
          <span><b>{file?.name || name}</b><small>{where}{file ? ` · ${formatBytes(file.size_bytes)}` : ''}</small></span>
        </button>
      )}
    </NodeViewWrapper>
  )
}
