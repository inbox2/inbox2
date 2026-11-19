import { useEffect, useState } from 'react'
import { MgmtButton } from '../../../components/management'
import useSealedStore from '../../../stores/sealedStore'
import { CrossSealDialog } from './SealedUI'
import styles from './Sealed.module.css'

/** Moves and copies across a seal boundary left unfinished in this browser (6.8): offered for resume on entering Disk. */
export default function ResumeJobs({ orgId, onDone }) {
  const [jobs, setJobs] = useState([])
  const [open, setOpen] = useState(null) // { job, scope }
  const [error, setError] = useState(null)
  useEffect(() => {
    import('../../../lib/disk/crossSeal').then(({ jobStore }) => jobStore.all()).then((all) => setJobs(all.filter((j) => j.orgId === orgId && !j.done))).catch(() => {})
  }, [orgId])
  if (!jobs.length) return null
  const resume = async (job) => {
    const scope = await useSealedStore.getState().open(orgId, job.scopeId)
    const from = job.fromScopeId ? await useSealedStore.getState().open(orgId, job.fromScopeId) : null
    if (!scope || (job.fromScopeId && !from)) return setError('Unlock your key to resume it.')
    setOpen({ job, scope, from })
  }
  return (
    <div className={`${styles.banner} ${styles.warn}`} role="status">
      <b>Unfinished:</b> {jobs.length === 1 ? 'a move or copy' : `${jobs.length} moves or copies`} into or out of a sealed folder stopped part way.
      {jobs.map((j) => <MgmtButton key={j.id} size="sm" variant="primary" onClick={() => resume(j)}>Resume ({j.items.filter((i) => i.state === 'done').length} of {j.items.length} done)</MgmtButton>)}
      {error && <span className={styles.error}>{error}</span>}
      {open && (
        <CrossSealDialog op={open.job.op} direction={open.job.direction} count={open.job.items.length} job={open.job} scope={open.scope} from={open.from}
          onDone={() => { setJobs((all) => all.filter((x) => x.id !== open.job.id)); onDone?.() }}
          onClose={() => setOpen(null)} />
      )}
    </div>
  )
}
