// Block remote content in email HTML so nothing phones home when a message is
// opened (tracking-pixel / open-tracking defence — see emailprivacytester.com).
//
// Every remote-loading reference is neutralized in place: the original URL is
// stashed on a data-* attribute and the live attribute is replaced with a
// transparent placeholder, so layout holds and the loader hook (useRemoteImages)
// can later restore them — directly on "Show images", or via the Rails proxy.
//
// Inline-style url() references (CSS background-image, list-style-image, cursor,
// content) are stripped outright: they're rare in real mail and we don't offer a
// restore path for them. Tag-based vectors (iframe/object/embed/video/audio/etc.)
// are removed upstream by DOMPurify via the BLOCKED_TAGS/BLOCKED_ATTR lists below.

// 1x1 transparent GIF.
export const PLACEHOLDER =
  'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';

// A positive px dimension from an attribute or inline style, else null.
// Percentages are unusable (no fixed ratio) and are ignored.
function pxDim(el, name) {
  for (const raw of [el.getAttribute(name), el.style && el.style[name]]) {
    if (!raw || /%/.test(raw)) continue;
    const v = parseFloat(raw);
    if (Number.isFinite(v) && v > 0) return Math.round(v);
  }
  return null;
}

// Placeholder for a blocked <img>. A bare 1x1 GIF balloons under the responsive
// rule `img{height:auto}` (ubiquitous in marketing/bank templates): a 1:1 ratio
// makes height track width, so a `width="125"` button becomes a 125x125 square
// and a full-width divider becomes a giant block. We instead emit a transparent
// SVG sized from whatever the image declares:
//   • both width+height → exact intrinsic size, ratio preserved.
//   • one dimension     → the other defaults to 1px, so `height:auto` collapses
//     the placeholder to a thin line instead of ballooning into a square.
//   • neither           → the 1x1 GIF (can't balloon without an external width).
// The real image (with its true ratio) replaces this once the proxy swaps it in.
function imgPlaceholder(el) {
  const w = pxDim(el, 'width');
  const h = pxDim(el, 'height');
  if (!w && !h) return PLACEHOLDER;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w || 1}" height="${h || 1}"/>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

// Tags whose sole purpose, in mail, is to fetch a remote resource (and the
// bypass vectors emailprivacytester.com probes). Fed to DOMPurify FORBID_TAGS.
export const BLOCKED_TAGS = [
  'iframe', 'object', 'embed', 'applet', 'portal', 'bgsound',
  'video', 'audio', 'source', 'track',
  'base', 'form', 'input', 'button', 'link', 'meta', 'script',
  'frame', 'frameset', 'param',
];

// Attributes that trigger a request or redirect resolution. Fed to FORBID_ATTR.
export const BLOCKED_ATTR = ['ping', 'formaction', 'background', 'lowsrc', 'dynsrc'];

// Backgrounds are handled separately (stashed/proxied); these rarer url()
// properties are just stripped.
const STYLE_URL_PROPS = ['list-style-image', 'cursor', 'content'];

// Neutralize remote refs on a parsed DOM root (Document or Element). Mutates in
// place; returns the count of restorable image references (the banner total).
export function blockRemoteContent(root) {
  if (!root) return 0;
  let blocked = 0;

  for (const el of root.querySelectorAll('img, [srcset], [poster], [background]')) {
    // img/input image src
    const src = el.getAttribute('src');
    if (src && !src.startsWith('data:') && !el.dataset.blockedSrc) {
      el.dataset.blockedSrc = src;
      el.setAttribute('src', imgPlaceholder(el));
      blocked++;
    }
    // srcset on <img>/<source>/<picture>
    const srcset = el.getAttribute('srcset');
    if (srcset && !el.dataset.blockedSrcset) {
      el.dataset.blockedSrcset = srcset;
      el.removeAttribute('srcset');
      blocked++;
    }
    // <video poster>
    const poster = el.getAttribute('poster');
    if (poster && !poster.startsWith('data:')) {
      el.dataset.blockedPoster = poster;
      el.removeAttribute('poster');
    }
    // legacy background="" attribute (body/td/table) — stash so it can be
    // proxied/restored like a background-image, not destroyed.
    const bgAttr = el.getAttribute('background');
    if (bgAttr && !bgAttr.startsWith('data:') && !el.dataset.blockedBg) {
      el.dataset.blockedBg = bgAttr;
      el.removeAttribute('background');
      blocked++;
    }
  }

  // SVG remote references — <image>, <use>, <feImage> with href / xlink:href.
  // The HTML <img> handling above doesn't cover these, and DOMPurify keeps inline
  // SVG, so they'd phone home (emailprivacytester: "SVG inline with remote image"
  // / "filter feImage"). Proxying SVG hrefs isn't worth it — strip them.
  const XLINK = 'http://www.w3.org/1999/xlink';
  for (const el of root.querySelectorAll('image, use, feImage')) {
    const href = el.getAttribute('href') || el.getAttributeNS(XLINK, 'href');
    if (href && !href.startsWith('data:') && !href.startsWith('#')) {
      el.removeAttribute('href');
      el.removeAttributeNS(XLINK, 'href');
    }
  }

  // Inline-style url() refs. A background-image is the email's layout (hero
  // banners etc.) — stash it (proxiable/restorable) instead of deleting it, or we
  // leave a blank gap that "Show images" can't recover. The rarer cursor/content/
  // list-style url()s are just stripped.
  for (const el of root.querySelectorAll('[style]')) {
    if (!el.style || !/url\(/i.test(el.getAttribute('style') || '')) continue;

    // backgroundImage longhand catches both `background-image:` and the
    // `background:` shorthand (the browser expands it).
    const m = el.style.backgroundImage.match(/url\((['"]?)([^'")]+)\1\)/i);
    if (m && !m[2].startsWith('data:') && !el.dataset.blockedBg) {
      el.dataset.blockedBg = m[2];
      el.style.backgroundImage = 'none';
      blocked++;
    }

    for (const prop of STYLE_URL_PROPS) {
      const val = el.style.getPropertyValue(prop);
      if (val && /url\(/i.test(val)) el.style.removeProperty(prop);
    }
  }

  return blocked;
}
