import { useState, useEffect, useCallback } from 'react';
import api from '../../../lib/api';
import Button from '../../../components/Button/Button';
import styles from '../settings.module.css';

const LISTS = [
  { kind: 'blocklist', title: 'Block list', label: 'Block address or domain', placeholder: 'spammer@evil.com', button: 'Add to blocklist' },
  { kind: 'allowlist', title: 'Allow list', label: 'Trust address or domain', placeholder: 'trusted@good.com', button: 'Add to allowlist' },
  {
    kind: 'junk', title: 'Marked as spam', label: 'Send address or domain to spam', placeholder: 'security@facebookmail.com', button: 'Add to spam list',
    blurb: 'Senders your team marked as spam. Their mail still arrives and lands in Spam.',
  },
];

export default function SpamSettings({ orgId }) {
  return (
    <>
      <h1 className={styles.settingsTitle}>Spam &amp; filtering</h1>
      {LISTS.map(list => <FilterSection key={list.kind} orgId={orgId} {...list} />)}
    </>
  );
}

// One filter kind: two full-width panels side by side — the add form on the
// left, the current entries scrolling on the right with remove-as-link rows.
function FilterSection({ orgId, kind, title, label, placeholder, button, blurb }) {
  const [filters, setFilters] = useState([]);
  const [value, setValue] = useState('');
  const [error, setError] = useState(null);

  const load = useCallback(
    () => api.get(`/orgs/${orgId}/filters?kind=${kind}`).then(d => setFilters(d.filters)).catch(() => { /* load error */ }),
    [orgId, kind],
  );

  useEffect(() => { if (orgId) load(); }, [orgId, load]);

  const handleAdd = async () => {
    const v = value.trim();
    if (!v) return;
    // An address (name@domain.com) or a bare domain (domain.com) — mirrors the
    // MailFilter::VALUE_FORMAT validation on the API.
    if (!/^(?:[^\s@]+@)?[^\s@.]+(?:\.[^\s@.]+)+$/.test(v)) {
      setError('Enter an email address or a domain, like name@domain.com or domain.com.');
      return;
    }
    setError(null);
    await api.post(`/orgs/${orgId}/filters`, { kind, value: kind === 'junk' ? v.toLowerCase() : v });
    setValue('');
    load();
  };

  const handleRemove = async (id) => {
    await api.delete(`/orgs/${orgId}/filters/${id}`);
    load();
  };

  return (
    <div className={styles.settingsSection}>
      <div className={styles.settingsSectionTitle}>{title} ({filters.length})</div>
      <div className={styles.prefGrid}>
        <section className={styles.settingsPanel}>
          {blurb && <p>{blurb}</p>}
          <div className={styles.settingsField}>
            <label htmlFor={`${kind}-value`}>{label}</label>
            <input
              id={`${kind}-value`}
              value={value}
              onChange={e => { setValue(e.target.value); setError(null); }}
              onKeyDown={e => { if (e.key === 'Enter') handleAdd(); }}
              placeholder={placeholder}
            />
          </div>
          {error && <p className={styles.filterError}>{error}</p>}
          <Button className={styles.settingsButton} onClick={handleAdd}>{button}</Button>
        </section>
        <section className={styles.settingsPanel}>
          <div className={styles.filterScroll}>
            {filters.length === 0 && <div className={styles.filterEmpty}>No entries yet.</div>}
            {filters.map(f => (
              <div key={f.id} className={styles.filterRow}>
                <span className={styles.filterValue}>{f.value}</span>
                <button type="button" className={styles.filterRemove} onClick={() => handleRemove(f.id)}>
                  Remove
                </button>
              </div>
            ))}
          </div>
        </section>
      </div>
    </div>
  );
}
