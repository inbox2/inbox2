// Procedural bonsai — the Atelier theme's backdrop.
//
// buildBonsai(w, h) lays out one seeded tree (same tree every time, scaled to
// the viewport); drawBonsai(ctx, scene, p) paints it with growth progress p in
// [0, 1] — trunk first, then branches by depth, then the foliage pads swell in.
// Pure canvas 2D, no DOM, so the theme picker's still (public/bg-atelier.webp)
// can be rendered from the same code.

const SEED = 20260930;
const PAPER_TOP = '#f8f3ea';
const PAPER_BOTTOM = '#efe4d3';
const SUN = 'rgba(226, 178, 112, 0.30)';
const BARK_DARK = '#3e2b20';
const BARK_LIGHT = '#6e5240';
const LEAF_DARK = [52, 66, 40];
const LEAF_LIGHT = [146, 158, 96];
const POT_TOP = '#a3613a';
const POT_BOTTOM = '#6a3a1f';
// Paper mist over the finished painting: keeps the tree a backdrop, not a subject.
const MIST = 'rgba(248, 243, 234, 0.42)';

function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function buildBonsai(w, h) {
  const rnd = rng(SEED);
  const u = Math.min(h, w * 0.75) / 1000; // layout unit
  const baseX = w * 0.7;
  const potTop = h * 0.86;
  const segs = [];
  const pads = [];

  // One limb: a few bent steps, side branches off the trunk and big limbs,
  // a foliage pad at the tip. `t0`..`t1` is the limb's slice of the growth.
  const limb = (x, y, ang, len, wid, depth, t0, t1, side) => {
    const steps = depth === 0 ? 7 : depth === 1 ? 4 : 3;
    let a = ang;
    let flip = rnd() < 0.5 ? 1 : -1;
    for (let i = 0; i < steps; i++) {
      if (depth === 0) a += Math.sin(i * 1.15 + 2.4) * 0.3 + (rnd() - 0.5) * 0.1;
      else {
        // Bonsai limbs run near-horizontal with a slight lift.
        const target = side < 0 ? -Math.PI + 0.22 : -0.22;
        a += (target - a) * 0.35 + (rnd() - 0.5) * 0.45;
      }
      const step = len / steps;
      const nx = x + Math.cos(a) * step;
      const ny = y + Math.sin(a) * step;
      const w0 = wid * (1 - (i / steps) * 0.6);
      const w1 = wid * (1 - ((i + 1) / steps) * 0.6);
      const s0 = t0 + ((t1 - t0) * i) / steps;
      const s1 = t0 + ((t1 - t0) * (i + 1)) / steps;
      segs.push({ x0: x, y0: y, x1: nx, y1: ny, w0, w1, s0, s1 });

      if (depth === 0 && i >= 2 && i < steps - 1) {
        flip = -flip;
        const k = 1 - i / steps;
        limb(nx, ny, a + flip * (1.0 + rnd() * 0.3), len * (0.36 + k * 0.22), w1 * 0.5, 1, s1, Math.min(1, s1 + 0.3), flip);
      } else if (depth === 1 && i >= 1 && rnd() < 0.55) {
        const sd = rnd() < 0.5 ? -1 : 1;
        limb(nx, ny, a + sd * 0.7, len * 0.4, w1 * 0.55, 2, s1, Math.min(1, s1 + 0.15), side);
      }
      x = nx;
      y = ny;
    }
    const r = (depth === 0 ? 150 : depth === 1 ? 95 : 60) * u * (0.85 + rnd() * 0.3);
    const dabs = [];
    const n = depth === 0 ? 160 : depth === 1 ? 110 : 60;
    for (let j = 0; j < n; j++) {
      // Flat-topped cloud: dabs fill a squashed half-ellipse, densest low.
      const ang2 = rnd() * Math.PI * 2;
      const rad = Math.sqrt(rnd());
      const dx = Math.cos(ang2) * rad * r;
      const dy = Math.sin(ang2) * rad * r * 0.36 - r * 0.1;
      dabs.push({ dx, dy, r: r * (0.06 + rnd() * 0.07), lift: (0.36 * r - dy) / (0.72 * r) });
    }
    dabs.sort((p, q) => q.dy - p.dy); // underside first, lit top last
    pads.push({ x, y, r, dabs, s: t1 });
  };

  // Distant Fuji: concave cone with a flat crater rim, a jagged snow line,
  // and two low ridges in front — all washed out in drawBonsai.
  const fuji = { x: w * 0.4, top: h * 0.36, base: h * 0.8, half: Math.min(w * 0.44, h * 0.95), rim: h * 0.05 };
  const mrnd = rng(SEED + 1); // own stream so the tree's shape doesn't shift
  const snow = [];
  for (let i = 0; i <= 28; i++) snow.push(0.16 + mrnd() * 0.04 + (i % 2) * (0.04 + mrnd() * 0.1));
  const ridges = [0.7, 0.77].map((y0, k) => {
    const pts = [];
    for (let x = -40; x <= w + 40; x += 40) {
      pts.push([x, h * y0 + Math.sin(x / (260 + k * 140) + k * 2) * 26 * u + (mrnd() - 0.5) * 10 * u]);
    }
    return pts;
  });

  limb(baseX, potTop - 18 * u, -Math.PI / 2 + 0.1, 560 * u, 70 * u, 0, 0, 0.55, 0);

  return {
    w, h, u, baseX, potTop, segs, pads, fuji, snow, ridges,
    pot: { x: baseX - 210 * u, y: potTop, w: 420 * u, h: 62 * u },
    sun: { x: baseX - 120 * u, y: potTop - 520 * u, r: 300 * u },
  };
}

