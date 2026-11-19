import { useEffect, useState } from 'react';
import ConfirmDialog from '../ConfirmDialog';
import { isTauri } from '../../lib/tauri';

/**
 * Bridges custom native-menu accelerators (set up in Rust) to app behaviour:
 *   - ⌘Q / window close ("menu:quit-request") → confirm before quitting; the
 *     confirm button is auto-focused so Enter quits.
 * (⌘W is a custom no-op menu item in Rust purely so it doesn't close the single
 * window — nothing to handle here.)
 * Mounted once globally; inert on the web build.
 */
export default function AppMenuBridge() {
  const [quitOpen, setQuitOpen] = useState(false);

  useEffect(() => {
    if (!isTauri()) return;
    let unlistenQuit;
    // Only the main window asks. The global `listen` hears events for every
    // target, so the notification popup (same bundle) would ask too.
    import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
      const win = getCurrentWindow();
      if (win.label !== 'main') return;
      win.listen('menu:quit-request', () => setQuitOpen(true)).then((fn) => { unlistenQuit = fn; });
    });
    return () => { unlistenQuit?.(); };
  }, []);

  const confirmQuit = async () => {
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('quit_app');
    } catch { /* exiting */ }
  };

  return (
    <ConfirmDialog
      open={quitOpen}
      title="Quit Inbox2?"
      confirmLabel="Quit"
      cancelLabel="Cancel"
      variant="danger"
      onConfirm={confirmQuit}
      onCancel={() => setQuitOpen(false)}
    />
  );
}
