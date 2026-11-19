// Key recovery (docs/E2EE.md "Key loss & recovery"): the recovery phrase opens
// the encryption key, which is then locked again with the account password.
// For a key still locked with an older password, or after a password reset.
import { useState } from 'react';
import { MgmtButton, MgmtField, MgmtModal } from '../management';
import { recover } from '../../lib/e2eeStore';
import styles from './RecoverKeyModal.module.css';

export default function RecoverKeyModal({ onClose }) {
  const [passphrase, setPassphrase] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const submit = async () => {
    if (busy || !passphrase.trim() || !password) return;
    setBusy(true);
    setError(null);
    try {
      await recover(passphrase, password);
      onClose();
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  };

  return (
    <MgmtModal open onClose={busy ? undefined : onClose} onSubmit={submit} width={480}>
      <h2 className={styles.title}>Restore your encryption key</h2>
      <p className={styles.text}>
        Use this if your password does not unlock your key. This occurs after a password change or a password reset.
      </p>
      <ol className={styles.steps}>
        <li>Enter the six-word recovery phrase. inbox2 showed it one time, when you made your key. It is not in the recovery email: that email contains only the locked key.</li>
        <li>Enter the password you use now to sign in.</li>
        <li>Select Restore key. Your key is then locked with that password, and it stays open in this tab.</li>
      </ol>
      <MgmtField label="Recovery phrase" value={passphrase} onChange={(e) => setPassphrase(e.target.value)} placeholder="six words" autoComplete="off" spellCheck={false} autoFocus />
      <MgmtField label="Your inbox2 password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <p className={styles.small}>Your files, your mail and your recovery phrase do not change. inbox2 cannot do this for you: it does not have the phrase.</p>
      {error && <p className={styles.error} role="alert">{error}</p>}
      <div className={styles.actions}>
        <MgmtButton variant="glass" onClick={onClose} disabled={busy}>Cancel</MgmtButton>
        <MgmtButton variant="dark" onClick={submit} disabled={busy || !passphrase.trim() || !password}>{busy ? 'Restoring…' : 'Restore key'}</MgmtButton>
      </div>
    </MgmtModal>
  );
}
