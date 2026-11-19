// Procedural guidebook grid: the Groovebox theme's backdrop.
//
// A charcoal ground under a violet isometric line grid, with outlined pastel
// objects (rainbow arcs, keycaps, pyramids, a dial, felt pom-poms) parked
// around the edges where the panels don't cover them. Same contract as
// lib/bonsai.js: buildGroovebox(w, h) lays the scene out once per size,
// drawGroovebox(ctx, scene, p) paints it with p in [0, 1]: the grid fades up,
// then the outlines trace themselves in. Pure canvas 2D, so the theme picker's
// still (public/bg-groovebox.webp) renders from the same code.

const GROUND = '#2a2a2e';
const GRID = 'rgba(148, 121, 216, 0.42)';
const INK = '#f3f0ea';
const CORAL = '#f2785c';
const MUSTARD = '#f0b545';
const TEAL = '#44c2b3';
const LAVENDER = '#a68cf0';
const PINK = '#f0a3bd';

// Isometric rhombus cell (30° lines).
const CELL_W = 96;
const CELL_H = CELL_W * Math.tan(Math.PI / 6);

export function buildGroovebox(w, h) {
  const u = Math.max(0.6, Math.min(w, h) / 900); // layout unit
  const shapes = [];

  // Bottom-left: rainbow arcs, outermost first.
  [CORAL, MUSTARD, TEAL, LAVENDER].forEach((color, i) => {
    shapes.push({ kind: 'arc', x: -20 * u, y: h + 20 * u, r: (300 - i * 34) * u, color });
  });
  // Top-left: a big dial with its crescent.
  shapes.push({ kind: 'dial', x: 120 * u, y: 110 * u, r: 70 * u, color: LAVENDER });
  // Top-right: two pyramids.
  shapes.push({ kind: 'pyramid', x: w - 150 * u, y: 150 * u, s: 120 * u, color: CORAL });
  shapes.push({ kind: 'pyramid', x: w - 60 * u, y: 200 * u, s: 90 * u, color: MUSTARD });
  // Right edge: stacked keycaps.
  shapes.push({ kind: 'key', x: w - 140 * u, y: h * 0.52, s: 92 * u, color: TEAL });
  shapes.push({ kind: 'key', x: w - 110 * u, y: h * 0.52 + 120 * u, s: 92 * u, color: MUSTARD });
  // Bottom-right: one cream key.
  shapes.push({ kind: 'key', x: w - 230 * u, y: h - 120 * u, s: 92 * u, color: INK });
  // Felt pom-poms, scattered along the bottom and top edges.
  [
    [0.32, 0.96, CORAL], [0.55, 0.985, LAVENDER], [0.74, 0.93, TEAL],
    [0.42, 0.04, PINK], [0.63, 0.025, MUSTARD], [0.88, 0.97, PINK],
  ].forEach(([fx, fy, color]) => shapes.push({ kind: 'pom', x: w * fx, y: h * fy, r: 9 * u, color }));

  return { w, h, u, shapes };
}

function rrect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
}

function grid(ctx, w, h) {
  ctx.strokeStyle = GRID;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  // Two families of 30° lines; extend past the edges so the rhombi tile clean.
  const slope = CELL_H / CELL_W;
  const span = w * slope + h;
  for (let c = -span; c <= span + h; c += CELL_H) {
    ctx.moveTo(0, c);
    ctx.lineTo(w, c + w * slope);
    ctx.moveTo(0, c);
    ctx.lineTo(w, c - w * slope);
  }
  ctx.stroke();
}

function shape(ctx, s, u) {
  ctx.strokeStyle = s.color;
  ctx.fillStyle = s.color;
  ctx.lineWidth = 3 * u;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  switch (s.kind) {
    case 'arc':
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.r, -Math.PI / 2, 0);
      ctx.stroke();
      break;
    case 'dial':
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(s.x + s.r * 0.12, s.y - s.r * 0.2, s.r * 0.36, Math.PI * 0.75, Math.PI * 2.1);
      ctx.stroke();
      break;
    case 'pyramid':
      ctx.beginPath();
      ctx.moveTo(s.x - s.s * 0.6, s.y);
      ctx.lineTo(s.x, s.y - s.s);
      ctx.lineTo(s.x + s.s * 0.6, s.y);
      ctx.closePath();
      ctx.moveTo(s.x, s.y - s.s);
      ctx.lineTo(s.x + s.s * 0.12, s.y);
      ctx.stroke();
      break;
    case 'key': {
      const k = s.s;
      // Ghost (the keycap's skirt), then the cap and its legend slot.
      ctx.globalAlpha *= 0.5;
      rrect(ctx, s.x + 8 * u, s.y - 8 * u, k, k * 0.82, 20 * u);
      ctx.stroke();
      ctx.globalAlpha /= 0.5;
      rrect(ctx, s.x, s.y, k, k * 0.82, 20 * u);
      ctx.stroke();
      ctx.strokeStyle = INK;
      rrect(ctx, s.x + k * 0.3, s.y + k * 0.16, k * 0.38, k * 0.2, k * 0.1);
      ctx.stroke();
      break;
    }
    case 'pom':
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
      ctx.fill();
      break;
    default:
  }
}

export function drawGroovebox(ctx, scene, p = 1) {
  const { w, h, u, shapes } = scene;
  ctx.globalAlpha = 1;
  ctx.fillStyle = GROUND;
  ctx.fillRect(0, 0, w, h);

  // Grid over the first 40% of the run, objects one after another over the rest.
  ctx.globalAlpha = Math.min(1, p / 0.4);
  grid(ctx, w, h);
  const t = Math.max(0, (p - 0.3) / 0.7) * shapes.length;
  shapes.forEach((s, i) => {
    const a = Math.min(1, Math.max(0, t - i));
    if (a <= 0) return;
    ctx.globalAlpha = a;
    shape(ctx, s, u);
  });
  ctx.globalAlpha = 1;
}
