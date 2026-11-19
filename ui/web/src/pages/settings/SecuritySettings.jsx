import { useState, useEffect } from 'react';
import api from '../../lib/api';
import Button from '../../components/Button/Button';
import styles from './settings.module.css';

export default function SecuritySettings() {
  const [sessions, setSessions] = useState([]);

  useEffect(() => {
    api.get('/auth/sessions')
      .then(data => setSessions(data.sessions || []))
      .catch(() => { /* load error */ });
  }, []);

  const handleSignOutAll = async () => {
    await api.delete('/auth/sessions');
    const data = await api.get('/auth/sessions');
    setSessions(data.sessions || []);
  };

  return (
    <>
      <h1 className={styles.settingsTitle}>Security &amp; sign-in</h1>
      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Active sessions</div>
        {sessions.length === 0 ? (
          <p>No active sessions</p>
        ) : (
          sessions.map((s, i) => (
            <div key={i} className={styles.settingsField}>
              <label>{s.user_agent || 'Unknown device'}</label>
              <input value={`${s.ip_address} · Last active: ${new Date(s.last_active_at).toLocaleString()}`} disabled />
            </div>
          ))
        )}
        <Button className={styles.settingsButton} onClick={handleSignOutAll}>
          Sign out all other sessions
        </Button>
      </div>
    </>
  );
}
