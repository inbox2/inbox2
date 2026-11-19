import { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import Icon from '../Icon';
import { shortcutHint } from '../../lib/shortcuts';
import styles from './UndoToast.module.css';

const VARIANT_CLASS = { triage: styles.toastTriage, danger: styles.toastDanger };

// Fallback glyph when an entry doesn't carry an action-specific icon.
const DEFAULT_ICON = 'arrow.uturn.backward';

// Drag past this many px in *either* direction flings the toast away (dismiss
// only — the command stays in history, so Cmd+Z still undoes). Smaller moves
// snap back; anything under TAP_SLOP isn't treated as a drag.
const SWIPE_THRESHOLD = 80;
const TAP_SLOP = 5;
const FLING_MS = 180;
// How long a removed toast stays mounted to play its fade-out before unmounting.
const FADE_MS = 220;

function ToastItem({ entry, leaving, onUndo, onDismiss }) {
  const ref = useRef(null);
  const drag = useRef({ active: false, startX: 0, dx: 0, moved: false });

  const onPointerDown = useCallback((e) => {
    if (e.button !== 0 || e.target.closest('button')) return; // let buttons act
    const d = drag.current;
    d.active = true; d.startX = e.clientX; d.dx = 0; d.moved = false;
    const el = ref.current;
    if (el) { el.style.transition = 'none'; el.setPointerCapture?.(e.pointerId); }
  }, []);

  const onPointerMove = useCallback((e) => {
    const d = drag.current;
    if (!d.active) return;
    d.dx = e.clientX - d.startX;
    if (Math.abs(d.dx) > TAP_SLOP) d.moved = true;
    const el = ref.current;
    if (!el) return;
    // Follows the finger either way; fades with distance from centre.
    el.style.transform = `translateX(${d.dx}px)`;
    el.style.opacity = String(Math.max(0, 1 - Math.abs(d.dx) / (SWIPE_THRESHOLD * 2.2)));
  }, []);

  const settle = useCallback((e) => {
    const d = drag.current;
    if (!d.active) return;
    d.active = false;
    const el = ref.current;
    if (el) el.releasePointerCapture?.(e.pointerId);
    if (!el) return;
    if (Math.abs(d.dx) > SWIPE_THRESHOLD) {
      // Fling off the way it was dragged, then dismiss (command stays — Cmd+Z
      // still undoes).
      const off = (el.offsetWidth + 48) * (d.dx < 0 ? -1 : 1);
      el.style.transition = `transform ${FLING_MS}ms var(--ease-in, ease-in), opacity ${FLING_MS}ms linear`;
      el.style.transform = `translateX(${off}px)`;
      el.style.opacity = '0';
      setTimeout(() => onDismiss(entry.id), FLING_MS - 10);
      return;
    }
    // Snap back into place.
    el.style.transition = 'transform 0.2s var(--ease-out, ease-out), opacity 0.2s linear';
    el.style.transform = '';
    el.style.opacity = '';
  }, [entry.id, onDismiss]);

  return (
    <div
      ref={ref}
      className={`${styles.toast}${VARIANT_CLASS[entry.variant] ? ` ${VARIANT_CLASS[entry.variant]}` : ''}${leaving ? ` ${styles.leaving}` : ''}`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={settle}
      onPointerCancel={settle}
    >
      <span className={styles.iconBadge}>
        <Icon name={entry.icon || DEFAULT_ICON} size={16} />
      </span>
      <span className={styles.message}>{entry.description}</span>
      {/* Notices (a failed action) carry no command — nothing to undo. */}
      {entry.undoable === false ? null : (
        <button className={styles.undoButton} onClick={() => onUndo(entry.id)}>
          Undo
          <kbd className={styles.kbd}>{shortcutHint('undo')}</kbd>
        </button>
      )}
      <button
        className={styles.dismissButton}
        onClick={() => onDismiss(entry.id)}
        aria-label="Dismiss"
      >
        <Icon name="xmark" size={11} />
      </button>
      <div className={styles.progressBar} />
    </div>
  );
}

export default function UndoToast({ entries, onUndo, onDismiss }) {
  // Mirror the store's toasts but keep just-removed ones around (flagged
  // `leaving`) long enough to play a fade-out before unmounting — covers every
  // removal path (auto-dismiss, Undo, dismiss button, swipe).
  const [visible, setVisible] = useState(() => (entries || []).map(e => ({ ...e, leaving: false })));
  const exitTimers = useRef(new Map());

  useEffect(() => {
    const live = entries || [];
    const liveIds = new Set(live.map(e => e.id));
    setVisible((prev) => {
      const result = live.map(e => ({ ...e, leaving: false }));
      // Re-insert any item that vanished from the store at its previous slot and
      // mark it leaving so it fades instead of popping out.
      prev.forEach((it, idx) => {
        if (liveIds.has(it.id)) return;
        if (!exitTimers.current.has(it.id)) {
          const t = setTimeout(() => {
            exitTimers.current.delete(it.id);
            setVisible(cur => cur.filter(x => x.id !== it.id));
          }, FADE_MS);
          exitTimers.current.set(it.id, t);
        }
        result.splice(Math.min(idx, result.length), 0, { ...it, leaving: true });
      });
      return result;
    });
  }, [entries]);

  useEffect(() => {
    const timers = exitTimers.current;
    return () => { for (const t of timers.values()) clearTimeout(t); };
  }, []);

  if (visible.length === 0) return null;

  return createPortal(
    <div className={styles.container}>
      {/* Newest at the bottom: the store lists newest-first, so render reversed
          and let the container anchor to the bottom — older toasts ride up. */}
      {visible.slice().reverse().map(entry => (
        <ToastItem key={entry.id} entry={entry} leaving={entry.leaving} onUndo={onUndo} onDismiss={onDismiss} />
      ))}
    </div>,
    document.body
  );
}
