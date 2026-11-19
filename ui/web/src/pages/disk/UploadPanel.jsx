import { useRef, useState } from 'react'
import FileTypeIcon, { ActionIcon } from '../../components/FileTypeIcon'
import { MgmtButton, MgmtConfirm, MgmtMeter } from '../../components/management'
import useUploadStore, { UPLOAD_STATE as S } from '../../stores/uploadStore'
import { cancel, pause, reattach, resolveConflict, resume, retry, SKIP } from '../../lib/disk/upload'
import { KEEP_BOTH, REPLACE } from '../../lib/disk/api'
import formatBytes from '../../lib/formatBytes'
import useEngineStore from '../../stores/engineStore'
import { setEngineDeclined } from '../../lib/disk/engine/env'
import { makeQueuedRenditions } from '../../lib/disk/engine/rendition'
import styles from './UploadPanel.module.css'

const STATUS = {
  [S.QUEUED]: 'Waiting',
  [S.RUNNING]: 'Uploading',
  [S.PAUSED]: 'Paused',
  [S.CONFLICT]: 'Name taken',
  [S.DONE]: 'Done',
  [S.ERROR]: 'Failed',
  [S.CANCELLED]: 'Cancelled',
  [S.INTERRUPTED]: 'Interrupted',
}

/* Uploads in flight (spec F2): per file and overall progress, pause, cancel,
   retry, the name-clash choice, and uploads a reload interrupted. */
