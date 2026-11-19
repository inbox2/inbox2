import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { MgmtButton, MgmtField, MgmtModal, MgmtSelect } from '../../../components/management'
import DateField from '../../../components/DateField/DateField'
import Icon from '../../../components/Icon'
import RecoverKeyModal from '../../../components/E2eeUnlock/RecoverKeyModal'
import { RecoveryGate } from '../../admin/E2eePanel'
import api from '../../../lib/api'
import diskApi, { SEAL } from '../../../lib/disk/api'
import { identityKeys, refreshIdentity, setupIdentity, unlock, useE2ee } from '../../../lib/e2eeStore'
import { ROLE, ROLE_LABEL } from '../../../lib/disk/model'
import { DISK_SEAL_ACK } from '../../../lib/storageKeys'
import useSealedStore from '../../../stores/sealedStore'
import useAuth from '../../../hooks/useAuth'
import styles from './Sealed.module.css'

const sealedLib = () => import('../../../lib/disk/sealed')

// Password AutoFill (Apple Passwords, browsers) picks the saved login by its
// username, so the password field rides with one: hidden, not display:none, which AutoFill skips.
function AccountName() {
  const { user } = useAuth()
  return <input className={styles.account} type="text" name="username" autoComplete="username" value={user?.username || ''} readOnly tabIndex={-1} aria-hidden="true" />
}

/** Unlock with the account password (the identity key, spec F7 "a locked identity key prompts for unlock"). */
export function UnlockForm({ onDone }) {
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [recovering, setRecovering] = useState(false)
  const submit = async (e) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await unlock(password)
      setPassword('')
      onDone?.()
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(false)
    }
  }
  return (
    <form className={styles.unlock} onSubmit={submit}>
      <AccountName />
      <MgmtField label="Your inbox2 password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <MgmtButton type="submit" size="sm" variant="primary" disabled={!password || busy}>Unlock</MgmtButton>
      {error && <p className={styles.error} role="alert">{error}</p>}
      <button type="button" className={styles.link} onClick={() => setRecovering(true)}>Password doesn&apos;t work? Use your recovery phrase</button>
      {recovering && <RecoverKeyModal onClose={() => setRecovering(false)} />}
    </form>
  )
}

/** Opening a sealed item with the key locked (or not made yet) asks for it in place. */
// The mode is fixed at open: creating a key flips identityStatus to unlocked, and the
// one-time recovery phrase must stay on screen until it is confirmed.
export function UnlockDialog({ onClose, onUnlocked }) {
  const { identityStatus } = useE2ee()
  const [setup] = useState(identityStatus === 'none')
  return (
    <MgmtModal open onClose={onClose}>
      <h2 className={styles.title}><Icon name="lock.fill" size={18} className={styles.titleIcon} />{setup ? 'Create your encryption key' : 'Unlock your key'}</h2>
      <p className={styles.muted}>Your browser encrypts sealed items. inbox2 can&apos;t read them.</p>
      {setup ? <SetupKeyForm onDone={onUnlocked} /> : <UnlockForm onDone={onUnlocked} />}
    </MgmtModal>
  )
}

/**
 * Create the encryption key right here (it is the person's own, one per account, not a domain
 * setting): the account password protects it, then the recovery phrase is shown once.
 */
export function SetupKeyForm({ onDone }) {
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [phrase, setPhrase] = useState(null)
  const submit = async (e) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const { passphrase } = await setupIdentity(password)
      setPassword('')
      setPhrase(passphrase)
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(false)
    }
  }
  return (
    <form className={styles.unlock} onSubmit={submit}>
      <AccountName />
      <MgmtField label="Your inbox2 password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <MgmtButton type="submit" size="sm" variant="primary" disabled={!password || busy}>Create my key</MgmtButton>
      {error && <p className={styles.error} role="alert">{error}</p>}
      {phrase && createPortal(<RecoveryGate passphrase={phrase} onDone={() => { setPhrase(null); onDone?.() }} />, document.body)}
    </form>
  )
}

/** What sealing does, as a picture: the file is locked in the browser, before upload. */
function SealDiagram({ shared }) {
  return (
    <figure className={styles.diagram}>
      <div className={styles.stage}><Icon name="doc" size={22} /><b>1. Your file</b><span>You add it to the folder.</span></div>
      <Icon name="chevron.right" size={14} />
      <div className={`${styles.stage} ${styles.stageKey}`}><Icon name="lock.fill" size={22} /><b>2. This browser locks it</b><span>{shared ? 'Only members have the key.' : 'Only you have the key.'}</span></div>
      <Icon name="chevron.right" size={14} />
      <div className={styles.stage}><Icon name="externaldrive" size={22} /><b>3. inbox2 keeps it</b><span>Locked. inbox2 can&apos;t read it.</span></div>
    </figure>
  )
}

