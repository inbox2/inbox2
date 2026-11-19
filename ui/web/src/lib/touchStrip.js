// Touch Strip — the app-wide bottom bar (docs/Touch-Strip.md). This module is the
// non-React half: the widget registry, the default layout, the synced config
// store, and the pure maths the widgets draw with (treemap, time zones, rain).
import { useSyncExternalStore } from 'react';
import api from './api';
import log from './log';
import { createExternalStore } from './prefStore';
import { TOUCH_STRIP_CONFIG } from './storageKeys';

// Mirrors User::TOUCH_STRIP_ITEMS (the API rejects anything else).
export const STRIP_ITEMS = ['clocks', 'weather', 'stocks', 'crypto', 'news', 'ip'];

// Palette copy + icon per widget; `expands` = tapping the key opens a
// full-width view (the IP key copies instead).
export const STRIP_WIDGETS = {
  clocks: { label: 'World clocks', hint: 'Up to 6 cities, meeting planner', icon: 'clock', expands: true },
  weather: { label: 'Weather', hint: 'Your location or chosen cities', icon: 'cloud.sun', expands: true },
  stocks: { label: 'Stocks', hint: 'Watchlist treemap', icon: 'square.treemap', expands: true },
  crypto: { label: 'Crypto', hint: 'Prices with 24h sparklines', icon: 'dollarsign.circle.fill', expands: true },
  news: { label: 'News', hint: 'Headlines from RSS feeds', icon: 'newspaper', expands: true },
  ip: { label: 'Public IP', hint: 'Click to copy, flags VPNs', icon: 'globe', expands: false },
};

export const STOCK_SIZE = { EQUAL: 'equal', WEIGHT: 'weight' };
export const CRYPTO_CURRENCIES = ['EUR', 'USD'];

const LIMITS = { clocks: 6, places: 3, stocks: 24, crypto: 8, feeds: 6 };
export const stripLimit = (section) => LIMITS[section];

export const localTimeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

// "Europe/Amsterdam" → "AMS": the default short label for a clock.
export const shortLabel = (name) => (name || '').split('/').pop().replace(/[^A-Za-z]/g, '').slice(0, 3).toUpperCase() || 'UTC';

// A preference default, not display data: the strip a new user starts from.
function defaultConfig() {
  const tz = localTimeZone();
  return {
    items: [...STRIP_ITEMS],
    clocks: [
      { label: shortLabel(tz), tz },
      { label: 'NYC', tz: 'America/New_York' },
      { label: 'SFO', tz: 'America/Los_Angeles' },
      { label: 'TYO', tz: 'Asia/Tokyo' },
    ].filter((c, i, all) => all.findIndex((o) => o.tz === c.tz) === i),
    places: [{ current: true }],
    stocks: ['AAPL', 'NVDA', 'MSFT', 'ASML.AS', 'GOOGL', 'AMZN'].map((symbol) => ({ symbol, weight: 1 })),
    crypto: ['BTC', 'ETH', 'SOL'],
    feeds: [
      { label: 'NOS', url: 'https://feeds.nos.nl/nosnieuwsalgemeen' },
      { label: 'HN', url: 'https://hnrss.org/frontpage' },
    ],
    options: { stock_size: STOCK_SIZE.EQUAL, crypto_currency: 'EUR' },
  };
}

// Saved sections win; a section the account never saved (null) keeps the default.
export function mergeConfig(saved) {
  const base = defaultConfig();
  if (!saved || typeof saved !== 'object') return base;
  const out = { ...base };
  for (const key of Object.keys(base)) {
    if (saved[key] == null) continue;
    out[key] = key === 'options' ? { ...base.options, ...saved.options } : saved[key];
  }
  out.items = (out.items || []).filter((id) => STRIP_ITEMS.includes(id));
  return out;
}

// ── Config store: localStorage for instant paint (and the standalone desktop,
// which has no account), synced to the account when signed in. ──────────────

function readLocal() {
  try {
    const raw = localStorage.getItem(TOUCH_STRIP_CONFIG);
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}

let config = mergeConfig(readLocal());
let remote = false; // true once the account copy loaded — only then do saves go up
let saveTimer = null;
const store = createExternalStore(() => config);

export function setStripConfig(update) {
  config = mergeConfig(typeof update === 'function' ? update(config) : update);
  try { localStorage.setItem(TOUCH_STRIP_CONFIG, JSON.stringify(config)); } catch { /* storage unavailable */ }
  store.emit();
  if (!remote) return;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    api.saveTouchStrip(config).catch((e) => log.warn('TouchStrip', `save failed: ${e?.message || e}`));
  }, 800);
}

