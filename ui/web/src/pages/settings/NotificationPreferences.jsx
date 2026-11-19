import { useState, useEffect } from 'react';
import api from '../../lib/api';
import styles from './settings.module.css';

export default function NotificationPreferences() {
  const [prefs, setPrefs] = useState(null);

  useEffect(() => {
    api.get('/notifications/preferences')
      .then(data => setPrefs(data.preferences))
      .catch(() => { /* load error */ });
  }, []);

  if (!prefs) return <p>Loading preferences…</p>;

  return (
    <>
      <h1 className={styles.settingsTitle}>Notification preferences</h1>
      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Email notifications</div>
        {Object.entries(prefs).map(([key, enabled]) => (
          <div key={key} className={styles.settingsField}>
            <label>{key.replace(/_/g, ' ')}: {enabled ? 'Enabled' : 'Disabled'}</label>
          </div>
        ))}
      </div>
    </>
  );
}
