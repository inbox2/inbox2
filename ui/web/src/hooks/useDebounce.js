import { useEffect, useState } from 'react';

// Debounce a rapidly-changing value (search/filter inputs): returns `value` only
// after it has stopped changing for `delay` ms. Replaces the per-page re-defined
// / inlined setTimeout-debounce effects (CommandCenterPage, InboxPage, …).
export default function useDebounce(value, delay = 200) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(t);
  }, [value, delay]);
  return debounced;
}
