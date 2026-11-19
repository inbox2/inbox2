import { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router';
import useAuth from '../../hooks/useAuth';
import api from '../../lib/api';
import { isTauri } from '../../lib/tauri';
import ConfirmDialog from '../../components/ConfirmDialog/ConfirmDialog';
import useTransientFlag from '../../hooks/useTransientFlag';
import Button from '../../components/Button/Button';
import Icon from '../../components/Icon';
import ExportMyDisk from './ExportMyDisk';
import ImportMail from './ImportMail';
import SearchSelect from '../../components/SearchSelect/SearchSelect';
import { LANGUAGES } from '../../lib/languages';
import styles from './settings.module.css';

export default function AccountSettings() {
  const { user, logout } = useAuth();
  const navigate = useNavigate();
  const [displayName, setDisplayName] = useState('');
  const [language, setLanguage] = useState('en');
  const [importing, setImporting] = useState(false);
  const [avatarUrl, setAvatarUrl] = useState('');
  const [error, setError] = useState(null);
  const [uploading, setUploading] = useState(false);
  const [saved, flashSaved] = useTransientFlag();
  const [clearConfirmOpen, setClearConfirmOpen] = useState(false);
  const fileRef = useRef(null);
  const isDesktop = isTauri();

  useEffect(() => {
    api.getAccount().then(data => {
      const acct = data.account || data.user || {};
      setDisplayName(acct.display_name || '');
      setLanguage(acct.default_language || 'en');
      setAvatarUrl(acct.avatar_url || '');
    }).catch(() => { /* load error */ });
  }, []);

  const handleAvatarUpload = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setUploading(true);
    try {
      const data = await api.uploadAvatar(file);
      setAvatarUrl(data.account.avatar_url || '');
    } catch {
      /* upload error */
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  const handleLogoutAndClear = async () => {
    setClearConfirmOpen(false);
    // Revoke the API session and clear web-side state first: on desktop the
    // native command restarts the app, so anything after it won't run.
    try { await logout(); } catch { /* best-effort */ }
    localStorage.clear();
    if (isDesktop) {
      const { invoke } = await import('@tauri-apps/api/core');
      try {
        // Cleanly stops sync, deletes the local SQLite DB + caches, then
        // restarts the app — so this promise never resolves on success.
        await invoke('clear_local_data');
      } catch { /* deletion failed — fall through to the login screen */ }
    }
    navigate('/login', { replace: true });
  };

  const handleClearCancel = useCallback(() => setClearConfirmOpen(false), []);

  const handleSave = async () => {
    setError(null);
    try {
      await api.patch('/account', {
        display_name: displayName,
        default_language: language,
      });
      flashSaved();
    } catch (e) {
      setError(e?.message || "Couldn't save your settings");
    }
  };

  return (
    <>
      <h1 className={styles.settingsTitle}>Account & profile</h1>

      <div className={styles.settingsField}>
        <label>Profile picture</label>
        <div className={styles.iconUrlRow}>
          {avatarUrl && (
            <img
              src={avatarUrl}
              alt=""
              className={styles.avatarPreview}
              onError={e => { e.target.style.display = 'none'; }}
            />
          )}
          <input
            value={avatarUrl}
            onChange={e => setAvatarUrl(e.target.value)}
            placeholder="https://example.com/avatar.png"
          />
          <button
            type="button"
            className={styles.addAccountBtn}
            onClick={() => fileRef.current?.click()}
            disabled={uploading}
          >
            <Icon name="arrow.up.circle.fill" size={14} />
            {uploading ? 'Uploading...' : 'Upload'}
          </button>
          <input
            ref={fileRef}
            type="file"
            accept="image/*"
            onChange={handleAvatarUpload}
            hidden
          />
        </div>
      </div>

      <div className={styles.settingsField}>
        <label>Username</label>
        <input value={user?.username || ''} disabled />
      </div>
      <div className={styles.settingsField}>
        <label htmlFor="display-name">Display name</label>
        <input id="display-name" value={displayName} onChange={e => setDisplayName(e.target.value)} />
      </div>
      <div className={styles.settingsField}>
        <label htmlFor="language">Default language</label>
        <SearchSelect id="language" label="Default language" value={language} onChange={setLanguage}
          options={LANGUAGES} placeholder="Search languages" />
      </div>
      <p className={styles.settingsHint}>
        Time zone, working hours and out of office live in Settings › Scheduling.
      </p>

      {error && <div className={styles.settingsError}>{error}</div>}

      <Button className={styles.settingsButton} onClick={handleSave}>
        {saved ? 'Saved' : 'Save changes'}
      </Button>

      <ExportMyDisk disabled={importing} />
      <ImportMail onBusyChange={setImporting} />
      <div className={styles.dangerZone}>
        <div className={styles.settingsSectionTitle}>Danger zone</div>
        <div className={styles.dangerZoneRow}>
          <div>
            <span className={styles.tablePrimary}>Log out &amp; clear data</span>
            <span className={styles.tableSecondary}>Deletes the mail, drafts and preferences stored on this device.</span>
          </div>
          <Button variant="danger" className={styles.dangerZoneBtn} onClick={() => setClearConfirmOpen(true)}>
            Clear data &amp; log out
          </Button>
        </div>
      </div>
      <ConfirmDialog
        open={clearConfirmOpen}
        title="Clear all local data?"
        message="You’re logged out and the mail, drafts and preferences on this device are deleted for good."
        confirmLabel="Clear data"
        variant="danger"
        onConfirm={handleLogoutAndClear}
        onCancel={handleClearCancel}
      />
    </>
  );
}
