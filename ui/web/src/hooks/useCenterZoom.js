import { useEffect } from 'react';

// Center-point zoom for a react-force-graph canvas: always zoom toward the
// viewport center, not the mouse position. passive:false is required for
// preventDefault; rAF throttle prevents jank.
export default function useCenterZoom(containerRef, graphRef) {
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    let pending = false;
    let pendingDelta = 0;
    const handler = (e) => {
      e.preventDefault();
      pendingDelta += -e.deltaY * 0.001;
      if (pending) return;
      pending = true;
      requestAnimationFrame(() => {
        const fg = graphRef.current;
        if (fg) {
          const cur = fg.zoom();
          fg.zoom(Math.max(0.1, Math.min(20, cur * (1 + pendingDelta))), 0);
        }
        pendingDelta = 0;
        pending = false;
      });
    };
    el.addEventListener('wheel', handler, { passive: false });
    return () => el.removeEventListener('wheel', handler);
  }, [containerRef, graphRef]);
}
