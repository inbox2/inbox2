import { useEffect, useRef } from 'react';

/**
 * Fallback refresh: calls `onRefetch` when the tab regains focus / becomes visible
 * again. Safety net for when the realtime socket (useMailRefresh) missed a signal
 * or was disconnected while the tab was backgrounded — returning to the tab pulls
 * anything that arrived meanwhile.
 *
 * Held in a ref so the listeners bind once for the component's lifetime.
 *
 * @param {() => void} onRefetch
 */
export default function useRefetchOnFocus(onRefetch) {
  const ref = useRef(onRefetch);
  useEffect(() => { ref.current = onRefetch; }, [onRefetch]);
  useEffect(() => {
    const fire = () => { if (document.visibilityState !== 'hidden') ref.current?.(); };
    window.addEventListener('focus', fire);
    document.addEventListener('visibilitychange', fire);
    return () => {
      window.removeEventListener('focus', fire);
      document.removeEventListener('visibilitychange', fire);
    };
  }, []);
}
