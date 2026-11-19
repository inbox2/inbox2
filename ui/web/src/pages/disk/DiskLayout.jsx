import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import RouteLoading from '../../components/RouteLoading'
import AppSwitcher from '../../components/AppSwitcher'
import { NavLink, Navigate, Outlet, useLocation } from 'react-router'
import useAuth from '../../hooks/useAuth'
import useDismiss from '../../hooks/useDismiss'
import useIsPhone from '../../hooks/useIsPhone'
import useOrgMembers from '../../hooks/useOrgMembers'
import useDiskStore from '../../stores/diskStore'
import { DISK_ORG } from '../../lib/storageKeys'
import { isAdminRole } from '../../lib/orgRoles'
import { diskOrg, diskPath, diskSplat, drivePath, IMPORT_SEGMENT, parseDiskPath, pathUrl, setTeamLetter, shareRoot, teamLetter, teamsByLetter, VIEWS } from '../../lib/disk/model'
import FileTypeIcon, { ActionIcon } from '../../components/FileTypeIcon'
import { MgmtButton, MgmtMeter, MgmtSideFoot } from '../../components/management'
import Skeleton from '../../components/Skeleton'
import UploadPanel from './UploadPanel'
import ResumeJobs from './sealed/ResumeJobs'
import useEngineStore, { ENGINE } from '../../stores/engineStore'
import formatBytes from '../../lib/formatBytes'
import { restoreInterrupted } from '../../lib/disk/upload'
import { holdDiskTab } from '../../lib/disk/engine/client'
import { registerDiskWorker } from '../../lib/disk/swRegister'
import '../../styles/management.css'
import styles from './DiskLayout.module.css'
import { consolePath } from '../../lib/consoleHost'

// The org Disk is on, remembered per browser (lib/disk/model.js diskOrg).
const readDiskOrg = () => { try { return localStorage.getItem(DISK_ORG) } catch { return null } }
const rememberDiskOrg = (id) => { try { localStorage.setItem(DISK_ORG, id) } catch { /* storage blocked: not remembered */ } }

/* The Disk shell: management skin, a sidebar with the drives (C:\ is the
 * person's own, then one lettered drive per team), the current team's shares,
 * the four views and the quota meters, around the routed browser. Disk works
 * on one team at a time: the drive letter in the URL, else ?org=, else the
 * remembered choice, else the org the person acts in. */