/**
 * What a sealed location needs from the person before it lists: unlock, an
 * identity key, a key at all (an admin who is not a member sees the top only),
 * and the rotation a departed holder left due.
 */
export function SealedBanner({ entry, isManager, onRotate, shareName }) {
  const { identityStatus } = useE2ee()
  if (!entry) return null
  if (identityStatus === 'none' || (entry.status === 'locked' && identityStatus === 'none')) {
    return <div className={styles.banner} role="status"><b>Sealed.</b> You need an encryption key to open sealed files. Create yours here, then ask a key holder to add you.<SetupKeyForm /></div>
  }
  if (entry.status === 'locked') {
    return (
      <div className={styles.banner} role="status">
        <b>Sealed.</b> Unlock your key to see names and open files here.
        <UnlockForm />
      </div>
    )
  }
  if (entry.status === 'nokey') {
    return (
      <div className={styles.banner} role="status">
        <b>Sealed{shareName ? `: ${shareName}` : ''}.</b> You can manage this share, but you don&apos;t hold its key. Only its members can open it.
      </div>
    )
  }
  if (entry.status === 'error') return <div className={styles.banner} role="alert"><b>Sealed.</b> The key didn&apos;t open: {entry.error?.message}</div>
  if (entry.status === 'open' && entry.scope.rotationDue) {
    return (
      <div className={`${styles.banner} ${styles.warn}`} role="status">
        <b>A key holder left.</b> They still have the old key, so no one can add or change files with it.
        {isManager ? <MgmtButton size="sm" variant="primary" onClick={onRotate}>Renew the key</MgmtButton> : ' Ask a manager of this folder to renew the key.'}
      </div>
    )
  }
  return null
}

/** The first-use warning, kept per browser once acknowledged. */
const acknowledged = () => { try { return localStorage.getItem(DISK_SEAL_ACK) === '1' } catch { return false } }

/**
 * New sealed share or sealed folder on C:\ (spec F7 first box). Entitled orgs
 * only; the lost-keys warning must be acknowledged before the first one.
 */
