import { useCallback, useEffect, useState } from 'react'
import useAuth from '../../hooks/useAuth'
import Skeleton from '../../components/Skeleton'
import Switch from '../../components/Switch/Switch'
import { MgmtButton, MgmtConfirm, MgmtMeter } from '../../components/management'
import diskApi from '../../lib/disk/api'
import { formatPath, pathSegments } from '../../lib/disk/paths'
import formatBytes from '../../lib/formatBytes'
import { pathUrl } from '../../lib/disk/model'
import DiskActivity from './DiskActivity'
import DiskAgents from './DiskAgents'
import styles from './console.module.css'
import own from './ConsoleDisk.module.css'
import { consolePath } from '../../lib/consoleHost';

const STATE_TEXT = {
  read_only: (s) => `Your plan no longer includes Disk, so it is read-only. You can open and download files until ${new Date(s.read_only_until).toLocaleDateString()}. inbox2 deletes them on ${new Date(s.purge_at).toLocaleDateString()}. Upgrade to keep Disk.`,
}

/* /console/disk (spec F11): usage by member and by share, every public link with
   revoke, the public-links switch, and the org export. Owners and admins only;
   the API refuses everyone else. */
export default function ConsoleDisk() {
  const { currentOrg } = useAuth()
  const orgId = currentOrg?.id
  const [usage, setUsage] = useState(null)
  const [error, setError] = useState(null)
  const [links, setLinks] = useState(null)
  const [cursor, setCursor] = useState(null)
  const [revoke, setRevoke] = useState(null)
  const [exporting, setExporting] = useState(null) // { done, bytes } | { result } | { error }
  const [exportCtl, setExportCtl] = useState(null)

  const load = useCallback(() => {
    if (!orgId) return
    diskApi.adminUsage(orgId).then((d) => { setUsage(d.usage); setError(null) }).catch(setError)
    diskApi.adminLinks(orgId).then((d) => { setLinks(d.links); setCursor(d.next_cursor) }).catch(() => setLinks([]))
  }, [orgId])
  useEffect(() => { load() }, [load])

  const moreLinks = () => diskApi.adminLinks(orgId, cursor).then((d) => { setLinks((l) => [...l, ...d.links]); setCursor(d.next_cursor) })
  const toggleLinks = (on) => diskApi.adminSettings(orgId, { links_enabled: on })
    .then(({ settings }) => setUsage((u) => ({ ...u, settings })))
    .catch(setError)
  const doRevoke = () => {
    const l = revoke
    setRevoke(null)
    diskApi.adminRevokeLink(orgId, l.id).then(() => setLinks((all) => all.filter((x) => x.id !== l.id))).catch(setError)
  }
  const startExport = async () => {
    const ctl = new AbortController()
    setExportCtl(ctl)
    setExporting({ done: 0, bytes: 0 })
    try {
      const { exportOrg } = await import('../../lib/disk/orgExport')
      const result = await exportOrg(orgId, `${currentOrg.slug || 'disk'}-disk-export.zip`, { signal: ctl.signal, onProgress: (p) => setExporting(p) })
      setExporting({ result })
    } catch (e) {
      setExporting(e.aborted || e.name === 'AbortError' ? null : { error: e.message })
    } finally {
      setExportCtl(null)
    }
  }

  if (error?.status === 403 && !usage) {
    return (
      <div className={`${styles.card} ${own.pad}`} role="alert">
        <h1 className={styles.cardTitle}>Disk</h1>
        <p>{error.message}</p>
        <MgmtButton as="a" href={consolePath('billing')} variant="glass" size="sm">See plans</MgmtButton>
      </div>
    )
  }

  const q = usage?.quota
  const settings = usage?.settings
  const pct = q?.pool_bytes ? (q.used_bytes + q.reserved_bytes) / q.pool_bytes : 0
  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>Disk</div>
          <h1 className={styles.pageTitle}>Disk</h1>
          <p className={styles.pageSub}>Manage space and public links, and export the shares.</p>
        </div>
      </div>
      {error && <p className={own.error} role="alert">{error.message}</p>}
      {settings?.state === 'read_only' && <p className={own.warn} role="status">{STATE_TEXT.read_only(settings)}</p>}
      {!usage ? (
        <div aria-busy="true">
          <div className={`${styles.card} ${own.pad}`}><h2 className={styles.cardTitle}>Space</h2><Skeleton variant="text" count={3} /></div>
          <div className={`${styles.card} ${styles.mt}`}><div className={styles.cardHead}><h2 className={styles.cardTitle}>By share</h2></div><Skeleton variant="text" count={4} className={own.tableSkeleton} /></div>
        </div>
      ) : (
        <>
          <div className={`${styles.card} ${own.pad}`}>
            <h2 className={styles.cardTitle}>Space</h2>
            <p className={own.big}>{formatBytes(q.used_bytes)} of {formatBytes(q.pool_bytes)} used{q.reserved_bytes ? `, ${formatBytes(q.reserved_bytes)} uploading` : ''}</p>
            <MgmtMeter value={pct} />
            <p className={own.muted}>
              Files {formatBytes(q.files_bytes || 0)}, older versions {formatBytes(q.versions_bytes || 0)}, Trash {formatBytes(q.trash_bytes || 0)}.
              {usage.quota_override_gb ? ` Set to ${usage.quota_override_gb} GB for this organization.` : ' Shared by every member.'}
            </p>
            {pct >= 1 && <p className={own.error}>Disk is full. Free space or upgrade to upload again.</p>}
            {pct >= 0.8 && pct < 1 && <p className={own.warn}>Disk is {Math.round(pct * 100)}% full.</p>}
          </div>

          {/* A member's C:\ is their own (2026-10-07), not in this team's space, so only the shares are listed. */}
          <div className={`${styles.card} ${styles.mt}`}>
              <div className={styles.cardHead}><h2 className={styles.cardTitle}>By share</h2></div>
              <table className={styles.tbl}>
                <thead><tr><th>Share</th><th>Members</th><th className={styles.right}>Size</th></tr></thead>
                <tbody>
                  {[...usage.shares].sort((a, b) => b.bytes - a.bytes).map((r) => (
                    <tr key={r.share.id}>
                      <td>{r.share.name}{r.share.trashed_at ? ' (deleted)' : r.share.archived_at ? ' (archived)' : ''}</td>
                      <td className={styles.num}>{r.share.member_count}</td>
                      <td className={`${styles.right} ${styles.num}`}>{formatBytes(r.bytes)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
          </div>

          <div className={`${styles.card} ${styles.mt}`}>
            <div className={styles.cardHead}>
              <h2 className={styles.cardTitle}>Public links</h2>
              <Switch
                id="disk-links"
                label="Allow public links"
                checked={!!settings?.links_enabled}
                onChange={toggleLinks}
                ariaLabel="Allow public links"
              />
            </div>
            {!settings?.links_enabled && <p className={`${own.muted} ${own.pad}`}>Nobody can make a public link, and existing links don't open.</p>}
            {links === null ? <Skeleton variant="text" count={3} className={own.tableSkeleton} /> : !links.length ? (
              <p className={`${own.muted} ${own.pad}`}>No public links.</p>
            ) : (
              <table className={styles.tbl}>
                <thead><tr><th>Item</th><th>Made by</th><th>Expires</th><th>Last opened</th><th /></tr></thead>
                <tbody>
                  {links.map((l) => (
                    <tr key={l.id}>
                      <td>
                        <a className={own.link} href={`${pathUrl(l.node.path || [])}?org=${encodeURIComponent(currentOrg.slug)}`}>{l.node.name || 'Sealed item'}</a>
                        <small className={own.path}>{l.node.path?.length ? formatPath(pathSegments(l.node.drive, l.node.path.slice(0, -1))) : ''}</small>
                        {(l.has_password || l.hide_download) && <small className={own.path}>{[l.has_password && 'password', l.hide_download && 'no download button'].filter(Boolean).join(', ')}</small>}
                      </td>
                      <td>{l.created_by?.name}</td>
                      <td>{l.expired ? 'Expired' : l.expires_at ? new Date(l.expires_at).toLocaleDateString() : 'Never'}</td>
                      <td>{l.last_used_at ? new Date(l.last_used_at).toLocaleDateString() : 'Not yet'}</td>
                      <td className={styles.right}><MgmtButton size="sm" variant="danger" onClick={() => setRevoke(l)}>Revoke</MgmtButton></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
            {cursor && <div className={own.pad}><MgmtButton size="sm" variant="glass" onClick={moreLinks}>Show more</MgmtButton></div>}
          </div>

          <DiskActivity orgId={orgId} shares={usage.shares} members={usage.members} />

          <div className={`${styles.card} ${styles.mt} ${own.pad}`}>
            <h2 className={styles.cardTitle}>Export shares</h2>
            <p className={own.muted}>
              You get one zip of every file and page in the shares.
              It skips sealed items and each member's C:\.
            </p>
            {exporting?.done != null && <p className={own.muted} role="status">Exporting: {exporting.done} items, {formatBytes(exporting.bytes)}...</p>}
            {exporting?.result && (
              <p className={own.muted} role="status">
                Export saved with {exporting.result.done - exporting.result.skipped.length} items.
                {exporting.result.skipped.length ? ` ${exporting.result.skipped.length} skipped. SKIPPED.txt in the zip lists them.` : ''}
              </p>
            )}
            {exporting?.error && <p className={own.error} role="alert">{exporting.error}</p>}
            {exportCtl
              ? <MgmtButton size="sm" variant="glass" onClick={() => exportCtl.abort()}>Cancel</MgmtButton>
              : <MgmtButton size="sm" variant="dark" onClick={startExport}>Start export</MgmtButton>}
          </div>
        </>
      )}
      {usage && <DiskAgents orgId={orgId} orgSlug={currentOrg.slug} />}
      <MgmtConfirm
        open={!!revoke}
        danger
        title="Revoke this link?"
        message="It stops opening at once."
        confirmLabel="Revoke"
        onConfirm={doRevoke}
        onClose={() => setRevoke(null)}
      />
    </>
  )
}