export default function DiskLayout() {
  const { pathname, search } = useLocation()
  const { organizations, user, currentOrg } = useAuth()
  const [, rerender] = useState(0)
  const chosen = readDiskOrg()
  const wanted = new URLSearchParams(search).get('org')
  const engine = useEngineStore()
  const letter = parseDiskPath(diskSplat(pathname)).letter
  const org = diskOrg(organizations, wanted || chosen, currentOrg, letter)
  setTeamLetter(teamLetter(org))
  // Stable, so a lookup in other orgs (DiskBrowser Elsewhere) runs once.
  // Stable, so a lookup in other orgs (DiskBrowser Elsewhere) runs once.
  const switchOrg = useCallback((o) => { rememberDiskOrg(o.id); rerender((n) => n + 1) }, [rerender])
  // The browser mounts only once the store is on this org: its requests start after the
  // store's reset (enterOrg, in an effect below), never before it, where it would drop them.
  const storeOrg = useDiskStore((s) => s.orgId)
  const orgId = org?.id
  const drives = useDiskStore((s) => s.drives)
  const drivesError = useDiskStore((s) => s.drivesError)
  const loadDrives = useDiskStore((s) => s.loadDrives)
  const members = useOrgMembers(orgId)

  const isPhone = useIsPhone()
  const [navOpen, setNavOpen] = useState(false)
  const sideRef = useRef(null)
  const menuBtnRef = useRef(null)
  const closeNav = useCallback(() => {
    setNavOpen(false)
    menuBtnRef.current?.focus()
  }, [setNavOpen])
  useDismiss(sideRef, closeNav, navOpen)
  useEffect(() => {
    if (navOpen) sideRef.current?.querySelector('a, button')?.focus()
  }, [navOpen])

  useEffect(() => {
    if (!orgId) return
    useDiskStore.getState().enterOrg(orgId)
    loadDrives(orgId)
    restoreInterrupted(orgId)
    // Only reads what is installed (and quietly updates it); the first Office file starts the download.
    import('../../lib/disk/engine/install').then((m) => m.refreshEngine())
  }, [orgId, loadDrives])

  // Converted files belong to one account: another account's are dropped on entry (spec F5b).
  useEffect(() => {
    if (user?.id) import('../../lib/disk/engine/conversions').then((m) => m.dropOtherAccounts(user.id)).catch(() => {})
  }, [user?.id])

  // The exact-view window closes once no tab holds this (lib/disk/engine/client.js).
  useEffect(() => holdDiskTab(), [])
  // The sealed-file service worker (6.11): scope "/", acting only on /disk/sealed/,
  // fetching only from the storage origins the API names.
  const storageOrigins = drives ? (drives.settings?.storage_origins || []) : null
  const originsKey = storageOrigins?.join(',')
  useEffect(() => { if (originsKey != null) registerDiskWorker(originsKey ? originsKey.split(',') : []) }, [originsKey])

  const people = useMemo(
    () => members.filter((m) => m.status === 'active').map((m) => ({ id: m.id, name: m.user?.display_name || m.user?.username || m.id, avatar_url: m.user?.avatar_url })),
    [members],
  )

  if (organizations && !org) return <Navigate to={consolePath()} replace />
  if (!org) return <RouteLoading />
  // A drive letter in the address picks its team; ?org= picks the org once and is dropped from the address.
  if (letter && org.id !== chosen) rememberDiskOrg(org.id)
  if (wanted) {
    if (org.id !== chosen) rememberDiskOrg(org.id)
    const rest = new URLSearchParams(search)
    rest.delete('org')
    return <Navigate to={`${pathname}${rest.toString() ? `?${rest}` : ''}`} replace />
  }

  const slug = org.slug
  // Another app: on its own host when Disk has its own (disk.inbox2.com), else this host's path.
  const isAdmin = isAdminRole(org.role)
  // Spec F8: after a downgrade Disk is read-only for a month (view, download, delete), then blocked.
  const state = drives?.settings?.state || 'active'
  const writable = state === 'active'
  const ctx = { org, orgId, slug, domains: org.domains || [], drives, isAdmin, people, writable, reloadDrives: () => loadDrives(orgId), organizations, switchOrg }
  const quota = drives?.quota
  const cQuota = drives?.c_quota
  const pct = (q) => (q?.pool_bytes ? (q.used_bytes + (q.reserved_bytes || 0)) / q.pool_bytes : 0)
  const quotaPct = Math.max(pct(quota), pct(cQuota))
  const myLetter = teamLetter(org)
  const navCls = ({ isActive }) => [styles.navItem, isActive ? styles.on : ''].join(' ')

  let body
  if (drivesError?.status === 403) body = <Paywall isAdmin={isAdmin} />
  else if (drivesError) body = (
    <div className={styles.state} role="alert">
      <h1 className={styles.stateTitle}>Disk didn't load</h1>
      <p>{drivesError.message}</p>
      <MgmtButton onClick={() => loadDrives(orgId)}>Try again</MgmtButton>
    </div>
  )
  else body = <>
    {state === 'read_only' && (
      <p className={styles.banner} role="status">
        Your plan no longer includes Disk. You can view, download and delete files until {new Date(drives.settings.read_only_until).toLocaleDateString()}.
        On {new Date(drives.settings.purge_at).toLocaleDateString()} we delete them.
        {isAdmin && <> <NavLink to={consolePath('billing')}>See plans</NavLink></>}
      </p>
    )}
    {quotaPct >= 1 && <p className={`${styles.banner} ${styles.bannerFull}`} role="status">Disk is full. To upload again, empty the trash or delete old versions{isAdmin ? ', or move to a plan with more space' : ''}.</p>}
    {quotaPct >= 0.8 && quotaPct < 1 && <p className={styles.banner} role="status">Disk is {Math.round(quotaPct * 100)}% full.</p>}
    <ResumeJobs orgId={orgId} onDone={() => useDiskStore.getState().invalidate(orgId)} />
    {storeOrg === orgId && <Outlet context={ctx} />}
  </>

  return (
    <div className={`management ${styles.shell}`}>
      <header className={styles.mobileBar}>
        <button
          ref={menuBtnRef}
          type="button"
          className={styles.menuBtn}
          aria-label="Drives and views"
          aria-expanded={navOpen}
          onClick={() => setNavOpen((o) => !o)}
        >
          <ActionIcon name="list" size={18} />
        </button>
        <span className={styles.brandWord}>inbox2</span><span className={styles.brandKicker}>Disk</span>
      </header>
      {navOpen && <div className={styles.scrim} aria-hidden="true" />}
      {/* eslint-disable-next-line jsx-a11y/click-events-have-key-events -- links fire click on Enter; a presentation role would drop the nav landmark */}
      <nav
        ref={sideRef}
        className={[styles.side, navOpen ? styles.sideOpen : ''].join(' ')}
        aria-label="Disk"
        inert={isPhone && !navOpen}
        onClick={(e) => { if (navOpen && e.target.closest('a')) closeNav() }}
      >
        <div className={styles.brand}><span className={styles.brandWord}>inbox2</span><span className={styles.brandKicker}>Disk</span></div>
        <div className={styles.group}>Drives</div>
        <NavLink to={drivePath('C')} className={navCls}>
          <FileTypeIcon kind="drive" drive="C" size={22} />My disk<span className={styles.drv}>C:\</span>
        </NavLink>
        {/* One lettered drive per team, in the order joined; the current team's shares sit under its drive. */}
        {teamsByLetter(organizations).map((o) => {
          const l = teamLetter(o)
          const here = o.id === org.id
          return (
            <Fragment key={o.id}>
              <NavLink to={drivePath('D', l)} end className={navCls}
                onClick={() => { if (!here) switchOrg(o) }}>
                <FileTypeIcon kind="drive" drive={l} size={22} />{organizations.length > 1 ? o.name : 'Shared disk'}<span className={styles.drv}>{l}:\</span>
              </NavLink>
              {here && !drives && !drivesError && <Skeleton variant="text" count={3} />}
              {here && drives?.shares.map((s) => (
                <NavLink key={s.id} to={pathUrl([shareRoot(s)])} state={{ kind: 'folder', drive: 'D', path: [shareRoot(s)] }} className={({ isActive }) => `${navCls({ isActive })} ${styles.sub}`}>
                  <FileTypeIcon kind="share" emblem={s.icon} color={s.color} size={20} />{s.name}{s.sealed && <span className={styles.lock}>sealed</span>}
                </NavLink>
              ))}
            </Fragment>
          )
        })}
        <NavLink to={diskPath(IMPORT_SEGMENT)} className={navCls}><ActionIcon name="download" size={18} />Import</NavLink>
        <div className={styles.group}>Views</div>
        {VIEWS.map((v) => <NavLink key={v.slug} to={diskPath(v.slug)} className={navCls}><ActionIcon name={v.icon} size={18} />{v.label}</NavLink>)}
        {/* Space used, under the views, quietly: few people near the limit, and the banners above the page
            speak up from 80%. Nothing behind the paywall; after a downgrade the pool is 0, so only what is used. */}
        {(cQuota || quota) && (
          <div className={styles.usage}>
            {cQuota && <QuotaMeter letter="C" quota={cQuota} hint="Your own disk, the same in every team" />}
            {quota && <QuotaMeter letter={myLetter} quota={quota} hint={`Shared by everyone in ${org.name}`} />}
          </div>
        )}

        {/* The console's foot: the other apps, then the person. */}
        <MgmtSideFoot
          sub={org.domain}
          onAction={() => setNavOpen(false)}
        />
      </nav>
      <main className={styles.main}>
        <div className={styles.topBar}><AppSwitcher current="disk" variant="light" /></div>
        {body}
      </main>
      <UploadPanel />
      {/* The exact-view engine downloads when the first Office file is opened (install.js ensureEngine) and keeps going once the preview is closed; this goes when it is ready. */}
      {(engine.status === ENGINE.DOWNLOADING || engine.status === ENGINE.VERIFYING) && (
        <div className={styles.engineChip} role="status">
          <span>Getting exact view{engine.status === ENGINE.DOWNLOADING && engine.total ? ` ${Math.round((engine.loaded / engine.total) * 100)}%` : '...'}</span>
          <MgmtMeter value={engine.total ? engine.loaded / engine.total : 0} />
        </div>
      )}
    </div>
  )
}

