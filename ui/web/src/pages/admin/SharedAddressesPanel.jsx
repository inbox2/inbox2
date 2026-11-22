// Shared addresses tab (address folders): the domain's shared addresses
// (info@, support@). Each one is a folder for the people who can read it.
// PUT replaces the whole list, so every change sends the full list back.
// The parent keys this panel by domain: a new domain starts from a fresh load.
import { useCallback, useEffect, useState } from 'react';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import IconButton from '../../components/IconButton';
import { MgmtButton } from '../../components/management';
import api from '../../lib/api';
import log from '../../lib/log';
import admin from './adminShared.module.css';
import styles from './DomainSettingsPage.module.css';
import css from './SharedAddressesPanel.module.css';

export default function SharedAddressesPanel({ domain }) {
  const path = `/orgs/${domain.orgKey}/domains/${domain.domainKey}/shared-addresses`;
  const [list, setList] = useState(null); // null = loading
  const [names, setNames] = useState({}); // display-name drafts by local_part
  const [local, setLocal] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  // Load failed: PUT replaces the whole list, so no writes until it loads.
  const [loadFailed, setLoadFailed] = useState(false);

  const apply = (res) => {
    const next = res.shared_addresses || [];
    setList(next);
    setNames(Object.fromEntries(next.map((a) => [a.local_part, a.display_name || ''])));
  };

  useEffect(() => {
    let cancelled = false;
    api.get(path)
      .then((res) => { if (!cancelled) apply(res); })
      .catch((e) => {
        log.warn('SharedAddresses', `load failed: ${e?.message || e}`);
        if (!cancelled) setLoadFailed(true);
      });
    return () => { cancelled = true; };
  }, [path]);

  const save = useCallback(async (next) => {
    setBusy(true);
    setError(null);
    try {
      apply(await api.put(path, { shared_addresses: next }));
      return true;
    } catch (e) {
      setError(e?.message || "Couldn't save the shared addresses.");
      return false;
    } finally {
      setBusy(false);
    }
  }, [path]);

  const current = () => (list || []).map((a) => ({ local_part: a.local_part, display_name: a.display_name || '' }));

  const add = async () => {
    const [lp, host] = local.trim().toLowerCase().split('@');
    if (!lp) return;
    if (host && host !== domain.name.toLowerCase()) {
      setError(`Only addresses on ${domain.name} go here.`);
      return;
    }
    if (await save([...current(), { local_part: lp, display_name: '' }])) setLocal('');
  };
  const remove = (lp) => save(current().filter((a) => a.local_part !== lp));
  const rename = (lp) => {
    const name = (names[lp] || '').trim();
    const row = (list || []).find((a) => a.local_part === lp);
    if (!row || name === (row.display_name || '')) return;
    save(current().map((a) => (a.local_part === lp ? { ...a, display_name: name } : a)));
  };

  if (loadFailed) {
    return (
      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>Shared addresses</h2>
        <p className={admin.settingsError} role="alert">
          <Icon name="exclamationmark.triangle.fill" size={13} /> Couldn&apos;t load the shared addresses. Reload the page to try again.
        </p>
      </div>
    );
  }
  if (list === null) return <div className={styles.loading}><Spinner size={22} color="var(--violet)" /></div>;

  return (
    <div className={styles.section}>
      <h2 className={styles.sectionTitle}>Shared addresses</h2>
      <p className={css.intro}>
        Each shared address is a folder for the people who can read it. Mail to any other address that is not a
        person&apos;s own address, or one they can reply as, goes to the Other folder.
      </p>

      {error && (
        <p className={admin.settingsError} role="alert">
          <Icon name="exclamationmark.triangle.fill" size={13} /> {error}
        </p>
      )}

      <div className={css.scroll}>
      <table className={css.table}>
        <thead>
          <tr>
            <th scope="col">Address</th>
            <th scope="col">Who replies</th>
            <th scope="col">Display name</th>
            <th scope="col"><span className={css.srOnly}>Remove</span></th>
          </tr>
        </thead>
        <tbody>
          {list.length === 0 && (
            <tr><td colSpan={4} className={css.empty}>No shared addresses yet.</td></tr>
          )}
          {list.map((a) => (
            <tr key={a.local_part}>
              <th scope="row" className={css.addr}>{a.local_part}@</th>
              <td className={css.repliers}>{a.repliers?.length ? a.repliers.join(', ') : 'Nobody yet'}</td>
              <td>
                <input className={[admin.modalInput, css.nameInput].join(' ')} value={names[a.local_part] ?? ''}
                  placeholder="None" aria-label={`Display name for ${a.address}`} disabled={busy}
                  onChange={(e) => setNames((n) => ({ ...n, [a.local_part]: e.target.value }))}
                  onBlur={() => rename(a.local_part)}
                  onKeyDown={(e) => { if (e.key === 'Enter') rename(a.local_part); }} />
              </td>
              <td className={css.actions}>
                <IconButton className={admin.personAction} icon="xmark" iconSize={11} disabled={busy}
                  onClick={() => remove(a.local_part)} title={`Remove ${a.address}`} aria-label={`Remove ${a.address}`} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      </div>

      <div className={css.addRow}>
        <input className={[admin.modalInput, css.localInput].join(' ')} value={local} placeholder="info"
          aria-label="Address name" disabled={busy}
          onChange={(e) => setLocal(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') add(); }} />
        <span className={css.suffix}>@{domain.name}</span>
        <MgmtButton variant="glass" size="sm" onClick={add} disabled={busy || !local.trim()}>
          <Icon name="plus" size={13} /> Add address
        </MgmtButton>
      </div>
    </div>
  );
}
