import { useCallback, useEffect, useRef, useState } from 'react';

// A boolean flag that auto-resets to false after `duration` ms. Replaces the
// `setSaved(true); setTimeout(() => setSaved(false), N)` pattern duplicated
// across the settings pages and copy buttons. Returns [flag, trigger].
export default function useTransientFlag(duration = 2000) {
  const [flag, setFlag] = useState(false);
  const timer = useRef(null);

  const trigger = useCallback(() => {
    setFlag(true);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setFlag(false), duration);
  }, [duration]);

  useEffect(() => () => clearTimeout(timer.current), []);

  return [flag, trigger];
}
