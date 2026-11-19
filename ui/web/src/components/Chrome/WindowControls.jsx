// Minimize / maximize / close for Windows and Linux, where the main window has
// no native title bar (decorations are off, see src-tauri/src/setup.rs). macOS
// keeps its overlaid traffic lights, so this renders nothing there.
//
// Close goes through the window's close request, which Rust turns into the
// same confirm-before-quit dialog as ⌘Q (lib.rs on_window_event).
import { useEffect, useState } from 'react';
import Icon from '../Icon';
import { hasOwnWindowControls } from '../../lib/tauri';
import styles from '../../styles/layout.module.css';

const win = () => import('@tauri-apps/api/window').then(({ getCurrentWindow }) => getCurrentWindow());

export default function WindowControls() {
  const enabled = hasOwnWindowControls();
  const [maximized, setMaximized] = useState(false);

  // The middle button reads "Restore" while the window is maximized. Resize
  // events cover maximize, restore, a double-click on the bar and the WM's own
  // shortcuts, so the label never goes stale.
  useEffect(() => {
    if (!enabled) return undefined;
    let unlisten = null;
    let cancelled = false;
    win().then(async (w) => {
      const sync = () => w.isMaximized().then(setMaximized).catch(() => {});
      sync();
      unlisten = await w.onResized(sync);
      if (cancelled) unlisten();
    });
    return () => { cancelled = true; if (unlisten) unlisten(); };
  }, [enabled]);

  if (!enabled) return null;
  const middle = maximized ? 'Restore' : 'Maximize';
  return (
    <div className={styles.winControls}>
      <button className={styles.winControl} aria-label="Minimize" title="Minimize" onClick={() => win().then((w) => w.minimize())}>
        <Icon name="minus" size={12} />
      </button>
      <button className={styles.winControl} aria-label={middle} title={middle} onClick={() => win().then((w) => w.toggleMaximize())}>
        <Icon name={maximized ? 'macwindow.floating' : 'macwindow'} size={12} />
      </button>
      <button className={`${styles.winControl} ${styles.winControlClose}`} aria-label="Close" title="Close" onClick={() => win().then((w) => w.close())}>
        <Icon name="xmark" size={12} />
      </button>
    </div>
  );
}