const ease = (t) => 1 - (1 - t) ** 3;
const clamp01 = (t) => Math.max(0, Math.min(1, t));
const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));

export function drawBonsai(ctx, sc, p = 1) {
  const { w, h, u, baseX, potTop, pot, sun } = sc;

  const paper = ctx.createLinearGradient(0, 0, 0, h);
  paper.addColorStop(0, PAPER_TOP);
  paper.addColorStop(1, PAPER_BOTTOM);
  ctx.fillStyle = paper;
  ctx.fillRect(0, 0, w, h);

  const glow = ctx.createRadialGradient(sun.x, sun.y, 0, sun.x, sun.y, sun.r);
  glow.addColorStop(0, SUN);
  glow.addColorStop(0.7, SUN);
  glow.addColorStop(1, 'rgba(226, 178, 112, 0)');
  ctx.fillStyle = glow;
  ctx.fillRect(0, 0, w, h);

  // Mountains: shape first, then fade each toward the mist at its foot.
  const { fuji, snow } = sc;
  const fujiPath = () => {
    ctx.beginPath();
    ctx.moveTo(fuji.x - fuji.half, fuji.base);
    ctx.quadraticCurveTo(fuji.x - fuji.half * 0.42, fuji.base - (fuji.base - fuji.top) * 0.35, fuji.x - fuji.rim, fuji.top);
    ctx.lineTo(fuji.x + fuji.rim, fuji.top);
    ctx.quadraticCurveTo(fuji.x + fuji.half * 0.42, fuji.base - (fuji.base - fuji.top) * 0.35, fuji.x + fuji.half, fuji.base);
    ctx.closePath();
  };
  const fujiFill = ctx.createLinearGradient(0, fuji.top, 0, fuji.base);
  fujiFill.addColorStop(0, 'rgba(120, 132, 150, 0.30)');
  fujiFill.addColorStop(1, 'rgba(120, 132, 150, 0)');
  ctx.fillStyle = fujiFill;
  fujiPath();
  ctx.fill();
  // Snow cap: clip to the cone, fill down to a ragged line.
  ctx.save();
  fujiPath();
  ctx.clip();
  const span = fuji.half * 0.42;
  ctx.beginPath();
  ctx.moveTo(fuji.x - span, fuji.top - 10);
  snow.forEach((d, i) => {
    ctx.lineTo(fuji.x - span + (2 * span * i) / (snow.length - 1), fuji.top + (fuji.base - fuji.top) * d);
  });
  ctx.lineTo(fuji.x + span, fuji.top - 10);
  ctx.closePath();
  ctx.fillStyle = 'rgba(252, 250, 246, 0.75)';
  ctx.fill();
  ctx.restore();
  sc.ridges.forEach((pts, k) => {
    const top = Math.min(...pts.map((q) => q[1]));
    const g = ctx.createLinearGradient(0, top, 0, top + h * 0.2);
    g.addColorStop(0, `rgba(130, 140, 140, ${0.16 + k * 0.06})`);
    g.addColorStop(1, 'rgba(130, 140, 140, 0)');
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.moveTo(pts[0][0], h);
    for (const [x, y] of pts) ctx.lineTo(x, y);
    ctx.lineTo(pts[pts.length - 1][0], h);
    ctx.closePath();
    ctx.fill();
  });

  // Shadow on the table, then the pot.
  ctx.fillStyle = 'rgba(80, 52, 30, 0.12)';
  ctx.beginPath();
  ctx.ellipse(baseX, pot.y + pot.h + 6 * u, pot.w * 0.62, 16 * u, 0, 0, Math.PI * 2);
  ctx.fill();
  const potFill = ctx.createLinearGradient(0, pot.y, 0, pot.y + pot.h);
  potFill.addColorStop(0, POT_TOP);
  potFill.addColorStop(1, POT_BOTTOM);
  ctx.fillStyle = potFill;
  ctx.beginPath();
  ctx.moveTo(pot.x - 10 * u, pot.y);
  ctx.lineTo(pot.x + pot.w + 10 * u, pot.y);
  ctx.lineTo(pot.x + pot.w - 14 * u, pot.y + pot.h);
  ctx.lineTo(pot.x + 14 * u, pot.y + pot.h);
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = 'rgba(255, 230, 200, 0.35)';
  ctx.fillRect(pot.x - 10 * u, pot.y, pot.w + 20 * u, 4 * u);
  ctx.fillStyle = POT_BOTTOM;
  ctx.fillRect(pot.x + 30 * u, pot.y + pot.h, 34 * u, 10 * u);
  ctx.fillRect(pot.x + pot.w - 64 * u, pot.y + pot.h, 34 * u, 10 * u);

  // Moss mound.
  ctx.fillStyle = `rgb(${LEAF_DARK.join(',')})`;
  ctx.beginPath();
  ctx.ellipse(baseX, potTop, pot.w * 0.46, 14 * u, 0, Math.PI, 0);
  ctx.fill();

  // Root flare (nebari).
  const rootP = ease(clamp01(p / 0.08));
  ctx.strokeStyle = BARK_DARK;
  ctx.lineCap = 'round';
  for (const [dx, wd] of [[-80, 16], [-46, 22], [52, 20], [92, 13]]) {
    ctx.lineWidth = wd * u;
    ctx.beginPath();
    ctx.moveTo(baseX, potTop - 30 * u);
    ctx.quadraticCurveTo(baseX + dx * 0.4 * u, potTop - 6 * u, baseX + dx * rootP * u, potTop - 2 * u);
    ctx.stroke();
  }

  // Wood: dark stroke, then a narrower highlight on the lit side.
  for (const pass of [0, 1]) {
    ctx.strokeStyle = pass ? BARK_LIGHT : BARK_DARK;
    for (const sg of sc.segs) {
      if (p <= sg.s0) continue;
      const k = clamp01((p - sg.s0) / (sg.s1 - sg.s0));
      const x1 = sg.x0 + (sg.x1 - sg.x0) * k;
      const y1 = sg.y0 + (sg.y1 - sg.y0) * k;
      const wd = (sg.w0 + sg.w1) / 2;
      ctx.lineWidth = pass ? wd * 0.35 : wd;
      const off = pass ? -wd * 0.22 : 0;
      ctx.beginPath();
      ctx.moveTo(sg.x0 + off, sg.y0);
      ctx.lineTo(x1 + off, y1);
      ctx.stroke();
    }
  }

  // Foliage pads swell in once their limb has reached them.
  for (const pad of sc.pads) {
    const k = ease(clamp01((p - pad.s + 0.05) / 0.25));
    if (k <= 0) continue;
    ctx.fillStyle = 'rgba(52, 40, 28, 0.08)';
    ctx.beginPath();
    ctx.ellipse(pad.x, pad.y + pad.r * 0.32, pad.r * 1.05 * k, pad.r * 0.16 * k, 0, 0, Math.PI * 2);
    ctx.fill();
    for (const d of pad.dabs) {
      const [r, g, b] = mix(LEAF_DARK, LEAF_LIGHT, clamp01(d.lift));
      ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${0.5 * k + 0.2})`;
      ctx.beginPath();
      ctx.arc(pad.x + d.dx * k, pad.y + d.dy * k, d.r * k, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  ctx.fillStyle = MIST;
  ctx.fillRect(0, 0, w, h);
}
