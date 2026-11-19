import { useState, useEffect, useCallback } from 'react';
import { MgmtModal, MgmtButton, MgmtConfirm, MgmtCheckbox } from '../../components/management';
import Icon from '../../components/Icon';
import api from '../../lib/api';
import log from '../../lib/log';
import { passkeysSupported, createPasskey, isPasskeyCancel } from '../../lib/passkeys';
import styles from './adminShared.module.css';

/* Manage the signed-in user's passkeys from the console dropdown: list, add
 * (the browser runs the ceremony), remove. A passkey signs in on its own from
 * the login page — no username, password or 2FA code. */

export default function PasskeysModal({ onClose }) {
  const [passkeys, setPasskeys] = useState(null);
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [removing, setRemoving] = useState(null);
  // Adding needs the password unless you just signed in (null = not asked yet).
  const [addPassword, setAddPassword] = useState(null);
  const [required, setRequired] = useState(false);
  // Turning the requirement off needs the password again (null = not asking).
  const [offPassword, setOffPassword] = useState(null);
  const supported = passkeysSupported();

  const load = useCallback(() => api.listPasskeys()
    .then((data) => { setPasskeys(data.credentials || []); setRequired(!!data.required); })
      .catch((e) => { setError(e?.message || "Couldn't load your passkeys."); }), []);

  useEffect(() => { load(); }, [load]);

  const add = async () => {
    if (busy || !supported) return;
    setError('');
    setBusy(true);
    try {
      await createPasskey(name.trim(), addPassword || undefined);
      setName('');
      setAddPassword(null);
      await load();
    } catch (e) {
      if (e?.status === 401) {
        // First refusal just reveals the field; after that the password was wrong.
        if (addPassword === null) setAddPassword('');
        else setError('That password is not right.');
      } else if (!isPasskeyCancel(e)) {
        log.warn('Admin', `Add passkey failed: ${e?.message || e}`);
        // InvalidStateError = this authenticator already holds one of our passkeys.
        setError(e?.name === 'InvalidStateError'
          ? 'This device already has a passkey for your account.'
          : (e?.message || "Couldn't add the passkey."));
      }
    } finally {
      setBusy(false);
    }
  };

  const confirmRemove = async () => {
    const { id } = removing;
    setRemoving(null);
    setError('');
    try {
      await api.deletePasskey(id);
      await load();
    } catch (e) {
      setError(e?.message || "Couldn't remove the passkey.");
    }
  };

  // Turning it on: the server refuses without a fallback and says why. Turning
  // it off is a downgrade, so ask for the password first.
  const toggleRequired = async (next) => {
    setError('');
    if (!next && offPassword === null) { setOffPassword(''); return; }
    try {
      const data = await api.setPasskeyRequired(next, offPassword || undefined);
      setRequired(!!data.required);
      setOffPassword(null);
    } catch (e) {
      setError(e?.message || "Couldn't change that setting.");
    }
  };

  return (
    <>
    {/* Escape belongs to the confirm while it is up, so it doesn't close both. */}
    <MgmtModal open onClose={busy || removing ? undefined : onClose} width={460}>
      <h2 className={styles.modalTitle}>Passkeys</h2>
      <p className={styles.modalSub}>
        Sign in with your fingerprint, face or device PIN instead of a password.
      </p>

      {passkeys?.length === 0 && <p className={styles.modalSub}>No passkeys yet.</p>}
      {passkeys?.map((p) => (
        <div key={p.id} className={styles.passkeyRow}>
          <Icon name="key" size={15} />
          <span className={styles.passkeyName}>{p.nickname}</span>
          <span className={styles.passkeyDate}>Added {new Date(p.created_at).toLocaleDateString()}</span>
          <MgmtButton variant="glass" size="sm" onClick={() => setRemoving(p)} aria-label={`Remove ${p.nickname}`}>
            Remove
          </MgmtButton>
        </div>
      ))}

      {passkeys?.length > 0 && (
        <label className={styles.passkeyToggle}>
          <MgmtCheckbox
            
            checked={required}
            onChange={(e) => (offPassword !== null ? setOffPassword(null) : toggleRequired(e.target.checked))}
          />
          <span>
            Don&apos;t allow password-only sign-in
            <em>After your password you&apos;ll also need a passkey (or your authenticator code, if you use one). Needs a backup first — a second passkey or an authenticator app — so a lost device can&apos;t lock you out.</em>
          </span>
        </label>
      )}
      {offPassword !== null && (
        <div className={styles.modalField}>
          <label className={styles.modalLabel} htmlFor="passkey-off-password">Enter your password to turn this off</label>
          <input
            id="passkey-off-password"
            className={styles.modalInput}
            type="password"
            value={offPassword}
            onChange={(e) => setOffPassword(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && offPassword) toggleRequired(false); }}
            autoComplete="current-password"
            placeholder="Your password"
          />
          <div className={styles.passkeyOffActions}>
            <MgmtButton variant="glass" size="sm" onClick={() => setOffPassword(null)}>Keep it on</MgmtButton>
            <MgmtButton variant="danger" size="sm" onClick={() => toggleRequired(false)} disabled={!offPassword}>Turn off</MgmtButton>
          </div>
        </div>
      )}

      {supported ? (
        <label className={styles.modalField}>
          <span className={styles.modalLabel}>Name for a new passkey</span>
          <input
            className={styles.modalInput}
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') add(); }}
            placeholder="e.g. MacBook, iPhone, YubiKey"
            maxLength={60}
          />
        </label>
      ) : (
        <p className={styles.modalSub}>This browser doesn&apos;t support passkeys.</p>
      )}
      {supported && addPassword !== null && (
        <label className={styles.modalField}>
          <span className={styles.modalLabel}>Enter your password to add a passkey</span>
          <input
            className={styles.modalInput}
            type="password"
            value={addPassword}
            onChange={(e) => setAddPassword(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') add(); }}
            autoComplete="current-password"
            placeholder="Your password"
            autoFocus
          />
        </label>
      )}
      {error && <p className={styles.modalError}>{error}</p>}
      <div className={styles.modalActions}>
        <MgmtButton variant="glass" className={styles.modalCancel} onClick={onClose}>Done</MgmtButton>
        {supported && (
          <MgmtButton variant="primary" onClick={add} disabled={busy || addPassword === ''}>
            {busy ? 'Waiting for your device…' : 'Add a passkey'}
          </MgmtButton>
        )}
      </div>
    </MgmtModal>
    <MgmtConfirm
      open={!!removing}
      title="Remove passkey?"
      message={removing ? `"${removing.nickname}" will stop working for sign-in. You can add it again later.` : ''}
      confirmLabel="Remove"
      danger
      onConfirm={confirmRemove}
      onClose={() => setRemoving(null)}
    />
    </>
  );
}
