import { useCallback, useEffect, useRef, useState } from 'react';
import Button from '../../components/Button/Button';
import Switch from '../../components/Switch/Switch';
import SegmentedControl from '../../components/SegmentedControl/SegmentedControl';
import Checkbox from '../../components/Checkbox/Checkbox';
import ConfirmDialog from '../../components/ConfirmDialog/ConfirmDialog';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import FileTypeIcon from '../../components/FileTypeIcon/FileTypeIcon';
import useAuth from '../../hooks/useAuth';
import diskApi from '../../lib/disk/api';
import { useE2ee } from '../../lib/e2eeStore';
import formatBytes from '../../lib/formatBytes';
import relativeTime from '../../lib/relativeTime';
import log from '../../lib/log';
import { diskFinder, statusLine, SPEEDS } from '../../lib/diskFinder';
import styles from './settings.module.css';
import own from './DiskFinderSettings.module.css';

/* Settings › Disk (docs/Disk-Sync.md): show inbox2 Disk in the Finder sidebar.
 * The Finder extension inside the app syncs; this screen turns it on, shows its
 * state and holds its settings. macOS 15 or later. */

const errText = (e) => (typeof e === 'string' ? e : e?.message) || 'That did not work. Try again.';
const C_DRIVE = 'c';

export default function DiskFinderSettings({ orgId }) {
  const { user, organizations } = useAuth();
  const { identityStatus } = useE2ee();
  const org = (organizations || []).find((o) => o.slug === orgId || o.id === orgId);
  const [status, setStatus] = useState(null);
  const [drives, setDrives] = useState(null);
  const [drivesError, setDrivesError] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [loadError, setLoadError] = useState('');
  const inFlight = useRef(false);
  const [confirmOff, setConfirmOff] = useState(false);
  const [kept, setKept] = useState(null);

  const load = useCallback(() => {
    diskFinder.status().then((s) => { setStatus(s); setLoadError(''); }).catch((e) => setLoadError(errText(e)));
  }, []);

  useEffect(() => {
    load();
    const t = setInterval(load, 5000);
    return () => clearInterval(t);
  }, [load]);

  const loadDrives = useCallback(() => {
    if (!org) return;
    diskApi.drives(org.id).then(setDrives).catch((e) => {
      log.warn('DiskFinder', `drives: ${errText(e)}`);
      setDrivesError(errText(e));
    });
  }, [org]);

  useEffect(() => { loadDrives(); }, [loadDrives]);

  // An unlock in this window reaches the extension straight away.
  useEffect(() => {
    if (status?.enabled && identityStatus === 'unlocked' && !status.sealed_open && status.filevault) {
      diskFinder.refresh().then(setStatus).catch(() => {});
    }
  }, [identityStatus, status?.enabled, status?.sealed_open, status?.filevault]);

  const run = async (fn) => {
    // One change at a time: a second one in flight could land first and lose the later choice.
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError('');
    try {
      const next = await fn();
      if (next && typeof next === 'object') setStatus(next);
      else load();
    } catch (e) {
      setError(errText(e));
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  const turnOn = () => run(() => diskFinder.enable(org, user));
  const turnOff = () => run(async () => {
    setConfirmOff(false);
    setKept(await diskFinder.disable());
    return null;
  });
  const update = (args) => run(() => diskFinder.update(args));
  const toggleDrive = (key, show) => {
    const hidden = new Set(status?.hidden_drives || []);
    if (show) hidden.delete(key); else hidden.add(key);
    update({ hiddenDrives: [...hidden] });
  };

  if (!status) {
    return (
      <>
        <div className={styles.settingsTitle}>Disk</div>
        <div className={styles.settingsPanel}>
          {loadError ? (
            <>
              <p className={own.error} role="alert">{loadError}</p>
              <Button variant="secondary" onClick={load}>Try again</Button>
            </>
          ) : <Spinner size="sm" label="Loading" />}
        </div>
      </>
    );
  }

  if (!status.supported) {
    return (
      <>
        <div className={styles.settingsTitle}>Disk</div>
        <div className={styles.settingsPanel}>
          <p className={styles.sectionDesc}>Disk in Finder needs macOS 15 or later.</p>
        </div>
      </>
    );
  }

  const line = statusLine(status);
  // Finder holds one organization at a time; another one's location is not this page's to manage.
  const on = status.enabled && status.org === org?.id;
  const otherOrg = status.enabled && !on
    ? (organizations || []).find((o) => o.id === status.org)?.name || 'another organization'
    : null;
  const shares = drives?.shares?.filter((s) => !s.trashed_at) || [];
  const hasSealed = shares.some((s) => s.sealed);

  return (
    <>
      <div className={styles.settingsTitle}>Disk</div>

      <div className={styles.settingsPanel}>
        <Switch
          id="disk-finder"
          label="Show Disk in Finder"
          description="Your files appear in the Finder sidebar. Files download when you open them."
          checked={on}
          disabled={busy || !org}
          onChange={(v) => (v ? turnOn() : setConfirmOff(true))}
        />
        {otherOrg && (
          <>
            <hr className={styles.settingsGroupDivider} />
            <p className={own.step}>Finder shows the files of {otherOrg}. Turn this on to show {org?.name} there.</p>
          </>
        )}
        {on && (
          <>
            <hr className={styles.settingsGroupDivider} />
            <div className={own.stateRow}>
              <div className={own.state}>
                <span className={`${own.status} ${own[line.tone]}`}>{line.text}</span>
                <span className={own.meta}>
                  {status.last_sync_at ? `Checked ${relativeTime(status.last_sync_at * 1000)}` : 'Not checked yet'}
                  {` · ${formatBytes(status.local_bytes)} on this Mac`}
                </span>
              </div>
              <div className={own.actions}>
                <Button variant="secondary" disabled={busy || !status.approved} onClick={() => run(() => diskFinder.pause(!status.paused))}>
                  {status.paused ? 'Resume' : 'Pause'}
                </Button>
                <Button disabled={busy || !status.approved} onClick={() => run(diskFinder.open)}>Open in Finder</Button>
              </div>
            </div>
          </>
        )}
        {kept && <p className={styles.settingsHint}>Edits that didn&apos;t upload are in {kept}.</p>}
        {(error || loadError) && <p className={own.error} role="alert">{error || loadError}</p>}
      </div>

      {on && !status.approved && (
        <div className={styles.settingsPanel}>
          <div className={styles.settingsSectionTitle}>Allow inbox2 in System Settings</div>
          <p className={own.step}>In General, open Login Items &amp; Extensions and turn on inbox2 under File Providers.</p>
          <Button onClick={diskFinder.openSystemSettings}>Open System Settings</Button>
        </div>
      )}

      {on && (
        <div className={styles.settingsPanel}>
          <div className={styles.settingsSectionTitle}>New files</div>
          <p className={styles.settingsHint}>Online-only files use no space until you open them.</p>
          <SegmentedControl disabled={busy}
            aria-label="New files"
            size="lg"
            value={status.keep_downloaded ? 'keep' : 'online'}
            onChange={(v) => update({ keepDownloaded: v === 'keep' })}
            options={[
              { value: 'online', label: 'Online-only', icon: 'cloud' },
              { value: 'keep', label: 'Keep on this Mac', icon: 'arrow.down.circle' },
            ]}
          />

          <hr className={styles.settingsGroupDivider} />
          <div className={styles.settingsSectionTitle}>Drives in Finder</div>
          <div className={own.drives}>
            {!drives && !drivesError && <Spinner size="sm" label="Loading" />}
            {drivesError && (
              <>
                <p className={own.error} role="alert">{drivesError}</p>
                <Button variant="secondary" onClick={() => { setDrivesError(''); loadDrives(); }}>Try again</Button>
              </>
            )}
            {drives && (
              <Checkbox checked={!status.hidden_drives.includes(C_DRIVE)} disabled={busy} onChange={(e) => toggleDrive(C_DRIVE, e.target.checked)}>
                <span className={own.drive}><FileTypeIcon kind="drive" drive="C" size={20} />My files</span>
              </Checkbox>
            )}
            {shares.map((s) => (
              <Checkbox key={s.id} checked={!status.hidden_drives.includes(s.id)} disabled={busy} onChange={(e) => toggleDrive(s.id, e.target.checked)}>
                <span className={own.drive}><ShareMark share={s} domains={org?.domains} />{s.name}</span>
                {s.sealed && <span className={own.sealed}><Icon name="lock.fill" size={11} /> sealed</span>}
              </Checkbox>
            ))}
          </div>
          {hasSealed && <SealedNote status={status} identityStatus={identityStatus} />}

          <hr className={styles.settingsGroupDivider} />
          <div className={own.speedRow}>
            <div className={styles.settingsSectionTitle}>Upload speed</div>
            <SegmentedControl disabled={busy} aria-label="Upload speed" value={status.upload_kbps} options={SPEEDS} onChange={(v) => update({ uploadKbps: v })} />
          </div>
          <div className={own.speedRow}>
            <div className={styles.settingsSectionTitle}>Download speed</div>
            <SegmentedControl disabled={busy} aria-label="Download speed" value={status.download_kbps} options={SPEEDS} onChange={(v) => update({ downloadKbps: v })} />
          </div>
        </div>
      )}

      <ConfirmDialog
        open={confirmOff}
        title="Remove Disk from Finder?"
        message="Your files stay in inbox2. Edits that didn't upload move to a folder on this Mac."
        confirmLabel="Remove"
        onConfirm={turnOff}
        onCancel={() => setConfirmOff(false)}
      />
    </>
  );
}

/* A share shows its company's logo, so teams are told apart at a glance;
 * a share with no company (or no logo) keeps its own share icon. */
function ShareMark({ share, domains }) {
  const logo = share.domain && (domains || []).find((d) => d.id === share.domain.id)?.icon_url;
  if (logo) return <img className={own.logo} src={logo} alt="" width={20} height={20} />;
  return <FileTypeIcon kind="share" emblem={share.icon} color={share.color} size={20} />;
}

/* Sealed shares open in Finder only with FileVault on and Disk unlocked here. */
function SealedNote({ status, identityStatus }) {
  if (!status.filevault) {
    return <p className={own.note}><Icon name="lock.fill" size={12} /> Turn on FileVault to open sealed shares on this Mac.</p>;
  }
  if (status.sealed_open) return null;
  if (identityStatus === 'none') return <p className={own.note}>Set up encryption in Disk to open sealed shares.</p>;
  return <p className={own.note}><Icon name="lock.fill" size={12} /> Unlock sealed files in Disk to open them in Finder.</p>;
}
