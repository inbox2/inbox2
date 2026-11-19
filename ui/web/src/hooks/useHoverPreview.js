import { useState, useCallback, useRef, useEffect } from 'react';

export default function useHoverPreview() {
  const [hoverPreview, setHoverPreview] = useState({ conv: null, rect: null });
  const hoverTimerRef = useRef(null);
  const closeTimerRef = useRef(null);

  useEffect(() => () => {
    clearTimeout(hoverTimerRef.current);
    clearTimeout(closeTimerRef.current);
  }, []);

  // While the preview/right-click popup is open, flag <body> so rows suppress
  // their hover quick-actions (they'd otherwise sit on top of the popup's own
  // triage toolbar). See QuickActions.module.css.
  useEffect(() => {
    if (hoverPreview.conv) document.body.dataset.previewOpen = 'true';
    else delete document.body.dataset.previewOpen;
    return () => { delete document.body.dataset.previewOpen; };
  }, [hoverPreview.conv]);

  const cancelClose = useCallback(() => {
    clearTimeout(closeTimerRef.current);
  }, []);

  const scheduleClose = useCallback(() => {
    clearTimeout(closeTimerRef.current);
    closeTimerRef.current = setTimeout(() => {
      setHoverPreview(prev => prev.conv ? { conv: null, rect: null } : prev);
    }, 300);
  }, []);

  const handleContextMenu = useCallback((conv, e) => {
    e.preventDefault();
    clearTimeout(hoverTimerRef.current);
    cancelClose();
    const rect = e.currentTarget?.getBoundingClientRect();
    if (rect) setHoverPreview({ conv, rect });
  }, [cancelClose]);

  const handleCardHover = useCallback((conv, e) => {
    clearTimeout(hoverTimerRef.current);
    cancelClose();
    // Capture rect synchronously — currentTarget is null after dispatch
    const rect = e.currentTarget?.getBoundingClientRect();
    if (!rect) return;
    hoverTimerRef.current = setTimeout(() => {
      setHoverPreview({ conv, rect });
    }, 3000);
  }, [cancelClose]);

  const handleCardHoverEnd = useCallback(() => {
    clearTimeout(hoverTimerRef.current);
    // Delayed close — cancelled if mouse enters popup or another card
    scheduleClose();
  }, [scheduleClose]);

  const handlePopupMouseEnter = useCallback(() => {
    cancelClose();
  }, [cancelClose]);

  const handlePopupMouseLeave = useCallback(() => {
    scheduleClose();
  }, [scheduleClose]);

  const closePreview = useCallback(() => {
    clearTimeout(hoverTimerRef.current);
    clearTimeout(closeTimerRef.current);
    setHoverPreview(prev => prev.conv ? { conv: null, rect: null } : prev);
  }, []);

  return {
    hoverPreview,
    handleContextMenu,
    handleCardHover,
    handleCardHoverEnd,
    handlePopupMouseEnter,
    handlePopupMouseLeave,
    closePreview,
  };
}
