import { useState, useEffect } from 'react';

/**
 * Manages the `?` keyboard-shortcuts help overlay.
 *
 * Returns `{ helpOpen, setHelpOpen }`. Binds `?` (no modifiers) to open the
 * overlay, ignoring the key while typing in an input/textarea/contentEditable
 * or while another overlay is open (so it does not collide with the command
 * palette or a compose window). Pair with the shared <ShortcutsHelp> component.
 */
export default function useShortcutHelp() {
  const [helpOpen, setHelpOpen] = useState(false);

  useEffect(() => {
    const handler = (e) => {
      if (e.key !== '?' || e.metaKey || e.ctrlKey || e.altKey) return;
      const el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
      if (document.querySelector('[data-overlay-open]')) return;
      e.preventDefault();
      setHelpOpen(true);
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);

  return { helpOpen, setHelpOpen };
}
