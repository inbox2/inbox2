import { useState } from 'react';
import { MgmtModal, MgmtButton } from '../../components/management';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './adminShared.module.css';

/* Change the signed-in user's password from the console dropdown. Requires the
 * current password (server re-auths); confirms the new one matches client-side
 * before sending. Mirrors the InviteMxModal shape (shared modal* styles). */

const MIN_LENGTH = 8;

export default function ChangePasswordModal({ onClose }) {
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [keyWarning, setKeyWarning] = useState(false); // the encryption key still opens with the old password
  const [error, setError] = useState('');

  const submit = async () => {
    if (busy) return;
    if (next.length < MIN_LENGTH) { setError(`New password must be at least ${MIN_LENGTH} characters.`); return; }
    if (next !== confirm) { setError("The new passwords don't match."); return; }
    setError('');
    setBusy(true);
    try {
      // The encryption key is wrapped under the password: open it with the old
      // one first, re-wrap under the new one once the change went through.
      const { unwrapForRewrap, hasIdentityKey } = await import('../../lib/e2eeStore');
      const rewrap = await unwrapForRewrap(current).catch(() => null);
      const hasKey = await hasIdentityKey().catch(() => false);
      await api.changePassword({ current_password: current, password: next });
      let rewrapped = !hasKey;
      try {
        if (rewrap) { await rewrap(next); rewrapped = true; }
      } catch (re) {
        log.warn('E2EE', `identity re-wrap after password change failed: ${re?.message || re}`);
      }
      setKeyWarning(!rewrapped);
      // Re-encrypt the credential vault under the new password (docs/E2EE.md), so
      // backed-up tokens stay reachable and an exposed old password can't derive
      // the new key. Desktop-only (runs through the local engine); best-effort.
      try {
        const { isTauri } = await import('../../lib/tauri');
        if (isTauri()) {
          const { invoke } = await import('@tauri-apps/api/core');
          await invoke('rotate_vault', { newPassword: next });
        }
      } catch (re) {
        log.warn('Vault', `rotate after password change failed: ${re?.message || re}`);
      }
      setDone(true);
    } catch (e) {
      log.warn('Admin', `Change password failed: ${e?.message || e}`);
      setError(e?.data?.errors?.[0]?.message || e?.message || "Couldn't change the password.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <MgmtModal open onClose={busy ? undefined : onClose} onSubmit={done ? onClose : (busy ? undefined : submit)} width={460}>
      {done ? (
        <>
          <h2 className={styles.modalTitle}>Password changed</h2>
          <p className={styles.modalSub}>Use your new password next time you sign in.</p>
          {keyWarning && (
            <p className={styles.settingsError}>
              Your encryption key could not be moved to the new password. To open encrypted mail, unlock it with your
              old password or your six-word recovery phrase.
            </p>
          )}
          <div className={styles.modalActions}>
            <MgmtButton variant="primary" onClick={onClose}>Done</MgmtButton>
          </div>
        </>
      ) : (
        <>
          <h2 className={styles.modalTitle}>Change password</h2>
          <p className={styles.modalSub}>Enter your current password, then choose a new one.</p>
          <label className={styles.modalField}>
            <span className={styles.modalLabel}>Current password</span>
            <input
              className={styles.modalInput}
              type="password"
              value={current}
              onChange={(e) => setCurrent(e.target.value)}
              autoComplete="current-password"
              placeholder="Your current password"
            />
          </label>
          <label className={styles.modalField}>
            <span className={styles.modalLabel}>New password</span>
            <input
              className={styles.modalInput}
              type="password"
              value={next}
              onChange={(e) => setNext(e.target.value)}
              autoComplete="new-password"
              placeholder={`At least ${MIN_LENGTH} characters`}
            />
          </label>
          {next && (
            <label className={styles.modalField}>
              <span className={styles.modalLabel}>Confirm new password</span>
              <input
                className={styles.modalInput}
                type="password"
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
                autoComplete="new-password"
                placeholder="Re-enter the new password"
              />
            </label>
          )}
          {error && <p className={styles.modalError}>{error}</p>}
          <div className={styles.modalActions}>
            <MgmtButton variant="glass" className={styles.modalCancel} onClick={onClose}>Cancel</MgmtButton>
            <MgmtButton variant="primary" onClick={submit} disabled={busy || !current || !next || !confirm}>
              {busy ? 'Saving…' : 'Change password'}
            </MgmtButton>
          </div>
        </>
      )}
    </MgmtModal>
  );
}
