import { useState, useEffect } from 'react';
import Button from '../../components/Button/Button';
import useTriage from '../../hooks/useTriage';
import { getSecret, setSecret, clearSecret } from '../../lib/secretStore';
import styles from './settings.module.css';

// Lands as `kv:typesafe_api_key` in app_secrets, which src-tauri loads into the
// engine at startup (setup.rs); set_jev_key applies a change right away.
const JEV_SECRET = 'typesafe_api_key';

const JEV_STATUS = {
  ok: { label: 'Connected', status: 'connected' },
  unauthorized: { label: 'Key rejected', status: 'error' },
  missing: { label: 'Not connected', status: 'idle' },
};

/**
 * Jev by TypeSafe — the triage model for local channels (docs/Triage.md). The
 * user's own key: checked with one real call before it's stored, then pushed
 * to the engine. Status is the engine's `jevStatus` (a 401 flips it to
 * unauthorized until the key changes). Desktop only.
 */
export default function JevKeyCard() {
  const { progress, refreshProgress } = useTriage();
  const [hasKey, setHasKey] = useState(false);
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    let active = true;
    getSecret(JEV_SECRET).then((v) => { if (active) setHasKey(!!v); });
    return () => { active = false; };
  }, []);

  const pushKey = async (key) => {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('set_jev_key', { key });
    await refreshProgress();
  };

  const save = async () => {
    const key = draft.trim();
    if (!key) return;
    setBusy(true);
    setError('');
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('validate_jev_key', { key });
      await setSecret(JEV_SECRET, key);
      await pushKey(key);
      setHasKey(true);
      setDraft('');
    } catch (e) {
      setError(String(e?.message || e));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    setBusy(true);
    setError('');
    try {
      await clearSecret(JEV_SECRET);
      await pushKey(null);
      setHasKey(false);
    } catch (e) {
      setError(String(e?.message || e));
    } finally {
      setBusy(false);
    }
  };

  const status = JEV_STATUS[progress.jevStatus] || (hasKey ? JEV_STATUS.ok : JEV_STATUS.missing);

  return (
    <div className={styles.providerCard}>
      <div className={styles.providerHeader}>
        <img src="/ai/jev.png" alt="" className={styles.providerLogo} />
        <div>
          <h3 className={styles.providerName}>Jev by TypeSafe</h3>
          <p className={styles.providerDesc}>
            Sorts mail from your connected accounts into labels, urgency and Spaces.
            Mail content is sent to TypeSafe to do this.
          </p>
        </div>
        <span className={styles.providerStatus} data-status={status.status}>{status.label}</span>
      </div>
      <div className={styles.settingsField}>
        <label htmlFor="jev-key">API key</label>
        <input
          id="jev-key"
          type="password"
          value={draft}
          onChange={(e) => { setDraft(e.target.value); setError(''); }}
          onKeyDown={(e) => { if (e.key === 'Enter') save(); }}
          placeholder={hasKey ? 'Key saved. Paste a new one to replace it' : 'Paste your TypeSafe API key'}
          autoComplete="off"
        />
      </div>
      {error && <p className={styles.settingsError}>{error}</p>}
      <div className={styles.providerActions}>
        <Button className={styles.settingsButton} onClick={save} disabled={busy || !draft.trim()}>
          {busy ? 'Checking…' : 'Save'}
        </Button>
        {hasKey && (
          <Button variant="danger-link" onClick={remove} disabled={busy}>Remove key</Button>
        )}
      </div>
    </div>
  );
}
