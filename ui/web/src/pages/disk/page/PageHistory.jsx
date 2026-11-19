import { useEffect, useState } from 'react'
import SlideOver from '../../../components/SlideOver'
import Skeleton from '../../../components/Skeleton'
import { MgmtButton } from '../../../components/management'
import diskApi from '../../../lib/disk/api'
import formatBytes from '../../../lib/formatBytes'
import styles from './Page.module.css'

/* A page's history (spec F6): one entry per person per ten minutes, kept 180
   days. Pick one to read it; Restore loads it into the live page and saves
   with restored_from, so everyone editing converges on it. */
export default function PageHistory({ orgId, node, canRestore, onRestore, onClose }) {
  const [versions, setVersions] = useState(null)
  const [open, setOpen] = useState(null)
  const [error, setError] = useState(null)
  const [cursor, setCursor] = useState(null)
  useEffect(() => {
    let live = true
    diskApi.pageVersions(orgId, node.id)
      .then((d) => { if (live) { setVersions(d.versions); setCursor(d.next_cursor || null) } })
      .catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [orgId, node.id])
  const more = () => diskApi.pageVersions(orgId, node.id, cursor)
    .then((d) => { setVersions((v) => [...v, ...d.versions]); setCursor(d.next_cursor || null) })
    .catch(setError)
  const show = (v) => diskApi.pageVersion(orgId, node.id, v.revision).then((d) => setOpen(d.version)).catch(setError)
  return (
    <SlideOver open onClose={onClose} title={`History of ${node.name}`}>
      <div className={styles.history}>
        {error && <p className={styles.error} role="alert">{error.message}</p>}
        {!versions && !error && <Skeleton variant="text" count={5} />}
        {versions?.length === 0 && <p>No saved versions yet.</p>}
        <ul className={styles.versions}>
          {versions?.map((v, i) => (
            <li key={v.revision} className={styles.version}>
              <button type="button" className={styles.versionBtn} aria-pressed={open?.revision === v.revision} onClick={() => show(v)}>
                <b>{new Date(v.updated_at || v.created_at).toLocaleString()}{i === 0 ? ', latest' : ''}</b>
                <small>{v.author?.name || 'Someone'}, {formatBytes(v.size_bytes)}</small>
              </button>
              {canRestore && i > 0 && <MgmtButton size="sm" variant="ghost" onClick={() => onRestore(v.revision)}>Restore</MgmtButton>}
            </li>
          ))}
        </ul>
        {cursor && <MgmtButton size="sm" variant="glass" onClick={more}>Show older versions</MgmtButton>}
        {open && <pre className={styles.versionText}>{open.markdown}</pre>}
      </div>
    </SlideOver>
  )
}
