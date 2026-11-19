// Pure formatting helpers shared by the MX admin console (AdminSyncs) and its
// extracted management widgets.

// Compact count: 1200 → "1.2K", 12000 → "12K".
export function fmt(n) {
  if (n >= 1000) return `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}K`;
  return String(n);
}

// Plan limit → readable label. Plan.UNLIMITED is 999_999 (api/app/models/plan.rb).
export function limitLabel(value, noun) {
  if (value >= 999999) return `Unlimited ${noun}s`;
  return `${value} ${noun}${value === 1 ? '' : 's'}`;
}

// Cents → "$0" / "$19.99" (drop the decimals only for whole-dollar amounts).
export function priceLabel(cents) {
  const dollars = (cents || 0) / 100;
  return `$${Number.isInteger(dollars) ? dollars : dollars.toFixed(2)}`;
}

// Build a sparkline path from a data series (normalized to the 0–100 × 0–44 box).
export function seriesToPath(series) {
  if (!series || series.length < 2) return null;
  // All-zero series = no activity yet. Drawing it maps every point to the
  // baseline, i.e. a flat horizontal line that reads as a stray blue rule.
  if (series.every((v) => !v)) return null;
  const max = Math.max(...series, 1);
  const n = series.length;
  const pts = series.map((v, i) => {
    const x = (i / (n - 1)) * 100;
    const y = 42 - (v / max) * 38;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  return `M${pts.join(' L')}`;
}
