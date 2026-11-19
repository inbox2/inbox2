// Theme registry — single source of truth for selectable themes + the advanced
// per-theme token customizer (user overrides layered on top of a theme's tokens).
//
// A theme has:
//   id          unique key, persisted to localStorage and exposed as
//               `data-theme-variant` on <html> (hook for future per-variant tweaks).
//   label       display name in the picker.
//   description short subtitle shown under the name in the radio card.
//   mode        'dark' | 'light' — drives the token set via `data-theme`.
//   background  image served from /public, or null to use the animated pixel grid.
//               Doubles as the poster / reduced-motion fallback when `video` is set,
//               and as the still preview in the theme picker.
//   video       optional looping ambient clip served from /public. When present (and
//               the user hasn't requested reduced motion) the backdrop animates with
//               slow, subtle motion — drifting clouds, faint haze — instead of the
//               static image. Generated from `background` via Higgsfield (image→video).
//   procedural  optional canvas renderer key ('bonsai' → lib/bonsai.js, 'groovebox' →
//               lib/groovebox.js) drawn live in
//               place of `background`, which then only serves as the picker still.
//   swatch      { bg, fg, accent } — colours used to render the radio-card preview.
//   appIcon     optional app icon id (lib/appIcon.js) switched to when the user
//               picks this theme — once, on the way in; they can change it after.
//
// Per-variant token tweaks (the Warm theme's violet buttons, the Dark theme's
// gold controls, the Stars theme's purple) are plain CSS keyed on
// [data-theme-variant] in tokens.css — see the blocks at the bottom of that file.

import {
  THEME_OVERRIDES as OVERRIDES_KEY,
  THEME_BACKGROUNDS as BG_KEY,
  TEXT_SCALE as TEXT_SCALE_KEY,
} from './storageKeys';

// The two token-set modes a theme can use (the `data-theme` attribute values).
export const THEME_MODE = { DARK: 'dark', LIGHT: 'light' };

export const THEMES = [
  {
    id: 'dark-warm',
    label: 'Warm',
    description: 'Sunset ridgeline',
    mode: THEME_MODE.DARK,
    background: '/bg-warm.webp',
    video: '/bg-warm.mp4',
    swatch: { bg: '#1a1410', fg: '#f0e8dc', accent: '#7c5cfc' },
  },
  {
    id: 'dark',
    label: 'Dark',
    description: 'Alpine mountains',
    mode: THEME_MODE.DARK,
    background: '/bg-dark.webp',
    video: '/bg-dark.mp4',
    swatch: { bg: '#0e1420', fg: '#e6ecf5', accent: '#b4875a' },
  },
  {
    id: 'light',
    label: 'Light',
    description: 'Bright surfaces, pixel grid',
    mode: THEME_MODE.LIGHT,
    background: null,
    swatch: { bg: '#e9edf3', fg: '#1c2530', accent: '#2f6fb4' },
  },
  {
    id: 'dark-stars',
    label: 'Stars',
    description: 'Distant planet',
    mode: THEME_MODE.DARK,
    background: '/bg-stars.webp',
    video: '/bg-stars.mp4',
    swatch: { bg: '#080b14', fg: '#dfe6f5', accent: '#7aa2ff' },
  },
  {
    id: 'soiree',
    label: 'Soirée',
    description: 'Bottle green & brushed gold',
    mode: THEME_MODE.DARK,
    background: '/bg-soiree.webp',
    swatch: { bg: '#0b110f', fg: '#efe7d7', accent: '#c9a661' },
  },
  {
    id: 'atelier',
    label: 'Atelier',
    description: 'Ivory, cognac & gold',
    mode: THEME_MODE.LIGHT,
    background: '/bg-atelier.webp',
    procedural: 'bonsai',
    swatch: { bg: '#f5efe6', fg: '#211b17', accent: '#8e4f28' },
  },
  {
    id: 'groovebox',
    label: 'Groovebox',
    description: 'Keycaps on a guidebook grid',
    mode: THEME_MODE.DARK,
    background: '/bg-groovebox.webp',
    procedural: 'groovebox',
    swatch: { bg: '#121214', fg: '#f3f0ea', accent: '#a68cf0' },
    appIcon: 'groovebox',
  },
];

// Theme groups, in display order — drives the grouped picker.
export const THEME_GROUPS = [
  { mode: THEME_MODE.DARK, label: 'Dark themes' },
  { mode: THEME_MODE.LIGHT, label: 'Light themes' },
];

export const DEFAULT_THEME_ID = 'dark-warm';

