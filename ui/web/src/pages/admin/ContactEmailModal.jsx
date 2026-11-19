import { useState } from 'react';
import { MgmtModal, MgmtButton } from '../../components/management';
import useAuth from '../../hooks/useAuth';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './adminShared.module.css';

/* The address for password resets and account notices (docs/TODO.md 48.21). A new
 * one stays pending until the link mailed to it is clicked. */
export default function ContactEmailModal({ onClose }) {
  const { user, refreshAccount } = useAuth();
  const [address, setAddress] = useState('');
  const [busy, setBusy] = useState(false);
  const [sentTo, setSentTo] = useState(null);
  const [warning, setWarning] = useState(null);
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  const waiting = sentTo || user?.pending_billing_email;

  const submit = async () => {
    if (busy || !address.trim()) return;
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const hadPending = user?.pending_billing_email;
      const { account, warnings } = await api.updateContactEmail(address.trim());
      await refreshAccount?.();
      if (account.pending_billing_email) {
        setSentTo(account.pending_billing_email);
        setWarning(warnings?.[0] || null);
      } else {
        // The confirmed address, typed again: nothing to confirm, and any waiting change is off.
        setAddress('');
        setNotice(hadPending ? `You already use this address. We cancelled the change to ${hadPending}.` : 'You already use this address.');
      }
    } catch (e) {
      log.warn('Admin', `Contact email change failed: ${e?.message || e}`);
      setError(e?.data?.errors?.[0]?.message || e?.message || "Couldn't save the address.");
    } finally {
      setBusy(false);
    }
  };

  if (sentTo) {
    return (
      <MgmtModal open onClose={onClose} onSubmit={onClose} width={460}>
        <h2 className={styles.modalTitle}>Check your mail</h2>
        <p className={styles.modalSub}>Click the link we sent to {sentTo}. It works for 24 hours.</p>
        {warning && <p className={styles.settingsError}>{warning}</p>}
        <div className={styles.modalActions}><MgmtButton variant="primary" onClick={onClose} autoFocus>Done</MgmtButton></div>
      </MgmtModal>
    );
  }
  return (
    <MgmtModal open onClose={busy ? undefined : onClose} width={460}>
      <h2 className={styles.modalTitle}>Contact email</h2>
      <p className={styles.modalSub}>We send password resets and account notices here.</p>
      <p className={styles.modalSub}>
        {user?.billing_email ? <code className={styles.emailCode}>{user.billing_email}</code> : 'No address yet.'}
        {waiting && <> Waiting for you to confirm <code className={styles.emailCode}>{waiting}</code>.</>}
      </p>
      <label className={styles.modalField}>
        <span className={styles.modalLabel}>New address</span>
        <input className={styles.modalInput} type="email" value={address} onChange={(e) => setAddress(e.target.value)} autoComplete="email" placeholder="you@example.com"
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); submit(); } }} />
      </label>
      {notice && <p className={styles.modalSub} role="status">{notice}</p>}
      {error && <p className={styles.settingsError}>{error}</p>}
      <div className={styles.modalActions}>
        <MgmtButton variant="ghost" onClick={onClose} disabled={busy}>Cancel</MgmtButton>
        <MgmtButton variant="primary" onClick={submit} disabled={busy || !address.trim()}>Send link</MgmtButton>
      </div>
    </MgmtModal>
  );
}
