import { useEffect } from 'react';
import { useMobileLayout } from '../hooks/useIsPhone';
import { isTauri } from '../lib/tauri';

/* Route-level switch: the touch screen (phone or tablet) where the viewport
 * calls for one, the desktop page everywhere else. The desktop app never
 * switches, however narrow its window — the touch layout is a web view of MX
 * mail, not a Tauri one. */
export default function PhoneSwitch({ phone, children }) {
  const layout = useMobileLayout();
  return layout && !isTauri() ? phone : children;
}

/* Mirrors the touch layout onto <html data-layout>, so CSS outside the shell
 * (portaled toasts, settings, editors) can style the tablet case — a width
 * media query can't tell an iPad from a desktop window. */
export function MobileLayoutAttr() {
  const layout = useMobileLayout();
  const active = layout && !isTauri() ? layout : null;
  useEffect(() => {
    const root = document.documentElement;
    if (active) root.dataset.layout = active;
    else delete root.dataset.layout;
  }, [active]);
  return null;
}