// ── Advanced customizer ───────────────────────────────────────────────────────
// Curated subset of the token set in tokens.css that users can recolour per theme.
// Each token gets a raw-value text field; `picker: false` hides the native colour
// input for values a colour picker can't represent (gradients). Overrides are
// stored per theme id and layered on top of the theme's own tokens by applyTheme.
export const EDITABLE_TOKEN_GROUPS = [
  {
    label: 'Accents',
    tokens: [
      { key: '--accent-primary', label: 'Primary' },
      { key: '--accent-warm', label: 'Warm' },
      { key: '--accent-success', label: 'Success' },
      { key: '--accent-warning', label: 'Warning' },
      { key: '--accent-danger', label: 'Danger' },
      { key: '--accent-purple', label: 'Purple' },
      { key: '--accent-warm-bright', label: 'Bright accent' },
    ],
  },
  {
    label: 'Surfaces',
    tokens: [
      { key: '--bg-base', label: 'App background' },
      { key: '--bg-sidebar', label: 'Sidebar' },
    ],
  },
  {
    label: 'Text',
    tokens: [
      { key: '--text-primary', label: 'Primary text' },
      { key: '--text-secondary', label: 'Secondary text' },
      { key: '--text-muted', label: 'Muted text' },
      { key: '--text-link', label: 'Links' },
    ],
  },
  {
    label: 'Controls',
    tokens: [
      { key: '--control-checked', label: 'Toggle fill' },
      { key: '--btn-primary-bg', label: 'Primary button', picker: false },
    ],
  },
  {
    label: 'Calendar',
    tokens: [
      { key: '--clock-digits', label: 'Clock digits' },
      { key: '--clock-label', label: 'Clock date & AM/PM' },
    ],
  },
];

// Flat set of every customizable token key — gates what an imported file may set.
export const EDITABLE_TOKEN_KEYS = new Set(
  EDITABLE_TOKEN_GROUPS.flatMap((g) => g.tokens.map((t) => t.key)),
);

// Bump if the shared-theme file shape changes incompatibly.
export const THEME_EXPORT_VERSION = 1;

// localStorage shape: { [themeId]: { '--token': value, ... } }.
function _readOverrideStore() {
  try {
    return JSON.parse(localStorage.getItem(OVERRIDES_KEY)) || {};
  } catch {
    return {};
  }
}

function _writeOverrideStore(store) {
  if (Object.keys(store).length) localStorage.setItem(OVERRIDES_KEY, JSON.stringify(store));
  else localStorage.removeItem(OVERRIDES_KEY);
}

// The user overrides for one theme id (empty object if none).
export function getUserOverrides(themeId) {
  return _readOverrideStore()[themeId] || {};
}

// Set (or, when value is empty/null, clear) one token override for a theme.
export function setUserOverride(themeId, key, value) {
  const store = _readOverrideStore();
  const next = { ...(store[themeId] || {}) };
  if (value == null || value === '') delete next[key];
  else next[key] = value;
  if (Object.keys(next).length) store[themeId] = next;
  else delete store[themeId];
  _writeOverrideStore(store);
}

// Drop all overrides for a theme (reset to the theme's shipped tokens).
export function clearUserOverrides(themeId) {
  const store = _readOverrideStore();
  delete store[themeId];
  _writeOverrideStore(store);
}

// ── Background choice (default backdrop vs a custom image) ───────────────────────
// DEFAULT — the theme's shipped backdrop (an image for dark themes, the dot grid
// for light, which ships none). NONE — force the animated dot grid regardless of
// the theme. CUSTOM — a user-supplied image.
export const BACKGROUND_MODE = { DEFAULT: 'default', NONE: 'none', CUSTOM: 'custom' };

function _readBgStore() {
  try {
    return JSON.parse(localStorage.getItem(BG_KEY)) || {};
  } catch {
    return {};
  }
}

function _writeBgStore(store) {
  if (Object.keys(store).length) localStorage.setItem(BG_KEY, JSON.stringify(store));
  else localStorage.removeItem(BG_KEY);
}

// A theme's background choice: { mode, image }. image is a data URL or null.
export function getBackgroundPref(themeId) {
  const e = _readBgStore()[themeId];
  return { mode: e?.mode || BACKGROUND_MODE.DEFAULT, image: e?.image || null };
}

// Update the background choice. Pass { mode } and/or { image } (image: null clears
// the stored picture). Throws (e.g. quota) — caller surfaces the message.
export function setBackgroundPref(themeId, patch) {
  const store = _readBgStore();
  const cur = store[themeId] || {};
  const mode = patch.mode ?? cur.mode ?? BACKGROUND_MODE.DEFAULT;
  const image = patch.image !== undefined ? patch.image : (cur.image || null);
  if (mode === BACKGROUND_MODE.DEFAULT && !image) delete store[themeId];
  else store[themeId] = image ? { mode, image } : { mode };
  _writeBgStore(store);
}

export function clearBackground(themeId) {
  const store = _readBgStore();
  delete store[themeId];
  _writeBgStore(store);
}

