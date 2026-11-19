// An organization's colour, sampled from its own logo (docs/plans/lore.md §4b):
// the cover gradient's tint when the site declares no theme-color. Runs on the
// already-fetched icon (an object URL, so the canvas isn't tainted).

const SIZE = 32;
const BUCKETS = 24; // hue buckets of 15°

/** rgb (0–255) → [h 0–360, s 0–1, l 0–1] */
function hsl(r, g, b) {
  const max = Math.max(r, g, b) / 255;
  const min = Math.min(r, g, b) / 255;
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  const [rr, gg, bb] = [r / 255, g / 255, b / 255];
  let h;
  if (max === rr) h = ((gg - bb) / d + (gg < bb ? 6 : 0)) * 60;
  else if (max === gg) h = ((bb - rr) / d + 2) * 60;
  else h = ((rr - gg) / d + 4) * 60;
  return [h, s, l];
}

const hex = (n) => Math.round(n).toString(16).padStart(2, '0');

/**
 * The logo's dominant *colourful* colour as "#rrggbb", or null when it is
 * greyscale (most black/white logos). Pixels that are near-transparent, near
 * white, near black or unsaturated don't vote; the fullest hue bucket wins and
 * its pixels are averaged. ponytail: 32×32 hue histogram — good enough for a
 * tint, not a palette extractor.
 */
export function dominantColor(pixels) {
  const votes = Array.from({ length: BUCKETS }, () => ({ n: 0, r: 0, g: 0, b: 0 }));
  for (let i = 0; i < pixels.length; i += 4) {
    const [r, g, b, a] = [pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]];
    if (a < 128) continue;
    const [h, s, l] = hsl(r, g, b);
    if (s < 0.25 || l < 0.12 || l > 0.92) continue;
    const v = votes[Math.floor(h / (360 / BUCKETS)) % BUCKETS];
    v.n += 1; v.r += r; v.g += g; v.b += b;
  }
  const best = votes.reduce((a, b) => (b.n > a.n ? b : a));
  if (best.n < 4) return null;
  return `#${hex(best.r / best.n)}${hex(best.g / best.n)}${hex(best.b / best.n)}`;
}

/** Is "#rrggbb" a real colour (not white, black or grey)? A site's theme-color often isn't. */
export function isColorful(hexColor) {
  const m = String(hexColor || '').match(/^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i);
  if (!m) return false;
  const [, s, l] = hsl(parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16));
  return s >= 0.25 && l >= 0.12 && l <= 0.92;
}

/** Load an image URL and sample it; null when it can't be read. */
export function sampleImageColor(url) {
  return new Promise((resolve) => {
    if (!url || typeof document === 'undefined') { resolve(null); return; }
    const img = new Image();
    img.onload = () => {
      try {
        const canvas = document.createElement('canvas');
        canvas.width = SIZE;
        canvas.height = SIZE;
        const ctx = canvas.getContext('2d', { willReadFrequently: true });
        ctx.drawImage(img, 0, 0, SIZE, SIZE);
        resolve(dominantColor(ctx.getImageData(0, 0, SIZE, SIZE).data));
      } catch { resolve(null); }
    };
    img.onerror = () => resolve(null);
    img.src = url;
  });
}
