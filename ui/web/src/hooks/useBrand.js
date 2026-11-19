import { useEffect, useState } from 'react';
import api from '../lib/api';
import log from '../lib/log';
import { isColorful, sampleImageColor } from '../lib/brandColor';
import { isDemoMode } from '../lib/demoData';

/*
 * An organization's imagery by domain (docs/plans/lore.md §4b):
 *   useBrand('odido.nl') → { name, icon, image, color, accent } | null
 *     accent — the site's theme-color, else the dominant colour of its logo (lib/brandColor)
 * The API looks the domain up once and caches it; icon/image come back as
 * image-proxy paths that need the session, so they're fetched here and handed
 * out as object URLs. Only the domain name leaves the device — never mail.
 * Cached per domain for the session; a failed lookup is just "no brand".
 */
const cache = new Map(); // domain → Promise<brand|null>

// The proxy path carries the original URL; fetchProxiedImage wants that.
const remoteOf = (proxyPath) => {
  try { return new URL(proxyPath, window.location.origin).searchParams.get('url'); } catch { return null; }
};

async function image(proxyPath) {
  const remote = proxyPath && remoteOf(proxyPath);
  if (!remote) return null;
  try { return URL.createObjectURL(await api.fetchProxiedImage(remote)); } catch { return null; }
}

// Demo mode: the domains are the invented cast's, which may be someone's real
// site — never look them up; give each a steady colour of its own instead.
const DEMO_ACCENTS = ['#7a5cd6', '#2383e2', '#d9730d', '#448361', '#c14c8a', '#cb912f'];
function demoBrand(domain) {
  let h = 0;
  for (const ch of domain) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return { name: null, icon: null, image: null, color: null, accent: DEMO_ACCENTS[h % DEMO_ACCENTS.length] };
}

async function lookup(domain) {
  if (isDemoMode()) return demoBrand(domain);
  try {
    const { brand } = await api.getBrand(domain);
    if (!brand) return null;
    const [icon, cover] = await Promise.all([image(brand.icon_url), image(brand.image_url)]);
    const color = brand.theme_color || null;
    const accent = (isColorful(color) && color) || await sampleImageColor(icon);
    return { name: brand.name || null, icon, image: cover, color, accent };
  } catch (e) {
    log.warn('useBrand', `${domain}: ${e?.message || e}`);
    return null;
  }
}

export function loadBrand(domain) {
  if (!cache.has(domain)) {
    const p = lookup(domain);
    // Only hits stay cached: a miss is looked up again on the next mount.
    p.then((b) => { if (!b?.icon && !b?.accent) cache.delete(domain); });
    cache.set(domain, p);
  }
  return cache.get(domain);
}

export default function useBrand(domain) {
  const [state, setState] = useState({ domain: null, brand: null });
  useEffect(() => {
    if (!domain) return undefined;
    let live = true;
    loadBrand(domain).then((brand) => { if (live) setState({ domain, brand }); });
    return () => { live = false; };
  }, [domain]);
  return state.domain === domain ? state.brand : null;
}
