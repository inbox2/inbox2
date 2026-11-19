import { useEffect, useState } from 'react'
import { useNavigate, useOutletContext } from 'react-router'
import Breadcrumbs from '../../components/Breadcrumbs'
import FileTypeIcon, { ActionIcon } from '../../components/FileTypeIcon'
import DropdownMenu from '../../components/DropdownMenu/DropdownMenu'
import ContextMenu from '../../components/DropdownMenu/ContextMenu'
import Skeleton from '../../components/Skeleton'
import { MgmtButton, MgmtConfirm, MgmtSelect } from '../../components/management'
import useContextMenuTrigger from '../../hooks/useContextMenuTrigger'
import useDiskStore from '../../stores/diskStore'
import diskApi from '../../lib/disk/api'
import { companyOptions, drivePath, OPENNESS, pathUrl, shareRoot, SHARE_TEMPLATES, teamDriveLabel } from '../../lib/disk/model'
import { ShareMembersDialog, ShareSettingsDialog } from './DiskDialogs'
import { CreateSealedDialog, SealedShareMembers } from './sealed/SealedUI'
import styles from './SharesOverview.module.css'

/* D:\ — the shares as tiles (spec F3). Same click model as the file list:
 * a click selects, the name or a double click opens. Owners and admins create,
 * delete and restore shares; a share's managers edit and archive it. */