// What the space is used for, in the donut's fixed order; colours per key in the CSS (k_<key>).
const SLICES = ['documents', 'images', 'video', 'audio', 'sealed', 'other', 'versions', 'trash']
const SLICE_LABEL = { documents: 'Documents', images: 'Images', video: 'Video', audio: 'Audio', sealed: 'Sealed', other: 'Other', versions: 'Older versions', trash: 'Trash' }

// The breakdown as a donut: a circle of circumference 100, one dashed stroke per slice, a small gap
// between slices. Decorative beside its legend (which carries every label and value), so aria-hidden.
function Donut({ rows }) {
  const total = rows.reduce((s, [, v]) => s + v, 0)
  const gap = rows.length > 1 ? 1.2 : 0
  const pcts = rows.map(([, v]) => (v / total) * 100)
  const starts = pcts.map((_, i) => pcts.slice(0, i).reduce((a, b) => a + b, 0))
  return (
    <svg className={styles.donut} viewBox="0 0 42 42" aria-hidden="true">
      {rows.map(([k], i) => {
        const len = Math.max(pcts[i] - gap, 0.4)
        return (
          <circle key={k} className={styles[`k_${k}`]} cx="21" cy="21" r="15.9155" fill="none" strokeWidth="6"
            strokeDasharray={`${len} ${100 - len}`} strokeDashoffset={25 - starts[i]} />
        )
      })}
    </svg>
  )
}