// convert: an unsealed folder on C:\ being sealed (Seal on its menu): the new sealed folder takes its
// name, beside it (cRootId is its parent), and the caller moves its contents in (6.8).
export function CreateSealedDialog({ orgId, cRootId, kind = 'share', convert = null, onCreated, onClose }) {
  const { identityStatus } = useE2ee()
  const [entitled, setEntitled] = useState(null)
  const [ack, setAck] = useState(acknowledged)
  const [name, setName] = useState(convert?.name || '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  useEffect(() => { api.getBilling(orgId).then((b) => setEntitled(!!b.plan?.e2ee)).catch(() => setEntitled(false)) }, [orgId])
  // Nothing may have asked yet whether this account has a key (a fresh page): ask, or the dialog stays empty.
  useEffect(() => { if (identityStatus === 'unknown') refreshIdentity() }, [identityStatus])

  const create = async () => {
    setBusy(true)
    setError(null)
    try {
      try { localStorage.setItem(DISK_SEAL_ACK, '1') } catch { /* storage blocked: ask again next time */ }
      const lib = await sealedLib()
      const identity = identityKeys()
      const res = kind === 'share'
        ? await lib.createSealedShare({ orgId, name: name.trim(), identity })
        : await lib.createSealedRoot({ orgId, parentId: cRootId, name: name.trim(), identity })
      onCreated(res)
    } catch (e) {
      setError(e)
      setBusy(false)
    }
  }
  const what = kind === 'share' ? 'sealed share' : 'sealed folder'
  return (
    <MgmtModal open onClose={onClose} width={520}>
      <h2 className={styles.title}><Icon name="lock.fill" size={18} className={styles.titleIcon} />{convert ? `Seal "${convert.name}"?` : `New ${what}`}</h2>
      {(entitled === null || (entitled && identityStatus === 'unknown')) && <p className={styles.muted}>Checking your encryption key...</p>}
      {entitled === false && <p className={styles.muted}>This organization&apos;s plan doesn&apos;t include sealing.</p>}
      {entitled && identityStatus === 'none' && (
        <>
          <p className={styles.step}><b>Step 1 of 2: Create your encryption key.</b> Your password opens it. We show a recovery phrase once, in case you forget the password.</p>
          <SetupKeyForm />
        </>
      )}
      {entitled && !convert && (identityStatus === 'locked' || identityStatus === 'unlocked') && (
        <>
          <SealDiagram shared={kind === 'share'} />
          <p className={styles.muted}>
            {kind === 'share'
              ? "Only members can open the files. Owners and admins who aren't members can manage the share but can't open the files."
              : 'Only you and the people you add can open the files.'}
          </p>
        </>
      )}
      {entitled && <SealingLimits />}
      {entitled && identityStatus === 'locked' && (
        <>
          <p className={styles.step}><b>Step 1 of 2: Open your encryption key.</b> It stays open until you close this tab. Next, name the {what}.</p>
          <UnlockForm />
        </>
      )}
      {entitled && identityStatus === 'unlocked' && (
        <>
          {convert && (
            <p className={styles.muted}>
              This browser encrypts each file into a sealed folder of the same name. Then it deletes the originals for good.
            </p>
          )}
          {convert && (
            <ul className={styles.list}>
              <li><span>Older versions don&apos;t carry over.</span></li>
              <li><span>Public links stop working. People with access lose it until you add them as key holders.</span></li>
            </ul>
          )}
          {!convert && <MgmtField label="Name" value={name} onChange={(e) => setName(e.target.value)} autoFocus />}
          {kind === 'share' && <p className={styles.small}>Owners and admins can see this name. Names inside the share are encrypted.</p>}
          {!acknowledged() && (
            <label className={styles.ack}>
              <MgmtCheckbox  checked={ack} onChange={(e) => setAck(e.target.checked)} />
              <span>If I lose my password and recovery phrase and nobody else holds the key, I lose these files.</span>
            </label>
          )}
          {error && <p className={styles.error} role="alert">{error.message}</p>}
          <div className={styles.actions}>
            <MgmtButton variant="glass" onClick={onClose}>Cancel</MgmtButton>
            <MgmtButton variant="primary" disabled={!name.trim() || !ack || busy} onClick={create}>{convert ? 'Seal folder' : `Create ${what}`}</MgmtButton>
          </div>
        </>
      )}
    </MgmtModal>
  )
}

/**
 * Key holders of a sealed scope (6.7): add with a sealed key grant, remove
 * through rotation (the dialog lists the scope's file links with Revoke and
 * says earlier files stay readable), and renew the key when one is due.
 */
export function SealedMembersDialog({ orgId, scope, share, people, isManager, onClose, onChanged }) {
  const [who, setWho] = useState('')
  const [role, setRole] = useState(ROLE.VIEW)
  const [removing, setRemoving] = useState(null) // holder, or 'renew'
  const [links, setLinks] = useState(scope.links)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const holders = scope.holders
  const inScope = new Set(holders.map((h) => h.id))
  const roles = share ? [ROLE.VIEW, ROLE.EDIT, ROLE.MANAGE] : [ROLE.VIEW, ROLE.EDIT]
  const run = async (fn) => {
    setBusy(true)
    setError(null)
    try { await fn(); await onChanged() } catch (e) { setError(e) } finally { setBusy(false) }
  }
  const add = () => run(async () => {
    const lib = await sealedLib()
    await lib.addHolder({ orgId, scope, shareId: share?.id, membershipId: who, role })
    setWho('')
  })
  const rotate = (remove) => run(async () => {
    const lib = await sealedLib()
    await lib.rotateScope({ orgId, scope, remove })
    setRemoving(null)
  })
  const revoke = (l) => diskApi.revokeLink(orgId, l.id).then(() => setLinks((all) => all.filter((x) => x.id !== l.id))).catch(setError)
  const errorText = error?.data?.code === SEAL.NO_IDENTITY_KEY ? 'This person has no encryption key yet. Ask them to set one up in Settings.' : error?.message

  // The confirmation takes the dialog's place: two stacked modals read as one broken one.
  if (removing) {
    return (
      <MgmtModal open onClose={() => setRemoving(null)} width={520}>
        <h2 className={styles.title}>{removing === 'renew' ? 'Renew the key?' : `Remove ${removing.name}?`}</h2>
        <p className={styles.muted}>
          {removing === 'renew'
            ? 'Everyone who still holds the key gets a new one. New files use it.'
            : `Everyone else gets a new key, so ${removing.name} can't read new files. They can still open files they could open before.`}
        </p>
        {links.length > 0 && (
          <>
            <p className={styles.muted}>These public links keep working, even for someone you remove:</p>
            <ul className={styles.list}>
              {links.map((l) => <li key={l.id}><span>Link made {new Date(l.created_at).toLocaleDateString()}{l.expires_at ? `, expires ${new Date(l.expires_at).toLocaleDateString()}` : ''}</span><MgmtButton size="sm" variant="ghost" onClick={() => revoke(l)}>Revoke</MgmtButton></li>)}
            </ul>
          </>
        )}
        {errorText && <p className={styles.error} role="alert">{errorText}</p>}
        <div className={styles.actions}>
          <MgmtButton variant="glass" onClick={() => setRemoving(null)}>Cancel</MgmtButton>
          <MgmtButton variant={removing === 'renew' ? 'primary' : 'danger'} disabled={busy} onClick={() => rotate(removing === 'renew' ? [] : [removing.id])}>{removing === 'renew' ? 'Renew' : 'Remove and renew the key'}</MgmtButton>
        </div>
      </MgmtModal>
    )
  }

  return (
    <MgmtModal open onClose={onClose} width={560}>
      <h2 className={styles.title}>Key holders{share ? ` of ${share.name}` : ''}</h2>
      <p className={styles.muted}>Everyone here can open every file.</p>
      {isManager && (
        <div className={styles.row}>
          <MgmtSelect bare compact aria-label="Person" value={who} onChange={(e) => setWho(e.target.value)}
            options={[{ value: '', label: 'Add a person...' }, ...people.filter((p) => !inScope.has(p.id)).map((p) => ({ value: p.id, label: p.name }))]} />
          <MgmtSelect bare compact aria-label="Role" value={role} onChange={(e) => setRole(e.target.value)} options={roles.map((r) => ({ value: r, label: ROLE_LABEL[r] }))} />
          <MgmtButton size="sm" disabled={!who || busy} onClick={add}>Add</MgmtButton>
        </div>
      )}
      <ul className={styles.list}>
        {holders.map((h) => (
          <li key={h.id}>
            <span>{h.name}{h.agent ? ' (agent)' : ''}<small>{ROLE_LABEL[h.role] || h.role}{h.has_key ? '' : ", doesn't have the current key"}</small></span>
            {isManager && <MgmtButton size="sm" variant="ghost" onClick={() => setRemoving(h)}>Remove</MgmtButton>}
          </li>
        ))}
      </ul>
      {scope.rotationDue && isManager && <MgmtButton size="sm" variant="primary" onClick={() => setRemoving('renew')}>Renew the key</MgmtButton>}
      {errorText && <p className={styles.error} role="alert">{errorText}</p>}
    </MgmtModal>
  )
}

/** Sharing part of a sealed folder (disk_sealed_whole): move it into a new sealed share instead. */
export function MoveToSealedShareDialog({ orgId, node, from, onDone, onClose }) {
  const [name, setName] = useState(node.name || '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const go = async () => {
    setBusy(true)
    try {
      const lib = await sealedLib()
      const { share } = await lib.createSealedShare({ orgId, name: name.trim(), identity: identityKeys() })
      const to = await useSealedStore.getState().open(orgId, share.root_node_id)
      await lib.moveAcrossScopes({ orgId, from, to, node, targetId: share.root_node_id })
      onDone(share)
    } catch (e) {
      setError(e)
      setBusy(false)
    }
  }
  return (
    <MgmtModal open onClose={onClose} width={520}>
      <h2 className={styles.title}>Move to sealed share</h2>
      <p className={styles.muted}>Key holders get the whole folder. To share only &quot;{node.name}&quot;, move it to a new sealed share.</p>
      <MgmtField label="New sealed share" value={name} onChange={(e) => setName(e.target.value)} />
      {error && <p className={styles.error} role="alert">{error.message}</p>}
      <div className={styles.actions}>
        <MgmtButton variant="glass" onClick={onClose}>Cancel</MgmtButton>
        <MgmtButton variant="primary" disabled={!name.trim() || busy} onClick={go}>Move</MgmtButton>
      </div>
    </MgmtModal>
  )
}

/** A public link to one sealed file (6.9): the key rides in the link's #fragment, never sent to inbox2. */
export function SealedLinkDialog({ orgId, scope, node, onClose }) {
  const [password, setPassword] = useState('')
  const [expires, setExpires] = useState('')
  const [hide, setHide] = useState(false)
  const [made, setMade] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const make = async () => {
    setBusy(true)
    setError(null)
    try {
      const lib = await sealedLib()
      setMade(await lib.createSealedLink({ orgId, scope, node, password: password || null, expiresAt: expires || null, hideDownload: hide }))
    } catch (e) {
      setError(e)
    } finally {
      setBusy(false)
    }
  }
  return (
    <MgmtModal open onClose={onClose} width={560}>
      <h2 className={styles.title}>Public link to &quot;{node.name}&quot;</h2>
      <p className={styles.muted}>
        Anyone with the link {password ? 'and the password ' : ''}can open this version of the file. If you remove someone from this folder, revoke any link they have.
      </p>
      {made ? (
        <div className={styles.created}>
          <input className={styles.linkField} readOnly value={made.url} aria-label="Link" onFocus={(e) => e.target.select()} />
          <MgmtButton size="sm" onClick={() => navigator.clipboard?.writeText(made.url)}>Copy</MgmtButton>
          <p className={styles.small}>Copy it now. We can&apos;t show it again.</p>
        </div>
      ) : (
        <>
          <MgmtField label="Password (optional)" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
          <div className={styles.row}>
            <span className={styles.small}>Expires</span>
            <DateField value={expires} onChange={setExpires} placeholder="Never" />
          </div>
          <label className={styles.ack}><MgmtCheckbox  checked={hide} onChange={(e) => setHide(e.target.checked)} /><span>Hide the download button</span></label>
          {error && <p className={styles.error} role="alert">{error.data?.code === SEAL.ROTATION_REQUIRED ? 'A key holder left. Renew the key in Key holders, then make the link.' : error.message}</p>}
          <div className={styles.actions}>
            <MgmtButton variant="glass" onClick={onClose}>Cancel</MgmtButton>
            <MgmtButton variant="primary" disabled={busy} onClick={make}>{busy && password ? 'Making link...' : 'Make link'}</MgmtButton>
          </div>
        </>
      )}
    </MgmtModal>
  )
}

/** The limits of sealing, in plain words (spec F7b last box; build guide 6.1), folded into the
 *  dialog that makes a sealed share or folder: the moment someone decides to seal. */
function SealingLimits() {
  return (
    <details className={styles.limits}>
      <summary>Limits of sealing</summary>
      <ul>
        <li><b>inbox2 can&apos;t read sealed files.</b> Your browser encrypts contents, names, types, thumbnails and page text before upload. Our database, storage and logs hold only encrypted data.</li>
        <li><b>A removed person keeps what they had.</b> After removal, they can&apos;t read new files. Files they opened before can stay on their devices.</li>
        <li><b>You trust our servers with the key holder list.</b> Our servers report who holds each key. A server that lies can add a key holder you didn&apos;t choose. Signed key lists will detect this. We haven&apos;t built them yet.</li>
        <li><b>A link to a sealed file opens for anyone who has it.</b> The key is in the link. Removal from the folder leaves the link working. Revoke the link to stop it.</li>
        <li><b>A lost key means lost files.</b> If all key holders lose their password and recovery phrase, nobody can open the folder. We can&apos;t open it either.</li>
      </ul>
    </details>
  )
}

/** Hands a sealed folder's key to someone else before its holder leaves (6.7 transfer). */
export function TransferKey({ orgId, scopeId, members, onDone }) {
  const [to, setTo] = useState('')
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)
  const go = async () => {
    setBusy(true)
    setError(null)
    try {
      const scope = await useSealedStore.getState().open(orgId, scopeId)
      if (!scope) throw new Error("You don't hold the key to this folder.")
      const lib = await sealedLib()
      await lib.transferScope({ orgId, scope, membershipId: to })
      onDone?.()
    } catch (e) {
      setError(e)
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className={styles.row}>
      <MgmtSelect bare compact aria-label="Give the key to" value={to} onChange={(e) => setTo(e.target.value)}
        options={[{ value: '', label: 'Give the key to...' }, ...members.map((m) => ({ value: m.id, label: m.user?.display_name || m.user?.username || m.id }))]} />
      <MgmtButton size="sm" disabled={!to || busy} onClick={go}>Give key</MgmtButton>
      {error && <p className={styles.error} role="alert">{error.message}</p>}
    </div>
  )
}

/**
 * Moving or copying across a seal boundary (6.8): a confirmation, then the
 * client job one item at a time with progress; a stopped job resumes and
 * skips what finished. plan: () => Promise<job>; job: a resumed one.
 */
// autoStart: begin at once (the person already confirmed, as Seal does); title replaces the question.
export function CrossSealDialog({ direction, op, count, plan, job: resumed, scope, from = null, autoStart = false, title = null, onDone, onClose }) {
  const [job, setJob] = useState(resumed || null)
  const [running, setRunning] = useState(false)
  const [error, setError] = useState(null)
  const started = useRef(false)
  const toSealed = direction === 'to_sealed'
  const sealedCopy = direction === 'sealed_copy'
  const start = async () => {
    setRunning(true)
    setError(null)
    try {
      const [lib, cross] = await Promise.all([sealedLib(), import('../../../lib/disk/crossSeal')])
      const j = job || await plan()
      setJob(j)
      const done = await cross.runJob(j, { sealed: lib, scope, from, onProgress: setJob })
      onDone?.(done)
    } catch (e) {
      setError(e)
    } finally {
      setRunning(false)
    }
  }
  useEffect(() => {
    if (!autoStart || started.current) return
    started.current = true
    start()
  })
  const items = job?.items || []
  const finished = items.filter((i) => i.state === 'done').length
  const failed = items.filter((i) => i.state === 'failed')
  return (
    <MgmtModal open onClose={running ? () => {} : onClose} width={560}>
      <h2 className={styles.title}>{title || (sealedCopy ? 'Copy sealed items?' : `${op === 'move' ? 'Move' : 'Copy'} ${toSealed ? 'and seal' : 'and unseal'}?`)}</h2>
      <p className={styles.muted}>
        {sealedCopy
          ? 'Copies stay sealed. Items with the same name get a number.'
          : toSealed
          ? `This browser seals each file and uploads it again${op === 'move' ? '. Then it deletes the originals and their older versions for good' : ''}. Older versions don't carry over.`
          : `This browser decrypts each file and uploads it unsealed, so inbox2 can read ${op === 'move' ? 'them' : 'the copies'}.${op === 'move' ? ' Public links to the sealed files stop working.' : ''} Older versions don't carry over.`}
      </p>
      {!job && <p className={styles.muted}>{count} {count === 1 ? 'item' : 'items'}.</p>}
      {job && <p className={styles.progress} role="status">{finished} of {items.length} done{failed.length ? `, ${failed.length} failed` : ''}{running ? '...' : ''}</p>}
      {failed.length > 0 && <ul className={styles.list}>{failed.map((i) => <li key={i.sourceId}><span>{i.name}<small>{i.reason}</small></span></li>)}</ul>}
      {job?.kept?.length > 0 && <p className={styles.progress} role="status">The original changed while this ran, so {job.kept.length === 1 ? 'that folder is' : `${job.kept.length} folders are`} in Trash.</p>}
      {error && <p className={styles.error} role="alert">{error.message}</p>}
      <div className={styles.actions}>
        {!running && <MgmtButton variant="glass" onClick={onClose}>{job?.done ? 'Close' : 'Later'}</MgmtButton>}
        {!job?.done && <MgmtButton variant={toSealed ? 'primary' : 'danger'} disabled={running} onClick={start}>{job ? 'Resume' : op === 'move' ? 'Move' : 'Copy'}</MgmtButton>}
      </div>
    </MgmtModal>
  )
}

/**
 * The members dialog for a sealed share (spec F7): its key holders. Opens the
 * share's scope first; an admin who holds no key can see the share but cannot
 * give anyone its key, and the dialog says so instead of failing.
 */
export function SealedShareMembers({ orgId, share, people, onChanged, onClose }) {
  const entry = useSealedStore((s) => s.scopes[`${orgId}/${share.root_node_id}`])
  const { identityStatus } = useE2ee()
  useEffect(() => { useSealedStore.getState().open(orgId, share.root_node_id) }, [orgId, share.root_node_id, identityStatus])
  if (entry?.status === 'open') {
    return (
      <SealedMembersDialog orgId={orgId} scope={entry.scope} share={share} people={people} isManager
        onChanged={async () => { await useSealedStore.getState().reopen(orgId, share.root_node_id); onChanged?.() }} onClose={onClose} />
    )
  }
  return (
    <MgmtModal open onClose={onClose} width={480}>
      <h2 className={styles.title}>Key holders of {share.name}</h2>
      {!entry || entry.status === 'loading' ? <p className={styles.muted}>Opening the share&apos;s key...</p> : <SealedBanner entry={entry} shareName={share.name} />}
      <div className={styles.actions}><MgmtButton variant="glass" onClick={onClose}>Close</MgmtButton></div>
    </MgmtModal>
  )
}

import { MgmtCheckbox } from '../../../components/management';