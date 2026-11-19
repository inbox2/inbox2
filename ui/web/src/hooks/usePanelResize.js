import { useState, useRef, useCallback } from 'react';

/**
 * Manages a resizable panel width with localStorage persistence.
 *
 * @param {string} storageKey  localStorage key (e.g. 'inbox2_sidebar_width')
 * @param {number} defaultWidth  fallback width in px
 * @param {{ min: number, max: number, reverse?: boolean }} opts
 *   reverse — if true, dragging left increases width (for right-edge panels)
 * @returns {{ width: number, startResize: (e: MouseEvent) => void, resetWidth: () => void }}
 */
export default function usePanelResize(storageKey, defaultWidth, { min, max, reverse = false }) {
  const [width, setWidth] = useState(() => {
    const saved = localStorage.getItem(storageKey);
    const parsed = saved ? Number(saved) : NaN;
    return Number.isFinite(parsed) ? Math.min(max, Math.max(min, parsed)) : defaultWidth;
  });
  const widthRef = useRef(width);

  const startResize = useCallback((e) => {
    e.preventDefault();
    const startX = e.clientX;
    const startWidth = widthRef.current;

    const onMouseMove = (moveE) => {
      const delta = reverse ? startX - moveE.clientX : moveE.clientX - startX;
      const newWidth = Math.min(max, Math.max(min, startWidth + delta));
      widthRef.current = newWidth;
      setWidth(newWidth);
    };

    const onMouseUp = () => {
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup', onMouseUp);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
      localStorage.setItem(storageKey, String(Math.round(widthRef.current)));
    };

    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
    document.addEventListener('mousemove', onMouseMove);
    document.addEventListener('mouseup', onMouseUp);
  }, [min, max, reverse, storageKey]);

  const resetWidth = useCallback(() => {
    widthRef.current = defaultWidth;
    setWidth(defaultWidth);
    localStorage.setItem(storageKey, String(defaultWidth));
  }, [defaultWidth, storageKey]);

  return { width, startResize, resetWidth };
}
