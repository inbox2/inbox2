import { useState, useEffect, useRef } from 'react';
import api from '../../../lib/api';
import useTransientFlag from '../../../hooks/useTransientFlag';
import Icon from '../../../components/Icon';
import Button from '../../../components/Button/Button';
import styles from '../settings.module.css';

export default function OrgPreferences({ orgId }) {
  const [name, setName] = useState('');
  const [timezone, setTimezone] = useState('UTC');
  const [iconUrl, setIconUrl] = useState('');
  const [saved, flashSaved] = useTransientFlag();
  const [uploading, setUploading] = useState(false);
  const fileRef = useRef(null);

  useEffect(() => {
    if (!orgId) return;
    api.getOrg(orgId).then(data => {
      setName(data.organization.name);
      setTimezone(data.organization.timezone || 'UTC');
      setIconUrl(data.organization.icon_url || '');
    }).catch(() => { /* load error */ });
  }, [orgId]);

  const handleSave = async () => {
    await api.patch(`/orgs/${orgId}`, { name, timezone, icon_url: iconUrl || null });
    flashSaved();
  };

  const handleUpload = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setUploading(true);
    try {
      const form = new FormData();
      form.append('file', file);
      const data = await api.upload(`/orgs/${orgId}/icon`, form);
      setIconUrl(data.organization.icon_url || '');
    } catch {
      /* upload error */
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  return (
    <>
      <h1 className={styles.settingsTitle}>Organization settings</h1>
      <div className={styles.settingsField}>
        <label htmlFor="org-name">Name</label>
        <input id="org-name" value={name} onChange={e => setName(e.target.value)} />
      </div>
      <div className={styles.settingsField}>
        <label htmlFor="org-tz">Timezone</label>
        <input id="org-tz" value={timezone} onChange={e => setTimezone(e.target.value)} />
      </div>
      <div className={styles.settingsField}>
        <label>Icon</label>
        <div className={styles.iconUrlRow}>
          {iconUrl && (
            <img
              src={iconUrl}
              alt=""
              width="32"
              height="32"
              className={styles.iconPreview}
              onError={e => { e.target.style.display = 'none'; }}
            />
          )}
          <input
            value={iconUrl}
            onChange={e => setIconUrl(e.target.value)}
            placeholder="https://example.com/icon.png"
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
            onChange={handleUpload}
            hidden
          />
        </div>
      </div>
      <Button className={styles.settingsButton} onClick={handleSave}>
        {saved ? 'Saved' : 'Save changes'}
      </Button>
    </>
  );
}