// Resolve a theme's render background, honouring a custom image (drops the ambient
// video so the still custom image shows). Returns the theme unchanged otherwise.
export function resolveThemeBackground(theme) {
  const pref = getBackgroundPref(theme.id);
  if (pref.mode === BACKGROUND_MODE.CUSTOM && pref.image) {
    return { ...theme, background: pref.image, video: null, procedural: null };
  }
  // NONE — drop the shipped backdrop so DotMatrix renders the animated dot grid.
  if (pref.mode === BACKGROUND_MODE.NONE) {
    return { ...theme, background: null, video: null, procedural: null };
  }
  return theme;
}

const _byId = new Map(THEMES.map((t) => [t.id, t]));

// Resolve an id (or legacy value) to a theme, falling back to the default.
export function getTheme(id) {
  return _byId.get(id) || _byId.get(DEFAULT_THEME_ID);
}

// ── Text size ───────────────────────────────────────────────────────────────
// Every --text-* step is in rem, so one <html> font-size multiplier scales the
// whole type ramp while the px spacing grid holds the layout still. Global (not
// per-theme): text size is a reading preference, not part of a theme's look.
export const TEXT_SCALES = [
  { value: 0.9, label: 'Compact' },
  { value: 1, label: 'Default' },
  { value: 1.1, label: 'Large' },
  { value: 1.2, label: 'Larger' },
];

const DEFAULT_TEXT_SCALE = 1;

export function getTextScale() {
  const raw = Number(localStorage.getItem(TEXT_SCALE_KEY));
  return TEXT_SCALES.some((s) => s.value === raw) ? raw : DEFAULT_TEXT_SCALE;
}

export function setTextScale(value) {
  if (value === DEFAULT_TEXT_SCALE) localStorage.removeItem(TEXT_SCALE_KEY);
  else localStorage.setItem(TEXT_SCALE_KEY, String(value));
  applyTextScale();
}

export function applyTextScale() {
  const scale = getTextScale();
  const root = document.documentElement;
  if (scale === DEFAULT_TEXT_SCALE) root.style.removeProperty('font-size');
  else root.style.setProperty('font-size', `${scale * 100}%`);
}

// Override CSS-var keys we last set, so a theme switch can clear stale ones.
let _appliedOverrideKeys = [];

// Apply a theme to <html>: the base token set (`data-theme` = mode), the variant
// hook (`data-theme-variant` = id, which tokens.css keys its per-variant tweaks
// on) and the user's custom-property overrides. Single source of truth so the
// boot path (main.jsx) and the React hook (useTheme) apply themes identically —
// otherwise pre-app screens (the login / onboarding pages, which never mount
// useTheme) miss the user's overrides.
export function applyTheme(id) {
  const theme = getTheme(id);
  const root = document.documentElement;
  root.setAttribute('data-theme', theme.mode);
  root.setAttribute('data-theme-variant', theme.id);
  // The user's per-theme token customizations. Clear any keys we set last time
  // so a switch leaves no residue.
  const merged = getUserOverrides(theme.id);
  for (const key of _appliedOverrideKeys) root.style.removeProperty(key);
  _appliedOverrideKeys = Object.keys(merged);
  for (const [key, value] of Object.entries(merged)) {
    root.style.setProperty(key, value);
  }
  // Ride along with the theme apply so the boot path sets it too.
  applyTextScale();
  return theme;
}

// ── Share (export / import) ─────────────────────────────────────────────────────
// A shareable theme = a base theme id + the user's token overrides on it.

export function exportTheme(themeId) {
  const theme = getTheme(themeId);
  return {
    inbox2Theme: THEME_EXPORT_VERSION,
    baseThemeId: theme.id,
    baseLabel: theme.label,
    overrides: getUserOverrides(theme.id),
    background: getBackgroundPref(theme.id),
  };
}

// Validate an imported object and persist its overrides onto the named base theme.
// Returns the base theme id to activate. Throws on malformed input or unknown base.
export function importTheme(data) {
  if (!data || typeof data !== 'object') throw new Error('Not a theme file.');
  const baseId = data.baseThemeId;
  if (!_byId.has(baseId)) throw new Error(`Unknown base theme “${baseId ?? '—'}”.`);

  const src = data.overrides && typeof data.overrides === 'object' ? data.overrides : {};
  const clean = {};
  for (const [k, v] of Object.entries(src)) {
    // Only accept known editable tokens with non-empty string values.
    if (EDITABLE_TOKEN_KEYS.has(k) && typeof v === 'string' && v.trim()) clean[k] = v.trim();
  }

  const store = _readOverrideStore();
  if (Object.keys(clean).length) store[baseId] = clean;
  else delete store[baseId];
  _writeOverrideStore(store);

  // Background (optional). Accept only a known mode + string image.
  const bg = data.background;
  if (bg && typeof bg === 'object') {
    const mode = Object.values(BACKGROUND_MODE).includes(bg.mode) ? bg.mode : BACKGROUND_MODE.DEFAULT;
    const image = typeof bg.image === 'string' && bg.image ? bg.image : null;
    setBackgroundPref(baseId, { mode, image });
  } else {
    clearBackground(baseId);
  }

  return baseId;
}
