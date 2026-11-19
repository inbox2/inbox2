// Marks the conversation currently shown in a reading pane as read, following
// the user's Outlook-style preference (see lib/markReadPref.js):
//
//   immediate         — mark read as soon as it's displayed
//   delay (default 5s) — mark read after it's been displayed N seconds; the
//                        timer only runs while the window is focused & visible,
//                        and is cancelled if the selection changes first
//   selection-change   — mark the PREVIOUS item read when selection moves off it
//   never              — manual only
//
// `conv` is the displayed conversation as `{ id, read, accountKey }` (or null).
// `markRead(id, accountKey)` performs the actual mutation and must be stable.
import { useEffect, useRef } from 'react';
import useMarkReadPref, { MARK_READ_MODES } from '../lib/markReadPref';

export default function useMarkRead({ conv, enabled = true, markRead }) {
  const { mode, delaySeconds } = useMarkReadPref();

  // Previously displayed item, for selection-change mode.
  const prevRef = useRef(null);

  // Hold markRead in a ref so its identity churning (e.g. it closes over a
  // frequently-changing conversation list) doesn't tear down and restart the
  // dwell timer on every list update.
  const markReadRef = useRef(markRead);
  useEffect(() => { markReadRef.current = markRead; }, [markRead]);

  // Last id auto-marked. If the mutation fails (or a sync reverts it) the item
  // goes unread again, which would restart the dwell timer and re-mark it in a
  // loop — one auto-mark per displayed conversation instead. Single slot, so
  // re-selecting it later (or after a manual mark-unread + moving away) marks
  // again; a manual mark-unread on the item you're reading stays unread.
  const markedRef = useRef(null);
  const doMark = (id, accountKey) => {
    if (markedRef.current === id) return;
    markedRef.current = id;
    markReadRef.current?.(id, accountKey);
  };

  const id = conv?.id ?? null;
  const accountKey = conv?.accountKey;
  const unread = conv ? !conv.read : false;

  useEffect(() => {
    const prev = prevRef.current;
    // Record what's displayed now (used as "previous" on the next change).
    prevRef.current = id ? { id, accountKey, unread } : null;

    if (!enabled || mode === MARK_READ_MODES.NEVER) return;

    if (mode === MARK_READ_MODES.SELECTION_CHANGE) {
      // Selection moved off `prev` → mark it read (if it was still unread).
      if (prev && prev.id !== id && prev.unread) doMark(prev.id, prev.accountKey);
      return;
    }

    // immediate / delay operate on the item displayed now.
    if (!id || !unread) return;

    if (mode === MARK_READ_MODES.IMMEDIATE) {
      doMark(id, accountKey);
      return;
    }

    // delay — focus-gated dwell timer.
    let timer = null;
    const isFocused = () => document.hasFocus() && !document.hidden;
    const start = () => {
      if (timer || !isFocused()) return;
      timer = setTimeout(() => doMark(id, accountKey), delaySeconds * 1000);
    };
    const stop = () => { clearTimeout(timer); timer = null; };
    const onFocusChange = () => { isFocused() ? start() : stop(); };

    start();
    window.addEventListener('focus', onFocusChange);
    window.addEventListener('blur', onFocusChange);
    document.addEventListener('visibilitychange', onFocusChange);
    return () => {
      stop();
      window.removeEventListener('focus', onFocusChange);
      window.removeEventListener('blur', onFocusChange);
      document.removeEventListener('visibilitychange', onFocusChange);
    };
  }, [enabled, mode, delaySeconds, id, accountKey, unread]);
}
