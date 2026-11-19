import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { MgmtButton, MgmtField, MgmtModal, MgmtSelect } from '../../components/management'
import DateField from '../../components/DateField/DateField'
import FileTypeIcon from '../../components/FileTypeIcon'
import Skeleton from '../../components/Skeleton'
import { SHARE_COLORS } from '../../components/FileTypeIcon/glyphs'
import diskApi from '../../lib/disk/api'
import { companyOptions, OPENNESS, openTo, ROLE, ROLE_LABEL, ROLES, SHARE_ICONS, SHARE_ORG_ROLES, teamDriveLabel } from '../../lib/disk/model'
import styles from './DiskDialogs.module.css'

const roleOptions = (roles) => roles.map((r) => ({ value: r, label: ROLE_LABEL[r] }))

function ErrorLine({ error }) {
  return error ? <p className={styles.error} role="alert">{error.message || String(error)}</p> : null
}

/* Pick a destination folder: drives first, then down through folders. */
export function MoveDialog({ orgId, drives, movingIds, verb = 'Move', pickFiles = false, onPick, onClose }) {
  const [trail, setTrail] = useState([])
  const [folders, setFolders] = useState(null)
  const [error, setError] = useState(null)
  const here = trail.at(-1)

  useEffect(() => {
    if (!here) return undefined
    let live = true
    diskApi.children(orgId, here.id, { ...(pickFiles ? {} : { type: 'folders' }), sort: 'name', dir: 'asc' })
      .then((d) => { if (live) setFolders(d.nodes) })
      .catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [orgId, here, pickFiles])

  const go = (next) => { setFolders(null); setError(null); setTrail(next) }
  const roots = [
    { id: drives.c_drive.id, label: 'C:\\', sub: 'My disk' },
    ...drives.shares.filter((s) => !s.archived_at).map((s) => ({ id: s.root_node_id, label: s.name, sub: teamDriveLabel(), share: s })),
  ]
  const blocked = !here || movingIds.includes(here.id)
  const list = here ? (folders || []).filter((f) => !f.sealed && !movingIds.includes(f.id) && (f.kind === 'folder' || (pickFiles && f.kind === 'file'))) : roots

  return (
    <MgmtModal open onClose={onClose} width={520}>
      <h2 className={styles.title}>{pickFiles ? `${verb} a file` : `${verb} to...`}</h2>
      <nav className={styles.trail} aria-label="Destination">
        <button type="button" className={styles.trailBtn} onClick={() => go([])}>Drives</button>
        {trail.map((t, i) => (
          <span key={t.id}>\<button type="button" className={styles.trailBtn} onClick={() => go(trail.slice(0, i + 1))}>{t.label}</button></span>
        ))}
      </nav>
      <div className={styles.pickList} role="group" aria-label={here ? `Folders in ${here.label}` : 'Drives'}>
        {here && !folders && !error && <Skeleton variant="text" count={4} />}
        {here && folders && !list.length && <p className={styles.muted}>No folders in here.</p>}
        {list.map((f) => (
          <button
            key={f.id}
            type="button"
            className={styles.pickRow}
            onClick={() => (f.kind === 'file' ? onPick(here.id, f, trail[0]?.root) : go([...trail, { id: f.id, label: f.label || f.name, root: trail[0]?.root || { drive: f.share ? 'D' : f.sub ? 'C' : null, shareId: f.share?.id || null } }]))}
          >
            {f.share
              ? <FileTypeIcon kind="share" emblem={f.share.icon} color={f.share.color} size={24} />
              : f.sub ? <FileTypeIcon kind="drive" drive="C" size={22} />
                : f.kind === 'file' ? <FileTypeIcon name={f.name} mime={f.mime} size={24} /> : <FileTypeIcon kind="folder" size={24} />}
            <span>{f.label || f.name}</span>
            {f.sub && <small className={styles.muted}>{f.sub}</small>}
          </button>
        ))}
      </div>
      <ErrorLine error={error} />
      <div className={styles.actions}>
        <MgmtButton variant="glass" onClick={onClose}>Cancel</MgmtButton>
        {!pickFiles && <MgmtButton variant="primary" disabled={blocked} onClick={() => onPick(here.id, null, here.root)}>{verb} here</MgmtButton>}
      </div>
    </MgmtModal>
  )
}

/* People with their own access to a node (grants), and how to add one. */
export function PeopleDialog({ orgId, node, share, people, onClose }) {
  const [grants, setGrants] = useState(null)
  const [members, setMembers] = useState([])
  const [error, setError] = useState(null)
  const [who, setWho] = useState('')
  const [role, setRole] = useState(ROLE.VIEW)
  const [rev, setRev] = useState(0)

  useEffect(() => {
    let live = true
    diskApi.grants(orgId, node.id)
      .then((d) => { if (live) setGrants(d.grants) })
      .catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [orgId, node.id, rev])
  useEffect(() => {
    if (!share) return undefined
    let live = true
    diskApi.shareMembers(orgId, share.id).then((d) => { if (live) setMembers(d.members) }).catch(() => {})
    return () => { live = false }
  }, [orgId, share])
  const viaShare = new Map(members.map((m) => [m.membership_id, m.role]))

  const run = (p) => p.then(() => { setError(null); setRev((r) => r + 1) }).catch(setError)
  const granted = new Set((grants || []).map((g) => g.membership.id))
  const candidates = people.filter((p) => !granted.has(p.id))

  return (
    <MgmtModal open onClose={onClose} width={520}>
      <h2 className={styles.title}>Share "{node.name}"</h2>
      <p className={styles.muted}>
        {share
          ? `Everyone with access to ${share.name} can open it.`
          : 'Only you and the people you add can open it.'}
      </p>
      <div className={styles.addRow}>
        <MgmtSelect bare compact aria-label="Person" value={who} onChange={(e) => setWho(e.target.value)}
          options={[{ value: '', label: 'Add a person...' }, ...candidates.map((p) => ({ value: p.id, label: p.name }))]} />
        <MgmtSelect bare compact aria-label="Role" value={role} onChange={(e) => setRole(e.target.value)} options={roleOptions([ROLE.VIEW, ROLE.EDIT])} />
        <MgmtButton size="sm" disabled={!who} onClick={() => { run(diskApi.setGrant(orgId, node.id, who, role)); setWho('') }}>Add</MgmtButton>
      </div>
      <ul className={styles.people}>
        {grants === null && !error && <li><Skeleton variant="text" count={3} /></li>}
        {grants?.length === 0 && <li className={styles.muted}>You haven&apos;t added anyone yet.</li>}
        {grants?.map((g) => (
          <li key={g.membership.id} className={styles.person}>
            <span>{g.membership.name}</span>
            <MgmtSelect bare compact aria-label={`Role for ${g.membership.name}`} value={g.role}
              onChange={(e) => run(diskApi.setGrant(orgId, node.id, g.membership.id, e.target.value))}
              options={roleOptions([ROLE.VIEW, ROLE.EDIT])} />
            <MgmtButton
              size="sm"
              variant="ghost"
              disabled={viaShare.has(g.membership.id)}
              title={viaShare.has(g.membership.id) ? `Also a member of ${share.name} (${ROLE_LABEL[viaShare.get(g.membership.id)].toLowerCase()}): removing this keeps that access` : undefined}
              onClick={() => run(diskApi.removeGrant(orgId, node.id, g.membership.id))}
            >
              Remove
            </MgmtButton>
          </li>
        ))}
      </ul>
      {share && members.length > 0 && (
        <>
          <h3 className={styles.sub}>Through the share {share.name}</h3>
          <ul className={styles.people}>
            {members.map((m) => (
              <li key={m.membership_id} className={styles.person}><span>{m.name}</span><span className={styles.muted}>{ROLE_LABEL[m.role]}</span></li>
            ))}
          </ul>
        </>
      )}
      <ErrorLine error={error} />
      <div className={styles.actions}><MgmtButton variant="primary" onClick={onClose}>Done</MgmtButton></div>
    </MgmtModal>
  )
}

/* Create a share, or change its name, emblem, colour, company and who it is open to.
 * The company picker shows once the org has more than one domain (or the share has one). */
export function ShareSettingsDialog({ orgId, share, domains = [], onSaved, onClose }) {
  const [name, setName] = useState(share?.name || '')
  const [icon, setIcon] = useState(share?.icon ?? null)
  const [color, setColor] = useState(share?.color || SHARE_COLORS.blue)
  const [openness, setOpenness] = useState(share?.openness || OPENNESS.ASSIGNED)
  const [orgRole, setOrgRole] = useState(share?.org_role || ROLE.VIEW)
  const [domainId, setDomainId] = useState(share?.domain?.id || '')
  // Icon and colour each show as they are, with Change to open their choices ('icon' | 'color').
  // A mouse pick closes them; arrow keys move through them, so the link reads Done while open.
  const [picking, setPicking] = useState(null)
  const byPointer = useRef(false)
  const pickedBy = { onPointerDown: () => { byPointer.current = true }, onKeyDown: () => { byPointer.current = false } }
  const picked = () => { if (byPointer.current) setPicking(null) }
  const toggle = (what) => (
    <button type="button" className={styles.change} aria-expanded={picking === what} onClick={() => setPicking(picking === what ? null : what)}>
      {picking === what ? 'Done' : 'Change'}
    </button>
  )
  const picksCompany = domains.length > 1 || !!share?.domain
  const domain = domains.find((d) => d.id === domainId)
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)

  const save = async () => {
    if (!name.trim() || busy) return
    setBusy(true)
    const attrs = { name: name.trim(), icon, color, openness, org_role: orgRole, ...(picksCompany && { domain_id: domainId || null }) }
    try {
      const res = share ? await diskApi.updateShare(orgId, share.id, attrs) : await diskApi.createShare(orgId, attrs)
      onSaved(res.share)
    } catch (e) {
      setError(e)
      setBusy(false)
    }
  }

  return (
    <MgmtModal open onClose={onClose} onSubmit={save} width={560}>
      <h2 className={styles.title}>{share ? 'Edit share' : 'New share'}</h2>
      <MgmtField label="Name" value={name} onChange={(e) => setName(e.target.value)} maxLength={120} required />
      <fieldset className={styles.fieldset}>
        <legend className={styles.legend}>Icon</legend>
        <div className={styles.iconNow}>
          <FileTypeIcon kind="share" emblem={icon} color={color} size={44} />
          {toggle('icon')}
        </div>
        {picking === 'icon' && (
          <div className={styles.swatches} {...pickedBy}>
            {[null, ...SHARE_ICONS].map((i) => (
              <label key={i || 'none'} className={styles.swatch} title={i || 'No icon'}>
                <input type="radio" name="share-icon" value={i || ''} checked={icon === i} onChange={() => { setIcon(i); picked() }} className={styles.radio} aria-label={i || 'No icon'} />
                <FileTypeIcon kind="share" emblem={i} color={color} size={36} />
              </label>
            ))}
          </div>
        )}
      </fieldset>
      <fieldset className={styles.fieldset}>
        <legend className={styles.legend}>Colour</legend>
        <div className={styles.iconNow}>
          <FileTypeIcon kind="share" color={color} size={30} />
          {toggle('color')}
        </div>
        {picking === 'color' && (
          <div className={styles.swatches} {...pickedBy}>
            {Object.entries(SHARE_COLORS).map(([key, hex]) => (
              <label key={key} className={styles.swatch} title={key}>
                <input type="radio" name="share-color" value={hex} checked={color === hex} onChange={() => { setColor(hex); picked() }} className={styles.radio} aria-label={key} />
                <FileTypeIcon kind="share" color={hex} size={30} />
              </label>
            ))}
          </div>
        )}
      </fieldset>
      {picksCompany && (
        <fieldset className={styles.fieldset}>
          <legend className={styles.legend}>Company</legend>
          <MgmtSelect bare compact aria-label="Company" value={domainId} onChange={(e) => setDomainId(e.target.value)} options={companyOptions(domains)} />
        </fieldset>
      )}
      <fieldset className={styles.fieldset}>
        <legend className={styles.legend}>Who can open it</legend>
        <label className={styles.choice}>
          <input type="radio" name="share-open" checked={openness === OPENNESS.ASSIGNED} onChange={() => setOpenness(OPENNESS.ASSIGNED)} />
          Only the members I add
        </label>
        <label className={styles.choice}>
          <input type="radio" name="share-open" checked={openness === OPENNESS.ORG} onChange={() => setOpenness(OPENNESS.ORG)} />
          {openTo(domain && { domain })}
          {openness === OPENNESS.ORG && (
            <MgmtSelect bare compact aria-label="Everyone's role" value={orgRole} onChange={(e) => setOrgRole(e.target.value)} options={roleOptions(SHARE_ORG_ROLES)} />
          )}
        </label>
      </fieldset>
      <ErrorLine error={error} />
      <div className={styles.actions}>
        <MgmtButton variant="glass" onClick={onClose}>Cancel</MgmtButton>
        <MgmtButton variant="primary" disabled={!name.trim() || busy} onClick={save}>{share ? 'Save' : 'Create share'}</MgmtButton>
      </div>
    </MgmtModal>
  )
}

/* A share's members and their roles. Managers change them; the API refuses everyone else. */
export function ShareMembersDialog({ orgId, share, people, onChanged, onClose }) {
  const [members, setMembers] = useState(null)
  const [error, setError] = useState(null)
  const [who, setWho] = useState('')
  const [role, setRole] = useState(ROLE.EDIT)
  const [rev, setRev] = useState(0)

  useEffect(() => {
    let live = true
    diskApi.shareMembers(orgId, share.id)
      .then((d) => { if (live) setMembers(d.members) })
      .catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [orgId, share.id, rev])

  const run = (p) => p.then(() => { setError(null); setRev((r) => r + 1); onChanged?.() }).catch(setError)
  const inShare = new Set((members || []).map((m) => m.membership_id))
  const candidates = people.filter((p) => !inShare.has(p.id))

  return (
    <MgmtModal open onClose={onClose} width={540}>
      <h2 className={styles.title}>Members of {share.name}</h2>
      {share.openness === OPENNESS.ORG && (
        <p className={styles.muted}>Open to {openTo(share).replace(/^Everyone/, 'everyone')} ({ROLE_LABEL[share.org_role].toLowerCase()}). Add members to give them more.</p>
      )}
      <div className={styles.addRow}>
        <MgmtSelect bare compact aria-label="Person" value={who} onChange={(e) => setWho(e.target.value)}
          options={[{ value: '', label: 'Add a member...' }, ...candidates.map((p) => ({ value: p.id, label: p.name }))]} />
        <MgmtSelect bare compact aria-label="Role" value={role} onChange={(e) => setRole(e.target.value)} options={roleOptions(ROLES)} />
        <MgmtButton size="sm" disabled={!who} onClick={() => { run(diskApi.setShareMember(orgId, share.id, who, role)); setWho('') }}>Add</MgmtButton>
      </div>
      <ul className={styles.people}>
        {members === null && !error && <li><Skeleton variant="text" count={3} /></li>}
        {members?.length === 0 && <li className={styles.muted}>No members yet.</li>}
        {members?.map((m) => (
          <li key={m.membership_id} className={styles.person}>
            <span>{m.name}</span>
            <MgmtSelect bare compact aria-label={`Role for ${m.name}`} value={m.role}
              onChange={(e) => run(diskApi.setShareMember(orgId, share.id, m.membership_id, e.target.value))} options={roleOptions(ROLES)} />
            <MgmtButton size="sm" variant="ghost" onClick={() => run(diskApi.removeShareMember(orgId, share.id, m.membership_id))}>Remove</MgmtButton>
          </li>
        ))}
      </ul>
      <ErrorLine error={error} />
      <div className={styles.actions}><MgmtButton variant="primary" onClick={onClose}>Done</MgmtButton></div>
    </MgmtModal>
  )
}

/* Share several items with one person: one grant call per item (the API has no bulk grant). */
export function BulkShareDialog({ orgId, nodes, people, onClose }) {
  const [who, setWho] = useState('')
  const [role, setRole] = useState(ROLE.VIEW)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const shareable = nodes.filter((n) => !n.sealed)
  const go = async () => {
    setBusy(true)
    const out = await Promise.allSettled(shareable.map((n) => diskApi.setGrant(orgId, n.id, who, role)))
    const failed = out.map((r, i) => (r.status === 'rejected' ? `${shareable[i].name}: ${r.reason?.message}` : null)).filter(Boolean)
    setResult({ ok: out.length - failed.length, failed })
    setBusy(false)
  }
  return (
    <MgmtModal open onClose={onClose} width={520}>
      <h2 className={styles.title}>Share {shareable.length} {shareable.length === 1 ? 'item' : 'items'}</h2>
      {nodes.length > shareable.length && <p className={styles.muted}>Sealed items are left out. Add key holders to share those.</p>}
      <div className={styles.addRow}>
        <MgmtSelect bare compact aria-label="Person" value={who} onChange={(e) => setWho(e.target.value)}
          options={[{ value: '', label: 'Choose a person...' }, ...people.map((p) => ({ value: p.id, label: p.name }))]} />
        <MgmtSelect bare compact aria-label="Role" value={role} onChange={(e) => setRole(e.target.value)} options={roleOptions([ROLE.VIEW, ROLE.EDIT])} />
      </div>
      {result && (
        <p className={result.failed.length ? styles.error : styles.muted} role="status">
          Shared {result.ok} of {shareable.length}.{result.failed.length ? ` Not shared: ${result.failed.join('; ')}` : ''}
        </p>
      )}
      <div className={styles.actions}>
        <MgmtButton variant="glass" onClick={onClose}>{result ? 'Done' : 'Cancel'}</MgmtButton>
        {!result && <MgmtButton variant="primary" disabled={!who || busy || !shareable.length} onClick={go}>Share</MgmtButton>}
      </div>
    </MgmtModal>
  )
}

/* Public links (spec F4): who has a link, and a new one with an optional
   password, expiry and hidden download. The address shows once, at creation. */
export function LinkDialog({ orgId, node, onClose }) {
  const [links, setLinks] = useState(null)
  const [error, setError] = useState(null)
  const [password, setPassword] = useState('')
  const [expires, setExpires] = useState('')
  const [hide, setHide] = useState(false)
  const [created, setCreated] = useState(null)
  const [copied, setCopied] = useState(false)
  const [rev, setRev] = useState(0)
  useEffect(() => {
    let live = true
    diskApi.links(orgId, node.id).then((d) => { if (live) setLinks(d.links) }).catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [orgId, node.id, rev])
  const create = async () => {
    try {
      const attrs = { hide_download: hide }
      if (password) attrs.password = password
      if (expires) attrs.expires_at = new Date(`${expires}T23:59:59`).toISOString()
      const { link } = await diskApi.createLink(orgId, node.id, attrs)
      setCreated(link)
      setPassword('')
      setError(null)
      setRev((r) => r + 1)
    } catch (e) {
      setError(e)
    }
  }
  const linkUrl = created?.url // absolute, made by the API (WEB_APP_URL/share/<name-slug>/<token>)
  const copy = () => navigator.clipboard?.writeText(linkUrl).then(() => setCopied(true))
  const today = new Date().toISOString().slice(0, 10)
  return (
    <MgmtModal open onClose={onClose} width={560}>
      <h2 className={styles.title}>Public link to "{node.name}"</h2>
      <p className={styles.muted}>Anyone with the link can open it.</p>
      {created && (
        <div className={styles.created} role="status">
          <p><b>Copy the link now.</b> You can&apos;t see it again.</p>
          <div className={styles.addRow}>
            <input className={styles.linkField} readOnly value={linkUrl} aria-label="New link" onFocus={(e) => e.target.select()} />
            <MgmtButton size="sm" variant="primary" onClick={copy}>{copied ? 'Copied' : 'Copy'}</MgmtButton>
          </div>
        </div>
      )}
      <fieldset className={styles.fieldset}>
        <legend className={styles.legend}>New link</legend>
        {/* Most links need none of these: folded away, with what is set shown on the summary. */}
        <details className={styles.more}>
          <summary className={styles.moreSummary}>
            Password, expiry, download
            {(password || expires || hide) && <span className={styles.muted}> · {[password && 'password', expires && `until ${new Date(`${expires}T00:00`).toLocaleDateString()}`, hide && 'no download button'].filter(Boolean).join(', ')}</span>}
          </summary>
          <MgmtField label="Password (optional)" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" maxLength={72} />
          <label className={styles.choice}>
            Expires (optional)
            <DateField value={expires} onChange={setExpires} min={today} aria-label="Expiry date" placeholder="Never" className={styles.dateField} />
          </label>
          <label className={styles.choice}>
            <MgmtCheckbox  checked={hide} onChange={(e) => setHide(e.target.checked)} />
            Hide the Download button
          </label>
        </details>
        <MgmtButton size="sm" variant="primary" onClick={create}>Create link</MgmtButton>
      </fieldset>
      <h3 className={styles.sub}>Links</h3>
      <ul className={styles.people}>
        {links === null && !error && <li><Skeleton variant="text" count={2} /></li>}
        {links?.length === 0 && <li className={styles.muted}>No links yet.</li>}
        {links?.map((l) => (
          <li key={l.id} className={styles.person}>
            <span>
              {l.expired ? 'Expired' : l.expires_at ? `Until ${new Date(l.expires_at).toLocaleDateString()}` : 'No expiry'}
              {l.has_password ? ', password' : ''}{l.hide_download ? ', no download button' : ''}
              <small className={styles.small}>Made {new Date(l.created_at).toLocaleDateString()} by {l.created_by?.name}{l.last_used_at ? `, last opened ${new Date(l.last_used_at).toLocaleDateString()}` : ', not opened yet'}</small>
            </span>
            <MgmtButton size="sm" variant="ghost" onClick={() => diskApi.revokeLink(orgId, l.id).then(() => setRev((r) => r + 1)).catch(setError)}>Revoke</MgmtButton>
          </li>
        ))}
      </ul>
      <ErrorLine error={error} />
      <div className={styles.actions}><MgmtButton variant="primary" onClick={onClose}>Done</MgmtButton></div>
    </MgmtModal>
  )
}

/* A name clash (409): keep both, replace (a copied file becomes a new version of the one there), or leave it. */
export function ConflictDialog({ message, onKeep, onReplace, onCancel }) {
  return (
    <MgmtModal open onClose={onCancel} width={460}>
      <h2 className={styles.title}>That name is taken</h2>
      <p className={styles.muted}>{message} Keep both adds a number, like "Report (1)".{onReplace ? ' Replace makes it a new version.' : ''}</p>
      <div className={styles.actions}>
        <MgmtButton variant="glass" onClick={onCancel}>Cancel</MgmtButton>
        {onReplace && <MgmtButton variant="glass" onClick={onReplace}>Replace</MgmtButton>}
        <MgmtButton variant="primary" onClick={onKeep}>Keep both</MgmtButton>
      </div>
    </MgmtModal>
  )
}

/** MoveDialog for callers outside Disk (mail): loads the drives itself. */
export function DiskPicker({ orgId, ...props }) {
  const [drives, setDrives] = useState(null)
  const [error, setError] = useState(null)
  useEffect(() => { diskApi.drives(orgId).then(setDrives).catch(setError) }, [orgId])
  // Mail's own key handlers stop Escape before MgmtModal's window listener sees it: take it first.
  const { onClose } = props
  useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose() } }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [onClose])
  if (error) {
    return (
      <MgmtModal open onClose={props.onClose} width={420}>
        <p className={styles.muted} role="alert">{error.status === 403 ? "Your plan doesn't include Disk." : error.message}</p>
        <MgmtButton onClick={props.onClose}>Close</MgmtButton>
      </MgmtModal>
    )
  }
  if (!drives) return null
  // Mail renders this inside its own panes: portal it above them.
  return createPortal(<MoveDialog orgId={orgId} drives={drives} movingIds={[]} {...props} />, document.body)
}

import { MgmtCheckbox } from '../../components/management';