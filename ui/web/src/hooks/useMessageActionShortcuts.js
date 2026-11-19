import { useEffect, useRef } from 'react';
import { matchShortcut } from '../lib/shortcuts';

/**
 * Keyboard shortcuts for actions on the currently selected conversation.
 *
 * Wired into the channel view (InboxPage), the unified list view, and the
 * search results view. Each view supplies the callbacks it supports — an id
 * whose callback is absent is silently ignored (e.g. search omits
 * status/triage). Delete/trash is intentionally NOT handled here; it stays in
 * useInboxKeyboardNav (Backspace/Delete) to avoid double-binding.
 *
 * @param {object}   opts
 * @param {object}   opts.conversation   currently selected conversation (or null)
 * @param {boolean}  [opts.enabled=true]  gate (e.g. unified list-mode only)
 * @param {function} [opts.onStatusAction] (action) => void — 'archive'|'spam'|'mark_read'|'mark_unread'
 * @param {function} [opts.onTriage]       (quadrantKey|null) => void
 * @param {object}   opts.draftActions    { reply, replyAll, forward } from useDraftActions
 */
export default function useMessageActionShortcuts({
  conversation,
  enabled = true,
  onStatusAction,
  onTriage,
  draftActions,
}) {
  // Keep latest values in a ref so the listener stays stable across renders.
  const ref = useRef();
  useEffect(() => {
    ref.current = { conversation, enabled, onStatusAction, onTriage, draftActions };
  });

  useEffect(() => {
    const shouldIgnore = () => {
      const el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return true;
      // Any open overlay (modal, command palette, compose popup) swallows shortcuts.
      if (document.querySelector('[data-overlay-open]')) return true;
      return false;
    };

    const handler = (e) => {
      const { conversation: conv, enabled: on, onStatusAction: status, onTriage: triage, draftActions: drafts } = ref.current;
      if (!on || !conv || shouldIgnore()) return;

      const id = matchShortcut(e);
      if (!id) return;

      // Resolve whether we can actually handle this id with the supplied callbacks.
      let handled = true;
      switch (id) {
        case 'reply': drafts?.reply(); break;
        case 'reply-all': drafts?.replyAll(); break;
        case 'forward': drafts?.forward(); break;
        case 'archive':
        case 'spam':
        case 'mark_read':
        case 'mark_unread':
          if (status) status(id); else handled = false;
          break;
        default:
          if (id.startsWith('triage_')) {
            if (triage) triage(id === 'triage_clear' ? null : id.slice('triage_'.length));
            else handled = false;
          } else {
            handled = false;
          }
      }

      if (handled) e.preventDefault();
    };

    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);
}