export const resetStripConfig = () => setStripConfig(defaultConfig());

// Pull the account's strip. An account that never saved one adopts this
// device's layout (pushes it up) rather than resetting it to defaults.
export async function loadRemoteStripConfig() {
  try {
    const { touch_strip: saved } = await api.getTouchStrip();
    remote = true;
    const hasSaved = saved && Object.values(saved).some((v) => v != null);
    if (hasSaved) {
      config = mergeConfig(saved);
      try { localStorage.setItem(TOUCH_STRIP_CONFIG, JSON.stringify(config)); } catch { /* storage unavailable */ }
      store.emit();
    } else {
      setStripConfig(config);
    }
  } catch (e) {
    log.warn('TouchStrip', `load failed: ${e?.message || e}`);
  }
}

export const useStripConfig = () => useSyncExternalStore(store.subscribe, store.getSnapshot);

// ── Treemap (squarified, Bruls et al.) ───────────────────────────────────────
// items: [{ value, ... }] → same items + { x, y, w, h } in a W×H box. Sorted
// largest first, which is what keeps the cells close to square.
export function squarify(items, W, H) {
  const total = items.reduce((s, i) => s + Math.max(i.value, 0), 0);
  if (!total || W <= 0 || H <= 0) return [];
  const scale = (W * H) / total;
  const nodes = [...items].sort((a, b) => b.value - a.value).map((i) => ({ ...i, area: Math.max(i.value, 0) * scale }));

  const out = [];
  let x = 0; let y = 0; let w = W; let h = H;
  let row = [];
  const worst = (r, side) => {
    const s = r.reduce((a, n) => a + n.area, 0);
    const max = Math.max(...r.map((n) => n.area));
    const min = Math.min(...r.map((n) => n.area));
    return Math.max((side * side * max) / (s * s), (s * s) / (side * side * min));
  };
  const place = () => {
    const s = row.reduce((a, n) => a + n.area, 0);
    if (!s) return;
    if (w >= h) { // a column on the left
      const cw = s / h;
      let yy = y;
      for (const n of row) { const nh = n.area / cw; out.push({ ...n, x, y: yy, w: cw, h: nh }); yy += nh; }
      x += cw; w -= cw;
    } else { // a row along the top
      const rh = s / w;
      let xx = x;
      for (const n of row) { const nw = n.area / rh; out.push({ ...n, x: xx, y, w: nw, h: rh }); xx += nw; }
      y += rh; h -= rh;
    }
    row = [];
  };
  for (let i = 0; i < nodes.length;) {
    const side = Math.min(w, h);
    if (!row.length || worst([...row, nodes[i]], side) <= worst(row, side)) { row.push(nodes[i]); i += 1; } else place();
  }
  place();
  return out;
}

// Day change → a colour step: flat, then three steps each way.
export function changeBucket(pct) {
  if (pct == null || Math.abs(pct) < 0.05) return 'flat';
  const mag = Math.abs(pct);
  const step = mag < 1 ? 1 : mag < 2.5 ? 2 : 3;
  return `${pct > 0 ? 'up' : 'down'}${step}`;
}

// Weighted mean of the day change — the watchlist's one headline number.
export function weightedChange(quotes, weightOf) {
  let sum = 0; let wsum = 0;
  for (const q of quotes) {
    if (q.change_pct == null) continue;
    const w = weightOf(q.symbol);
    sum += q.change_pct * w; wsum += w;
  }
  return wsum ? sum / wsum : null;
}

// ── Time zones ───────────────────────────────────────────────────────────────

// Minutes east of UTC for `tz` at `date` (DST-correct, via Intl).
export function tzOffsetMinutes(tz, date = new Date()) {
  try {
    const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric',
      hour: 'numeric', minute: 'numeric', second: 'numeric',
    }).formatToParts(date).map((p) => [p.type, p.value]));
    const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
    return Math.round((asUtc - date.getTime()) / 60000);
  } catch { return 0; }
}

// Minutes past midnight in `tz`.
export function minutesInZone(tz, date = new Date()) {
  const m = (date.getUTCHours() * 60 + date.getUTCMinutes() + tzOffsetMinutes(tz, date)) % 1440;
  return (m + 1440) % 1440;
}

