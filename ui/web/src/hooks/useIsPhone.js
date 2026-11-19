import { useSyncExternalStore } from 'react';

// Viewport classes for the touch layout (src/mobile/) — the iOS/Android app
// structure in the browser:
//   phone  — ≤760px wide: one screen at a time over a floating capsule nav.
//   tablet — a touch screen up to iPad Pro landscape (1366px): the same screens
//            with the nav as a left rail and list + conversation side by side.
// Anything else (desktop browsers, the Tauri app) keeps the desktop client.
// Keep PHONE in step with the 760px media queries in CSS; tablet CSS keys off
// html[data-layout='tablet'] (set by MobileLayoutAttr in routes.jsx).
export const PHONE_QUERY = '(max-width: 760px)';
export const TABLET_QUERY = '(any-pointer: coarse) and (max-width: 1366px)';
export const MOBILE_LAYOUT = { PHONE: 'phone', TABLET: 'tablet' };

const subscribe = (cb) => {
  const queries = [PHONE_QUERY, TABLET_QUERY].map((q) => window.matchMedia(q));
  queries.forEach((mq) => mq.addEventListener('change', cb));
  return () => queries.forEach((mq) => mq.removeEventListener('change', cb));
};
const layoutSnapshot = () => {
  if (window.matchMedia(PHONE_QUERY).matches) return MOBILE_LAYOUT.PHONE;
  if (window.matchMedia(TABLET_QUERY).matches) return MOBILE_LAYOUT.TABLET;
  return null;
};
const phoneSnapshot = () => window.matchMedia(PHONE_QUERY).matches;

export const isPhoneNow = () => typeof window !== 'undefined' && phoneSnapshot();
export const mobileLayoutNow = () => (typeof window === 'undefined' ? null : layoutSnapshot());

/** 'phone' | 'tablet' | null — which touch layout this viewport gets, if any. */
export function useMobileLayout() {
  return useSyncExternalStore(subscribe, layoutSnapshot, () => null);
}

/** Phone-width viewport only (the console's drawer breakpoint). */
export default function useIsPhone() {
  return useSyncExternalStore(subscribe, phoneSnapshot, () => false);
}

// Wide enough to pin the folder list beside the inbox (iPad landscape).
const WIDE_TABLET_QUERY = '(min-width: 1100px)';
const subscribeWide = (cb) => {
  const mq = window.matchMedia(WIDE_TABLET_QUERY);
  mq.addEventListener('change', cb);
  return () => mq.removeEventListener('change', cb);
};
export function useWideTablet() {
  const layout = useMobileLayout();
  const wide = useSyncExternalStore(subscribeWide, () => window.matchMedia(WIDE_TABLET_QUERY).matches, () => false);
  return layout === MOBILE_LAYOUT.TABLET && wide;
}
