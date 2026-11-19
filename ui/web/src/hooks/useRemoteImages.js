// useRemoteImages — loads the remote images that blockRemoteContent neutralized
// in the rendered email body.
//
// With a token we ALWAYS go through the Rails proxy: each image is fetched
// server-side and swapped in as a blob URL, so the sender never sees the reader's
// IP. The iframe also runs a strict CSP (img-src data: blob:) so any vector we
// might miss still can't phone home. A DIRECT load (which leaks the IP) is allowed
// ONLY on an explicit per-message "Show images" click with no token available —
// never automatically from safe-sender / always-show.
//
// A MutationObserver re-scans so images revealed late (expanding quoted text or a
// signature) are handled the same way. Blob URLs are revoked on cleanup.
//
// Graceful degradation: some image hosts (CDNs behind bot management, e.g.
// Cloudflare) 403 the server-side proxy no matter what headers it sends — they
// fingerprint the TLS client itself. Those fetches fail with 502; we count them
// and offer an explicit per-message "Load directly" action. Accepting it rebuilds
// the iframe with a relaxed CSP (img-src https:) and the still-failing images fall
// back to their original URLs — a consented, minimal IP exposure limited to the
// hosts that refuse the proxy.
import { useEffect, useState, useCallback } from 'react';
import api from '../lib/api';
import log from '../lib/log';
import { isTauri } from '../lib/tauri';
import useImageProxyPref from '../lib/imageProxyPref';
import { isSafeSender, addSafeSender } from '../lib/safeSenders';
import { getAlwaysShowImages, setAlwaysShowImages } from '../lib/alwaysShowImagesPref';
import { isShownMessage, markShownMessage } from '../lib/shownMessages';
import { shouldProxyImages } from '@inbox2/email-body';

// Read a proxied image blob as a data: URL. We deliberately avoid blob: URLs:
// the email renders in a sandboxed `srcdoc` iframe, and in WKWebView a blob: URL
// created in the parent window isn't reachable from the iframe's partition, so
// the <img> stays blank with no error. data: URLs are partition-independent.
function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error || new Error('FileReader failed'));
    reader.readAsDataURL(blob);
  });
}