export default function UploadPanel() {
  const items = useUploadStore((s) => s.items)
  const clearFinished = useUploadStore((s) => s.clearFinished)
  const engineOffer = useUploadStore((s) => s.engineOffer)
  const setEngineOffer = useUploadStore((s) => s.setEngineOffer)
  const downloadSize = useEngineStore((s) => s.downloadSize)
  const renditions = useUploadStore((s) => s.renditions)
  const renditionsRunning = useUploadStore((s) => s.renditionsRunning)
  const [renditionError, setRenditionError] = useState(null)
  const [open, setOpen] = useState(true)
  const [applyAll, setApplyAll] = useState(false)
  const [mismatch, setMismatch] = useState(null)
  const [stopping, setStopping] = useState(null)
  const picker = useRef(null)
  const pickFor = useRef(null)
  if (!items.length && !renditions.length) return null

  const live = items.filter((it) => ![S.CANCELLED].includes(it.state))
  const total = live.reduce((s, it) => s + (it.size || 0), 0)
  const loaded = live.reduce((s, it) => s + (it.state === S.DONE ? it.size : it.loaded || 0), 0)
  const active = items.filter((it) => [S.QUEUED, S.RUNNING].includes(it.state)).length
  const quota = items.find((it) => it.quota)
  const conflicts = items.filter((it) => it.state === S.CONFLICT)
  const answer = (id, choice) => resolveConflict(id, choice, applyAll)
  // An upload that has sent something asks first: cancelling throws that progress away.
  // An interrupted one shows 0 sent after a reload but still holds its parts (uploadId).
  const askCancel = (it) => (it.loaded > 0 || it.uploadId ? setStopping(it) : cancel(it.id))

  return (
    <section className={styles.panel} aria-label="Uploads">
      <header className={styles.head}>
        <button type="button" className={styles.toggle} aria-expanded={open} onClick={() => setOpen(!open)}>
          {active ? `Uploading ${active} ${active === 1 ? 'file' : 'files'}` : 'Uploads'}
          <span className={styles.sum}>{formatBytes(loaded)} of {formatBytes(total)}</span>
        </button>
        {!active && <button type="button" className={styles.link} onClick={clearFinished}>Clear</button>}
      </header>
      <div className={styles.overall}><MgmtMeter value={total ? loaded / total : 0} /></div>
      {open && (
        <>
          {quota && <p className={styles.alert} role="alert">{quota.error} Empty the trash or delete old versions, or ask an admin for more space.</p>}
          {engineOffer && (
            <div className={styles.offer} role="status">
              Add exact view to this device? Office files you upload then get an exact view everyone can open{downloadSize ? ` (one-time ${formatBytes(downloadSize)} download)` : ''}.
              <span className={styles.offerActs}>
                <MgmtButton size="sm" variant="primary" onClick={() => { setEngineOffer(false); import('../../lib/disk/engine/install').then((m) => m.installEngine()).catch(() => {}) }}>Add exact view</MgmtButton>
                <MgmtButton size="sm" variant="ghost" onClick={() => { setEngineOffer(false); setEngineDeclined(true) }}>Not now</MgmtButton>
              </span>
            </div>
          )}
          {renditions.length > 0 && (
            <div className={styles.offer} role="status">
              {renditionsRunning
                ? `Making exact views: ${renditions.length} left. Keep this tab open.`
                : `${renditions.length} ${renditions.length === 1 ? 'file opens' : 'files open'} in quick view for now.`}
              {!renditionsRunning && (
                <span className={styles.offerActs}>
                  <MgmtButton size="sm" variant="glass" onClick={() => { setRenditionError(null); makeQueuedRenditions().catch((e) => setRenditionError(e.message)) }}>
                    Make exact {renditions.length === 1 ? 'view' : 'views'}
                  </MgmtButton>
                </span>
              )}
              {renditionError && <span className={styles.error}>{renditionError}</span>}
            </div>
          )}
          {conflicts.length > 0 && (
            <label className={styles.applyAll}>
              <MgmtCheckbox  checked={applyAll} onChange={(e) => setApplyAll(e.target.checked)} />
              Use my answer for every taken name ({conflicts.length})
            </label>
          )}
          {mismatch && <p className={styles.alert} role="alert">{mismatch}</p>}
          <ul className={styles.list}>
            {items.map((it) => (
              <li key={it.id} className={styles.item}>
                <div className={styles.row}>
                  <FileTypeIcon name={it.name} size={16} />
                  <span className={styles.name} title={it.relativePath}>{it.relativePath || it.name}</span>
                  <span className={styles.state}>{STATUS[it.state]}</span>
                  {![S.DONE, S.CANCELLED].includes(it.state) && (
                    <button type="button" className={styles.icon} onClick={() => askCancel(it)} aria-label={`Cancel ${it.name}`}><ActionIcon name="x" size={14} /></button>
                  )}
                </div>
                {[S.RUNNING, S.PAUSED, S.QUEUED].includes(it.state) && <MgmtMeter value={it.size ? it.loaded / it.size : 0} />}
                {it.error && it.state !== S.CANCELLED && <p className={styles.error}>{it.error}</p>}
                {it.note && <p className={styles.note}>{it.note}</p>}
                <div className={styles.acts}>
                  {it.state === S.CONFLICT && <>
                    <MgmtButton size="sm" variant="glass" onClick={() => answer(it.id, KEEP_BOTH)}>Keep both</MgmtButton>
                    <MgmtButton size="sm" variant="glass" onClick={() => answer(it.id, REPLACE)}>Replace</MgmtButton>
                    <MgmtButton size="sm" variant="ghost" onClick={() => answer(it.id, SKIP)}>Skip</MgmtButton>
                  </>}
                  {it.state === S.RUNNING && <button type="button" className={styles.icon} onClick={() => pause(it.id)} aria-label={`Pause ${it.name}`}>Pause</button>}
                  {it.state === S.PAUSED && <button type="button" className={styles.icon} onClick={() => resume(it.id)} aria-label={`Resume ${it.name}`}>Resume</button>}
                  {it.state === S.ERROR && !it.quota && <button type="button" className={styles.icon} onClick={() => retry(it.id)} aria-label={`Retry ${it.name}`}>Retry</button>}
                  {it.state === S.INTERRUPTED && (
                    <button type="button" className={styles.icon} onClick={() => { pickFor.current = it; picker.current.click() }}>Choose the file to resume</button>
                  )}
                </div>
              </li>
            ))}
          </ul>
          <input
            ref={picker}
            type="file"
            hidden
            onChange={(e) => {
              const file = e.target.files?.[0]
              e.target.value = ''
              const it = pickFor.current
              if (file && it) setMismatch(reattach(it.id, file) ? null : `That's not "${it.name}" (${formatBytes(it.size)}). Choose the same file to resume.`)
            }}
          />
        </>
      )}
      <MgmtConfirm
        open={!!stopping}
        title="Cancel this upload?"
        message={stopping && (stopping.loaded > 0
          ? `${stopping.name}: you lose the ${formatBytes(stopping.loaded)} of ${formatBytes(stopping.size)} already sent.`
          : `${stopping.name}: you lose the part already sent.`)}
        confirmLabel="Cancel upload"
        cancelLabel="Keep uploading"
        danger
        onConfirm={() => { cancel(stopping.id); setStopping(null) }}
        onClose={() => setStopping(null)}
      />
    </section>
  )
}

import { MgmtCheckbox } from '../../components/management';