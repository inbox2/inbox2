/* Squarified treemap layout — Bruls, Huizing & van Wijk (2000). Pure geometry,
 * no dependency. Given { value, ... } items and a pixel rect, returns each item
 * annotated with { x, y, w, h } in the same pixel space. Computing in real
 * pixels keeps the aspect-ratio term honest so cells stay near-square. */

function worstRatio(row, side) {
  let sum = 0;
  let max = -Infinity;
  let min = Infinity;
  for (const n of row) {
    sum += n.area;
    if (n.area > max) max = n.area;
    if (n.area < min) min = n.area;
  }
  const s2 = sum * sum;
  return Math.max((side * side * max) / s2, s2 / (side * side * min));
}

function layoutRow(row, rect, out) {
  let sum = 0;
  for (const n of row) sum += n.area;
  if (rect.w >= rect.h) {
    const band = sum / rect.h;
    let y = rect.y;
    for (const n of row) {
      const h = n.area / band;
      out.push({ ...n.item, x: rect.x, y, w: band, h });
      y += h;
    }
    rect.x += band;
    rect.w -= band;
  } else {
    const band = sum / rect.w;
    let x = rect.x;
    for (const n of row) {
      const w = n.area / band;
      out.push({ ...n.item, x, y: rect.y, w, h: band });
      x += w;
    }
    rect.y += band;
    rect.h -= band;
  }
}

/** Lay out `items` (each with numeric `value`) inside the pixel rect.
 *  Returns a new array of `{ ...item, x, y, w, h }`. Drops value<=0. */
export function squarify(items, x, y, width, height) {
  const live = items.filter((it) => it.value > 0);
  if (live.length === 0 || width <= 0 || height <= 0) return [];
  let total = 0;
  for (const it of live) total += it.value;
  const scale = (width * height) / total;
  const nodes = live.map((it) => ({ item: it, area: it.value * scale }));
  const out = [];
  const rect = { x, y, w: width, h: height };
  let i = 0;
  while (i < nodes.length) {
    let row = [nodes[i]];
    const side = Math.min(rect.w, rect.h);
    let best = worstRatio(row, side);
    let j = i + 1;
    while (j < nodes.length) {
      const candidate = row.concat(nodes[j]);
      const ratio = worstRatio(candidate, side);
      if (ratio > best) break;
      row = candidate;
      best = ratio;
      j += 1;
    }
    layoutRow(row, rect, out);
    i = j;
  }
  return out;
}

/** Shrink a rect by `gap` on every side, never past zero. */
export function inset(r, gap) {
  return { x: r.x + gap, y: r.y + gap, w: Math.max(0, r.w - gap * 2), h: Math.max(0, r.h - gap * 2) };
}
