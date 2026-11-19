/* Deterministic per-space color system. A space's color is the single source of
 * truth that ties together: its treemap cell, its tab in the inbox, and its
 * routing chips. Palette drawn from the /admin/raw console — violet, yellow,
 * pink, green — plus a neutral slate for the Triage holding pen. Custom spaces
 * the user creates get a stable palette slot by hash so the same id always
 * lands on the same color across sessions and clients.
 *
 * `dark: true` means the hue is light enough (yellow) to need dark text on the
 * filled cell; `textOn` exposes the right header-text color. */

const PALETTE = [
  { key: 'violet', a: '#8d7bf3', b: '#6a5af0' },
  { key: 'yellow', a: '#ffd64a', b: '#f3b51c', dark: true },
  { key: 'pink', a: '#fb5a78', b: '#ef2d57' },
  { key: 'green', a: '#3ddc97', b: '#1fa566' },
  // Extras for custom spaces beyond the canonical five.
  { key: 'cyan', a: '#36d6ee', b: '#129fc4' },
  { key: 'orange', a: '#ff9d4d', b: '#f5701c', dark: true },
  { key: 'indigo', a: '#7c83ff', b: '#4f54e0' },
  // Pinned-only from here on (see HASH_SLOTS).
  { key: 'teal', a: '#2ee6c5', b: '#13a58c' },
];

// Custom spaces hash over the first seven hues only, so adding a pinned hue
// never repaints the custom spaces people already know by color.
const HASH_SLOTS = 7;

// Canonical spaces every SMB recognises — pinned to a console hue.
const CANONICAL = {
  support: 'violet',
  sales: 'yellow',
  marketing: 'pink',
  finance: 'green',
  triage: 'orange',
  operations: 'cyan',
  // Personal Spaces (desktop, Mine view) — distinct from the six org defaults.
  reading: 'indigo',
  personal: 'teal',
  ops: 'cyan',
  product: 'indigo',
  hr: 'pink',
  legal: 'indigo',
};

function hash(str) {
  let h = 0;
  for (let i = 0; i < str.length; i += 1) h = str.charCodeAt(i) + ((h << 5) - h);
  return Math.abs(h);
}

function entryFor(id) {
  const slug = String(id || '').toLowerCase();
  const pinned = CANONICAL[slug];
  if (pinned) return PALETTE.find((p) => p.key === pinned) || PALETTE[0];
  return PALETTE[hash(slug) % HASH_SLOTS];
}

const cache = new Map();

/** Resolve a space id → its color tokens (memoised per id; the result is
 *  immutable so a shared object is safe to reuse).
 *  { key, a, b, gradient, solid, glow, textOn } */
export function spaceColor(id) {
  const cached = cache.get(id);
  if (cached) return cached;
  const e = entryFor(id);
  const color = {
    key: e.key,
    a: e.a,
    b: e.b,
    solid: e.a,
    textOn: e.dark ? '#1a1a1f' : '#ffffff',
    gradient: `linear-gradient(140deg, ${e.a} 0%, ${e.b} 100%)`,
    glow: `color-mix(in srgb, ${e.a} 40%, transparent)`,
  };
  cache.set(id, color);
  return color;
}

/** The palette's hue keys — the color choices for custom triage labels (the
 *  shared seven; iOS/Android know these by name, not the pinned-only extras). */
export const PALETTE_KEYS = PALETTE.slice(0, HASH_SLOTS).map((p) => p.key);

/** A palette key (`violet`, …) → its solid hex, or null for none/unknown. */
export function paletteSolid(key) {
  return PALETTE.find((p) => p.key === key)?.a || null;
}
