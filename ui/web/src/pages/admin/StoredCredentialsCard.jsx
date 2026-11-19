import { useState, useEffect, useCallback } from 'react';
import Spinner from '../../components/Spinner';
import { MgmtButton, MgmtField, MgmtConfirm } from '../../components/management';
import { providerIcon } from '../../lib/providerTypes';
import { isTauri } from '../../lib/tauri';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './ApiKeysPage.module.css';

// Management card for the zero-knowledge credential vault (docs/E2EE.md). Lists
// the channel credentials backed up to the user's inbox2 account (metadata only —
// the server never holds a usable key), and on desktop exposes the vault controls
// (enable / unlock / restore / disable) which run through the local engine.
export default function StoredCredentialsCard() {
  const [creds, setCreds] = useState(null);
  const [status, setStatus] = useState(null); // { enabled, unlocked, account_count }
  const [error, setError] = useState(null);
  const [removing, setRemoving] = useState(null);
  // Inline password prompt: { action: 'enable'|'unlock'|'restore', value, busy }
  const [prompt, setPrompt] = useState(null);
  const desktop = isTauri();

  // .then-style (not async) so setState only happens in deferred callbacks — keeps
  // the load effect off React's synchronous-setState path.
  const load = useCallback(() => {
    api.listStoredCredentials()
      .then((d) => setCreds(d.stored_credentials || []))
      .catch((e) => { log.warn('Vault', `list failed: ${e?.message || e}`); setCreds([]); });
    if (desktop) {
      import('@tauri-apps/api/core')
        .then(({ invoke }) => invoke('vault_status'))
        .then((s) => setStatus(s))
        .catch(() => { /* engine not reachable */ });
    }
  }, [desktop]);

  useEffect(() => { load(); }, [load]);

  const runVault = async (cmd, args) => {
    const { invoke } = await import('@tauri-apps/api/core');
    return invoke(cmd, args);
  };

  const submitPrompt = async () => {
    if (!prompt?.value) return;
    setPrompt((p) => ({ ...p, busy: true }));
    setError(null);
    try {
      if (prompt.action === 'enable') await runVault('enable_cloud_backup', { password: prompt.value });
      else if (prompt.action === 'unlock') await runVault('unlock_vault', { password: prompt.value });
      else if (prompt.action === 'restore') {
        const n = await runVault('restore_from_cloud', { password: prompt.value });
        log.info('Vault', `restored ${n} account(s)`);
      }
      setPrompt(null);
      await load();
    } catch (e) {
      setError(typeof e === 'string' ? e : (e?.message || 'Vault operation failed'));
      setPrompt((p) => ({ ...p, busy: false }));
    }
  };

  const disable = async () => {
    setError(null);
    try { await runVault('disable_cloud_backup'); await load(); }
    catch (e) { setError(e?.message || "Couldn't turn off cloud backup"); }
  };

  const confirmRemove = async () => {
    const k = removing.key;
    setRemoving(null);
    try { await api.deleteStoredCredential(k); await load(); }
    catch (e) { setError(e?.message || "Couldn't remove credential"); }
  };

  if (creds === null) {
    return (
      <section className={styles.section}>
        <h2 className={styles.sectionTitle}>Saved logins</h2>
        <div className={styles.loading}><Spinner size={20} color="var(--m-violet)" /></div>
      </section>
    );
  }

  return (
    <section className={styles.section}>
      <h2 className={styles.sectionTitle}>Saved logins (encrypted)</h2>
      <p className={styles.sectionHint}>
        Your account logins, encrypted and backed up to inbox2. Only your devices can read them.
        Sign in on a new device to get your accounts back.
      </p>

      {error && <p className={styles.error}>{error}</p>}

      {creds.length === 0 ? (
        <p className={styles.sectionHint}>No saved logins yet.</p>
      ) : (
        <ul className={styles.list}>
          {creds.map((c) => (
            <li key={c.id} className={styles.row}>
              <div className={styles.rowMain}>
                <img src={providerIcon(c.provider)} alt={c.provider} width="22" height="22" />
                <span className={styles.keyName}>{c.external_email}</span>
              </div>
              <div className={styles.rowMeta}><span>{c.provider}</span></div>
              <MgmtButton variant="ghost" className={styles.revokeBtn} onClick={() => setRemoving(c)}>
                Remove
              </MgmtButton>
            </li>
          ))}
        </ul>
      )}

      {/* Vault controls — desktop only (they run through the local sync engine). */}
      {desktop && status && (
        <div className={styles.vaultControls}>
          {!status.enabled && (
            <MgmtButton variant="primary" onClick={() => setPrompt({ action: 'enable', value: '' })}>
              Turn on cloud backup
            </MgmtButton>
          )}
          {status.enabled && !status.unlocked && (
            <MgmtButton variant="primary" onClick={() => setPrompt({ action: 'unlock', value: '' })}>
              Use on this device
            </MgmtButton>
          )}
          {creds.length > 0 && (
            <MgmtButton variant="dark" onClick={() => setPrompt({ action: 'restore', value: '' })}>
              Restore on this device
            </MgmtButton>
          )}
          {status.enabled && (
            <MgmtButton variant="ghost" onClick={disable}>Turn off cloud backup</MgmtButton>
          )}
        </div>
      )}

      {prompt && (
        <div className={styles.vaultPrompt}>
          <MgmtField
            type="password"
            label="Your inbox2 password"
            value={prompt.value}
            autoFocus
            onChange={(e) => setPrompt((p) => ({ ...p, value: e.target.value }))}
            onKeyDown={(e) => { if (e.key === 'Enter') submitPrompt(); }}
          />
          <div className={styles.vaultControls}>
            <MgmtButton variant="primary" onClick={submitPrompt} disabled={!prompt.value || prompt.busy}>
              {prompt.busy ? 'Working…' : 'Continue'}
            </MgmtButton>
            <MgmtButton variant="ghost" onClick={() => setPrompt(null)}>Cancel</MgmtButton>
          </div>
        </div>
      )}

      <MgmtConfirm
        open={!!removing}
        title="Remove saved login?"
        message={removing ? `Delete the encrypted backup for ${removing.external_email}? New devices won’t get it back. The account keeps working here.` : ''}
        confirmLabel="Remove"
        danger
        onConfirm={confirmRemove}
        onClose={() => setRemoving(null)}
      />
    </section>
  );
}
