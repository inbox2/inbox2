// imagePolicy — the pure remote-image privacy decision, extracted from
// useRemoteImages so it can be shared and unit-tested independently of React/DOM.
//
// Policy (see docs / the useRemoteImages hook): remote images load through the
// privacy proxy ONLY when there's a token AND the reader has opted in — either
// automatically (the proxy toggle, a trusted sender, or "always show all") or
// explicitly for this message ("show once"). With no token, images stay blocked;
// a direct (IP-leaking) load is never decided here — that is a separate, explicit
// per-message action in the host.

/**
 * @param {object} o
 * @param {boolean} o.proxyEnabled  global image-proxy toggle is on
 * @param {boolean} o.isSafeSender   this sender is on the trusted list
 * @param {boolean} o.alwaysShow     "always show all images" pref is on
 * @param {boolean} o.shownOnce      reader clicked "show images" for this message
 * @param {boolean} o.hasToken       a cloud-auth token is available (proxy needs it)
 * @returns {boolean} whether to load images through the privacy proxy
 */
export function shouldProxyImages({ proxyEnabled, isSafeSender, alwaysShow, shownOnce, hasToken }) {
  const autoShow = Boolean(proxyEnabled || isSafeSender || alwaysShow);
  const manualShow = Boolean(shownOnce);
  return (autoShow || manualShow) && Boolean(hasToken);
}
