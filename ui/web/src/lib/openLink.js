// Central decision point for opening a link from an email body: always the
// system browser — desktop opens a new tab in the user's default browser via the
// Tauri opener plugin, web opens a new tab with window.open. There is no in-app
// browser. Non-web schemes (mailto:, tel:, …) go to the system handler too;
// in-page anchors and javascript: are ignored.
import { isTauri } from './tauri';
import log from './log';

// One email-link click can reach openLink twice — the native email-link-router
// cancels the in-frame navigation and emits open-external-link, AND EmailFrame's
// capture-phase click listener fires — so the link would open in two places.
// Dedupe per URL within a short window, on globalThis so it holds even when this
// module is duplicated across chunks (the two callers can be in different ones).
const DEDUPE_MS = 1000;
function recentlyOpened(url) {
  const last = globalThis.__inbox2_lastLinkOpen;
  const now = Date.now();
  if (last && last.url === url && now - last.at < DEDUPE_MS) return true;
  globalThis.__inbox2_lastLinkOpen = { url, at: now };
  return false;
}

// Resolves true once the link was handed to the browser (the sign-in card
// trashes its mail only then), false otherwise.
export async function openLink(url) {
  const trimmed = (url || '').trim();
  if (!trimmed) return false;
  const lower = trimmed.toLowerCase();
  if (trimmed.startsWith('#') || lower.startsWith('javascript:')) return false;
  if (recentlyOpened(trimmed)) return false;

  try {
    if (isTauri()) {
      const { openUrl } = await import('@tauri-apps/plugin-opener');
      await openUrl(trimmed);
    } else {
      // A click originates inside the sandboxed email iframe (allow-same-origin,
      // no allow-popups), so window.open() is popup-blocked. A real anchor click
      // in the parent (unsandboxed) document opens a new tab reliably and still
      // carries noopener/noreferrer for untrusted email links.
      const a = document.createElement('a');
      a.href = trimmed;
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
      a.click();
    }
    return true;
  } catch (e) {
    log.warn('Link', `Failed to open externally: ${e?.message || e}`);
    return false;
  }
}

// Click handler for any container holding rendered anchors (chat bubbles, comment
// bodies, the comment "source" link). Routes the click through openLink so links
// open in a new system-browser tab instead of navigating the app webview.
export function handleAnchorClick(e) {
  const a = e.target.closest?.('a');
  if (!a) return;
  const href = a.getAttribute('href');
  if (!href) return;
  e.preventDefault();
  openLink(href);
}
