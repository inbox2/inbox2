// Inline unlock prompt for sealed conversations (docs/E2EE.md Phase F).
// Shown above the message list when sealed content is present but the E2EE
// identity is locked (per-session unlock) or missing (no identity yet —
// point the user at encryption settings).
import { useState } from 'react';
import Icon from '../Icon';
import { unlock } from '../../lib/e2eeStore';
import RecoverKeyModal from './RecoverKeyModal';
import styles from './E2eeUnlock.module.css';

export default function E2eeUnlock({ identityStatus }) {
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [recovering, setRecovering] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    if (!password || busy) return;
    setBusy(true);
    setError(null);
    try {
      await unlock(password);
      setPassword('');
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  };

  if (identityStatus === 'none') {
    return (
      <div className={styles.panel} role="note">
        <Icon name="lock.fill" size={15} />
        <div className={styles.text}>
          <strong>Sealed messages.</strong> You don&apos;t have a key for this conversation yet. Set up
          your key, then ask a teammate with access to share it with you.
        </div>
      </div>
    );
  }

  return (
    <form className={styles.panel} onSubmit={submit}>
      <Icon name="lock.fill" size={15} />
      <div className={styles.text}>
        <strong>Sealed messages.</strong> Enter your password to read this conversation here.
      </div>
      <div className={styles.controls}>
        <input
          type="password"
          className={styles.input}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="Account password"
          aria-label="Account password"
          autoComplete="current-password"
        />
        <button type="submit" className={styles.button} disabled={!password || busy}>
          {busy ? 'Opening…' : 'Open'}
        </button>
      </div>
      {error && (
        <div className={styles.error} role="alert">
          {error} <button type="button" className={styles.link} onClick={() => setRecovering(true)}>Use your recovery phrase</button>
        </div>
      )}
      {recovering && <RecoverKeyModal onClose={() => setRecovering(false)} />}
    </form>
  );
}
