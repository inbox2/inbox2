import { useCallback, useEffect, useState } from 'react'
import { useOutletContext, useSearchParams } from 'react-router'
import FileTypeIcon, { ActionIcon } from '../../components/FileTypeIcon'
import Skeleton from '../../components/Skeleton'
import { MgmtButton, MgmtModal } from '../../components/management'
import diskApi from '../../lib/disk/api'
import formatBytes from '../../lib/formatBytes'
import ImportWizard from './ImportWizard'
import { saveUrl } from '../../lib/disk/download'
import styles from './ImportPage.module.css'

const ACTIVE = ['queued', 'running']
const STATE_TEXT = { running: 'Importing', queued: 'Waiting', paused: 'Paused', done: 'Done', cancelled: 'Cancelled', skipped: 'Skipped' }
const count = (n, one, many) => `${n} ${n === 1 ? one : many}`
const PAUSE_TEXT = {
  quota: 'Disk is full. Free some space or ask an admin for more, then resume.',
  transfer_cap: 'The source limits how much you can copy a day. Resume tomorrow.',
  authorization: 'The connection to the source stopped working. Connect again, then resume.',
  error: 'Something went wrong. Resume to try again.',
}
/* /disk/import (spec F10): bring files in from Google Drive, Microsoft 365
   or Dropbox. The wizard connects a source and starts an import; this page
   follows the progress, resumes a paused import and shows the report.
   `?new=1` opens the wizard; the provider's callback reopens it on its source. */
export default function ImportPage() {
  const { orgId, isAdmin } = useOutletContext()
  const [params, setParams] = useSearchParams()
  const [imports, setImports] = useState(null)
  const [report, setReport] = useState(null)
  const [error, setError] = useState(null)
  const failed = params.get('status') && params.get('status') !== 'connected'
  // null closed, { provider } open (provider null: the source cards).
  const [wizard, setWizard] = useState(() => (params.get('status') === 'connected' ? { provider: params.get('source') }
    : params.get('new') ? { provider: null } : null))

  const loadImports = useCallback(() => diskApi.imports(orgId).then((d) => setImports(d.imports)).catch(() => setImports([])), [orgId])
  useEffect(() => { loadImports() }, [loadImports])
  // Live progress while anything runs.
  const running = imports?.some((i) => ACTIVE.includes(i.state))
  useEffect(() => {
    if (!running) return undefined
    const t = setInterval(loadImports, 3000)
    return () => clearInterval(t)
  }, [running, loadImports])

  const connect = (provider, reach) => diskApi.importConnect(orgId, provider, reach)
    .then(({ authorize_url: url }) => { window.location.assign(url) })
    .catch(setError)
  const act = (p) => p.then(loadImports).catch(setError)
  const closeWizard = () => { setWizard(null); setParams({}, { replace: true }) }

  return (
    <div className={styles.page}>
      <div className={styles.head}>
        <div>
          <h1 className={styles.title}>Import</h1>
          <p className={styles.sub}>Copy files from Google Drive, OneDrive or Dropbox. Nothing changes there.</p>
        </div>
        <MgmtButton size="sm" variant="primary" onClick={() => setWizard({ provider: null })}><ActionIcon name="download" />Import files</MgmtButton>
      </div>
      {failed && (
        <p className={styles.error} role="status">
          Connecting didn&apos;t work. Try again.
          <MgmtButton size="sm" variant="ghost" onClick={() => setParams({}, { replace: true })}>Dismiss</MgmtButton>
        </p>
      )}
      {error && <p className={styles.error} role="alert">{error.message}</p>}

      <h2 className={styles.h2}>Imports</h2>
      {imports === null ? <Skeleton variant="text" count={3} /> : !imports.length ? <p className={styles.muted}>Nothing imported yet.</p> : (
        <ul className={styles.imports}>
          {imports.map((i) => (
            <li key={i.id} className={styles.import}>
              <FileTypeIcon kind="folder" size={28} />
              <span className={styles.importText}>
                <b>{i.space_name || i.provider}</b>
                <small>
                  {i.state === 'queued' && i.waiting_until ? `Waiting for the source until ${new Date(i.waiting_until).toLocaleTimeString()}` : STATE_TEXT[i.state] || i.state}
                  {i.counts ? `: ${count(i.counts.files || 0, 'file', 'files')}, ${count(i.counts.folders || 0, 'folder', 'folders')}, ${formatBytes(i.counts.bytes || 0)}${i.counts.skipped ? `, ${i.counts.skipped} skipped` : ''}${i.counts.failed ? `, ${i.counts.failed} failed` : ''}` : ''}
                  {isAdmin && i.started_by?.name ? `, by ${i.started_by.name}` : ''}
                </small>
                {i.state === 'paused' && <small className={styles.warn}>{PAUSE_TEXT[i.pause_reason] || i.error}</small>}
                {i.state === 'skipped' && i.error && <small>{i.error}</small>}
              </span>
              {i.state === 'paused' && i.pause_reason === 'authorization' && (
                <MgmtButton size="sm" variant="glass" onClick={() => connect(i.provider, i.space_kind === 'personal' ? 'member' : 'org')}>Connect again</MgmtButton>
              )}
              {i.resumable && <MgmtButton size="sm" variant="primary" onClick={() => act(diskApi.resumeImport(orgId, i.id))}>Resume</MgmtButton>}
              {[...ACTIVE, 'paused'].includes(i.state) && <MgmtButton size="sm" variant="ghost" onClick={() => act(diskApi.cancelImport(orgId, i.id))}>Cancel</MgmtButton>}
              <MgmtButton size="sm" variant="glass" onClick={() => setReport(i)}>Report</MgmtButton>
            </li>
          ))}
        </ul>
      )}

      {wizard && <ImportWizard provider={wizard.provider} onClose={closeWizard} onStarted={() => { closeWizard(); loadImports() }} />}
      {report && <ImportReport orgId={orgId} imp={report} onClose={() => setReport(null)} />}
    </div>
  )
}

