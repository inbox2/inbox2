import { useState, useEffect, useCallback } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import { MgmtButton, MgmtField, MgmtSelect, MgmtConfirm } from '../../components/management';
import useCopyToClipboard from '../../hooks/useCopyToClipboard';
import api from '../../lib/api';
import log from '../../lib/log';
import { platformLabel } from '../../lib/deviceLink';
import StoredCredentialsCard from './StoredCredentialsCard';
import styles from './ApiKeysPage.module.css';
import { consolePath } from '../../lib/consoleHost';

/* Personal API keys (A17). Light "management" surface, reached from the console
 * dropdown. Keys are for standalone / headless clients (scripts, the MCP server,
 * a desktop install that never did an MX login). A client signed in via MX login
 * already authenticates with its session token and needs no key. */

// Scope presets map to ApiKey::SCOPES (read / write) on the server.
const SCOPE_PRESETS = [
  { value: 'rw', label: 'Read & write', scopes: ['read', 'write'] },
  { value: 'ro', label: 'Read only', scopes: ['read'] },
];

function scopeLabel(scopes) {
  if (!scopes || scopes.length === 0) return 'Full access';
  if (scopes.includes('write')) return 'Read & write';
  if (scopes.includes('read')) return 'Read only';
  return scopes.join(', ');
}

function fmtDate(iso) {
  if (!iso) return null;
  try {
    return new Date(iso).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  } catch {
    return null;
  }
}

