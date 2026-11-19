import { useEffect, useRef } from 'react';
import styles from './MgmtModal.module.css';

/* Management-styled modal: dimmed backdrop + a centred white card. Closes on
 * backdrop click and Escape. The `management` class on the overlay scopes the
 * --m-* tokens so it can be opened from anywhere (not just inside an admin page).
 *
 * Keyboard behaviour (admin popups, see spec): the first input field is focused
 * on open, Escape closes (via onClose), and Enter submits — pass `onSubmit` to
 * opt a form-style popup into Enter-to-confirm. Enter inside a <textarea> still
 * inserts a newline; Shift+Enter never submits. */
export default function MgmtModal({ open, onClose, onSubmit, children, width = 480 }) {
  const cardRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') onClose?.(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  // Focus the first input field once the card is mounted; fall back to the card
  // itself so Enter/Escape still route to the topmost modal when it has no input.
  useEffect(() => {
    if (!open) return;
    const card = cardRef.current;
    if (!card) return;
    const el = card.querySelector(
      'input:not([type="hidden"]):not([disabled]), textarea:not([disabled]), select:not([disabled])'
    );
    (el || card).focus();
  }, [open]);

  if (!open) return null;

  const onKeyDown = (e) => {
    if (e.key !== 'Enter' || e.shiftKey || !onSubmit) return;
    if (e.target.tagName === 'TEXTAREA') return;
    e.preventDefault();
    onSubmit();
  };

  return (
    <div className={`${styles.overlay} management`} onMouseDown={onClose} role="presentation">
      <div
        className={styles.card}
        ref={(el) => {
          cardRef.current = el;
          if (el) el.style.maxWidth = `${width}px`;
        }}
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={onKeyDown}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
      >
        {children}
      </div>
    </div>
  );
}
