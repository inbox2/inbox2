import { create } from 'zustand';
import { useEffect, useRef } from 'react';

/**
 * Command-palette open state + the page-scoped actions it can run.
 *
 * The palette itself is mounted ONCE, globally (routes.jsx), so ⌘P works on
 * every screen — Settings, the console, Triage Lab, spaces — and not only on
 * the five pages that used to each carry their own copy.
 *
 * What a page can *do* still differs (composing needs the page's DraftProvider,
 * "toggle unread" needs its filter state), so a page registers those closures
 * here while it's mounted and the global palette calls them.
 */
const usePaletteStore = create((set) => ({
  open: false,
  actions: {},
  toggle: () => set((s) => ({ open: !s.open })),
  close: () => set({ open: false }),
  setActions: (actions) => set({ actions }),
}));

// Every action the palette knows how to offer. A page passes the subset it
// supports; the palette hides the rest (see buildCommands).
const ACTION_NAMES = ['compose', 'refresh', 'notifications', 'toggleView', 'toggleUnread'];

/**
 * Register this page's palette actions for as long as it's mounted.
 * The handlers are read through a ref, so a page may pass fresh closures on
 * every render without re-registering — only the *set* of actions it offers
 * (which never changes mid-render in practice) re-runs the effect.
 */
export function usePaletteActions(actions) {
  const latest = useRef(actions);
  useEffect(() => { latest.current = actions; });
  const setActions = usePaletteStore((s) => s.setActions);
  const offered = ACTION_NAMES.filter((n) => actions[n]).join(',');

  useEffect(() => {
    const stable = {};
    for (const name of offered ? offered.split(',') : []) {
      stable[name] = (...args) => latest.current[name]?.(...args);
    }
    setActions(stable);
    // Clear only if nothing else registered in the meantime: on a route change
    // the incoming page can mount before the outgoing one unmounts, and a blind
    // reset would wipe the new page's actions.
    return () => usePaletteStore.setState((s) => (s.actions === stable ? { actions: {} } : {}));
  }, [offered, setActions]);
}

export default usePaletteStore;
