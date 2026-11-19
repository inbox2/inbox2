import { useCallback, useEffect, useState } from 'react'
import { useOutletContext } from 'react-router'
import { ActionIcon } from '../../components/FileTypeIcon'
import Skeleton from '../../components/Skeleton'
import { MgmtButton, MgmtModal } from '../../components/management'
import diskApi from '../../lib/disk/api'
import { teamDriveLabel } from '../../lib/disk/model'
import { MoveDialog } from './DiskDialogs'
import styles from './ImportPage.module.css'

const STEPS = ['Source', 'Connect', 'Choose files']
const SPACE_TEXT = {
  personal: 'Your own files go to',
  shared: "This shared drive becomes a share on this team's disk",
  member: "A person's own files go to their C:\\",
}
// The providers' own marks, one file per provider slug (public/disk/import/).
const logo = (provider) => `/disk/import/${provider}.svg`

/* The import wizard (spec F10): pick a source, connect it with a read-only
   grant, tick what to bring and where it lands. Connecting leaves for the
   provider's consent page; the callback reopens the wizard on `provider`. */
export default function ImportWizard({ provider: initial = null, onClose, onStarted }) {
  const { orgId, people, drives } = useOutletContext()
  const [sources, setSources] = useState(null)
  const [provider, setProvider] = useState(initial)
  const [picked, setPicked] = useState(() => new Set())
  const [target, setTarget] = useState(null) // { id, label } for personal imports
  const [choosing, setChoosing] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const load = useCallback(() => diskApi.importSources(orgId).then((d) => setSources(d.sources)).catch((e) => { setError(e); setSources([]) }), [orgId])
  useEffect(() => { load() }, [load])

  const s = sources?.find((x) => x.provider === provider)
  const step = !s ? 0 : s.spaces?.length ? 2 : 1
  const name = (id) => people.find((p) => p.id === id)?.name
  const connect = (reach) => diskApi.importConnect(orgId, s.provider, reach)
    .then(({ authorize_url: url }) => { window.location.assign(url) })
    .catch(setError)
  const disconnect = (reach) => diskApi.importDisconnect(orgId, s.provider, reach).then(load).catch(setError)
  const pick = (p) => { setProvider(p); setPicked(new Set()); setError(null) }
  const toggle = (id, on) => {
    const next = new Set(picked)
    if (on) next.add(id)
    else next.delete(id)
    setPicked(next)
  }
  const start = () => {
    setBusy(true)
    diskApi.startImport(orgId, s.provider, [...picked], target?.id).then(onStarted).catch((e) => { setError(e); setBusy(false) })
  }

  if (choosing && drives) {
    return (
      <MoveDialog orgId={orgId} drives={drives} movingIds={[]} verb="Import" onClose={() => setChoosing(false)}
        onPick={(id, _f, root) => { setChoosing(false); setTarget({ id, label: root?.drive === 'D' ? teamDriveLabel() : 'C:\\...' }) }} />
    )
  }

  return (
    <MgmtModal open onClose={onClose} width={620}>
      <ol className={styles.steps}>
        {STEPS.map((label, i) => <li key={label} aria-current={i === step ? 'step' : undefined}>{label}</li>)}
      </ol>
      {error && <p className={styles.error} role="alert">{error.message}</p>}

      {sources === null ? <Skeleton variant="text" count={4} /> : !s ? (
        <>
          <h2 className={styles.wizTitle}>Choose a source</h2>
          <p className={styles.muted}>inbox2 copies your files and leaves the source as it was. Imported files arrive unsealed.</p>
          {!sources.length ? <p className={styles.muted}>This team has no sources yet.</p> : (
            <div className={styles.sourceGrid}>
              {sources.map((x) => (
                <button key={x.provider} type="button" className={styles.source} onClick={() => pick(x.provider)}>
                  <img src={logo(x.provider)} alt="" />
                  {x.label}
                  <small>{x.connected ? `Connected as ${x.account_email || 'you'}` : x.org_connected ? 'Connected for the organization' : 'Not connected yet'}</small>
                </button>
              ))}
            </div>
          )}
        </>
      ) : (
        <>
          <h2 className={styles.wizTitle}><img src={logo(s.provider)} alt="" />{s.label}</h2>
          <p className={styles.muted}>
            {s.connected
              ? <>Connected as {s.account_email || 'you'} <MgmtButton size="sm" variant="ghost" onClick={() => disconnect('member')}>Disconnect</MgmtButton></>
              : <>inbox2 asks for read-only access. <MgmtButton size="sm" variant="primary" onClick={() => connect('member')}>Connect {s.label}</MgmtButton></>}
          </p>
          {s.org_available && (
            <p className={styles.muted}>
              Shared drives and everyone&apos;s files: {s.org_connected
                ? <>connected ({s.org_account}) <MgmtButton size="sm" variant="ghost" onClick={() => disconnect('org')}>Disconnect</MgmtButton></>
                : <MgmtButton size="sm" variant="glass" onClick={() => connect('org')}>Connect for the organization</MgmtButton>}
            </p>
          )}
          {s.spaces_error && <p className={styles.error}>Couldn&apos;t list {s.label}: {s.spaces_error}</p>}
          {step === 2 && (
            <ul className={styles.spaces}>
              {s.spaces.map((sp) => {
                const skip = sp.kind === 'member' && !sp.member_id
                return (
                  <li key={sp.id}>
                    <label className={styles.space}>
                      <MgmtCheckbox  checked={picked.has(sp.id)} onChange={(e) => toggle(sp.id, e.target.checked)} />
                      <span>
                        <b>{sp.name}</b>{sp.email ? ` (${sp.email})` : ''}
                        <small>
                          {SPACE_TEXT[sp.kind]}
                          {sp.kind === 'personal' && ` ${target ? target.label : 'C:\\'}\\${s.folder_name}`}
                          {sp.kind === 'member' && (skip ? '. No member uses this address, so the import skips it.' : ` (${name(sp.member_id) || 'a member'})`)}
                        </small>
                      </span>
                    </label>
                  </li>
                )
              })}
            </ul>
          )}
        </>
      )}

      <div className={styles.row}>
        {s && <MgmtButton size="sm" variant="glass" className={styles.back} onClick={() => pick(null)}><ActionIcon name="chevronLeft" />Other source</MgmtButton>}
        {step === 2 && s.spaces.some((sp) => sp.kind === 'personal') && <MgmtButton size="sm" variant="glass" onClick={() => setChoosing(true)}>Choose a folder...</MgmtButton>}
        <MgmtButton size="sm" variant="glass" onClick={onClose}>Cancel</MgmtButton>
        {step === 2 && <MgmtButton size="sm" variant="primary" disabled={!picked.size || busy} onClick={start}>Start import</MgmtButton>}
      </div>
    </MgmtModal>
  )
}

import { MgmtCheckbox } from '../../components/management';