export default function useRemoteImages(root, body, sender, messageKey) {
  const { enabled } = useImageProxyPref();

  // Token lives in the secret store (async). Hydrate into state; null until known.
  // Prod web has no bearer in JS — the HttpOnly session cookie authenticates the
  // proxy, so "has credentials" is always true there. Only desktop needs a token.
  const [hasToken, setHasToken] = useState(!isTauri() || !!api.token);
  useEffect(() => {
    let alive = true;
    api.getToken().then((t) => { if (alive) setHasToken(!isTauri() || !!t); });
    return () => { alive = false; };
  }, []); // token is global, not body-scoped — hydrate once

  const [blockedCount, setBlockedCount] = useState(0);
  // Proxy fetches the upstream host refused (bot-managed CDNs) — drives the
  // "couldn't load privately" banner.
  const [failedCount, setFailedCount] = useState(0);
  // Per-body state by comparison, so a new message resets cleanly.
  const [shownFor, setShownFor] = useState(null);
  // Per-message consent to load the proxy-failed images directly (session-only,
  // explicit click — never automatic).
  const [directFor, setDirectFor] = useState(null);
  const direct = directFor === body;

  // Proxy-only: images load ONLY through the proxy (private). There is no direct
  // load — without a token images stay blocked, so the reader's IP can never leak.
  // The decision itself is the shared @inbox2/email-body policy; this hook just
  // feeds it the trust-list/pref lookups and "show once" state.
  const proxyMode = shouldProxyImages({
    proxyEnabled: enabled,
    isSafeSender: isSafeSender(sender),
    alwaysShow: getAlwaysShowImages(),
    shownOnce: shownFor === body || isShownMessage(messageKey),
    hasToken,
  });

  // Explicit click with no credentials (MX logged out): the proxy can't run, so
  // honour the click with a consented direct load — the relaxed CSP admits it.
  const onShowOnce = useCallback(() => {
    markShownMessage(messageKey); setShownFor(body);
    if (!hasToken) setDirectFor(body);
  }, [body, messageKey, hasToken]);
  const onAlwaysSender = useCallback(() => { addSafeSender(sender); setShownFor(body); }, [body, sender]);
  const onAlwaysAll = useCallback(() => { setAlwaysShowImages(true); setShownFor(body); }, [body]);
  const onLoadDirect = useCallback(() => setDirectFor(body), [body]);

  useEffect(() => {
    const container = root;
    if (!container) return;
    let cancelled = false;

    const swapIn = (el, kind, url) => {
      if (kind === 'src') { el.setAttribute('src', url); delete el.dataset.blockedSrc; }
      else { el.style.backgroundImage = `url("${url}")`; delete el.dataset.blockedBg; }
    };

    const loadViaProxy = async (el) => {
      // srcset can't be proxied per-candidate; drop it and let src carry the image.
      if (el.dataset.blockedSrcset) { el.removeAttribute('srcset'); delete el.dataset.blockedSrcset; }
      const targets = [];
      if (el.dataset.blockedSrc) targets.push(['src', el.dataset.blockedSrc]);
      if (el.dataset.blockedBg) targets.push(['bg', el.dataset.blockedBg]);
      for (const [kind, orig] of targets) {
        try {
          const blob = await api.fetchProxiedImage(orig);
          if (cancelled) return;
          // Inline as a data: URL, not a blob: URL. The email renders inside a
          // sandboxed `srcdoc` iframe; in WKWebView (desktop/iOS) a blob: URL
          // minted in the parent window lives in a different partition and fails
          // to load there (silently — no error, blank image). data: URLs aren't
          // origin-scoped and are already permitted by the iframe CSP (img-src
          // data:), so they render everywhere. Images are size-capped by the proxy.
          const url = await blobToDataUrl(blob);
          if (cancelled) return;
          swapIn(el, kind, url);
        } catch (e) {
          if (cancelled) return;
          log.warn('RemoteImages', `proxy failed (${kind} status=${e?.status}) → ${orig.slice(0, 80)}`);
          if (direct) {
            // Consented fallback: this host refuses the proxy, so load it straight
            // from the reader. The relaxed CSP of the direct render permits it.
            swapIn(el, kind, orig);
          } else {
            setFailedCount((c) => c + 1);
          }
        }
      }
    };

    const process = (el) => {
      if (!el.dataset.blockedSrc && !el.dataset.blockedSrcset && !el.dataset.blockedBg) return;
      if (el.dataset.proxyTried) return; // don't re-fire on re-scan
      if (proxyMode) { el.dataset.proxyTried = '1'; loadViaProxy(el); return; }
      if (!direct) return; // not requested → stay blocked
      // No credentials + explicit click → direct load (consented).
      el.dataset.proxyTried = '1';
      if (el.dataset.blockedSrcset) { el.setAttribute('srcset', el.dataset.blockedSrcset); delete el.dataset.blockedSrcset; }
      if (el.dataset.blockedSrc) swapIn(el, 'src', el.dataset.blockedSrc);
      if (el.dataset.blockedBg) swapIn(el, 'bg', el.dataset.blockedBg);
    };

    const scan = () => {
      if (cancelled) return;
      const els = container.querySelectorAll('[data-blocked-src], [data-blocked-srcset], [data-blocked-bg]');
      setBlockedCount(els.length);
      els.forEach(process);
    };

    const raf = requestAnimationFrame(() => {
      setFailedCount(0); // fresh document / policy — failures re-count from zero
      scan();
    });
    const observer = new MutationObserver(scan);
    observer.observe(container, { childList: true, subtree: true });

    return () => {
      cancelled = true;
      cancelAnimationFrame(raf);
      observer.disconnect();
    };
  }, [root, body, proxyMode, hasToken, direct]);

  return {
    blockedCount,
    onShowOnce,
    onAlwaysSender,
    onAlwaysAll,
    // Banner when images are blocked and not proxying — "Show images" proxies them
    // (with a key). With no key it stays blocked; the banner notes a key is needed.
    showBanner: blockedCount > 0 && !proxyMode && !direct,
    // Graceful degradation: the proxy ran but some hosts refused it. The host
    // component relaxes the iframe CSP when `direct` flips true.
    failedCount,
    direct,
    onLoadDirect,
    showFailedBanner: failedCount > 0 && proxyMode && !direct,
  };
}
