import { useEffect, useRef, useState } from 'react';
import useAuth from '../../hooks/useAuth';
import usePaneMode, { PANE_MODE, paneModeIcon } from '../../hooks/usePaneMode';
import { PaneModeMenu } from '../PaneMode/PaneMode';
import Icon from '../Icon';
import { TOUCH_STRIP_MODE } from '../../lib/storageKeys';
import { STRIP_WIDGETS, useStripConfig, loadRemoteStripConfig } from '../../lib/touchStrip';
import { WIDGET_COMPONENTS as COMPONENTS } from './widgetMap';
import StripCustomize from './StripCustomize';
import styles from './TouchStrip.module.css';

// The Touch Strip — the app-wide bottom bar (docs/Touch-Strip.md), a nod to the
// MacBook Touch Bar: one glass bar of raised keys, each a dense glanceable
// widget; tapping a key takes over the whole bar with its detail view (Esc or ✕
// backs out). Docks like the unified inbox's side panes — pinned / floating /
// hidden via usePaneMode — and its layout syncs to the account.
//
// Mounted at the bottom of each app shell: AppChrome, UnifiedInboxView, InboxPage.

// Floating mode auto-hide, like the Dock: rest on the bottom edge to summon the
// bar, move away to dismiss it. A click on the edge tab pins it instead.
const HOVER_OPEN_MS = 120;
const HOVER_CLOSE_MS = 450;

export default function TouchStrip() {
  const dockRef = useRef(null);
  const pane = usePaneMode(TOUCH_STRIP_MODE, dockRef);
  const config = useStripConfig();
  const { user } = useAuth();
  const [expanded, setExpanded] = useState(null);
  const [customizing, setCustomizing] = useState(false);
  const open = expanded && config.items.includes(expanded) ? expanded : null;
  const hoverTimer = useRef(null);
  const hoverOpened = useRef(false); // open because of the pointer, so it may auto-hide

  useEffect(() => () => clearTimeout(hoverTimer.current), []);

  const onEdgeEnter = () => {
    if (!pane.floating || pane.open) return;
    clearTimeout(hoverTimer.current);
    hoverTimer.current = setTimeout(() => { hoverOpened.current = true; pane.setOpen(true); }, HOVER_OPEN_MS);
  };
  const onDockEnter = () => { if (hoverOpened.current) clearTimeout(hoverTimer.current); };
  const onDockLeave = () => {
    clearTimeout(hoverTimer.current);
    if (!hoverOpened.current || customizing) return;
    hoverTimer.current = setTimeout(() => { hoverOpened.current = false; pane.setOpen(false); }, HOVER_CLOSE_MS);
  };
  // Clicking the tab while hover-opened pins the bar rather than closing it.
  const onEdgeClick = () => {
    clearTimeout(hoverTimer.current);
    if (hoverOpened.current && pane.open) { hoverOpened.current = false; return; }
    hoverOpened.current = false;
    pane.setOpen((o) => !o);
  };

  useEffect(() => { if (user?.id) loadRemoteStripConfig(); }, [user?.id]);

  // Fixed-bottom bars (DraftBar) sit on the strip's footprint, not under it.
  useEffect(() => {
    const el = dockRef.current;
    if (!el) return undefined;
    const root = document.documentElement;
    const ro = new ResizeObserver(() => root.style.setProperty('--touch-strip-offset', `${el.offsetHeight}px`));
    ro.observe(el);
    return () => { ro.disconnect(); root.style.removeProperty('--touch-strip-offset'); };
  }, []);

  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') setExpanded(null); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open]);

  const Expanded = open && COMPONENTS[open];

  return (
    <div ref={dockRef} className={styles.dock} data-mode={pane.mode} role="presentation" onMouseEnter={onDockEnter} onMouseLeave={onDockLeave}>
      {pane.strip && (
        <div className={styles.edge} data-pane-strip role="presentation" onMouseEnter={onEdgeEnter}>
          {pane.mode === PANE_MODE.HIDDEN ? (
            <PaneModeMenu pane={pane} icon="chevron.up" label="Touch Strip" align="left" direction="up" className={styles.edgeButton} />
          ) : (
            <button type="button" className={styles.edgeButton} onClick={onEdgeClick} aria-expanded={pane.open} aria-label="Touch Strip" title="Touch Strip">
              <Icon name="chevron.up" size={12} />
            </button>
          )}
        </div>
      )}

      {pane.shown && (
        <div className={styles.bar} data-floating={pane.floating ? 'true' : undefined} role="toolbar" aria-label="Touch Strip">
          {Expanded ? (
            <>
              <button type="button" className={styles.squareKey} onClick={() => setExpanded(null)} aria-label={`Close ${STRIP_WIDGETS[open].label}`} title="Back (Esc)">
                <Icon name="xmark" size={10} />
              </button>
              <Expanded config={config} expanded />
            </>
          ) : (
            <>
              <PaneModeMenu
                pane={pane}
                label="Touch Strip"
                align="left"
                direction="up"
                trigger={(
                  <button type="button" className={styles.squareKey} title="Strip mode" aria-label="Strip mode">
                    <Icon name={paneModeIcon(pane.mode)} size={13} />
                  </button>
                )}
              />
              {config.items.map((id) => {
                const Widget = COMPONENTS[id];
                return <Widget key={id} config={config} onExpand={STRIP_WIDGETS[id].expands ? () => setExpanded(id) : undefined} />;
              })}
              {config.items.length === 0 && <span className={styles.empty}>Nothing in the strip yet. Add widgets with Customize.</span>}
              <button type="button" className={`${styles.squareKey} ${styles.pushRight}`} onClick={() => setCustomizing(true)} title="Customize Touch Strip" aria-label="Customize Touch Strip">
                <Icon name="slider.horizontal.3" size={14} />
              </button>
            </>
          )}
        </div>
      )}

      <StripCustomize open={customizing} onClose={() => setCustomizing(false)} />
    </div>
  );
}