export default function ApiKeysPage() {
  const navigate = useNavigate();
  const [keys, setKeys] = useState(null); // null = loading
  const [error, setError] = useState('');

  // Create form.
  const [name, setName] = useState('');
  const [preset, setPreset] = useState('rw');
  const [creating, setCreating] = useState(false);

  // One-time reveal of a freshly minted secret.
  const [revealed, setRevealed] = useState(null); // { name, token }
  const [copied, copy] = useCopyToClipboard();

  // Revoke confirm.
  const [revoking, setRevoking] = useState(null); // the key object pending confirm
  const [revokeBusy, setRevokeBusy] = useState(false);

  const load = useCallback(() => {
    api.listApiKeys()
      .then((res) => setKeys(res.api_keys || []))
      .catch((e) => { log.warn('ApiKeys', `load failed: ${e?.message || e}`); setKeys([]); setError("Couldn't load your API keys."); });
  }, []);

  useEffect(() => { load(); }, [load]);

  const create = useCallback(async () => {
    const trimmed = name.trim();
    if (!trimmed || creating) return;
    setCreating(true);
    setError('');
    try {
      const scopes = SCOPE_PRESETS.find((p) => p.value === preset)?.scopes || ['read', 'write'];
      const res = await api.createApiKey({ name: trimmed, scopes });
      setRevealed({ name: res.api_key?.name || trimmed, token: res.token });
      setName('');
      setKeys((prev) => [res.api_key, ...(prev || [])]);
    } catch (e) {
      setError(e?.data?.errors?.[0]?.message || e?.message || "Couldn't create the key.");
    } finally {
      setCreating(false);
    }
  }, [name, preset, creating]);

  const copyToken = useCallback(() => {
    if (!revealed?.token) return;
    copy(revealed.token);
  }, [revealed, copy]);

  // Split device-link keys (shown as "Linked devices") from manually-created keys.
  const deviceKeys = (keys || []).filter((k) => k.device_platform);
  const plainKeys = (keys || []).filter((k) => !k.device_platform);

  const confirmRevoke = useCallback(async () => {
    if (!revoking) return;
    setRevokeBusy(true);
    try {
      await api.revokeApiKey(revoking.id);
      setKeys((prev) => (prev || []).filter((k) => k.id !== revoking.id));
      setRevoking(null);
    } catch (e) {
      setError(e?.message || "Couldn't revoke the key.");
    } finally {
      setRevokeBusy(false);
    }
  }, [revoking]);

  return (
    <div className={`${styles.page} management`}>
      <header className={styles.head}>
        <button type="button" className={styles.back} onClick={() => navigate(consolePath())}>
          <Icon name="chevron.left" size={14} /> Console
        </button>
        <div className={styles.headText}>
          <h1 className={styles.headTitle}>API keys</h1>
          <span className={styles.headSub}>Personal tokens for scripts &amp; standalone clients</span>
        </div>
      </header>

      <div>
        <div className={styles.panel}>
          {/* Reveal banner — shown once, right after creation. */}
          {revealed && (
            <div className={styles.reveal} role="status">
              <div className={styles.revealHead}>
                <Icon name="checkmark.circle.fill" size={16} />
                <span>Key “{revealed.name}” created. Copy it now, you won’t see it again.</span>
              </div>
              <div className={styles.revealRow}>
                <code className={styles.revealToken}>{revealed.token}</code>
                <MgmtButton variant="dark" onClick={copyToken}>
                  <Icon name={copied ? 'checkmark' : 'doc.on.doc'} size={13} /> {copied ? 'Copied' : 'Copy'}
                </MgmtButton>
              </div>
              <button type="button" className={styles.revealDismiss} onClick={() => setRevealed(null)}>Done</button>
            </div>
          )}

          {/* Create form. */}
          <section className={styles.section}>
            <h2 className={styles.sectionTitle}>Create a key</h2>
            <p className={styles.hint}>
              Scripts, the MCP server and standalone clients sign in with a key.
              Apps you’ve signed in to with your domain login don’t need one.
            </p>
            <div className={styles.createRow}>
              <MgmtField
                className={styles.nameField}
                label="Name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="e.g. Backup script"
                autoComplete="off"
                onKeyDown={(e) => { if (e.key === 'Enter') create(); }}
              />
              <MgmtSelect
                className={styles.scopeField}
                label="Access"
                value={preset}
                onChange={(e) => setPreset(e.target.value)}
                options={SCOPE_PRESETS}
              />
              <MgmtButton variant="primary" onClick={create} disabled={!name.trim() || creating}>
                {creating ? 'Creating…' : 'Create key'}
              </MgmtButton>
            </div>
            {error && <p className={styles.error}>{error}</p>}
          </section>

          {/* Linked devices — keys minted by the device-link flow (desktop/mobile
              "Link to inbox2 account"). Revoking one signs that device out. */}
          {deviceKeys.length > 0 && (
            <section className={styles.section}>
              <h2 className={styles.sectionTitle}>Linked devices</h2>
              <ul className={styles.list}>
                {deviceKeys.map((k) => {
                  const last = fmtDate(k.last_used_at);
                  const linked = fmtDate(k.created_at);
                  return (
                    <li key={k.id} className={styles.row}>
                      <div className={styles.rowMain}>
                        <span className={styles.keyName}>{k.name}</span>
                        <span className={styles.scopeBadge}>{platformLabel(k.device_platform)}</span>
                      </div>
                      <div className={styles.rowMeta}>
                        <span>{last ? `Last active ${last}` : 'Never active'}</span>
                        {linked && <span>· Linked {linked}</span>}
                      </div>
                      <MgmtButton variant="ghost" className={styles.revokeBtn} onClick={() => setRevoking(k)}>
                        Unlink
                      </MgmtButton>
                    </li>
                  );
                })}
              </ul>
            </section>
          )}

          {/* Saved logins (zero-knowledge credential vault — docs/E2EE.md). */}
          <StoredCredentialsCard />

          {/* Key list. */}
          <section className={styles.section}>
            <h2 className={styles.sectionTitle}>Your keys</h2>
            {keys === null ? (
              <div className={styles.loading}><Spinner size={20} color="var(--m-violet)" /></div>
            ) : plainKeys.length === 0 ? (
              <p className={styles.empty}>No API keys yet. Create one above.</p>
            ) : (
              <ul className={styles.list}>
                {plainKeys.map((k) => {
                  const last = fmtDate(k.last_used_at);
                  const created = fmtDate(k.created_at);
                  const expires = fmtDate(k.expires_at);
                  return (
                    <li key={k.id} className={styles.row}>
                      <div className={styles.rowMain}>
                        <span className={styles.keyName}>{k.name}</span>
                        <code className={styles.keyPrefix}>{k.prefix}…</code>
                        <span className={styles.scopeBadge}>{scopeLabel(k.scopes)}</span>
                      </div>
                      <div className={styles.rowMeta}>
                        <span>{last ? `Last used ${last}` : 'Never used'}</span>
                        {created && <span>· Created {created}</span>}
                        {expires && <span>· Expires {expires}</span>}
                      </div>
                      <MgmtButton variant="ghost" className={styles.revokeBtn} onClick={() => setRevoking(k)}>
                        Revoke
                      </MgmtButton>
                    </li>
                  );
                })}
              </ul>
            )}
          </section>
        </div>
      </div>

      <MgmtConfirm
        open={!!revoking}
        title="Revoke this key?"
        message={revoking ? `“${revoking.name}” stops working right away. Anything that uses it needs a new key.` : ''}
        confirmLabel="Revoke key"
        danger
        busy={revokeBusy}
        onConfirm={confirmRevoke}
        onClose={() => setRevoking(null)}
      />
    </div>
  );
}