/** The report (spec F10): skipped, renamed, converted and not verified, moved, deleted at the source, unmatched people. */
function ImportReport({ orgId, imp, onClose }) {
  const [pages, setPages] = useState([])
  const [cursor, setCursor] = useState(undefined)
  const [error, setError] = useState(null)
  const more = useCallback((c) => diskApi.importReport(orgId, imp.id, c)
    // The first page replaces (the effect may run twice); later pages append.
    .then(({ report }) => { setPages((p) => (c ? [...p, report] : [report])); setCursor(report.next_cursor) })
    .catch(setError), [orgId, imp.id])
  useEffect(() => { more() }, [more])
  const first = pages[0]
  const entries = pages.flatMap((p) => p.entries)
  // A done item can carry a reason too (a Doc over the page limit kept as a .md file).
  const line = (e) => (e.status === 'done' && e.reason ? `${what(e)}. ${e.reason}` : what(e))
  const what = (e) => {
    if (e.status === 'skipped' || e.status === 'failed') return `${e.status}: ${e.reason || ''}`
    if (e.renamed_from) return `renamed from "${e.renamed_from}"${e.rename_reason ? ` (${e.rename_reason})` : ''}${e.clashed_with ? `, clashed with ${e.clashed_with}` : ''}`
    if (e.converted) return `converted${e.format ? ` to ${e.format}` : ''}${e.hash_verified === false ? ', not verified against the source' : ''}`
    if (e.moved) return 'moved at the source since the last import'
    if (e.deleted_at_source) return 'deleted at the source (kept here)'
    if (e.public_link) return 'had a public link at the source (not copied)'
    return e.status
  }
  return (
    <MgmtModal open onClose={onClose} width={640}>
      <h2 className={styles.h2}>Import report: {imp.space_name || imp.provider}</h2>
      {error && <p className={styles.error}>{error.message}</p>}
      {!first ? <Skeleton variant="text" count={4} /> : (
        <>
          <p className={styles.muted}>{Object.entries(first.import.counts || {}).filter(([, n]) => n).map(([k, n]) => `${k.replace(/_/g, ' ')} ${k === 'bytes' ? formatBytes(n) : n}`).join(', ')}</p>
          {first.unmatched_people?.length > 0 && (
            <>
              <h3 className={styles.h3}>Unmatched people</h3>
              <p className={styles.muted}>inbox2 couldn&apos;t copy their access. Invite them, then share again.</p>
              <ul className={styles.plain}>{first.unmatched_people.map((p) => <li key={p.email}>{p.email}, {p.items} {p.items === 1 ? 'item' : 'items'}</li>)}</ul>
            </>
          )}
          {first.unresolved_groups?.length > 0 && (
            <>
              <h3 className={styles.h3}>Unmatched groups</h3>
              <ul className={styles.plain}>{first.unresolved_groups.map((g) => <li key={g.name}>{g.name}, {g.items} {g.items === 1 ? 'item' : 'items'}</li>)}</ul>
            </>
          )}
          <h3 className={styles.h3}>Items to check</h3>
          {!entries.length ? <p className={styles.muted}>inbox2 copied every item unchanged.</p> : (
            <ul className={styles.plain}>{entries.map((e) => <li key={e.source_id}><b>{e.name}</b> <small>{line(e)}</small></li>)}</ul>
          )}
          {cursor && <MgmtButton size="sm" variant="glass" onClick={() => more(cursor)}>Show more</MgmtButton>}
        </>
      )}
      <div className={styles.row}>
        <MgmtButton variant="glass" size="sm" disabled={!first} onClick={async () => {
          // The whole report as JSON: every page, fetched here (the API's ?download=1 answers the same).
          const all = [...pages]
          for (let c = cursor; c;) { const { report: r } = await diskApi.importReport(orgId, imp.id, c); all.push(r); c = r.next_cursor }
          saveUrl(URL.createObjectURL(new Blob([JSON.stringify({ ...all[0], entries: all.flatMap((p) => p.entries), next_cursor: null }, null, 2)], { type: 'application/json' })), `import-report-${imp.id}.json`)
        }}><ActionIcon name="download" />Download report</MgmtButton>
        <MgmtButton variant="glass" size="sm" onClick={onClose}><ActionIcon name="check" />Close</MgmtButton>
      </div>
    </MgmtModal>
  )
}
