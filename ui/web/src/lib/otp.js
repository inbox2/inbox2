// Sign-in alert helpers for the desktop card. The detection itself lives in
// the shared Rust core (ui/desktop/core/src/otp.rs, local channels) and in
// Rails (OtpDetector, inbox2-hosted mail); both send `otp` on the alert as
// {code} or {link, host} — docs/Notifications.md "Sign-in codes and links".

// A favicon from these says "Google", not who wrote to you.
const FREEMAIL = new Set(['gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'yahoo.com', 'icloud.com', 'me.com']);

/**
 * The icon of the site behind a mail card: a sign-in link's host, else the
 * sender's domain — skipped for freemail. Fetched through the Rails image
 * proxy like any remote email image — the card never contacts a host the mail
 * named. ponytail: plain /favicon.ico; a site that only declares its icon in
 * <link rel=icon> gets the channel icon instead.
 */
export function siteIconUrl(otp, senderEmail) {
  const host = otp?.host || senderEmail?.split('@')[1];
  if (!host || (!otp?.host && FREEMAIL.has(host.toLowerCase()))) return null;
  return `https://${host}/favicon.ico`;
}

const ICON_TIMEOUT_MS = 1500;
// ponytail: per-session cache keyed on URL so a chatty sender costs one fetch;
// misses are cached too (a site without a favicon stays without one).
const iconCache = new Map();

export async function fetchSiteIcon(url) {
  if (!url) return null;
  if (iconCache.has(url)) return iconCache.get(url);
  const icon = await fetchSiteIconUncached(url);
  iconCache.set(url, icon);
  return icon;
}

async function fetchSiteIconUncached(url) {
  try {
    const { default: api } = await import('./api.js');
    const blob = await Promise.race([
      api.fetchProxiedImage(url),
      new Promise((resolve) => setTimeout(() => resolve(null), ICON_TIMEOUT_MS)),
    ]);
    if (!blob || blob.size > 64 * 1024) return null;
    return await new Promise((resolve) => {
      const r = new FileReader();
      r.onload = () => resolve(r.result);
      r.onerror = () => resolve(null);
      r.readAsDataURL(blob);
    });
  } catch {
    return null;
  }
}

/** What goes on the clipboard: the code without its grouping space/dash. */
export const codeForClipboard = (code) => code.replace(/[ -]/g, '');

// The notification panel can never become key window (docs/Notifications.md),
// which navigator.clipboard needs — so the desktop writes through the plugin.
export async function copyText(text) {
  try {
    const { writeText } = await import('@tauri-apps/plugin-clipboard-manager');
    await writeText(text);
  } catch {
    await navigator.clipboard.writeText(text);
  }
}
