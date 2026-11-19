import { useState, useEffect, useRef, useCallback } from 'react';
import Button from '../../components/Button/Button';
import Icon from '../../components/Icon';
import log from '../../lib/log';
import { checkForUpdates } from '../../lib/updater';
import useUpdateStore from '../../stores/updateStore';
import settings from './settings.module.css';
import styles from './AboutSettings.module.css';

// Desktop-only "About & Updates" panel: shows the running version and drives the
// manual update flow. The update itself (found → install → relaunch) lives in
// updateStore, shared with the chrome bell tag and the notification panel.
export default function AboutSettings() {
  const [version, setVersion] = useState('');
  // idle | checking | up-to-date | error — the check flow only; the install
  // flow's state comes from the store.
  const [status, setStatus] = useState('idle');
  const [checkError, setCheckError] = useState('');
  const { update, busy, progress, deferred, error: installError, found, install } = useUpdateStore();
  const progressRef = useRef(null);

  useEffect(() => {
    let active = true;
    import('@tauri-apps/api/app')
      .then(({ getVersion }) => getVersion())
      .then((v) => { if (active) setVersion(v); })
      .catch(() => { /* web — no native version */ });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (progressRef.current) {
      progressRef.current.style.setProperty('--progress', `${Math.round((progress ?? 0) * 100)}%`);
    }
  }, [progress]);

  const handleCheck = useCallback(async () => {
    setStatus('checking');
    setCheckError('');
    try {
      const info = await checkForUpdates();
      if (info) { found(info); setStatus('idle'); }
      else { setStatus('up-to-date'); }
    } catch (err) {
      log.error('updater', 'check failed', err);
      setCheckError(String(err?.message || err));
      setStatus('error');
    }
  }, [found]);

  const error = installError || checkError;

  return (
    <>
      <h1 className={settings.settingsTitle}>About &amp; updates</h1>

      <div className={settings.settingsSection}>
        <div className={settings.settingsSectionTitle}>Version</div>
        <div className={styles.versionRow}>
          <Icon name="app.badge" size={16} />
          <span className={styles.versionNum}>{version ? `Inbox2 ${version}` : 'Inbox2'}</span>
        </div>
        <p className={settings.sectionDesc}>
          Inbox2 checks for updates while it runs. You can also check now.
        </p>

        {update && !busy && !deferred && (
          <div className={styles.banner} data-kind="available">
            <Icon name="arrow.down.circle.fill" size={14} />
            <div className={styles.bannerBody}>
              <span className={styles.bannerTitle}>
                Update available: {update.current_version} → {update.version}
              </span>
              {update.notes && <span className={styles.bannerNotes}>{update.notes}</span>}
              <span className={styles.bannerHint}>
                On Linux .deb and .rpm builds, your system asks for your password to finish.
              </span>
            </div>
          </div>
        )}

        {status === 'up-to-date' && !update && (
          <div className={styles.banner} data-kind="ok">
            <Icon name="checkmark.circle.fill" size={14} />
            <span>You’re on the latest version.</span>
          </div>
        )}

        {busy && (
          <div className={styles.progressWrap}>
            <div ref={progressRef} className={styles.progressBar} />
            <span className={styles.progressLabel}>
              {progress != null && progress >= 1 ? 'Restarting…' : 'Downloading update…'}
            </span>
          </div>
        )}

        {deferred && (
          <div className={styles.banner} data-kind="ok">
            <Icon name="checkmark.circle.fill" size={14} />
            <span>The installer is open. Follow its steps to finish.</span>
          </div>
        )}

        {error && (
          <div className={styles.banner} data-kind="error">
            <Icon name="exclamationmark.triangle.fill" size={14} />
            <span>Update failed: {error}</span>
          </div>
        )}

        <div className={styles.actions}>
          {update ? (
            <Button onClick={install} disabled={busy || deferred}>
              Install &amp; relaunch
            </Button>
          ) : (
            <Button onClick={handleCheck} disabled={status === 'checking'}>
              {status === 'checking' ? 'Checking…' : 'Check for updates'}
            </Button>
          )}
        </div>
      </div>
    </>
  );
}
