import { useState, useEffect } from 'react';

// ResizeObserver → the element's live content-box size ({ width, height }).
export default function useContainerSize(ref, initial = { width: 700, height: 500 }) {
  const [size, setSize] = useState(initial);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(entries => {
      const { width, height } = entries[0].contentRect;
      setSize({ width, height });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [ref]);

  return size;
}
