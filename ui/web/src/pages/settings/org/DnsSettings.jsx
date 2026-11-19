import { useState, useEffect } from 'react';
import api from '../../../lib/api';
import Button from '../../../components/Button/Button';
import styles from '../settings.module.css';

export default function DnsSettings({ orgId }) {
  const [dns, setDns] = useState(null);

  useEffect(() => {
    if (!orgId) return;
    api.getOrgDns(orgId).then(data => setDns(data)).catch(() => { /* load error */ });
  }, [orgId]);

  const handleVerify = async () => {
    await api.post(`/orgs/${orgId}/dns/verify`);
    const data = await api.getOrgDns(orgId);
    setDns(data);
  };

  if (!dns) return <p>Loading DNS settings…</p>;

  return (
    <>
      <h1 className={styles.settingsTitle}>Domain &amp; DNS</h1>
      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Domain: {dns.domain}</div>
        <p>Status: {dns.status}</p>
        <Button className={styles.settingsButton} onClick={handleVerify}>Re-verify DNS</Button>
      </div>
      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Required DNS records</div>
        {dns.records?.map((record, i) => (
          <div key={i} className={styles.settingsField}>
            <label>{record.type}{record.priority ? ` (priority ${record.priority})` : ''} — {record.host}</label>
            <input value={record.value} disabled />
          </div>
        ))}
      </div>
    </>
  );
}