export default function SharesOverview() {
  const { orgId, domains, drives, isAdmin, people } = useOutletContext()
  const navigate = useNavigate()
  const [selected, setSelected] = useState(null)
  const [menu, setMenu] = useState(null)
  const [dialog, setDialog] = useState(null)
  const [error, setError] = useState(null)
  const [trashed, setTrashed] = useState(null)
  const [showTrash, setShowTrash] = useState(false)
  const refresh = () => useDiskStore.getState().invalidate(orgId)

  useEffect(() => {
    if (!showTrash) return undefined
    let live = true
    diskApi.shares(orgId, true).then((d) => { if (live) setTrashed(d.shares) }).catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [orgId, showTrash, drives])

  const shares = drives?.shares || []
  const run = (p) => p.then(() => { setError(null); refresh() }).catch(setError)
  const open = (s) => navigate(pathUrl([shareRoot(s)]), { state: { kind: 'folder', drive: 'D', path: [shareRoot(s)] } })
  const newShare = () => setDialog({ type: 'settings', share: null })
  const I = (name) => <ActionIcon name={name} size={14} />
  const menuFor = (s) => [
    { label: 'Open', icon: I('eye'), shortcut: 'Enter', onSelect: () => open(s) },
    { separator: true },
    { label: 'Members', icon: I('people'), onSelect: () => setDialog({ type: 'members', share: s }) },
    { label: 'Edit share', icon: I('pencil'), onSelect: () => setDialog({ type: 'settings', share: s }) },
    { label: s.archived_at ? 'Unarchive' : 'Archive (read-only)', icon: I('clock'), onSelect: () => run(diskApi.updateShare(orgId, s.id, { archived: !s.archived_at })) },
    ...(isAdmin ? [{ separator: true }, { label: 'Delete share', icon: I('trash'), danger: true, onSelect: () => setDialog({ type: 'delete', share: s }) }] : []),
  ]

  const trigger = useContextMenuTrigger((position, target) => {
    const tile = target.closest?.('[data-index]')
    if (!tile) return
    const s = shares[Number(tile.dataset.index)]
    setSelected(s.id)
    setMenu({ position, items: menuFor(s) })
  })

  const onKeyDown = (e) => {
    trigger.onKeyDown(e)
    if (e.defaultPrevented) return
    const tile = e.target.closest('[data-index]')
    if (!tile) return
    const i = Number(tile.dataset.index)
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key]
    if (step) {
      e.preventDefault()
      const j = Math.max(0, Math.min(shares.length - 1, i + step))
      setSelected(shares[j].id)
      tile.parentElement.querySelector(`[data-index="${j}"]`)?.focus()
    } else if (e.key === 'Enter' && e.target === tile) {
      open(shares[i])
    }
  }

  return (
    <div>
      <Breadcrumbs segments={[{ id: null, label: teamDriveLabel(), drive: 'D' }]} onNavigate={() => navigate(drivePath('D'))} />
      <div className={styles.head}>
        <div>
          <h1 className={styles.title}>Shared disk</h1>
          <p className={styles.sub}>One share per team. Everyone in a share sees everything in it.</p>
        </div>
        {isAdmin && (
          <div className={styles.split}>
            <MgmtButton variant="primary" className={styles.splitMain} onClick={newShare}><ActionIcon name="folder" />New share</MgmtButton>
            <DropdownMenu
              variant="light"
              trigger={<MgmtButton variant="primary" className={styles.splitMore} aria-haspopup="menu" aria-label="More kinds of share"><ActionIcon name="chevronDown" /></MgmtButton>}
              items={[
                { label: 'New share', onSelect: newShare },
                { label: 'New sealed share', onSelect: () => setDialog({ type: 'sealed' }) },
              ]}
            />
          </div>
        )}
      </div>

      {!drives ? (
        <Skeleton variant="tile" count={6} className={styles.tiles} />
      ) : (
        <>
          {isAdmin && !shares.length && <Templates orgId={orgId} domains={domains} onDone={refresh} onCustom={newShare} />}
          {!isAdmin && !shares.length && (
            <p className={styles.empty}>No shares yet. Ask an owner or admin to add you.</p>
          )}
          <div className={styles.tiles} role="listbox" tabIndex={-1} aria-label="Shares" {...trigger} onKeyDown={onKeyDown}>
            {shares.map((s, i) => (
              // eslint-disable-next-line jsx-a11y/click-events-have-key-events -- the listbox onKeyDown handles arrows and Enter for its options
              <div
                key={s.id}
                data-index={i}
                role="option"
                aria-selected={selected === s.id}
                tabIndex={selected === s.id || (!selected && i === 0) ? 0 : -1}
                className={[styles.tile, selected === s.id ? styles.picked : ''].join(' ')}
                onClick={(e) => { if (!e.target.closest('button')) setSelected(s.id) }}
                onDoubleClick={() => open(s)}
              >
                <FileTypeIcon kind="share" emblem={s.icon} color={s.color} size={64} />
                <button type="button" className={styles.name} onClick={() => open(s)}>{s.name}{s.sealed && <span className={styles.lock}>sealed</span>}</button>
                <small className={styles.meta}>
                  {s.member_count} {s.member_count === 1 ? 'member' : 'members'}
                  {s.openness === OPENNESS.ORG && `, open to everyone${s.domain ? ` at ${s.domain.name}` : ''}`}
                  {s.domain && <span className={styles.tag}>{s.domain.name}</span>}
                  {s.archived_at && <span className={styles.tag}>archived</span>}
                </small>
              </div>
            ))}
            {isAdmin && shares.length > 0 && (
              <button type="button" className={`${styles.tile} ${styles.newTile}`} onClick={() => setDialog({ type: 'settings', share: null })}>+ New share</button>
            )}
          </div>
        </>
      )}

      {error && <p className={styles.error} role="alert">{error.message}</p>}

      {isAdmin && (
        <section className={styles.trash}>
          <button type="button" className={styles.trashToggle} aria-expanded={showTrash} onClick={() => setShowTrash((v) => !v)}>
            Deleted shares (kept 30 days)
          </button>
          {showTrash && (trashed === null ? <Skeleton variant="text" count={2} /> : !trashed.length ? (
            <p className={styles.empty}>No deleted shares.</p>
          ) : (
            <ul className={styles.trashList}>
              {trashed.map((s) => (
                <li key={s.id} className={styles.trashRow}>
                  <FileTypeIcon kind="share" emblem={s.icon} color={s.color} size={28} />
                  <span className={styles.trashName}>{s.name}<small>kept until {new Date(s.purge_at).toLocaleDateString()}</small></span>
                  <MgmtButton size="sm" variant="glass" onClick={() => run(diskApi.restoreShare(orgId, s.id))}>Restore</MgmtButton>
                  <MgmtButton size="sm" variant="danger" onClick={() => setDialog({ type: 'purge', share: s })}>Delete forever</MgmtButton>
                </li>
              ))}
            </ul>
          ))}
        </section>
      )}

      <ContextMenu open={!!menu} position={menu?.position} items={menu?.items || []} onClose={() => setMenu(null)} variant="light" />

      {dialog?.type === 'settings' && (
        <ShareSettingsDialog
          orgId={orgId}
          domains={domains}
          share={dialog.share}
          onClose={() => setDialog(null)}
          onSaved={(s) => {
            setDialog(dialog.share ? null : { type: 'members', share: s })
            refresh()
          }}
        />
      )}
      {dialog?.type === 'sealed' && (
        <CreateSealedDialog orgId={orgId} kind="share" onClose={() => setDialog(null)}
          onCreated={({ share }) => { setDialog(null); refresh(); navigate(pathUrl([shareRoot(share)])) }} />
      )}
      {dialog?.type === 'members' && (
        dialog.share.sealed
          ? <SealedShareMembers orgId={orgId} share={dialog.share} people={people} onChanged={refresh} onClose={() => setDialog(null)} />
          : <ShareMembersDialog orgId={orgId} share={dialog.share} people={people} onChanged={refresh} onClose={() => setDialog(null)} />
      )}
      <MgmtConfirm
        open={dialog?.type === 'delete'}
        danger
        title={`Delete ${dialog?.share?.name}?`}
        message="Owners and admins can restore it for 30 days. Its public links stop working now."
        confirmText={dialog?.share?.name}
        confirmLabel="Delete share"
        onConfirm={() => { const s = dialog.share; setDialog(null); run(diskApi.deleteShare(orgId, s.id, s.name)) }}
        onClose={() => setDialog(null)}
      />
      <MgmtConfirm
        open={dialog?.type === 'purge'}
        danger
        title={`Delete ${dialog?.share?.name} forever?`}
        message="You lose everything in it."
        confirmLabel="Delete forever"
        onConfirm={() => { const s = dialog.share; setDialog(null); run(diskApi.purgeShare(orgId, s.id)).then(() => setTrashed(null)) }}
        onClose={() => setDialog(null)}
      />
    </div>
  )
}