// "+7", "−6", "+5:30" relative to `baseTz`; '' when the same.
export function relativeOffset(tz, baseTz, date = new Date()) {
  const d = tzOffsetMinutes(tz, date) - tzOffsetMinutes(baseTz, date);
  if (!d) return '';
  const sign = d > 0 ? '+' : '−';
  const abs = Math.abs(d);
  return `${sign}${Math.floor(abs / 60)}${abs % 60 ? `:${String(abs % 60).padStart(2, '0')}` : ''}`;
}

export const WORK_START = 9 * 60;
export const WORK_END = 17 * 60;
const SLOT = 15;

// A city's 09:00–17:00 on the viewer's 24h axis, as [start, end) minute spans
// (two when it wraps past midnight).
export function workingSpans(tz, baseTz, date = new Date()) {
  const shift = tzOffsetMinutes(tz, date) - tzOffsetMinutes(baseTz, date);
  const start = (((WORK_START - shift) % 1440) + 1440) % 1440;
  const end = start + (WORK_END - WORK_START);
  return end <= 1440 ? [[start, end]] : [[start, 1440], [0, end - 1440]];
}

// The longest window (viewer-local minutes) where every zone is in working
// hours, or null when there is none.
export function sharedWindow(tzs, baseTz, date = new Date()) {
  if (!tzs.length) return null;
  const slots = new Array(1440 / SLOT).fill(true);
  for (const tz of tzs) {
    const spans = workingSpans(tz, baseTz, date);
    slots.forEach((ok, i) => {
      const m = i * SLOT;
      if (ok && !spans.some(([s, e]) => m >= s && m < e)) slots[i] = false;
    });
  }
  let best = null; let runStart = null;
  slots.concat(false).forEach((ok, i) => {
    if (ok && runStart === null) runStart = i;
    if (!ok && runStart !== null) {
      if (!best || i - runStart > best[1] - best[0]) best = [runStart, i];
      runStart = null;
    }
  });
  return best && [best[0] * SLOT, best[1] * SLOT];
}

// Rough phase of the day from local clock time alone (the clocks know a zone,
// not a latitude): night before 06:00 and from 21:00, twilight either side of
// 07:30–19:30. ponytail: fixed hours; real sunrise needs coordinates per city.
export const DAY_PHASE = { NIGHT: 'night', DAWN: 'dawn', DAY: 'day', DUSK: 'dusk' };
export function dayPhase(minutes) {
  if (minutes < 360 || minutes >= 1260) return DAY_PHASE.NIGHT;
  if (minutes < 450) return DAY_PHASE.DAWN;
  if (minutes >= 1170) return DAY_PHASE.DUSK;
  return DAY_PHASE.DAY;
}

export const formatMinutes = (m) => `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

// ── Weather ──────────────────────────────────────────────────────────────────

// WMO weather code → the Icon name the strip draws.
export function weatherIcon(code, isDay = true) {
  if (code == null) return 'cloud';
  if (code <= 1) return isDay ? 'sun.max.fill' : 'moon.fill';
  if (code === 2) return isDay ? 'cloud.sun' : 'cloud';
  if (code === 3) return 'cloud';
  if (code === 45 || code === 48) return 'cloud.fog';
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return 'cloud.snow';
  if (code >= 95) return 'cloud.bolt';
  return 'cloud.rain';
}

const WET_MM = 0.1;
const hhmm = (iso) => (iso || '').slice(11, 16);

// Open-Meteo's 15-minute precipitation slots → one line: when it starts / stops.
export function rainSummary(rain) {
  if (!rain?.length) return null;
  const wet = rain.map((r) => r.mm >= WET_MM);
  const hours = Math.round((rain.length * SLOT) / 60);
  if (!wet.some(Boolean)) return `Dry for ${hours}h`;
  if (wet[0]) {
    const dry = wet.indexOf(false);
    return dry === -1 ? `Rain for the next ${hours}h` : `Rain until ~${hhmm(rain[dry].time)}`;
  }
  return `Rain from ${hhmm(rain[wet.indexOf(true)].time)}`;
}

// ── Numbers ──────────────────────────────────────────────────────────────────

export function formatPrice(n) {
  if (n == null) return '—';
  const digits = Math.abs(n) >= 1000 ? 0 : Math.abs(n) >= 1 ? 2 : 4;
  return n.toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function formatPct(n) {
  if (n == null) return '';
  return `${n > 0 ? '+' : n < 0 ? '−' : ''}${Math.abs(n).toFixed(2)}%`;
}

// "ASML.AS" → "ASML", "BTC-EUR" → "BTC", "^AEX" → "AEX": the tile label.
export const tickerLabel = (symbol) => symbol.replace(/^\^/, '').split(/[.-]/)[0];
