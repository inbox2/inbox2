import { useState } from 'react';
import MgmtModal from './MgmtModal';
import MgmtButton from './MgmtButton';
import styles from './MgmtConfirm.module.css';

/* Management-styled confirm dialog.
 *   danger       — red confirm button (destructive)
 *   confirmText  — when set, the user must type this exact string to enable
 *                  the confirm button (e.g. a domain name before a wipe). */
export default function MgmtConfirm({
  open,
  title,
  message,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  danger = false,
  confirmText,
  busy = false,
  onConfirm,
  onClose,
}) {
  const [typed, setTyped] = useState('');
  const locked = confirmText && typed.trim() !== confirmText;

  const close = () => { setTyped(''); onClose?.(); };

  return (
    <MgmtModal
      open={open}
      onClose={busy ? undefined : close}
      onSubmit={locked || busy ? undefined : onConfirm}
      width={440}
    >
      <h2 className={styles.title}>{title}</h2>
      {message && <p className={styles.message}>{message}</p>}
      {confirmText && (
        <label className={styles.confirmField}>
          <span className={styles.confirmLabel}>Type <strong>{confirmText}</strong> to confirm</span>
          <input
            className={styles.input}
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
            placeholder={confirmText}
            autoFocus
            autoComplete="off"
            spellCheck={false}
          />
        </label>
      )}
      <div className={styles.actions}>
        <button type="button" className={styles.cancel} onClick={close} disabled={busy}>{cancelLabel}</button>
        <MgmtButton
          variant={danger ? 'danger' : 'primary'}
          onClick={onConfirm}
          disabled={locked || busy}
        >
          {busy ? 'Working…' : confirmLabel}
        </MgmtButton>
      </div>
    </MgmtModal>
  );
}