/* First run (spec F3): D:\ is empty, so say what a share is and offer the
   team shares as tiles to switch on, or a share of your own. */
function Templates({ orgId, domains, onDone, onCustom }) {
  const [picked, setPicked] = useState(() => new Set())
  const [domainId, setDomainId] = useState('')
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)
  const toggle = (name) => {
    const next = new Set(picked)
    if (next.has(name)) next.delete(name)
    else next.add(name)
    setPicked(next)
  }
  const create = () => {
    setBusy(true)
    diskApi.shareTemplates(orgId, [...picked], domainId).then(onDone).catch((e) => { setError(e); setBusy(false) })
  }
  return (
    <section className={styles.templates} aria-labelledby="disk-templates">
      <FileTypeIcon kind="share" emblem="shared" size={72} />
      <h2 id="disk-templates" className={styles.templatesTitle}>No shares yet. Set up the first ones.</h2>
      <p className={styles.sub}>Pick your teams. You add the people next.</p>
      <div className={styles.templateGrid}>
        {SHARE_TEMPLATES.map((t) => (
          <button key={t.name} type="button" className={styles.template} aria-pressed={picked.has(t.name)} onClick={() => toggle(t.name)}>
            <FileTypeIcon kind="share" emblem={t.icon} size={48} />
            {t.name}
            <span className={styles.tick} aria-hidden="true"><ActionIcon name="check" size={12} /></span>
          </button>
        ))}
      </div>
      {error && <p className={styles.error} role="alert">{error.message}</p>}
      <div className={styles.templateActions}>
        {domains.length > 1 && (
          <MgmtSelect bare compact aria-label="Company" value={domainId} onChange={(e) => setDomainId(e.target.value)} options={companyOptions(domains)} />
        )}
        <MgmtButton variant="primary" disabled={!picked.size || busy} onClick={create}>
          {picked.size ? `Create ${picked.size} ${picked.size === 1 ? 'share' : 'shares'}` : 'Create shares'}
        </MgmtButton>
        <MgmtButton variant="glass" onClick={onCustom}>Name my own share</MgmtButton>
      </div>
    </section>
  )
}