/* Space used, quietly: a thin gray bar, the figures on hover or focus. Few people near the limit,
   and the banners above the page speak up from 80%. After a downgrade the pool is 0, so only what is used. */
function QuotaMeter({ letter, quota, hint }) {
  const used = quota.used_bytes + (quota.reserved_bytes || 0)
  const summary = `${formatBytes(quota.used_bytes)}${quota.pool_bytes ? ` of ${formatBytes(quota.pool_bytes)}` : ' used'}`
  // Fixed category order, so a category keeps its colour (and its place) whatever its size.
  const bytes = { ...quota.types_bytes, versions: quota.versions_bytes, trash: quota.trash_bytes }
  const rows = SLICES.map((k) => [k, bytes[k] || 0]).filter(([, v]) => v > 0)
  return (
    <div className={styles.quota} tabIndex={0} aria-label={`${letter}:\\ ${summary}`}>
      <span className={styles.quotaLetter}>{letter}:\</span>
      <MgmtMeter value={quota.pool_bytes ? used / quota.pool_bytes : 0} />
      <div className={styles.quotaTip} role="tooltip">
        <b>{summary}</b>
        <span className={styles.quotaHint}>{hint}</span>
        {rows.length > 0 && (
          <div className={styles.quotaBreak}>
            <Donut rows={rows} />
            <dl>{rows.map(([k, v]) => (
              <Fragment key={k}><dt><i className={`${styles.swatch} ${styles[`k_${k}`]}`} />{SLICE_LABEL[k]}</dt><dd>{formatBytes(v)}</dd></Fragment>
            ))}</dl>
          </div>
        )}
      </div>
    </div>
  )
}

function Paywall({ isAdmin }) {
  return (
    <div className={styles.state}>
      <FileTypeIcon kind="folder" size={84} />
      <h1 className={styles.stateTitle}>Disk isn't in your plan</h1>
      <p>Disk stores files for everyone in your organization.</p>
      {isAdmin
        ? <MgmtButton as={NavLink} to={consolePath('billing')}>See plans</MgmtButton>
        : <p>Ask an owner or admin to upgrade.</p>}
    </div>
  )
}
